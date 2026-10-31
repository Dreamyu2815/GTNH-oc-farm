local util = {}

local computer = require("computer")
local ok_ser, serialization = pcall(require, "serialization")

-- ---------------- 文件 ----------------
function util.read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

function util.write(path, data)
  local f = io.open(path, "wb")
  if not f then return false end
  f:write(data)
  f:close()
  return true
end

function util.load(path, default)
  local data = util.read(path)
  if not data or data == "" then return default end
  if not ok_ser then return default end
  local ok, value = pcall(serialization.unserialize, data)
  if ok and type(value) == "table" then return value end
  return default
end

function util.save(path, value)
  if not ok_ser then return false end
  local ok, data = pcall(serialization.serialize, value)
  if not ok then return false end
  return util.write(path, data)
end

-- 合并网络地址：ae.dat（setup.lua 生成）优先，config.lua 的 ae 只作兜底
function util.merge_ae(cfg, root)
  cfg = cfg or {}
  cfg.ae = cfg.ae or {}
  local a = util.load(root .. "/ae.dat", nil)
  if type(a) == "table" then
    for k, v in pairs(a) do
      if k ~= "seq" and v ~= nil then cfg.ae[k] = v end
    end
  end
  return cfg
end

-- ---------------- 时间 ----------------
function util.uptime()
  return computer.uptime()
end

function util.fmt(sec)
  sec = math.floor(sec or 0)
  local h = math.floor(sec / 3600)
  local m = math.floor((sec % 3600) / 60)
  local s = sec % 60
  return string.format("%02d:%02d:%02d", h, m, s)
end

function util.stamp()
  -- os.date/os.time 是"游戏时间"（这台机上比真实时间快几十倍），日志要用真实时间。
  -- computer.realTime() 是 Unix 秒（UTC），+8 小时换算成本地时间（Asia/Shanghai）。
  local sec = math.floor(os.time() or 0)
  local ok, v = pcall(computer.realTime)
  if ok and type(v) == "number" then sec = math.floor(v) end
  sec = sec + 8 * 3600
  return string.format("%02d:%02d:%02d",
    math.floor(sec / 3600) % 24, math.floor(sec / 60) % 60, sec % 60)
end

-- ---------------- 日志 ----------------
local log_file = nil

function util.logf(path)
  log_file = path
end

function util.log(fmt, ...)
  local msg
  if select("#", ...) > 0 then
    local ok, formatted = pcall(string.format, fmt, ...)
    msg = ok and formatted or tostring(fmt)
  else
    msg = tostring(fmt)
  end
  local line = "[" .. util.stamp() .. "] " .. msg
  print(line)
  if log_file then
    local f = io.open(log_file, "a")
    if f then
      f:write(line .. "\n")
      f:close()
    end
  end
  return line
end

-- ---------------- 小工具 ----------------
function util.deepcopy(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = util.deepcopy(v) end
  return out
end

-- 在 NBT 表里递归找某个键（OC 返回的 tag 可能是嵌套表）
function util.find_tag(t, key, depth)
  depth = depth or 0
  if type(t) ~= "table" or depth > 6 then return nil end
  local v = t[key]
  if type(v) == "string" then return v end
  for _, sub in pairs(t) do
    if type(sub) == "table" then
      local found = util.find_tag(sub, key, depth + 1)
      if found then return found end
    end
  end
  return nil
end

function util.split(s, sep)
  local out = {}
  for part in string.gmatch(s, "([^" .. sep .. "]+)") do out[#out + 1] = part end
  return out
end

return util
