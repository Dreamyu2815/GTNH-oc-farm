-- 诊断脚本：把"这台 gt_machine 到底算不算在干活"的所有信号原样打出来。
-- 用法：lua work_probe.lua [gt地址]
--   不给地址就自动找第一个 gt_machine。
-- 请在农场【确定正在生长】的时候跑一次，把输出贴回来，我就能定位是哪个信号在撒谎。
local ROOT = "/home/ocfarm"
local component = require("component")

local function loadmod(name)
  return dofile(ROOT .. "/lib/" .. name .. ".lua")
end

local farmio = loadmod("farmio")
local F = farmio.new({})

local function strip(s)
  return tostring(s):gsub("\194\167.", "")
end

-- 找 gt 地址
local gt = nil
do
  local n = select("#", ...)
  for i = 1, n do
    local v = select(i, ...)
    if type(v) == "string" and v:match("^%x+%-") then gt = v end
  end
end
if not gt then
  local list = component.list("gt_machine", true)
  for addr in pairs(list) do gt = addr break end
end
if not gt then print("[错误] 没找到 gt_machine，先给农场控制器贴适配器"); return end

print("gt = " .. gt)

-- 原始调用：直接 component.invoke，打印 返回类型 + 值
local function probe(name, ...)
  local ok, res = pcall(component.invoke, gt, name, ...)
  if not ok then
    print(string.format("  %-22s ERR  %s", name, tostring(res)))
    return nil
  end
  local t = type(res)
  local show
  if t == "table" then
    local parts = {}
    for i, v in ipairs(res) do parts[#parts + 1] = tostring(v) end
    show = "{ " .. table.concat(parts, ", ") .. " }"
  else
    show = tostring(res)
  end
  print(string.format("  %-22s %-6s %s", name, t, show))
  return res
end

print("---- 四个干活信号 ----")
probe("hasWork")
probe("getWorkMaxProgress")
probe("getWorkProgress")
probe("isMachineActive")
probe("isWorkAllowed")

print("---- 连续 3 秒采样 getWorkProgress（看它在不在涨） ----")
for i = 1, 4 do
  local ok, res = pcall(component.invoke, gt, "getWorkProgress")
  print(string.format("  t=%d  getWorkProgress=%s", i, ok and tostring(res) or ("ERR " .. tostring(res))))
  os.sleep(1)
end

print("---- 传感器原文（看总运行时长/问题数等） ----")
local ok, info = pcall(component.invoke, gt, "getSensorInformation")
if ok then
  if type(info) == "string" then info = { info } end
  for _, line in ipairs(info or {}) do
    print("  | " .. strip(line))
  end
else
  print("  读传感器失败：" .. tostring(info))
end
