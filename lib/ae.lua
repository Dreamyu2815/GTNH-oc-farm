-- AE 封装：两张网（存储 / 种子）+ 接口终端搬样板
-- 注意：这一版 OC 里 proxy 上的"方法"是 table（带 __call），不是 function；
-- 所以既试 proxy[name](...)，也回退到 component.invoke(addr, name, ...)。
local component = require("component")
local util = require("lib.util")

-- 英文名 -> 中文名（英文客户端/未本地化作物的 label 是英文时翻回中文）
-- 多路径加载：require 依赖 cwd，服务器上不一定找得到 → 再试相对/绝对路径
local CROPS_ZH = {}
do
  local okz, mz = pcall(require, "crops_zh")
  if okz and type(mz) == "table" then CROPS_ZH = mz end
  if not next(CROPS_ZH) then
    for _, p in ipairs({ "crops_zh.lua", "/home/ocfarm/crops_zh.lua", "lib/crops_zh.lua" }) do
      local ok2, m2 = pcall(dofile, p)
      if ok2 and type(m2) == "table" and next(m2) then CROPS_ZH = m2 break end
    end
  end
end
local function zh(s)
  local z = CROPS_ZH[s]
  return z or s
end

local ae = {}
ae.__index = ae

-- OC 的迭代器 userdata / 表都能吃
local function drain(x)
  if x == nil then return {} end
  if type(x) == "table" then return x end
  if type(x) ~= "userdata" and type(x) ~= "function" then return {} end
  local out = {}
  for _ = 1, 500000 do
    local ok, v = pcall(x)
    if not ok or v == nil then break end
    out[#out + 1] = v
  end
  return out
end

-- 统一调用：先试 proxy，再试 invoke
local function invoke(addr, method, ...)
  if not addr then return false, "no address" end
  local okp, proxy = pcall(component.proxy, addr)
  if okp and proxy then
    local f = proxy[method]
    if f ~= nil then
      local ok, res = pcall(f, ...)
      if ok then return true, res end
      -- 有些方法要通过地址调，继续回退
    end
  end
  local ok, res = pcall(component.invoke, addr, method, ...)
  if not ok then return false, tostring(res) end
  return true, res
end

local function call_obj(obj, method, ...)
  if obj == nil then return false, "nil object" end
  local f = obj[method]
  if f == nil then return false, "no method " .. tostring(method) end
  return pcall(f, ...)
end

function ae.new(opts)
  local self = setmetatable({}, ae)
  self.opts = opts or {}
  return self
end

-- kind: "storage" / "seed" / "terminal"，返回地址
function ae:addr(kind)
  return self.opts[kind]
end

-- 某张网上的全部物品栈
function ae:items(kind)
  local addr = self:addr(kind)
  if not addr then return {} end
  local ok, res = invoke(addr, "getItemsInNetwork")
  if not ok then
    ok, res = invoke(addr, "allItems")
  end
  if not ok then return {} end
  return drain(res)
end

-- 原始列表（一次读取，调用方自己聚合，避免同一张网重复读）
function ae:raw(kind)
  return self:items(kind)
end

-- 带过滤的查询：第一个参数是 {label=…} / {name=…} 这类表，AE 侧先过滤，返回的条目少得多
function ae:query(kind, filter)
  local addr = self:addr(kind)
  if not addr then return {} end
  local ok, res = invoke(addr, "getItemsInNetwork", filter)
  if not ok then return {} end
  return drain(res)
end

-- 按物品注册名统计数量
function ae:count_item(kind, name)
  local total = 0
  for _, stack in ipairs(self:items(kind)) do
    if stack.name == name then
      total = total + (stack.size or 0)
    end
  end
  return total
end

-- 统计某张网里的种子：cropId -> { count, stack }
function ae:seeds_by_crop(kind)
  local out = {}
  for _, stack in ipairs(self:items(kind)) do
    if stack.name == "cropsnh:genericSeed" then
      local crop = util.find_tag(stack.tag, "crop")
      if crop then
        local e = out[crop]
        if not e then
          e = { count = 0, stack = stack }
          out[crop] = e
        end
        e.count = e.count + (stack.size or 0)
      end
    end
  end
  return out
end

-- 按显示名/注册名找可合成的条目（返回 craftable 对象）
-- 直接复用 craftables()，避免这里再用错方法名（getItemStack -> getStack）
function ae:find_craftable(kind, name)
  return self:find_craftable_by_label(kind, name)
end

-- 下单（返回 job 或 nil, err）
function ae:request(kind, name, amount, cpu)
  local entry, ferr = self:find_craftable(kind, name)
  if not entry then return nil, tostring(ferr) end
  local ok, job
  if cpu then
    ok, job = call_obj(entry, "request", amount, true, cpu)
  end
  if not ok or job == nil then
    ok, job = call_obj(entry, "request", amount)
  end
  if not ok then return nil, tostring(job) end
  return job
end

-- 接口终端：列出可见接口
function ae:interfaces()
  local addr = self:addr("terminal")
  if not addr then return {}, "no terminal" end
  local ok, res = invoke(addr, "getInterfaces")
  if not ok then return {}, tostring(res) end
  return drain(res)
end

-- 按显示名统计种子：label 去掉末尾"种子"（中文）或 "Seed(s)"（英文）
function ae:seeds_by_label(kind)
  local out = {}
  for _, stack in ipairs(self:items(kind)) do
    if stack.name == "cropsnh:genericSeed" then
      local label = tostring(stack.label or "")
      local name = zh(label:gsub("种子$", ""):gsub("%s+[Ss]eeds?$", ""))
      local e = out[name]
      if not e then
        e = { count = 0, label = label, stack = stack }
        out[name] = e
      end
      e.count = e.count + (stack.size or 0)
    end
  end
  return out
end

-- 按显示名统计全部物品
function ae:items_by_label(kind)
  local out = {}
  for _, stack in ipairs(self:items(kind)) do
    local label = tostring(stack.label or "")
    local e = out[label]
    if not e then
      e = { count = 0, name = stack.name, damage = stack.damage }
      out[label] = e
    end
    e.count = e.count + (stack.size or 0)
  end
  return out
end

-- 列出可合成条目（原始信息，便于排查）
-- 注意：这一版 OC 的 Craftable 对象方法叫 getStack，不是 getItemStack
function ae:craftables(kind)
  local addr = self:addr(kind)
  if not addr then return nil, "no address" end
  local ok, res = invoke(addr, "getCraftables")
  if not ok then return nil, tostring(res) end
  local function stack_of(entry)
    local o, st = call_obj(entry, "getStack")
    if o and type(st) == "table" then return st end
    o, st = call_obj(entry, "getItemStack")
    if o and type(st) == "table" then return st end
    return nil
  end
  local out = {}
  for _, entry in ipairs(drain(res)) do
    local stack = stack_of(entry)
    if stack then
      out[#out + 1] = {
        entry = entry,
        label = tostring(stack.label or ""),
        name = tostring(stack.name or ""),
        damage = stack.damage,
        size = stack.size,
      }
    end
  end
  return out
end

local function plain(s)
  return (tostring(s):gsub("\194\167.", ""))
end

-- 按显示名找可合成条目
function ae:find_craftable_by_label(kind, label)
  local list, err = self:craftables(kind)
  if not list then return nil, tostring(err) end
  local want = plain(label)
  for _, e in ipairs(list) do
    if plain(e.label) == want or e.name == label then return e.entry end
  end
  -- 退一步：前缀匹配（"空间之花种子" 与 "空间之花种子 " 之类）
  for _, e in ipairs(list) do
    local got = plain(e.label)
    if got:find(want, 1, true) or want:find(got, 1, true) then return e.entry end
  end
  local names = {}
  for i = 1, math.min(#list, 8) do names[i] = list[i].label end
  return nil, "没有样板: " .. tostring(label) .. "（现有: " .. table.concat(names, ", ") .. "）"
end

-- 读样板的倍增数（mult）：可合成条目的产物栈 size 就是"每份出几个"。
-- 1:1 样板里进、出数量一致，所以它也等于"每份发几颗种子"。
-- 读不到（无样板/名字对不上/size 缺失）返回 nil，由调用方退回 config 里的 mult。
function ae:craftable_mult(kind, label)
  local list, err = self:craftables(kind)
  if not list then return nil, tostring(err) end
  local want = plain(label)
  local function pick(e)
    if plain(e.label) == want or e.name == label then
      return e
    end
    local got = plain(e.label)
    if got:find(want, 1, true) or want:find(got, 1, true) then return e end
    return nil
  end
  for _, e in ipairs(list) do
    local hit = pick(e)
    if hit and hit.size and math.floor(hit.size) > 0 then
      return math.floor(hit.size)
    end
  end
  return nil, "no craftable size for " .. tostring(label)
end

-- 列出网络里 OC 可见的合成 CPU（= 装了合成监控器 Crafting Monitor 的 CPU）。
-- 没装监控器的 CPU 对 OC 完全不可见，getCpus() 就看不到它。
-- 返回 {} + 空表 表示"一个可见 CPU 都没有"（这是"忘装监控器"的直接信号）。
function ae:get_cpus()
  local addr = self:addr("seed")
  if not addr then return {}, "no seed interface" end
  local ok, res = invoke(addr, "getCpus")
  if not ok then return {}, tostring(res) end
  return drain(res)
end

-- 把样板从 from 搬到 to（等价于"清空旧位置"）
-- from/to = { x=, y=, z=, side=, slot=, dimension= }
function ae:move_pattern(from, to)
  local addr = self:addr("terminal")
  if not addr then return false, "no terminal" end
  local function mk(d)
    return {
      location = { x = d.x, y = d.y, z = d.z, dimension = d.dimension or 0 },
      side = d.side or 0,
      slot = d.slot or 0,
    }
  end
  local task = { source = mk(from), target = mk(to) }
  local ok, err = invoke(addr, "send", task)
  if ok then return true end
  local ok2, err2 = invoke(addr, "sendBatch", { task })
  if ok2 then return true end
  return false, tostring(err) .. " | " .. tostring(err2)
end

-- 统计空闲的合成 CPU：返回 free, total
-- 判 busy 用 cpu:isBusy()；调不通就退 isActive()；两者都读不到时按"空闲"处理，避免死等。
function ae:free_cpus()
  local list = self:get_cpus()
  local free, total = 0, 0
  for _, c in ipairs(list or {}) do
    total = total + 1
    local busy = false
    local ok, v = pcall(function() return c:isBusy() end)
    if not ok then
      ok, v = pcall(function() return c.isBusy(c) end)
    end
    if ok and v == true then
      busy = true
    else
      local ok2, v2 = pcall(function() return c:isActive() end)
      if ok2 and v2 == true then busy = true end
    end
    if not busy then free = free + 1 end
  end
  return free, total
end

-- 下单前等一个空闲合成 CPU（别的农场正在发配时排队等，不要硬挤进去）
-- 返回 true, 等待秒数 / false, 原因
function ae:wait_free_cpu(limit, onwait)
  local limit = tonumber(limit) or 300
  local comp = require("computer")
  local t0 = comp.uptime()
  while true do
    local free, total = self:free_cpus()
    if total == 0 then return true, 0 end          -- 看不到 CPU 就别卡着
    local el = comp.uptime() - t0
    if free > 0 then return true, el end
    if onwait then onwait(total, el) end
    if el > limit then
      return false, string.format("合成 CPU 全被占用，等了 %.0f 秒还没空出来（共 %d 个）", el, total)
    end
    os.sleep(1)
  end
end

return ae
