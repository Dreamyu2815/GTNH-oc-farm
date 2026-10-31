-- ============================================================
--  绑定向导：把「适配器(gt_machine) + 红石端口 + 发配接口」绑成一台农场
--
--  用法：
--    lua bind.lua             全量绑定（已绑定的跳过，未绑定的从前往后问）
--    lua bind.lua fix <id>    只重绑第 <id> 台（id 是排序后的编号）
--    lua bind.lua show        只看当前绑定，不操作
--
--  键盘（只在"等你拔插端口"的时候有效）：
--    双击 u   撤销上一台，重新绑它
--    双击 s   跳过这台（最后会统一再问一次）
--    双击 r   全部重来（清空所有绑定）
--    按一次 q 保存并退出整个程序
--
--  绑定结果存 /home/ocfarm/binds.dat，主程序后面读它来认农场。
-- ============================================================
local ROOT = "/home/ocfarm"
local BINDS = ROOT .. "/binds.dat"

local function loadmod(name)
  local path = ROOT .. "/lib/" .. name .. ".lua"
  local f = io.open(path, "r")
  if not f then error("缺少模块: " .. path) end
  f:close()
  return dofile(path)
end

local component = require("component")
local computer = require("computer")

local cfg = dofile(ROOT .. "/config.lua")
local util = loadmod("util")
local farmio = loadmod("farmio")
local patmod = loadmod("pat")

local F = farmio.new({})
local PAT = patmod.new(cfg)

-- 取命令行参数：OpenOS 的 lua 把参数放在 chunk 的 varargs（...）里，
-- 全局 arg 有时是 nil 或把脚本名放在 arg[1]，所以两路都收，
-- 再"按关键词扫描"，不依赖参数位置。
-- 注意：必须在顶层用 ... 调用（函数体内的 ... 是它自己的可变参）
local function collect_args(...)
  local t = {}
  local n = select("#", ...)
  for i = 1, n do t[#t + 1] = select(i, ...) end
  if #t == 0 and type(arg) == "table" then
    for _, v in pairs(arg) do
      if type(v) == "string" then t[#t + 1] = v end
    end
  end
  return t
end

local ARGS = collect_args(...)
local MODE = "all"
local FIX_ID = nil
for _, a in ipairs(ARGS) do
  local s = tostring(a)
  if s == "show" or s == "coords" or s == "fix" or s == "all" or s == "clear" then
    MODE = s
  end
end
if MODE == "fix" or MODE == "clear" then
  for _, a in ipairs(ARGS) do
    local n = tonumber(a)
    if n then FIX_ID = n end
  end
end

local function say(fmt, ...)
  local args = table.pack(...)
  for i = 1, args.n do
    local v = args[i]
    if type(v) == "number" and math.type(v) == "float" and v == math.floor(v) then
      args[i] = math.floor(v)
    end
  end
  local ok, s = pcall(string.format, fmt, table.unpack(args, 1, args.n))
  if not ok then
    local parts = {}
    for i = 1, args.n do parts[#parts + 1] = tostring(args[i]) end
    s = fmt .. "  <" .. table.concat(parts, ", ") .. ">"
  end
  print(s)
end

-- ============ 枚举农场 ============
-- getCoordinates 在这版里是“多返回值”（x, y, z[, dimension] 分开给），
-- 普通 pcall 只接得到第一个数，所以这里把所有返回值都收下来。
local function call_all(addr, method, ...)
  local okp, proxy = pcall(component.proxy, addr)
  if okp and proxy then
    local f = proxy[method]
    if f ~= nil then
      local r = table.pack(pcall(f, ...))
      if r[1] then
        local out = {}
        for i = 2, r.n do out[#out + 1] = r[i] end
        return true, out
      end
    end
  end
  local r = table.pack(pcall(component.invoke, addr, method, ...))
  if r[1] then
    local out = {}
    for i = 2, r.n do out[#out + 1] = r[i] end
    return true, out
  end
  return false, tostring(r[2])
end

local function coords_of(gt)
  local ok, vals = call_all(gt, "getCoordinates")
  if not ok then return nil, "调用失败：" .. tostring(vals) end
  if type(vals) ~= "table" then return nil, "返回类型奇怪：" .. tostring(vals) end

  -- 情况 1：多个数字（x, y, z[, dim]）
  if #vals >= 3 and type(vals[1]) == "number" and type(vals[2]) == "number" and type(vals[3]) == "number" then
    return { x = tonumber(vals[1]), y = tonumber(vals[2]), z = tonumber(vals[3]), dimension = tonumber(vals[4]) or 0 }
  end

  -- 情况 2：一个表 {x,y,z} / {x=,y=,z=}
  local t = vals[1]
  if type(t) == "table" then
    local x = t.x or t[1]
    local y = t.y or t[2]
    local z = t.z or t[3]
    local dim = t.dimension or t.dimId or t[4]
    if x ~= nil and y ~= nil and z ~= nil then
      return { x = tonumber(x), y = tonumber(y), z = tonumber(z), dimension = tonumber(dim) or 0 }
    end
    return nil, "表里没有 x/y/z：" .. tostring(t)
  end

  -- 情况 3：一个字符串 "98, 64, -43"
  if type(t) == "string" then
    local a, b, c = t:match("(%-?%d+)[, ]+%s*(%-?%d+)[, ]+%s*(%-?%d+)")
    if a then
      return { x = tonumber(a), y = tonumber(b), z = tonumber(c), dimension = 0 }
    end
  end

  local parts = {}
  for i = 1, math.min(#vals, 6) do parts[#parts + 1] = tostring(vals[i]) end
  return nil, "返回值看不懂：共 " .. tostring(#vals) .. " 个 -> " .. table.concat(parts, ", ")
end

local function list_gt()
  local out = {}
  for addr, ty in component.list("gt_machine", true) do
    if ty == "gt_machine" then out[#out + 1] = addr end
  end
  return out
end

local function dist(a, b)
  return math.abs((a.x or 0) - (b.x or 0))
    + math.abs((a.y or 0) - (b.y or 0))
    + math.abs((a.z or 0) - (b.z or 0))
end

local function match_iface(fc)
  local best, bestD = nil, math.huge
  for _, e in ipairs(PAT:ifaces()) do
    local l = e.location
    if type(l) == "table" then
      local d = dist(fc, { x = l.x, y = l.y, z = l.z })
      if d < bestD then best, bestD = e, d end
    end
  end
  return best, bestD
end

local function discover()
  local farms = {}
  for _, gt in ipairs(list_gt()) do
    local c, cerr = coords_of(gt)
    if c then
      local ie, id = match_iface(c)
      farms[#farms + 1] = {
        gt = gt, x = c.x, y = c.y, z = c.z, dimension = c.dimension,
        iface = ie, iface_dist = id,
      }
    else
      say("[警告] 适配器 %s 读不到坐标：%s，跳过", tostring(gt), tostring(cerr))
    end
  end
  table.sort(farms, function(a, b)
    if a.x ~= b.x then return a.x < b.x end
    if a.z ~= b.z then return a.z < b.z end
    return a.y < b.y
  end)
  return farms
end

local function iface_name(ie)
  if not ie then return "(无)" end
  local n = ie.name
  if n == nil or n == "Nothing" or n == "" then return "(未命名)" end
  return tostring(n)
end

local function iface_loc(ie)
  if not ie or type(ie.location) ~= "table" then return "(无)" end
  return string.format("(%s,%s,%s)", tostring(ie.location.x), tostring(ie.location.y), tostring(ie.location.z))
end

-- ============ 键盘：双击判定 + q 退出 ============
local function key_char(a, b, c)
  local ch = b
  if ch == nil then ch = a end
  if type(ch) == "number" and ch >= 32 and ch <= 126 then return string.char(ch):lower() end
  if type(ch) == "string" then return ch:sub(1, 1):lower() end
  return nil
end

local last_key, last_key_u = nil, 0
local function double_press(ch)
  local u = computer.uptime()
  if ch and ch == last_key and (u - last_key_u) < 0.8 then
    last_key, last_key_u = nil, 0
    return true
  end
  last_key, last_key_u = ch, u
  return false
end

-- ============ 绑定状态（提前声明，wait_redstone 里要用） ============
local binds, save_binds, find_bind_by_gt, find_bind_by_redstone

-- ============ 等待一次"拔下又插回" ============
-- 注意：OC 里拆掉方块会销毁它的方块实体，装回去就是一个【新地址】，
-- 所以不能要求"拔下来和插回去是同一个地址"——那永远不成立。
-- 两条判据：A. component_added/removed 事件（参数是 地址, 类型）
--           B. 每 0.25 秒轮询 redstone 端口集合，比对差异
-- 返回：("bind", addr) / ("undo") / ("skip") / ("restart") / ("save") / ("quit")
local function redstone_addrs()
  local t = {}
  for a, ty in component.list("redstone", true) do
    if ty == "redstone" then t[#t + 1] = a end
  end
  return t
end

local function addr_set(list)
  local s = {}
  for _, a in ipairs(list) do s[a] = true end
  return s
end

-- 把信号队列里残留的事件吃干净。上一台绑定成功时留下的 component_added
-- 如果不清掉，会被下一台立刻当成"刚装上的端口"抢走（实际踩过这个坑）。
local function flush_signals()
  for _ = 1, 500 do
    local s = computer.pullSignal(0)
    if s == nil then break end
  end
end

local function show_manual(list)
  print("  ---- 当前网络里的红石 I/O 端口 ----")
  for k, a in ipairs(list) do
    local who = find_bind_by_redstone(a)
    local tag = ""
    if who then
      tag = string.format("   (已绑给 #%s)", tostring(who.id))
    else
      tag = "   (未绑定)"
    end
    print(string.format("   %d) %s%s", k, tostring(a), tag))
  end
  print("  按数字选一个绑给这台；再按 m 刷新列表")
end

local function wait_redstone(label)
  flush_signals()
  local prev = addr_set(redstone_addrs())
  local manual = nil   -- 手动模式下的候选列表
  print("")
  print("==========================================")
  print("现在绑定「" .. label .. "」的红石端口：")
  print("  · 已经插着的：把【红石 I/O 端口】拆下来，再装回去（贴在活化工具台上的那个方块）")
  print("  · 还没插的：直接装到活化工具台旁边")
  print("  · 只认 redstone 端口的插拔，拆 ME 接口/线缆不会触发")
  print("  ---- 按键 ----")
  print("   单按 m  = 列出当前所有红石端口，按数字选一个直接绑（推荐，最稳）")
  print("   双击 u  = 撤销上一台      双击 s = 跳过这台")
  print("   双击 r  = 全部重来        单按 w = 保存并退出")
  print("   双击 q  = 直接退出程序")
  print("==========================================")
  while true do
    local sig = table.pack(computer.pullSignal(0.25))
    local name = sig[1]

    if name == "key_down" then
      local ch = key_char(sig[2], sig[3], sig[4])
      if manual and ch and ch:match("^%d$") then
        local idx = tonumber(ch)
        if idx and idx >= 1 and idx <= #manual then
          local pick = manual[idx]
          local who = find_bind_by_redstone(pick)
          if who then
            print(string.format("  [提示] 这个端口已经绑给 #%s 了，换一个（按 m 刷新列表）", tostring(who.id)))
          else
            return "bind", pick
          end
        else
          print("  [提示] 没有这个编号，按 m 重新看列表")
        end
      elseif ch == "m" then
        manual = redstone_addrs()
        if #manual == 0 then
          print("  [手动] 当前网络里一个红石端口都没有。先把 I/O 端口装上，再按 m。")
          manual = nil
        else
          show_manual(manual)
        end
      elseif ch == "w" then
        return "save"
      elseif ch == "q" then
        if double_press("q") then return "quit" end
      elseif ch == "u" and double_press("u") then
        return "undo"
      elseif ch == "s" and double_press("s") then
        return "skip"
      elseif ch == "r" and double_press("r") then
        return "restart"
      end

    -- 事件路径（OC 的事件参数是：地址, 类型）
    elseif name == "component_removed" and sig[3] == "redstone" then
      print("  · 检测到端口被拆下：" .. tostring(sig[2]))
    elseif name == "component_added" and sig[3] == "redstone" then
      local addr = sig[2]
      if prev[addr] then
        print("  · 忽略一条旧事件（这个端口本来就在：" .. tostring(addr) .. "）")
      else
        local who = find_bind_by_redstone(addr)
        if who then
          print(string.format("  · 这个端口已经绑给 #%s，忽略。请给这台装一个新端口。", tostring(who.id)))
          prev[addr] = true
        else
          print("  · 检测到端口装上：" .. tostring(addr))
          return "bind", addr
        end
      end
    elseif name == "interrupted" then
      return "quit"
    end

    -- 轮询兜底：集合里多出一个就说明装了新端口
    local cur = addr_set(redstone_addrs())
    local added = nil
    for a in pairs(cur) do if not prev[a] then added = a end end
    if added then
      local who = find_bind_by_redstone(added)
      if who then
        print(string.format("  · 这个端口已经绑给 #%s，忽略。请给这台装一个新端口。", tostring(who.id)))
        prev = cur
      else
        print("  · 轮询发现端口装上：" .. tostring(added))
        return "bind", added
      end
    else
      prev = cur
    end
  end
end

-- ============ 主流程 ============
binds = util.load(BINDS, { seq = 0, farms = {} })
if type(binds.farms) ~= "table" then binds.farms = {} end

function save_binds()
  binds.seq = #binds.farms
  util.save(BINDS, binds)
end

function find_bind_by_gt(gt)
  for k, f in ipairs(binds.farms) do
    if f.gt == gt then return k, f end
  end
  return nil
end

function find_bind_by_redstone(redstone)
  for _, f in ipairs(binds.farms) do
    if f.redstone == redstone then return f end
  end
  return nil
end

if MODE == "show" then
  say("已绑定农场数：%d", binds.seq or 0)
  for i, f in ipairs(binds.farms) do
    say("  #%d gt=%s redstone=%s 接口=%s", i, tostring(f.gt), tostring(f.redstone), tostring(f.iface_name))
  end
  return
end

-- 清除绑定：lua bind.lua clear      全部清空
--           lua bind.lua clear 2    只清 #2
if MODE == "clear" then
  local n = #binds.farms
  if FIX_ID then
    local rec = binds.farms[FIX_ID]
    if not rec then
      say("[清除] 没有 #%d 这条绑定（当前共 %d 条）。用 lua bind.lua show 看现有绑定。", FIX_ID, n)
      return
    end
    say("[清除] 删除 #%d：控制器(%s,%s,%s) 红石 %s", FIX_ID,
      tostring(rec.x), tostring(rec.y), tostring(rec.z), tostring(rec.redstone))
    table.remove(binds.farms, FIX_ID)
    save_binds()
    say("[清除] 已删除，剩余 %d 条。", #binds.farms)
  else
    if n == 0 then
      say("[清除] 当前本来就没有绑定。")
      return
    end
    say("[清除] 将清空全部 %d 条绑定：", n)
    for i, f in ipairs(binds.farms) do
      say("  #%d 控制器(%s,%s,%s) 红石 %s", i, tostring(f.x), tostring(f.y), tostring(f.z), tostring(f.redstone))
    end
    -- 需要确认：按 y 确认，其它任意键取消，10 秒无输入自动取消
    say("确认清空请按 y，其它任意键取消（10 秒后自动取消）")
    local t0 = computer.uptime()
    local confirmed = false
    while computer.uptime() - t0 < 10 do
      local s = table.pack(computer.pullSignal(1))
      if s[1] == "key_down" then
        local ch = key_char(s[2], s[3], s[4])
        if ch == "y" then confirmed = true end
        break
      end
    end
    if not confirmed then
      say("[取消] 没有清空，绑定保持不变。")
      return
    end
    binds.farms = {}
    save_binds()
    say("[清除] 已清空全部绑定。现在可以重新跑 lua bind.lua 从头绑。")
  end
  return
end

-- 调试：把每个 gt_machine 的 getCoordinates 原始返回值全打印出来
if MODE == "coords" then
  for _, gt in ipairs(list_gt()) do
    local ok, vals = call_all(gt, "getCoordinates")
    if ok and type(vals) == "table" then
      local parts = {}
      for k = 1, #vals do parts[#parts + 1] = tostring(vals[k]) end
      say("%s -> %d 个值: %s", tostring(gt), #vals, table.concat(parts, " | "))
    else
      say("%s -> 失败: %s", tostring(gt), tostring(vals))
    end
    local c, err = coords_of(gt)
    if c then
      say("    解析成 (x=%s, y=%s, z=%s, dim=%s)", tostring(c.x), tostring(c.y), tostring(c.z), tostring(c.dimension))
    else
      say("    解析失败: %s", tostring(err))
    end
  end
  return
end

local farms = discover()
say("发现 %d 台农场（按坐标排序）：", #farms)
for i, f in ipairs(farms) do
  say("  #%d 控制器(%s,%s,%s) 发配接口 %s %s", i, tostring(f.x), tostring(f.y), tostring(f.z), iface_name(f.iface), iface_loc(f.iface))
end
if #farms == 0 then
  say("[错误] 没找到任何 gt_machine（农场适配器）。先确认每台农场控制器上都贴了适配器。")
  return
end

local i = 1
local skipped = {}
while i <= #farms do
  local f = farms[i]
  local label = string.format("#%d 控制器(%s,%s,%s) 接口 %s",
    i, tostring(f.x), tostring(f.y), tostring(f.z), iface_name(f.iface))

  local k, existing = find_bind_by_gt(f.gt)
  local need_rebind = (MODE == "fix" and i == FIX_ID)
  if existing and not need_rebind then
    say("[跳过] %s 已绑定（红石 %s）", label, tostring(existing.redstone))
    i = i + 1
  else
    local act, val = wait_redstone(label)
    if act == "quit" then
      save_binds()
      say("[退出] 收到双击 q，已保存后直接退出程序。未绑定的农场下次继续。")
      return
    elseif act == "save" then
      save_binds()
      say("[保存] 已保存，退出绑定向导。未绑定的农场下次继续。")
      return
    elseif act == "undo" then
      -- 撤销上一台：删掉上一台的绑定，回退到它
      if k then table.remove(binds.farms, k) end
      if i > 1 then
        i = i - 1
        local pk, pf = find_bind_by_gt(farms[i].gt)
        if pk then table.remove(binds.farms, pk) end
        say("[撤销] 回到 #%d 重新绑", i)
      else
        say("[提示] 已经是最前面一台，没有可撤销的")
      end
    elseif act == "skip" then
      skipped[#skipped + 1] = i
      say("[跳过] #%d 先跳过，最后再问", i)
      i = i + 1
    elseif act == "restart" then
      binds.farms = {}
      skipped = {}
      say("[重来] 已清空所有绑定，从 #1 开始")
      i = 1
    elseif act == "bind" then
      local dup = find_bind_by_redstone(val)
      if dup and dup.gt ~= f.gt then
        say("[错误] 这个端口已经绑给其它农场了（gt %s）。请换一个端口，或双击 u 撤销。", tostring(dup.gt))
      else
        local loc = f.iface and f.iface.location
        local rec = {
          id = i,
          gt = f.gt,
          x = f.x, y = f.y, z = f.z, dimension = f.dimension,
          redstone = val,
          iface_name = iface_name(f.iface),
          iface = (loc and type(loc) == "table") and {
            x = loc.x, y = loc.y, z = loc.z, dimension = loc.dimId or loc.dimension or 0
          } or nil,
        }
        if k then binds.farms[k] = rec else binds.farms[#binds.farms + 1] = rec end
        save_binds()
        say("[绑定] %s -> 红石端口 %s", label, tostring(val))
        i = i + 1
      end
    end
  end
end

-- 收尾：处理被跳过的农场
while #skipped > 0 do
  local idx = table.remove(skipped, 1)
  local f = farms[idx]
  local label = string.format("#%d 控制器(%s,%s,%s) 接口 %s",
    idx, tostring(f.x), tostring(f.y), tostring(f.z), iface_name(f.iface))
  local k = find_bind_by_gt(f.gt)
  if k then
    say("[跳过] %s 已绑定", label)
  else
    local act, val = wait_redstone(label .. "（之前跳过）")
    if act == "quit" then save_binds(); say("[退出] 收到双击 q，已保存后直接退出。"); return
    elseif act == "save" then save_binds(); say("[保存] 已保存，退出绑定向导。"); return
    elseif act == "bind" then
      local loc = f.iface and f.iface.location
      local rec = {
        id = idx, gt = f.gt, x = f.x, y = f.y, z = f.z, dimension = f.dimension,
        redstone = val, iface_name = iface_name(f.iface),
        iface = (loc and type(loc) == "table") and { x = loc.x, y = loc.y, z = loc.z, dimension = loc.dimId or loc.dimension or 0 } or nil,
      }
      binds.farms[#binds.farms + 1] = rec
      save_binds()
      say("[绑定] %s -> 红石端口 %s", label, tostring(val))
    end
  end
end

save_binds()
say("")
say("========== 绑定完成 ==========")
say("共绑定 %d 台农场：", #binds.farms)
for i, f in ipairs(binds.farms) do
  say("  #%d gt=%s redstone=%s 接口=%s", i, tostring(f.gt), tostring(f.redstone), tostring(f.iface_name))
end
say("下一步：跑 lua verify.lua 实测每台的红石端口（发一批种子、脉冲、看 hasWork）。")
