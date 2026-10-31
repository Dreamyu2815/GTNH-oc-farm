-- install.lua —— 从 GitHub 一键装好整套 OC 农场脚本
-- 用法（在 OC 电脑里，需要 Internet Card）：
--   lua install.lua
--   lua install.lua https://raw.githubusercontent.com/Dreamyu2815/GTNH-oc-farm/main/
--   国内连不上 raw.githubusercontent.com 时用镜像：
--   lua install.lua https://cdn.jsdelivr.net/gh/Dreamyu2815/GTNH-oc-farm@main/
-- 说明：
--   * 会下载到 /home/ocfarm/，覆盖同名文件
--   * 下载完提示你跑 lua setup.lua（配置 AE 地址）和 lua bind.lua（绑定农场）
--   * 如果一直卡住：检查是否装了网卡、服务端 config 里 enableHttp 是否为 true

local component = require("component")
local internet = require("internet")
local filesystem = require("filesystem")

local DEFAULT_BASE = "https://raw.githubusercontent.com/Dreamyu2815/GTNH-oc-farm/main/"
local DEST = "/home/ocfarm"

local FILES = {
  "main.lua", "config.lua", "setup.lua", "set.lua", "help.lua",
  "reset.lua", "backup.lua", "discover.lua", "bind.lua", "verify.lua",
  "crops.lua", "crops_bed.lua", "specs.lua", "check.lua",
  "lib/ae.lua", "lib/farmio.lua", "lib/pat.lua", "lib/selfcheck.lua",
  "lib/tasks.lua", "lib/util.lua", "lib/ui.lua",
}

local function mkdir(path)
  if filesystem.exists(path) then return true end
  local ok, err = filesystem.makeDirectory(path)
  if not ok and not filesystem.exists(path) then
    return false, err or "无法创建目录"
  end
  return true
end

local function fetch(url, path)
  local ok, response = pcall(internet.request, url, nil, { ["user-agent"] = "ocfarm-install" })
  if not ok then return nil, tostring(response) end
  local f, werr = io.open(path, "wb")
  if not f then return nil, "写文件失败: " .. tostring(werr) end
  local ok2, n = pcall(function()
    local total = 0
    for chunk in response do
      total = total + #chunk
      f:write(chunk)
    end
    return total
  end)
  f:close()
  if not ok2 then return nil, "下载失败: " .. tostring(n) end
  return n
end

local function main(args)
  if not component.isAvailable("internet") then
    print("这台电脑没有网卡（Internet Card），无法联网下载。")
    print("请先装网卡，或改用 zip 手动复制文件的方式安装。")
    return
  end

  local base = args and args[1] or DEFAULT_BASE
  if base:sub(-1) ~= "/" then base = base .. "/" end

  print("==== 从 " .. base .. " 安装到 " .. DEST .. " ====")
  local okd, derr = mkdir(DEST)
  if not okd then print("创建目录失败: " .. tostring(derr)); return end
  mkdir(DEST .. "/lib")

  local okn, bad = 0, {}
  for i = 1, #FILES do
    local rel = FILES[i]
    local url = base .. rel
    local target = DEST .. "/" .. rel
    io.write(string.format("[%2d/%2d] %-20s ", i, #FILES, rel))
    local n, err = fetch(url, target)
    if n then
      io.write(string.format("ok  %.1fKB\n", n / 1024))
      okn = okn + 1
    else
      io.write("失败\n")
      bad[#bad + 1] = rel .. " -> " .. tostring(err)
    end
  end

  print("")
  print(string.format("完成：%d/%d 个文件。", okn, #FILES))
  if #bad > 0 then
    print("以下文件没下载成功：")
    for _, b in ipairs(bad) do print("  " .. b) end
    print("可以重跑 lua install.lua 重试（只会覆盖）。")
    return
  end
  print("")
  print("下一步：")
  print("  1) lua setup.lua    —— 探测并确认 AE 网络地址（生成 ae.dat）")
  print("  2) lua bind.lua     —— 绑定每台农场的控制器和红石口（生成 binds.dat）")
  print("  3) lua specs.lua    —— 看看这台电脑配置够不够")
  print("  4) lua main.lua     —— 启动；F1 打开仪表盘")
end

main({ ... })
