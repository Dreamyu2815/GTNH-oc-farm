-- 只读观察工具台状态（绝不写任何设置）
-- 用途：一边在游戏里操作/发红石，一边看这几个值到底谁在变
local component = require("component")
local event = require("event")

local tab
for a, t in component.list("tt_animationTablet", true) do
  if t == "tt_animationTablet" then tab = a break end
end
if not tab then
  print("当前没有活化工具台组件（说明它已经不在 OC 网络上了，这样最安全）")
  return
end

print("工具台 = " .. tab)
print("本脚本只调用 get* 读取，不会 set 任何东西。")
print("按 Ctrl+Alt+C 结束。每 2 秒打印一次。")
print("")

local function read(m)
  local ok, res = pcall(component.invoke, tab, m)
  if not ok then return "ERR" end
  return tostring(res)
end

while true do
  print(string.format("%s  redstone=%s leftClick=%s rotation=%s hasItem=%s",
    os.date("%H:%M:%S"),
    read("getRedstone"), read("getLeftClick"), read("getRotation"), read("hasItem")))
  local t = os.time()
  while os.time() - t < 2 do
    event.pull(0.5)
  end
end
