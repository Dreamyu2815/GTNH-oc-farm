-- 任务台账：记住"哪个作物、在哪台农场、发了多少颗、什么时候发的"
-- 比"总种子 - 网络 = 在制"稳：机器里压着多少、压了多久，一目了然，重启也能恢复
-- 兼容任意 CWD 加载 util：run 命令可能在 /home 下启动，require("lib.util") 会找不到
local function load_util()
  local m = package.loaded["util"] or package.loaded["lib.util"]
  if type(m) == "table" then return m end
  for _, name in ipairs({ "lib.util", "util" }) do
    local ok, mod = pcall(require, name)
    if ok and type(mod) == "table" then return mod end
  end
  local cands = { "/home/ocfarm/lib/util.lua", "./lib/util.lua", "util.lua" }
  local src = debug and debug.getinfo and debug.getinfo(1, "S") and debug.getinfo(1, "S").source
  if src then
    local d = src:match("@(.*/)")
    if d then table.insert(cands, 1, d .. "util.lua") end
  end
  for _, path in ipairs(cands) do
    local ok, mod = pcall(dofile, path)
    if ok and type(mod) == "table" then return mod end
  end
  error("lib/util.lua 加载失败（请确认 /home/ocfarm/lib/util.lua 存在）", 0)
end
local util = load_util()

local tasks = {}
tasks.__index = tasks
tasks.DEFAULT = "/home/ocfarm/tasks.dat"

function tasks.new(path)
  local self = setmetatable({ path = path or tasks.DEFAULT, list = {}, seq = 0 }, tasks)
  self:load()
  return self
end

function tasks:load()
  local d = util.load(self.path, { list = {}, seq = 0 })
  self.list = d.list or {}
  self.seq = d.seq or #self.list
  return self
end

function tasks:save()
  util.save(self.path, { list = self.list, seq = self.seq })
end

-- 新增一条进行中的任务，返回记录（含 id）
function tasks:add(rec)
  self.seq = (self.seq or 0) + 1
  rec.id = self.seq
  rec.t0 = rec.t0 or os.time()
  rec.state = rec.state or "dispatched"
  self.list[#self.list + 1] = rec
  self:save()
  return rec
end

-- 结束任务（按 id）
function tasks:finish(id)
  for i = #self.list, 1, -1 do
    if self.list[i].id == id then table.remove(self.list, i) end
  end
  self:save()
end

-- 某作物在制数量；传 farm 时只算那一台（多农场并行：别台同作物的在制不挡路）
function tasks:inflight(crop, farm)
  local n = 0
  for _, t in ipairs(self.list) do
    if (crop == nil or t.crop == crop) and (farm == nil or t.farm == farm) then
      n = n + (t.n or 0)
    end
  end
  return n
end

function tasks:count() return #self.list end

function tasks:each()
  return function(_, i)
    i = i + 1
    local t = self.list[i]
    if t then return i, t end
  end, nil, 0
end

return tasks
