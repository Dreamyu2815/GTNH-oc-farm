-- 单独跑总自检：lua check.lua
-- 结果同时写到 /home/ocfarm/check.txt
local ROOT = "/home/ocfarm"

local function loadmod(name)
  local path = ROOT .. "/lib/" .. name .. ".lua"
  local f = io.open(path, "r")
  if not f then error("缺少模块: " .. path) end
  f:close()
  return dofile(path)
end

local ae = loadmod("ae")
local farmio = loadmod("farmio")
local util = loadmod("util")
local selfcheck = loadmod("selfcheck")
local cfg = dofile(ROOT .. "/config.lua")
util.merge_ae(cfg, ROOT)   -- 网络地址以 ae.dat 为准（setup.lua 生成）

local A = ae.new(cfg.ae)
local F = farmio.new({})

print("==== 开机总自检 ====")
local ok, lines = selfcheck.run(cfg, A, F)

local text = table.concat(lines, "\n") .. "\n"
util.write(ROOT .. "/check.txt", text)
print("已写入 /home/ocfarm/check.txt")
if not ok then
  print("结果：有致命项")
else
  print("结果：全部通过")
end
