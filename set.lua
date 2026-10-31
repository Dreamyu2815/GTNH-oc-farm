-- 设置作物阈值（产物 low/high）和苗床需求，运行时生效
-- OC 里打不了中文，所以全部用「编号」操作：
--   lua set.lua              交互式：列出作物编号 → 选编号 → 填数值
--   lua set.lua 2            直接编辑 2 号作物（同交互菜单）
--   lua set.lua 2 128 512    直接按编号设 low/high
--   lua set.lua bed 2 5      按编号设苗床需求（0=无要求）
--   lua set.lua del 2        删除 2 号的覆盖（回 config.lua 默认）
--   lua set.lua list         只列出，不改
--   lua set.lua side 2 4     把 2 号农场的红石端口绑到西面（0=下 1=上 2=北 3=南 4=西 5=东）
-- 说明：写入 /home/ocfarm/limits.dat；main.lua 每个轮询周期自动重读，无需重启。
-- 防呆：改之前建议先跑 lua backup.lua 存个快照（改坏能回退）；全部命令见 lua help.lua。
local ROOT = "/home/ocfarm"
local util = dofile(ROOT .. "/lib/util.lua")
local FILE = ROOT .. "/limits.dat"
local cf = dofile(ROOT .. "/config.lua")

-- 收参数（chunk varargs + 全局 arg）
local args = {}
do
  local n = select("#", ...)
  for i = 1, n do args[#args + 1] = tostring(select(i, ...)) end
  if #args == 0 and type(arg) == "table" then
    for _, v in pairs(arg) do if type(v) == "string" then args[#args + 1] = v end end
  end
end

local t = util.load(FILE, nil)
if type(t) ~= "table" then t = {} end
t.t = t.t or {}
t.seq = tonumber(t.seq) or 0

-- ===== 作物列表：priority 顺序在前，其余 crops 补在后 =====
local list, seen = {}, {}
local function add_crop(c)
  if c and not seen[c] then seen[c] = true; list[#list + 1] = c end
end
for _, layer in ipairs(cf.priority or {}) do
  for _, c in ipairs(layer) do add_crop(c) end
end
if type(cf.crops) == "table" then
  local rest = {}
  for c in pairs(cf.crops) do rest[#rest + 1] = c end
  table.sort(rest)
  for _, c in ipairs(rest) do add_crop(c) end
end

-- 种子网络里已有的种子也算作物（主程序 auto_config 认到的可能还没写进 config.lua，
-- 这里直接列出来，默认 low=64/high=512，也能直接改）
local netborn = {}
do
  local okM, aem = pcall(dofile, ROOT .. "/lib/ae.lua")
  if okM and type(aem) == "table" and aem.new then
    local okA, A = pcall(function() return aem.new(cf.ae or {}) end)
    if okA and A then
      local okS, seeds = pcall(function() return A:seeds_by_label("seed") end)
      if okS and type(seeds) == "table" then
        local names = {}
        for crop, d in pairs(seeds) do
          if d and (d.count or 0) > 0 and not seen[crop] then names[#names + 1] = crop end
        end
        table.sort(names)
        for _, c in ipairs(names) do netborn[c] = true; add_crop(c) end
      end
    end
  end
end

local function cur(crop)
  local o = t.t[crop] or {}
  local ci = (cf.crops and cf.crops[crop]) or {}
  local th = (cf.thresholds and cf.thresholds[crop]) or {}
  return {
    low = math.floor(tonumber(o.low or th.low) or 64),
    high = math.floor(tonumber(o.high or th.high) or 512),
    bed = math.floor(tonumber(o.bed or ci.bed) or 0),
    product = th.product or ci.out or crop,
    over = (o.low ~= nil or o.high ~= nil or o.bed ~= nil),
  }
end

local function show_list()
  print("======== 作物阈值设置 ========")
  if #list == 0 then
    print("（没有作物：config.lua 的 priority / crops 是空的）")
    return
  end
  for i, c in ipairs(list) do
    local v = cur(c)
    print(string.format(" %2d) %s  产物=%s  low=%d  high=%d  苗床=%d%s%s",
      i, c, v.product, v.low, v.high, v.bed, v.over and "  *" or "",
      netborn[c] and "  [新种子]" or ""))
  end
  print("-------------------------------")
  print("（* = limits.dat 有覆盖；[新种子] = 种子网里有、config.lua 还没配，可直接改）")
  print("（输 prio 进优先级分层编辑；直接回车退出；命令速查 lua help.lua）")
  print("（改之前建议先 lua backup.lua 存个快照）")
end

local function ask(prompt)
  io.write(prompt)
  io.flush()
  local s = io.read()
  if not s then return nil end
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  return s
end

local function pick_index()
  local s = ask("编号 > ")
  if not s or s == "" then return nil end          -- 回车 = 退出
  local n = tonumber(s)
  if not n or not list[n] then
    print("没有这个编号。")
    return false
  end
  return n
end

local function edit(crop)
  while true do
    local v = cur(crop)
    print(string.format("【%s】产物=%s  low=%d  high=%d  苗床=%d%s",
      crop, v.product, v.low, v.high, v.bed, v.over and "（有覆盖）" or ""))
    print(" 1) 改下限 low（产物低于它才补种）")
    print(" 2) 改上限 high（产物达到它就收割）")
    print(" 3) 改苗床等级 bed（0=无要求）")
    print(" 4) 删除覆盖（回 config.lua 默认）")
    print(" 0) 返回")
    local s = ask("选项 > ")
    if not s or s == "" or s == "0" then return end
    if s == "1" then
      local n = tonumber(ask("新 low（整数）> ") or "")
      if not n or n < 0 or n % 1 ~= 0 then
        print("输入无效（要 ≥0 的整数）。")
      else
        t.t[crop] = t.t[crop] or {}
        t.t[crop].low = math.floor(n)
        local h = cur(crop).high
        if h <= t.t[crop].low then          -- 保证 high > low
          t.t[crop].high = math.floor(t.t[crop].low) + 1
          print(string.format("注意：high 自动调成 %d（必须大于 low）", t.t[crop].high))
        end
        t.seq = t.seq + 1
        util.save(FILE, t)
        print("已保存，main.lua 下个轮询周期生效。")
      end
    elseif s == "2" then
      local n = tonumber(ask("新 high（整数，必须大于 low）> ") or "")
      if not n or n < 0 or n % 1 ~= 0 then
        print("输入无效（要 ≥0 的整数）。")
      elseif n <= cur(crop).low then
        print(string.format("high 必须大于 low(%d)，没改。", cur(crop).low))
      else
        t.t[crop] = t.t[crop] or {}
        t.t[crop].high = math.floor(n)
        t.seq = t.seq + 1
        util.save(FILE, t)
        print("已保存，main.lua 下个轮询周期生效。")
      end
    elseif s == "3" then
      local n = tonumber(ask("新苗床等级（0=无要求，1..12）> ") or "")
      if not n or n < 0 or n > 12 or n % 1 ~= 0 then
        print("输入无效（0..12 的整数；1..12 对应 MV..UXV）。")
      else
        t.t[crop] = t.t[crop] or {}
        t.t[crop].bed = math.floor(n)
        t.seq = t.seq + 1
        util.save(FILE, t)
        print("已保存，main.lua 下个轮询周期生效。")
      end
    elseif s == "4" then
      local th = (cf.thresholds and cf.thresholds[crop]) or {}
      local ci = (cf.crops and cf.crops[crop]) or {}
      t.t[crop] = nil
      t.seq = t.seq + 1
      util.save(FILE, t)
      print(string.format("已删除覆盖，回到默认 low=%d high=%d bed=%d",
        math.floor(tonumber(th.low) or 64), math.floor(tonumber(th.high) or 512),
        math.floor(tonumber(ci.bed) or 0)))
    else
      print("没有这个选项。")
    end
  end
end

local function crop_by_arg(a)
  if not a then return nil end
  local n = tonumber(a)
  if n then return list[n] end
  for _, c in ipairs(list) do if c == a then return c end end
  return nil
end

local a1 = args[1]

-- ===== 优先级分层编辑（写 priority.dat；层号越小越优先；移出层 = 不种，自动配置也不会加回）=====
local PRIO_FILE = ROOT .. "/priority.dat"
local function load_prio()
  local p = util.load(PRIO_FILE, nil)
  if type(p) == "table" and type(p.layers) == "table" then
    p.excluded = p.excluded or {}
    p.seq = tonumber(p.seq) or 0
  else
    local layers = {}
    for _, layer in ipairs(cf.priority or {}) do
      local nl = {}
      for _, c in ipairs(layer) do nl[#nl + 1] = c end
      layers[#layers + 1] = nl
    end
    p = { seq = 0, layers = layers, excluded = {} }
  end
  while #p.layers < 10 do p.layers[#p.layers + 1] = {} end   -- 固定 10 层：1..10，第 10 层=未定级兜底
  -- 未在任何层里的作物 = 未定级 → 直接放进第 10 层（和 main 自动配置的行为一致，不是"不种"）
  do
    local last = p.layers[#p.layers]
    local seenL = {}
    for _, layer in ipairs(p.layers) do for _, c in ipairs(layer) do seenL[c] = true end end
    for _, c in ipairs(list) do
      if not seenL[c] and not p.excluded[c] then last[#last + 1] = c; seenL[c] = true end
    end
  end
  return p
end
local function save_prio(p)
  p.seq = (tonumber(p.seq) or 0) + 1
  util.save(PRIO_FILE, p)
end
local function remove_from(p, crop)
  for _, layer in ipairs(p.layers) do
    for i = #layer, 1, -1 do
      if layer[i] == crop then table.remove(layer, i) end
    end
  end
end
local function layer_of(p, crop)
  for i, layer in ipairs(p.layers) do
    for _, c in ipairs(layer) do if c == crop then return i end end
  end
end
local function prio_rows(p)
  local out, seen = {}, {}
  for i, layer in ipairs(p.layers) do
    for _, c in ipairs(layer) do out[#out + 1] = { crop = c, layer = i }; seen[c] = true end
  end
  for _, c in ipairs(list) do
    if not seen[c] then out[#out + 1] = { crop = c, layer = 0 }; seen[c] = true end
  end
  return out
end
local function show_prio(p)
  print("======== 优先级分层（层号越小越优先，共 10 层）========")
  local rows = prio_rows(p)
  for i, r in ipairs(rows) do
    print(string.format(" %2d) %-12s %s", i, r.crop,
      r.layer > 0 and ("第" .. r.layer .. "层") or "已移出（不种）"))
  end
  print("-------------------------------")
  local empt = {}
  for i = 1, #p.layers do if #p.layers[i] == 0 then empt[#empt + 1] = i end end
  print("空层：" .. (#empt > 0 and table.concat(empt, ",") or "无") .. "（第10层=未定级，新作物自动进这层）")
  print("输编号 → 再输目标层号（1.." .. #p.layers .. "；+1 上移 / -1 下移 / 0 移出=不种）")
end
local function apply_prio_move(p, row, target)
  if not row then print("没有这个编号。") return end
  if target == 0 then
    remove_from(p, row.crop)
    p.excluded[row.crop] = true
    save_prio(p)
    print(string.format("%s 已移出优先队列（不种；自动配置也不会再加回）", row.crop))
    return
  end
  local n = target
  if n == "+1" or n == "-1" then
    local cur = layer_of(p, row.crop) or 0
    n = cur + (n == "+1" and -1 or 1)      -- +1 = 上移 = 层号 -1
    if n < 1 then n = 1 end
  end
  n = tonumber(n)
  if not n then print("层号无效。") return end
  n = math.max(1, math.min(math.floor(n), #p.layers + 1))
  if n > #p.layers then p.layers[n] = {} end
  remove_from(p, row.crop)
  p.layers[n][#p.layers[n] + 1] = row.crop
  p.excluded[row.crop] = nil
  save_prio(p)
  print(string.format("%s → 第%d层（main.lua 一个轮询周期内生效）", row.crop, n))
end
local function prio_loop()
  while true do
    local p = load_prio()
    show_prio(p)
    local s = ask("编号（回车退出）> ")
    if not s or s == "" then return end
    local rows = prio_rows(p)
    local n = tonumber(s)
    if not n or not rows[n] then print("没有这个编号。") else
      local tgt = ask("目标层 > ")
      if tgt and tgt ~= "" then apply_prio_move(p, rows[n], tgt) end
    end
  end
end

-- lua set.lua prio [编号] [层号|+1|-1|0]
if a1 == "prio" then
  if args[2] then
    local p = load_prio()
    local rows = prio_rows(p)
    local row = nil
    local n = tonumber(args[2])
    if n and rows[n] then row = rows[n] end
    if not row then
      for _, r in ipairs(rows) do if r.crop == args[2] then row = r end end
    end
    if not row then print("没有这个编号（先 lua set.lua prio 看编号）。") return end
    if not args[3] then print("用法：lua set.lua prio <编号> <层号|+1|-1|0>") return end
    apply_prio_move(p, row, args[3])
    return
  end
  prio_loop()
  return
end

-- 直接按编号设 low/high：lua set.lua 2 128 512
if a1 and tonumber(a1) and args[2] and args[3] then
  local crop = list[tonumber(a1)]
  local low, high = tonumber(args[2]), tonumber(args[3])
  if not crop or not low or not high then print("编号或数值无效（先 lua set.lua list 看编号）。") return end
  if low < 0 or high <= low or low % 1 ~= 0 or high % 1 ~= 0 then print(string.format("参数不对：high(%s) 必须大于 low(%s)，且都是 ≥0 的整数", tostring(high), tostring(low))) return end
  t.t[crop] = t.t[crop] or {}
  t.t[crop].low, t.t[crop].high = math.floor(low), math.floor(high)
  t.seq = t.seq + 1
  util.save(FILE, t)
  print(string.format("已设置 %d 号 %s：low=%d high=%d（main.lua 约一个轮询周期内生效）", tonumber(a1), crop, math.floor(low), math.floor(high)))
  return
end

-- lua set.lua bed 2 5
if a1 == "bed" then
  local crop = crop_by_arg(args[2])
  local bed = tonumber(args[3])
  if not crop or not bed then print("用法：lua set.lua bed <编号> <0..12>") return end
  bed = math.floor(bed)
  if bed < 0 or bed > 12 then
    print("苗床等级范围 0..12（0=无要求；1..12 对应 MV..UXV），没改。")
    return
  end
  t.t[crop] = t.t[crop] or {}
  t.t[crop].bed = bed
  t.seq = t.seq + 1
  util.save(FILE, t)
  print(string.format("已设置 %s 苗床需=%d", crop, bed))
  return
end

-- lua set.lua del 2
if a1 == "del" then
  local crop = crop_by_arg(args[2])
  if not crop then print("用法：lua set.lua del <编号>") return end
  local th = (cf.thresholds and cf.thresholds[crop]) or {}
  local ci = (cf.crops and cf.crops[crop]) or {}
  t.t[crop] = nil
  t.seq = t.seq + 1
  util.save(FILE, t)
  print(string.format("已删除 %s 的覆盖，回到默认 low=%d high=%d bed=%d",
    crop, math.floor(tonumber(th.low) or 64), math.floor(tonumber(th.high) or 512),
    math.floor(tonumber(ci.bed) or 0)))
  return
end

-- lua set.lua list：只列不改
if a1 == "list" then
  show_list()
  return
end

-- lua set.lua side [农场号 [面0..5]]   —— 红石端口热改，写 farms.dat（main.lua 轮询自动生效，无需重启）
if a1 == "side" then
  local FARMS_FILE = ROOT .. "/farms.dat"
  local side_name = function(n)
    local names = { "下(0)", "上(1)", "北(2)", "南(3)", "西(4)", "东(5)" }
    return names[math.floor(tonumber(n) or 0) + 1] or ("面" .. tostring(n))
  end
  local ft = util.load(FARMS_FILE, nil)
  if type(ft) ~= "table" or type(ft.farms) ~= "table" then ft = { farms = {}, seq = 0 } end
  ft.farms = ft.farms or {}
  ft.seq = tonumber(ft.seq) or 0
  if not args[2] then
    if next(ft.farms) == nil then
      print("还没有红石端口覆盖（默认面 1=上；农场 2/3 也继承 1=上）。")
    else
      for id, o in pairs(ft.farms) do
        print(string.format("农场 %s：红石端口 %s", tostring(id), side_name(o.redstone_side)))
      end
    end
    print("用法：lua set.lua side <农场号> <面0..5>   （0=下 1=上 2=北 3=南 4=西 5=东）")
    return
  end
  local sid = tonumber(args[2])
  local sside = tonumber(args[3])
  if not sid or not sside then
    print("用法：lua set.lua side <农场号> <面0..5>   （0=下 1=上 2=北 3=南 4=西 5=东）")
    return
  end
  sside = math.floor(sside)
  if sside < 0 or sside > 5 then
    print("面号范围 0..5（0=下 1=上 2=北 3=南 4=西 5=东），没改。")
    return
  end
  ft.farms[tostring(sid)] = { redstone_side = sside }
  ft.seq = ft.seq + 1
  util.save(FARMS_FILE, ft)
  print(string.format("已设置农场 %d：红石端口 %s。main.lua 约一个轮询周期内生效，无需重启。", sid, side_name(sside)))
  return
end

-- lua set.lua 2：直接进 2 号作物的编辑菜单
if a1 and tonumber(a1) then
  local crop = list[tonumber(a1)]
  if not crop then print("没有这个编号（先 lua set.lua list 看编号）。") return end
  edit(crop)
  return
end

-- 无参数：交互循环
while true do
  show_list()
  local s = ask("编号（或 prio）> ")
  if not s or s == "" then break end
  if s == "prio" then
    prio_loop()
  else
    local n = tonumber(s)
    if not n or not list[n] then print("没有这个编号。") else edit(list[n]) end
  end
end
print("退出。")
