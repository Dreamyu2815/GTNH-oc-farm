-- ============================================================
--  discover.lua：扫描种子网络 + 仓库样板，输出自动配置所需信息
--  用法：在 OC 里 cd /home/ocfarm && lua discover.lua
--  只读；结果写到 /home/ocfarm/discover.txt
--  它把「网络里有什么种子/垫块、仓库里有哪些样板（含原料+产物+倍率）」
--  全部打印出来，供自动生成 config.lua 的 crops / priority / thresholds。
-- ============================================================
local component = require("component")
local util = require("lib.util")
local cfg = dofile("/home/ocfarm/config.lua")
util.merge_ae(cfg, "/home/ocfarm")   -- 网络地址以 ae.dat 为准
local CROPS = dofile("/home/ocfarm/crops.lua")

local out = {}
local function p(fmt, ...)
  local s
  if select("#", ...) > 0 then
    local ok, f = pcall(string.format, fmt, ...)
    s = ok and f or tostring(fmt)
  else
    s = tostring(fmt)
  end
  out[#out + 1] = s
  print(s)
end

-- 这一版 OC 里 proxy 上的"方法"是 table（带 __call），不是 function：
-- 先试 proxy[name](...)，失败再走 component.invoke(addr, name, ...)（和 lib/ae.lua 一致）
local function call(addr, method, ...)
  if not addr then return nil, "没有地址" end
  local okp, proxy = pcall(component.proxy, addr)
  if okp and proxy then
    local f = proxy[method]
    if f ~= nil then
      local ok, res = pcall(f, ...)
      if ok then return res end
    end
  end
  local ok, res = pcall(component.invoke, addr, method, ...)
  if not ok then return nil, tostring(res) end
  return res
end

local function stack_label(v)
  if type(v) ~= "table" then return nil end
  local l = v.label or v.displayName or v.name
  if l ~= nil and tostring(l) ~= "" then return tostring(l) end
  return nil
end

-- 解析样板 itemstack：产物 / 种子 / 垫块 / 倍率
local function parse_pattern(stack)
  local outs, ins = {}, {}
  if type(stack) == "table" then
    if type(stack.outputs) == "table" then
      for _, v in pairs(stack.outputs) do if type(v) == "table" then outs[#outs + 1] = v end end
    end
    if type(stack.inputs) == "table" then
      for _, v in pairs(stack.inputs) do if type(v) == "table" then ins[#ins + 1] = v end end
    end
  end
  local function lbl(v) return tostring(v.label or v.displayName or v.name or "") end
  local product = outs[1] and lbl(outs[1]) or "?"
  local mult = outs[1] and outs[1].size or "?"
  local seed, subsoil = nil, nil
  for _, v in ipairs(ins) do
    local l = lbl(v)
    if l:find("种子", 1, true) then
      seed = l
    elseif not subsoil then
      subsoil = l
    end
  end
  return product, seed, subsoil, mult
end

local function dump(t, indent, depth)
  if type(t) ~= "table" then return end
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = tostring(k) end
  table.sort(keys)
  for _, k in ipairs(keys) do
    local v = t[k]
    if type(v) == "table" then
      if depth > 0 then
        p("%s%s =", indent, k)
        dump(v, indent .. "  ", depth - 1)
      else
        p("%s%s = <table>", indent, k)
      end
    else
      p("%s%s = %s", indent, k, tostring(v))
    end
  end
end

-- ① 种子网络全部物品（种子带 tag.crop，垫块就是普通物品）
p("==== 种子网络物品 ====")
local seedAddr = cfg.ae and cfg.ae.seed
local items, ierr = call(seedAddr, "getItemsInNetwork")
if not items then
  p("getItemsInNetwork 失败: %s", tostring(ierr))
else
  local list = {}
  for _, s in ipairs(items) do list[#list + 1] = s end
  table.sort(list, function(a, b) return tostring(a.label or a.name) < tostring(b.label or b.name) end)
  for _, s in ipairs(list) do
    local crop = util.find_tag(s.tag, "crop")
    local meta = crop and CROPS[crop] or nil
    p("  %s | %s | x%d | tag.crop=%s | crops.lua: tier=%s bed=%s name=%s",
      tostring(s.label or s.name), tostring(s.name), s.size or 0,
      tostring(crop), tostring(meta and meta.tier), tostring(meta and meta.bed), tostring(meta and meta.name))
  end
end

-- ② 接口终端：所有接口的样板（含 inputs/outputs 原始结构 + 解析结果）
p("")
p("==== 接口终端 / 仓库样板 ====")
local termAddr = cfg.ae and cfg.ae.terminal
local ifs, terr = call(termAddr, "getInterfaces")
if not ifs then
  p("getInterfaces 失败: %s", tostring(terr))
else
  for _, it in ipairs(ifs) do
    local n = 0
    if type(it.patterns) == "table" then for _ in pairs(it.patterns) do n = n + 1 end end
    local L = it.location
    p("-- 接口 name=%s side=%s loc=(%s,%s,%s) patterns=%d",
      tostring(it.name), tostring(it.side),
      tostring(L and L.x), tostring(L and L.y), tostring(L and L.z), n)
    if n > 0 and type(it.patterns) == "table" then
      local slots = {}
      for k in pairs(it.patterns) do slots[#slots + 1] = k end
      table.sort(slots)
      for _, slot in ipairs(slots) do
        local st = it.patterns[slot]
        local product, seed, subsoil, mult = parse_pattern(st)
        p("   [槽 %s] 解析：产物=%s 种子=%s 垫块=%s 倍率=%s", tostring(slot), product, tostring(seed), tostring(subsoil), tostring(mult))
        p("   [槽 %s] 原始：", tostring(slot))
        dump(st, "     ", 3)
      end
    end
  end
end

p("")
p("==== 结束 ====")
util.write("/home/ocfarm/discover.txt", table.concat(out, "\n"))
print("已写入 /home/ocfarm/discover.txt")
