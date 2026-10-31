-- 完整单农场闭环测试（一轮）：
--   1 自检（接口名字、传感器、红石、残留样板回收）
--   2 产物低阈值检查
--   3 搬样板 仓库 → 下单接口
--   4 下单 N 颗
--   5 等发配完成（优先用 job 状态，退而统计种子减少）
--   6 脉冲 → Farm，等产物到 high
--   7 脉冲 → Output，等种子回网
--   8 台账对账 → 脉冲 → Input
--   9 样板搬回仓库
-- 每一步都打印耗时，用来抓"到底哪一步慢"。
-- 用法：lua full_test.lua        正常按阈值判断
--       lua full_test.lua force  忽略阈值，强制跑一轮
local component = require("component")
local computer = require("computer")
local util = dofile("/home/ocfarm/lib/util.lua")
local cfg = dofile("/home/ocfarm/config.lua")
local F = dofile("/home/ocfarm/lib/farmio.lua")
local ROOT = "/home/ocfarm"

local lines = {}
local function say(fmt, ...)
  local ok, s = pcall(string.format, fmt, ...)
  if not ok then s = tostring(fmt) end
  io.write(s .. "\n"); io.flush()
  lines[#lines + 1] = s
end

local T0 = computer.uptime()
local LAST = T0
local function step(name)
  local now = computer.uptime()
  local d = now - LAST
  LAST = now
  if d >= 0.3 then say("[耗时] %s 用了 %.1f 秒", name, d) end
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
local SUB = ci.subsoil
local farm = (cfg.farms or {})[1]
local T = cfg.timing or {}
local th = (cfg.thresholds or {})[CROP] or {}
local LO, HI = th.low or 128, th.high or 512
local FORCE = tostring((arg and arg[1]) or "") == "force"
local STATE = ROOT .. "/dispatch_state.dat"

-- ===== 工具 =====
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

local function count_at(list, loc)
  for _, it in ipairs(list) do
    if same_loc(it.location, loc) then return pcount(it.patterns) end
  end
  return -1
end

local function is_farm_iface(it)
  return tostring(it.name or ""):find("industrialfarm", 1, true) ~= nil
end

local function find_pair()
  local list = A:interfaces()
  local whName = (cfg.ae or {}).warehouse_name
  local fname = farm and farm.interface_name
  local wh_named, wh_blank_pat, wh_blank, farm_named, farm_type
  for _, it in ipairs(list) do
    local nm = tostring(it.name or "")
    if whName and nm == whName then wh_named = it end
    if fname and nm == fname then farm_named = it end
    if is_farm_iface(it) then farm_type = farm_type or it end
    if nm == "Nothing" or nm == "" then
      if pcount(it.patterns) > 0 then wh_blank_pat = wh_blank_pat or it else wh_blank = wh_blank or it end
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

-- 网络里某作物的数量（用 label 过滤，AE 侧先筛，快很多）
local function count_label(kind, label)
  local t0 = computer.uptime()
  local q = A:query(kind, { label = label })
  local n = 0
  for _, s in ipairs(q) do n = n + (s.size or 0) end
  if #q == 0 then
    -- 过滤没生效时退回全量扫描
    local all = A:items_by_label(kind)
    n = math.floor((all[label] and all[label].count) or 0)
  end
  return math.floor(n), computer.uptime() - t0
end

-- ===== 台账 =====
local function ledger_load()
  local d = util.load(STATE, {})
  d.crops = d.crops or {}
  return d
end
local function ledger_save(d) util.save(STATE, d) end
local function inflight_total(d)
  local n = 0
  for _, r in pairs(d.crops or {}) do n = n + (r.in_machine or 0) end
  return n
end
local function ledger_sync(d, crop, net, in_machine, idle)
  local rec = d.crops[crop] or {}
  if idle then rec.total = net else rec.total = math.max(rec.total or 0, net + (in_machine or 0)) end
  rec.net = net
  rec.in_machine = math.max(0, (rec.total or net) - net)
  d.crops[crop] = rec
  ledger_save(d)
  return rec
end

-- ===== job 状态 =====
local function job_flag(job, name)
  if job == nil then return nil end
  local f = job[name]
  if f == nil then return nil end
  local ok, v = pcall(function() return job[name](job) end)
  if ok then return v end
  ok, v = pcall(f)
  if ok then return v end
  return nil
end

local function run()
  say("==== 完整闭环测试（%s）%s ====", CROP, FORCE and "[强制]" or "")
  local wh, f_if, list = find_pair()
  say("接口 %d 个：", #list)
  for i, it in ipairs(list) do
    say("  #%d %s name=%s patterns=%d", i, loc_str(it.location), tostring(it.name), pcount(it.patterns))
  end
  if not wh or not f_if then
    say("[失败] 仓库=%s 农场接口=%s 识别失败（检查名字）", tostring(wh ~= nil), tostring(f_if ~= nil))
    return
  end
  step("列接口")

  -- 传感器
  local sen = F.new():read_sensor(farm.gt)
  local cap = sen and math.floor(sen.capacity or 0) or 0
  say("[农场] 等级 %s，容量 %d，耗水 %s/周期", tostring(sen and sen.level), cap, tostring(sen and sen.water))
  step("读传感器")

  -- 红石
  local okr, rerr = F.new():test_redstone(farm.redstone)
  say("[红石] %s", okr and "六面可写" or ("异常：" .. tostring(rerr)))
  if not okr then return end
  step("红石自检")

  -- 残留样板回收
  local d = ledger_load()
  local inflight = inflight_total(d)
  if inflight > 0 then
    say("[自检] 台账还有 %d 颗在制，跳过样板回收", inflight)
  else
    local swept = 0
    local _, _, lst = find_pair()
    for _, it in ipairs(lst) do
      if not same_loc(it.location, wh.location) then
        local nm = tostring(it.name or "")
        local hit = is_farm_iface(it) or (farm.interface_name and nm == farm.interface_name)
        if hit and pcount(it.patterns) > 0 then
          local s = first_slot(it.patterns)
          if move_and_verify(it, wh, s, 0, pcount(wh.patterns) + 1) then swept = swept + 1 end
        end
      end
    end
    say("[自检] 残留样板回收 %d 个", swept)
    wh, f_if = find_pair()
  end
  step("残留回收")

  -- 产物
  local have, dt = count_label("storage", CROP)
  say("[产物] 存储网 %s = %d（阈值 %d/%d，查询 %.1fs）→ %s", CROP, have, LO, HI, dt,
    (have < LO) and "可以开工" or "已达阈值")
  if have >= LO and not FORCE then say("[跳过] 未低于低阈值"); return end

  -- 种子 / 垫块
  local seeds = A:seeds_by_label("seed")
  local seedNet = math.floor((seeds[CROP] and seeds[CROP].count) or 0)
  local subNet = seedNet
  if SUB then
    local it2 = A:items_by_label("seed")
    subNet = math.floor((it2[SUB] and it2[SUB].count) or 0)
  end
  local rec0 = d.crops[CROP]
  local inMachine = rec0 and (rec0.in_machine or 0) or 0
  say("[种子] 网络 %d，垫块 %s %d，在制 %d，总 %d", seedNet, SUB or "-", subNet, inMachine, seedNet + inMachine)
  step("读种子")

  -- 搬样板
  if pcount(f_if.patterns) > 0 then
    say("[搬样] 下单接口上已有样板，跳过")
  else
    local slot = first_slot(wh.patterns)
    if pcount(wh.patterns) == 0 then say("[失败] 仓库没样板"); return end
    local w0, f0 = pcount(wh.patterns), pcount(f_if.patterns)
    local ok = move_and_verify(wh, f_if, slot, w0 - 1, f0 + 1)
    say("[搬样] 仓库 → 下单接口 %s（仓库 %d→%d）", ok and "完成" or "失败", w0, w0 - 1)
    if not ok then return end
  end
  step("搬样板")

  -- 下单
  local limit = math.min(seedNet, cap, math.max(LO - have, 1))
  if SUB then limit = math.min(limit, subNet) end
  local n = math.floor(limit / mult) * mult
  if mult <= 1 then n = math.floor(limit) end
  if n <= 0 then
    say("[跳过] 凑不满 1 份：种子 %d 垫块 %d 容量 %d，1 份 %d 颗", seedNet, subNet, cap, mult)
    return
  end
  local before = seedNet
  local tq = computer.uptime()
  local job, jerr = A:request("seed", OUT, n)
  say("[下单] %s ×%d（%d 份）｜job=%s 请求耗时 %.1fs", OUT, n, math.floor(n / mult),
    tostring(job ~= nil), computer.uptime() - tq)
  if not job then say("[失败] %s", tostring(jerr)); return end
  ledger_sync(d, CROP, seedNet, inMachine, false)
  step("下单")

  -- 等发配：优先 job.isDone
  local t0, dispatched = computer.uptime(), false
  while computer.uptime() - t0 < 120 do
    os.sleep(1)
    local done = job_flag(job, "isDone")
    local fail = job_flag(job, "hasFailed")
    if fail == true then say("[失败] 合成任务标记为失败"); break end
    if done == true then
      say("[发配] job 完成，用时 %.0f 秒", computer.uptime() - t0)
      dispatched = true
      break
    end
    local now = count_label("seed", CROP)
    if now <= before - n then
      say("[发配] 种子 %d → %d（-%.0f 秒）", before, now, computer.uptime() - t0)
      dispatched = true
      break
    end
  end
  if not dispatched then say("[警告] 120 秒没等到发配完成，继续跑看看") end
  step("等发配")

  -- 台账：这批种子算在制
  local netNow = count_label("seed", CROP)
  local recA = ledger_sync(d, CROP, netNow, n, false)
  say("[台账] 总量 %d = 网络 %d + 在制 %d", recA.total, recA.net, recA.in_machine)
  step("记账")

  -- 脉冲 → Farm
  local okp, perr = F.new():pulse(farm.redstone, T.pulse_width or 0.1, farm.redstone_side)
  say("[切换] → Farm %s", okp and "已发脉冲" or ("失败：" .. tostring(perr)))
  if not okp then return end
  step("脉冲 Farm")

  -- 等产物到 high
  local t1 = computer.uptime()
  local lastp = have
  while computer.uptime() - t1 < (T.grow_timeout or 7200) do
    os.sleep(5)
    local p = count_label("storage", CROP)
    if p ~= lastp then
      say("      …产物 %d → %d（%d/%d）", lastp, p, p, HI)
      lastp = p
    end
    if p >= HI then
      say("[产物] 到阈值 %d，用时 %.0f 秒", p, computer.uptime() - t1)
      break
    end
  end
  if lastp < HI then say("[警告] 产物没到 %d（现在 %d），仍然继续收", HI, lastp) end
  step("等产物")

  -- 脉冲 → Output
  local okp2 = F.new():pulse(farm.redstone, T.pulse_width or 0.1, farm.redstone_side)
  say("[切换] → Output %s", okp2 and "已发脉冲" or "失败")
  step("脉冲 Output")

  -- 等种子回网
  local baseSeed = (d.crops[CROP] and d.crops[CROP].in_machine) or 0
  local t2 = computer.uptime()
  local hard = T.reclaim_timeout or 180
  local back = 0
  while computer.uptime() - t2 < hard do
    os.sleep(2)
    local now = count_label("seed", CROP)
    back = now - netNow
    if back >= baseSeed then break end
  end
  say("[回收] 种子回来 %d/%d（用时 %.0f 秒）", math.floor(back), math.floor(baseSeed), computer.uptime() - t2)
  step("等回收")

  -- 台账：回收后回到空闲基准
  local netEnd = count_label("seed", CROP)
  local recB = ledger_sync(d, CROP, netEnd, 0, true)
  say("[台账] 校准：总量 = 网络 %d", recB.total)
  step("台账校准")

  -- 脉冲 → Input
  local okp3 = F.new():pulse(farm.redstone, T.pulse_width or 0.1, farm.redstone_side)
  say("[切换] → Input %s", okp3 and "已发脉冲" or "失败")
  step("脉冲 Input")

  -- 样板回仓库
  local w2, f2 = find_pair()
  if f2 and pcount(f2.patterns) > 0 then
    local s = first_slot(f2.patterns)
    local w0, f0 = pcount(w2.patterns), pcount(f2.patterns)
    local ok2 = move_and_verify(f2, w2, s, f0 - 1, w0 + 1)
    say("[搬样] 下单接口 → 仓库 %s", ok2 and "完成" or "未确认")
  else
    say("[警告] 下单接口上没有样板")
  end
  step("样板回仓库")

  say("[完成] 一整轮结束，总耗时 %.0f 秒", computer.uptime() - T0)
end

local okrun, errrun = pcall(run)
if not okrun then say("[异常] %s", tostring(errrun)) end
util.write(ROOT .. "/full.txt", table.concat(lines, "\n") .. "\n")
say("已写入 %s/full.txt", ROOT)
