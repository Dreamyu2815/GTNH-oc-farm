-- ============================================================
--  绑定后自检：对每台已绑定农场"发一批种子 → 脉冲 → 看 hasWork"
--  这是判断"红石端口 ↔ 活化工具台 ↔ 这台农场"是否连对的最终手段。
--
--  用法：
--    lua verify.lua             全部测一遍（自动挑一个「有种子且有仓库样板」的作物）
--    lua verify.lua <作物名>    只测指定作物（例：lua verify.lua 空间之花）
--    lua verify.lua <id>        只测第 <id> 台（id 与 bind.lua 的编号一致）
--    lua verify.lua <id> <作物  两台一起（顺序无所谓）
--
--  注意：verify 不依赖优先级——它只关心「种子网里有种子 + 仓库里有样板」，
--        因为自检要验证的是发配链路本身，跟你怎么排优先级无关。
--
--  每台流程：
--    读传感器(等级/容量) → 测红石可写 → 搬样板(仓库→本农场下单接口)
--    → 下单 1 批(mult 颗) → 等吸种 → 脉冲切 Farm → 25 秒内看 hasWork
--    → OK/FAIL → 恢复(切 Output 退回种子 → 切回 Input) → 样板搬回仓库
-- ============================================================
local ROOT = "/home/ocfarm"
local BINDS = ROOT .. "/binds.dat"

local function loadmod(name)
  local path = ROOT .. "/lib/" .. name .. ".lua"
  local f = io.open(path, "r")
  if not f then error("缺少模块: " .. path) end
  f:close()
  return dofile(path)
end

local component = require("component")
local computer = require("computer")

local cfg = dofile(ROOT .. "/config.lua")
local util = loadmod("util")
util.merge_ae(cfg, ROOT)   -- 网络地址以 ae.dat 为准
local farmio = loadmod("farmio")
local aemod = loadmod("ae")
local patmod = loadmod("pat")

local F = farmio.new({})
local A = aemod.new(cfg.ae)
local PAT = patmod.new(cfg)

-- 取命令行参数（OpenOS 放在 chunk varargs 里，全局 arg 可能为 nil），按数字扫描
local ARGS = {}
do
  local n = select("#", ...)
  for i = 1, n do ARGS[#ARGS + 1] = select(i, ...) end
  if #ARGS == 0 and type(arg) == "table" then
    for _, v in pairs(arg) do
      if type(v) == "string" then ARGS[#ARGS + 1] = v end
    end
  end
end
local ONLY = nil
local CROP_ARG = nil
for _, a in ipairs(ARGS) do
  local n = tonumber(a)
  if n then
    ONLY = n
  elseif type(a) == "string" and a:gsub("%s", "") ~= "" then
    CROP_ARG = a:gsub("种子$", "")   -- 允许 `空间之花种子` 也认
  end
end

local function say(fmt, ...)
  local args = table.pack(...)
  for i = 1, args.n do
    local v = args[i]
    if type(v) == "number" and math.type(v) == "float" and v == math.floor(v) then
      args[i] = math.floor(v)
    end
  end
  local ok, s = pcall(string.format, fmt, table.unpack(args, 1, args.n))
  if not ok then
    local parts = {}
    for i = 1, args.n do parts[#parts + 1] = tostring(args[i]) end
    s = fmt .. "  <" .. table.concat(parts, ", ") .. ">"
  end
  print(s)
end

local function key_char(a, b, c)
  local ch = b
  if ch == nil then ch = a end
  if type(ch) == "number" and ch >= 32 and ch <= 126 then return string.char(ch):lower() end
  if type(ch) == "string" then return ch:sub(1, 1):lower() end
  return nil
end

local q_at = 0
local function check_q()
  local sig = table.pack(computer.pullSignal(0))
  if sig[1] == "key_down" then
    local ch = key_char(sig[2], sig[3], sig[4])
    if ch == "q" then
      if computer.uptime() - q_at < 1.0 then return true end
      q_at = computer.uptime()
    end
  end
  return false
end

-- 等农场开始运行，最多 timeout 秒；期间响应 q 退出
local function wait_work(gt, timeout)
  local t0 = computer.uptime()
  local why = "无"
  while computer.uptime() - t0 < timeout do
    if check_q() then return nil, "用户按 q 退出" end
    local w, w2 = F:is_working(gt)
    if w then return true, w2 end
    why = tostring(w2)
    os.sleep(1)
  end
  return false, why
end

-- 等"发配"真正完成：AE 每 5 tick 推一份，不能拿固定秒数猜。
-- 优先 job 状态（伪合成卡下原料发完即 isDone），兜底看种子数真的少了 n 颗。
local function wait_dispatched(job, crop, before, n, limit)
  local label = tostring(crop) .. "种子"
  local t0 = computer.uptime()
  local last_read, last_report, sent = 0, 0, 0
  while true do
    local el = computer.uptime() - t0
    if el >= (limit or 300) then return false, "超时", el end
    if check_q() then return false, "用户退出", el end
    local okh, hasf, whyf = pcall(function() local a, b = job:hasFailed() return a, b end)
    if okh and hasf == true then
      -- AE 集成里 hasFailed 常带默认占位 reason「no link」，那种不是真失败（真失败是
      -- request failed (...)）。和 main.lua 同一判据：只有 request failed 才算失败。
      local realfail = tostring(whyf or ""):find("request failed", 1, true) ~= nil
      if realfail then return false, "任务失败（" .. tostring(whyf) .. "）", el end
    end
    local okd, done = pcall(function() return job:isDone() end)
    if okd and done == true then return true, "job 已发配完成", el end
    if el - last_read >= 2 then
      last_read = el
      local now
      local q = A:query("seed", { label = label })
      if q and #q > 0 then
        now = 0
        for _, s in ipairs(q) do
          if s.name == "cropsnh:genericSeed" then now = now + (s.size or 0) end
        end
      else
        local sd = A:seeds_by_label("seed")[crop]
        now = sd and sd.count or 0
      end
      sent = before - now
      if sent >= n then return true, string.format("种子已发出 %d 颗", sent), el end
    end
    if el - last_report >= 10 then
      last_report = el
      local okc, comp = pcall(function() return job:isComputing() end)
      if okc and comp == false then
        say("[发配] 在排队等合成 CPU（已等 %.0f 秒），CPU 空出来就会开始发", el)
      else
        say("[发配] 已发出约 %d/%d 颗，等 %.0f 秒（合成 CPU 占用中，属正常）", math.max(sent, 0), n, el)
      end
    end
    os.sleep(0.5)
  end
end

-- 检测失败时把原始信号摊开，方便一次定位（只读，不碰机器）
local function dump_state(tag, gt)
  local function one(m)
    local ok, v = pcall(component.invoke, gt, m)
    if not ok then return m .. "=ERR" end
    return string.format("%s=%s", m, tostring(v))
  end
  say("[诊断] %s %s %s %s %s %s", tag, one("hasWork"), one("getWorkMaxProgress"), one("getWorkProgress"), one("isMachineActive"), one("getEUInputAverage"))
  local ok, info = pcall(component.invoke, gt, "getSensorInformation")
  if ok then
    if type(info) == "string" then info = { info } end
    for _, line in ipairs(info or {}) do
      local s = tostring(line):gsub("\194\167.", "")
      if s:find("进度") or s:find("问题") or s:find("耗水") or s:find("营养")
        or s:find("rogress") or s:find("roblem") or s:find("ater") or s:find("utrition") then
        say("[诊断]   | %s", s)
      end
    end
  end
end

-- 找绑定里某台农场的下单接口条目（按坐标）
local function farm_iface_entry(bind)
  if not bind.iface then return nil end
  return PAT:entry_by_loc({ location = {
    x = bind.iface.x, y = bind.iface.y, z = bind.iface.z, dimension = bind.iface.dimension,
  } })
end

-- 从仓库样板里反查某作物的产物名和倍增数（新增作物不在 config.crops 里，也要能测）
-- 名字对不上（种子网里是中文、样板里是英文，或反过来）时，再按物品身份 name+damage 兜底匹配
local function product_for(crop, seedstack)
  local wh = PAT:warehouse()
  if not wh then return nil, nil end
  for _, slot in ipairs(PAT:slots(wh)) do
    local st = wh.patterns and wh.patterns[slot]
    local hit = type(st) == "table" and PAT:pattern_matches(st, crop)
    if not hit and type(seedstack) == "table" then
      hit = PAT:pattern_has_item(st, seedstack.name, seedstack.damage)
    end
    if hit then
      if type(st.outputs) == "table" then
        for _, v in pairs(st.outputs) do
          local l = v and (v.label or v.name)
          if l then return tostring(l), (tonumber(v.size) or 0) end
        end
      end
    end
  end
  return nil, nil
end

-- 选测试作物：不依赖优先级。
--   指定了作物 -> 用它（前提是有种子 + 仓库有样板）
--   没指定     -> 从种子网里挑第一个「有种子且有仓库样板」的作物（按名字排序，结果稳定）
local function testable(crop, seeds)
  local e = seeds[crop]
  if not e or (e.count or 0) < 1 then return nil end
  local ci = cfg.crops and cfg.crops[crop]
  local out = ci and ci.out
  local mult = ci and ci.mult
  if not out then out, mult = product_for(crop, e and e.stack) end
  if not out then return nil end
  return out, (mult or 0) > 0 and mult or 1, e.stack
end

local function pick_crop()
  local seeds = A:seeds_by_label("seed")
  if CROP_ARG then
    local out, m, stk = testable(CROP_ARG, seeds)
    if out then return CROP_ARG, out, m, stk end
    return nil, nil, nil, nil, CROP_ARG
  end
  local names = {}
  for name, e in pairs(seeds) do
    if (e.count or 0) > 0 then names[#names + 1] = name end
  end
  table.sort(names)
  for _, name in ipairs(names) do
    local out, m, stk = testable(name, seeds)
    if out then return name, out, m, stk end
  end
  return nil, nil, nil, nil, nil
end

local binds = util.load(BINDS, { seq = 0, farms = {} })
if type(binds.farms) ~= "table" or #binds.farms == 0 then
  say("[错误] 还没有绑定记录（binds.dat 为空）。先跑 lua bind.lua。")
  return
end

local crop, out, mult, seedstack, want = pick_crop()
if not crop then
  local seeds = A:seeds_by_label("seed")
  local avail = {}
  for name, e in pairs(seeds) do
    if (e.count or 0) > 0 then avail[#avail + 1] = string.format("%s×%d", name, e.count) end
  end
  if want then
    say("[错误] 指定的作物 %s 测不了：种子网里没有它的种子，或仓库里没有它的样板。", want)
  elseif #avail > 0 then
    say("[错误] 种子网里这些作物都有种子，但仓库里都没有对应样板：")
  else
    say("[错误] 种子网络里没有任何种子。先放一批种子进种子网络。")
  end
  if #avail > 0 then
    for _, s in ipairs(avail) do say("        - %s", s) end
    say("        往仓库接口放对应样板后重试；也可以 lua verify.lua <作物> 指定要测的作物。")
  end
  return
end

mult = mult or A:craftable_mult("seed", out) or 1
local wh = PAT:warehouse()
if not wh then
  say("[错误] 找不到仓库接口（config.ae.warehouse_name 或空名字接口）。")
  return
end
local src_slot = PAT:slot_for(crop, seedstack)
if not src_slot then
  say("[错误] 仓库样板槽找不到：%s", tostring(crop))
  return
end

say("========== 绑定自检（verify） ==========")
say("测试作物：%s（下单目标 %s，1 批 %d 颗）", crop, tostring(out), mult)
say("仓库接口：%s（槽 %d）", PAT:name_of(wh), src_slot)
say("==========================================")

local results = {}
for idx, bind in ipairs(binds.farms) do
  if not ONLY or bind.id == ONLY then
    local label = string.format("#%d gt=%s", bind.id or idx, tostring(bind.gt))
    local ok = true

    -- 1) 传感器
    local info, serr = F:read_sensor(bind.gt)
    if not info then
      say("[FAIL] %s 读不到传感器：%s", label, tostring(serr))
      results[idx] = "FAIL"
      goto continue
    end
    say("[OK] %s 等级=%s 容量=%s", label, tostring(info.level), tostring(info.capacity))
    if info.level == nil then
      say("[提示] %s 传感器文本里没识别到容量（中文「容量」/English「capacity」都试过了），原文前几行：", label)
      for i = 1, math.min(#(info.lines or {}), 4) do
        say("[提示]    | %s", tostring(info.lines[i]))
      end
    end

    -- 2) 红石可写
    local rok, rerr = F:test_redstone(bind.redstone)
    if not rok then
      say("[FAIL] %s 红石端口写不进：%s", label, tostring(rerr))
      results[idx] = "FAIL"
      goto continue
    end
    say("[OK] %s 红石六面可写", label)

    -- 3) 下单接口
    local fe = farm_iface_entry(bind)
    if not fe then
      say("[FAIL] %s 下单接口没找到（binds.iface 坐标对不上接口终端列表）", label)
      results[idx] = "FAIL"
      goto continue
    end
    say("[OK] %s 下单接口 %s", label, PAT:name_of(fe))

    -- 4) 搬样板：仓库 -> 本农场下单接口
    local mok, mmsg = PAT:move(wh, src_slot, fe)
    if not mok then
      say("[FAIL] %s 样板搬不进下单接口：%s", label, tostring(mmsg))
      results[idx] = "FAIL"
      goto continue
    end
    say("[搬样] %s 仓库槽 %d -> %s", label, src_slot, PAT:name_of(fe))

    -- 下面这段整体包进 do...end：这样 goto move_back 是"跳出本块"，
    -- 不会跳进 job/dw/side 等局部变量的作用域（Lua 5.3 的硬规则）
    do

    -- 5) 下单 1 批（先等合成 CPU 空出来，别的农场正在发配时排队，不硬挤）
    local okc, cw = A:wait_free_cpu(300, function(total, el)
      say("[等待] %s 合成 CPU 全被占用（%d 个，已等 %.0f 秒），空出来就下单", label, total, el)
    end)
    if not okc then
      say("[FAIL] %s 拿不到合成 CPU：%s", label, tostring(cw))
      goto move_back
    end
    if tonumber(cw) and tonumber(cw) >= 1 then
      say("[发配] %s 合成 CPU 空出来了（等了 %.0f 秒）", label, tonumber(cw))
    end
    local before = 0
    local sdb = A:seeds_by_label("seed")[crop]
    if sdb then before = sdb.count or 0 end
    local job, jerr = A:request("seed", out, mult)
    if not job then
      say("[FAIL] %s 下单失败：%s", label, tostring(jerr))
      goto move_back
    end
    say("[下单] %s %s ×%d", label, tostring(out), mult)

    -- 6) 等 CPU 任务发配完成 + 1 秒（和 main.lua 同步：不再猜 4.25 秒）
    local ddone, dmsg, del = wait_dispatched(job, crop, before, mult, 300)
    if not ddone then
      say("[FAIL] %s 发配没完成：%s（已等 %.0f 秒）", label, tostring(dmsg), del or 0)
      goto move_back
    end
    say("[发配] %s CPU 任务完成（%.0f 秒），再等 1 秒让输入总线吸完", label, del)
    os.sleep(1)

    -- 7) 脉冲切 Farm
    local side = nil
    for _, f in ipairs(cfg.farms or {}) do
      if f.gt == bind.gt or f.id == bind.id then side = f.redstone_side end
    end
    local pok, perr = F:pulse(bind.redstone, cfg.timing.pulse_width, side)
    if not pok then
      say("[FAIL] %s 脉冲失败：%s", label, tostring(perr))
      goto move_back
    end
    say("[脉冲] %s 切 Farm（面 %s）", label, tostring(side))

    -- 刷新工作开关（关→开），和 main.lua 一致：防"切 Farm 后机器不开工"卡生长
    os.sleep(0.3)
    local rk, rr = F:set_work_allowed(bind.gt, false)
    if rk then
      os.sleep(0.5)
      F:set_work_allowed(bind.gt, true)
      os.sleep(0.3)
      say("[刷新] %s 已自动关→开工作开关", label)
    else
      say("[警告] %s 切工作开关失败（%s），跳过刷新", label, tostring(rr))
    end

    -- 8) 等农场开工（从输入切到 Farm 后有时要 5 秒以上才真正开始跑，给足 60 秒）
    local worked, wmsg = wait_work(bind.gt, 60)
    if worked == nil then
      say("[退出] %s 用户按 q 退出", label)
      return
    elseif worked then
      say("[PASS] %s 红石链路正确：农场已开工（%s）", label, tostring(wmsg))
      results[idx] = "PASS"
    else
      say("[FAIL] %s 60 秒内农场没开工：%s", label, tostring(wmsg))
      dump_state(label, bind.gt)
      results[idx] = "FAIL"
    end

    -- 9) 恢复：切 Output 退回种子 → 切 Input（10 秒足够把种子+垫块成对吐回输出总线）
    say("[恢复] %s 切 Output 退回种子", label)
    F:pulse(bind.redstone, cfg.timing.pulse_width, side)
    local r0 = computer.uptime()
    while computer.uptime() - r0 < 10 do
      if check_q() then say("[退出]"); return end
      os.sleep(0.5)
    end
    say("[恢复] %s 切回 Input", label)
    F:pulse(bind.redstone, cfg.timing.pulse_width, side)

    end -- do

    ::move_back::
    -- 10) 样板搬回仓库：优先放回原槽（其它槽可能已占），失败再放第一个空槽。
    --     之前固定放 0 号槽：仓库多样板时 0 号已占 → 搬回失败 → 样板卡在农场，
    --     下一台再从原槽搬就是空的（这就是 #2~#6「返回 false」的来源）。
    local cur = PAT:entry_by_loc({ location = { x = bind.iface.x, y = bind.iface.y, z = bind.iface.z, dimension = bind.iface.dimension } })
    if cur and PAT:count(cur) > 0 then
      for _, sl in ipairs(PAT:slots(cur)) do
        local bok = PAT:move(cur, sl, wh, src_slot)
        if not bok then
          local free = PAT:free_slot(wh)
          if free ~= nil then bok = PAT:move(cur, sl, wh, free) end
        end
        if bok then say("[搬样] %s 样板已搬回仓库（槽 %d）", label, src_slot) end
      end
    end

    ::continue::
  end
end

say("")
say("========== 自检结果 ==========")
for idx, bind in ipairs(binds.farms) do
  if not ONLY or bind.id == ONLY then
    say("  #%d (%s) -> %s", bind.id or idx, tostring(bind.gt), tostring(results[idx] or "未测"))
  end
end
say("================================")
