-- ============================================================
--  pulse_side.lua —— 红石 I/O 端口「输出面」手动诊断工具
--
--  背景：活化工具台在红石端口【正下方】时正常；端口放【边上/上方】时
--  会连挥两下。怀疑是 main.lua 的「六面全写」导致。
--  本工具让你：
--    1) 先选【哪个红石 I/O 端口】（农场号 / 端口编号 / 完整地址）
--    2) 再选【只写哪一个面】发脉冲；也能「六面全写」做对照
--  你盯着游戏里的工具台数挥了几下，就能判断到底是不是六面输出的锅。
--
--  OC 的 side 编号（setOutput 的第二参数，世界方向，与方块朝向无关）：
--    0 = bottom(下)   1 = top(上)
--    2 = north(北)    3 = south(南)
--    4 = west(西)     5 = east(东)
--  哪个面贴着工具台不确定？用 scan 依次试。
--
--  用法（在 OC 电脑里）：
--    lua pulse_side.lua                    交互式（先列端口，再选面）
--    lua pulse_side.lua status             只列农场 ↔ 红石端口对照
--    lua pulse_side.lua farm 3             选农场3 的端口，进交互菜单
--    lua pulse_side.lua 2                  选端口列表第 2 个，进交互菜单
--    lua pulse_side.lua <地址>             直接给完整端口地址
--    lua pulse_side.lua farm 3 2           对农场3 端口第 2 面发 1 次
--    lua pulse_side.lua farm 3 all         六面全写 1 次（对照组）
--    lua pulse_side.lua farm 3 scan        逐面 0~5 各发 1 次（间隔 3 秒）
--    lua pulse_side.lua farm 3 cmp 2       对照：单写第 2 面 vs 六面全写
--    可再跟 [宽度] [次数]，如：lua pulse_side.lua farm 3 2 0.05 3
-- ============================================================
local component = require("component")

local SIDE_NAMES = {
  [0] = "bottom(下)", [1] = "top(上)",
  [2] = "north(北)",  [3] = "south(南)",
  [4] = "west(西)",   [5] = "east(东)",
}
local NAME_TO_SIDE = {
  bottom = 0, down = 0, ["下"] = 0,
  top = 1, up = 1, ["上"] = 1,
  north = 2, n = 2, ["北"] = 2,
  south = 3, s = 3, ["南"] = 3,
  west = 4, w = 4, ["西"] = 4,
  east = 5, e = 5, ["东"] = 5,
}

local WIDTH = 0.05     -- 默认 1 tick；命令行可覆盖
local TIMES = 1        -- 连续发几次
local GAP = 2.0        -- 两次测试之间的间隔（防止工具台被"短间隔双击"重置）

-- ---------------- 基础 ----------------
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

local function list_type(t)
  local out = {}
  for a, ty in component.list(t, true) do
    if ty == t then out[#out + 1] = a end
  end
  return out
end

local function realsec()
  local ok, v = pcall(function() return computer.realTime() end)
  if ok and tonumber(v) then return tonumber(v) end
  return os.time()
end

-- 读数据文件（binds.dat），返回表或 nil
local function load_data(...)
  for _, path in ipairs({ ... }) do
    local f = io.open(path, "rb")
    if f then
      local raw = f:read("*a")
      f:close()
      if raw and raw ~= "" then
        local ok, t = pcall(function() return load("return " .. raw, "fd", "t")() end)
        if ok and type(t) == "table" then return t end
      end
    end
  end
  return nil
end

-- 遍历 binds 里的农场（兼容数组和 id 键两种结构）
local function each_farm(t, fn)
  if type(t) ~= "table" or type(t.farms) ~= "table" then return end
  for k, v in pairs(t.farms) do
    if type(v) == "table" then
      local id = tonumber(v.id) or tonumber(k) or tostring(k)
      fn(id, v)
    end
  end
end

-- ---------------- 端口与农场 ----------------
local reds = list_type("redstone")
local BINDS = load_data("/home/ocfarm/binds.dat", "binds.dat", "../binds.dat", "ocfarm/binds.dat")

local farm_of_red = {}
if BINDS then
  each_farm(BINDS, function(id, b)
    if b.redstone then farm_of_red[b.redstone] = id end
  end)
end

local function print_ports()
  print("红石 I/O 端口（component.list('redstone')）：")
  if #reds == 0 then
    print("  （一个都没有：先给活化工具台旁边贴一个红石 I/O）")
    return
  end
  for i, a in ipairs(reds) do
    local fid = farm_of_red[a]
    print(string.format("  %2d) %s%s", i, a, fid and ("   ← 农场" .. tostring(fid)) or ""))
  end
  if BINDS then
    print("binds.dat 里的农场：")
    each_farm(BINDS, function(id, b)
      local state = "不在当前网络"
      for _, a in ipairs(reds) do
        if a == b.redstone then state = "端口在" break end
      end
      print(string.format("   农场%-3s redstone=%s（%s）", tostring(id), tostring(b.redstone), state))
    end)
  end
end

-- 按 农场号 / 端口编号 / 地址 解析出端口地址
local function resolve_port(arg)
  if not arg or arg == "" then return nil end
  for _, a in ipairs(reds) do
    if a == arg then return a end
  end
  -- 农场号
  if BINDS then
    local hit
    each_farm(BINDS, function(id, b)
      if tostring(id) == tostring(arg) and b.redstone then hit = b.redstone end
    end)
    if hit then
      for _, a in ipairs(reds) do
        if a == hit then return a end
      end
      return nil, "农场" .. tostring(arg) .. " 的红石端口 " .. tostring(hit) .. " 不在当前网络里（拆装了？先 lua bind.lua 重绑）"
    end
  end
  -- 端口列表编号
  local n = tonumber(arg)
  if n and n >= 1 and n <= #reds then return reds[n] end
  return nil, "找不到这个端口/农场： " .. tostring(arg)
end

-- ---------------- 工具台观测（尽力而为） ----------------
local function tablet_addr()
  local t = list_type("tt_animationTablet")
  return t[1]
end

local function left_click()
  local a = tablet_addr()
  if not a then return nil end
  local ok, r = invoke(a, "getLeftClick")
  if ok then return tonumber(r) end
  return nil
end

local function tablet_state()
  local a = tablet_addr()
  if not a then return "（网络里没有可读的活化工具台组件，挥几下靠你肉眼看）" end
  local ok1, rs = invoke(a, "getRedstone")
  local ok2, lc = invoke(a, "getLeftClick")
  local ok3, lk = invoke(a, "getLeftClickLock")
  return string.format("redstone=%s leftClick=%s", ok1 and tostring(rs) or "ERR", ok2 and tostring(lc) or "ERR")
end

-- ---------------- 脉冲 ----------------
local last_pulse_u = {}   -- [addr] = 上次脉冲结束时刻

local function wait_gap(addr)
  local g = realsec() - (last_pulse_u[addr] or 0)
  if g < GAP then os.sleep(GAP - g) end
end

-- 只写一个面
local function pulse_one(addr, side, width)
  invoke(addr, "setOutput", side, 0)
  invoke(addr, "setOutput", side, 15)
  os.sleep(width)
  local ok, err = invoke(addr, "setOutput", side, 0)
  last_pulse_u[addr] = realsec()
  return ok, err
end

-- 六面全写（对照组 = main.lua 现在的实际行为）
local function pulse_all(addr, width)
  local errs = {}
  for s = 0, 5 do
    local ok, err = invoke(addr, "setOutput", s, 0)
    if not ok then errs[#errs + 1] = string.format("面%d:%s", s, tostring(err)) end
  end
  for s = 0, 5 do invoke(addr, "setOutput", s, 15) end
  os.sleep(width)
  for s = 0, 5 do
    local ok, err = invoke(addr, "setOutput", s, 0)
    if not ok then errs[#errs + 1] = string.format("面%d:%s", s, tostring(err)) end
  end
  last_pulse_u[addr] = realsec()
  return errs
end

-- 一次测试（可连续 times 次），并打印工具台计数差
local function run_test(addr, face, width, times)
  local label
  if face == "all" then
    label = "六面全写"
  elseif type(face) == "number" then
    label = string.format("只写第 %d 面（%s）", face, SIDE_NAMES[face] or "?")
  else
    label = tostring(face)
  end
  print(string.format("→ %s × %d 次，宽度 %.2f 秒，端口 %s", label, times, width, tostring(addr)))
  local before = left_click()
  local errs = {}
  for i = 1, times do
    if i > 1 then os.sleep(GAP) end
    if face == "all" then
      for _, e in ipairs(pulse_all(addr, width)) do errs[#errs + 1] = e end
    else
      local ok, err = pulse_one(addr, face, width)
      if not ok then errs[#errs + 1] = tostring(err) end
    end
  end
  if #errs > 0 then print("  [警告] 部分面写失败：" .. table.concat(errs, "; ")) end
  os.sleep(0.6)
  local after = left_click()
  if before and after then
    local d = after - before
    local hint = "?"
    if d > times then hint = string.format("%+d  ← 比脉冲次数多！疑似连挥", d)
    elseif d == times then hint = string.format("+%d（脉冲几次挥几次，正常）", d)
    else hint = string.format("%+d", d) end
    print(string.format("  leftClick: %s -> %s（%s）", tostring(before), tostring(after), hint))
  end
  print("  请同时用肉眼看游戏里：工具台挥了几下？")
end

-- 逐面扫描
local function run_scan(addr, width)
  print("依次对 6 个面各发一次脉冲，每面间隔 3 秒，请盯紧工具台：")
  for s = 0, 5 do
    local before = left_click()
    print(string.format("[面 %d %s] 发脉冲…", s, SIDE_NAMES[s] or "?"))
    pulse_one(addr, s, width)
    os.sleep(3)
    local after = left_click()
    if before and after then
      local d = after - before
      local hint = (d > 1) and string.format("%+d  ← 挥了不止一下！", d) or string.format("%+d", d)
      print(string.format("  leftClick: %s -> %s（%s）", tostring(before), tostring(after), hint))
    end
  end
  print("scan 完成。重点记：哪个面能触发工具台、触发时挥了几下。")
end

-- 单面 vs 六面 对照
local function run_cmp(addr, side, width)
  print("== 对照测试：同一个面，单面 vs 六面 ==")
  print("第一组：只写第 " .. side .. " 面（" .. (SIDE_NAMES[side] or "?") .. "）")
  run_test(addr, side, width, 1)
  print("（等 2 秒）")
  os.sleep(GAP)
  print("第二组：六面全写")
  run_test(addr, "all", width, 1)
  print("两组对比：如果六面全写挥两下、单面只挥一下，就是六面输出的问题。")
end

-- ---------------- 交互菜单 ----------------
local function menu(addr)
  while true do
    print("")
    print("==== 红石输出面诊断（端口 " .. tostring(addr) .. "） ====")
    print("工具台：" .. tablet_state())
    print("  0~5  只对该面发一次脉冲   all  六面全写一次")
    print("  scan 逐面 0~5 各一次       cmp <面>  单面 vs 六面 对照")
    print("  t    修改脉冲宽度/次数     s    刷新   q    退出")
    io.write("> ")
    local line = io.read("*l")
    if not line then return end
    line = tostring(line):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if line == "q" or line == "quit" then
      return
    elseif line == "s" then
      -- 只刷新，循环开头会重印
    elseif line == "all" then
      run_test(addr, "all", WIDTH, TIMES)
    elseif line == "scan" then
      run_scan(addr, WIDTH)
    elseif line:sub(1, 3) == "cmp" then
      local s = tonumber(line:match("cmp%s+(%d)")) or tonumber(line:match("cmp (%S+)"))
      if s and s >= 0 and s <= 5 then
        run_cmp(addr, s, WIDTH)
      else
        print("用法：cmp <面0..5>，例如 cmp 2")
      end
    elseif line == "t" then
      io.write("默认脉冲宽度（秒，0.05~0.5，回车不改）：")
      local w = io.read("*l")
      w = w and tonumber(w)
      if w and w >= 0.05 and w <= 0.5 then WIDTH = w end
      io.write("每次连发次数（1~20，回车不改）：")
      local n = io.read("*l")
      n = n and tonumber(n)
      if n and n >= 1 and n <= 20 then TIMES = math.floor(n) end
      print(string.format("当前：宽度 %.2f 秒，次数 %d", WIDTH, TIMES))
    else
      local s = tonumber(line)
      if s and s >= 0 and s <= 5 then
        run_test(addr, math.floor(s), WIDTH, TIMES)
      else
        print("[提示] 看不懂，输入 0~5 / all / scan / cmp <面> / t / s / q")
      end
    end
  end
end

-- ---------------- 命令行入口 ----------------
local args = {}
for i = 1, select("#", ...) do args[#args + 1] = select(i, ...) end
if #args == 0 and type(arg) == "table" then
  for _, v in pairs(arg) do
    if type(v) == "string" then args[#args + 1] = v end
  end
end

local cmd = (args[1] and tostring(args[1]) or ""):lower()

if cmd == "status" or cmd == "s" then
  print_ports()
  return
end

local function parse_side_arg(v)
  if v == nil then return nil end
  local n = tonumber(v)
  if n and n >= 0 and n <= 5 then return math.floor(n) end
  return NAME_TO_SIDE[tostring(v):lower()]
end

-- 解析 [宽度] [次数] 尾巴
local function take_tail(rest, width, times)
  local i = 1
  local w = tonumber(rest[i])
  if w and w >= 0.05 and w <= 0.5 then width = w; i = i + 1 end
  local n = tonumber(rest[i])
  if n and n >= 1 and n <= 20 then times = math.floor(n) end
  return width, times
end

-- 参数结构：
--   farm <id> [face|all|scan|cmp <face>] [width] [times]
--   <port|idx|addr> [face|all|scan|cmp <face>] [width] [times]
local port_arg, rest = nil, {}
if cmd == "farm" then
  port_arg = args[2]
  for i = 3, #args do rest[#rest + 1] = args[i] end
elseif cmd == "port" then
  port_arg = args[2]
  for i = 3, #args do rest[#rest + 1] = args[i] end
else
  port_arg = args[1]
  for i = 2, #args do rest[#rest + 1] = args[i] end
end

local addr, perr = nil, nil
if #reds == 0 then
  print("[错误] 没找到红石 I/O 端口。请先给活化工具台旁边贴一个红石 I/O。")
  return
end

if port_arg == nil or port_arg == "" then
  if #reds == 1 then
    addr = reds[1]
    print("只找到 1 个红石端口，直接使用：" .. addr)
  else
    print_ports()
    io.write("输入端口编号 / 农场号 / 完整地址（直接回车用第 1 个）：")
    local line = io.read("*l")
    line = line and tostring(line):gsub("^%s+", ""):gsub("%s+$", "")
    if not line or line == "" then
      addr = reds[1]
    else
      addr, perr = resolve_port(line)
    end
  end
else
  addr, perr = resolve_port(port_arg)
end

if not addr then
  print("[错误] " .. tostring(perr or "端口解析失败"))
  print_ports()
  return
end

if #rest == 0 then
  menu(addr)
  return
end

local face = nil
local i = 1
local f = (rest[1] and tostring(rest[1]) or ""):lower()
if f == "all" or f == "scan" then
  face = f
  i = 2
elseif f == "cmp" then
  face = "cmp:" .. tostring(rest[2] or "?")
  i = 3
else
  face = parse_side_arg(rest[1])
  if face == nil then
    print("[提示] 看不懂的面 \"" .. tostring(rest[1]) .. "\"，进交互菜单。")
    menu(addr)
    return
  end
  i = 2
end

local rest2 = {}
for j = i, #rest do rest2[#rest2 + 1] = rest[j] end
local width, times = take_tail(rest2, WIDTH, TIMES)

if face == "scan" then
  run_scan(addr, width)
elseif face == "all" then
  run_test(addr, "all", width, times)
elseif type(face) == "string" and face:sub(1, 4) == "cmp:" then
  local s = parse_side_arg(face:sub(5))
  if s then run_cmp(addr, s, width) else print("[提示] cmp 需要面编号，如 cmp 2") end
else
  run_test(addr, face, width, times)
end
