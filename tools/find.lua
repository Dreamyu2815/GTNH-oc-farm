-- 列出所有组件地址，并逐个测试 redstone 端口能不能写（只写 0，安全，不会点动工具台）
local component = require("component")

local function line(s) print(s) end

line("==== 组件全表 ====")
local n = 0
for a, t in component.list() do
  n = n + 1
  line(string.format("%-24s %s", t, a))
end
line("共 " .. n .. " 个")
line("")

line("==== redstone 逐个试写 side0 = 0 ====")
local cnt = 0
for a, t in component.list("redstone", true) do
  if t == "redstone" then
    cnt = cnt + 1
    local ok, p = pcall(component.proxy, a)
    if ok and p then
      local ok2, e2 = pcall(function() return p.setOutput(0, 0) end)
      local ok3, e3 = pcall(component.invoke, a, "setOutput", 0, 0)
      line(string.format("%s  proxy=%s  invoke=%s  %s",
        a, tostring(ok2), tostring(ok3), tostring(ok2 and "" or e2)))
      -- 六面都试着置 0
      local bad = {}
      for s = 0, 5 do
        local o, e = pcall(function() return p.setOutput(s, 0) end)
        if not o then bad[#bad + 1] = s .. ":" .. tostring(e) end
      end
      if #bad > 0 then line("  面错误: " .. table.concat(bad, "; ")) else line("  六面均可写") end
    else
      line(a .. "  proxy 失败: " .. tostring(p))
    end
  end
end
if cnt == 0 then line("(没有 redstone 组件！)") end
line("")

line("==== 其它关键组件 ====")
for _, kind in ipairs({ "gt_machine", "me_interface", "me_interface_terminal", "tt_animationTablet" }) do
  local c = 0
  for a, t in component.list(kind, true) do
    if t == kind then
      c = c + 1
      line(string.format("%-22s %s", kind, a))
    end
  end
  if c == 0 then line(string.format("%-22s (无)", kind)) end
end
