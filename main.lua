-- 主循环（多农场版 · 阶段①：单作物多农场并行）
-- 用法：lua main.lua       正常跑
--       lua main.lua dry   只看状态，不下单也不点红石
-- 停止：运行中按任意键（安全退出）；或另开一个终端建 /home/ocfarm/stop 文件
local ROOT = "/home/ocfarm"
local STOP_FILE = ROOT .. "/stop"

local function loadmod(name)
  local path = ROOT .. "/lib/" .. name .. ".lua"
  local f = io.open(path, "r")
  if not f then error("缺少模块: " .. path) end
  f:close()
  return dofile(path)
end

local computer = require("computer")
local component = require("component")
local event = require("event")
local ae = loadmod("ae")
local farmio = loadmod("farmio")
local util = loadmod("util")
local selfcheck = loadmod("selfcheck")
local tasksmod = loadmod("tasks")
local cfg = dofile(ROOT .. "/config.lua")

-- 英文名 -> 中文名（英文客户端/未本地化的作物 label 是英文时，显示统一翻回中文）
local okZh, zhMap = pcall(dofile, ROOT .. "/crops_zh.lua")
local CROPS_ZH = (okZh and type(zhMap) == "table") and zhMap or {}
local function zh(s)
  local z = CROPS_ZH[s]
  return z or s
end

-- §9.1：农场地址/坐标以 binds.dat 为准（拆装方块会换新 UUID，config 里的旧地址不可信）。
-- config.farms 只保留 redstone_side / enabled 这类行为参数，这里按 id 合到 binds 上。
local function load_binds()
  local t = util.load(ROOT .. "/binds.dat", nil)
  if not t or type(t.farms) ~= "table" or #t.farms == 0 then return nil end
  return t.farms
end

local function merge_farms(binds_farms)
  local by_id = {}
  for _, f in ipairs(cfg.farms or {}) do
    if type(f) == "table" and f.id ~= nil then by_id[f.id] = f end
  end
  local out = {}
  for _, b in ipairs(binds_farms) do
    local beh = by_id[b.id] or {}
    out[#out + 1] = {
      id             = b.id,
      gt             = b.gt,
      redstone       = b.redstone,
      x = b.x, y = b.y, z = b.z, dimension = b.dimension,
      iface          = b.iface,
      iface_name     = b.iface_name,
      interface_name = b.iface_name,           -- pat.lua 按这个名字认下单接口
      redstone_side  = beh.redstone_side,   -- 弃用：farmio 已写死只向上发，side 参数不再使用
      enabled        = (beh.enabled == nil) and true or beh.enabled,
    }
  end
  return out
end

local binds_farms = load_binds()
if not binds_farms then
  error("[致命] 没有可用的 /home/ocfarm/binds.dat（农场表为空或缺失）。请先跑 lua bind.lua 绑定农场，再启动 main.lua。", 0)
end
cfg.farms = merge_farms(binds_farms)

-- 网络地址：/home/ocfarm/ae.dat 是权威（lua setup.lua 扫描生成），config.lua 的 ae 只作兜底。
-- 换电脑 / 换存档 / 拆装方块后不用手改 config：跑一遍 setup.lua 生成 ae.dat 即可。
do
  cfg.ae = cfg.ae or {}
  local a = util.load(ROOT .. "/ae.dat", nil)
  if type(a) == "table" then
    for k, v in pairs(a) do
      if k ~= "seq" and v ~= nil then cfg.ae[k] = v end
    end
  end
  if not (cfg.ae.storage and cfg.ae.seed) then
    error("[致命] 没有可用的网络地址：/home/ocfarm/ae.dat 缺失、config.lua 的 ae 段也是空的。\n请先跑 lua setup.lua 扫描并写入网络地址，再启动 main.lua。", 0)
  end
end

-- 取命令行参数：OpenOS 的 lua 把参数放在 chunk varargs（...）里，
-- 全局 arg 有时是 nil，所以两路都收，再按关键词扫描（不依赖位置）
local ARGS = {}
do
  local n = select("#", ...)
  for i = 1, n do ARGS[#ARGS + 1] = select(i, ...) end
  if #ARGS == 0 and type(arg) == "table" then
    for _, v in pairs(arg) do
      if type(v) == "string" then ARGS[#ARGS + 1] = v end
    end
  end
end

local DRY = false
local PLAIN = false
local FRESH = false
for _, a in ipairs(ARGS) do
  local s = tostring(a)
  if s == "dry" then DRY = true
  elseif s == "plain" then PLAIN = true
  elseif s == "fresh" then FRESH = true
  end
end

-- 地址自愈：配置里的地址失效（比如红石端口被拆掉重放，地址会变）时，
-- 如果同类组件只有一个，就自动改用那个；有多个就停机并列出候选
local function adr_ok(addr)
  if not addr then return false end
  local ok, p = pcall(component.proxy, addr)
  return ok and p ~= nil
end
local function list_of(kind)
  local t = {}
  for a, ty in component.list(kind, true) do
    if ty == kind then t[#t + 1] = a end
  end
  return t
end

local heal_notes = {}
local function heal(addr, kind, what)
  if adr_ok(addr) then return addr end
  local cand = list_of(kind)
  if #cand == 1 then
    heal_notes[#heal_notes + 1] = string.format("[自愈] %s 地址 %s 失效 → 改用唯一候选 %s", what, tostring(addr), cand[1])
    return cand[1]
  end
  return addr, cand
end

local heal_fail = {}
local function heal_cfg()
  local a, c = heal(cfg.ae.storage, "me_interface", "存储网接口")
  if c then heal_fail[#heal_fail + 1] = "存储网接口: " .. table.concat(c, ", ") end
  cfg.ae.storage = a
  a, c = heal(cfg.ae.seed, "me_interface", "种子网接口")
  if c then heal_fail[#heal_fail + 1] = "种子网接口: " .. table.concat(c, ", ") end
  cfg.ae.seed = a
  a, c = heal(cfg.ae.terminal, "me_interface_terminal", "接口终端")
  if c then heal_fail[#heal_fail + 1] = "接口终端: " .. table.concat(c, ", ") end
  cfg.ae.terminal = a
  for _, f in ipairs(cfg.farms) do
    a, c = heal(f.gt, "gt_machine", "农场" .. f.id .. " 机器")
    if c then heal_fail[#heal_fail + 1] = "农场" .. f.id .. " 机器: " .. table.concat(c, ", ") end
    f.gt = a
    a, c = heal(f.redstone, "redstone", "农场" .. f.id .. " 红石")
    if c then heal_fail[#heal_fail + 1] = "农场" .. f.id .. " 红石: " .. table.concat(c, ", ") end
    f.redstone = a
  end
end
heal_cfg()

local A = ae.new(cfg.ae)
local F = farmio.new({})
local T = cfg.timing
local TASKS = tasksmod.new(ROOT .. "/tasks.dat")
-- 仪表盘：T3 屏（≥160×50）可用，其余屏幕/无 GPU 自动退化纯终端。开关记忆在 ui.dat，F1 切换。
local UI = nil
if not (DRY or PLAIN) then
  UI = loadmod("ui").new(ROOT)
end
-- 面板存在时把 print 收进日志环（面板开：只进环；面板关：照常打印到终端），避免和仪表盘抢屏
if UI and UI.ok then
  local realprint = print
  print = function(s) if UI then UI:log(tostring(s)) else realprint(s) end end
end
local PAT = loadmod("pat").new(cfg)

-- 退出/崩溃时把屏幕还给终端（否则仪表盘画着，shell 提示符和报错都看不见）
local function ui_restore()
  if UI and UI.ok and UI.on then
    pcall(function() UI:toggle(false) end)
  end
end

-- 统一秒口径：用 computer.uptime()——它是"游戏时间秒"（实现：每游戏 tick +1，再 ÷20）。
-- 游戏暂停 / 世界不加载 / 存档关着的时候它不动，所以不会把"游戏没开着的那段"算进
-- 生长时长和耗时（用墙钟 realTime 会一觉睡出 5 万秒的假超时）。realTime 只当兜底。
local function upsec()
  local ok, v = pcall(computer.uptime)
  if ok and type(v) == "number" then return v end
  local ok2, v2 = pcall(computer.realTime)
  if ok2 and type(v2) == "number" then return v2 end
  return os.time()
end

-- 注意顺序：upsec 必须先定义，now 里引用的才是这个局部函数（否则按全局找，运行时 nil 报错）
local function now() return math.floor(upsec()) end

if type(A.seeds_by_label) ~= "function" or type(A.items_by_label) ~= "function" then
  local n = 0
  for _ in pairs(ae) do n = n + 1 end
  error("ae.lua 版本不对：方法数=" .. n .. "，缺 seeds_by_label/items_by_label，请重新部署 lib/ae.lua")
end

-- ===== §9.2 每农场独立状态 =====
-- state.dat 现在是 { farms = { [id] = {...} } }。旧版扁平单份结构（带 phase 字段）读到就迁到 farms[1]。
local function new_state(id)
  return {
    id = id,
    phase = "input", crop = nil, pending = 0,
    seed_base = 0, sub_base = 0,
    since = now(), since_u = upsec(),
    cycles = 0,
    reclaim_ticks = 0,
    last_prod = nil, last_prod_u = nil,
    task_id = nil, retried = nil, warned = nil,
    dq = nil,               -- 发配流水线子状态（nil = 不在流水线里）
    last_preempt = 0,       -- 上次被抢占的时间（阶段②抢占用）
  }
end

local ST = util.load(cfg.paths.state, nil)
if type(ST) ~= "table" then ST = {} end
if ST.farms == nil then
  local legacy = (ST.phase ~= nil or ST.crop ~= nil) and ST or nil
  ST = { farms = {} }
  if legacy then
    legacy.id = legacy.id or 1
    ST.farms[1] = legacy
  end
end
-- 每台都要有状态对象；重启后 uptime 清零，旧 since_u 大于当前 uptime 就重置计时
for _, f in ipairs(cfg.farms) do
  local s = ST.farms[f.id]
  if not s then s = new_state(f.id); ST.farms[f.id] = s end
  s.id = f.id
  -- 时间戳口径迁移：旧状态文件里 since_u/last_prod_u 是游戏秒（约 1e3 量级），
  -- 真实秒是 1.7e9 量级；旧值重打为"现在"，不动阶段/作物/在制数，避免旧值立刻算成超时
  if (s.since_u or 0) < 1e7 then s.since_u = upsec() end
  if s.last_prod_u ~= nil and s.last_prod_u < 1e7 then s.last_prod_u = upsec() end
  if s.cycles == nil then s.cycles = 0 end
  if s.pending == nil then s.pending = 0 end
  if s.dq ~= nil then s.dq = nil end   -- 流水线是本次运行的内存过程，重启一律作废（样板由 sweep 搬回）
end

-- 台账清场：只有"非空闲农场 + state 里还挂着 task_id"的才算真在制。
-- 上次异常退出/Ctrl+C 会留下 state="dispatched" 的陈旧记录，它们会让分配器的
-- inflight(crop, farm) 永远 > 0 —— 农场明明空着，这个作物却分不到它（这就是种子剩着不种的元凶）。
do
  local live = {}
  for _, f in ipairs(cfg.farms) do
    local s = ST.farms[f.id]
    if s and s.task_id and s.phase ~= "input" then live[s.task_id] = true end
  end
  local stale = {}
  for i = #TASKS.list, 1, -1 do
    local t = TASKS.list[i]
    if not live[t.id] then
      stale[#stale + 1] = string.format("#%d %s×%d@农场%s", t.id, tostring(t.crop), math.floor(t.n or 0), tostring(t.farm))
      table.remove(TASKS.list, i)
    end
  end
  if #stale > 0 then
    TASKS:save()
    heal_notes[#heal_notes + 1] = "[台账] 清掉 " .. #stale .. " 条上次没回收完的在制记录：" .. table.concat(stale, "，")
  end
end
local function save() util.save(cfg.paths.state, ST) end

local function say(fmt, ...)
  local args = table.pack(...)
  -- 这一版 OC 从 AE 拿到的数量是浮点（64.0），直接配 %d 会报
  -- "number has no integer representation"；整数值的浮点先转成整数
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
  if UI then UI:log(s) else print(s) end
  local f = io.open(cfg.paths.log, "a")
  if f then
    f:write("[" .. util.stamp() .. "] " .. s .. "\n")
    f:close()
  end
end

local function stop_flag()
  local f = io.open(STOP_FILE, "r")
  if f then f:close() return true end
  return false
end

-- 同一条消息内容重复时只打一次，避免每轮轮询都刷屏（比如"还有 N 颗在制"）
local notes_seen = {}
local function note(key, fmt, ...)
  local s
  if select("#", ...) > 0 then
    local ok, r = pcall(string.format, fmt, ...)
    s = ok and r or (fmt .. " " .. tostring((...)))
  else
    s = fmt
  end
  if notes_seen[key] == s then return end
  notes_seen[key] = s
  say("%s", s)
end
local function note_clear(key) notes_seen[key] = nil end

-- 分段睡眠：期间检查 stop 文件和键盘（连按两次 q 退出）
-- 注意：组件事件的首个参数是组件地址，key_down 实际是 (地址, 字符, 键码)
local stopping = false
local qlast = -99
local boot_ticks = 0
local function key_char(a, b)
  local addr_like = type(a) == "string" and a:find("^%x%x%x%x%x%x%x%x%-") ~= nil
  local ch = addr_like and b or a
  -- 这版 OC 的 key_down 给的是 ASCII 码（数字），要转回字符
  if type(ch) == "number" then
    if ch >= 32 and ch <= 126 then return string.char(ch) end
    return nil
  end
  return ch
end

-- 致命错误：打印并终止本轮运行（不再"假装正常"往下走）
local function fatal(stx, fmt, ...)
  local s = select("#", ...) > 0 and string.format(fmt, ...) or fmt
  say("[致命] %s", s)
  if stx and stx.id then
    say("[致命] 农场 %d 已停在阶段=%s 作物=%s，修正后重新运行即可接着做", stx.id, stx.phase, tostring(stx.crop))
  end
  stopping = true
end

local function wait(sec)
  local deadline = upsec() + (sec or 1)
  while upsec() < deadline do
    local left = deadline - upsec()
    local slice = math.max(0.05, math.min(0.25, left))
    local name, a, b, c = event.pull(slice)
    -- OpenOS 的 Ctrl+C：lib/event.lua 包在 pullSignal 上，按键状态命中就塞 "interrupted" 信号；
    -- 之前这里只认 key_down 把中断吞了，现在接住 = 安全退出。
    if name == "interrupted" then
      stopping = true
      say("[停止] 被 Ctrl+C 中断，准备安全退出")
      return false
    end
    if name == "key_down" then
      -- F1 开关必须先送进 UI（关着的时候也要能按开）；开着时才把按键全交给面板
      if UI and UI.ok then UI:key(a, b, c) end
      if UI and UI.ok and UI.on then
        if UI.quit_requested then
          stopping = true
          say("[停止] 连按两次 q，准备安全退出")
          return false
        end
      else
        local ch = key_char(a, b)
        if ch == "q" or ch == "Q" then
          local t = upsec()
          if t - qlast <= 5 then
            stopping = true
            say("[停止] 连按两次 q，准备安全退出")
            return false
          end
          qlast = t
          say("[提示] 再按一次 q 退出")
        end
      end
    end
    if name == "clipboard" and UI and UI.ok and UI.on then
      -- 鼠标中键粘贴：文字只进终端输入行，别漏到屏幕其它地方
      local txt = nil
      for _, v in ipairs({ a, b, c }) do
        if type(v) == "string" and not v:find("^%x%x%x%x%x%x%x%x%-") then txt = (txt or "") .. v end
      end
      if txt then UI:paste(txt) end
    end
    if stop_flag() then
      stopping = true
      say("[停止] 检测到 stop 文件，准备安全退出")
      return false
    end
    if UI then UI:tick() end
  end
  return true
end

local function cropinfo(name) return (cfg.crops and cfg.crops[name]) or {} end

-- ===== job（合成任务对象）状态 =====
-- request() 返回的对象有 isDone/isComputing/isCanceled/hasFailed。
-- 插了伪合成卡时，"原料发配完"job 立刻 isDone —— 这是判断发配完成最权威的信号，
-- 不用再去数种子（数种子会慢、会被别的消耗干扰）。
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

-- 同 job_flag，但保留第二个返回值：
-- AE2 的 CraftingStatus.hasFailed() 返回 (failed, reason)，reason 里是真正的报错文案，
-- 例如 "request failed (missing resources)" / "request failed (Error submitting job to AE2.)"
local function job_flag2(job, name)
  if job == nil then return nil end
  local f = job[name]
  if f == nil then return nil end
  local ok, v1, v2 = pcall(function() return job[name](job) end)
  if ok then return v1, v2 end
  ok, v1, v2 = pcall(f)
  if ok then return v1, v2 end
  return nil
end

local function wait_job(job, limit)
  local t0 = upsec()
  while upsec() - t0 < (limit or 60) do
    if job_flag(job, "hasFailed") == true then return false, "任务标记失败" end
    if job_flag(job, "isCanceled") == true then return false, "任务被取消" end
    if job_flag(job, "isDone") == true then return true, upsec() - t0 end
    if not wait(1) then return false, "用户退出" end
  end
  return false, "超时"
end

-- 作物在第几层（层号越小越优先）；不在表里 = 比谁都低
local function layer_of(crop)
  for li, layer in ipairs(cfg.priority) do
    for _, c in ipairs(layer) do
      if c == crop then return li end
    end
  end
  return #cfg.priority + 1
end

-- 候选作物：按 priority 层序，同层按缺口比例降序。
-- 缺口（比例）只用来排序，不当种子数下限（种子≠产物；用户原则：尽量把种子用光）
-- 返回 { {crop, have, low, high, seeds, sub, bed, subsoil, out, mult, ratio}, ... }
local function candidates(prod, seeds, allSeed)
  local out = {}
  for _, layer in ipairs(cfg.priority) do
    local layerCands = {}
    for _, crop in ipairs(layer) do
      local th = cfg.thresholds[crop] or {}
      local have = prod[th.product or crop]
      have = have and have.count or 0
      local low = th.low or 64
      local sd = seeds[crop]
      local haveSeeds = sd and sd.count or 0
      if have < low and haveSeeds > 0 then
        local ci = cropinfo(crop)
        local haveSub = 0
        if ci.subsoil then
          local s = allSeed[ci.subsoil]
          haveSub = s and s.count or 0
          if haveSub <= 0 then
            note("sub:" .. crop, "[跳过] %s 需要垫块「%s」，种子网里没有", crop, tostring(ci.subsoil))
          else
            note_clear("sub:" .. crop)
          end
        end
        if not ci.subsoil or haveSub > 0 then
          layerCands[#layerCands + 1] = {
            crop = crop, have = have, low = low,
            high = th.high or (low * 8),
            seeds = haveSeeds, sub = haveSub,
            bed = ci.bed or 0, subsoil = ci.subsoil, out = ci.out or crop,
            mult = ci.mult or 1,
            ratio = (low - have) / low,
          }
        end
      end
    end
    table.sort(layerCands, function(a, b) return a.ratio > b.ratio end)
    for _, c in ipairs(layerCands) do out[#out + 1] = c end
  end
  return out
end

-- ===== 配置自动化：读仓库样板，自动补齐 config 里没有的作物 =====
-- 你在 AE 里给作物写一个样板（垫块 + 种子 → 产物）、把种子丢进种子网络，
-- 启动时这里就会自动生成 crops/thresholds 条目，priority 里没有的挂到最后一层。
-- 已存在的作物不覆盖（阈值用 lua set.lua 改）。
local function stack_label_size(v)
  if type(v) ~= "table" then return nil end
  local l = v.label or v.displayName or v.name
  if l == nil or tostring(l) == "" then return nil end
  return tostring(l), tonumber(v.size) or 0
end

local function pattern_crop_info(st)
  if type(st) ~= "table" then return nil end
  local product, mult
  if type(st.outputs) == "table" then
    for _, v in pairs(st.outputs) do
      local l, n = stack_label_size(v)
      if l then product, mult = l, n break end
    end
  end
  if not product then return nil end
  local seedLbl, subLbl
  if type(st.inputs) == "table" then
    for _, v in pairs(st.inputs) do
      local l = stack_label_size(v)
      if l then
        if l:find("种子$") or l:find("[Ss]eeds?$") then seedLbl = seedLbl or l
        else subLbl = subLbl or l end
      end
    end
  end
  if not seedLbl then return nil end
  local crop = zh(seedLbl:gsub("种子$", ""):gsub("%s+[Ss]eeds?$", ""))
  return { crop = crop, product = product, mult = (mult or 0) > 0 and mult or 1, subsoil = subLbl }
end

local function in_priority(crop)
  for _, layer in ipairs(cfg.priority) do
    for _, c in ipairs(layer) do if c == crop then return true end end
  end
  return false
end

-- ===== 苗床需求表（crops_bed.lua，GTNH 中文维基「工业农场」专属作物表）=====
-- 只列 12 种专属作物；其它作物无苗床要求（bed=0）。分配时按 bed <= 农场等级过滤，
-- 等级不够的农场不接单——否则种子会卡在输入总线里把整台机器堵死。
local CROPS_BED = {}
do
  local ok, t = pcall(dofile, ROOT .. "/crops_bed.lua")
  if ok and type(t) == "table" then CROPS_BED = t end
end
local BED_BY_PRODUCT = {}
for bname, e in pairs(CROPS_BED) do
  if type(e) == "table" and e.product then BED_BY_PRODUCT[e.product] = e.bed end
end
-- 查最低苗床等级：先按作物名，再按产物名（作物名可能和样板产物名不同，如 空间之草/空间之花）
local function bed_of(crop, product)
  local e = CROPS_BED[crop]
  if type(e) == "table" then return e.bed end
  local b = product and BED_BY_PRODUCT[product]
  if b then return b end
  return nil
end

-- 优先级排除名单：apply_priority 填、auto_config 读。必须先于 auto_config 声明（否则 auto_config 里是全局 nil）
local PRIO_EXCLUDED = {}

local function auto_config()
  local wh = PAT:warehouse()
  if not wh then say("[配置] 找不到仓库接口，跳过自动配置"); return end
  local slots = PAT:slots(wh)
  if #slots == 0 then say("[配置] 仓库里没有样板，跳过自动配置"); return end
  local added, bedUnknown = {}, {}
  local lastLayer = cfg.priority[#cfg.priority]
  -- 全新安装（优先级全空）：新发现的作物放第 1 层，而不是「未定级」的第 10 层
  do
    local total = 0
    for _, lay in ipairs(cfg.priority) do total = total + #lay end
    if total == 0 then lastLayer = cfg.priority[1] end
  end
  for _, slot in ipairs(slots) do
    local ci = pattern_crop_info(wh.patterns and wh.patterns[slot])
    if ci and ci.crop ~= "" and ci.crop ~= "空白" then
      cfg.crops = cfg.crops or {}
      local bedKnown = bed_of(ci.crop, ci.product)
      local bedUse = bedKnown
      if not bedUse and ci.subsoil then bedUse = 5 end  -- 有垫块但查不到：保守按最高苗床(5)
      if not cfg.crops[ci.crop] then
        cfg.crops[ci.crop] = { out = ci.product, mult = ci.mult, subsoil = ci.subsoil, bed = bedUse or 0 }
      else
        local ce = cfg.crops[ci.crop]
        if (not ce.bed or ce.bed == 0) and bedUse and bedUse > 0 then ce.bed = bedUse end
        if not ce.out then ce.out = ci.product end
        if not ce.mult then ce.mult = ci.mult end
        if not ce.subsoil then ce.subsoil = ci.subsoil end
      end
      cfg.thresholds = cfg.thresholds or {}
      if not cfg.thresholds[ci.crop] then
        cfg.thresholds[ci.crop] = { product = ci.product, low = 64, high = 512 }
      end
      if not in_priority(ci.crop) and not PRIO_EXCLUDED[ci.crop] then
        lastLayer[#lastLayer + 1] = ci.crop
        if ci.subsoil and not bedKnown then bedUnknown[#bedUnknown + 1] = ci.crop end
        added[#added + 1] = string.format("%s（产物 %s ×%d，垫块 %s，苗床 %s）",
          ci.crop, zh(ci.product), ci.mult, ci.subsoil or "无",
          bedKnown and tostring(bedKnown) or (ci.subsoil and "5(保守)" or "0"))
      end
    end
  end
  if #added > 0 then
    say("[配置] 自动补了 %d 个作物（阈值默认 64/512，可 lua set.lua 改）：%s",
      #added, table.concat(added, "；"))
  end
  if #bedUnknown > 0 then
    say("[配置] 以下作物有垫块但苗床需求表里没有、先按 5 保守处理（不准就 lua set.lua bed <作物> <等级>）：%s",
      table.concat(bedUnknown, "、"))
  end
  -- 苗床需求汇总：一眼看清哪些作物要求几级苗床
  do
    local parts = {}
    for _, layer in ipairs(cfg.priority) do
      for _, c in ipairs(layer) do
        local ci = cfg.crops and cfg.crops[c]
        local b = ci and (ci.bed or 0) or 0
        if b > 0 then parts[#parts + 1] = string.format("%s=苗床%d", c, b) end
      end
    end
    if #parts > 0 then
      say("[苗床] 最低苗床等级：%s；低于要求的农场不接单（种子不会卡在输入总线）", table.concat(parts, "、"))
    end
  end
  -- 种子网里有、但没有样板的作物，提示一下（不然会一直不种）
  local okS, seedsNet = pcall(function() return A:seeds_by_label("seed") end)
  if okS and type(seedsNet) == "table" then
    local noPat = {}
    for crop, d in pairs(seedsNet) do
      if (d.count or 0) > 0 and (not cfg.crops or not cfg.crops[crop]) and not in_priority(crop) then
        noPat[#noPat + 1] = crop
      end
    end
    if #noPat > 0 then
      say("[配置] 种子网里有种子、但仓库里没有对应样板（不会种）：%s", table.concat(noPat, "、"))
    end
  end
end

-- ===== 优先级分层：priority.dat（lua set.lua prio 写入）=====
-- 启动时【先于】auto_config 加载：被移出优先队列（excluded）的作物不会被自动加回最后一层。
-- 主循环里热读，和 limits.dat 一样一个轮询周期内生效。层内顺序不重要，层号越小越优先。
local PRIO_FILE = ROOT .. "/priority.dat"
local prio_seq = 0
local function apply_priority(announce)
  local t = util.load(PRIO_FILE, nil)
  if type(t) ~= "table" or type(t.layers) ~= "table" then return end
  local seq = tonumber(t.seq) or 0
  if seq == prio_seq then return end
  prio_seq = seq
  local layers, seen, nraw = {}, {}, 0
  for _, layer in ipairs(t.layers) do
    if type(layer) == "table" then
      nraw = nraw + 1
      local nl = {}
      for _, c in ipairs(layer) do
        if type(c) == "string" and c ~= "" and not seen[c] then seen[c] = true; nl[#nl + 1] = c end
      end
      layers[#layers + 1] = nl     -- 空层也保留：层号固定 1..10，新作物自动落最后一层
    end
  end
  if nraw == 0 then return end
  while #layers < 10 do layers[#layers + 1] = {} end
  while #layers > 10 do layers[#layers] = nil end
  PRIO_EXCLUDED = {}
  if type(t.excluded) == "table" then
    for c, v in pairs(t.excluded) do if v then PRIO_EXCLUDED[c] = true end end
  end
  cfg.priority = layers
  if announce then
    local parts = {}
    for i, lay in ipairs(layers) do parts[#parts + 1] = string.format("第%d层=%s", i, table.concat(lay, ",")) end
    say("[优先级] %s（第10层=未定级，新作物自动进这层）", table.concat(parts, "；"))
  end
end
apply_priority(true)   -- 先于 auto_config：排除名单里的作物不会被自动加回
-- 固定 10 层（没有 priority.dat 时也保证新作物落到第 10 层=未定级）
while #cfg.priority < 10 do cfg.priority[#cfg.priority + 1] = {} end

auto_config()

-- ===== 阈值热改：limits.dat（lua set.lua 写入），主循环里自动重读 =====
local LIMITS_FILE = ROOT .. "/limits.dat"
local limits_seq = 0
local function apply_limits(announce)
  local t = util.load(LIMITS_FILE, nil)
  if type(t) ~= "table" or type(t.t) ~= "table" then return end
  local seq = tonumber(t.seq) or 0
  if seq == limits_seq then return end
  limits_seq = seq
  cfg.thresholds = cfg.thresholds or {}
  cfg.crops = cfg.crops or {}
  for crop, v in pairs(t.t) do
    if type(v) == "table" then
      local old = cfg.thresholds[crop] or {}
      if type(v.low) == "number" and type(v.high) == "number" and v.high > v.low then
        cfg.thresholds[crop] = { product = v.product or old.product, low = v.low, high = v.high }
        if announce then say("[阈值] %s：low=%d high=%d", crop, v.low, v.high) end
      end
      if type(v.bed) == "number" and cfg.crops[crop] then
        cfg.crops[crop].bed = v.bed
        if announce then say("[阈值] %s：苗床需=%d", crop, v.bed) end
      end
    end
  end
end
apply_limits(true)

-- ===== 红石端口热改：farms.dat（lua set.lua side 写入），主循环里自动重读 =====
local FARMS_FILE = ROOT .. "/farms.dat"
local farms_seq = 0
local function apply_farms(announce)
  local t = util.load(FARMS_FILE, nil)
  if type(t) ~= "table" or type(t.farms) ~= "table" then return end
  local seq = tonumber(t.seq) or 0
  if seq == farms_seq then return end
  farms_seq = seq
  for _, f in ipairs(cfg.farms) do
    local o = t.farms[tostring(f.id)]
    if o and type(o.redstone_side) == "number" then
      f.redstone_side = o.redstone_side
      if announce then say("[农场] 农场 %d：红石端口改到面 %d", f.id, o.redstone_side) end
    end
  end
end
apply_farms(true)

util.logf(cfg.paths.log)
local farm_ids = {}
for _, f in ipairs(cfg.farms) do farm_ids[#farm_ids + 1] = tostring(f.id) end
say("[启动] 主循环开始%s，农场 %s（共 %d 台）—— 连按两次 q 安全退出",
  DRY and "（试运行）" or "", table.concat(farm_ids, ","), #farm_ids)
say("[帮助] 改阈值/优先级：lua set.lua；清场重来：lua reset.lua yes；备份：lua backup.lua；速查：lua help.lua")
say("[帮助] 加新作物：AE 里写样板（种子+垫块→产物）放进仓库接口，重启 main 自动识别")
if UI and UI.ok then
  say("[帮助] 仪表盘：F1 开/关（记忆在 ui.dat）；仪表盘里 Tab 切焦点、▲▼ 滚动，终端输入 help 看命令")
elseif not (DRY or PLAIN) then
  say("[帮助] 未检测到 T3 屏幕（分辨率≥160×50），仪表盘不可用，继续纯终端")
end
do
  -- 时钟校准行：每次启动打一行，方便核对秒口径。
  -- 口径：uptime = 游戏时间秒（按 tick 累计 ÷20，游戏停着不动），计时统一用它；
  -- realTime = 墙钟秒（游戏停着也走，只能当兜底）；os.time = 游戏内时间（可能被加速）。
  local okR, rt = pcall(computer.realTime)
  say("[校准] uptime=%s realTime=%s os.time=%s（计时口径=uptime 游戏秒）",
    string.format("%.1f", computer.uptime()),
    okR and type(rt) == "number" and string.format("%.1f", rt) or "无",
    tostring(os.time()))
end
for _, n in ipairs(heal_notes) do say(n) end
if #heal_fail > 0 then
  say("[致命] 有地址无效且无法自动确定（同类型组件有多个，不敢乱猜）：")
  for _, n in ipairs(heal_fail) do say("  " .. n) end
  say("[致命] 农场地址漂移 → lua bind.lua fix <id> 重绑；AE 接口地址变了 → 改 config.lua。")
  error("地址无效，已停止", 0)
end

-- 开机总自检：组件地址/类型、ME 网络、农场传感器、红石可写、作物数据
-- 有任何致命项就停下，不带着坏配置跑
-- 应急开关：home 下存在 noselfcheck 文件就跳过自检和清场（万一自检卡死，先用它进主循环）
local SKIPCHECK = io.open(ROOT .. "/noselfcheck") ~= nil
if not DRY and not SKIPCHECK then
  say("[启动] 开始总自检（组件/地址/网络/传感器/红石/作物）——卡住的话最后一行就是卡在哪")
  local okc, lines = selfcheck.run(cfg, A, F)
  util.write(ROOT .. "/check.txt", table.concat(lines, "\n") .. "\n")
  if not okc then
    say("[致命] 总自检没通过，已停止；细节见 /home/ocfarm/check.txt（按提示修好后，lua reset.lua yes 重来）")
    error("总自检失败，已停止", 0)
  end
  say("[自检] 总自检通过（结果也写到 check.txt）")
  say("[启动] 开始清场（搬回残留样板）…")
  -- 清场：把上轮/上次异常退出留在农场接口上的样板搬回仓库
  local oks, sres = PAT:sweep()
  if oks then
    say("[清场] 农场接口上的残留样板已搬回仓库：%s 个", tostring(sres))
  else
    say("[警告] 清场失败：%s", tostring(sres))
  end
end
if not DRY then
  -- 状态修复（每台）：上次异常退出会留下"阶段=farming"，但机器其实没在干活。
  -- 这种情况直接回到 input 重新调度，而不是傻等产物涨到 high。
  for _, f in ipairs(cfg.farms) do
    local stx = ST.farms[f.id]
    if not stx then stx = new_state(f.id); ST.farms[f.id] = stx end
    if FRESH or stx.phase ~= "input" then
      local hw = F:is_working(f.gt)
      if FRESH or hw == false then
        say("[修复] 农场 %d 状态里阶段=%s 但机器没在干活，判定为上次异常退出，重置为 input 重新调度",
          f.id, tostring(stx.phase))
        if stx.task_id then TASKS:finish(stx.task_id); stx.task_id = nil end
        stx.phase = "input"
        stx.crop = nil
        stx.pending = 0
        stx.retried = nil
        stx.last_prod = nil
        stx.last_prod_u = nil
        stx.since = now()
      end
    end
  end
  save()
end

-- ===== 每 tick 读两张网一次，所有农场共用 =====
local function read_nets()
  local seeds, allSeed, prod = {}, {}, {}
  local nSeedRaw = 0
  for _, s in ipairs(A:raw("seed")) do
    nSeedRaw = nSeedRaw + 1
    local label = tostring(s.label or "")
    local e = allSeed[label]
    if not e then e = { count = 0, name = s.name }; allSeed[label] = e end
    e.count = e.count + (s.size or 0)
    if s.name == "cropsnh:genericSeed" then
      local cropName = zh(label:gsub("种子$", ""):gsub("%s+[Ss]eeds?$", ""))
      local q = seeds[cropName]
      if not q then q = { count = 0, label = label, stack = s }; seeds[cropName] = q end
      q.count = q.count + (s.size or 0)
    end
  end
  for _, s in ipairs(A:raw("storage")) do
    local label = tostring(s.label or "")
    local e = prod[label]
    if not e then e = { count = 0, name = s.name, damage = s.damage }; prod[label] = e end
    e.count = e.count + (s.size or 0)
  end
  return seeds, allSeed, prod, nSeedRaw
end

-- ===== 发配流水线（每台农场独立推进；同一种作物的生效样板全网只有一份，用 PATLOCK 占位）=====
-- 多农场可并发发配（不同作物天然不冲突，可同时用多个合成 CPU）；
-- 同一种作物同一时刻只允许一台农场拿走样板，第二台排队等样板回仓库。
local PATLOCK = {}            -- [作物] = 正拿着这份样板的农场 id；nil = 样板在仓库
local PATLOCK_since = {}      -- [作物] = 开始拿样板的时间（告警用）
local RECLAIM = {}            -- [作物] = 正在 Output 回收这台作物的农场 id（同作物回收串行，防对账互相污染）
local sigs = {}               -- 每台最近打印过的状态签名，变了才打

local function finish_dispatch(f, stx, dq)
  stx.phase = "farming"
  stx.crop = dq.crop
  stx.pending = dq.n
  stx.since = now()
  stx.since_u = upsec()
  stx.dq = nil
  stx.fails = nil          -- 成功一次就把失败退避清零
  stx.prod_base = nil      -- 下一 tick 记本场产物基线
  PATLOCK[dq.crop] = nil
  save()
  say("[切换] 农场 %d → Farm 模式（第 %d 轮，作物 %s）", f.id, stx.cycles + 1, dq.crop)
end

-- 发配中途放弃：样板尽量还给仓库、清掉这台流水线状态，退回 input 等下一轮分配。
-- 不 fatal：一个农场的一次发配失败不该拖垮其它农场（AE 偶发失败/采样窗口撞上会自愈）
local function abort_dq(f, stx, why)
  local dq = stx.dq
  if dq and dq.crop and (dq.step == "cpu" or dq.step == "suck") and dq.fei and dq.whi then
    local okb, mb = PAT:move(dq.fei, 0, dq.whi, dq.wh_slot or 0)   -- 尽力搬回
    if not okb then say("[警告] 农场 %d 样板搬回仓库失败：%s", f.id, tostring(mb)) end
  end
  if dq and dq.crop then PATLOCK[dq.crop] = nil end
  stx.dq = nil
  stx.phase = "input"
  stx.prod_base = nil
  -- 连续失败就歇一会再试，避免同一个问题无限重发刷屏（基数 30 秒，最多 15 分钟）
  stx.fails = (stx.fails or 0) + 1
  stx.cool_until = upsec() + math.min(30 * stx.fails, 900)
  save()
  say("[错误] 农场 %d 发配中断：%s（已退回 input，%d 秒后再试）", f.id, tostring(why),
    math.floor(math.max(0, (stx.cool_until or 0) - upsec())))
end

-- 读"某作物在网络里的种子数量"（先试带 label 的过滤查询，失败再全量扫）
local function count_seeds_for(crop)
  local n, got = 0, false
  local q = A:query("seed", { label = tostring(crop) .. "种子" })
  if q and #q > 0 then
    got = true
    for _, s in ipairs(q) do
      if s.name == "cropsnh:genericSeed" then n = n + (s.size or 0) end
    end
  end
  if not got then
    local sd2 = A:seeds_by_label("seed")[crop]
    n = sd2 and sd2.count or 0
  end
  return n
end

-- 推进一台农场的发配流水线（每 tick 一步，别的农场照常轮询）
local function advance_dq(f, stx)
  local dq = stx.dq
  if not dq then return end
  local u = upsec()

  -- 流水线看门狗：任何一步卡住太久就放弃这台，别把样板/状态占死。
  -- 现在是真实秒口径，而大单（几千颗）光 AE 推原料就要十几二十分钟，给足 2 小时
  if u - (dq.created or u) > 7200 then
    abort_dq(f, stx, string.format("发配流水线卡了 %.0f 秒没走完（卡在 %s）", u - dq.created, tostring(dq.step)))
    return
  end

  if dq.step == "slot" then
    local slot, serr = PAT:slot_for(dq.crop, dq.seed)
    if not slot then
      abort_dq(f, stx, "拿不到样板槽位：" .. tostring(serr))
      return
    end
    local whi, fei = PAT:warehouse(), PAT:farm(f.id)
    if not whi then abort_dq(f, stx, "没找到仓库接口（检查 config.ae.warehouse_name 或接口名）") return end
    if not fei then abort_dq(f, stx, string.format("没找到农场 %d 的下单接口（检查 farms[].interface_name）", f.id)) return end
    local okm, mmsg = PAT:move(whi, slot, fei, 0)
    if not okm then
      abort_dq(f, stx, "搬样板失败：" .. tostring(mmsg))
      return
    end
    say("[搬样] 仓库槽 %s → 农场 %d 下单接口", tostring(slot), f.id)
    dq.slot, dq.fei, dq.whi = slot, fei, whi
    dq.wh_slot = slot
    dq.step = "cpu"
    dq.cpu_t0 = upsec()   -- 从搬样完成起算，别把搬样耗时算进等 CPU
    return
  end

  if dq.step == "cpu" then
    local free, total = A:free_cpus()
    if total == 0 or free > 0 then
      local waited = u - (dq.cpu_t0 or u)
      if waited >= 1 then
        say("[发配] 农场 %d：合成 CPU 空出来了（等了 %.0f 秒）", f.id, waited)
      end
      local job, jerr = A:request("seed", dq.label, dq.n)
      if not job then
        abort_dq(f, stx, string.format("下单失败：%s（检查样板是否在种子网络、产物名是不是「%s」）", tostring(jerr), dq.label))
        return
      end
      say("[下单] 农场 %d：%s ×%d（%d 份 × %d 颗），等 CPU 任务完成后再 +1 秒",
        f.id, dq.label, dq.n, dq.batches, dq.mult)
      dq.job = job
      dq.step = "suck"
      dq.t0 = u
      return
    end
    local waited = u - (dq.cpu_t0 or u)
    if u - (dq.cpu_warn_at or 0) >= 5 then
      dq.cpu_warn_at = u
      say("[等待] 合成 CPU 全被占用（%d 个，已等 %.0f 秒），空出来就下单", total, waited)
    end
    if waited > 900 then
      abort_dq(f, stx, string.format("合成 CPU 等了 900 秒仍全被占用（共 %d 个）", total))
      return
    end
    return
  end

  if dq.step == "suck" then
    -- 发配完成的权威信号：job isDone（伪合成卡一发完原料就 isDone），再 +1 秒让输入总线吸进机器
    if not dq.job_done then
      local done = job_flag(dq.job, "isDone") == true
      local failed, failReason = job_flag2(dq.job, "hasFailed")
      local canceled, cancelReason = job_flag2(dq.job, "isCanceled")
      local computing = job_flag(dq.job, "isComputing") == true
      local whyj = tostring(cancelReason or failReason or "无")
      -- 只有 fail() 写进去的 "request failed (...)" 才是 AE 的真失败原因；
      -- "no link" 是 CraftingStatus 的默认占位（任务对象没绑定合成链接），不算失败。
      local realFail = whyj:find("request failed", 1, true) ~= nil
      if done then
        -- isDone 才是权威的完成信号：AE 有时先报 failed/取消、后来又 done（误判）
        dq.job_done = true
        dq.job_done_u = u
        say("[发配] 农场 %d：CPU 任务完成，再等 1 秒让输入总线吸完", f.id)
      elseif failed or canceled then
        -- AE 的任务状态经常误报：真失败（request failed…）与"no link"占位都不据此中断，
        -- 按"已发配"往下走，交给农场实际表现验证（开工=成功；一直不开工=work 步超时吐料重发）。
        local moved0 = math.max(0, dq.seedBefore - count_seeds_for(dq.crop))
        if realFail then
          say("[发配] 农场 %d：AE 报任务%s（原因：%s；种子已推进 %d 颗）→ 按已发配处理；开工失败会自动吐料重发",
            f.id, canceled and "取消" or "失败", whyj, moved0)
        else
          say("[发配] 农场 %d：任务状态=%s（原因：%s，computing=%s；种子已推进 %d 颗）→ 无有效失败信息，按已发配处理",
            f.id, canceled and "取消" or "失败", whyj, tostring(computing), moved0)
        end
        dq.job_done = true
        dq.job_done_u = u
      elseif computing then
        -- 还在提交/推料中：继续等
        if u - (dq.t0 or u) > 3600 then
          abort_dq(f, stx, "下单后 3600 秒 CPU 任务还没完成")
          return
        end
        return
      else
        -- 大单（上千颗）AE 光把原料推进接口就要十几分钟（现在按真实秒计），给 1 小时
        if u - (dq.t0 or u) > 3600 then
          abort_dq(f, stx, "下单后 3600 秒 CPU 任务还没完成")
          return
        end
        return
      end
    end
    if u - dq.job_done_u < 1 then return end
    -- 自检①：网络种子数差值仍是"有没有真发出去"的主要信号，但它会被并发回收/吸种干扰，
    -- 所以给 120 秒观察窗口：计数下降或机器开工都算送到；窗口内啥都没有才判没送进去 → 吐料重发。
    local seedAfter = count_seeds_for(dq.crop)
    local moved = dq.seedBefore - seedAfter
    local mult = dq.mult or 1
    if moved <= 0 then
      local since = u - (dq.job_done_u or u)
      local hw = nil
      if since >= 120 and not DRY then hw = F:is_working(f.gt) end
      if since >= 120 and hw == true then
        say("[发配] 农场 %d：种子数没降但机器已在干活 → 按已发配处理", f.id)
      elseif since >= 120 then
        say("[警告] 农场 %d：发配后 120 秒种子数没降、机器也没开工 → 判定种子没送进去，切 Output 吐料重发", f.id)
        if dq.fei and dq.whi then
          local okb = PAT:move(dq.fei, 0, dq.whi, dq.wh_slot or 0)
          if okb then say("[搬样] 农场 %d 样板已搬回仓库", f.id) end
          if PATLOCK[dq.crop] then PATLOCK[dq.crop] = nil end
        end
        if not DRY then F:pulse(f.redstone, T.pulse_width, f.redstone_side) end
        dq.step = "dump"
        dq.dump_goal = dq.seedBefore or 0
        dq.dump_t0 = u
        return
      else
        return   -- 观察窗口内，继续等（种子可能正在被吸进机器）
      end
    elseif moved < mult then
      -- 只推进了不到一批：不拿这几颗硬开工（浪费产能），吐料重发
      say("[警告] 农场 %d 只发出去 %d 颗（不到一批 %d 颗）→ 切 Output 吐料重发", f.id, moved, mult)
      if dq.fei and dq.whi then
        local okb2 = PAT:move(dq.fei, 0, dq.whi, dq.wh_slot or 0)
        if okb2 then say("[搬样] 农场 %d 样板已搬回仓库", f.id) end
        if PATLOCK[dq.crop] then PATLOCK[dq.crop] = nil end
      end
      if not DRY then F:pulse(f.redstone, T.pulse_width, f.redstone_side) end
      dq.step = "dump"
      dq.dump_goal = dq.seedBefore or 0
      dq.dump_t0 = u
      return
    elseif moved < dq.n then
      say("[警告] 农场 %d 只发出去 %d / %d 颗，按实际数量记", f.id, moved, dq.n)
      dq.n = moved
    end
    -- ② 台账：记一条"在制任务"（按农场过滤，别的农场同作物不挡路）
    local trec = TASKS:add({ crop = dq.crop, farm = f.id, n = dq.n, label = dq.label })
    stx.task_id = trec.id
    -- 样板使命完成：搬回仓库，别占着农场接口（发配已结束，搬走不会打断）
    local okb, mb = PAT:move(dq.fei, 0, dq.whi, dq.wh_slot or 0)
    if okb then
      say("[搬样] 农场 %d 样板已搬回仓库", f.id)
    else
      say("[警告] 农场 %d 样板搬回仓库失败：%s", f.id, tostring(mb))
    end
    dq.step = "pulse"
    return
  end

  if dq.step == "dump" then
    -- 等吐出的原料回到种子网络（回到下单前的存量就算吐完），再切回 Input 重新排队
    local back = count_seeds_for(dq.crop)
    if back >= (dq.dump_goal or 0) then
      if not DRY then
        local ok3, e3 = F:pulse(f.redstone, T.pulse_width, f.redstone_side)   -- Output → Input
        if not ok3 then say("[警告] 农场 %d 切回 Input 脉冲失败：%s", f.id, tostring(e3)) end
      end
      say("[清料] 农场 %d：吐回的原料已回到种子网络（种子 %d），下一轮重新发配", f.id, back)
      abort_dq(f, stx, "发配失败，已把原料吐回网络，重新排队")
      return
    end
    if u - (dq.dump_t0 or u) > 600 then
      say("[警告] 农场 %d：等原料吐回超时（种子 %d < %d），先切回 Input", f.id, back, dq.dump_goal or 0)
      if not DRY then F:pulse(f.redstone, T.pulse_width, f.redstone_side) end
      abort_dq(f, stx, "发配失败，等原料吐回超时")
      return
    end
    return
  end

  if dq.step == "pulse" then
    -- 自检②：红石能不能真的点动工具台（吸种子的等待已在下单后完成）
    local ok2, perr = F:pulse(f.redstone, T.pulse_width, f.redstone_side)
    if not ok2 then
      abort_dq(f, stx, string.format("红石脉冲失败：%s（检查红石 I/O 端口地址、端口是否贴着活化工具台）", tostring(perr)))
      return
    end
    -- 切 Farm 之后默认"关→开"一次工作开关（软锤）：
    -- CropsNH 工业农场经常出现"模式对了、种子也进去了，但就是不开工，
    -- 必须玩家开关一次 GUI 才恢复"的状态不刷新问题。每次切 Farm 都强制刷新一次，
    -- 不等它卡住再救（用户要求：干脆写成默认自动刷新）。
    if not DRY then
      os.sleep(0.3)
      local okk, kerr = F:set_work_allowed(f.gt, false)
      if okk then
        os.sleep(0.5)
        F:set_work_allowed(f.gt, true)
        os.sleep(0.3)
        say("[刷新] 农场 %d：已切 Farm 并自动关→开工作开关（防卡死不工作）", f.id)
      else
        note("qqkick:" .. f.id, "[刷新] 农场 %d 切换工作开关失败（%s），跳过自动刷新", f.id, tostring(kerr))
      end
    end
    dq.step = "work"
    dq.work_t0 = upsec()
    dq.saw_false = false
    return
  end

  if dq.step == "work" then
    -- 切 Farm 之后确认机器真的开工；大单（几千颗）光吸进机器就要一阵子，
    -- 所以给足 120 秒，中途只说一声、不折腾模式（来回切会把刚吸进去的种子搅乱）
    local hw, hwhy = F:is_working(f.gt)
    if hw == true then
      say("[确认] 农场 %d 已开工（%s）", f.id, tostring(hwhy))
      finish_dispatch(f, stx, dq)
      return
    end
    if hw == false then dq.saw_false = true end
    local waited_w = u - (dq.work_t0 or u)
    if waited_w >= 300 and not dq.warn1 then
      dq.warn1 = true
      say("[等待] 农场 %d 切 Farm 后 300 秒机器还没开工（种子可能还在吸），继续等", f.id)
      return
    end
    if waited_w >= 900 then
      -- 15 分钟还没开工：种子多半白推进去了。切 Output 把原料吐回网络，再重新排队，
      -- 不拿机器里那点种子硬开工（浪费产能）。
      say("[警告] 农场 %d 切 Farm 后 900 秒机器还没开工 → 切 Output 吐料，重新排队", f.id)
      if not DRY then
        local okp = F:pulse(f.redstone, T.pulse_width, f.redstone_side)
        if not okp then
          abort_dq(f, stx, "等开工超时且红石脉冲失败")
          return
        end
      end
      dq.dump_goal = dq.seedBefore or 0
      dq.dump_t0 = u
      dq.step = "dump"
      return
    end
    return
  end

  -- 未知子步（理论上到不了）：当发配失败处理，退回 input
  abort_dq(f, stx, string.format("流水线子步未知（%s）", tostring(dq.step)))
end

local function advance_farming(f, stx, prod, seeds, allSeed)
  local th = cfg.thresholds[stx.crop] or {}
  local h = th.high or 512
  local cur = prod[th.product or stx.crop]
  cur = cur and cur.count or 0
  local u = upsec()

  -- 产物一旦变化就记下时间；用来判断"卡住"（机器不干活、产物不涨）
  if (stx.last_prod or -1) ~= cur then
    stx.last_prod = cur
    stx.last_prod_u = u
    save()
  end

  -- 收割判据沿用旧逻辑：存储网里该产物总量 ≥ high 就收（多台并行只是为了更快到量）。
  -- 同作物回收串行：另一台正在收，我先继续长着，等它收完（防两台同时收把对账搅乱）。
  if cur >= h then
    if RECLAIM[stx.crop] and RECLAIM[stx.crop] ~= f.id then
      local ro = ST.farms[RECLAIM[stx.crop]]
      if ro and ro.phase == "reclaim" then
        note("rq:" .. f.id, "[等待] 农场 %d：%s 正在被农场 %d 回收，等它收完再收（继续长着）",
          f.id, tostring(stx.crop), RECLAIM[stx.crop])
        return
      else
        RECLAIM[stx.crop] = nil   -- 陈旧锁（那台农场已经不在回收了），清掉
      end
    end
    note_clear("rq:" .. f.id)
    RECLAIM[stx.crop] = f.id
    stx.got_peak = nil
    stx.got_u = nil
    if not DRY then
      local ok2, perr = F:pulse(f.redstone, T.pulse_width, f.redstone_side)
      if not ok2 then
        fatal(stx, "切 Output 时红石脉冲失败：%s", tostring(perr))
        return
      end
    end
    -- 记下"切 Output 那一刻"网络里已有的该作物种子数：
    -- 回收要靠"增量"，不能用绝对值比（网络里原本就有剩余种子）
    local bs = stx.crop and seeds[stx.crop]
    stx.seed_base = bs and bs.count or 0
    local ciT = stx.crop and cropinfo(stx.crop) or {}
    local subT = ciT.subsoil and allSeed[ciT.subsoil] or nil
    stx.sub_base = subT and subT.count or 0
    stx.phase = "reclaim"
    stx.since = now()
    stx.since_u = u
    stx.warned = nil
    stx.reclaim_ticks = 0
    save()
    say("[切换] 农场 %d → Output 模式（产物 %d/%d，回收上限 %d 秒）", f.id, cur, h,
      math.floor((cfg.timing and cfg.timing.reclaim_timeout) or 180))
  elseif u - (stx.since_u or u) > T.grow_timeout then
    local gs = u - (stx.since_u or u)
    say("[警告] 农场 %d 生长超时 %d 秒，检查农场/供电", f.id, math.floor(gs))
    stx.since = now()
    stx.since_u = u
    save()
  else
    -- 不用"产物增长"判断农场是否在运行：有些作物十几轮才出一个产物，产物不动不代表没跑。
    -- 只有传感器明确说 is_working=false 时才记一行观察，不自动改状态、不切模式。
    -- 性能：is_working 内部 os.sleep(1.5) 双采样，绝不能每 tick 都调（3 台 farming 每 tick
    -- 白睡 4.5 秒，机器就卡、q q 都退不出去）。改成每台约 25 秒查一次，并错开相位。
    if not DRY then
      local hwiv = 25 + ((f.id or 0) % 3) * 4
      if u - (stx.hw_at or 0) >= hwiv then
        stx.hw_at = u
        local hw, why = F:is_working(f.gt)
        if hw == false then
          -- 时长按 30 秒一档量化，不然每秒都会因为数字变化重打一遍
          local ndur = math.floor((u - (stx.since_u or u)) / 30) * 30
          note("notwork:" .. f.id, "[观察] 农场 %d 传感器说没在干活（阶段=farming 作物=%s，已约 %d 秒）：%s",
            f.id, tostring(stx.crop), ndur, tostring(why))
        else
          note_clear("notwork:" .. f.id)
        end
      end
    end
  end
end

local function advance_reclaim(f, stx, seeds, allSeed)
  local ci2 = stx.crop and cropinfo(stx.crop) or {}
  local sd = stx.crop and seeds[stx.crop]
  local back = sd and sd.count or 0
  local base = stx.seed_base or 0
  local got = back - base          -- 真正回来的数量（增量），而不是网络里的总数
  if got < 0 then got = 0 end
  local pending = stx.pending or 0
  -- 计时用 upsec()（单调秒，开机后不回退）；os.time() 在 OpenOS 里偶尔不可靠
  local uNow = upsec()
  local waited = uNow - (stx.since_u or uNow)
  if waited < 0 then waited = 0 end
  local hard = (cfg.timing and cfg.timing.reclaim_timeout) or 180
  -- 第一轮不判超时：慢读本身可能就要几十秒，先完整观察一轮再说
  stx.reclaim_ticks = (stx.reclaim_ticks or 0) + 1
  local first_tick = stx.reclaim_ticks < 2
  local subBackN = 0

  -- 种子回收的"完成"有两种：全回来；或者回来的数稳定不动了（其余已被机器种下，
  -- 留在机器里继续长，收不回来是正常的——以前死等全量会卡在回收里出不来）。
  if got > (stx.got_peak or -1) then
    stx.got_peak = got
    stx.got_u = uNow
    save()
  end
  local no_prog = uNow - (stx.got_u or stx.since_u or uNow)
  if no_prog < 0 then no_prog = 0 end
  local stable = pending > 0 and got > 0 and no_prog >= 60

  if pending > 0 and (got >= pending or stable) then
    -- 种子已经全部回到种子网络：这才是"完成"
    if not DRY then
      local ok2, perr = F:pulse(f.redstone, T.pulse_width, f.redstone_side)
      if not ok2 then
        fatal(stx, "切回 Input 时红石脉冲失败：%s", tostring(perr))
        return
      end
    end
    if ci2.subsoil and stx.crop then
      local sb = allSeed[ci2.subsoil]
      local subBack = (sb and sb.count or 0) - (stx.sub_base or 0)
      if subBack < 0 then subBack = 0 end
      subBackN = subBack
      if subBack < pending then
        say("[警告] 农场 %d 垫块没回齐，还差 %d 个（种子已齐，说明垫块可能卡在机器或输出总线里）", f.id, math.floor(pending - subBack))
      end
    end
    local parts = { string.format("种子 %d/%d", math.floor(got), math.floor(pending)) }
    if ci2.subsoil then
      parts[#parts + 1] = string.format("垫块 %d/%d", math.floor(subBackN or 0), math.floor(pending))
    end
    local partial = (pending > 0 and got < pending)
    say("[回收] 农场 %d %s：%s%s", f.id, tostring(stx.crop or "-"), table.concat(parts, " · "),
      partial and "（其余已种下/在机器里，继续长）" or "")
    say("[完成] 农场 %d 第 %d 轮（网络原有 种子 %d · 垫块 %d）", f.id, stx.cycles + 1, base, stx.sub_base or 0)
    say("[切换] 农场 %d → Input 模式", f.id)
    if stx.task_id then TASKS:finish(stx.task_id); stx.task_id = nil end
    if stx.crop and RECLAIM[stx.crop] == f.id then RECLAIM[stx.crop] = nil end
    stx.phase = "input"
    stx.crop = nil
    stx.pending = 0
    stx.warned = nil
    stx.retried = nil
    stx.since = now()
    stx.cycles = stx.cycles + 1
    stx.got_peak = nil
    stx.got_u = nil
    save()
  elseif waited >= hard and not first_tick and no_prog >= 300 then
    -- ③ 自愈：超时不代表一定坏，可能是"脉冲没点上、模式还停在 Farm"。
    --    先补一次 Output 脉冲再等一轮，两次都不行才放弃。
    if not stx.retried then
      local ok2b, perr2 = true, nil
      if not DRY then ok2b, perr2 = F:pulse(f.redstone, T.pulse_width, f.redstone_side) end
      stx.retried = true
      stx.since_u = upsec()
      save()
      say("[警告] 农场 %d 回收超时 %d 秒（种子 %d/%d），补一次 Output 脉冲再等 30 秒%s",
        f.id, math.floor(waited), got, pending, ok2b and "" or ("（脉冲本身失败：" .. tostring(perr2) .. "）"))
    else
      if not DRY then
        local ok2, perr = F:pulse(f.redstone, T.pulse_width, f.redstone_side)
        if not ok2 then
          fatal(stx, "强制切回 Input 时红石脉冲失败：%s", tostring(perr))
          return
        end
      end
      say("[错误] 农场 %d 回收超时 %d 秒：种子 %d/%d（网络原有 %d）。已强制切回 Input，请自检",
        f.id, math.floor(waited), got, pending, base)
      if stx.task_id then TASKS:finish(stx.task_id); stx.task_id = nil end
      if stx.crop and RECLAIM[stx.crop] == f.id then RECLAIM[stx.crop] = nil end
      stx.phase = "input"
      stx.crop = nil
      stx.pending = 0
      stx.warned = nil
      stx.retried = nil
      stx.since = now()
      stx.cycles = stx.cycles + 1
      stx.got_peak = nil
      stx.got_u = nil
      save()
    end
  elseif waited >= T.reclaim_wait and not stx.warned then
    say("[等待] 农场 %d 回收已 %d 秒：种子 %d/%d，继续等（上限 %d 秒）",
      f.id, math.floor(waited), got, pending, math.floor(hard))
    stx.warned = true
    save()
  end
end

-- ===== 分配器（每 tick 一次）：§9.3 装箱 + 抢占 =====
-- ASSIGN 是运行时表（不落盘）：重启后分配器重算，丢了也不影响状态机
local ASSIGN = {}   -- [农场id] = { crop, n, out, mult, subsoil }

local function allocator(seeds, allSeed, prod, sinfo)
  -- ① 农场不再空闲（有 dq / 阶段变了）就作废它的 assign
  for fid in pairs(ASSIGN) do
    local s = ST.farms[fid]
    if not s or s.phase ~= "input" or s.dq then ASSIGN[fid] = nil end
  end

  local cands = candidates(prod, seeds, allSeed)
  if #cands == 0 then return end

  -- ② 空闲农场 = input、无 dq、还没 assign；按等级降序（高等级先装满，尽量少占农场）
  local idle = {}
  for _, f in ipairs(cfg.farms) do
    local s = ST.farms[f.id]
    if f.enabled ~= false and s and s.phase == "input" and not s.dq and not ASSIGN[f.id]
       and not (s.cool_until and upsec() < s.cool_until) then
      local info = sinfo[f.id]
      if info then
        idle[#idle + 1] = { fid = f.id, level = info.level or 0, cap = info.capacity or 0 }
      end
    end
  end
  table.sort(idle, function(a, b)
    if a.level ~= b.level then return a.level > b.level end
    return a.fid < b.fid
  end)

  -- ③ 可用种子/垫块 = 网络存量 − 已 assign 还没执行的份额；
  --    同时记下"哪些作物已经有农场在排队领任务了"（不算没农场，不触发抢占）
  local seedsLeft, subLeft, reserved = {}, {}, {}
  for c, q in pairs(seeds) do seedsLeft[c] = q.count end
  for lbl, q in pairs(allSeed) do subLeft[lbl] = q.count end
  for fid, asg in pairs(ASSIGN) do
    seedsLeft[asg.crop] = (seedsLeft[asg.crop] or 0) - asg.n
    if asg.subsoil then subLeft[asg.subsoil] = (subLeft[asg.subsoil] or 0) - asg.n end
    reserved[asg.crop] = true
  end

  -- ④ 有农场正在回收的作物：整作物先不发（网络是共享的，任何新下单都会
  --    吃掉别人正在等的"回收增量"，害它超时）
  local reclaiming = {}
  for _, f2 in ipairs(cfg.farms) do
    local s2 = ST.farms[f2.id]
    if s2 and s2.phase == "reclaim" and s2.crop then reclaiming[s2.crop] = true end
  end

  -- ⑤ 贪心装箱：候选按（层序 + 缺口比例降序）轮着来，每个候选每轮最多占一台空农场。
  --    同一时刻最多只有一份样板能跑一种作物（别的农场排队等样板），所以先把不同作物铺开，
  --    让橡树和空间之花这类互不相干的作物真正并行；同一作物多台农场仍排队（样板互斥）。
  local unsatisfied = {}
  local cinfo = {}
  for _, cd in ipairs(cands) do
    local mult = A:craftable_mult("seed", cd.out)
    if not mult or mult < 1 then mult = math.floor(cd.mult or 0) end
    if not mult or mult < 1 then mult = 1 end
    cinfo[cd.crop] = mult
  end
  local batch = (cfg.timing and cfg.timing.batch) or 0
  local maxItems = (cfg.timing and cfg.timing.max_items) or 0
  local progressed = true
  while progressed and #idle > 0 do
    progressed = false
    for _, cd in ipairs(cands) do
      if #idle == 0 then break end
      if not reclaiming[cd.crop] then
        note_clear("reclaim_wait:" .. cd.crop)
        local mult = cinfo[cd.crop]
        -- 输入总线推满了只会卡住（推送目标已满），农场消化掉就继续，不算失败；
        -- 所以不再按 max_items 卡单次发配量，只保留一个可选的上限配置（0=不限）
        local itemCap = math.huge
        if maxItems > 0 then itemCap = math.floor(maxItems / mult) * mult end
        local i = 1
        while i <= #idle do
          local fe = idle[i]
          if fe.level < cd.bed then
            cd._level = true
            i = i + 1
          else
            local haveS = seedsLeft[cd.crop] or 0
            local haveSub = cd.subsoil and (subLeft[cd.subsoil] or 0) or math.huge
            -- 农场容量按种子数算（用户实测：机器能装 3k+ 颗种子），一批 = mult 颗种子
            local capSeeds = (mult > 1) and (math.floor(fe.cap / mult) * mult) or math.floor(fe.cap)
            local avail = math.min(haveS, haveSub, capSeeds, itemCap)
            if batch > 0 then avail = math.min(avail, batch) end
            local n = (mult > 1) and (math.floor(avail / mult) * mult) or math.floor(avail)
            if n > 0 then
              if TASKS:inflight(cd.crop, fe.fid) == 0 then
                ASSIGN[fe.fid] = { crop = cd.crop, n = n, out = cd.out, mult = mult, subsoil = cd.subsoil }
                seedsLeft[cd.crop] = haveS - n
                if cd.subsoil then subLeft[cd.subsoil] = haveSub - n end
                table.remove(idle, i)
                cd._got = true
                progressed = true
                break      -- 这个候选本轮先拿一台，剩下的轮给别的作物
              else
                i = i + 1  -- 这台对这个作物有在制，跳过这台（别的农场不受影响）
                cd._busy = cd._busy or {}
                cd._busy[fe.fid] = TASKS:inflight(cd.crop, fe.fid)
              end
            else
              if fe.cap >= mult then cd._short = true else cd._small = true end
              i = i + 1    -- 这台容量/存量不够凑一份，看下一台
            end
          end
        end
      else
        note("reclaim_wait:" .. cd.crop, "[等待] %s 等农场回收完再发（避免抢走别人正在等的种子）", cd.crop)
      end
    end
  end
  -- 没分到农场的候选：能分的都分完了，剩下的要么凑不满/等级不够，要么没空闲农场（留给抢占）
  for _, cd in ipairs(cands) do
    if cd._got then
      note_clear("sub:" .. cd.crop)
      note_clear("short:" .. cd.crop)
      note_clear("level:" .. cd.crop)
      note_clear("small:" .. cd.crop)
      note_clear("busy:" .. cd.crop)
    elseif cd._short then
      note("short:" .. cd.crop, "[跳过] %s 凑不满 1 份（1 份需 %d 颗，当前只能凑 %d 颗）", cd.crop, cinfo[cd.crop],
        math.floor(math.min(seedsLeft[cd.crop] or 0, cd.subsoil and (subLeft[cd.subsoil] or 0) or math.huge)))
    elseif cd._level and #idle == 0 then
      note("level:" .. cd.crop, "[跳过] %s 需要苗床等级 %d，没有够格的空闲农场", cd.crop, math.floor(cd.bed))
    elseif cd._small and #idle == 0 then
      note("small:" .. cd.crop, "[跳过] %s 一份要 %d 颗种子，所有空闲农场容量都不够一份", cd.crop, cinfo[cd.crop])
    elseif cd._busy then
      local fids = {}
      for fid2 in pairs(cd._busy) do fids[#fids + 1] = tostring(fid2) end
      note("busy:" .. cd.crop, "[跳过] %s：农场 %s 还挂着在制台账，这些农场先不接这个作物", cd.crop, table.concat(fids, ","))
    elseif #idle == 0 and not reserved[cd.crop] then
      unsatisfied[#unsatisfied + 1] = cd   -- 有农场排队领它了，就不算"没农场"
    end
  end

  -- ⑥ 抢占：高优先作物有种子却没农场可用，就把在种更低优先作物的农场挤下来。
  --    受害者 = 作物层号最大（最不优先）者中、农场等级最高的那台；
  --    刚开工不到 60 秒的不抢；同一台 30 秒内最多被抢一次。
  if #unsatisfied > 0 then
    local top = unsatisfied[1]
    local topLayer = layer_of(top.crop)
    local uNow = upsec()
    local victim = nil
    for _, f in ipairs(cfg.farms) do
      local s = ST.farms[f.id]
      -- 只抢"真的能接住这个作物"的农场（等级够格），不然挤下来也种不上
      local flv = sinfo[f.id] and sinfo[f.id].level or 0
      if f.enabled ~= false and s and s.phase == "farming" and s.crop
         and (uNow - (s.since_u or 0)) >= 60 and flv >= top.bed then
        local li = layer_of(s.crop)
        if li > topLayer then
          local lv = sinfo[f.id] and sinfo[f.id].level or 0
          local better = false
          if not victim then
            better = true
          else
            local vs = ST.farms[victim]
            local vli = vs and layer_of(vs.crop or "") or 0
            local vlv = victim and (sinfo[victim] and sinfo[victim].level or 0) or 0
            better = li > vli or (li == vli and lv > vlv)
          end
          if better then victim = f.id end
        end
      end
    end
    if victim then
      local vs = ST.farms[victim]
      if uNow - (vs.last_preempt or 0) >= 30 then
        local fv
        for _, ff in ipairs(cfg.farms) do if ff.id == victim then fv = ff break end end
        if not DRY then
          local okp, perr = F:pulse(fv.redstone, T.pulse_width, fv.redstone_side)
          if not okp then
            fatal(vs, "抢占切 Output 时红石脉冲失败：%s", tostring(perr))
            return
          end
        end
        local ciV = cropinfo(vs.crop)
        local bs = vs.crop and seeds[vs.crop]
        vs.seed_base = bs and bs.count or 0
        local subT = ciV.subsoil and allSeed[ciV.subsoil] or nil
        vs.sub_base = subT and subT.count or 0
        vs.phase = "reclaim"
        vs.since = now()
        vs.since_u = uNow
        vs.warned = nil
        vs.reclaim_ticks = 0
        vs.last_preempt = uNow
        save()
        say("[抢占] 农场 %d 在种 %s（第 %d 层，优先级低），让位给第 %d 层的 %s（种子 %d 颗没地用），切 Output 回收",
          victim, tostring(vs.crop), layer_of(vs.crop), topLayer, top.crop, math.floor(top.seeds))
      end
    end
  end
end

local function advance_inner(f, stx, seeds, allSeed, prod, info, serr)
  if not info then
    note("sensor:" .. f.id, "[错误] 农场 %d 读不到传感器：%s", f.id, tostring(serr))
    return
  end
  note_clear("sensor:" .. f.id)

  -- 正在流水线里的：先推进发配，其它状态不动。
  -- 同一个 tick 里把不阻塞的子步（搬样/下单/脉冲）一口气推完，别一台农场每 tick 只走一步，
  -- 不然几台农场排队发配看起来就是串行。推到阻塞点（等 CPU/等任务完成/等开工）自动停下。
  if stx.dq then
    local guard = 0
    repeat
      local step = stx.dq.step
      advance_dq(f, stx)
      guard = guard + 1
    until not stx.dq or stx.dq.step == step or guard > 50
    return
  end

  if stx.phase == "farming" then
    advance_farming(f, stx, prod, seeds, allSeed)
    return
  elseif stx.phase == "reclaim" then
    advance_reclaim(f, stx, seeds, allSeed)
    return
  end

  -- phase == "input"：分配器给没给任务？给了就认领流水线（DRY 只打印不动作）
  local asg = ASSIGN[f.id]
  if not asg then return end

  -- 认领前复核：这作物已经被别的农场喂饱了（产物冲过 low），任务作废，别多种一轮
  local thC = cfg.thresholds[asg.crop] or {}
  local prodC = prod[thC.product or asg.crop]
  if prodC and prodC.count >= (thC.low or 64) then
    ASSIGN[f.id] = nil
    return
  end

  if DRY then
    note("dry:" .. f.id .. ":" .. asg.crop .. ":" .. asg.n,
      "[试运行] 农场 %d 会下单 %s ×%d（mult=%d）", f.id, zh(asg.out), asg.n, asg.mult)
    return
  end

  -- 认领时按"当前网络实际种子数/垫块数"复核下发量：分配是几秒前算的，别的农场可能已经吃掉一部分
  local seedNow = (seeds[asg.crop] and seeds[asg.crop].count) or 0
  local subNow = asg.subsoil and ((allSeed[asg.subsoil] and allSeed[asg.subsoil].count) or 0) or math.huge
  local fitTo = math.floor(math.min(seedNow, subNow))
  local maxItems2 = (cfg.timing and cfg.timing.max_items) or 0
  if maxItems2 > 0 then
    fitTo = math.min(fitTo, math.floor(maxItems2 / asg.mult) * asg.mult)
  end
  if asg.n > fitTo then
    local fit = (asg.mult > 1) and (math.floor(fitTo / asg.mult) * asg.mult) or fitTo
    if fit < 1 then
      ASSIGN[f.id] = nil
      note("short:" .. asg.crop, "[跳过] %s 网络种子/垫块凑不满一份（下一轮再看）", asg.crop)
      return
    end
    say("[调整] 农场 %d：%s 按网络实际存量下调，下发量 %d → %d", f.id, asg.out, asg.n, fit)
    asg.n = fit
  end

  -- 同一种作物全网只有一份生效样板：样板在别的农场手里时先排队，等它搬回仓库
  if PATLOCK[asg.crop] and PATLOCK[asg.crop] ~= f.id then
    note("pat:" .. f.id, "[排队] 农场 %d 等着发配（%s 的样板在农场 %d 手里）", f.id, asg.crop, PATLOCK[asg.crop])
    return
  end

  note_clear("pat:" .. f.id)
  PATLOCK[asg.crop] = f.id
  PATLOCK_since[asg.crop] = upsec()
  stx.fails = nil
  stx.cool_until = nil
  local seedBefore = (seeds[asg.crop] and seeds[asg.crop].count) or 0
  stx.dq = {
    step = "slot", crop = asg.crop, n = asg.n, label = asg.out, mult = asg.mult,
    seed = (seeds[asg.crop] and seeds[asg.crop].stack) or nil,
    batches = math.max(1, math.floor(asg.n / asg.mult)),
    seedBefore = seedBefore,
    t0 = upsec(),
    created = upsec(),
  }
  say("[分配] 农场 %d：%s ×%d（种子网剩 %d 颗）", f.id, zh(asg.out), asg.n, math.floor(seedBefore))
  ASSIGN[f.id] = nil
  local guard = 0
  repeat
    local step = stx.dq.step
    advance_dq(f, stx)
    guard = guard + 1
  until not stx.dq or stx.dq.step == step or guard > 50
end

local function advance(f, stx, seeds, allSeed, prod, info, serr)
  local before = string.format("%s|%s|%d", stx.phase, tostring(stx.crop), stx.cycles)
  advance_inner(f, stx, seeds, allSeed, prod, info, serr)
  local after = string.format("%s|%s|%d", stx.phase, tostring(stx.crop), stx.cycles)
  if after ~= before and after ~= sigs[f.id] then
    sigs[f.id] = after
    say("[状态] 农场 %d | 阶段=%s 作物=%s 已循环=%d%s", f.id, stx.phase, tostring(stx.crop), stx.cycles,
      DRY and " (试运行)" or "")
  end
end

-- ===== 仪表盘数据快照（每 tick 一次，纯内存拼接，不给轮询加负担）=====
local function ui_fmt_dur(sec)
  sec = math.max(0, math.floor(sec or 0))
  local h = math.floor(sec / 3600)
  local m = math.floor((sec % 3600) / 60)
  local s = sec % 60
  if h > 0 then return string.format("%dh%02dm", h, m) end
  if m > 0 then return string.format("%dm%02ds", m, s) end
  return s .. "s"
end

local function ui_snapshot(seeds, allSeed, prod, sinfo, sinfoErr)
  -- 种子行：priority 顺序在前，网络里额外出现的作物排后面
  local seen, order = {}, {}
  for _, layer in ipairs(cfg.priority) do
    for _, c in ipairs(layer) do
      if not seen[c] then seen[c] = true; order[#order + 1] = c end
    end
  end
  for c in pairs(seeds) do
    if not seen[c] then seen[c] = true; order[#order + 1] = c end
  end
  -- 在制 = 台账未完成 + 已下地（农场 pending）
  local making, planted = {}, {}
  for _, t in ipairs(TASKS.list) do
    if t.state ~= "finished" then making[t.crop] = (making[t.crop] or 0) + math.floor(t.n or 0) end
  end
  for _, f in ipairs(cfg.farms) do
    local s = ST.farms[f.id]
    if s and s.crop and s.phase == "farming" then
      planted[s.crop] = (planted[s.crop] or 0) + math.floor(s.pending or 0)
    end
  end
  local srows = {}
  for _, c in ipairs(order) do
    local ci = cropinfo(c)
    local th = cfg.thresholds[c] or {}
    local product = th.product or c
    local sd = seeds[c]
    local net = sd and math.floor(sd.count or 0) or 0
    local mk = making[c] or 0
    local pl = planted[c] or 0
    local sub = nil
    if ci.subsoil then
      sub = allSeed[ci.subsoil] and math.floor(allSeed[ci.subsoil].count or 0) or 0
    end
    local p = prod[product]
    srows[#srows + 1] = {
      crop = c, net = net, making = mk + pl, idle = math.max(0, net - mk - pl),
      sub = sub, prod = p and math.floor(p.count or 0) or 0,
      th = string.format("%d-%d", th.low or 64, th.high or 512),
    }
  end
  -- 农场行（异常置顶交给 ui.lua 排序）
  local frows = {}
  for _, f in ipairs(cfg.farms) do
    local s = ST.farms[f.id]
    if s then
      local info = sinfo[f.id]
      local phase = s.dq and ("发配·" .. tostring(s.dq.step)) or s.phase
      local fc = "white"
      if sinfoErr[f.id] then fc = "red"
      elseif s.dq or s.phase == "farming" then fc = "green"
      elseif s.phase == "reclaim" then fc = "yellow"
      elseif s.phase == "input" then fc = "gray" end
      frows[#frows + 1] = {
        id = f.id, lv = info and info.level, cap = info and info.capacity,
        phase = phase, crop = tostring(s.crop or ""),
        pending = math.floor((s.dq and s.dq.n or s.pending) or 0),
        dur = ui_fmt_dur(upsec() - (s.since_u or upsec())),
        cycles = s.cycles or 0,
        note = (sinfoErr[f.id] ~= nil and ("传感器:" .. tostring(sinfoErr[f.id]))) or (s.dq and ("步骤:" .. tostring(s.dq.step)) or ""),
        err = sinfoErr[f.id] ~= nil,
        fcolor = fc,
      }
    end
  end
  -- 告警板：从日志环捞最近的 [告警] 行（新→旧）
  local alarms = {}
  if UI then
    for i = #UI.ring, 1, -1 do
      local l = UI.ring[i]
      if l:find("[告警]", 1, true) then
        alarms[#alarms + 1] = l
        if #alarms >= 5 then break end
      end
    end
  end
  return { seeds = srows, farms = frows, alarms = alarms }
end

local alarm_t = 0            -- 主动告警节流：每 120 秒最多一轮
local SENSOR_CACHE = {}      -- 传感器读数缓存（等级/容量静态，别每 tick 都读）

local ok, err = pcall(function()
  while not stopping do
    boot_ticks = boot_ticks + 1
    -- 开机保持终端可见；跑满 2 个 tick 确认没卡住，才恢复上次开着的仪表盘
    if boot_ticks == 2 and UI and UI.ok and UI.on_pref then
      UI.on_pref = false
      UI:toggle(true)
    end
    local t_loop = upsec()
    if stop_flag() then
      stopping = true
      say("[停止] 检测到 stop 文件，退出")
      break
    end

    -- 阈值热改：set.lua 写过 limits.dat 就重新应用（一个轮询周期内生效）
    apply_limits(true)
    -- 优先级热改：set.lua prio 写过 priority.dat 就重新应用
    apply_priority(true)
    -- 红石端口热改：set.lua side 写过 farms.dat 就重新应用
    apply_farms(true)

    -- 每 tick 读两张网一次，所有农场共用
    local seeds, allSeed, prod, nSeedRaw = read_nets()
    local readSec = upsec() - t_loop
    if readSec >= 30 then
      say("[耗时] 读两张网用了 %.1f 秒（种子网 %d 种物品）", readSec, nSeedRaw)
    end

    if DRY then
      for _, layer in ipairs(cfg.priority) do
        for _, c in ipairs(layer) do
          local th = cfg.thresholds[c] or {}
          local p = prod[th.product or c]
          local sd = seeds[c]
          local ci2 = cropinfo(c)
          local sub = ci2.subsoil and allSeed[ci2.subsoil]
          local out = ci2.out or c
          say("[试运行] %s 产物=%s(low=%s high=%s) 种子=%s 垫块=%s 苗床需=%s | 下单目标=%s",
            c,
            tostring(p and p.count or 0), tostring(th.low or 64), tostring(th.high or 512),
            tostring(sd and sd.count or 0),
            ci2.subsoil and tostring(sub and sub.count or 0) or "(无需求)",
            tostring(ci2.bed or 0), zh(out))
          local entry, cerr = A:find_craftable_by_label("seed", out)
          if entry then
            say("[试运行]   → 样板可用")
          else
            say("[试运行]   → 样板查找失败：%s", tostring(cerr))
          end
        end
      end
    end

    -- 每台读传感器（分配器要看等级/容量，状态机也要用）；等级/容量是静态的，缓存 60 秒，
    -- 别每 tick 都读——GT 传感器读数有开销，读多了机器会卡。读失败不缓存，下 tick 重试。
    local sinfo, sinfoErr = {}, {}
    for _, f in ipairs(cfg.farms) do
      if f.enabled ~= false then
        local c = SENSOR_CACHE[f.id]
        if c and upsec() - c.at < 60 then
          sinfo[f.id] = c.info
        else
          local info, serr = F:read_sensor(f.gt)
          if info then
            SENSOR_CACHE[f.id] = { info = info, at = upsec() }
            sinfo[f.id] = info
          else
            SENSOR_CACHE[f.id] = nil
            sinfoErr[f.id] = serr
          end
        end
      end
    end

    -- 分配器：按优先级装箱，给空闲农场发 assign；必要时抢占低优先作物
    allocator(seeds, allSeed, prod, sinfo)

    for _, f in ipairs(cfg.farms) do
      if f.enabled ~= false then
        advance(f, ST.farms[f.id], seeds, allSeed, prod, sinfo[f.id], sinfoErr[f.id])
      end
    end

    -- ===== 主动告警（防呆：断粮/断垫块/样板卡死，别等出事了才发现）=====
    if upsec() - alarm_t >= 120 then
      alarm_t = upsec()
      local warns = {}
      local seenW = {}
      for _, layer in ipairs(cfg.priority) do
        for _, crop in ipairs(layer) do
          if not seenW[crop] then
            seenW[crop] = true
            local ciW = cropinfo(crop)
            -- 一份的份数别定死 45：以配置为准，没有就查样板，再没有才兜底 45
            local multW = math.floor(ciW.mult or 0)
            if not multW or multW < 1 then
              local m2 = A:craftable_mult("seed", ciW.out or crop)
              multW = (m2 and m2 >= 1) and math.floor(m2) or 45
            end
            -- 种子和垫块是一体的一批：在制(台账)+下地(机器里)两边共用
            local inflightW = TASKS:inflight(crop)
            local plantedW = 0
            for _, ff in ipairs(cfg.farms) do
              if ff.enabled ~= false then
                local sx = ST.farms[ff.id]
                if sx and sx.crop == crop and sx.pending then
                  plantedW = plantedW + (tonumber(sx.pending) or 0)
                end
              end
            end
            local sdW = seeds[crop]
            local sc = sdW and math.floor(sdW.count) or 0
            local totalSeed = sc + inflightW + plantedW
            local shortSeed = totalSeed < multW
            local subn, totalSub, shortSub = nil, 0, false
            if ciW.subsoil then
              local subW = allSeed[ciW.subsoil]
              subn = subW and math.floor(subW.count) or 0
              totalSub = subn + inflightW + plantedW
              shortSub = totalSub < multW
            end
            -- 种子和垫块一条路判断：凑不齐一份才告警（少量盈余/残留不算）
            if shortSeed or shortSub then
              local parts = {}
              if shortSeed then parts[#parts + 1] = string.format("种子剩 %d", totalSeed) end
              if shortSub then parts[#parts + 1] = string.format("垫块「%s」剩 %d", ciW.subsoil, totalSub) end
              warns[#warns + 1] = string.format("%s 凑不齐一份（%d）：%s；补料后自动恢复",
                crop, multW, table.concat(parts, "、"))
            end
          end
        end
      end
      for crop, fid in pairs(PATLOCK) do
        local held = upsec() - (PATLOCK_since[crop] or upsec())
        if held > 600 then
          warns[#warns + 1] = string.format("%s 的样板在农场 %d 手里超过 10 分钟（疑似卡住），可 lua reset.lua yes 清场", crop, fid)
        end
      end
      for i, w in ipairs(warns) do say("[告警] " .. w) end
    end

    if UI and UI.ok then
      UI:data(ui_snapshot(seeds, allSeed, prod, sinfo, sinfoErr))
    end

    local loopSec = upsec() - t_loop
    if loopSec >= 300 then say("[耗时] 本轮逻辑 %.1f 秒（不含轮询等待）", loopSec) end
    if not wait(T.poll) then break end
  end
end)

if not ok then
  ui_restore()
  local msg = tostring(err)
  if msg:find("interrupted", 1, true) then
    say("[停止] 被 Ctrl+C 中断，已退出")
  else
    say("[致命] 程序异常退出：%s", msg)
    say("[致命] 先 lua reset.lua yes 清场重来；还复现就把 log.txt 里 [致命]/[告警] 附近几行发给 AI")
    error(msg)
  end
end

if stop_flag() then
  os.remove(STOP_FILE)
  say("[停止] 已删除 stop 文件")
end
save()
ui_restore()
local exit_parts = {}
for _, f in ipairs(cfg.farms) do
  local s = ST.farms[f.id] or {}
  exit_parts[#exit_parts + 1] = string.format("#%d:%s/%s(循环%d)", f.id, tostring(s.phase or "-"), tostring(s.crop or "-"), s.cycles or 0)
end
say("[退出] 状态已保存：%s", table.concat(exit_parts, " "))
