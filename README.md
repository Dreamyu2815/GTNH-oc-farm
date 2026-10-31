# OC CropsNH 全自动农场（GT New Horizons 2.9.0）

用一台 OpenComputers 电脑 / 服务器，把 GTNH 的 CropsNH 工业农场做成全自动：

- 多农场并行、多作物按优先级排队，产物够了自动收进 AE
- 按等级选农场、缺口比例排序、装箱塞满、抢占高优先级作物
- 从样板自动识别作物/倍率/垫块；从种子网络自动补配置，不用手写
- F1 仪表盘（T3 屏幕）：种子/农场/告警/终端/日志一屏全看
- 热命令：阈值、优先级、红石端口、备份都能在游戏里直接改

## 快速安装

### 方式 A：网卡一键下载（推荐）

电脑里装好 **Internet Card**，进游戏后逐行执行（OpenOS 不支持 `&&`，一行一条命令）：

```
wget -f https://raw.githubusercontent.com/Dreamyu2815/GTNH-oc-farm/main/install.lua
lua install.lua
```

连不上 raw.githubusercontent.com 时换镜像（jsDelivr）：

```
wget -f https://cdn.jsdelivr.net/gh/Dreamyu2815/GTNH-oc-farm@main/install.lua
lua install.lua https://cdn.jsdelivr.net/gh/Dreamyu2815/GTNH-oc-farm@main/
```

> `wget -f` 是覆盖下载；`install.lua` 会自动建好 `/home/ocfarm` 并下载全部 21 个文件。
> 需要服务端 `OpenComputers.cfg` 里 `enableHttp=true`（单机默认就是 true）。

### 方式 B：手动复制

把本仓库的 `.lua` 文件和 `lib/` 目录复制到存档目录（最省事的做法：在这里点 **Code → Download ZIP**，解压后把整个文件夹挪进去）：

```
<saves>/<世界>/opencomputers/<电脑UUID>/home/ocfarm/
```

然后：

```
cd /home/ocfarm
lua setup.lua     -- 探测 AE 网络，生成 ae.dat（有人工确认）
lua bind.lua      -- 绑定每台农场的控制器 + 红石 I/O 口，生成 binds.dat
lua specs.lua     -- 体检：组件数/内存/磁盘够不够
lua main.lua      -- 启动；按 F1 开仪表盘
```

> 多人服务器上文件在**服务器**的世界存档里，客户端看不到，需要管理员把文件放进去。

## 环境要求

| 项目 | 要求 |
|---|---|
| OC 版本 | 1.12.64-GTNH（GTNH 2.9.0 自带） |
| 电脑 | T3 电脑（4 台农场上限），或机架里的服务器（见下表） |
| 屏幕 | T3（160×50）才有仪表盘；T1/T2 自动退化成纯终端 |
| 内存 | ≥384KB（192KB 会 OOM） |
| 硬盘 | ≥1MB（建议 2MB，含日志和自动备份） |
| 每台农场 | 1 个 gt_machine 控制器 + 1 个红石 I/O 口 + 适配器 |
| AE | 两张网：存储网（产物/垫块）+ 种子网（种子）；各贴一个 ME 接口 |

服务器档位（组件上限 = 固定 7 个 + 每台农场 2 个）：

| 平台 | 组件上限 | 理论农场数 | 实际建议 |
|---|---|---|---|
| T3 电脑 | 16 | 4 | 4 |
| T1 服务器 | 12 | 2 | 2 |
| T2 服务器 | 32 | 12 | 6～8 |
| T3/T4 服务器 | 48 | 20 | 8～10 |

## 命令速查（游戏里）

| 命令 | 作用 |
|---|---|
| `lua main.lua` | 启动（运行中按 `q q` 或按住 Ctrl+C 退出） |
| `lua specs.lua` | 配置体检：组件数/内存/磁盘/屏幕 |
| `lua setup.lua` | 探测 AE 网络并生成 `ae.dat` |
| `lua bind.lua` | 绑定农场（交互式，逐台确认） |
| `lua set.lua` | 改阈值/优先级/红石端口（`lua set.lua prio`、`side`、`2 128 512`） |
| `lua backup.lua` | 配置快照（自动留最近 10 份） |
| `lua reset.lua` | 清场（默认只预览，`yes` 才真清） |
| `lua help.lua` | 命令速查 |
| `lua discover.lua` | 把网络里的种子/样板打印出来，方便核对 |

仪表盘里（F1 打开后）也内置了终端：`help status seeds farms log N cal set prio side backup dash off clear`。

## 目录

```
main.lua config.lua setup.lua set.lua help.lua reset.lua backup.lua
discover.lua bind.lua verify.lua crops.lua crops_bed.lua specs.lua check.lua
lib/{ae,farmio,pat,selfcheck,tasks,util,ui}.lua
```

运行数据（`state.dat`、`tasks.dat`、`binds.dat`、`ae.dat`、`limits.dat`、`priority.dat`、`farms.dat`、`ui.dat`、`backups/`、`log.txt`）由程序生成，不随仓库分发。

## 常见坑

- **第一次启动没反应**：`lua main.lua` 会先自检（扫农场、读两张网），大约 10~30 秒，屏幕暂时不动是正常的。
- **苗床限制**：**农场等级由传感器容量反推**（等级 = (√容量−11)/4，如 3481 → 12 级）；**每种作物**需要的最低苗床是一个固定属性，写在 `crops_bed.lua`（全部 12 种专属作物，按中文作物名匹配），分配前会用「作物最低苗床 ≤ 农场等级」过滤。等级不够种子会卡在输入总线里、整台机器进不去。
- **仓库接口位置**：样板仓库接口要放在**种子网**里（程序按名字找，默认名字"仓库"），样板也放这个接口。
- **垫块位置**：垫块在作物下方**第二格**（y-2），不是正下方。
- **样板**：同一种作物全网只能有一份生效样板（本程序会在仓库接口和农场接口之间搬），不同作物可以并行。
- **输出总线**：单次发配物品总量别超过输出总线容量，超了会卡在"推送目标已满"（不算失败，等一会儿会自己吸完）。
- **服务器**：OC 文件存在服务器世界存档里，多人服要让管理员放文件，或给电脑装网卡用 `install.lua` 下载。
- **仪表盘只在 T3**：T1/T2 屏自动用纯终端，程序照常跑。

## 许可

随便用、随便改；出问题欢迎开 issue。
