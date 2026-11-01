-- 农场 IO：读 gt_machine 传感器 + 红石脉冲点工具台
-- 注意：活化工具台虽然出现在组件表里，但在这套整合包中调用任何方法都会抛
-- dan200/.../LuaException（缺 CC 类），所以只能走红石脉冲。
local component = require("component")
local computer = require("computer")

-- 真实秒（与 main 的 upsec 同口径）：realTime 优先，退回 os.time()
local function realsec()
  local ok, v = pcall(computer.realTime)
  if ok and type(v) == "number" then return v end
  return os.time()
end

local farmio = {}
farmio.__index = farmio

local function invoke(addr, method, ...)
  if not addr then return false, "no address" end
  -- 先走 component.invoke：gt_machine 这个类型名有 4 个 Computronics 驱动共用，
  -- proxy 表上拿到的不一定是我们要的那个驱动，实测 proxy 路径会"静默返回 nil"，
  -- 而 component.invoke 走的是 OC 真实的回调分发，结果可靠。
  local ok, res = pcall(component.invoke, addr, method, ...)
  if ok then return true, res end
  local okp, proxy = pcall(component.proxy, addr)
  if okp and proxy then
    local f = proxy[method]
    if f ~= nil then
      local ok2, res2 = pcall(f, ...)
      if ok2 then return true, res2 end
      return false, tostring(res2)
    end
  end
  return false, tostring(res)
end

-- 暴露出去，方便调试脚本直接 F.invoke(地址, 方法, ...)
farmio.invoke_raw = invoke

-- 去掉颜色控制符：UTF-8 的 § 是 C2 A7，后面跟一个样式字符
local function strip(text)
  local s = tostring(text)
  s = s:gsub("\194\167.", "")
  return s
end

local function first_number(text)
  local s = strip(text):gsub(",", "")
  local m = s:match("(%-?%d+%.?%d*)")
  if not m then return nil end
  return tonumber(m)
end

function farmio.new(opts)
  return setmetatable({ opts = opts or {} }, farmio)
end

-- 容量 -> 苗床等级：capacity = (4L+11)^2
function farmio.level_from_capacity(cap)
  if not cap then return nil end
  local root = math.floor(math.sqrt(cap) + 0.5)
  if (root - 11) % 4 ~= 0 then return nil end
  local lv = (root - 11) / 4
  if lv < 1 or lv > 12 then return nil end
  return lv
end

-- 读传感器，返回 { level=, capacity=, water=, lines= }
function farmio:read_sensor(gt_addr)
  local ok, res = invoke(gt_addr, "getSensorInformation")
  if not ok then return nil, tostring(res) end
  if type(res) == "string" then res = { res } end
  if type(res) ~= "table" then return nil, "sensor 返回类型错误: " .. type(res) end

  local info = { lines = res }
  for _, line in ipairs(res) do
    local plain = strip(line)
    local low = plain:lower()
    -- 中英文都要认：单人档是中文，多人服（服务端 language=en_US）发来的物品/提示是英文。
    if not info.capacity and (plain:find("容量", 1, true) or low:find("capacity", 1, true)) then
      info.capacity = first_number(plain:match("容量(.*)$") or plain:match("[Cc]apacity(.*)$") or "")
    end
    if not info.water and (plain:find("耗水", 1, true) or low:find("water", 1, true)) then
      info.water = first_number(plain:match("耗水(.*)$") or plain:match("[Ww]ater(.*)$") or "")
    end
  end
  info.level = farmio.level_from_capacity(info.capacity)
  return info
end

-- 机器是否在干活（GT 的 hasWork）：true/false/nil(读不到)
function farmio:has_work(gt_addr)
  local ok, res = invoke(gt_addr, "hasWork")
  if not ok then return nil, tostring(res) end
  return res and true or false
end

-- 机器当前的输入功率（EU/t）。没活干的机器基本是 0，靠它判"在不在跑"最准。
-- 依次试 getEUInputAverage（平均输入）、getAverageElectricInput。
function farmio:eu_input(gt_addr)
  local ok, v = invoke(gt_addr, "getEUInputAverage")
  if ok and tonumber(v) then return tonumber(v), "getEUInputAverage" end
  local ok2, v2 = invoke(gt_addr, "getAverageElectricInput")
  if ok2 and tonumber(v2) then return tonumber(v2), "getAverageElectricInput" end
  return nil, "读不到输入功率"
end

function farmio:eu_output(gt_addr)
  local ok, v = invoke(gt_addr, "getEUOutputAverage")
  if ok and tonumber(v) then return tonumber(v) end
  return nil
end

-- 综合判断"农场正在运行"，返回 ok, 依据
-- 判据优先级：
--   ① 输入功率 > 0 —— 最准，机器没在长就是 0（用户提的判据）
--   ② 进度条在动 —— 隔 1.5 秒采两次 getWorkProgress，值变了就是在跑。
--      双采样要睡 1.5 秒，主循环 1 秒一轮会全卡在这：每台机器最多 5 秒采样一次，
--      窗口内的"在走"结果缓存复用；没在走就落到 ③。
--   ③ hasWork / getWorkMaxProgress / getWorkProgress / isMachineActive 任一为真
local work_cache = {}   -- [addr] = { t=上次双采样时间, moving=当时进度是否在走 }

function farmio:is_working(gt_addr)
  if not gt_addr then return false, "没配置机器地址" end

  local eu = self:eu_input(gt_addr)
  if eu and eu > 1 then
    return true, string.format("耗电 %.0f EU/t", eu)
  end

  local c = work_cache[gt_addr]
  if not c then c = { t = -1e9 }; work_cache[gt_addr] = c end
  if realsec() - c.t >= 5 then
    local ok1, p1 = invoke(gt_addr, "getWorkProgress")
    if ok1 and tonumber(p1) then
      os.sleep(1.5)
      local ok2, p2 = invoke(gt_addr, "getWorkProgress")
      c.moving = ok2 and tonumber(p2) and tonumber(p2) ~= tonumber(p1) and true or false
    else
      c.moving = false
    end
    c.t = realsec()
    if c.moving then
      return true, "进度在走（最近一次双采样）"
    end
  elseif c.moving then
    return true, "进度在走（缓存，最近 5 秒内采过）"
  end

  local hw, err = self:has_work(gt_addr)
  if hw == true then return true, "hasWork=true" end
  local okm, mp = invoke(gt_addr, "getWorkMaxProgress")
  if okm and tonumber(mp) and tonumber(mp) > 0 then return true, "getWorkMaxProgress>0" end
  local okw, wp = invoke(gt_addr, "getWorkProgress")
  if okw and tonumber(wp) and tonumber(wp) > 0 then return true, "getWorkProgress>0" end
  local oka, act = invoke(gt_addr, "isMachineActive")
  if oka and act then return true, "isMachineActive=true" end

  if hw == nil then return false, tostring(err) end
  return false, "四个信号全假且没耗电"
end

-- ===== 机器"是否允许工作"（GUI 里那个软锤开关） =====
-- 工业农场偶尔会出现"有种子、模式也对，但就是不开工"，玩家开关一次 GUI 才恢复；
-- 这类机器属于内部状态没刷新。用 setWorkAllowed 关→开 一次，等于按一下软锤，
-- 能强制机器重新评估结构/配方，比来回切模式安全（不会搅乱已吸进去的种子）。
function farmio:is_allowed(gt_addr)
  if not gt_addr then return nil, "没配置机器地址" end
  local ok, v = invoke(gt_addr, "isWorkAllowed")
  if ok and type(v) == "boolean" then return v end
  return nil, "读不到 isWorkAllowed"
end

function farmio:set_work_allowed(gt_addr, on)
  if not gt_addr then return false, "没配置机器地址" end
  local ok, err = invoke(gt_addr, "setWorkAllowed", on and true or false)
  if ok then return true end
  return false, tostring(err)
end

-- 红石端口：写死「只向上发信号（side=1）」。用户实测（2026-11-01）：红石 I/O 摆在
-- 活化工具台正下方、只朝上发，触发最稳；六面全写/朝向选择都不稳定，已回退。
-- 注意：这版 redstone 的 setOutput 必须带 side。
local RS_UP = 1

-- 开跑前的自检：能不能写红石（向上那面置 0，安全）
function farmio:test_redstone(addr)
  if not addr then return false, "没配置红石端口" end
  local ok, err = invoke(addr, "setOutput", RS_UP, 0)
  if not ok then return false, "红石端口写不进去（向上那面）：" .. tostring(err) end
  return true
end

-- 一次脉冲 = 工具台挥一下
-- 两个坑：
-- ① 脉冲宽度要短（>0.2 秒工具台会连挥好几次，Input 直接跳到 Output）；
-- ② 两次短间隔的红石脉冲会把活化工具台重置（用户实测）→ 下面按红石端口做 ≥1 秒间隔保护。
local last_pulse = {}   -- [addr] = 上次脉冲结束的时刻（realsec）

function farmio:pulse(addr, width, side)
  if not addr then return false, "没配置红石端口" end
  local w = tonumber(width) or 0.05
  if w < 0.05 then w = 0.05 end
  if w > 0.2 then w = 0.2 end

  -- 间隔保护：距离这个端口上一次脉冲不足 1 秒，先睡满，避免把工具台重置
  local gap = realsec() - (last_pulse[addr] or 0)
  if gap < 1 then
    os.sleep(1 - gap)
  end

  -- 写死只写向上那一面（红石端口摆在活化工具台正下方）
  local ok0, e0 = invoke(addr, "setOutput", RS_UP, 0)
  if not ok0 then return false, "红石端口写不进去（向上那面）：" .. tostring(e0) end
  invoke(addr, "setOutput", RS_UP, 15)
  os.sleep(w)
  invoke(addr, "setOutput", RS_UP, 0)
  last_pulse[addr] = realsec()
  return true
end

return farmio
