-- run.lua —— 全局启动命令：装到 /bin/run.lua 后，任何目录下输入 run 即运行主程序
-- 用法：
--   run          正常启动（等价 cd /home/ocfarm && lua main.lua）
--   run dry      试运行：只看状态，不写任何东西
--   run plain    纯终端模式（不开仪表盘）
-- 退出方式同主程序：连按两次 q，或 Ctrl+C；也认 /home/ocfarm/stop 文件。
local args = table.pack(...)
local chunk, err = loadfile("/home/ocfarm/main.lua")
if not chunk then
  print("[run] 读不到主程序 /home/ocfarm/main.lua：" .. tostring(err))
  return false
end
return chunk(table.unpack(args, 1, args.n))
