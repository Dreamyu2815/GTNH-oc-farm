-- backup.lua —— 配置快照（防呆：set.lua 改坏、清场清错都能回退）
-- 用法：
--   lua backup.lua                    立即备份到 backups/<时间戳>/
--   lua backup.lua list               列出已有快照
--   lua backup.lua restore <名字> yes 回退（覆盖当前配置，需 yes 确认）
--
-- 只备份可变文件：config.lua limits.dat priority.dat state.dat tasks.dat binds.dat
-- 快照保留最近 10 份，更早的自动清理。
local ROOT = "/home/ocfarm"
local BKROOT = ROOT .. "/backups"
local KEEP = 10
local LIST = { "config.lua", "limits.dat", "priority.dat", "state.dat", "tasks.dat", "binds.dat" }

local computer = require("computer")
local fs = require("filesystem")
local util = dofile(ROOT .. "/lib/util.lua")

local ARGS = { ... }
if #ARGS == 0 and type(arg) == "table" then
  for _, v in pairs(arg) do
    if type(v) == "string" then ARGS[#ARGS + 1] = v end
  end
end

local function ts()
  local sec = math.floor(os.time() or 0)
  local ok, v = pcall(computer.realTime)
  if ok and type(v) == "number" then sec = math.floor(v) end
  return os.date("%Y%m%d_%H%M%S", sec + 8 * 3600)
end

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

local function do_backup()
  fs.makeDirectory(BKROOT)
  local dir = BKROOT .. "/" .. ts()
  fs.makeDirectory(dir)
  local n = 0
  for _, f in ipairs(LIST) do
    local data = util.read(ROOT .. "/" .. f)
    if data ~= nil then
      if util.write(dir .. "/" .. f, data) then
        n = n + 1
      else
        print("[备份] 写失败：" .. f)
      end
    end
  end
  local name = dir:match("([^/]+)$")
  print("[备份] 完成：" .. dir .. "（" .. n .. " 个文件）")
  print("[备份] 想回退时跑：lua backup.lua restore " .. name .. " yes")
  local dirs = dirs_of(BKROOT)
  while #dirs > KEEP do
    local victim = table.remove(dirs, 1)
    remove_tree(BKROOT .. "/" .. victim)
    print("[备份] 清理旧快照：" .. victim)
  end
end

local function do_list()
  local dirs = dirs_of(BKROOT)
  if #dirs == 0 then
    print("[备份] 还没有快照。跑 lua backup.lua 建一个。")
    return
  end
  print("[备份] 现有快照（旧 -> 新）：")
  for i = 1, #dirs do print("  " .. dirs[i]) end
end

local function do_restore(name, yes)
  if not name then
    print("用法：lua backup.lua restore <快照名> yes")
    return
  end
  if yes ~= "yes" then
    print("[备份] 回退会覆盖当前配置！确认请跑：lua backup.lua restore " .. name .. " yes")
    print("[备份] （先跑 lua backup.lua 把现状也存一份更稳）")
    return
  end
  local dir = BKROOT .. "/" .. name
  if not fs.isDirectory(dir) then
    print("[备份] 找不到快照：" .. name .. "（用 lua backup.lua list 看名字）")
    return
  end
  for _, f in ipairs(LIST) do
    local data = util.read(dir .. "/" .. f)
    if data ~= nil then
      if util.write(ROOT .. "/" .. f, data) then
        print("[备份] 已恢复 " .. f)
      else
        print("[备份] 恢复失败：" .. f)
      end
    end
  end
  print("[备份] 恢复完成。main.lua 在跑的话先 Ctrl+C，再 lua main.lua 生效。")
end

local cmd = ARGS[1]
if cmd == "list" then
  do_list()
elseif cmd == "restore" then
  do_restore(ARGS[2], ARGS[3])
elseif cmd == nil then
  do_backup()
else
  print("用法：lua backup.lua | list | restore <名字> yes")
end
