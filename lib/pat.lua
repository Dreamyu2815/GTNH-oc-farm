-- 样板搬运：仓库接口 ⇄ 农场下单接口
-- 前提：所有接口都在同一张 ME 网上，且电脑上插着「ME 接口终端」部件（已贴适配器）
-- 关键调用：component.invoke(terminal, "send", src, dst)，src/dst = {location={x,y,z,dimension}, side=.., slot=..}
local component = require("component")

local pat = {}
pat.__index = pat

function pat.new(cfg, aeaddr)
  return setmetatable({ cfg = cfg, term = cfg.ae and cfg.ae.terminal }, pat)
end

function pat:terminal()
  local a = self.cfg.ae and self.cfg.ae.terminal
  if a then
    local ok = pcall(component.proxy, a)
    if ok then return a end
  end
  for addr in component.list("me_interface_terminal", true) do return addr end
  return nil
end

function pat:ifaces()
  local t = self:terminal()
  if not t then return {} end
  local ok, res = pcall(function() return component.invoke(t, "getInterfaces") end)
  if not ok or type(res) ~= "table" then return {} end
  return res
end

local function loc(entry)
  local l = entry.location
  if type(l) == "table" then return { x = l.x, y = l.y, z = l.z, dimension = l.dimId or l.dimension } end
  return nil
end

function pat:name_of(entry)
  local n = entry.name
  if n == nil or n == "Nothing" then return "" end
  return tostring(n)
end

function pat:count(entry)
  local p = entry.patterns
  if type(p) ~= "table" then return 0 end
  local n = 0
  for k, v in pairs(p) do
    if type(k) == "number" then n = n + 1 end
  end
  return n
end

function pat:slots(entry)
  local out = {}
  local p = entry.patterns
  if type(p) ~= "table" then return out end
  for k, v in pairs(p) do
    if type(k) == "number" and v ~= nil then out[#out + 1] = k end
  end
  table.sort(out)
  return out
end

function pat:is_farm(entry)
  local n = self:name_of(entry):lower()
  return n:find("industrialfarm", 1, true) ~= nil or n:find("industrial_farm", 1, true) ~= nil
end

-- 仓库：优先 config 里写的名字（如"仓库"），否则 name 为空/Nothing 的接口
function pat:warehouse()
  local want = self.cfg.ae and self.cfg.ae.warehouse_name
  local cand, candEmpty = nil, nil
  for _, e in ipairs(self:ifaces()) do
    local n = self:name_of(e)
    if want and n == want then
      if not cand or self:count(e) > self:count(cand) then cand = e end
    end
    if not self:is_farm(e) and (n == "" or n == "Nothing") then
      if not candEmpty or self:count(e) > self:count(candEmpty) then candEmpty = e end
    end
  end
  return cand or candEmpty
end

-- 农场下单接口：优先 config 里 farms[id].interface_name（如"农场1"）
function pat:farm(id)
  local f = nil
  for _, x in ipairs(self.cfg.farms or {}) do if x.id == id then f = x end end
  local want = f and f.interface_name
  for _, e in ipairs(self:ifaces()) do
    if want and self:name_of(e) == want then return e end
  end
  for _, e in ipairs(self:ifaces()) do
    if self:is_farm(e) then return e end
  end
  return nil
end

function pat:entry_by_loc(target)
  if not target then return nil end
  local t = loc(target)
  if not t then return nil end
  for _, e in ipairs(self:ifaces()) do
    local l = loc(e)
    if l and l.x == t.x and l.y == t.y and l.z == t.z then return e end
  end
  return nil
end

-- 实际搬运：返回 ok, 说明。dst_slot 缺省 0（旧行为，单样板时可用）
function pat:move(src_entry, src_slot, dst_entry, dst_slot)
  local t = self:terminal()
  if not t then return false, "没有接口终端" end
  if not src_entry or not dst_entry then return false, "没找到源或目标接口" end
  local s, d = loc(src_entry), loc(dst_entry)
  if not s or not d then return false, "接口没有坐标" end
  local src = { location = s, side = src_entry.side, slot = src_slot or 0 }
  local dst = { location = d, side = dst_entry.side, slot = (dst_slot ~= nil) and dst_slot or 0 }
  local ok, res = pcall(function() return component.invoke(t, "send", src, dst) end)
  if not ok then return false, "调用失败：" .. tostring(res) end
  if res ~= true then return false, "返回 " .. tostring(res) end
  -- send 返回 true = AE 已确认搬运完成，这就是成功判据。
  -- 下面的"槽位数变化"只当锦上添花的确认：接口列表本身有刷新延迟，
  -- 而且有的接口收到样板后会立刻推进网络存储、槽位数根本不涨，
  -- 拿它当失败判据会误报"搬回失败"（实测样板已经搬回来了）。最多等 3 秒。
  local before_src, before_dst = self:count(src_entry), self:count(dst_entry)
  for i = 1, 6 do
    os.sleep(0.5)
    local s2 = self:entry_by_loc(src_entry)
    local d2 = self:entry_by_loc(dst_entry)
    if s2 and d2 then
      local cs, cd = self:count(s2), self:count(d2)
      if cs < before_src and cd > before_dst then
        return true, string.format("槽 %d：%d→%d，%d→%d", src_slot or 0, cs + 1, cs, cd - 1, cd)
      end
    end
  end
  return true, "已发送（接口列表刷新慢，槽位数没来得及变，属正常）"
end

-- 把农场接口上残留的样板搬回仓库（发配前清场）。每搬一个都重查仓库取最新空槽，
-- 多作物时仓库可能已经放着好几个样板，不能都塞 0 号槽。
function pat:sweep()
  local moved = 0
  for _ = 1, 32 do
    local wh = self:warehouse()
    if not wh then return false, "没找到仓库接口" end
    local target, tslot = nil, nil
    for _, e in ipairs(self:ifaces()) do
      if self:is_farm(e) or (self.cfg.farms and (function()
        for _, f in ipairs(self.cfg.farms) do
          if f.interface_name and self:name_of(e) == f.interface_name then return true end
        end
        return false
      end)()) then
        local sl = self:slots(e)
        if #sl > 0 then target, tslot = e, sl[1] break end
      end
    end
    if not target then return true, moved end
    local free = self:free_slot(wh)
    if free == nil then return false, "仓库没空槽了" end
    local ok, msg = self:move(target, tslot, wh, free)
    if not ok then return false, "搬回失败：" .. tostring(msg) end
    moved = moved + 1
  end
  return true, moved
end

-- 样板 itemstack 上某个物品字段的显示名
local function stack_label(v)
  if type(v) ~= "table" then return nil end
  local l = v.label or v.displayName or v.name
  if l ~= nil and tostring(l) ~= "" then return tostring(l) end
  return nil
end

-- 样板里能读到的产物名、输入名（GTNH 的样板带 outputs/inputs 字段）
function pat:pattern_labels(stack)
  local outs, ins = {}, {}
  if type(stack) == "table" then
    if type(stack.outputs) == "table" then
      for _, v in pairs(stack.outputs) do local l = stack_label(v) if l then outs[#outs + 1] = l end end
    end
    if type(stack.inputs) == "table" then
      for _, v in pairs(stack.inputs) do local l = stack_label(v) if l then ins[#ins + 1] = l end end
    end
  end
  return outs, ins
end

-- 这个样板是不是某作物的（产物名或种子输入名对得上）
function pat:pattern_matches(stack, crop)
  local outs, ins = self:pattern_labels(stack)
  for _, l in ipairs(outs) do if l == crop then return true end end
  local seed = tostring(crop) .. "种子"
  for _, l in ipairs(ins) do if l == seed then return true end end
  return false
end

-- 仓库里某种作物的样板槽号：先按样板产物/种子自动匹配，再退 config.pattern_slot
function pat:slot_for(crop)
  local m = self.cfg.pattern_slot
  if m and m[crop] then return m[crop] end
  local wh = self:warehouse()
  if not wh then return nil, "没找到仓库接口" end
  local sl = self:slots(wh)
  if #sl == 0 then return nil, "仓库里没有样板" end
  for _, slot in ipairs(sl) do
    local st = wh.patterns and wh.patterns[slot]
    if self:pattern_matches(st, crop) then return slot end
  end
  if #sl == 1 then return sl[1] end
  return nil, string.format("仓库里有 %d 个样板，没找到「%s」的样板（样板产物名对不上；可在 config.lua 的 pattern_slot 里手动指定槽号）", #sl, tostring(crop))
end

-- 仓库里第一个没放样板的槽（0 起）
function pat:free_slot(entry)
  local used = {}
  if type(entry.patterns) == "table" then
    for k in pairs(entry.patterns) do if type(k) == "number" then used[k] = true end end
  end
  for i = 0, 15 do
    if not used[i] then return i end
  end
  return nil
end

return pat
