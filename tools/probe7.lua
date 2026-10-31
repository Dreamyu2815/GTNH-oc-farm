-- probe7.lua —— ④ 产物识别（name+damage 过滤）与 ⑦ 事件订阅 实测
-- 只读，不改任何设置（setItemEventSubscription 会恢复成 false）
local component = require("component")
local computer = require("computer")
local event = require("event")
local serialization = require("serialization")

local ROOT = "/home/ocfarm"
local function loadmod(name)
  return assert(loadfile(ROOT .. "/lib/" .. name .. ".lua"))()
end
local util = loadmod("util")
local ae = loadmod("ae")
local cfg = assert(loadfile(ROOT .. "/config.lua"))()
local A = ae.new(cfg.ae)

local out = {}
local function P(s, ...)
  local line = select("#", ...) > 0 and string.format(s, ...) or s
  out[#out + 1] = line
  print(line)
end
local function flush()
  local f = io.open(ROOT .. "/probe7.txt", "w")
  if f then f:write(table.concat(out, "\n") .. "\n"); f:close() end
end
local function nowu() return computer.uptime() end

P("===== probe7：产物识别 + 事件订阅 =====")
P("时间：%s", os.date("%H:%M:%S"))

-- ===== 1. 全量扫描（基线） =====
local t0 = nowu()
local prod = A:items_by_label("storage")
local t_scan = nowu() - t0
local CROP = "空间之花"
local base = (prod[CROP] and prod[CROP].count) or 0
P("[基线] 全量扫描 %.0f 秒，读到 %d 种物品，%s = %d", t_scan * 1000, 0, CROP, base)

-- 找出产物物品的真实 name / damage
local pname, pdamage = nil, nil
if prod[CROP] then
  pname = prod[CROP].name
  pdamage = prod[CROP].damage
end
P("[基线] 产物 name=%s damage=%s label=%s", tostring(pname), tostring(pdamage), tostring(prod[CROP] and prod[CROP].label))

-- ===== 2. 三种过滤查询对比 =====
local function try_query(tag, filter)
  local t = nowu()
  local ok, res = pcall(function() return component.invoke(cfg.ae.storage, "getItemsInNetwork", filter) end)
  local dt = nowu() - t
  if not ok then
    P("[查询] %-28s 调用失败：%s", tag, tostring(res))
    return nil
  end
  local n, cnt = 0, 0
  if type(res) == "table" then
    for _, s in ipairs(res) do
      n = n + 1
      cnt = cnt + (s.size or 0)
    end
  elseif res ~= nil then
    -- 可能是迭代器 userdata
    local ok2 = pcall(function()
      for s in res do n = n + 1; cnt = cnt + (s.size or 0) end
    end)
    if not ok2 then P("[查询] %-28s 返回类型 %s，无法解析", tag, type(res)) end
  end
  P("[查询] %-28s 条目=%d 总量=%d 用时=%.0f ms", tag, n, cnt, dt * 1000)
  return cnt
end

try_query("name", { name = pname })
try_query("name+damage", { name = pname, damage = pdamage })
try_query("label", { label = CROP })
try_query("name(错名试错)", { name = "no.such.item" })

-- ===== 3. 事件订阅 =====
P("----- 事件订阅 -----")
local function sub_state()
  local ok, v = pcall(function() return component.invoke(cfg.ae.storage, "isItemEventSubscription") end)
  if not ok then return "错误：" .. tostring(v) end
  return tostring(v)
end
P("[订阅] 当前状态 = %s", sub_state())

local ok_set, res_set = pcall(function() return component.invoke(cfg.ae.storage, "setItemEventSubscription", true) end)
P("[订阅] setItemEventSubscription(true) → ok=%s res=%s", tostring(ok_set), tostring(res_set))
P("[订阅] 开启后状态 = %s", sub_state())

-- 监听 20 秒，记录所有事件名（排除键盘/中断）
P("[订阅] 监听 20 秒……")
local t_end = nowu() + 20
local seen, seq = {}, {}
while nowu() < t_end do
  local e = { event.pull(1) }
  if e[1] and e[1] ~= "key_down" and e[1] ~= "interrupted" and e[1] ~= "key_up" then
    if not seen[e[1]] then seen[e[1]] = 0 end
    seen[e[1]] = seen[e[1]] + 1
    if #seq < 12 then
      local parts = { tostring(e[1]) }
      for i = 2, math.min(#e, 6) do parts[#parts + 1] = tostring(e[i]) end
      seq[#seq + 1] = table.concat(parts, " | ")
    end
  end
  if e[1] == "key_down" then
    local a = e[3]
    if type(a) == "string" and a:sub(1, 1) == "q" then break end
  end
end
if next(seen) then
  local names = {}
  for k, v in pairs(seen) do names[#names + 1] = string.format("%s×%d", k, v) end
  P("[订阅] 收到事件：%s", table.concat(names, ", "))
else
  P("[订阅] 20 秒内没有收到任何非键盘事件")
end
for _, s in ipairs(seq) do P("[订阅]   %s", s) end

pcall(function() return component.invoke(cfg.ae.storage, "setItemEventSubscription", false) end)
P("[订阅] 已恢复为 %s", sub_state())

-- ===== 4. 结论 =====
P("----- 结论 -----")
P("过滤查询若能用，产物识别改 name+damage，读网时间会从 %.0f ms 降到上面几行的量级", t_scan * 1000)
flush()
P("已写入 /home/ocfarm/probe7.txt")
