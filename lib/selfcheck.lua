-- 开机总自检：组件地址/类型、ME 网络可读、农场传感器、红石可写、作物数据
-- 返回 ok（有致命项则 false）, lines（文本行数组，用于写文件）
local component = require("component")

local selfcheck = {}
selfcheck.__index = selfcheck

local function count(t)
  local n = 0
  for _ in pairs(t or {}) do n = n + 1 end
  return n
end

function selfcheck.run(cfg, A, F)
  local ok_all = true
  local out = {}
  local function line(fmt, ...)
    local s = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    out[#out + 1] = s
    print(s)
  end
  local function ok(cond, tag, fmt, ...)
    local s = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    if cond then
      line("  [OK]   %-14s %s", tag, s)
    else
      line("  [FAIL] %-14s %s", tag, s)
      ok_all = false
    end
    return cond
  end
  local function warn(tag, fmt, ...)
    local s = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    line("  [WARN] %-14s %s", tag, s)
  end

  -- 1. 组件表
  line("==== 组件 ====")
  local map = {}
  local n = 0
  for addr, name in component.list() do
    map[addr] = name
    n = n + 1
    line("  %-24s %s", name, addr)
  end
  line("  共 %d 个", n)

  -- 2. 配置里的地址是否都在、类型对不对
  line("==== 地址 ====")
  local want = {
    { "存储网接口", cfg.ae and cfg.ae.storage, "me_interface" },
    { "种子网接口", cfg.ae and cfg.ae.seed, "me_interface" },
    { "接口终端",   cfg.ae and cfg.ae.terminal, "me_interface_terminal" },
  }
  for i, f in ipairs(cfg.farms or {}) do
    want[#want + 1] = { "农场" .. i .. " 机器", f.gt, "gt_machine" }
    want[#want + 1] = { "农场" .. i .. " 红石", f.redstone, "redstone" }
  end
  for _, w in ipairs(want) do
    local got = w[2] and map[w[2]] or nil
    ok(got == w[3], w[1], "实际=%s，期望=%s（地址 %s）",
      tostring(got), tostring(w[3]), tostring(w[2]))
  end

  -- 3. ME 网络读取
  line("==== ME 网络 ====")
  local prod = A:items_by_label("storage") or {}
  if count(prod) > 0 then
    line("  [OK]   存储网         读到 %d 种物品", count(prod))
  else
    warn("存储网", "读到 0 种物品（网络为空，或接口/适配器没接上）")
  end
  local seeds = A:seeds_by_label("seed") or {}
  if count(seeds) > 0 then
    line("  [OK]   种子网         读到 %d 种种子", count(seeds))
  else
    warn("种子网", "读到 0 种种子（种子网空，或接口/适配器没接上）")
  end
  local allSeed = A:items_by_label("seed") or {}

  -- 3.5 合成 CPU / 合成监控器（伪合成卡依赖：发配完任务即结束，所以少量 CPU 即可）
  local cpus, cerr2 = A:get_cpus()
  if #cpus > 0 then
    line("  [OK]   合成CPU         可见 %d 个（已装合成监控器）", #cpus)
  else
    warn("合成CPU", "OC 看不到任何合成 CPU：可能没装「合成监控器 Crafting Monitor」。"
      .. " 没监控器 OC 无法监控任务、getCpus() 为空。若下单卡住先查这里。")
  end

  -- 4. 农场传感器
  line("==== 农场 ====")
  for i, f in ipairs(cfg.farms or {}) do
    local info, err = F:read_sensor(f.gt)
    if info then
      ok(true, "农场" .. i, "等级=%s 容量=%s 耗水=%s/周期",
        tostring(info.level), tostring(info.capacity), tostring(info.water))
    else
      ok(false, "农场" .. i, "读不到传感器：%s", tostring(err))
    end
  end

  -- 5. 红石端口可写（全部置 0，安全，不会点动工具台）
  line("==== 红石 ====")
  for i, f in ipairs(cfg.farms or {}) do
    local rok, rerr = F:test_redstone(f.redstone)
    ok(rok, "农场" .. i, rok and "六面可写" or tostring(rerr))
  end

  -- 6. 作物：种子/垫块/样板/阈值
  line("==== 作物 ====")
  local prod_map = prod or {}
  for _, layer in ipairs(cfg.priority or {}) do
    for _, crop in ipairs(layer) do
      local th = (cfg.thresholds or {})[crop] or {}
      local ci = (cfg.crops or {})[crop] or {}
      local out = ci.out or crop
      local have = (prod_map[th.product or crop] or {}).count or 0
      local sd = (seeds or {})[crop]
      local sd_n = sd and sd.count or 0
      local sub_n = 0
      local sub_txt = "无"
      if ci.subsoil then
        local s = allSeed[ci.subsoil]
        sub_n = s and s.count or 0
        sub_txt = ci.subsoil .. "=" .. sub_n
      end
      local entry, cerr = A:find_craftable_by_label("seed", out)
      line("  [作物] %s 产物=%d 阈值=%s/%s 种子=%d 垫块=%s 苗床需=%s 下单目标=%s",
        crop, have, tostring(th.low), tostring(th.high), sd_n, sub_txt,
        tostring(ci.bed or 0), out)
      if not entry then
        warn(crop, "找不到样板：%s", tostring(cerr))
      end
      if sd_n <= 0 then
        warn(crop, "种子网里没有这个作物的种子（%s 颗）", tostring(sd_n))
      end
      if ci.subsoil and sub_n <= 0 then
        warn(crop, "垫块 %s 在种子网里没有", tostring(ci.subsoil))
      end
    end
  end

  line("")
  if ok_all then
    line("==== 自检通过 ====")
  else
    line("==== 有致命项，请先修上面标 FAIL 的行 ====")
  end
  return ok_all, out
end

return selfcheck
