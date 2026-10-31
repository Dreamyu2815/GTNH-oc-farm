-- 让主循环安全退出：建一个 stop 文件
local ROOT = "/home/ocfarm"
local path = ROOT .. "/stop"
local f = io.open(path, "w")
if not f then
  print("创建失败: " .. path)
  return
end
f:write("stop\n")
f:close()
print("已创建 " .. path)
print("主循环会在这轮结束时（最多几秒）安全退出，并自动删掉这个文件")
