-- 测试：能不能通过 ME 接口终端把样板在接口之间搬动
-- 用法：lua test_move.lua
-- 规则（防止打断别人发配）：
--   * 源 = 样板仓库接口（cfg.ae.warehouse 有坐标就用坐标；否则只认 name=Nothing 的接口）
--   * 目标 = 贴着工业农场的下单接口（cfg.farms[1].interface 有坐标就用坐标；否则找 name 含 industrialfarm 的）
--   * 任何名字含 industrialfarm 的接口都绝不当源
-- 结论写进 /home/ocfarm/move.txt，同时打印到屏幕
local component = require("component")
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

-- 终端地址可能因为拆装变过：失效就自动找当前的
local function proxy_ok(a)
  if not a then return nil end
  local ok, p = pcall(component.proxy, a)
  return (ok and p) and a or nil
end
if not proxy_ok(cfg.ae.terminal) then
  for a in component.list("me_interface_terminal", true) do cfg.ae.terminal = a break end
end

local A = dofile("/home/ocfarm/lib/ae.lua").new({
  storage = cfg.ae.storage,
  seed = cfg.ae.seed,
  terminal = cfg.ae.terminal,
})

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
  return string.format("x%s y%s z%s dim%s",
    tostring(l.x), tostring(l.y), tostring(l.z), tostring(l.dimId or l.dimension))
end

local function same_loc(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  return a.x == b.x and a.y == b.y and a.z == b.z
end

local function is_farm_iface(it)
  local nm = tostring(it.name or "")
  if nm:find("industrialfarm", 1, true) then return true end
  if nm:find("industrial_farm", 1, true) then return true end
  return false
end

local function snapshot(tag)
  local list = A:interfaces()
  say("==== %s：共 %d 个接口 ====", tag, #list)
  local out = {}
  for i, it in ipairs(list) do
    local n = pcount(it.patterns)
    out[i] = { it = it, n = n }
    say("  #%d %s  name=%s  side=%s  patterns=%d",
      i, loc_str(it.location), tostring(it.name), tostring(it.side), n)
  end
  return out
end

local function mk(entry, slot)
  local l = entry.it.location or {}
  return {
    location = { x = l.x, y = l.y, z = l.z, dimension = l.dimId or l.dimension or 0 },
    side = entry.it.side or 0,
    slot = slot or 0,
  }
end

local function try_send(term, entry_src, entry_dst, slot)
  local src, dst = mk(entry_src, slot), mk(entry_dst, slot)
  local variants = {
    { name = "send{source,target}", fn = function()
        return component.invoke(term, "send", { source = src, target = dst })
      end },
    { name = "send(src,dst)", fn = function()
        return component.invoke(term, "send", src, dst)
      end },
    { name = "sendBatch{{source,target}}", fn = function()
        return component.invoke(term, "sendBatch", { { source = src, target = dst } })
      end },
  }
  local changed = nil
  for _, v in ipairs(variants) do
    local ok, res = pcall(v.fn)
    say("  尝试 %-30s → ok=%s res=%s", v.name, tostring(ok), tostring(res))
    -- 每次尝试后都看一遍接口：样板动了就停
    local now = snapshot("尝试 " .. v.name .. " 后")
    local s2, d2 = nil, nil
    for _, e in ipairs(now) do
      if same_loc(e.it.location, entry_src.it.location) then s2 = e end
      if same_loc(e.it.location, entry_dst.it.location) then d2 = e end
    end
    if s2 and d2 and s2.n < entry_src.n and d2.n > entry_dst.n then
      changed = v.name
      break
    end
  end
  return changed
end

local function run()
  say("==== 样板搬运测试 ====")
  local before = snapshot("搬运前")
  if #before == 0 then
    say("[失败] 接口终端看不到任何接口（终端地址不对，或终端不在播种网上）")
    return
  end

  -- 选目标：优先 config 里指定的农场接口坐标，否则第一个 industrialfarm 接口
  local dst
  local want = cfg.farms and cfg.farms[1] and cfg.farms[1].interface
  for _, e in ipairs(before) do
    if is_farm_iface(e.it) and (dst == nil) then dst = e end
  end
  if want then
    for _, e in ipairs(before) do
      if same_loc(e.it.location, want) then dst = e end
    end
  end

  -- 选源：只允许「仓库接口」。有坐标用坐标，没有就只认 name=Nothing 的
  local src
  local wh = cfg.ae.warehouse
  if wh then
    for _, e in ipairs(before) do
      if same_loc(e.it.location, wh) then src = e end
    end
  end
  if not src then
    for _, e in ipairs(before) do
      local nm = tostring(e.it.name or "")
      if e.n > 0 and not is_farm_iface(e.it) and (nm == "Nothing" or nm == "") then src = e end
    end
  end

  if not src then
    say("[失败] 没找到样板仓库接口（name=Nothing 且 patterns>0）")
    say("        如果你有多个仓库接口，请在 config.lua 里写 ae.warehouse = {x=?,y=?,z=?}")
    return
  end
  if not dst then
    say("[失败] 没找到贴着工业农场的下单接口")
    say("        请在 config.lua 里给 farms[1].interface = {x=?,y=?,z=?} 指定坐标")
    return
  end
  src.slot = first_slot(src.it.patterns)
  say("仓库接口: %s (patterns=%d, slot=%s)", loc_str(src.it.location), src.n, tostring(src.slot))
  say("下单接口: %s (patterns=%d, name=%s)", loc_str(dst.it.location), dst.n, tostring(dst.it.name))
  say("→ 只从仓库拿样板，绝不从别的农场下单接口拿")

  local used = try_send(cfg.ae.terminal, src, dst, src.slot or 0)
  local after = snapshot("最终状态")
  local s2, d2
  for _, e in ipairs(after) do
    if same_loc(e.it.location, src.it.location) then s2 = e end
    if same_loc(e.it.location, dst.it.location) then d2 = e end
  end
  say("仓库 patterns %d → %s ; 下单 patterns %d → %s",
    src.n, s2 and s2.n or "?", dst.n, d2 and d2.n or "?")
  if used then
    say("[成功] 样板搬动了，可用调用形态：%s", used)
  else
    say("[失败] 调用没把样板搬动（参数结构可能不对，见上面每次尝试的返回）")
  end
end

local okrun, errrun = pcall(run)
if not okrun then say("[异常] %s", tostring(errrun)) end
util.write(ROOT .. "/move.txt", table.concat(lines, "\n") .. "\n")
say("已写入 %s/move.txt", ROOT)
