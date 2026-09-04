# 防休眠 Keep-Awake

让 Windows 在 AI 编程（vibe coding）、长任务、远程无人值守时**不休眠、不熄屏、不锁屏**。

- **零依赖**：只需要 Windows 自带的 PowerShell 5.1，没有安装步骤、没有运行库。普通账户即可运行（唯一例外是可选的改合盖动作，那需要管理员）。
- **免登录**：clone/复制即用，双击 `.bat` 就跑，不联网、不注册、不上传任何数据。
- **本地面板**：浏览器打开 `http://127.0.0.1:8791/`，只监听回环地址。
- **说真话**：面板上"有没有效"不是猜的，是读内核电源日志数出来的（见下文《有效性是实测的》）。
- **数据和边界摊开写**：磁盘上每一个文件、每一个字段见 [PRIVACY.md](PRIVACY.md)；面板端口、提权、合成输入、没有代码签名这四件事的威胁模型见 [SECURITY.md](SECURITY.md)；每个版本改了什么见 [CHANGELOG.md](CHANGELOG.md)。
- **许可**：Apache-2.0。可商用、可修改、可闭源集成，自带专利授权；不授予任何商标或本项目名称的使用权（见下文《许可》）。

版本号只有一个真源：`ka-core.ps1` 里的 `$script:KaVersion`（面板页脚、托盘提示、`/api/state` 读的都是它）。本文标题**不带**版本号，因为两份版本号写在一起迟早会互相打脸。

## 30 秒上手

| 双击这个 | 作用 |
| --- | --- |
| **`on.bat`** | 立刻开始保护（不休眠 + 屏幕常亮 + 防锁屏），直到你停止它 |
| `on.bat 120` | 保护 120 分钟，到点自动释放（关掉这个窗口也不影响，计时在 worker 里） |
| **`panel.bat`** | 打开本地控制台，鼠标点着控制 |
| `tray.bat` | 系统托盘图标，不想要浏览器时用右键菜单起停 |
| **`off.bat`** | 停止保护，交还系统默认行为 |
| `ka.bat <子命令>` | 命令行全功能，不传参数等于 `ka.bat status` |

关闭那个黑色窗口**不会**停止保护：保护活在自己的 worker 进程里。要停就用 `off.bat`、托盘菜单或面板按钮。

命令行要多一点控制：

```powershell
ka.bat start                      # 一直保护到你说停
ka.bat start -Minutes 120         # 两小时后自动释放
ka.bat start -ExpireAt 09:00      # 到 9 点释放；这个点已过就顺延到明天 9 点
ka.bat start -ExpireAt "2026-08-30 07:30"
ka.bat start -Method mouse -IntervalSec 90 -NoDisplay   # 鼠标心跳、90 秒一次、允许熄屏
```

验证它确实在干活：

```powershell
ka.bat status        # 状态 / 已运行多久 / 心跳发了几次 / 电源请求 flags
ka.bat evidence      # 内核电源日志：最近 N 小时到底待机过几次（默认 24）
ka.bat requests      # powercfg /requests（这条需要管理员，能直接看到我们的请求登记上了）
```

## 它是怎么做到的（双引擎）

单靠一条路做不到全部三件事，所以两条互补的路一起上：

**引擎一 · 电源请求**（思路同 PowerToys Awake）
后台 worker 线程每 `reassertSec`（默认 60 秒）重申一次

```
SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED [| ES_DISPLAY_REQUIRED] [| ES_AWAYMODE_REQUIRED])
```

负责**防睡眠**和**防熄屏**。不改任何系统设置、不写注册表，进程一退出请求就自动消失，系统立刻回到原本的电源计划。

**引擎二 · 防锁屏心跳**（思路同 Caffeine / Mouse Jiggler）
每 `antiLockIntervalSec`（默认 240 秒）发一次无害输入，重置系统"空闲计时器"，从而压住屏保和空闲自动锁屏：

- `key`：按一下 **F15**。绝大多数键盘没有这个键，应用也忽略它，不会误触发任何快捷键。
- `mouse`：把光标移动 1 像素再立刻移回原位（位置是精确还原的，不是"大概回到原点"）。

> 为什么必须两条腿：`SetThreadExecutionState` 压得住电源计时器，压不住**会话空闲计时器** —— 微软那页的原话是 "This function does not stop the screen saver from executing"；而能重置空闲计时器又不需要管理员的，只有往会话里投递输入这一种办法。

## 能力边界（先说清楚做不到什么）

| 需求 | 能不能 | 说明 |
| --- | :-: | --- |
| 阻止空闲自动睡眠 | ✅ | 引擎一，插电池都生效 |
| 阻止空闲自动熄屏 | ✅ | 引擎一（电池低于阈值时按配置会主动放行，见 `batteryAllowDisplayOff`） |
| 阻止空闲锁屏 / 屏保 | ✅ | 引擎二心跳 |
| 重启后自动恢复保护 | ✅ | 装上看门狗 `ka.bat guard` |
| **阻止你手动按 Win+L** | ❌ | 只能用注册表策略禁用锁屏按钮，那是削弱系统安全的机器级策略，不该由一个脚本偷偷做 |
| **阻止合盖睡眠** | ❌（工具能改，但需要管理员） | 合盖动作由电源计划决定，而且本机把它隐藏了。`ka.bat lid -LidAction apply` 会先取消隐藏再设为"不采取任何操作"，并备份原值以便 `restore`；这一步要提权 —— 管理员账户是一次 UAC 确认，**标准账户（如本机）需要管理员凭据**，否则会失败并打印一条让管理员执行一次的 `powercfg` 命令 |
| 阻止电池耗尽导致的关机 | ❌ | 没有电池就没有一切 |
| 压住 OEM/平台强制待机 | ⚠️ 视机型 | 现代待机平台（S0）上，平台策略仍可能盖过电源请求 —— 所以本工具把"到底待机了几次"如实测出来给你看 |
| 穿透锁屏界面继续心跳 | ❌ | 安全桌面（logonui）之下合成输入到不了你的会话。worker 检测到锁屏会**跳过心跳并计数**，不会假装成功 |

## 换一台 Windows 会怎样（适配矩阵）

开源给别的机器用之前，把"实测过"和"只是推理"分开写清楚。

**"实测"的参照机只有一台**：Dell G15 5511（Dell Inc.），Windows 11 build 26200，S0 现代待机（`powercfg /a`：无 S3，休眠"尚未启用"）。下面凡写"本机实测"，都指这一台。换一台机器，尤其是 S3 传统待机机型或台式机，结论要重新走一遍 —— 表格最后一行专门列出了没测过的部分。

| | 结论 | 依据 |
| --- | --- | --- |
| 权限 | **普通账户即可**。全文 P/Invoke 15 个函数，全是标准用户可调用的：电源请求与读数（`SetThreadExecutionState`、`GetPwrCapabilities`、`GetSystemPowerStatus`、`GetLastInputInfo`、`GetTickCount64`）、心跳输入（`SendInput`、`GetCursorPos`、`GetSystemMetrics`）、前台完整性判定（`GetForegroundWindow`、`GetWindowThreadProcessId`、`OpenProcess`、`OpenProcessToken`、`GetTokenInformation`、`CloseHandle`）、会话归属（`WTSGetActiveConsoleSessionId`）；`powercfg` 只读 | 本机账户 `IsInRole(Administrator)` 为 False（2026-08-31 实测），上面 15 个调用全在这个非提升令牌上跑通 —— 包括 `GetPwrCapabilities` 的能力位和 `GetTokenInformation` 的自检 |
| 需要管理员的地方 | 只有 `lid apply`（改合盖动作）和 `requests`（`powercfg /requests` 本身要求管理员）。前者失败时会打印一条让管理员代跑一次的命令，不会静默假装成功 | 本机实测 |
| 看门狗自启 | **非管理员也能装**：`New-ScheduledTaskTrigger -AtLogOn` 不加 `-User` 注册的是"任意用户登录"任务，那是管理员专属；范围收到当前用户就能装 | 踩过一次坑后修正并加测试 |
| 路径含空格 / 中文 | 适配。全部脚本用 `$PSScriptRoot` 定位自己，不写死绝对路径 | 本机就在 `E:\claude code\防休眠`；GitHub 默认解压名 `防休眠-main (1)` 也验过 |
| 无人值守时自启 | 适配。计划任务在"带空格 + 中文"的脚本路径上每 10 分钟自行触发， Last Task Result `0x0` | `ka.bat report` 实读 |
| 复制两份目录 | **不再各跑一份**（这条改口是有原因的）：互斥体锁的是「数据根 + 用户 SID」，同一用户的两份目录解析出**同一个**互斥体名字，第二份撞车就退，不会留下两份谁也停不掉的电源请求。要真并行，得给其中一份 `KA_DATA` 指到别的目录（实测哈希随之改变） | 2026-09-04 实测：两个程序目录 → 同一个 `Local\KA-Worker-DCA86D0FFFB8`，另一进程持有时 `OpenExisting` 跨进程可见。**旧结论"两份各跑自己 worker、本目录点名另一份"是在数据目录还跟着脚本走时测的，已随阶段 1 作废**；对外来 worker 的点名代码还在（`foreignWorkers`），但"两份并行且互点名"这个场景没有重测，别当已验证 |
| 其他语言的 Windows | `powercfg` 的输出只有标签是本地化的，GUID 和十六进制数不是。中英标签直接命中；其他语言靠缩进结构（当前交流/直流恰好缩进 4 空格、属性行 6 空格）；两条都对不上就返回**未知**，不再退回"前两个十六进制值" —— 那个旧兜底读到的其实是设置的 `最小/最大可能值`，会把所有超时都读成 0 | 夹具测试 3 项（中/英/其他标签 + 结构失效 + 与本机直查比对） |
| S3（传统待机）机型、台式机 | 未实测。引擎一正是微软给这类机器的官方推荐用法，但本机的验证全部发生在 S0 现代待机上，`evidence` 读的事件 ID 在 S3 上不同 | —— |
| PowerShell 7（`pwsh`） | 未实测（本机只有 5.1）。代码里没有 `Get-WmiObject`、`winmgmts`、COM 这些 PS7 已移除/易踩的写法，托盘走 `Add-Type -AssemblyName` 在 PS7 下可用；`.bat` 入口显式调 `powershell.exe`，所以 5.1 是保证 | 静态检查 + `tests/ka-syntax.ps1` |
| 非 Windows | ❌ 不适用 | —— |

## 架构

```
ka.bat / on.bat / off.bat / panel.bat / tray.bat     双击入口（ASCII 内容，纯转调 ka.ps1）
└── ka.ps1          CLI：status start stop report check config guard unguard
                    log evidence serve stop-server tray requests lid
    ├── ka-gate.ps1    语言模式闸门：CLM / AllSigned 下按代码 2 拒绝启动，不改本机任何东西
    └── ka-core.ps1 共享库：电源请求、原生 API、powercfg 解析、进程发现、zh/en 词典、
        │            原子 JSON、数据目录与迁移、计划任务、日志、状态聚合
        ├── ka-worker.ps1  保护本体。独立进程 + 命名互斥体，只写 state.json 和 ka.log
        ├── ka-guard.ps1   看门狗。计划任务载体，只做 intent↔实况对账
        ├── ka-server.ps1  本地 HTTP 面板（HttpListener，127.0.0.1）
        ├── ka-lid.ps1     合盖动作读改还原（唯一需要管理员的路径）
        └── ka-tray.ps1    WinForms 托盘图标
dashboard/          index.html + styles.css + app.js + i18n.js（原生 JS，无框架、无 CDN、无构建；i18n.js 是中英两套词典）
tests/ka-tests.ps1  82 个行为测试，实机跑
tests/ka-encoding.ps1 / ka-syntax.ps1 / ka-privacy.ps1 / ka-privacy-mutation.ps1
                    独立门禁：BOM + 纯 LF、可解析、不外传、以及"隐私门禁真的会红"
tests/ka-release-files.ps1
                    便携 zip 的文件清单——唯一真源，打包和探针都从它取，不再各自抄一份
tests/probe-*.ps1   15 个实测探针：迁移、互斥体标识、CLM、下载标记(MOTW)、32 位 PowerShell、
                    区域文化、布尔配置、保存默认值、原生编译、全新解压时的数据根、面板句柄按端口分离，
                    外加四个"自检"
                    逐个跑法和本机判定见下方《独立门禁与实测探针》
README.md / SECURITY.md / PRIVACY.md / CHANGELOG.md / LICENSE (Apache-2.0) / NOTICE
```

进程之间不靠 PID 文件通信：

- **谁是活的**：`Get-Process` + 命令行里的 `-DataDir`（归属判定的主键）；worker 没报告数据根时才退回脚本路径匹配，另有面板句柄 `.server-<端口>.json` 记录的 pid/root 兜底——**按端口一份**，因为一个 TCP 端口只可能被一个活监听者占着，按端口就是按面板；旧的共享 `.server.json` 仍然**读**（改版前起来的面板还得找得回来），只在它的进程确实没了之后才被扫掉。**句柄不是无条件信的**：`startedEpoch` 和进程创建时间对不上（>900 秒）就当它是回收来的 pid，不许据此去杀进程。**2026-09-04 实测**：两个面板各写各的句柄，停掉其中一个，另一个的句柄还在、还能单独被找回来。**这一步刻意朝"是我的"失败**（`Test-KaOwnWorker`）：一个认不出归属的 worker 也算进来，因为"扫到一个都没有"在每个界面上都被读成"保护已停止"，那个误判比多算一个进程贵得多。
- **单实例**：`Local\KA-{Worker|Guard|Tray}-<sha256(数据根 | 用户SID)[0..12]>`。锁的是**数据根 + 谁在用**，不是安装目录——一份 `state.json`、一份 `stop.flag` 天然只属于一个 worker。**2026-09-04 实测**：两个不同的程序目录解析出同一个 `Local\KA-Worker-DCA86D0FFFB8`，另一个进程持有它时 `OpenExisting` 当场可见。所以同一用户复制两份目录时，第二份会撞上互斥体并退出，而不是留下两份谁也停不掉的电源请求；带上 `KA_DATA` 指向另一个目录才会拿到另一个哈希（实测改变）。SID 进哈希是为了让多人共用一份安装时互不排队。
- **状态真相**：`state.json` 是 worker 写的自述，但 `status` 只把它当成"锦上添花"——`Get-KaFullState` 里的 `$live` 判定要求真实进程存在才成立。
- **想不想要保护**：`intent.json`。这是看门狗的唯一依据 —— 你 `stop` 了，它就不会在 10 分钟后自作主张把你刚关掉的保护又开起来（上一版就是这么惹恼用户的）。定时运行到期会被判定为 `expired`，不算"该保护却没保护"。
- **写文件**：一律 write-then-move，读方永远看不到半截 JSON。

## 有效性是实测的

产品里最容易被糊弄的一句话是"已经不休眠了"。本工具的答案是去读**内核电源日志**：

```
Microsoft-Windows-Kernel-Power  506 = 进入待机   507 = 退出待机
Microsoft-Windows-Power-Troubleshooter  1 = 从睡眠唤醒
```

`ka.bat evidence -Hours 24` 或面板《保护是否真的有效》卡片会给出这段时间的待机次数、唤醒次数和逐条时间线。这是**窗口**统计，不管 worker 在不在跑，反映的是"这台机器最近睡了几次"。

真正能当作证据的是另一处：**worker 运行期间**，`ka.bat status` 的"有效性"一行和面板顶部的「有效性」指标只统计**本次运行开始之后**的事件（"待机 0 次 = 本次保护确实生效"），worker 不在跑时它们显示 `—`，绝不拿空窗期冒充成功。

## 远程无人值守（本工具的首要设计目标）

典型症状链：人不在电脑前 → 空闲 → **睡眠**（所有程序冻结、远程工具连不上）→ **锁屏** → 一段时间后**屏幕黑掉** → 你只能等到有人回去按电源键。

| 症状 | 拦截手段 | 引擎 |
| --- | --- | --- |
| 睡眠导致远程失联 | `ES_SYSTEM_REQUIRED`，AC/电池都生效 | 一 |
| 显示器断电黑屏 | `ES_DISPLAY_REQUIRED` | 一 |
| 空闲自动锁屏 / 屏保 | F15 心跳重置空闲计时器 | 二 |
| 重启后保护消失 | `KeepAwake-Logon` 计划任务，登录即按 intent 起保护 | 守护 |
| 进程被强杀/崩溃 | `KeepAwake-Guard` 每 10 分钟对账拉起 | 守护 |

用之前**务必**先装看门狗（一次性，**不需要管理员**，普通账户即可）：

```powershell
ka.bat guard         # 注册 KeepAwake-Logon + KeepAwake-Guard
ka.bat status        # 看门狗一行应显示"已安装（计划任务指向当前目录）"
ka.bat unguard       # 不想要了就删掉
```

它的行为是**对账**，不是"无条件开机"：

- `intent=off`（你主动 `stop` 过）→ 日志记 `GUARD action=none`，不会把你刚关掉的保护偷偷开回来。
- `intent=awake` 而 worker 没了（崩溃、被任务管理器杀掉）→ 立即重新拉起。
- 定时运行中途崩溃 → 按**剩余**时长续跑（实测 30 分钟的任务崩溃后以 29.82 分钟重启），不会因为崩溃白送时间。
- 定时已到期 → 判定为 `expired`，不算"该保护却没保护"，不会复活。

要点：

- 远程桌面（RDP）**断开连接 ≠ 注销**，程序继续跑；但**别点"注销"**。
- RDP 会话里心跳投不到控制台会话，`status` 的"会话"一行会明确告诉你控制台被谁占着（快速用户切换/RDP 时尤其要看）。
- 计划任务的电池相关选项已经配好（`AllowStartIfOnBatteries` + `DontStopIfGoingOnBatteries`），笔记本拔电也照跑。
- Windows 更新重启后：登录即自动恢复，不需要任何操作。

### 断电自恢复链（诚实版）

无人值守的完整恢复链是**三环**，本工具只负责后两环：

1. **BIOS 断电自启**（"断电来电后状态 = 开机"）——硬件行为，任何软件装不回来。
2. **自动登录**（`netplwiz` 关掉"要求用户输入用户名和密码"）——Windows 行为。
3. **KeepAwake-Logon + KeepAwake-Guard**——本工具装的两个计划任务，登录后立即对账拉起。

如果链条断在第 2 环（重启后停在登录界面），保护**不会**回来：`SetThreadExecutionState` 的请求和 F15 心跳都需要一个用户会话。想补上这一段，`ka.ps1 guard -Boot` 会额外注册一个开机触发器任务 `KeepAwake-Boot`——但**注册开机触发器需要管理员权限**，这一点实测钉死：标准账户下 S4U、交互式 principal、双触发器三种写法全部 `Access is denied`。提权用户注册成功时用 S4U（通电即保护，无需登录；登录前只有"不睡眠"生效，心跳不可用），登录后的第一次看门狗对账会把会话 0 里的 worker **迁回桌面会话**（日志记 `adopted-session`），心跳从那一刻恢复。标准账户跑 `-Boot` 会得到明确的一行拒绝说明，而不是假装装上了。

## 配置

配置文件是 **`%LOCALAPPDATA%\KeepAwake\config.json`**（`ka.bat config` 会把它的全路径打印出来；`KA_DATA` 可改到别处）。它**不在脚本旁边**——脚本目录是程序，你的选择归数据目录，这样升级、换目录、开两份 clone 都不会互相踩配置。改完下次 `start` 生效；如果 worker 正在跑且参数不同，会自动重启成新配置（面板上会提示）。

值在使用前一律过校验：数字过夹取（`Get-KaBounded`），枚举和布尔键在**写入端直接拒绝**并说明接受什么，**读取端宽容**——认不出的值回落到**该键自己的**默认值，绝不把缺失的数字夹到最小（0 和"没配过"是两件事）。布尔键手写成 `"false"` / `"off"` / `"否"` 都算假，`"true"` / `"1"` / `"yes"` / `"是"` 都算真；**写成别的会被拒绝**——PowerShell 的 `[bool]"false"` 是 True，这个坑不能留给你踩。文件里**只存与默认值不同的键**，所以升级改了某个默认值时，只要你没动过那个键，你就拿到新默认值。

| 键 | 默认 | 取值 | 含义 |
| --- | --- | --- | --- |
| `language` | `auto` | `auto` / `zh` / `en` | 界面语言。`auto` 下面板跟随**浏览器**语言，命令行跟随 Windows 给当前用户显示的**界面语言**（注册表 `MuiCached`）。词典之外的语言一律给英文。写入口拒绝词典外的值，读入口宽容 |
| `port` | `8791` | 1024–65534 | 本地面板端口 |
| `keepDisplayOn` | `true` | bool | 是否申请 `ES_DISPLAY_REQUIRED`（屏幕常亮） |
| `antiLock` | `true` | bool | 是否发防锁屏心跳 |
| `antiLockMethod` | `key` | `key` / `mouse` | 心跳方式：按 F15 / 移动鼠标 |
| `antiLockIntervalSec` | `240` | 10–3600 | 心跳间隔（秒）。**越小越保险**，但也更容易被注意到 |
| `reassertSec` | `60` | 15–3600 | 电源请求重申间隔（秒） |
| `awayMode` | `false` | bool | 追加 `ES_AWAYMODE_REQUIRED`。微软的定义里它是给**台式机上的媒体录制/分发**用的，明确写了便携机不该开，而且**它不影响睡眠空闲计时器**（要防睡仍得靠 `ES_SYSTEM_REQUIRED`）。现代待机机型基本是空操作 —— 保留只为兼容，默认关。**本机实测（2026-08-31）**：显式熄屏请求的「熄屏→真睡」链连 `0x80000003` 都拦不住（+6 秒，见下方链条条目）；带着它能不能拦住**没测过**（对照臂没跑），所以它在这里只是个不为它付代价的兼容开关，别指望它当解药 |
| `batteryFloorPercent` | `20` | 0–90 | 电池低于这个百分比时，主动放弃屏幕常亮（保命优先于好看） |
| `batteryAllowDisplayOff` | `true` | bool | 允许上述电池降级。设 `false` = 电量再低也强行保持屏幕亮 |
| `logMaxKb` | `512` | 64–20480 | `ka.log` 上限，超了轮转成 `ka.log.1` |

改配置三种等价方式，都走同一套校验：

```powershell
ka.bat config                                  # 看"生效配置"（config.json + 校验/夹取后的结果）
ka.bat config -Set antiLockIntervalSec=90      # 命令行改
# 或直接编辑 config.json，也可以在本地面板里改
```

`ka.bat check` 会重新读本机环境并把结论写进 `machine.json`。它只**建议**心跳间隔（发现更短的空闲超时时提示你调小），不会替你改 `config.json`。

### 界面语言（中文 / English）

```powershell
ka.bat config -Set language=en      # 长期生效，写进 config.json
$env:KA_LANG = 'en'                 # 只影响当前这个进程，不动配置文件
```

- 面板右上角有 自动 / 中文 / English 三档，点了立刻重绘并写回 `config.json`；命令行与托盘下次启动读同一个值，作用范围见本节最后一条。
- `auto` 的定义按界面各取最贴近的信号：面板在浏览器里渲染，所以跟随**浏览器**语言；命令行跟随 Windows 的**当前用户界面语言**，读的是注册表 `HKCU:\Control Panel\Desktop\MuiCached\MachinePreferredUILanguages`（也就是"设置 → 时间和语言 → 显示语言"写进去的那个值），拿不到才退到 `CurrentUiCulture`。**不用 `CurrentUICulture` 作首选是实测结论**：本机它报 `en-US`，而 `MuiCached` 报 `zh-CN`，Windows 界面确实是中文 —— 用错了会让一个中文用户一开机就拿到英文命令行。
- 词典只有中英两种。日语、德语、法语系统的用户拿到的是英文：这是有意的兜底，比给一个看不懂的语言好，也不会让"我的系统不是中文"变成用不了。
- **日志和 `state.json` 不受语言影响**：`PULSE`、`HEARTBEAT`、`EXIT`、`settes-zero:initial`、`note=lock-screen`、`note=battery-floor`、`note=il-mismatch`、`PULSE-SKIP reason=il-mismatch`、`PULSE-SKIP reason=lock-screen`、待机原因标记 `screen-off` / `idle` / `lid` 这些标记是机器读的，永远是 ASCII。面板的波形、`evidence` 的统计、测试断言都靠它们；显示时再经词典换成句子。所以换语言**不改变任何行为，只改变措辞**，也意味着 worker 更新不会把一句新话术硬塞进每种界面里。
- `language` 在读写两端规则不同，是有意的：**写入端拒绝**（`ka.bat config -Set language=de` 与面板上点一个非法值都会报错，且不落盘），因为你刚打错的那个字符应该当场知道；**读取端宽容**（config.json 是手改的、从别的机器同步来的、上个版本写的，任何一种都不能让工具起不来，只能回落默认）。
- 当前覆盖范围：**全部界面中英全量** —— 面板 `dashboard/i18n.js` 两套词典 459 个键；命令行 `status` / `report` / `check` / `start` / `stop` / `config` / `guard` / `serve` 等全部输出、托盘菜单与气泡、`ka.bat lid` 的合盖文案、看门狗与面板进程的控制台行，统一走服务端 zh/en 词典（缺键、占位符对不上、英文值里混进中文，测试直接失败）。两条兜底测试把成品抓在手里：把 `/api/state`（面板每 2 秒轮询的那个负载）按英文渲染后逐字符串叶子查汉字，以及真实跑一遍 `ka.ps1 status` 的英文输出逐行查汉字（两处都放行路径——项目目录名本身就是中文，而路径是你的数据不是我们的话术）。唯一的例外：`ka-guard-missing-core.txt` 那一行天生双语，因为它写下的前提是 `ka-core.ps1` 已经丢了、词典跟着一起丢了。
- **`report` 与 `status` 只发数据，不发句子**：风险条目、建议理由、红色提醒条、同类软件名在 JSON 里长这样 —— `{"id":"report.risk.lid-hidden"}`、`{"id":"report.why.half-of-lock-timer","secs":180}`、`{"level":"bad","id":"alert.multiWorker","count":2}`、`{"id":"competitor.powerToys"}`。`id` 就是三本词典（服务端 zh、服务端 en、面板 i18n.js）里共同的键名，所以一条测试就能从**发出端**向外查覆盖：词典缺键、占位符少给了数、面板少写一行，都会在测试里失败，而不是等用户看到一个空句子。认不出的 `id` 显示成 `id` 本身（可 grep），不会显示成空白。代价是命令行不再"顺手 Write-Host 一句话"，好处是两种界面永远说同一套话。

## 东西写在哪儿

三个目录，各管各的事：

| | 位置 | 里面是什么 |
| --- | --- | --- |
| **程序** | 脚本所在目录（`ka.bat config` 打印的 `program`） | 只有 `.ps1` / `.bat` / `dashboard/`。日志、配置、状态全在下面两处，所以整个目录可以随时替换、覆盖、升级。唯一可能出现在这里的是 `ka-guard-missing-core.txt`——`ka-core.ps1` 已经不在了、看门狗没法用正常途径报告时的最后一搏（那个目录也写不动就落到 `%TEMP%\KeepAwake-guard-missing-core.txt`） |
| **数据（按用户）** | `%LOCALAPPDATA%\KeepAwake` | `config.json`、`intent.json`、`state.json`、`ka.log`（+轮转的 `ka.log.1`）、`machine.json`、`.server-<端口>.json`（面板句柄，按端口一份）、`stop.flag`、`.migrated.json` |
| **数据（按机器）** | `%ProgramData%\KeepAwake` | 只有 `ka-lid-backup.json`——合盖动作的原值备份。它是**全机**设置，备份到按用户目录就会张冠李戴，所以单独放 |

拆分是为"下载即用"服务的：程序目录是**可替换的**，你的选择是**要留下的**。`KA_DATA` 可把数据根改到别处，它设了就用——哪怕指到一个不可写的目录，也绝不偷偷换个地方写，因为探针和测试要求的就是那个目录。`%LOCALAPPDATA%` 本身取不到时才退到 `%TEMP%\KeepAwake`（记 `no-localappdata`）；取到了却不可写**没有兜底**，路径原样留着，好让每条消息都点得出失败的那个位置（面板红条 `alert.dataDirUnwritable`，`/api/state` 里的 `dataError`）。

第一次以"数据目录独立"这个版本启动时，它会**把程序目录里已有的那几个文件复制**进 `%LOCALAPPDATA%\KeepAwake`（不是移动——原件留着），并把结论记进 `.migrated.json`。**已经存在的文件一律不覆盖**，冲突时跳过并在日志里留 `MIGRATE-SKIP files=... from=...`；哪个文件都没复制也没跳过，就不写这个标记。

逐文件写的是什么字段、含不含个人信息、怎么一键擦干净：见 **[PRIVACY.md](PRIVACY.md)**。

## 本地面板

`panel.bat`，或 `ka.bat serve`。面板是只读 GET + 明确 POST 的极简 HTTP 服务，页面 2 秒轮询一次状态。

- **状态台**：倒计时环、`SetThreadExecutionState` 的逐位读回（引擎 1）、心跳脉冲的次数/间隔/上次结果/锁屏跳过（引擎 2），以及一条按 `antiLockIntervalSec` 真实绘制的心跳波形。
- **对账条**：`intent.desired` / 时长 / intent 写入时间 / worker pid / 最近上报，一眼看出"你以为在保护"和"机器上真的在保护"是否一致。 属于**别的目录**的 worker 也会被点名并给出那个目录 —— 两份 clone 各持一份电源请求时，这里不会假装"已停止"。
- **控制**：时长预设（30 分钟–不限 + 自定义分钟）、屏幕常亮 / 防锁屏 / 离场模式 / 电池允许熄屏、心跳方式与间隔、重新声明、电池阈值，改完直接点启动。
- **存为默认**：把当前表单写进 `config.json`。启动时传的参数只作用于本次运行，重启后按 `config.json` 恢复——想让某组参数长期生效必须点它。面板会显式标出与 `config.json` 不一致的键。
- **有效性**：待机次数、唤醒次数、逐条时间线，窗口可选 6 小时 / 24 小时 / 3 天（这个窗口是真的查询参数，不是文案）。
- **合盖预报**：机检区多一块「现在合盖会发生什么」：按当前插电/电池档读出合盖将执行的动作（`Get-PowerSetting`，免管理员），跟着「设置实测」对账——以 lid 写入备份（`ka-lid-backup.json`）的时刻为界，看事件日志里此后有没有合盖待机，五态如实报：从没改过 / 改了还没合过盖（**写入成功≠平台遵守**）/ 改后那一次合盖没睡（只证明那一次，不是永久保证）/ 改后仍睡 / 事件查不到；「最近一次合盖待机」单独一行，块底注明整块是事件日志的历史口径、不是实时开合读数（那没有标准的免管理员读法）。CLI `report` 同样两行。
- **本机环境适配**：电源计划、睡眠状态、屏保、组策略锁屏、合盖动作、风险提示，一个按钮重新检测。
- **远程无人值守**：看门狗安装状态、计划任务上次/下次/结果，以及写明"什么时候会拉起、什么时候不会"的对账规则。
- **运行日志**：尾部日志 + 自动刷新 + 关闭面板进程（保护本身继续跑）。
- **能力边界**：能压住什么、压不住什么、怎么自己验证，三栏并列写死在页面上。
- 快捷键：`S` 启动、`X` 停止、`R` 刷新（输入框内不触发）。
- 编辑中的选项**不会被轮询冲掉**（脏标记 `controlsDirty`，只有点刷新才回读服务器值）。

### 安全模型

面板只监听回环前缀（`http://127.0.0.1:<port>/` 和 `http://localhost:<port>/`），但"只在本地"不等于谁都能碰——任意网页都能向 `127.0.0.1` 发请求。所以：

- **Host 固定**：只接受 `127.0.0.1` / `localhost`（端口任意，因为 `port` 可配置），挡住 DNS 重绑定。
- **Origin 固定**：请求带来 Origin 时必须是本机回环源；而且服务端**从不**发出 `Access-Control-Allow-*`，跨源读取拿不到任何东西。
- **`/api/*` 必须带 `X-Ka-Client: ka-dashboard`**。跨站表单/`fetch` 没法伪造这个自定义头（发不出来就先被预检拦住），所以这条是真正的 CSRF 边界。403 是直接掐断连接返回的，裸 socket 测试里也以"连接被中断"本身作为答案。
- **静态文件白名单**：只发 `dashboard/` 下按名字列举的那几个文件，不存在路径穿越。
- **GET 永不改状态**：所有副作用都在 POST 里。
- 不监听 `0.0.0.0`，不需要防火墙规则，没有任何外部可达面。

## 测试

82 个行为测试，跑真机、真电源 API、真事件日志、真计划任务，不是 mock：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\ka-tests.ps1
#   -Only 心跳                按名字子串选跑（只传一个子串）
#   -LeaveOutputs            保留临时副本
```

> `-Only` 是子串匹配，测试名多为中文（中文子串从 Git Bash 传进去实测是好的）。两个坑：`-Only a,b,c` 这种多值形式不会被拆成数组，结果是**一个测试都不跑**（汇总显示"通过 0"），想跑几组就分别跑；以及不要把带中文的**绝对路径**当 `-File` 的参数传，argv 会被弄坏并且**静默不执行** —— 用相对路径，必要时配 `-WorkingDirectory`。

覆盖的都是这个仓库真踩过的坑，或者产品对用户做出的、错了很贵的承诺：

- 心跳必须**真的**重置系统空闲计时器；鼠标心跳必须把光标放回**精确**原坐标。
- `powercfg /q` 解析必须取"当前交流/直流"，不是"最小/最大可能值"——第一版取了后者，于是所有超时都读成"从不"。第二版按标签过滤，只认中文和英文，并且**在标签认不出来时退回"前两个十六进制值"**：那在非中英版本的 Windows 上仍然是最小/最大可能值，等于把同一个 bug 换了个触发条件留下。现在解析器多一个 `-Text` 参数（能被喂夹具了，这是它以前测不到的根因），标签命中优先、否则按缩进结构取当前交流/直流，两条都不中就返回未知 —— **宁可显示"未知"，也不给一个像模像样的错数**。
- `SetThreadExecutionState` 返回的是**上一次的**掩码不是刚设的。测试因此改用"下一次调用读回上一次"的方式验证 flag 真的登记上了，失败信息里带真实十六进制。
- 看门狗的登录触发器必须绑定**当前用户**：`-AtLogOn` 不带 `-User` 的含义是"任意用户登录"，那是管理员专属注册，于是"不需要管理员"这句承诺在普通账户上直接变成 `Access is denied`。测试用一次性探测任务名真注册、真删除来把它钉住。
- 时长显示分两种语义且不可混用：电源计划里的 `0` 是"从不"，已经过去的秒数里的 `0` 是"刚刚"。混用的结果是刚启动的 worker 显示"已运行 从不"。
- worker 的声明参数与配置键的映射，用 **AST** 读（`Get-Command -LiteralPath` 只给通用脚本参数，用它等于没测）。
- 停止必须是协作式且干净的：进程消失、`stop.flag` 消失、`ka.log` 里有 `STOPPED`。
- 定时到期自行释放、并发启动收敛为 1 个、日志轮转、看门狗能收掉卡死的 worker（用诱饵验证）。
- 面板生命周期：健康面板必须被**复用**而不是杀掉重启（`Test-KaUrl` 曾经因为不带 `X-Ka-Client` 把健康面板判成死的，于是每次调用都重启一次面板）。
- `/api/start` 回显的 `applied` 必须包含面板读取的每一个键 —— 少了就是"界面能动但没作用"。
- 面板上的每个控件都必须真的改变后端行为：`[Uri]::Query` 是**带前导 `?`** 的，于是每个请求的第一个参数落到 `"?hours"` 这类键上被静默忽略 —— 有效性时间范围和日志 tail 都在"能动但没用"。测试用真 HTTP 请求把 `hours=6`、`tail=1` 钉住（进程内直调 `Invoke-KaApi` 传的是不带 `?` 的串，所以以前测不到）。
- **电源状态每一位都要按文档解释，且要和交流电一起判断**：`BatteryFlag & 8` 是"电池临界"。这台机器的固件在**插着电、99%** 时把它置了 1，旧策略一读就 `break` —— worker 上报完状态 1 秒后自己退出，而 `ka.bat start` 已经打印了"保护已启动（pid 14176）"，面板随后显示"未运行"。修法是两层：电池策略从 worker 循环里抽成纯函数 `Get-KaBatteryAction`（插着电永不中止；降级只在真的用电池时发生；恢复带 10 个点迟滞），测试直接喂它 13 种电源组合；`Start-KaWorker` 在收到 worker 自述后再等 4 秒确认进程还活着才回 `Ok`，否则把 worker 自己写下的退出原因当失败原因报出来。
- **别的目录起的 worker 必须被点名**：互斥体按目录哈希命名，所以两份 clone 会各起一个进程、各持一份电源请求。以前扫描只认本目录，另一份完全隐形 —— 这里报「已停止」，电脑却照样不睡，而 `stop` 对它无能为力。归属判定同时修掉了 `-like "*$root*"` 的前缀误判（`防休眠` 会把 `防休眠-v2` 认成自己人）；归因不出来时一律倒向"算我的"，因为空扫描会被每个界面读成"保护已释放"。测试真的在临时目录里起一个 worker 来验证这两向。
- **计划任务的返回码是无符号 DWORD，格式化失败不许改动"存在性"**：`LastTaskResult` 在被打断的运行上是 `0xC000013A`（3221225786），旧代码用 `[int]` 读它 —— 溢出抛异常，而那句抛异常和 `installed = ...` 在同一个 `try` 里，于是异常直接跳过赋值：**两个计划任务好好注册着，面板和 `ka.ps1 status` 却报"看门狗 未安装"**。现在 `installed` 只由任务存在性决定，运行记录读失败最多让那一格显示"运行记录读取失败"。测试拿 `Get-ScheduledTask` 独立复核 `installed`，并保证异常原文不会漏进用户看的字段。
- **内核能力位是主源，本地化文本只是后备**：`GetPwrCapabilities`（PowrProf.dll）的 `SYSTEM_POWER_CAPABILITIES` 按 SDK 自己的 `um/winnt.h` 逐字节解码 —— 那个结构体是**扁平的每成员 1 字节**，不是网上常说的位域打包；合成缓冲把每个用到的偏移钉死。`AoAc` 位直接回答"是否 S0 低电量待机"，不再依赖被翻译的 `powercfg /a` 文本；套件实时核对内核位与文本解析这两个独立来源 —— 同一个事实两条路，不可能错得一样。
- **UIPI 会静默丢弃心跳**：前台窗口属于更高完整性（管理员）进程时，`SendInput` 注入不报错、但输入到不了任何地方 —— worker 照样计数"心跳已发"，空闲计时器却根本没被重置。worker 现在每跳先读前台进程的完整性级别（`PROCESS_QUERY_LIMITED_INFORMATION` + `TokenIntegrityLevel`），**实测到** low→high 才跳过并计 `skipped:il-mismatch`；没测出来的状态（无前台、进程打不开）一律不当作拦截 —— 既不假装跳过，也不丢弃可能已落地的输入。
- **`requestsoverride` 是隐形拦截者**：一条指向 `powershell.exe`/`pwsh.exe` 的电源请求替代规则，会让内核把本工具发出的所有电源请求**直接扔掉、全程无错** —— 界面显示"保护中"，电源管理器当没看见。`ka.bat requests` 现在列出替代表并点名命中本工具的条目，`report` 的风险列表同步出现这一条。**两个读取的权限不一样，别混着说**（2026-08-31 在本机非提升令牌上实测）：替代表用 `powercfg /requestsoverride` 的列表形式读，**不需要管理员**（退出码 0，本机替代表为空 —— 这条隐形拦截者目前不在这台机器上）；同一条命令里"当前谁持有着请求"用的是 `powercfg /requests`，**它本身就要求管理员**（退出码 1，直接回"此命令需要管理员权限，并且必须从提升的命令提示符中执行"），所以那一段必须提权才看得到，标题里也照这一点名"需管理员"。写入替代表同样需要管理员。
- **合盖风险的诚实边界**：SETS 管不到合盖 —— 合盖动作在固件/ACPI 层面，任何防休眠软件都拦不住。**「实时开合状态」至今没有标准的非管理员读取途径**（2026-08-31 再测 `root/wmi` 的盖子类仍是"无效类"），所以配置层面工具只报告"配置的动作"（AC/DC 两档分开点名），绝不编造一个当场读数出来。但**「事件发生那一刻的开合状态」是有的**：每条 Kernel-Power 506/507 自带命名属性 `LidOpenState`，`evidence` 逐事件读它 —— 于是面板能说"这次待机是合着盖子进的"，这是历史记录，不是实时状态，两者绝不混写成一个读数。内核 `LidPresent=0` 的机器（台式机/无盖设备）不再报合盖风险。
- **待机发生了就要说出「为什么睡」**：2026-08-29 晚的真实事故 —— 最初的复盘写过一句"合盖瞬间内核发出 Screen Off Request"，而事件的**命名属性**把这句话证伪了：22:59:20 那条 506 的 `Reason` 确实是 screen-off-request，但同一事件里的 `LidOpenState` 显示**盖子是开的**；真正 reason=lid、LidOpenState=closed 的合盖事件在 14 分钟后的 23:13:47，同一秒进、同一秒出，23:13:48 那条 507 的 `Reason` 是 input-mouse、`LidOpenState` 仍是 closed，锁屏就在这一秒 —— 两个相隔 14 分钟的事件，被一句因果话缝在了一起。这就是逐事件命名字段存在的意义。`evidence` 现在从 Kernel-Power 506 的**命名属性**（按名读事件 XML，零本地化解析，任何 UI 语言成立）提取 `Reason`、`LidOpenState`、`ExternalMonitorConnectedState`：本机近 14 天实测 38 次进入 = 33 空闲超时(12) + 3 SC_MONITORPOWER(3) + 1 屏幕熄灭请求(11) + 1 合盖(15)，未知码显示原始 `code-N`（可 grep，不伪装成已知原因）；**这个 38 会随窗口漂移，所以它是"当时看到了什么"的记录，不是被断言的数字** —— 测试钉的是恒等式（原因计数之和 == enters）和字段值域，不是计数本身。交叉核对也留着：全部 506 里 `reason=lid` 的那一条必定带 `LidOpenState=closed`，且没有任何别的码带 closed —— 两条独立字段互为证据，不是"读一个数换个说法"。status 新增待机原因行、面板时间轴悬停标记带 `reason=`/`lid=`/`extMon=`、report 提醒条 `alert.standbyLid` 按事件口径点名，三处同说一套话。
- **「熄屏→真睡」链条是这台机器的实测事实，away mode 没过对照**：五次独立观测到同一条链 —— 显式熄屏请求后 5–6 秒内 566 从 1 直落到 2（真睡）：08-29 事故（当时在跑的 v1 默认就持 `0x80000003`，+6s）、08-30 三次故意发的 SC_MONITORPOWER（各 +5s；当时谁持着请求已不可考，日志被测试轮转覆盖）、2026-08-31 的对照实验 A 臂 —— 产品 worker（pid 33868）经 state.json 伪证门（`activeFlags=0x80000003` 且 pid 对上）加 `ka.log` 的 `STARTED`/`STOPPED` 双指纹核对后发请求：15:17:11 熄屏（506 `reason=sc-monitorpower`、566 0→1 同秒）、15:17:17 真睡（566 1→2，+6s），真睡了 42 秒被键盘唤醒。链条的**对照组**也钉住了：近 14 天 33 次 video-idle（空闲超时）熄屏没有一次链成真睡（12s–3.6h 后都是回到亮屏）—— 危险的不是熄屏本身，是**显式的熄屏请求**。设计中的 B 臂（加 `ES_AWAYMODE_REQUIRED` 的 `0x80000043` 是否拦得住）**没跑**：实验间隙保护被重新拉起（15:18:52 `STARTED ... antiLock=key@240s`，非探针所为，intent=awake），在「停掉正在跑的保护」与「少测一个对照」之间按用户拍板选了后者。所以 `awayMode` 默认维持 `false`：一个没跑成的对照臂换不来改默认值的证据。顺带一条文档学事实：现行 `winnt.h` 的 `SYSTEM_POWER_CAPABILITIES` 里**没有 `AwayMode` 字段**，想用能力位预检 away mode 是否受支持，这条路不存在。探针已删，A 臂数据以内核事件日志为证。
- **锁屏必须是「当下可知」，不是一个累计数字**：事故本身可复核，靠的是内核事件而不是本机日志 —— 2026-08-29 23:13:47 那条 506 带 `Reason=lid`、`LidOpenState=closed`，同一秒 566 从 2 回到 1、507 退出也仍写着 closed；23:13:48 又来一条 507 `Reason=input-mouse`、`LidOpenState` 依旧是 closed。**近 14 天全部 37 次退出里只有这两次是合着盖子的** —— 也就是说它是"合着盖就被唤醒，然后远程接进来只看到锁屏"，不是"开盖唤醒"。当时确凿在跑的是 v1 引擎，`keep-awake.log` 最后一行 `2026-08-29 23:13:47 heartbeat pid=6712 pulses=76` 正正停在那一秒；v3 那晚的 `ka.log` 已被测试套件的"备份—还原"覆盖，那一晚它到底写没写过东西，今天无从复查 —— 也不能拿它当证据。
  - **顺带撤回一句引文**：这一条从前是以一行 worker 日志开场的（`23:13:48 HEARTBEAT pid=25116 ... ilSkips=81 flags=0x00000003`，还说"开盖唤醒后 1 秒 worker 自己写下"）。它经不起复查，四条各自独立都不成立：pid 25116 在全盘任何产物里都不存在，只在 README 自己出现过；`activeFlags` 每次 apply 都 `-bor ES_CONTINUOUS`（`ka-worker.ps1:113`），所以 flags 读不出 `0x00000003` —— 本机 `ka.log` 里所有带 flags 的行（两条 `STARTED flags=`、两条 `STOPPED released=`）一律是 `0x80000003`，一个 `0x00000003` 都没有；第一条 HEARTBEAT 要等 `$nextBeatLog = $now + 1800`（`ka-worker.ps1:150`），而今天两次运行分别只活了 42 秒和 10 秒，`ka.log` 里因此**一条 HEARTBEAT 都不存在**，刚起 1 秒的 worker 更不会写；`ilSkips=81` 是一跳最多一个的计数，1 秒攒不出 81。规则留在这里：**带时间戳的引文必须能被重新读出来，读不出来就当没说。**
  - 现在三处同说一套话：`state.json` 多一个 `lastLockEpoch`（最后一次被安全桌面挡住的具体时刻）、worker 每跳在被锁时写 `PULSE-SKIP pid=… reason=lock-screen secureDesktop=true`（第 1 次以及每 20 次才写一行，否则一次过夜锁屏会刷满日志）、status/report/面板在**锁屏仍然成立期间**发红色提醒条 `alert.sessionLocked`，把"电源请求仍然有效、电脑不会休眠，但远程接入只会看到锁屏"直接说破，撤锁后自动消失。心跳规格表也多了「最后锁屏」一列。新测试不走"改 `state.json` 再读回来"那条路 —— 活着的 worker 大约 1 秒内就会把它重写掉（这一点在本仓库被实证过三次），任何回填式断言都是竞态；锁屏检测用的原语是"有没有叫 `logonui` 的进程"，所以把一个 `cmd.exe` 副本改名成 `logonui.exe` 跑起来就是一个**端到端**的合法夹具：真的被检测到、真的跳过心跳、真的写下时间戳与日志行、真的弹出提醒条，撤掉夹具后检测与提醒条一起消失。
- 本地主机边界：裸 socket 伪造 Host / Origin / 缺头 / 路径穿越 / 非法方法。

套件会先把 `config.json`、`intent.json`、`state.json`、`ka.log`、`.server.json` 备份，跑完在 `finally` 里还原，并停掉自己启动的 worker —— 中途崩了也不会让这台机器处于"意外被保护/意外没保护"的状态。同一段 `finally` 还会把**进程已经不在了**的面板句柄扫掉（含被强杀的测试面板留下的 `.server-<端口>.json`），但**pid 还活着的句柄一个都不碰**，所以你开着的面板不会因为这些测试而失联。已安装的看门狗计划任务也在同一段 `finally` 里停用并按捕获到的状态还原：看门狗每 10 分钟对账的就是这些测试正在改写的 `intent.json`/`state.json`，实测它会把自己启动的 worker 按 `reason=stopped` 收割掉，让两个测试看起来像产品 bug。

当前状态：**82 个 `It` 用例，最后一次全量实机运行为 2026-08-30（通过 82，失败 0，跳过 0）**。用例数与文件里 `grep -c "It '"` 的 82 一致，但"失败 0"是那一天那次运行的结果 —— 这一行新立的规矩对它自己同样成立：想引用当天状态就得当天跑一遍，跑不了就别替它说话。**2026-09-04 又动了套件两处**（面板句柄那条断言改走 `Get-KaServerHints`，`finally` 加了陈旧句柄清扫），改后**没有再全量实跑**，所以上面那个"失败 0"不顺延到今天。

### 独立门禁与实测探针

`tests/` 里除了 `ka-tests.ps1` 还有一批**各自独立、几秒到几分钟跑完、不碰这台机器的电源状态**的检查。它们不进套件是刻意的：有的要一份临时 clone，有的要第二个进程真的去抢互斥体，有的要把成品下载伪装成带 Web 标记的文件，有的要**短暂改坏 `ka-core.ps1` 再改回来**——这些都不该塞进一个"在正在工作的机器上随手跑跑看"的套件里。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\ka-encoding.ps1     # 也可 -Apply 补 BOM
powershell -NoProfile -ExecutionPolicy Bypass -File tests\probe-motw.ps1      # 探针同理
```

| 文件 | 钉住什么 | 2026-09-04 实跑末行 |
| --- | --- | --- |
| `ka-encoding.ps1` | 每个 `.ps1` 都是 UTF-8 **带 BOM** 且 **纯 LF**（`.gitattributes` 锁了 `*.ps1 eol=lf`） | `all scripts carry a UTF-8 BOM and are LF-only` |
| `ka-syntax.ps1` | 递归解析每个 `.ps1`，只解析不执行；能看见自己 | `all files parse clean` |
| `ka-privacy.ps1` | 成品里没有任何非回环 URL、没有未登记的联网 API、监听前缀全在回环、从不发 `Access-Control-*` | `PRIVACY GATE OK: ...` |
| `ka-privacy-mutation.ps1` | 上面四条**真的会红**：往临时副本里各注入一个缺陷，要求逐个点名 | `MUTATION CHECK OK: all four privacy rules fire on injected defects` |
| `ka-release-files.ps1` | **便携 zip 装了什么，只有一份清单**：探针读它，CI 打包也读它 | `-File` 直接跑会打印清单 |
| `probe-native.ps1` | 从 `ka-core.ps1` 里按 AST 抠出内嵌 C#，用同一个 csc 真编译，并核对产品调用的 15 个成员都在 | `... compiles, exposes all 15 members the product calls, and answers when run` |
| `probe-culture.ps1` / `-mutation.ps1` | 7 种区域设置下机器可读通道不变味（小数点、佛历、数字替换）；再把三处修复改回旧写法要求它变红 | `machine-readable output holds across 7 cultures` / `all 4 assertions are red on the reverted code and green on the shipped one` |
| `probe-clm-gate.ps1` | CLM 闸门的三条腿：静态接线、真降级后按代码 2 干净拒绝、去掉闸门必须炸在 `Add-Type` 上 | `9 cases green now, 7 red without the gate, 6 entry points gated before ka-core` |
| `probe-motw.ps1` / `-selftest.ps1` | 带 Zone.Identifier 的下载与不带的那份**输出逐行同形**，内嵌 C# 照样编译；`Expand-Archive` 实测不传播标记；自测用 CLM 注入一次真实阻塞证明它会红 | `a Zone-3 download of 23 files behaves exactly like an unmarked one...` / `catches a blocked native build on the marked leg and stays green when nothing is blocked` |
| `probe-wow64.ps1` / `-selftest.ps1` | 32 位与 64 位 PowerShell 的逐项差分；自测注入一个假的 32 位分歧，要求差分点名它 | `32-bit and 64-bit PowerShell give 37 identical answers...` |
| `probe-migrate.ps1` | 首次迁移：只填空缺、**永不覆盖**数据目录已有的文件 | `migration brings an old install forward without ever replacing a file the data root already has` |
| `probe-config-value.ps1` | 布尔词表：`"false"`/`"off"`/`"否"` 是假，词表外的值被拒绝且不落盘 | `a hand-edited config.json means what the person who edited it wrote` |
| `probe-fresh-data.ps1` | 按 zip 清单拼一份"刚下载的目录" + 空数据根，看首条命令到底写了什么、只读命令一个文件都不许多写 | `a fresh download runs, writes only what it is told to, survives a hand-mangled config.json, and shows one version` |
| `probe-save-default.ps1` | 面板「存为默认」走真 HTTP、真进程、真文件：存它所显示的，拒它不能兑现的 | `存为默认 over HTTP stores what the form showed, and refuses what it cannot honour` |
| `probe-mutex-identity.ps1` | 单实例互斥体锁的是**数据根 + SID**，不是安装目录；跨进程真的抢得到 | `the mutex keys on data root + SID, not on the install folder` |
| `probe-server-hint.ps1` / `-selftest.ps1` | 两个真面板两个真端口：句柄**按端口**各一份、停掉一个不许把另一个变成孤儿、端口还在应答就不许说"面板没有在运行"；自测分别退回修复前的两种写法（共享 `.server.json` + 退出即删 / 不探端口），要求各自红在自己的断言上 | `two panels hold two handles, stopping one leaves the other findable...` / `reverting either half of the fix turns this probe red on its own assertion, and the untouched mutant stays green` |

探针的脚手架要么写在仓库根的 `_tmp/`（gitignore 里，所以探针自己带 `-Force` 创建——全新 clone 时它并不存在），要么写在
`%TEMP%` 下的独立目录里（`probe-native` / `probe-wow64` 的编译沙箱、`probe-culture-mutation` 捕获的子进程输出走这条）。总之内嵌
C# 的 `.cs`、临时 clone、被改坏的副本都不会落在 `tests/` 旁边，中途被打断也不会留下第二份 `ka-core.ps1`。`probe-culture-mutation.ps1` 会**临时修改** `ka-core.ps1` 与 `ka-lid.ps1` 再逐字节还原，并在还原后用 md5 自查——如果它被打断，`git diff` 里会留下痕迹，别把那当成产品问题。

## 本机实测（2026-08-28，`ka.bat report` / `evidence` 原样输出）

```
系统      : Microsoft Windows 11 家庭版 中文版  10.0.26200 build 26200
PowerShell: 5.1.26100.9168
机器类型  : 笔记本（有电池）
睡眠状态  : S0现代待机=True  S3传统待机=False  休眠=False
计划休眠  : 交流 从不 / 电池 从不
计划熄屏  : 交流 10 分钟 / 电池 3 分钟
合盖动作  : 隐藏/不可读
屏保      : 无 / 锁屏策略：未发现组策略锁屏
建议心跳  : 240 秒
```

看门狗在这台机器上是**自己按时跑的**，不是测试里手工触发的：`KeepAwake-Guard` 每 10 分钟一次，`Get-ScheduledTaskInfo` 记录 `0x0 · 成功`，`ka.log` 里留下 `GUARD action=none intent=off workers=0 alive=no`（2026-08-29 观察到 10:28 / 10:38 两次自动运行）。计划任务的执行路径是带空格和中文的（`E:\claude code\防休眠`），这一并验证了"装在中文用户名/中文目录里也能被计划任务正常调起"。

**根因**：这台机器是 S0 现代待机平台。电源计划写着"睡眠从不"，但内核日志证明空闲时它照样反复自己进待机 —— 最近 72 小时 **10 次待机 / 9 次恢复**，而本工具当天 18:31 才第一次运行，也就是说这 10 次全部是**无保护状态下**发生的。用户看到的"锁屏 → 黑屏 → 按好几次空格才唤醒 → 要求登录"，全过程就是从 S0 待机里醒过来。

这是现代待机平台 + OEM 电源管理的已知行为，不是设置错误，改电源计划治不好。`ES_SYSTEM_REQUIRED` 能压住空闲待机，压不住合盖和平台强制策略 —— 所以无人值守时请保持开盖（或用 `ka.bat lid -LidAction apply` 明确改掉合盖动作）。

## 卸载 / 恢复原状

```powershell
off.bat             # 或 ka.bat stop：停止保护，电源请求随进程消失
ka.bat unguard      # 删除两个计划任务
ka.bat stop-server  # 关掉面板进程
ka.bat lid -LidAction restore   # 若曾改过合盖动作，还原备份值
```

然后删掉三处（后两处只在你用过对应功能时存在）：

```powershell
Remove-Item -LiteralPath "$env:LOCALAPPDATA\KeepAwake" -Recurse -Force   # 配置、日志、状态
Remove-Item -LiteralPath "$env:ProgramData\KeepAwake" -Recurse -Force    # 合盖动作备份（改过才有）
Remove-Item -LiteralPath "脚本目录" -Recurse -Force                        # 程序本身
```

它不留服务、不留驱动、不改电源计划、不写注册表策略。三个例外都是你明确下达过的命令：`ka.bat guard` 注册的那两个计划任务（`ka.bat unguard` 删除），`ka.bat lid -LidAction apply` 对合盖动作的修改（自带备份，`restore` 还原），以及上面那两个数据目录（**只删脚本目录不会带走它们**——配置和日志会留在 `%LOCALAPPDATA%` 里）。逐文件说明与更彻底的清理见 [PRIVACY.md](PRIVACY.md)。

## 常见问题

**窗口一闪而过 / 报执行策略错误？** 不要用 `powershell ka.ps1`，用目录里的 `.bat`（它们带 `-ExecutionPolicy Bypass -NoProfile`）。手工跑：`powershell -NoProfile -ExecutionPolicy Bypass -File ka.ps1 status`。

**面板打不开？** `ka.bat stop-server` 然后 `panel.bat`。端口被别的东西占了就改 `config.json` 的 `port`。

**"停止后电脑还是会醒"？** 三种可能，`ka.bat status` 都会点名：机器上装着 PowerToys Awake / Caffeine 之类（"同类软件"一行）；你放了**两份本工具的副本**、另一份的 worker 还活着（"提醒"一行会给出那个目录，它归那份副本管，去那个目录里 `off.bat`）；或者根本不是"待机"而只是熄屏 —— `ka.bat evidence` 分开这两件事，成因不同。

**心跳会不会干扰我？** 会打扰到你的话，把 `antiLockMethod` 设成 `mouse`（F15 一般没有，鼠标只挪 1 像素且回原位），或者干脆 `antiLock=false` 只用电源请求。

**能远程给别的电脑用吗？** 拷过去就行，它不需要网络。但 `machine.json` 是这台机器的事实，到新机器请重跑 `ka.bat check`。

## 许可

**Apache License 2.0**（全文见 `LICENSE`，版权与归属声明在 `NOTICE`）。选它而不是 MIT，理由具体到条款：

- **可以商用**：闭源售卖、集成进自己的安装包、内部部署都可以，不需要开源衍生版本（Apache-2.0 不是 copyleft，不像 GPL 会传染）。
- **必须履行的只有三件事**：保留 `LICENSE` 和 `NOTICE`；如果你改过文件，在改动处注明"修改过"（第 4(b) 条）；再分发时附上许可证副本。`NOTICE` 里的归属声明必须随分发传递，且**不许**在其中追加你的版权。
- **带专利授权**（第 3 条）：任何人贡献了代码就自动授予专利许可，而他一旦对本项目提起专利侵权诉讼，这份授权即终止。MIT 完全没有这一条 —— 对一个可能被大厂用户装上的系统级工具，这是选 Apache-2.0 的实际原因。
- **不授予商标**（第 6 条）：别人可以拿这份代码去卖，但**不能**把它叫"防休眠 / Keep-Awake"、不能用本项目的名字和图标做宣传。项目的品牌和 IP 留在原创者手里。
- **明示无担保、限制责任**（第 7、8 条）：这是一个会动电源策略的工具，条款里已经把"用它造成的后果自负"写清楚了。

发布前只需要改一处：把 `LICENSE` 末尾附录里的 `Copyright [yyyy] [name of copyright owner]` 和 `NOTICE` 第一行的 `Copyright 2026 The KeepAwake Authors` 换成你自己的名字或 ID —— 真正建立 IP 的是这一行，其余条款不会因为改名而变化。

## 遗留文件（已归档）

v2 之前的旧实现已于 **2026-09-03** 整体移入 `_legacy/`（原样保留，一个没删，随时可整体删除或拷回）：v1 引擎与助手 `keep-awake.ps1`、`manage.ps1`、`control-panel.ps1`、`install-guard.ps1`、`check-machine.ps1`、`fix-lid.ps1`，旧入口 `fix-lid.bat`、`start-keep-awake.bat`、`status-keep-awake.bat`、`stop-keep-awake.bat`、`start-control-panel.bat`、`enable-autostart-guard.bat`、`disable-autostart-guard.bat`，v1 运行产物 `keep-awake.log`、`.keep-awake.pid`，以及一枚当时的探针 `zz-probe2.ps1`。

归档前核过三道门：现行代码对它们零引用（只剩 ka-core 一句"check-machine.ps1 曾经只打印到控制台"的历史注释）；计划任务与 HKCU Run 键里没有指向它们的条目（2026-09-03 扫描，唯一命中是系统任务名里的 CapabilityAccessManager 误含 "manage"）；per-thread 电源请求测试的根目录扫描不下钻子目录，`_legacy/` 天然不在其列。它们仍可在 `_legacy/` 里独立运行（用的是自己那套旧进程发现逻辑），但和 v3 同时开着会互相抢电源请求 —— v1 引擎正是会调 `SetThreadExecutionState` 的那一个。不需要就整目录删掉。
