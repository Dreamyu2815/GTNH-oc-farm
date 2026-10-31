-- ============================================================
--  setup.lua —— 网络地址安装向导（给"抄作业"的人用）
--  用法：lua setup.lua
--   1) 扫描已连接的 ME 接口 / 接口终端
--   2) 读每张网里的物品和样板，给出"像存储网 / 像种子网"的建议
--   3) 你按编号确认（自动判断只是建议，最终由你拍板）
--   4) 写入 /home/ocfarm/ae.dat（main.lua 启动时自动读）
--  装好后：lua bind.lua（首次绑农场）→ lua main.lua
-- ============================================================
local ROOT = "/home/ocfarm"
local util = dofile(ROOT .. "/lib/util.lua")

local component = require("component")

local function line(s) print(tostring(s)) end

local function list_of(kind)
  local t = {}
  for a, ty in component.list(kind, true) do
    if ty == kind then t[#t + 1] = a end
  end
  return t
end

-- 与 lib/ae.lua 一致：先试 proxy，再试 component.invoke
local function invoke(addr, method, ...)
  if not addr then return nil end
  local okp, proxy = pcall(component.proxy, addr)
  if okp and proxy then
    local f = proxy[method]
    if f ~= nil then
      local ok, res = pcall(f, ...)
      if ok then return res end
    end
  end
  local ok, res = pcall(component.invoke, addr, method, ...)
  if ok then return res end
  return nil
end

-- 探测一张网：有多少物品、多少种子、多少产物、多少样板
local function probe(addr)
  local p = { items = 0, seeds = 0, prods = 0, patterns = 0, ifaces = 0 }
  local items = invoke(addr, "getItemsInNetwork")
  if type(items) == "table" then
    for _, it in ipairs(items) do
      if type(it) == "table" then
        p.items = p.items + 1
        local label = it.label and tostring(it.label) or ""
        if label:find("种子$") or it.name == "cropsnh:genericSeed" then
          p.seeds = p.seeds + 1
        elseif it.name == "cropsnh:materialLeaf" then
          p.prods = p.prods + 1
        end
      end
    end
  end
  local is = invoke(addr, "getInterfaces")
  if type(is) == "table" then
    for _, e in ipairs(is) do
      if type(e) == "table" then
        p.ifaces = p.ifaces + 1
        if type(e.patterns) == "table" then
          for _ in pairs(e.patterns) do p.patterns = p.patterns + 1 end
        end
      end
    end
  end
  return p
end

local function ask(prompt, default)
  io.write(prompt)
  local s = io.read()
  if s == nil then s = "" end
  s = tostring(s):match("^%s*(.-)%s*$")
  if s == "" then return default end
  return s
end

local function ask_num(prompt, lo, hi, default)
  while true do
    local s = ask(prompt, tostring(default or ""))
    local n = tonumber(s)
    if n and n >= lo and n <= hi then return n end
    line("  ! 请输入 " .. lo .. "~" .. hi .. " 的编号")
  end
end

local function exists(path)
  local f = io.open(path, "r")
  if f then f:close(); return true end
  return false
end

-- ------------------------------------------------------------
line("")
line("===== 网络地址安装向导（setup）=====")
line("")

local ifaces = list_of("me_interface")
local terms  = list_of("me_interface_terminal")
if #ifaces == 0 then
  line("[错误] 一个 me_interface（ME 接口）都没找到。请检查：")
  line("  1) 适配器（Adapter）是否贴到了 ME 接口方块上；")
  line("  2) 接口是否通电、在网里；")
  line("  3) 然后重跑 lua setup.lua")
  return
end

line("发现 ME 接口 " .. #ifaces .. " 个：")
local info = {}
for i, a in ipairs(ifaces) do
  local p = probe(a)
  info[i] = { addr = a, p = p }
  local hint
  if p.seeds > 0 and p.patterns > 0 then
    hint = "→ 很像【种子网】（有种子、有样板）"
  elseif p.seeds > 0 then
    hint = "→ 有种子（种子网；也可能兼存储）"
  elseif p.items > 0 then
    hint = "→ 只有物品/产物，很像【存储网】"
  else
    hint = "→ 空网？检查接口是否在网里"
  end
  line(string.format("  %d) %s  物品 %d 种 / 种子 %d / 产物 %d / 样板 %d  %s",
    i, a, p.items, p.seeds, p.prods, p.patterns, hint))
end
line("")

-- 建议值：样板多在种子网；纯产物网当存储网
local def_s, def_t
for i, e in ipairs(info) do
  if def_t == nil and e.p.patterns > 0 then def_t = i end
  if def_s == nil and e.p.prods > 0 and e.p.seeds == 0 then def_s = i end
end
if def_s == nil then def_s = 1 end
if def_t == nil then def_t = 1 end

line("请按编号确认（直接回车 = 用括号里的建议值）：")
local si = ask_num("  哪张网是【存储网】（收产物）？> ", 1, #ifaces, def_s)
local ti = ask_num("  哪张网是【种子网】（种子/样板/合成 CPU）？> ", 1, #ifaces, def_t)

if si == ti then
  line("  ! 存储网和种子网选了同一张——可以，但请确认这张网确实两者都有。")
end

local term_addr = nil
if #terms > 0 then
  line("")
  line("发现接口终端 " .. #terms .. " 个（不用就输 0）：")
  for i, a in ipairs(terms) do line("  " .. i .. ") " .. a) end
  local t = ask_num("  用哪个接口终端？> ", 0, #terms, 1)
  if t > 0 then term_addr = terms[t] end
end

line("")
local wh = ask("  样板仓库接口的名字（默认 仓库）> ", "仓库")

line("")
local go = ask("  写入 ae.dat？(回车=写入，n=放弃) > ", "")
if go:lower() == "n" then
  line("已放弃，ae.dat 未改动。")
  return
end

local data = {
  seq = 1,
  storage = ifaces[si],
  seed = ifaces[ti],
  terminal = term_addr,
  warehouse_name = wh,
}
local ok, err = pcall(util.save, ROOT .. "/ae.dat", data)
if not ok then
  line("[错误] 写 ae.dat 失败：" .. tostring(err))
  return
end

line("")
line("===== 已写入 /home/ocfarm/ae.dat =====")
line("  存储网：" .. data.storage)
line("  种子网：" .. data.seed)
line("  终端  ：" .. tostring(data.terminal or "（未设置）"))
line("  仓库名：" .. data.warehouse_name)
line("")
line("下一步：")
if not exists(ROOT .. "/binds.dat") then
  line("  1) lua bind.lua     （首次安装：绑定农场）")
  line("  2) lua main.lua     （启动；F1 开仪表盘）")
else
  line("  lua main.lua        （启动；F1 开仪表盘）")
end
line("")
