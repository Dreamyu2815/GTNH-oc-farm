-- 诊断 3：结果写进 /home/ocfarm/crafts.txt（屏幕不滚动也能看全）
local ROOT = "/home/ocfarm"
local OUT = ROOT .. "/crafts.txt"

local function loadmod(name)
  local path = ROOT .. "/lib/" .. name .. ".lua"
  local f = io.open(path, "r")
  if not f then error("缺少模块: " .. path) end
  f:close()
  return dofile(path)
end

local fh = io.open(OUT, "w")
local function w(s)
  if fh then fh:write(tostring(s), "\n") end
end

local realprint = print
print = function(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
  local s = table.concat(parts, "\t")
  w(s)
  realprint(s)
end

local component = require("component")
local ae = loadmod("ae")
local cfg = dofile(ROOT .. "/config.lua")
local A = ae.new(cfg.ae)

local function dump_table(t, indent, depth)
  indent = indent or "    "
  depth = depth or 0
  if type(t) ~= "table" then
    print(indent .. tostring(t))
    return
  end
  local n = 0
  for k, v in pairs(t) do
    n = n + 1
    if n > 10 then print(indent .. "..."); break end
    print(indent .. tostring(k) .. " = " .. type(v) .. " " .. tostring(v))
  end
end

local function raw_craft(kind, title)
  print("")
  print("#### " .. title .. " getCraftables 原始返回")
  local addr = A:addr(kind)
  if not addr then print("没有地址") return end
  print("addr = " .. tostring(addr))
  local ok, res = pcall(component.invoke, addr, "getCraftables")
  if not ok then print("调用失败: " .. tostring(res)) return end
  print("type=" .. type(res) .. "  tostring=" .. tostring(res))
  if type(res) ~= "table" then return end
  local total = 0
  for _ in pairs(res) do total = total + 1 end
  print("元素个数 #res=" .. tostring(#res) .. "  pairs=" .. tostring(total))
  local i = 0
  for k, v in pairs(res) do
    i = i + 1
    if i > 5 then print("  ..."); break end
    print(string.format("  [%s] type=%s %s", tostring(k), type(v), tostring(v)))
    if type(v) == "table" then
      dump_table(v, "      ")
      for _, m in ipairs({ "getStack", "getItemStack" }) do
        local mm = v[m]
        print("      " .. m .. " 字段类型 = " .. type(mm))
        if mm ~= nil then
          local oks, st = pcall(mm)
          print("        调用 " .. tostring(oks) .. " " .. tostring(st))
          if oks and type(st) == "table" then dump_table(st, "        ") end
        end
      end
    end
  end
end

raw_craft("seed", "种子网络")
raw_craft("storage", "存储网络")

print("")
print("#### 接口终端细节")
local term = A:addr("terminal")
if term then
  local ok, res = pcall(component.invoke, term, "getInterfaces")
  if ok and type(res) == "table" then
    local i = 0
    for _, it in ipairs(res) do
      i = i + 1
      print(string.format("接口 %d: type=%s", i, type(it)))
      if type(it) == "table" then
        print("    name = " .. tostring(it.name))
        print("    side = " .. tostring(it.side))
        if type(it.location) == "table" then
          local L = it.location
          print(string.format("    loc = x%d y%d z%d dim%d", L.x or -1, L.y or -1, L.z or -1, L.dimId or -1))
        end
        if type(it.patterns) == "table" then
          local pn = 0
          for _ in pairs(it.patterns) do pn = pn + 1 end
          print("    patterns 个数=" .. pn)
          for k, v in pairs(it.patterns) do
            print(string.format("      [%s] type=%s", tostring(k), type(v)))
            if type(v) == "table" then dump_table(v, "        ") end
          end
        end
      end
    end
  else
    print("getInterfaces 失败: " .. tostring(res))
  end
end

if fh then fh:close() end
realprint("")
realprint("已写入 " .. OUT)
