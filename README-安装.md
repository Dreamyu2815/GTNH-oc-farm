# 工业农场自动化（OCFarm）安装说明

一套 OpenComputers 程序：接在 GTNH 的 GT 工业农场 + AE2 网络上，自动维护每台农场的
循环模式（输入 → 种植 → 输出 → 回收），按优先级/缺口自动分配作物、自动搬运样板、
多 CPU 发配，T3 屏带全屏仪表盘。

适用：**GTNH 2.9.0-RC-2**（OpenComputers 1.12.64-GTNH）。别的版本数值/名字可能不同。

---

## 一、物理搭建（抄作业最容易翻车的地方）

1. **OC 电脑**：T3 屏（160×50，仪表盘必需；T1/T2 也能跑，只是没有仪表盘）+ 键盘
   + 红石卡（连农场循环模式输入）。
2. **两张 AE 网络**：
   - **存储网**：收农场产物。放一个 ME 接口，用适配器（Adapter）贴到 OC 电脑。
   - **种子网**：放种子（ME 存储）、样板（ME 接口）、合成 CPU（至少 1 台，越多越并行）、
     每台农场的下单接口（ME 接口）、一个"仓库"样板接口。
   - 种子网上也要一个贴了适配器的 ME 接口 + 一个 ME 接口终端。
3. **每台农场**三件套：
   - GT 工业农场（多方块）的**控制器**：用适配器贴住（程序靠 gt_machine 读传感器/工作状态）；
   - **红石 I/O 口** → 连 OC 电脑的红石卡（切模式）；
   - **ME 接口**当"下单接口"→ 连农场的输入总线/输入仓；建议改名"农场1/2/3"。
   - 输入总线容量越大越好（程序会按容量塞满）。
4. **样板**：每种作物在 AE 里编码一个"伪合成"样板：种子 + 垫块 → 产物，放进仓库接口。
   **同一作物全网只放一份样板**（程序自己会搬来搬去）。
5. 产物放存储网；种子+垫块放种子网。

---

## 二、安装

1. 在 GitHub 页面点 **Code → Download ZIP**，解压到存档目录：
   `.minecraft/saves/<存档>/opencomputers/<电脑UUID>/home/ocfarm`
   （解压后 `home/ocfarm/main.lua` 存在即正确）
2. 游戏里进 OC 终端：
   ```
   cd /home/ocfarm
   lua setup.lua      # 扫描网络接口 → 按提示确认 存储网/种子网/终端 → 写 ae.dat
   lua bind.lua       # 首次安装：绑定每台农场（GT 控制器 / 红石 / 下单接口）
   lua main.lua       # 启动
   ```
   **bind.lua 绑红石端口有两种方式，任选：**
   - ① 按提示**拆装**：把该农场的红石 I/O 口拆下来再装回去，程序检测到插拔就算绑定；
   - ② 按 **m** 列出当前所有红石端口，直接输编号选（推荐，最稳）。
   每台农场还会单独确认红石端口朝向（0=下 1=上 2=北 3=南 4=西 5=东）。
3. 启动后按 **F1** 打开仪表盘（再按一次关闭，开关状态记忆在 `ui.dat`）。
   **第一次启动会先自检（扫农场、读两张网，大约 10~30 秒），屏幕暂时不动是正常的。**
4. 加新作物：AE 里写好样板放进仓库、种子/垫块放进种子网；重启 main 或等自动配置。

---

## 三、日常操作

| 想做的事 | 命令 |
|---|---|
| 改产物阈值（低/高） | `lua set.lua`（编号操作）或 F1 仪表盘终端 `set 1 low 128` |
| 改优先级 | `lua set.lua prio` 或 F1 终端 `prio` |
| 改红石端口面 | `lua set.lua side 2 4` 或 F1 终端 `side` |
| 备份 / 回滚 | `lua backup.lua` / `lua backup.lua restore <名字> yes` |
| 清场重来 | `lua reset.lua`（只预览）→ `lua reset.lua yes` |
| 看全部命令 | `lua help.lua` 或 F1 终端 `help` |

---

## 四、常见坑

- **种子卡在输入总线**：农场苗床等级不够（crops_bed.lua 里有每种作物的最低苗床）。
  换/升苗床，或 `lua set.lua bed <编号> <等级>`。
- **AE 报 no link**：不是真失败（任务没挂链接的占位），程序会靠"农场开没开工"继续判断。
- **"推送目标已满"**：输入总线短暂停全是正常的，等它吸完。
- **拆装方块 = 新 UUID**：拆过接口/控制器后重跑 `lua setup.lua`（网络）或 `lua bind.lua`（农场）。
- **q q 退不出**：按 Ctrl+C 安全退出；程序在长计算里可能几秒没响应，正常。
- **仪表盘打不开**：屏幕分辨率 < 160×50（T1/T2）没有仪表盘，纯终端照常用。

---

## 五、文件说明

- **运行必需**：main.lua、config.lua、set.lua、help.lua、backup.lua、reset.lua、
  discover.lua、bind.lua、verify.lua、check.lua、setup.lua、crops.lua、crops_bed.lua、
  lib/（ae、pat、farmio、tasks、util、selfcheck、ui）.lua
- **工具（可选）**：`tools/` 目录，按需拷到 `home/ocfarm` 使用
- **运行时数据（自动生成，别拷贝）**：ae.dat、binds.dat、state.dat、tasks.dat、
  limits.dat、priority.dat、farms.dat、log.txt、check.txt、ui.dat

---

## 六、来源

- 苗床/作物数据：CropsNH 源码 + GTNH 中文维基「工业农场」
- AE 矿词过滤正则：`ore_filter_regex.txt`（贴进 AE 的矿词过滤卡，种子/垫块/产物三分类）
