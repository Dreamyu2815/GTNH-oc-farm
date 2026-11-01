-- 单独测试：给一次红石脉冲，看农场模式有没有变
-- 判定依据：切到 Farm 后 hasWork 变 true、EU 开始掉、工作进度会走
local cfg = dofile("/home/ocfarm/config.lua")
local F = dofile("/home/ocfarm/lib/farmio.lua")
local component = require("component")
local farm = cfg.farms[1]
local gt, rs = farm.gt, farm.redstone

-- 端口被拆过/挪过，地址就会变；这里自动挑当前唯一的 redstone 端口
local function adr_ok(a)
  if not a then return false end
  local ok, p = pcall(component.proxy, a)
  return ok and p ~= nil
end
local function redstones()
  local t = {}
  for a, ty in component.list("redstone", true) do
    if ty == "redstone" then t[#t + 1] = a end
  end
  return t
end
if not adr_ok(rs) then
  local c = redstones()
  if #c == 1 then
    print("[自愈] 配置里的红石地址失效，改用当前唯一端口：" .. c[1])
    rs = c[1]
  else
    print("[错误] 配置里的红石地址 " .. tostring(rs) .. " 不存在；当前有 " .. #c .. " 个 redstone 端口：")
    for _, a in ipairs(c) do print("   " .. a) end
    print("请把 config.lua 里的 farms[1].redstone 改成其中一个再跑。")
    return
  end
end

local function num(v)
  if type(v) == "number" then return string.format("%.0f", v) end
  return tostring(v)
end

local function call(method, ...)
  local ok, res = F.invoke_raw(gt, method, ...)
  if not ok then return nil, tostring(res) end
  return res
end

local function tablet_addr()
  for a, t in component.list("tt_animationTablet", true) do
    if t == "tt_animationTablet" then return a end
  end
  return nil
end
-- 只读：工具台如果还在 OC 网络上，就把它的几个状态念一遍（绝不 set）
local function tablet_state()
  local a = tablet_addr()
  if not a then return "（不在 OC 网络上）" end
  local function rd(m)
    local ok, r = pcall(component.invoke, a, m)
    return ok and tostring(r) or "ERR"
  end
  return string.format("redstone=%s leftClick=%s rotation=%s hasItem=%s",
    rd("getRedstone"), rd("getLeftClick"), rd("getRotation"), rd("hasItem"))
end

print("==== 红石脉冲测试 ====")
print("工具台状态(前)：" .. tablet_state())

-- 传感器最多试 3 次，失败把错误打出来
local info, serr
for i = 1, 3 do
  info, serr = F:read_sensor(gt)
  if info then break end
  print(string.format("  传感器第 %d 次失败：%s", i, tostring(serr)))
  os.sleep(1)
end
if info then
  print("传感器：等级=" .. num(info.level) .. " 容量=" .. num(info.capacity) .. " 耗水=" .. num(info.water))
else
  print("传感器：读不到（" .. tostring(serr) .. "）")
end

print("红石地址=" .. tostring(rs))
local rok, rerr = F:test_redstone(rs)
print("六面写 0 测试：" .. tostring(rok) .. (rok and "" or ("  " .. tostring(rerr))))

local function snap(tag)
  local hw, e1 = call("hasWork")
  local act, e2 = call("isMachineActive")
  local prog = call("getWorkProgress")
  local maxp = call("getWorkMaxProgress")
  local eu = call("getEUStored")
  print(string.format("%-7s hasWork=%s active=%s progress=%s/%s EU=%s%s",
    tag, tostring(hw), tostring(act), num(prog), num(maxp), num(eu),
    (hw == nil) and ("  err=" .. tostring(e1)) or ""))
  return { hw = hw, prog = prog, eu = eu }
end

local before = snap("之前")
local width = (cfg.timing and cfg.timing.pulse_width) or 0.1
local side = tonumber(arg and arg[1]) or farm.redstone_side
if side ~= nil then
  print("→ 发脉冲（单面 " .. side .. " 写 15，" .. tostring(width) .. " 秒）")
else
  print("→ 发脉冲（六面 15，" .. tostring(width) .. " 秒）—— 没配 redstone_side")
end
local pok, perr = F:pulse(rs, width, side)
print("脉冲结果：" .. tostring(pok) .. " " .. tostring(perr))

os.sleep(2)
local after2 = snap("2秒后")
print("工具台状态(后)：" .. tablet_state())
os.sleep(10)
local after10 = snap("12秒后")

print("")
print("==== 判定 ====")
if after10.hw == true and before.hw ~= true then
  print("[成功] 农场进入工作状态 → 模式已经切到 Farm")
elseif type(after10.eu) == "number" and type(before.eu) == "number" and after10.eu < before.eu - 1000 then
  print("[成功] EU 在掉 → 农场在工作（模式已切 Farm）")
elseif type(after10.prog) == "number" and type(after2.prog) == "number" and after10.prog ~= after2.prog then
  print("[成功] 工作进度在走 → 模式已切 Farm")
else
  print("[失败] 农场没动静")
  print("  排查顺序：")
  print("  1. 活化工具台里有没有插【螺丝刀】：工具台必须手持工具才会挥，空手点击不会触发 GT 的螺丝刀逻辑")
  print("  2. 红石 I/O 端口是不是紧贴工具台（六面同发只是省事，物理上必须挨着）")
  print("  3. 工具台正前方那格是不是农场控制器，朝向对不对")
  print("  4. 农场现在是不是 Input 模式（Farm 模式下再点会去 Output）")
end
