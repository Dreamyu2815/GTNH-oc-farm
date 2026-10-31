-- 一次完整的发配演练（带台账 + 启动样板回收）：
--   1) 找仓库接口与农场下单接口（按游戏里改的名字，config 里配）
--   2) 启动自检：把其它接口上残留的样板搬回仓库（台账里有在制任务时跳过）
--   3) 读存储网产物，确认低于低阈值
--   4) 把样板从仓库搬到下单接口
--   5) 下单 N 颗（45 的整数倍，能用多少发多少）
--   6) 等发配完成（网络里的种子减少 N 颗）
--   7) 记台账（总种子 = 网络 + 在制），把样板搬回仓库
-- 用法：lua dispatch_test.lua
local component = require("component")
local computer = require("computer")
local util = dofile("/home/ocfarm/lib/util.lua")
local cfg = dofile("/home/ocfarm/config.lua")
local ROOT = "/home/ocfarm"

local lines = {}
local function say(fmt, ...)
  local ok, s = pcall(string.format, fmt, ...)
  if not ok then s = tostring(fmt) end
  io.write(s .. "\n"); io.flush()
  lines[#lines + 1] = s
end

local function proxy_ok(a)
  if not a then return nil end
  local ok = pcall(component.proxy, a)
  return ok and a or nil
end
if not proxy_ok(cfg.ae.terminal) then
  for a in component.list("me_interface_terminal", true) do cfg.ae.terminal = a break end
end

local A = dofile("/home/ocfarm/lib/ae.lua").new({
  storage = cfg.ae.storage,
  seed = cfg.ae.seed,
  terminal = cfg.ae.terminal,
})

local CROP = "空间之花"
local ci = (cfg.crops or {})[CROP] or {}
local mult = math.max(math.floor(ci.mult or 1), 1)
local OUT = ci.out or CROP
local STATE = ROOT .. "/dispatch_state.dat"

-- ===== 小工具 =====
local function pcount(pat)
  if type(pat) ~= "table" then return 0 end
  local n = 0
  for _ in pairs(pat) do n = n + 1 end
  return n
end

local function first_slot(pat)
  if type(pat) ~= "table" then return 0 end
  local best
  for k, v in pairs(pat) do
    if type(k) == "number" and v ~= nil and (best == nil or k < best) then best = k end
  end
  return best or 0
end

local function loc_str(l)
  if type(l) ~= "table" then return "?" end
  return string.format("x%s y%s z%s", tostring(l.x), tostring(l.y), tostring(l.z))
end

local function same_loc(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  return a.x == b.x and a.y == b.y and a.z == b.z
end

local function is_farm_iface(it)
  return tostring(it.name or ""):find("industrialfarm", 1, true) ~= nil
end

local function count_at(list, loc)
  for _, it in ipairs(list) do
    if same_loc(it.location, loc) then return pcount(it.patterns) end
  end
  return -1
end

-- ===== 接口识别：名字优先 =====
local function find_pair()
  local list = A:interfaces()
  local whName = (cfg.ae or {}).warehouse_name
  local fname = cfg.farms and cfg.farms[1] and cfg.farms[1].interface_name
  local wh_named, wh_blank_pat, wh_blank, farm_named, farm_type
  for _, it in ipairs(list) do
    local nm = tostring(it.name or "")
    local pats = pcount(it.patterns)
    if whName and nm == whName then wh_named = it end
    if fname and nm == fname then farm_named = it end
    if is_farm_iface(it) then farm_type = farm_type or it end
    if nm == "Nothing" or nm == "" then
      if pats > 0 then wh_blank_pat = wh_blank_pat or it else wh_blank = wh_blank or it end
    end
  end
  return (wh_named or wh_blank_pat or wh_blank), (farm_named or farm_type), list
end

local function mk(it, slot)
  local l = it.location or {}
  return {
    location = { x = l.x, y = l.y, z = l.z, dimension = l.dimId or l.dimension or 0 },
    side = it.side,
    slot = slot or 0,
  }
end

local function send_pattern(from_it, to_it, slot)
  return pcall(component.invoke, cfg.ae.terminal, "send", mk(from_it, slot), mk(to_it, slot))
end

-- 搬运 + 静默确认（按坐标比对数量，AE 接口列表有刷新延迟）
local function move_and_verify(from_it, to_it, slot, want_from, want_to)
  local ok, res = send_pattern(from_it, to_it, slot)
  for _ = 1, 10 do
    os.sleep(0.5)
    local list = A:interfaces()
    if count_at(list, from_it.location) == want_from
      and count_at(list, to_it.location) == want_to then
      return true, ok, res
    end
  end
  return false, ok, res
end

-- ===== 种子台账 =====
local function ledger_load()
  local d = util.load(STATE, {})
  d.crops = d.crops or {}
  return d
end

local function ledger_save(d)
  util.save(STATE, d)
end

-- 总种子 = 网络 + 在制；空闲时以网络为准
local function ledger_sync(d, crop, net, in_machine, idle)
  local rec = d.crops[crop] or {}
  if idle then
    rec.total = net
  else
    rec.total = math.max(rec.total or 0, net + (in_machine or 0))
  end
  rec.net = net
  rec.in_machine = math.max(0, (rec.total or net) - net)
  d.crops[crop] = rec
  ledger_save(d)
  return rec
end

local function inflight_total(d)
  local n = 0
  for _, r in pairs(d.crops or {}) do n = n + (r.in_machine or 0) end
  return n
end

-- ===== 启动自检：把非仓库接口上的样板全搬回仓库 =====
local function sweep_patterns()
  local wh, _, list = find_pair()
  if not wh then return 0, 0, "没有仓库接口" end
  local moved, failed = 0, 0
  for _, it in ipairs(list) do
    if not same_loc(it.location, wh.location) then
      local nm = tostring(it.name or "")
      local is_target = is_farm_iface(it)
      for _, f in ipairs(cfg.farms or {}) do
        if f.interface_name and nm == f.interface_name then is_target = true end
      end
      if is_target and pcount(it.patterns) > 0 then
        local w0 = pcount(wh.patterns)
        local f0 = pcount(it.patterns)
        for slot in pairs(it.patterns) do
          if type(slot) == "number" then
            if move_and_verify(it, wh, slot, f0 - 1, w0 + 1) then
              moved = moved + 1
              f0 = f0 - 1
              w0 = w0 + 1
            else
              failed = failed + 1
              say("[警告] 样板搬不动：%s slot=%d", loc_str(it.location), slot)
            end
          end
        end
      end
    end
  end
  return moved, failed, nil
end

local function run()
  say("==== 发配演练（%s）====", CROP)
  local wh, farm, list = find_pair()
  say("接口共 %d 个", #list)
  for i, it in ipairs(list) do
    say("  #%d %s name=%s patterns=%d", i, loc_str(it.location), tostring(it.name), pcount(it.patterns))
  end
  if not wh then say("[失败] 找不到仓库接口（看 config.ae.warehouse_name）"); return end
  if not farm then say("[失败] 找不到农场下单接口（看 config.farms[i].interface_name）"); return end

  -- 启动自检：先扫一遍残留样板
  local d = ledger_load()
  local inflight = inflight_total(d)
  if inflight > 0 then
    say("[自检] 台账还有 %d 颗种子在制，跳过样板回收", inflight)
  else
    local n1, n2, berr = sweep_patterns()
    if berr then
      say("[自检] 跳过样板回收：%s", berr)
    elseif n1 == 0 and n2 == 0 then
      say("[自检] 接口上没有残留样板")
    else
      say("[自检] 样板回收：搬回 %d 个，失败 %d 个", n1, n2)
      local w2, f2 = find_pair()
      wh, farm = w2, f2
      if not wh or not farm then say("[失败] 回收后接口识别失败"); return end
    end
  end

  -- 产物与阈值
  local prods = A:items_by_label("storage")
  local have = math.floor((prods[CROP] and prods[CROP].count) or 0)
  local lo = ((cfg.thresholds or {})[CROP] or {}).low or 128
  local hi = ((cfg.thresholds or {})[CROP] or {}).high or 512
  say("[检查] 存储网 %s = %d，阈值 %d/%d → %s", CROP, have, lo, hi,
    (have < lo) and "低于低阈值，可以开工" or "还没低于阈值")
  if have >= lo then say("[跳过] 产物还够"); return end

  -- 种子/垫块
  local s0 = A:seeds_by_label("seed")
  local seedNet = math.floor((s0[CROP] and s0[CROP].count) or 0)
  local items0 = A:items_by_label("seed")
  local subNet = seedNet
  if ci.subsoil then subNet = math.floor((items0[ci.subsoil] and items0[ci.subsoil].count) or 0) end

  local rec0 = d.crops[CROP]
  local inMachine = rec0 and (rec0.in_machine or 0) or 0
  say("[台账] 网络种子 %d + 在制 %d = 总种子 %d", seedNet, inMachine, seedNet + inMachine)

  -- 搬样板：仓库 → 下单接口
  if pcount(farm.patterns) > 0 then
    say("[搬样] 下单接口上已经有样板了，跳过搬入")
  else
    local slot = first_slot(wh.patterns)
    if pcount(wh.patterns) == 0 then say("[失败] 仓库里没有样板"); return end
    say("[搬样] 仓库 %s → 下单接口 %s", loc_str(wh.location), loc_str(farm.location))
    local w0, f0 = pcount(wh.patterns), pcount(farm.patterns)
    local okm = move_and_verify(wh, farm, slot, w0 - 1, f0 + 1)
    if not okm then say("[失败] 样板没搬过去（重试 5 秒仍不匹配）"); return end
    say("[搬样] 完成（仓库 %d，下单 %d）", w0 - 1, f0 + 1)
  end

  -- 数量：45 的整数倍，能用多少发多少
  local cap = 1225
  do
    local okF, F = pcall(dofile, "/home/ocfarm/lib/farmio.lua")
    if okF and F and cfg.farms and cfg.farms[1] then
      local s = F.new():read_sensor(cfg.farms[1].gt)
      if s and s.capacity then cap = math.floor(s.capacity) end
    end
  end
  local limit = math.min(seedNet, cap, math.max(lo - have, 1))
  if ci.subsoil then limit = math.min(limit, subNet) end
  local n = math.floor(limit / mult) * mult
  if mult <= 1 then n = math.floor(limit) end
  if n <= 0 then
    say("[跳过] 凑不满 1 份：种子 %d，垫块 %d，容量 %d，缺口 %d，1 份需 %d 颗",
      seedNet, subNet, cap, math.max(lo - have, 1), mult)
    return
  end
  say("[下单] %s ×%d（%d 份 × %d 颗）｜网络种子 %d，垫块 %d，容量 %d，缺口 %d",
    OUT, n, math.floor(n / mult), mult, seedNet, subNet, cap, math.max(lo - have, 1))

  local before = seedNet
  local job, rerr = A:request("seed", OUT, n)
  if not job then
    say("[失败] 下单失败：%s", tostring(rerr))
    return
  end
  local recA = ledger_sync(d, CROP, seedNet, inMachine, false)
  say("[台账] 开工：总量 %d（网络 %d + 在制 %d）", recA.total, recA.net, recA.in_machine)

  -- 等发配完成
  say("[下单] 已提交，等发配（最多 120 秒）")
  local t0 = computer.uptime()
  local last, stable, progressed = seedNet, 0, false
  while computer.uptime() - t0 < 120 do
    os.sleep(2)
    local s2 = A:seeds_by_label("seed")[CROP]
    local now = math.floor((s2 and s2.count) or 0)
    if now <= before - n then
      say("[发配] 完成：种子 %d → %d（减少 %d，需要 %d），用时 %.0f 秒",
        before, now, before - now, n, computer.uptime() - t0)
      progressed = true
      break
    end
    if now < last then
      progressed = true
      stable = 0
      say("      …种子 %d → %d（已吸 %d/%d）", last, now, before - now, n)
    else
      stable = stable + 1
      if progressed and stable >= 3 then
        say("[发配] 停在 %d/%d（减少 %d，需要 %d），用时 %.0f 秒",
          now, before, before - now, n, computer.uptime() - t0)
        break
      end
    end
    last = now
  end
  if not progressed then say("[警告] 120 秒内种子一颗都没动") end

  -- 台账：这些种子现在算在制
  local s3 = A:seeds_by_label("seed")[CROP]
  local netNow = math.floor((s3 and s3.count) or 0)
  local recB = ledger_sync(d, CROP, netNow, n, false)
  say("[台账] 现在：总量 %d = 网络 %d + 在制 %d", recB.total, recB.net, recB.in_machine)

  -- 样板搬回仓库
  local w4, f4 = find_pair()
  if f4 and pcount(f4.patterns) > 0 then
    local s4 = first_slot(f4.patterns)
    local w0, f0 = pcount(w4.patterns), pcount(f4.patterns)
    local okb = move_and_verify(f4, w4, s4, f0 - 1, w0 + 1)
    say("[搬样] 下单接口 → 仓库 %s", okb and "完成" or "没确认到（再等一会儿看看）")
  else
    say("[警告] 下单接口上没有样板了")
  end
end

local okrun, errrun = pcall(run)
if not okrun then say("[异常] %s", tostring(errrun)) end
util.write(ROOT .. "/dispatch.txt", table.concat(lines, "\n") .. "\n")
say("已写入 %s/dispatch.txt", ROOT)
