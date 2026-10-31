-- 一键清场：出问题的时候，把现场还原成初始状态，然后重新启动 main.lua。
-- 用法：lua reset.lua          只看不动（预览 + 告诉你怎么确认）
--       lua reset.lua yes      清场 + 重新启动 main.lua
--       lua reset.lua clean    只清场，不启动
--       lua reset.lua show     只打印状态，什么都不改
-- 注意：先让 main.lua 停下（连按两次 q / Ctrl+C / 建 stop 文件），再执行本命令；
--       两个程序同时写状态会乱。
--
-- 清场做三件事：
--   1) 把农场接口上残留的样板搬回仓库（不依赖自检；自检挂了也能清）
--   2) 重置状态：空闲农场回到 input；还在长/还在干的农场保留原状态（否则会被当空闲重复下种）
--   3) 删掉任务台账 tasks.dat 和停止标记 stop，避免旧在制记录挡住发配
local ROOT = "/home/ocfarm"
local STOP_FILE = ROOT .. "/stop"

local function loadmod(name)
  local p = ROOT .. "/lib/" .. name .. ".lua"
  local f = io.open(p, "r")
  if not f then error("缺少模块: " .. p) end
  f:close()
  return dofile(p)
end

local computer = require("computer")
local util = loadmod("util")
local cfg = dofile(ROOT .. "/config.lua")

local MODE = "preview"
do
  local args = { ... }
  if #args == 0 and type(arg) == "table" then
    for _, v in pairs(arg) do
      if type(v) == "string" then args[#args + 1] = v end
    end
  end
  for _, a in ipairs(args) do
    local s = tostring(a)
    if s == "yes" then MODE = "run"
    elseif s == "clean" then MODE = "clean"
    elseif s == "show" then MODE = "show" end
  end
end

local function say(fmt, ...)
  local ok, s = pcall(string.format, fmt, ...)
  if not ok then s = fmt end
  print(s)
end

local function file_exists(p)
  local f = io.open(p, "r")
  if f then f:close() return true end
  return false
end

-- §9.1：农场地址以 binds.dat 为准（这里只需要 interface_name 认接口、gt 读传感器）
local binds = util.load(ROOT .. "/binds.dat", nil)
local binds_farms = (binds and type(binds.farms) == "table" and #binds.farms > 0) and binds.farms or nil
if not binds_farms then
  error("[致命] binds.dat 里没有农场表，先跑 lua bind.lua 绑定农场", 0)
end
local by_id = {}
for _, f in ipairs(cfg.farms or {}) do
  if type(f) == "table" and f.id ~= nil then by_id[f.id] = f end
end
cfg.farms = {}
for _, b in ipairs(binds_farms) do
  local beh = by_id[b.id] or {}
  cfg.farms[#cfg.farms + 1] = {
    id = b.id, gt = b.gt, redstone = b.redstone,
    x = b.x, y = b.y, z = b.z, dimension = b.dimension,
    iface = b.iface, iface_name = b.iface_name, interface_name = b.iface_name,
    redstone_side = (beh.redstone_side ~= nil) and beh.redstone_side or 1,
    enabled = (beh.enabled == nil) and true or beh.enabled,
  }
end

local PATH = cfg.paths.state
local ST = util.load(PATH, nil)
if type(ST) ~= "table" then ST = {} end
local old = {}
if ST.farms ~= nil then
  old = ST.farms
elseif ST.phase ~= nil or ST.crop ~= nil then
  old[1] = ST  -- 旧版扁平结构
end

if MODE == "show" or MODE == "preview" then
  say("状态文件：%s", PATH)
  for _, f in ipairs(cfg.farms) do
    local s = old[f.id]
    if s then
      say("  农场 %d：阶段=%s 作物=%s 待回收=%s 已循环=%s",
        f.id, tostring(s.phase), tostring(s.crop), tostring(s.pending), tostring(s.cycles))
    else
      say("  农场 %d：（无状态）", f.id)
    end
  end
  local t = util.load(ROOT .. "/tasks.dat", nil)
  say("任务台账：%s 条在制", tostring(t and t.list and #t.list or 0))
  if MODE == "preview" then
    say("")
    say("[清场] 执行会做三件事：1) 把农场接口上的残留样板搬回仓库；2) 重置状态（还在干活的农场保留，干完自动接着调度）；3) 清空任务台账与停止标记。")
    say("[清场] 确认执行：lua reset.lua yes（清场 + 重启主程序）")
    say("[清场] 只清场不重启：lua reset.lua clean")
    say("[清场] 改主意了：什么也不做，直接 Ctrl+C 就行。")
  end
  return
end

say("[清场] 开始：搬回样板、重置状态与台账（main.lua 还在跑的话请先 Ctrl+C）")

-- 1) 把农场接口上残留的样板搬回仓库
local okpat, patmod = pcall(loadmod, "pat")
if okpat then
  local okn, PAT = pcall(patmod.new, cfg)
  if okn then
    local oks, res = PAT:sweep()
    if oks then
      say("[清场] 农场接口上的残留样板已搬回仓库：%s 个", tostring(res))
    else
      say("[清场] 样板搬回失败：%s（继续做状态清理）", tostring(res))
    end
  else
    say("[清场] 接口终端不可用，跳过搬样板：%s", tostring(PAT))
  end
else
  say("[清场] 缺少 pat 模块，跳过搬样板")
end

-- 2) 重置状态。正在长的农场保留原状态，不能被当成空闲重复下种。
local F = nil
local okF, farmio = pcall(loadmod, "farmio")
if okF then F = farmio.new({}) end

local newst = { farms = {} }
local kept, resetN = 0, 0
for _, f in ipairs(cfg.farms) do
  local s = old[f.id]
  local working = nil
  if F then
    local okw, hw = pcall(F.is_working, F, f.gt)
    if okw then working = hw end
  end
  if working == true then
    if s and (s.phase == "farming" or s.phase == "reclaim") then
      s.dq = nil
      s.retried = nil
      s.warned = nil
      s.id = f.id
      newst.farms[f.id] = s
      say("[清场] 农场 %d 还在干活（阶段=%s 作物=%s），保留原状态，干完自动接着调度",
        f.id, tostring(s.phase), tostring(s.crop))
    else
      -- 还在干活但状态不明（没有旧状态 / 停在 input）：挂到 farming 等它干完，
      -- 干完机器一闲就会自动回 input，不会在它长着的时候重复下种
      newst.farms[f.id] = {
        id = f.id, phase = "farming", crop = nil, pending = 0,
        seed_base = 0, sub_base = 0,
        since = math.floor(os.time()), since_u = computer.uptime(),
        cycles = (s and s.cycles) or 0,
        reclaim_ticks = 0,
        last_prod = nil, last_prod_u = nil,
        task_id = nil, retried = nil, warned = nil,
        dq = nil, last_preempt = 0,
      }
      say("[清场] 农场 %d 还在干活但状态不明，先挂到 farming 等它干完再自动回 input", f.id)
    end
    kept = kept + 1
  else
    newst.farms[f.id] = {
      id = f.id, phase = "input", crop = nil, pending = 0,
      seed_base = 0, sub_base = 0,
      since = math.floor(os.time()), since_u = computer.uptime(),
      cycles = (s and s.cycles) or 0,
      reclaim_ticks = 0,
      last_prod = nil, last_prod_u = nil,
      task_id = nil, retried = nil, warned = nil,
      dq = nil, last_preempt = 0,
    }
    resetN = resetN + 1
    if working == nil and s and s.phase ~= "input" then
      say("[清场] 农场 %d 传感器读不到状态，按空闲重置（若其实还在长，等它长完再清场更稳）", f.id)
    end
  end
end
util.save(PATH, newst)
say("[清场] 状态已重置：%d 台回到初始，%d 台保留（还在干活）", resetN, kept)

-- 3) 清台账与停止标记
local removed = {}
for _, p in ipairs({ ROOT .. "/tasks.dat", STOP_FILE }) do
  if file_exists(p) then
    os.remove(p)
    removed[#removed + 1] = p:gsub("^" .. ROOT .. "/", "")
  end
end
if #removed > 0 then
  say("[清场] 已删除 %s", table.concat(removed, ", "))
else
  say("[清场] 没有多余的台账/停止标记需要删除")
end

say("[清场] 完成")
if MODE == "clean" then
  say("[清场] 现在可以运行：lua main.lua")
else
  say("[清场] 重新启动 main.lua ...")
  local chunk, cerr = loadfile(ROOT .. "/main.lua")
  if not chunk then error("main.lua 加载失败：" .. tostring(cerr), 0) end
  chunk()
end
