-- ===== 农场总控 · 仪表盘（lib/ui.lua）=====
-- 仅 T3 屏（分辨率 ≥160×50）可用；T1/T2/无 GPU 自动退化纯终端（ok=false）。
-- main.lua 每 tick 调 UI:data(d) 喂快照，wait() 里调 UI:tick()（渲染 + 吃按键）。
-- 开关记忆在 <ROOT>/ui.dat；F1 切换。仪表盘开启时所有按键进终端面板，
-- q q 退出只在「终端输入行为空」时生效；纯终端下 q q / Ctrl+C 照旧。
local component = require("component")
local computer  = require("computer")
local event     = require("event")
local ok_term, term = pcall(require, "term")
local ok_kb, keyboard = pcall(require, "keyboard")

local ui = {}
ui.__index = ui

local W, H = 160, 50

-- 键码（OpenOS 标准）；键盘库没有就用数值兜底
local function kcode(name, fb)
  if ok_kb and keyboard and type(keyboard.keys) == "table" and keyboard.keys[name] then
    return keyboard.keys[name]
  end
  return fb
end
local K_F1, K_ENTER, K_BACK, K_TAB = kcode("f1", 0x3B), kcode("enter", 28), kcode("back", 14), kcode("tab", 15)
local K_UP, K_DOWN, K_LEFT, K_RIGHT = kcode("up", 200), kcode("down", 208), kcode("left", 203), kcode("right", 205)

-- 颜色（0xRRGGBB）
local C = {
  black = 0x000000, white = 0xFFFFFF, gray = 0x909090, dim = 0x5A5A5A,
  cyan = 0x00E0E0, green = 0x20E020, yellow = 0xE0C020, red = 0xFF5050,
}

local function now_sec()
  local ok, v = pcall(computer.realTime)
  if ok and type(v) == "number" then return v end
  return os.time()
end

-- 游戏秒（运行时长用它：游戏停着不动，不会把关游戏的时间算进来）
local function game_sec()
  local ok, v = pcall(computer.uptime)
  if ok and type(v) == "number" then return v end
  return now_sec()
end

local function fmt_dur(sec)
  sec = math.max(0, math.floor(sec or 0))
  local h = math.floor(sec / 3600)
  local m = math.floor((sec % 3600) / 60)
  local s = sec % 60
  if h > 0 then return string.format("%dh%02dm", h, m) end
  if m > 0 then return string.format("%dm%02ds", m, s) end
  return s .. "s"
end

local function fmt_ts(sec)
  sec = math.floor(sec) + 8 * 3600
  return string.format("%02d:%02d:%02d",
    math.floor(sec / 3600) % 24, math.floor(sec / 60) % 60, sec % 60)
end

-- 数字缩写，和 AE2 的显示一致：1000→1k、1500→1.5k、100000→100k、1e6→1m、1e9→1g、1e12→1t
local function fmtn(n)
  n = math.floor(tonumber(n) or 0)
  if n < 1000 then return tostring(n) end
  local units = { { 1e12, "t" }, { 1e9, "g" }, { 1e6, "m" }, { 1e3, "k" } }
  for _, u in ipairs(units) do
    if n >= u[1] then
      local v = n / u[1]
      local s
      if v >= 100 or v == math.floor(v) then
        s = string.format("%d", math.floor(v))
      else
        s = string.format("%.1f", v):gsub("%.0$", "")
      end
      return s .. u[2]
    end
  end
  return tostring(n)
end

-- 显示宽度：OC 终端里 1 个 CJK/全角字符占 2 格，ASCII 占 1 格（之前按字节算导致中文被切半、列错位）
local utf8lib = utf8
local function is_wide(cp)
  return (cp >= 0x1100 and cp <= 0x115F) or (cp >= 0x2E80 and cp <= 0xA4CF)
      or (cp >= 0xAC00 and cp <= 0xD7A3) or (cp >= 0xF900 and cp <= 0xFAFF)
      or (cp >= 0xFE30 and cp <= 0xFE4F) or (cp >= 0xFF00 and cp <= 0xFF60)
      or (cp >= 0xFFE0 and cp <= 0xFFE6) or (cp >= 0x1F300 and cp <= 0x1FAFF)
end
local function swidth(s)
  s = tostring(s)
  if not utf8lib then return #s end
  local w = 0
  for _, cp in utf8lib.codes(s) do
    w = w + (cp < 0x80 and 1 or (is_wide(cp) and 2 or 1))
  end
  return w
end
local function scut(s, n)
  s = tostring(s)
  if not utf8lib then return s:sub(1, n) end
  local w, out = 0, {}
  for _, cp in utf8lib.codes(s) do
    local cw = (cp < 0x80 and 1 or (is_wide(cp) and 2 or 1))
    if w + cw > n then break end
    w = w + cw
    out[#out + 1] = utf8lib.char(cp)
  end
  return table.concat(out)
end
local function pad(s, n, align)
  s = tostring(s)
  local w = swidth(s)
  if w > n then return scut(s, n) end
  if align == "right" then return string.rep(" ", n - w) .. s end
  return s .. string.rep(" ", n - w)
end

-- 界面一律中文：焦点名 + 阶段名（避免面板上出现 term/farming/发配·suck 这类英文）
local FOCUS_CN = { term = "终端", seeds = "种子表", farms = "农场区" }
local PHASE_CN = {
  input = "空闲", farming = "种植中", reclaim = "回收中",
  slot = "搬样板", cpu = "等CPU", suck = "等吸入", pulse = "脉冲中", work = "等开工", dump = "吐料中",
}
local function phase_cn(p)
  p = tostring(p or "")
  local pre, tail = p:match("^(发配·)(.+)$")
  if pre then return "发配·" .. (PHASE_CN[tail] or tail) end
  return PHASE_CN[p] or p
end

function ui.new(ROOT)
  local self = setmetatable({}, ui)
  self.ROOT = ROOT
  self.ok = false
  self.on = false
  self.last = {}            -- 上一帧 { [y] = { {x,txt,fg}, ... } }
  self.ring = {}            -- 日志环形缓冲
  self.termout = {}         -- 终端输出环形缓冲
  self.input = ""           -- 终端输入行
  self.cur = 1
  self.hist = {}
  self.hist_i = 0
  self.focus = "term"       -- term / seeds / farms
  self.s_seeds, self.s_farms = 0, 0
  self.qtime = -99
  self.quit_requested = false
  self.boot = game_sec()
  self.d = { header = {}, seeds = {}, farms = {}, alarms = {} }
  self.blink = false

  self.realprint = print
  -- 终端热命令要用：util（load/save）与 config（默认阈值/苗床）
  self.util = nil
  do local oku, U = pcall(dofile, ROOT .. "/lib/util.lua"); if oku and type(U) == "table" then self.util = U end end
  self.cfg = nil
  do local okc, C = pcall(dofile, ROOT .. "/config.lua"); if okc and type(C) == "table" then self.cfg = C end end
  self.fs = nil
  do local okf, F = pcall(require, "filesystem"); if okf and type(F) == "table" then self.fs = F end end
  local gpu = component.gpu
  if not gpu then return self end
  self.gpu = gpu
  local ok, mw, mh = pcall(function() return gpu.maxResolution() end)
  if not ok or type(mw) ~= "number" or mw < W or mh < H then return self end
  self.ok = true

  -- 开关记忆 ui.dat（第一行 on=true / on=false）
  -- 注意：开机时不直接打开面板——先让终端可见把启动日志打完，
  -- 主循环跑到第 2 个 tick 确认没问题后才恢复上次的状态（见 main.lua），免得一开就黑屏
  local f = io.open(ROOT .. "/ui.dat", "r")
  if f then
    local first = f:read("*l") or ""
    f:close()
    self.on_pref = first:find("true", 1, true) ~= nil
  end
  return self
end

function ui:save_flag()
  if not self.ROOT then return end
  local f = io.open(self.ROOT .. "/ui.dat", "w")
  if f then f:write("on=" .. tostring(self.on) .. "\n"); f:close() end
end

function ui:log(line)
  self.ring[#self.ring + 1] = line
  if #self.ring > 200 then table.remove(self.ring, 1) end
  if not self.on then self.realprint(line) end
end

function ui:term(msg)
  -- 注意：gmatch 返回的是迭代函数，不能套 ipairs（之前写错，任何命令一执行就崩）
  for l in tostring(msg):gsub("\r", ""):gmatch("[^\n]*") do
    self.termout[#self.termout + 1] = l
  end
  while #self.termout > 300 do table.remove(self.termout, 1) end
end

function ui:data(d) self.d = d or self.d end

-- 鼠标中键粘贴：文字进终端输入行（不再漏到屏幕其它地方）
function ui:paste(text)
  if not self.on then return end
  text = tostring(text or ""):gsub("[\r\n\t]+", " ")
  text = text:gsub("[^ -~]", "")
  if text == "" then return end
  self.input = self.input:sub(1, self.cur - 1) .. text .. self.input:sub(self.cur)
  self.cur = self.cur + #text
  self.force = true
end

function ui:toggle(force)
  if force ~= nil then self.on = force else self.on = not self.on end
  if self.on and not self.ok then self.on = false end
  if self.on then
    pcall(function()
      local w, h = self.gpu.getResolution()
      if w < W or h < H then self.gpu.setResolution(W, H) end
    end)
    if ok_term and term and term.clear then pcall(term.clear) end
    self.last = {}
    self.force = true
  else
    if ok_term and term and term.clear then pcall(term.clear) end
    self.realprint("[仪表盘] 已关闭（按 F1 重新打开）")
  end
  self:save_flag()
end

-- ---------------- 终端命令 ----------------
local function cmd_help(u)
  u:term([[命令速查：
  help        本页
  status      三台农场的当前阶段一行一个
  farms       农场详情（等级/容量/作物/持续/循环）
  seeds       种子明细（网内/在制/闲置/垫块/产物/阈值）
  log [N]     最近 N 行日志（默认 12）
  cal         校准时钟（realTime 与 os.time 对照）
  prio        优先级分层（编号：prio 3 1 = 3号挪第1层；prio 3 0 = 不种）
  set         改阈值（set 看列表；set 3 low 128 / set 3 high 512）
  backup      配置快照（backup / backup list / backup restore <名> yes）
  dash off    关仪表盘（F1 再开）
  clear       清空终端输出
  （仪表盘外还有：lua set.lua 阈值 · lua reset.lua yes 清场 · lua backup.lua 快照）]])
end

local function cmd_status(u)
  local d = u.d
  if #d.farms == 0 then u:term("（暂无农场数据）") return end
  for _, f in ipairs(d.farms) do
    u:term(string.format("农场%d %s %s", f.id, phase_cn(f.phase), f.crop ~= "" and ("· " .. f.crop .. " ×" .. f.pending) or ""))
  end
end

local function cmd_farms(u)
  local d = u.d
  if #d.farms == 0 then u:term("（暂无农场数据）") return end
  for _, f in ipairs(d.farms) do
    u:term(string.format("── 农场%d Lv%s 容量%d %s", f.id, f.lv or "?", f.cap or 0, f.err and "[传感器异常]" or ""))
    u:term(string.format("   阶段 %s | 作物 %s | 持续 %s | 循环 %d", phase_cn(f.phase), f.crop ~= "" and f.crop or "-", f.dur, f.cycles))
    if f.note ~= "" then u:term("   注记 " .. f.note) end
  end
end

local function cmd_seeds(u)
  local d = u.d
  if #d.seeds == 0 then u:term("（暂无种子数据）") return end
  u:term("作物 | 网内 | 在制 | 闲置 | 垫块 | 产物 | 阈值")
  for _, s in ipairs(d.seeds) do
    u:term(string.format("%s %s %s %s %s %s %s",
      s.crop, s.net, s.making, s.idle, s.sub or "-", s.prod, s.th))
  end
end

local function cmd_log(u, n)
  n = tonumber(n) or 12
  local from = math.max(1, #u.ring - n + 1)
  if from > #u.ring then u:term("（日志为空）") return end
  for i = from, #u.ring do u:term(u.ring[i]) end
end

local function cmd_cal(u)
  local ok, rt = pcall(computer.realTime)
  u:term(string.format("realTime = %s (%s)", tostring(rt), fmt_ts(ok and rt or 0)))
  u:term(string.format("os.time  = %d (游戏秒，偏快，只作兜底)", math.floor(os.time())))
  u:term(string.format("仪表盘已运行 %s", fmt_dur(game_sec() - u.boot)))
end

-- ---- 终端热命令：优先级分层（写 priority.dat，main 轮询自动生效）----
local function ui_croplist(u)
  local seen, out = {}, {}
  local function add(c) if c and not seen[c] then seen[c] = true; out[#out + 1] = c end end
  local cfg = u.cfg or {}
  for _, layer in ipairs(cfg.priority or {}) do for _, c in ipairs(layer) do add(c) end end
  if type(cfg.crops) == "table" then
    local rest = {}
    for c in pairs(cfg.crops) do rest[#rest + 1] = c end
    table.sort(rest)
    for _, c in ipairs(rest) do add(c) end
  end
  for _, s in ipairs(u.d.seeds or {}) do add(s.crop) end
  return out
end
local function ui_load_prio(u)
  local util, cfg = u.util, u.cfg or {}
  local p = util and util.load(u.ROOT .. "/priority.dat", nil) or nil
  if type(p) ~= "table" or type(p.layers) ~= "table" then
    local layers = {}
    for _, layer in ipairs(cfg.priority or {}) do
      local nl = {}
      for _, c in ipairs(layer) do nl[#nl + 1] = c end
      layers[#layers + 1] = nl
    end
    p = { seq = 0, layers = layers, excluded = {} }
  end
  p.excluded = p.excluded or {}
  p.seq = tonumber(p.seq) or 0
  while #p.layers < 10 do p.layers[#p.layers + 1] = {} end
  local last, seenL = p.layers[#p.layers], {}
  for _, layer in ipairs(p.layers) do for _, c in ipairs(layer) do seenL[c] = true end end
  for _, c in ipairs(ui_croplist(u)) do
    if not seenL[c] and not p.excluded[c] then last[#last + 1] = c; seenL[c] = true end
  end
  return p
end
local function ui_prio_rows(u, p)
  local out, seen = {}, {}
  for i, layer in ipairs(p.layers) do
    for _, c in ipairs(layer) do out[#out + 1] = { crop = c, layer = i }; seen[c] = true end
  end
  for _, c in ipairs(ui_croplist(u)) do
    if not seen[c] then out[#out + 1] = { crop = c, layer = 0 }; seen[c] = true end
  end
  return out
end
local function ui_prio_layer_of(p, crop)
  for i, layer in ipairs(p.layers) do for _, c in ipairs(layer) do if c == crop then return i end end end
end
local function ui_prio_remove(p, crop)
  for _, layer in ipairs(p.layers) do
    for i = #layer, 1, -1 do if layer[i] == crop then table.remove(layer, i) end end
  end
end
local function ui_prio_save(u, p)
  p.seq = (tonumber(p.seq) or 0) + 1
  if u.util then u.util.save(u.ROOT .. "/priority.dat", p) end
end
local function cmd_prio(u, arg)
  local p = ui_load_prio(u)
  local rows = ui_prio_rows(u, p)
  if not arg or arg == "" then
    u:term("── 优先级（层号越小越优先，第10层=未定级）──")
    for i, r in ipairs(rows) do
      u:term(string.format(" %2d) %s  %s", i, r.crop, r.layer > 0 and ("第" .. r.layer .. "层") or "已移出(不种)"))
    end
    u:term("用法：prio <编号> <层|+1|-1|0>  （例 prio 3 1 / prio 3 0）")
    return
  end
  local n, target = arg:match("^(%d+)%s+(%S+)$")
  if not n then u:term("用法：prio <编号> <层|+1|-1|0>") return end
  local row = rows[tonumber(n)]
  if not row then u:term("没有这个编号（prio 看编号）") return end
  if target == "0" then
    ui_prio_remove(p, row.crop)
    p.excluded[row.crop] = true
    ui_prio_save(u, p)
    u:term(string.format("%s 已移出（不种；自动配置不再加回）", row.crop))
    return
  end
  local ln = target
  if ln == "+1" or ln == "-1" then
    local cur = ui_prio_layer_of(p, row.crop) or 0
    ln = cur + (ln == "+1" and -1 or 1)
    if ln < 1 then ln = 1 end
  end
  ln = tonumber(ln)
  if not ln then u:term("层号无效") return end
  ln = math.max(1, math.min(math.floor(ln), #p.layers + 1))
  if ln > #p.layers then p.layers[ln] = {} end
  ui_prio_remove(p, row.crop)
  p.layers[ln][#p.layers[ln] + 1] = row.crop
  p.excluded[row.crop] = nil
  ui_prio_save(u, p)
  u:term(string.format("%s → 第%d层（一个轮询周期内生效）", row.crop, ln))
end

-- ---- 红石端口朝向已取消：脉冲默认「六面全写」，不再提供 side 命令 ----

-- ---- 终端热命令：改阈值 low/high（写 limits.dat，main 轮询自动生效）----
local function ui_load_limits(u)
  local t = u.util and u.util.load(u.ROOT .. "/limits.dat", nil) or nil
  if type(t) ~= "table" then t = {} end
  t.t = t.t or {}
  t.seq = tonumber(t.seq) or 0
  return t
end
local function ui_cur(u, crop)
  local t = ui_load_limits(u)
  local o = t.t[crop] or {}
  local th = (u.cfg and u.cfg.thresholds and u.cfg.thresholds[crop]) or {}
  local ci = (u.cfg and u.cfg.crops and u.cfg.crops[crop]) or {}
  return {
    low = math.floor(tonumber(o.low or th.low) or 64),
    high = math.floor(tonumber(o.high or th.high) or 512),
    bed = math.floor(tonumber(o.bed or ci.bed) or 0),
    product = th.product or ci.out or crop,
  }
end
local function cmd_set(u, arg)
  if not u.util then u:term("（util 加载失败，无法读写 limits.dat）") return end
  local crops = ui_croplist(u)
  if not arg or arg == "" then
    u:term("── 作物阈值（编号操作）──")
    for i, c in ipairs(crops) do
      local v = ui_cur(u, c)
      u:term(string.format(" %2d) %s  产物=%s  low=%s high=%s 苗床=%d", i, c, v.product, fmtn(v.low), fmtn(v.high), v.bed))
    end
    u:term("用法：set <编号> low <值>  或  set <编号> high <值>")
    return
  end
  local n, key, val = arg:match("^(%d+)%s+(%a+)%s+(%d+)$")
  if not n or (key ~= "low" and key ~= "high") then
    u:term("用法：set <编号> low <值>  /  set <编号> high <值>")
    return
  end
  local crop = crops[tonumber(n)]
  if not crop then u:term("没有这个编号（set 看编号）") return end
  val = tonumber(val)
  local t = ui_load_limits(u)
  local v = ui_cur(u, crop)
  if key == "low" then
    if val < 0 or val % 1 ~= 0 then u:term("low 要 ≥0 的整数") return end
    t.t[crop] = t.t[crop] or {}
    t.t[crop].low = val
    if v.high <= val then
      t.t[crop].high = val + 1
      u:term(string.format("注意：high 自动调成 %d（必须 > low）", val + 1))
    end
  else
    if val < 0 or val % 1 ~= 0 then u:term("high 要 ≥0 的整数") return end
    if val <= v.low then u:term(string.format("high 必须 > low(%d)，没改", v.low)) return end
    t.t[crop] = t.t[crop] or {}
    t.t[crop].high = val
  end
  t.seq = t.seq + 1
  u.util.save(u.ROOT .. "/limits.dat", t)
  local nv = ui_cur(u, crop)
  u:term(string.format("%s 阈值改为 low=%s high=%s（一个轮询周期内生效）", crop, fmtn(nv.low), fmtn(nv.high)))
end

-- ---- 终端热命令：配置快照（等价 lua backup.lua）----
local function cmd_backup(u, arg)
  if not u.util or not u.fs then u:term("（util/filesystem 加载失败，无法备份）") return end
  local ROOT, fs, util = u.ROOT, u.fs, u.util
  local BKROOT = ROOT .. "/backups"
  local LIST = { "config.lua", "limits.dat", "priority.dat", "state.dat", "tasks.dat", "binds.dat" }
  local function dirs_of(path)
    local out = {}
    if not fs.exists(path) then return out end
    for f in fs.list(path) do
      if fs.isDirectory(path .. "/" .. f) then out[#out + 1] = f end
    end
    table.sort(out)
    return out
  end
  local function remove_tree(dir)
    for f in fs.list(dir) do
      local p = dir .. "/" .. f
      if fs.isDirectory(p) then remove_tree(p) else fs.remove(p) end
    end
    fs.remove(dir)
  end
  local function ts()
    local sec = math.floor(os.time() or 0)
    local ok, v = pcall(computer.realTime)
    if ok and type(v) == "number" then sec = math.floor(v) end
    return os.date("%Y%m%d_%H%M%S", sec + 8 * 3600)
  end
  if arg == "list" then
    local dirs = dirs_of(BKROOT)
    if #dirs == 0 then u:term("还没有快照（backup 建一个）") else
      u:term("现有快照（旧 → 新）：")
      for i = 1, #dirs do u:term("  " .. dirs[i]) end
    end
    return
  end
  local name, yes = arg:match("^restore%s+(%S+)%s+(%S+)$")
  if name then
    if yes ~= "yes" then u:term("回退会覆盖当前配置！确认请敲：backup restore " .. name .. " yes") return end
    local dir = BKROOT .. "/" .. name
    if not fs.isDirectory(dir) then u:term("找不到快照：" .. name) return end
    for _, f in ipairs(LIST) do
      local data = util.read(dir .. "/" .. f)
      if data ~= nil and util.write(ROOT .. "/" .. f, data) then u:term("已恢复 " .. f) end
    end
    u:term("恢复完成。建议 q q 退出后重启 main 生效。")
    return
  end
  fs.makeDirectory(BKROOT)
  local dir = BKROOT .. "/" .. ts()
  fs.makeDirectory(dir)
  local n = 0
  for _, f in ipairs(LIST) do
    local data = util.read(ROOT .. "/" .. f)
    if data ~= nil then
      if util.write(dir .. "/" .. f, data) then n = n + 1 else u:term("写失败：" .. f) end
    end
  end
  u:term(string.format("备份完成：%s（%d 个文件）", dir, n))
  local dirs = dirs_of(BKROOT)
  while #dirs > 10 do
    local victim = table.remove(dirs, 1)
    remove_tree(BKROOT .. "/" .. victim)
    u:term("清理旧快照：" .. victim)
  end
end

local function run_cmd(u, line)
  local cmd, arg = line:match("^%s*(%S+)%s*(.-)%s*$")
  if not cmd then return end
  if cmd == "help" then cmd_help(u)
  elseif cmd == "status" then cmd_status(u)
  elseif cmd == "farms" then cmd_farms(u)
  elseif cmd == "seeds" then cmd_seeds(u)
  elseif cmd == "log" then cmd_log(u, arg)
  elseif cmd == "cal" then cmd_cal(u)
  elseif cmd == "prio" then cmd_prio(u, arg)
  elseif cmd == "set" then cmd_set(u, arg)
  elseif cmd == "backup" then cmd_backup(u, arg)
  elseif cmd == "dash" and arg == "off" then u:toggle(false)
  elseif cmd == "clear" then u.termout = {}
  else u:term("未知命令：" .. cmd .. "（help 看命令）") end
end

-- ---------------- 键盘 ----------------
-- 键盘事件：本版 OC 的 key_down 是 (addr, char, code)，char 是 ASCII 数字；功能键 char=0，只有 code 有用
function ui:key(a, b, c)
  if not self.ok then return end
  local addr_like = type(a) == "string" and a:find("^%x%x%x%x%x%x%x%x%-") ~= nil
  local raw = addr_like and b or a
  local code = addr_like and c or b
  if type(raw) == "string" and #raw == 1 then raw = raw:byte() end
  if type(code) ~= "number" then code = (type(raw) == "number") and raw or nil end
  local ch = nil
  if type(raw) == "number" and raw >= 32 and raw <= 126 then ch = string.char(raw) end

  if code == K_F1 then
    self:toggle()
    return
  end
  if not self.on then return end
  self.force = true          -- 按下任何键都立刻重绘，不等 1 秒节流

  -- q q 退出：只在终端输入行为空、且焦点在终端时计数
  if self.focus == "term" and self.input == "" and (ch == "q" or ch == "Q") then
    local t = now_sec()
    if t - self.qtime <= 5 then
      self.quit_requested = true
      self:term("退出程序（状态已保存）…")
      return
    end
    self.qtime = t
    self:term("[提示] 再按一次 q 退出；继续打字则不算")
    return
  end

  if code == K_TAB then
    self.focus = self.focus == "term" and "seeds" or (self.focus == "seeds" and "farms" or "term")
    return
  end

  if self.focus == "term" then
    if code == K_ENTER then
      self:term("> " .. self.input)
      run_cmd(self, self.input)
      if self.input ~= "" then
        self.hist[#self.hist + 1] = self.input
        if #self.hist > 50 then table.remove(self.hist, 1) end
      end
      self.input = ""; self.cur = 1; self.hist_i = 0
    elseif code == K_BACK then
      if self.cur > 1 then
        self.input = self.input:sub(1, self.cur - 2) .. self.input:sub(self.cur)
        self.cur = self.cur - 1
      end
    elseif code == K_LEFT then self.cur = math.max(1, self.cur - 1)
    elseif code == K_RIGHT then self.cur = math.min(#self.input + 1, self.cur + 1)
    elseif code == K_UP then
      if self.hist_i < #self.hist then
        self.hist_i = self.hist_i + 1
        self.input = self.hist[#self.hist - self.hist_i + 1] or ""
        self.cur = #self.input + 1
      end
    elseif code == K_DOWN then
      if self.hist_i > 0 then
        self.hist_i = self.hist_i - 1
        self.input = self.hist_i == 0 and "" or (self.hist[#self.hist - self.hist_i + 1] or "")
        self.cur = #self.input + 1
      end
    elseif ch then
      self.input = self.input:sub(1, self.cur - 1) .. ch .. self.input:sub(self.cur)
      self.cur = self.cur + 1
    end
  elseif self.focus == "seeds" then
    if code == K_UP then self.s_seeds = math.max(0, self.s_seeds - 1) end
    if code == K_DOWN then self.s_seeds = self.s_seeds + 1 end
  elseif self.focus == "farms" then
    if code == K_UP then self.s_farms = math.max(0, self.s_farms - 1) end
    if code == K_DOWN then self.s_farms = self.s_farms + 1 end
  end
end

-- ---------------- 渲染 ----------------
function ui:tick()
  if not (self.ok and self.on) then return end
  local t = now_sec()
  -- 常规 1 秒节流；按过键就立刻重绘（不然 Tab/▲▼ 要等一拍才有反应）
  if not self.force and t - (self.last_t or 0) < 1 then return end
  self.force = false
  self.last_t = t
  self.blink = not self.blink
  local ok, err = pcall(self.render, self)
  if not ok then
    self.on = false
    self:save_flag()
    self.realprint("[仪表盘] 渲染出错，已切回纯终端：" .. tostring(err))
  end
end

-- 一行 = 若干段 {x, txt, fg}；和上一帧逐段对比，只重画变化段
local function seg(x, txt, fg) return { x = x, txt = txt, fg = fg } end

function ui:render()
  local g = self.gpu
  local d = self.d
  local frame = {}

  local function put(y, s, fg)
    frame[y] = frame[y] or {}
    table.insert(frame[y], seg(1, s, fg or C.white))
  end
  local function putx(x, y, s, fg)
    frame[y] = frame[y] or {}
    table.insert(frame[y], seg(x, s, fg or C.white))
  end

  -- 行 1：标题栏
  local alarms = #d.alarms or 0
  local up = fmt_dur(game_sec() - self.boot)
  put(1, pad(" 农场总控", 14), C.cyan)
  putx(15, 1, pad(fmt_ts(now_sec()) .. " · 运行 " .. up, 100), C.cyan)
  local atxt = alarms > 0 and string.format("[告警:%d]", alarms) or "[告警:0]"
  putx(116, 1, pad(atxt, 10, "right"), alarms > 0 and C.red or C.gray)
  putx(127, 1, pad("F1 切换", 8, "right"), C.gray)
  putx(136, 1, pad("焦点:" .. (FOCUS_CN[self.focus] or self.focus), 24), C.yellow)

  -- 行 2：分栏头
  put(2, "种子详情（网络）", C.gray)
  putx(56, 2, "农场详情", C.gray)

  -- 左栏（3 表头，4..20 作物，21 分隔，22..26 告警）
  local sx, sw = 2, 51
  local srows = d.seeds
  local vis = 17
  putx(sx, 3, pad("作物", 8), C.gray)
  putx(sx + 8, 3, pad("网内", 6, "right"), C.gray)
  putx(sx + 14, 3, pad("在制", 6, "right"), C.gray)
  putx(sx + 20, 3, pad("闲置", 6, "right"), C.gray)
  putx(sx + 26, 3, pad("垫块", 8, "right"), C.gray)
  putx(sx + 34, 3, pad("产物", 6, "right"), C.gray)
  putx(sx + 40, 3, pad("阈值", 11, "right"), C.gray)
  if #srows > vis then
    self.s_seeds = math.min(self.s_seeds, #srows - vis)
  else
    self.s_seeds = 0
  end
  for i = 1, vis do
    local idx = self.s_seeds + i
    local s = srows[idx]
    local y = 3 + i
    if s then
      local net = tonumber(s.net) or 0
      local fg = C.white
      if net <= 0 then fg = C.dim elseif net < 90 then fg = C.yellow end
      putx(sx, y, pad(s.crop, 8), fg)
      putx(sx + 8, y, pad(fmtn(s.net), 6, "right"), fg)
      putx(sx + 14, y, pad(fmtn(s.making), 6, "right"), s.making > 0 and C.green or C.dim)
      putx(sx + 20, y, pad(fmtn(s.idle), 6, "right"), fg)
      putx(sx + 26, y, pad(s.sub == nil and "-" or fmtn(s.sub), 8, "right"), s.sub == nil and C.dim or fg)
      putx(sx + 34, y, pad(fmtn(s.prod), 6, "right"), fg)
      putx(sx + 40, y, pad(tostring(s.th), 11, "right"), C.gray)
    else
      putx(sx, y, string.rep(" ", sw), C.black)
    end
  end
  put(21, "── 告警 ────────────────────────", C.gray)
  local arows = d.alarms
  for i = 1, 5 do
    local y = 21 + i
    local al = arows[i]
    if al then putx(sx, y, pad(al, sw), C.red) else putx(sx, y, string.rep(" ", sw), C.black) end
  end

  -- 右栏（3..26 农场）：>4 台切紧凑行，异常置顶
  local rx, rw = 56, 104
  local farms = {}
  for _, f in ipairs(d.farms) do farms[#farms + 1] = f end
  table.sort(farms, function(x, y)
    if x.err and not y.err then return true end
    if y.err and not x.err then return false end
    return (x.id or 0) < (y.id or 0)
  end)
  if #farms <= 4 then
    self.s_farms = 0
    local y = 3
    for _, f in ipairs(farms) do
      if y + 4 <= 26 then
        local fg = f.err and C.red or (C[f.fcolor] or C.white)
        putx(rx, y, "┌" .. pad(" 农场" .. f.id .. " · Lv" .. tostring(f.lv or "?") .. " · 容量" .. fmtn(f.cap or 0), rw - 2) .. "┐", C.gray)
        putx(rx, y + 1, "│ " .. pad("阶段 " .. phase_cn(f.phase) .. " | 作物 " .. (f.crop ~= "" and f.crop or "-") .. " ×" .. fmtn(f.pending), rw - 4) .. " │", fg)
        putx(rx, y + 2, "│ " .. pad("持续 " .. f.dur .. " · 循环 " .. f.cycles, rw - 4) .. " │", C.white)
        putx(rx, y + 3, "│ " .. pad((f.err and "传感器异常" or (f.note ~= "" and f.note or "正常")), rw - 4) .. " │", f.err and C.red or C.gray)
        putx(rx, y + 4, "└" .. string.rep("─", rw - 2) .. "┘", C.gray)
        y = y + 6
      end
    end
  else
    if self.s_farms > #farms - 24 then self.s_farms = math.max(0, #farms - 24) end
    local shown = 0
    for i = self.s_farms + 1, #farms do
      if shown >= 24 then break end
      local f = farms[i]
      local y = 3 + shown
      local fg = f.err and C.red or (C[f.fcolor] or C.white)
      putx(rx, y, pad(string.format("%d Lv%s %s %s×%s %s 循%d", f.id, tostring(f.lv or "?"), phase_cn(f.phase), f.crop ~= "" and f.crop or "-", fmtn(f.pending), f.dur, f.cycles), rw), fg)
      shown = shown + 1
    end
  end

  -- 行 28 分隔
  put(28, string.rep("─", W), C.dim)

  -- 终端（29 提示、30..41 输出、42 输入）
  -- 提示行带中文：光给命令名没人看得懂是干嘛的
  put(29, pad("终端  help=命令 status=概况 seeds=种子 farms=农场 log N=日志 cal=校准 set=阈值 prio=优先级 backup=备份 dash off=关 clear=清屏", W), C.gray)
  local nout = 12
  local from = math.max(1, #self.termout - nout + 1)
  for i = 1, nout do
    local line = self.termout[from + i - 1]
    put(30 + i - 1, line and pad(line, W) or string.rep(" ", W), line and C.white or C.black)
  end
  local cur = self.blink and "█" or "▌"
  local inl = " > " .. self.input:sub(1, self.cur - 1) .. cur .. self.input:sub(self.cur)
  put(42, pad(inl, W), C.cyan)

  -- 行 43 分隔
  put(43, string.rep("─", W), C.dim)

  -- 日志条（44..49，最新在底）
  for i = 1, 6 do
    local line = self.ring[#self.ring - 6 + i]
    if line then
      local fg = C.white
      if line:find("[致命]", 1, true) then fg = C.red
      elseif line:find("[告警]", 1, true) then fg = C.red
      elseif line:find("[错误]", 1, true) or line:find("[警告]", 1, true) then fg = C.yellow end
      put(43 + i, pad(line, W), fg)
    else
      put(43 + i, string.rep(" ", W), C.black)
    end
  end

  -- 行 50：快捷键条
  put(50, "[F1]切换  [Tab]焦点  [▲▼]滚动  [help]命令  退出：输入行为空连按 q q，或按住 Ctrl+C", C.gray)

  -- 逐行 diff 重绘
  pcall(function() g.setBackground(C.black) end)
  for y = 1, H do
    local newsegs = frame[y] or {}
    local oldsegs = self.last[y] or {}
    local n = math.max(#newsegs, #oldsegs)
    for i = 1, n do
      local a, b = newsegs[i], oldsegs[i]
      if not a then
        pcall(g.setForeground, C.black)
        pcall(g.set, b.x, y, string.rep(" ", #b.txt))
      elseif not b or a.txt ~= b.txt or a.fg ~= b.fg or a.x ~= b.x then
        pcall(g.setForeground, a.fg)
        pcall(g.set, a.x, y, a.txt)
      end
    end
  end
  self.last = frame
end

return ui
