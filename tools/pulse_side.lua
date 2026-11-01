-- ============================================================
--  pulse_side.lua —— 红石 io 端口「输出面」手动诊断工具
--
--  背景：活化工具台在红石端口【正下方】时正常；端口放【边上/上方】时
--  会莫名其妙连挥两下。怀疑是 farmio 里「六面全写」导致。
--  本工具让你手动指定【只写某一个面】发脉冲，逐个面测，
--  定位到底是不是「六面输出」的问题。
--
--  OC 的 side 编号（setOutput 的第二参数，固定世界方向，与方块朝向无关）：
--    0 = bottom(下)   1 = top(上)
--    2 = north(北)    3 = south(南)
--    4 = west(西)     5 = east(东)
--  不确定哪个编号贴着工具台？用 scan 模式依次试，盯游戏里工具台的反应。
--
--  用法（在 OC 电脑里，先 cd 到本文件所在目录）：
--    lua pulse_side.lua              交互式菜单（推荐）
--    lua pulse_side.lua status       只看端口/工具台状态，不发脉冲
--    lua pulse_side.lua scan         依次对 0~5 面各发一次（间隔 3 秒）
--    lua pulse_side.lua all          六面全写一次（对照组 = 现在 main.lua 的做法）
--    lua pulse_side.lua 3            只对第 3 面（south）发一次
--    lua pulse_side.lua 3 0.1        第 3 面，脉冲宽度 0.1 秒
-- ============================================================
local component = require("component")

local SIDE_NAMES = {
  [0] = "bottom(下)", [1] = "top(上)",
  [2] = "north(北)",  [3] = "south(南)",
  [4] = "west(西)",   [5] = "east(东)",
}

-- 默认脉冲宽度：与 config.timing.pulse_width 一致（0.05 秒 = 1 tick）
local WIDTH = 0.05

local function invoke(addr, method, ...)
  local ok, res = pcall(component.invoke, addr, method, ...)
  if ok then return true, res end
  local okp, proxy = pcall(component.proxy, addr)
  if okp and proxy then
    local f = proxy[method]
    if f ~= nil then
      local ok2, res2 = pcall(f, ...)
      if ok2 then return true, res2 end
      return false, tostring(res2)
    end
  end
  return false, tostring(res)
end

-- 枚举某类型的全部地址
local function list_type(t)
  local out = {}
  for a, ty in component.list(t, true) do
    if ty == t then out[#out + 1] = a end
  end
  return out
end

-- 收集命令行参数（OpenOS 的 lua 把参数放 varargs，也可能在全局 arg）
local function collect_args(...)
  local t = {}
  for i = 1, select("#", ...) do t[#t + 1] = select(i, ...) end
  if #t == 0 and type(arg) == "table" then
    for _, v in pairs(arg) do
      if type(v) == "string" then t[#t + 1] = v end
    end
  end
  return t
end
local ARGS = collect_args(...)

-- ============ 挑红石端口 ============
local reds = list_type("redstone")
if #reds == 0 then
  print("[错误] 没找到红石 io 端口。请先贴一个 redstone I/O 到活化工具台旁边。")
  return
end
local rs = reds[1]
if #reds > 1 then
  print("[提示] 检测到 " .. #reds .. " 个红石端口，默认用第一个：" .. tostring(rs))
  for i, a in ipairs(reds) do print(string.format("   %d) %s", i, tostring(a))) end
  print("   要用别的端口，改脚本里 `local rs = reds[1]` 的下标，或临时拆掉多余端口。")
end

-- ============ 读活化工具台状态（只读，绝不 set） ============
local function tablet()
  local tabs = list_type("tt_animationTablet")
  return tabs[1]
end

local function read_field(m)
  local a = tablet()
  if not a then return "无工具台" end
  local ok, r = pcall(component.invoke, a, m)
  if not ok then return "ERR" end
  return tostring(r)
end

local function tablet_state()
  local a = tablet()
  if not a then return "（OC 网络里没有活化工具台）" end
  return string.format("redstone=%s leftClick=%s rotation=%s hasItem=%s",
    read_field("getRedstone"), read_field("getLeftClick"),
    read_field("getRotation"), read_field("hasItem"))
end

local function left_click() return read_field("getLeftClick") end

-- ============ 发脉冲 ============
-- 只写一个面
local function pulse_side(addr, side, width)
  invoke(addr, "setOutput", side, 0)
  invoke(addr, "setOutput", side, 15)
  os.sleep(width)
  invoke(addr, "setOutput", side, 0)
end

-- 六面全写（对照组 = 现在 farmio.pulse 的实际行为）
local function pulse_all(addr, width)
  for s = 0, 5 do invoke(addr, "setOutput", s, 0) end
  for s = 0, 5 do invoke(addr, "setOutput", s, 15) end
  os.sleep(width)
  for s = 0, 5 do invoke(addr, "setOutput", s, 0) end
end

-- 把前后 getLeftClick 差算出来，差>1 大概率是连挥
local function diff(before, after)
  local b, a = tonumber(before), tonumber(after)
  if b and a then
    local d = a - b
    if d > 1 then return string.format("%+d  ← 疑似连挥！", d)
    elseif d == 1 then return "+1（正常挥一下）"
    else return string.format("%+d", d) end
  end
  return "?"
end

-- 一次单面脉冲，并报告工具台变化
local function do_side(side)
  local before = left_click()
  print(string.format("→ 只写第 %d 面（%s），宽度 %.2f 秒", side, SIDE_NAMES[side] or "?", WIDTH))
  pulse_side(rs, side, WIDTH)
  os.sleep(0.6)   -- 等工具台响应再读
  local after = left_click()
  print(string.format("   getLeftClick: %s -> %s（%s）", tostring(before), tostring(after), diff(before, after)))
  print("   请同时用肉眼看游戏里：工具台挥了几下？")
end

-- 六面全写一次（对照组）
local function do_all()
  local before = left_click()
  print(string.format("→ 六面全写一次，宽度 %.2f 秒（对照组）", WIDTH))
  pulse_all(rs, WIDTH)
  os.sleep(0.6)
  local after = left_click()
  print(string.format("   getLeftClick: %s -> %s（%s）", tostring(before), tostring(after), diff(before, after)))
  print("   请同时用肉眼看游戏里：工具台挥了几下？")
end

-- 自动逐面扫描
local function do_scan()
  print("依次对 6 个面各发一次脉冲，每面间隔 3 秒，请盯紧工具台：")
  for s = 0, 5 do
    local before = left_click()
    print(string.format("[面 %d %s] 发脉冲…", s, SIDE_NAMES[s] or "?"))
    pulse_side(rs, s, WIDTH)
    os.sleep(3)
    local after = left_click()
    print(string.format("   getLeftClick: %s -> %s（%s）", tostring(before), tostring(after), diff(before, after)))
  end
  print("scan 完成。重点记：哪个面能触发工具台、触发时挥了几下。")
end

-- 名称转编号（支持 bottom/top/north/south/west/east）
local NAME_TO_SIDE = { bottom = 0, top = 1, north = 2, south = 3, west = 4, east = 5, down = 0, up = 1 }

local function parse_side(s)
  local n = tonumber(s)
  if n and n >= 0 and n <= 5 then return math.floor(n) end
  local key = tostring(s):lower()
  if NAME_TO_SIDE[key] ~= nil then return NAME_TO_SIDE[key] end
  return nil
end

-- ============ 主入口 ============
local cmd = ARGS[1] and tostring(ARGS[1]) or ""
local cmd_l = cmd:lower()

-- 可选宽度参数：lua pulse_side.lua <side> <width>
local arg2 = ARGS[2] and tonumber(ARGS[2])
if arg2 and arg2 >= 0.05 and arg2 <= 0.5 then WIDTH = arg2 end

if cmd_l == "status" or cmd_l == "s" then
  print("红石端口：" .. tostring(rs))
  print("工具台状态：" .. tablet_state())
  return
end

if cmd_l == "scan" then
  do_scan()
  return
end

if cmd_l == "all" then
  do_all()
  return
end

local side = parse_side(cmd)
if side ~= nil then
  do_side(side)
  return
end

if cmd ~= "" then
  print("[提示] 看不懂参数 \"" .. cmd .. "\"。下面进入交互式菜单。")
end

-- 交互式菜单
print("==== 红石输出面诊断 ====")
print("红石端口：" .. tostring(rs))
print("工具台状态：" .. tablet_state())
print("  0~5  只对该面发一次脉冲")
print("  all  六面全写一次（对照组）")
print("  scan 依次 0~5 每面一次（间隔 3 秒）")
print("  s    刷新状态")
print("  q    退出")
while true do
  io.write("> ")
  local line = io.read("*l")
  if not line then return end
  line = line:lower():gsub("^%s+", ""):gsub("%s+$", "")
  if line == "q" or line == "quit" then
    return
  elseif line == "s" or line == "status" then
    print("工具台状态：" .. tablet_state())
  elseif line == "all" then
    do_all()
  elseif line == "scan" then
    do_scan()
  else
    local s = parse_side(line)
    if s ~= nil then
      do_side(s)
    else
      print("[提示] 看不懂，输入 0~5 / all / scan / s / q")
    end
  end
end
