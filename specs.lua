-- specs.lua —— 本机配置体检：这台电脑跑得动农场程序吗？
-- 用法：lua specs.lua
-- 判据（GTNH 2.9.0-RC-2 的 OpenComputers 配置）：
--   CPU 组件上限：T1=8 / T2=12 / T3=16
--   RAM 可装：192/256/384/512/768/1024 KB（<384 跑这套会紧张）
--   硬盘：1MB / 2MB / 4MB；软盘 512KB
--   GPU/屏幕：T1 50×16 / T2 80×25 / T3 160×50（仪表盘要 T3）
local component = require("component")
local computer = require("computer")

local function line(f, ...)
  local ok, s = pcall(string.format, f, ...)
  print(ok and s or f)
end

print("==== 本机配置体检 ====")

local n, kinds = 0, {}
for _addr, ty in component.list() do
  n = n + 1
  kinds[ty] = (kinds[ty] or 0) + 1
end
local kk = {}
for k in pairs(kinds) do kk[#kk + 1] = k end
table.sort(kk)

line("组件总数：%d（CPU 上限 T1=8 / T2=12 / T3=16）", n)
for _, k in ipairs(kk) do
  line("  %-26s x %d", k, kinds[k])
end
print("")

line("内存：总 %d KB / 空闲 %d KB", computer.totalMemory(), computer.freeMemory())
print("")

local okg, gpu = pcall(function() return component.gpu end)
if okg and gpu then
  local ok2, mw, mh = pcall(function() return gpu.maxResolution() end)
  if ok2 then
    line("屏幕最大分辨率：%s×%s（T1 50×16 / T2 80×25 / T3 160×50）", tostring(mw), tostring(mh))
  end
end

local okfs, fs = pcall(require, "filesystem")
if okfs then
  local ok2, used, total = pcall(fs.space, "/")
  if ok2 and type(used) == "number" and type(total) == "number" then
    line("磁盘：已用 %d KB / 总 %d KB", math.floor(used / 1024), math.floor(total / 1024))
  end
end
print("")

print("==== 结论 ====")
if n > 16 then
  line("组件数 %d 超过 T3 上限 16：减组件（每台农场要 2 个：gt_machine + 红石 I/O），或上服务器机架", n)
elseif n > 12 then
  line("组件数 %d：T2(12) 不够 → 需要 T3 CPU(16)", n)
elseif n > 8 then
  line("组件数 %d：T1(8) 不够，T2(12) 够", n)
else
  line("组件数 %d：T1(8) 够", n)
end

local mt = computer.totalMemory()
if mt < 384 then
  line("内存 %d KB 偏小：这套程序建议 ≥384KB（192KB 大概率 OOM）", mt)
else
  line("内存 %d KB 够用（≥384KB）", mt)
end
