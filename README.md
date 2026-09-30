# 防休眠 Keep-Awake

一个 Windows 防休眠工具：**不休眠、不熄屏、不锁屏**。给"人不在键盘前，但活还在干"的场面用。

> Windows keep-awake tool: no sleep, no display-off, no auto-lock. Zero dependencies beyond the in-box PowerShell 5.1, no network, portable zip or per-user installer. The rest of this file is Chinese; the tool's own UI speaks 中文 and English.

## 它解决的是哪一种具体的烦

你在挂着 AI 编程、一次编译、一个大文件下载、一个本地模型，或者从外面连着家里的机器。人去做别的事了，半小时后回来：屏幕黑了、机器睡了、远程断了，任务停在半路。

Windows 判断"没人用"的依据只有你多久没动键盘鼠标，它对"后台还有活在跑"一无所知。这个工具做的就是把"现在有活，先别睡"这句话持续地告诉系统，并且在你说了停之后原样收回 —— 不改电源计划、不写注册表、进程退了系统就回到默认行为。

## 适合谁

- 挂长任务的人：agent、编译、下载、跑批、本地推理，人不守在旁边
- **远程无人值守**：机器一睡，任何远程工具都跟着没了 —— 这是本工具最主要的设计目标，重启自恢复和看门狗都是一等为它做的（见《远程无人值守》）
- 笔记本合上盖子还要继续干活（`lid` 子命令，这一步需要管理员）
- 投屏、演示、录屏、视频会议期间不能熄屏
- 想要"不休眠"，但不想要后台服务、不想装运行库、不想注册账号、不想让它联网

**不适合**：指望它让程序熬过一次真睡眠（睡眠会杀掉所有进程，只有"别睡"有用）；macOS / Linux；Windows 7 / 8.1 —— 没测过，别指望（自带 PowerShell 也不是 5.1）；被 WDAC / AppLocker / 智能应用控制锁进 ConstrainedLanguage 的机器 —— 那是唯一一类根本跑不起来的机器，每一个入口脚本（"有哪些入口"是探针从发布清单里发现出来的，不是手写的）都会在加载 `ka-core.ps1` 之前按**代码 2** 干净退出并打印说明，不会静默失败（`tests/probe-clm-gate.ps1` 三条腿实测：`6 entry points gated before ka-core`）。

## 硬事实

| | |
| --- | --- |
| 系统要求 | Windows 10 / 11 + 系统自带的 PowerShell 5.1。没有运行库、没有 .NET 安装、没有后台服务。**实测参照机只有一台**（Windows 11 build 26200，S0 现代待机），Windows 10 与 S3 传统待机机型没测过 —— 差在哪一行一行写在《换一台 Windows 会怎样（适配矩阵）》 |
| 权限 | 普通账户就够。需要管理员的只有两处：可选的改合盖动作 `lid apply`，和 `requests`（`powercfg /requests` 这条命令本身要求） |
| 联网 | 不联网、不上传、不检查更新。下载它不需要账号，用它也不需要登录 |
| 手上有什么 | 两条分发路径：便携 zip（25 个文件，解压双击就跑；这个数由清单从仓库树推导，不是文档里手抄的）或每用户 `setup.exe` + `SHA256SUMS`。CI 每轮把两个都真构建出来：zip 那条由 `-Smoke` 当场解开、从临时数据根真跑一遍；`setup.exe` 那条更严——装上、用装好的那份起一次真保护、再真卸载（见《拿到 release 之后》《独立门禁与实测探针》） |
| 怎么控制 | 五个 `.bat` 入口：`on.bat`、`off.bat`、`panel.bat`、`tray.bat`、`ka.bat`（命令行全功能）；面板 `http://127.0.0.1:8791/` 只监听回环地址，不想开浏览器就用托盘图标 |
| 有没有效 | 不猜。读内核电源日志数出最近 N 小时真待机过几次：`ka.bat evidence`（见《有效性是实测的》） |
| 卸载 | 便携包删掉目录就没了；安装版走"已安装的应用"或 `unins000.exe`。配置和日志在 `%LOCALAPPDATA%\KeepAwake`，不跟着程序目录一起消失 |
| 摊开写的地方 | 磁盘上每一个文件、每一个字段：[PRIVACY.md](PRIVACY.md)。面板端口、提权、合成输入、没有代码签名这四件事的威胁模型：[SECURITY.md](SECURITY.md)。每个版本改了什么：[CHANGELOG.md](CHANGELOG.md)。**踩过的坑与调研结论**（平台事实、PowerShell 陷阱、门禁经验，逐条标了怎么得来的）：[PITFALLS.md](PITFALLS.md)。**设计**（模块边界与不变量、每条决策被否掉的替代方案）：[docs/DESIGN.md](docs/DESIGN.md)；**环境依赖**（三层依赖、工具链版本、每条命令的实测耗时）：[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)；**同类工具调研**（一手来源逐条可核）：[docs/RESEARCH.md](docs/RESEARCH.md)。哪个问题该翻哪一份：[docs/README.md](docs/README.md)
| 许可 | Apache-2.0。可商用、可修改、可闭源集成，自带专利授权；不授予任何商标或本项目名称的使用权（见下文《许可》） |

版本号只有一个真源：`ka-core.ps1` 里的 `$script:KaVersion`（面板页脚、托盘提示、`/api/state` 读的都是它）。本文标题**不带**版本号，因为两份版本号写在一起迟早会互相打脸。

## 30 秒上手

从下载到保护生效，四步：

1. 到 [Releases](https://github.com/faruheaisha/keepawake/releases/latest) 下载 `KeepAwake-<ver>-portable.zip`（想要开始菜单项就下 `setup.exe`）。
2. 可选但建议：核一下 `SHA256SUMS`。一段可以整块粘进 PowerShell 的脚本在《先核对哈希》，三个分支（对、被改过、缺文件）都在本机踩过。
3. 解压到任意目录。含空格和中文的路径实测可用，不需要管理员。
4. 双击 `on.bat`。屏幕不熄、机器不睡、会话不锁，直到你双击 `off.bat`。

双击哪个入口管什么：

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

## 拿到 release 之后（下载、校验、装、第一次跑）

一次 release 是三个文件，都由同一份清单（`tests/ka-release-files.ps1`）产出：

| 文件 | 是什么 | 什么时候选它 |
| --- | --- | --- |
| `KeepAwake-<ver>-portable.zip` | 25 个文件，解压到任意目录就能用 | 拷 U 盘、只给一台机器、不想让任何东西"安装"进系统 |
| `KeepAwake-<ver>-setup.exe` | 同一份清单编出来的**每用户**安装器（Inno Setup 6） | 想要开始菜单项、想在"已安装的应用"里能看到并卸载 |
| `SHA256SUMS` | 上面两个的 SHA-256，`sha256sum` 的文本格式 | 两个都下完之后**先跑它** |

清单只有一份，所以安装器和便携包不可能对"产品到底是哪些文件"各执一词——这正是探针当年各抄一份列表时踩过的坑。

### 先核对哈希

`SHA256SUMS` 每行是 `<64位十六进制><两个空格><文件名>`。把三个文件放在同一个目录里，在那个目录跑：

```powershell
$sums = @{}
foreach ($l in Get-Content .\SHA256SUMS) { if ($l -match '^([0-9a-f]{64})  (.+)$') { $sums[$matches[2].Trim()] = $matches[1] } }
foreach ($f in @(Get-ChildItem -File | Where-Object { $_.Name -ne 'SHA256SUMS' })) {
    $h = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($sums[$f.Name] -eq $h) { 'OK       ' + $f.Name }
    else { 'MISMATCH ' + $f.Name + ' - SHA256SUMS says [' + $sums[$f.Name] + '] the file is [' + $h + ']' }
}
foreach ($n in $sums.Keys) { if (-not (Test-Path -LiteralPath $n)) { 'MISSING  ' + $n + ' - named by SHA256SUMS but not here' } }
```

**2026-09-05 在本机对真产物跑过，2026-09-08 对着重建后的产物重跑过**：对这次构建出的 zip 和 setup.exe 都印 `OK`；把 zip 副本中间一个字节翻掉，它印 `MISMATCH KeepAwake-1.0.0-portable.zip - SHA256SUMS says [...] the file is [...]`；把 `SHA256SUMS` 留着而把那个文件从目录里拿走，它印 `MISSING KeepAwake-1.0.0-setup.exe - named by SHA256SUMS but not here`。两个红分支都亲自踩过，这段粘贴才值钱。

哈希回答的是"这份文件和我发布的那份是否一致"，它**不**回答"这份文件是谁编译的"——后者要代码签名，v1.0 明确没有，理由和后果都写在 [SECURITY.md](SECURITY.md)《没有代码签名》。

### 第一次运行，Windows 大概会先说两句

- **SmartScreen**：未签名的 `setup.exe` 首次运行会弹"Windows 已保护你的电脑 → 仍要运行"，浏览器也可能提示"典型的下载文件 / 不常见"。这一段是**照微软的公开行为写的，不是本机截图**——我们没有把产物传上网再下载回来点它，而弹窗文字取决于微软那边的信誉库，本机复现不出来。
- **下载标记（MOTW）**：从浏览器/IM 存下来的文件带 `Zone.Identifier`。这一半是实测的：带标记的下载和不带标记的那份**输出逐行同形**，内嵌 C# 照样编译（`tests/probe-motw.ps1`，见《独立门禁与实测探针》）。`Expand-Archive` 实测不传播标记。
- **真被策略锁住**：企业机器上的 WDAC / AppLocker / 智能应用控制会让 PowerShell 进入 ConstrainedLanguage。这时每一个入口脚本都会在加载库之前按**代码 2** 干净退出，打印三行说明（zh/en，跟你 Windows 的显示语言走），并且**对本机什么都没做**。这条既不是安装失败也不是崩溃，是刻意设计成看得懂的拒绝（`tests/probe-clm-gate.ps1` 三条腿实测）。

### 便携包：解压，双击

解压到任意目录（`C:\Tools\KeepAwake`、`D:\某处`、桌面都行，含空格和中文的路径实测可用），双击 `on.bat` 或 `panel.bat`，就是《30 秒上手》那一套。没有"安装"这一步，也没有卸载：程序目录里的东西全是文本，删掉目录就没了；你的配置和日志在 `%LOCALAPPDATA%\KeepAwake`，**不会**跟着程序目录一起消失（这是设计，见《东西写在哪儿》）。升级 = 用新的 zip 覆盖同一个目录（数据目录不参与其中，覆盖是安全的）。

### 安装版：`setup.exe`

**先说清楚这一段的分量**：`KeepAwake.iss` 在 2026-09-05 第一次被真编译器编译通过（本机 Inno Setup 6.7.3，`Successful compile (3.454 sec)`），**同一天的晚些时候第一次真的装上了又卸掉**：`packaging/ka-test-install.ps1 -WithWorker` 静默装进 `%TEMP%` 下一个新目录、用装好的那份起一次保护、再跑真卸载器，**一轮 20 条断言全绿**；这个循环本机后来反复跑过，每一遍该绿的都绿到同一句 `PROBE OK`，两个突变（就在本节下面）各红在自己那一条断言上。所以下面这些是跑出来的，不是读出来的。三处仍然只是读出来的，写在最后。

跑出来的事实（每一条都是那 20 条断言之一，命令在上面）：

- 每用户、静默、**全程没有 UAC 弹窗**；装完目录里恰好 = 清单那几个 + Inno 自己的 `unins000.dat` / `unins000.exe`，多一个少一个都算红。这条断言是 `$manifest.Count + 2` 算出来的，不是写死的数字：清单 23 个时它是 25（runner 上 2026-09-26 那轮原话 `expected the 24 manifest files + Inno's own 2, got 25 files` 是突变腿，正股就是 23+2）；清单改成从仓库树推导、变成 24 个之后，这一条就是 26，下一轮 runner 自己重数。
- 装进去的 `.ps1` **不带下载标记（MOTW）**——需要 `Unblock-File` 的是 zip 那条路，不是这条。
- 开始菜单正好那五项：`KeepAwake - Dashboard`、`- Tray`、`- Protect`、`- Release`、`Uninstall KeepAwake`。
- **桌面快捷方式默认是勾上的**（`desktopicon` 任务不用动它就有），指向 Dashboard；它落在 `C:\Users\DELL\OneDrive\Desktop\KeepAwake.lnk`——这台机器的桌面被 OneDrive 重定向了，`{autodesktop}` 认的是重定向后的那个，写死 `{commondesktop}` 反而错。
- `HKCU:\...\Uninstall\{8B7C1F4E-...}_is1`：`DisplayName=KeepAwake`、`DisplayVersion=1.0.0`（跟 `KaVersion` 同源）、`UninstallString` 是**带引号的完整路径**——这一条是"装在含空格的路径里也卸得掉"的证据。
- **安装不注册任何计划任务**（前后对比根任务目录：27 → 27），**也不开任何监听端口**（`[RUN]` 那条 Dashboard 带着 `skipifsilent`，静默装完没人替你开面板）。装好的那份 `ka.ps1 status` 退出码 0，第一行 `== 防休眠 Keep-Awake`。
- 卸载钩子在**第一条 `Deleting file:` 之前**跑完 `stop-server`、`stop`、`unguard`，顺序就是这三个。耗时实测五遍各为 **9.8 / 9.8 / 10.6 / 12.2 / 18.1 秒**（卸载日志里第一条钩子行到最后一条钩子行，脚本每次跑都把这个秒数打在 `info` 行里）——同一台机器上能差到将近一倍，没测过它具体慢在哪一步，也不假装知道。对照：整个卸载器进程从开日志到关日志 27.4 秒，安装侧 Inno 自己那 1.2 秒（两份日志的首末时间戳）。先起了保护再卸载：worker 随钩子一起没了，它攥着的电源请求也一起没了——不留"脚本已删、请求还在"的孤儿。
- 卸载之后四处痕迹一起消失：安装目录、开始菜单那个文件夹、桌面快捷方式、HKCU 那条卸载项。**`%LOCALAPPDATA%\KeepAwake` 原封不动**（逐文件 SHA256 前后一致）：那是"保护在你机器上到底做了什么"的唯一记录，我们不替你删。要彻底干净，手动删，命令在《卸载 / 恢复原状》。
- 钩子那三件事如果全失败，卸载照样完成（被"无法卸载"困住比留一个孤儿任务更糟，日志里留那一行）；这条的边界也实测了一次——把安装目录里的 `ka.ps1` 改名，钩子整段跳过，卸载仍然把该删的删干净了。

代价与防线（**在你机器上跑这件事之前要看**）：`unguard` 删的计划任务名是固定字符串（`ka-core.ps1:2641` 的 `KeepAwake-Guard` / `KeepAwake-Logon`，跟数据根无关），所以卸载测试会把你自己的那两份一起删掉。脚本的做法是**先把每个 KeepAwake 任务导出成 XML**（`Get-ScheduledTask`.Xml 在这台机器上是空的，得走 `Schedule.Service` COM），跑完再按名字补注册缺失的，并且**逐字节比对定义**——这次实测：两份都补回来了、定义与导出完全一致、`State` 仍是 `Disabled`。GitHub 的一次性 runner 上没有可损失的东西，本机上有，所以这份备份不是可选项。

两个突变同样跑过，各自红在自己那条断言上（同一份脚本加 `-SelfTest`，三棵树 2 分 41 秒）：**先把安装目录建出来** → 红在"install directory survived the uninstall"（Inno 只删它自己创建的目录，所以你要是手工建过 `…\Programs\KeepAwake`，卸载后会留一个空壳）；**清单里多算一个文件** → 红在文件数那一条。反过来，未注入的那一棵必须保持绿。

只有三件事仍然是读出来的：

- **带界面的向导一次都没点过**。上面全部走的是 `/VERYSILENT /DIR=...`。`DisableDirPage=auto` 意味着 `DefaultDirName={localappdata}\Programs\KeepAwake` 只是**默认值**（`/DIR` 实测能把它挪到 `%TEMP%` 下含空格的路径），向导会不会、以及长什么样地把这一页摆给用户，没人看过。
- `PrivilegesRequired=lowest` 且不提供"以管理员为所有用户安装"这个选项——这条是 `.iss` 里写死的，也是上面那次不提权安装能过的原因。
- 上面这些是**一台机器**（Win11 26200、中文 UI、OneDrive 重定向桌面）的一次结果。别的机器上唯一可能有实质差别的是桌面重定向和 `PowerShell 5.1` 的版本，而后者面板与状态都会照实报出来。

### 第一次跑什么

```powershell
ka.bat check      # 本机环境适配报告：这台机器能压住什么、压不住什么
ka.bat status     # 保护有没有真的在跑
ka.bat evidence   # 内核电源日志：最近 24 小时真待机过几次
```

`check` 是真机读数，不是"应该没问题"。本机 2026-09-05 的输出（`KA_DATA` 指到一个空的临时数据根跑的，所以没动这台机器真正的数据；整份报告 27 行，下面是**节选**，抄下来的每一行都原样未改）：

```
== 本机环境适配报告
  系统              Microsoft Windows 11 家庭版 中文版 10.0.26200 build 26200
  PowerShell        5.1.26100.9168
  电源              交流电（电池 100%）
  机器类型          笔记本（有电池）
  睡眠状态          S0现代待机=True  S3传统待机=False  休眠=False
  计划熄屏          交流 10 分钟 / 电池 3 分钟
  合盖动作          交流 0 / 电池 0（0=不采取任何操作）
  风险提示:
    - 本机为 S0 现代待机（Modern Standby）：SetThreadExecutionState 可抑制空闲待机，但合盖、电池耗尽或平台策略仍可能强制进入待机。
    - 启用了快速启动/混合睡眠：关机并非完全断电，唤醒行为可能异常。
```

**换新机器第一件事就是重跑 `ka.bat check`**：`machine.json` 记的是**这台机器**的事实，跟着 clone 走会让下一台机器拿着别人的电源计划做判断。

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
dashboard/          index.html + styles.css + app.js + i18n.js + favicon.svg（原生 JS，无框架、无 CDN、无构建；i18n.js 是中英两套词典）
                    这一行以前少写一个文件，而少的正是没人能发现的那类：`favicon.svg` 在仓库里、不在清单里，
                    于是它从来不在 release 里，`index.html` 按名字要它、面板拿到一个 404。现在整个 `dashboard/`
                    递归进清单（清单从树推导，见《独立门禁与实测探针》里 `ka-release-files.ps1` 那一行）
tests/ka-tests.ps1  84 个 It 用例（部分内含用例表；最近一轮 2026-09-26 的 CI 印出 91 条判定行：86 通过 / 5 跳过 / 0 失败），实机跑；CI 每轮在 GitHub 的一次性 runner 上全量跑一遍
tests/ka-encoding.ps1 / ka-syntax.ps1 / ka-privacy.ps1 / ka-privacy-mutation.ps1 / ka-workflow.ps1
                    独立门禁：发出去的每个文本文件各自该有的字节形状（`.ps1` 带 BOM + 纯 LF，
                    `.bat`/`.cmd`/`.iss` 纯 CRLF、零 BOM、零非 ASCII 字节，没有家族的扩展名不许发）、
                    可解析、不外传、"隐私门禁真的会红"、
                    ".github/workflows 里每个 run: 块都能被 PowerShell 5.1 解析，且 YAML 没被 tab 毁掉"
tests/ka-ci.ps1     一条命令跑完上面五个门禁 + 全部探针（CI 和本地用同一个入口，不分叉）
tests/ka-release-files.ps1
                    装了什么，只有一份清单——便携 zip、Inno 的暂存目录、探针拼的"刚下载的目录"、
                    CI 发布的三件套，全都从这一个函数取，不再各自抄一份
tests/probe-*.ps1   22 个实测探针（`ls tests/probe-*.ps1 | wc -l` 当场给的数；HEAD 里那 20 个，加本轮
                    的 `probe-ci-harness` 和 `probe-ci-harness-selftest`）：迁移、互斥体标识、CLM、下载标记(MOTW)、32 位 PowerShell、
                    区域文化、布尔配置、保存默认值、原生编译、全新解压时的数据根、面板句柄按端口分离、
                    托盘的 -SelfTest 到底有没有被谁执行过、字节形状闸门到底会不会红，
                    **外加那四个双击入口里的一行命令到底被 cmd 真跑过一次没有**，以及
                    **CI 那条等待逻辑本身**——干净 / 退出码 5 / 挂死 / 句柄没写 / 留了活口，五种状态
                    各让真 runner 跑一遍，再让它自己报出留下的进程
                    上一行那句"六个『自检』"数的其实是**文件名**（`ls tests/probe-*selftest* | wc -l`
                    现在是 7）：会自己注入缺陷的探针有 10 个（2026-09-29 加了 `probe-procwalk`，它把一份
                    带缺陷的库副本喂给自己），另外两个把自检放在自己文件里、不叫 selftest
                    （`grep -l '\[switch\]\$SelfTest' tests/probe-*.ps1` 回答 `probe-native` 和
                    `probe-bat-entry`；其中 `probe-native` 从 2026-09-28 起普通运行就带那条突变腿）。
                    数没写错，是它数的东西不是大家以为的那个东西
                    顺着这句话查下去查到一个洞：`ka-ci.ps1 -Probes` 是按 glob 跑 `tests/probe-*.ps1`、
                    **每个都不带参数**，所以那 7 个"文件形状"的自检每轮 CI 都跑，而那 2 个藏在
                    `[switch]$SelfTest` 后面的自检**一次也没进过 CI**。这件事在 2026-09-28 收成两个结果：
                    `probe-native` 那条改成**普通运行自己带 `-SelfTest` 起一次子进程并要那个孩子印标记**，
                    于是它每轮 CI 都被执行（代价 5.2 秒，见上表）；`probe-bat-entry` 那条**保持不进 CI**，
                    理由带数字——它本机整条 sweep 实测 8m35s，而 CI 上 "Gates and probes" 已经是这轮
                    21m42s 里最重的一段，加进去等于每次 push 多约 8.5 分钟，而它那 5 个注入缺陷各自该红在
                    哪条断言上已经逐个写在上表那一行里，动这份文件的人照单跑一遍就是。要接也有两条现成的路：
                    加一个 CI step 直接带开关调它（与安装器那步 `-SelfTest` 同一个形状），或把它改造成不带
                    开关的 `probe-bat-entry-selftest.ps1` 让 glob 自己捡到——两条的墙钟代价一样。
                    逐个跑法和本机判定见下方《独立门禁与实测探针》
packaging/build.ps1
                    真正跑过的打包逻辑：按清单出 zip、校验 zip 里每个文件的字节数、
                    解压实跑一遍（-Smoke）、出 staging、出 SHA256SUMS、调 Inno 出 setup.exe
packaging/ka-iscc.ps1
                    找 ISCC.exe 的唯一一份搜索顺序——build.ps1 和 probe-iss 都用它，
                    不然会出现"打包找得到编译器、门禁说没装"
packaging/ka-test-install.ps1
                    真装真卸：静默装 dist 里那个 setup.exe、量它落下的每一个文件、起一次保护、
                    跑真卸载器、再核对机器回到起点（计划任务先导出 XML 后逐字节补回）。
                    -SelfTest 要求两个注入的缺陷各自红在自己那条断言上。build-time only，不进清单
packaging/KeepAwake.iss
                    每用户安装的 Inno 脚本。本机 Inno Setup 6.7.3 **编译通过**（tests/probe-iss.ps1
                    六条断言：两个注入的缺陷必须红、一个编译器抓不到的盲点必须还是绿），
                    它做出来的 setup.exe **也在本机装过又卸掉了**（2026-09-05，
                    packaging/ka-test-install.ps1 一轮 20 条断言）。见《安装版：setup.exe》
.github/workflows/  ci.yml（push/PR）→ build-test.yml（装 Inno + 门禁 + 探针 + 套件 + 打包冒烟 + 真装真卸，可复用）
                    release.yml（打 tag 即出三件套并发布；它 needs: build-test，所以安装那一步也是发布的前置）
README.md / SECURITY.md / PRIVACY.md / CHANGELOG.md / PITFALLS.md / LICENSE (Apache-2.0) / NOTICE
```

进程之间不靠 PID 文件通信：

- **谁是活的**：`Get-Process` + 命令行里的 `-DataDir`（归属判定的主键）；worker 没报告数据根时才退回脚本路径匹配，另有面板句柄 `.server-<端口>.json` 记录的 pid/root 兜底——**按端口一份**，因为一个 TCP 端口只可能被一个活监听者占着，按端口就是按面板；旧的共享 `.server.json` 仍然**读**（改版前起来的面板还得找得回来），只在它的进程确实没了之后才被扫掉。**句柄不是无条件信的**：`startedEpoch` 和进程创建时间对不上（>900 秒）就当它是回收来的 pid，不许据此去杀进程。**2026-09-04 实测**：两个面板各写各的句柄，停掉其中一个，另一个的句柄还在、还能单独被找回来。**这一步刻意朝"是我的"失败**（`Test-KaOwnWorker`）：一个认不出归属的 worker 也算进来，因为"扫到一个都没有"在每个界面上都被读成"保护已停止"，那个误判比多算一个进程贵得多。
- **单实例**：`Local\KA-{Worker|Guard|Tray}-<sha256(数据根 | 用户SID)[0..12]>`。锁的是**数据根 + 谁在用**，不是安装目录——一份 `state.json`、一份 `stop.flag` 天然只属于一个 worker。**2026-09-04 实测**：两个不同的程序目录解析出同一个 `Local\KA-Worker-DCA86D0FFFB8`，另一个进程持有它时 `OpenExisting` 当场可见。所以同一用户复制两份目录时，第二份会撞上互斥体并退出，而不是留下两份谁也停不掉的电源请求；带上 `KA_DATA` 指向另一个目录才会拿到另一个哈希（实测改变）。SID 进哈希是为了让多人共用一份安装时互不排队。
- **状态真相**：`state.json` 是 worker 写的自述，但 `status` 只把它当成"锦上添花"——`Get-KaFullState` 里的 `$live` 判定要求真实进程存在才成立。
- **想不想要保护**：`intent.json`。这是看门狗的唯一依据 —— 你 `stop` 了，它就不会在 10 分钟后自作主张把你刚关掉的保护又开起来（上一版就是这么惹恼用户的）。定时运行到期会被判定为 `expired`，不算"该保护却没保护"。
- **写文件**：一律 write-then-move，读方永远看不到半截 JSON。

这一节的规则是**共识**；把它们逐条写成可检查的条目（谁负责、谁**不许**做、违反了会怎样、当初否掉的替代
方案是什么）在 [docs/DESIGN.md](docs/DESIGN.md)。改动模块边界之前先读那一份——它存在的理由就是让人不必
从这些段叙述里重新推导。

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
- **日志和 `state.json` 不受语言影响**：`PULSE`、`HEARTBEAT`、`EXIT`、`settes-zero:initial`、`note=lock-screen`、`note=battery-floor`、`note=il-mismatch`、`PULSE-SKIP reason=il-mismatch`、`PULSE-SKIP reason=lock-screen`、待机原因标记 `screen-off` / `idle` / `lid`、失败代码 `err=CimException#0x80131500#HRESULT 0x8004100e,GetCimInstanceCommand`（异常类型 # HRESULT # Win32 码 # cmdlet 错误 id，这几样 Windows 自己都不翻译）这些标记是机器读的，永远是 ASCII。面板的波形、`evidence` 的统计、测试断言都靠它们；显示时再经词典换成句子。所以换语言**不改变任何行为，只改变措辞**，也意味着 worker 更新不会把一句新话术硬塞进每种界面里。
- `language` 在读写两端规则不同，是有意的：**写入端拒绝**（`ka.bat config -Set language=de` 与面板上点一个非法值都会报错，且不落盘），因为你刚打错的那个字符应该当场知道；**读取端宽容**（config.json 是手改的、从别的机器同步来的、上个版本写的，任何一种都不能让工具起不来，只能回落默认）。
- 当前覆盖范围：**全部界面中英全量** —— 面板 `dashboard/i18n.js` 两套词典各 470 个键（zh 与 en 键集相同，条数用 `awk` 数两个块的键行得到）；命令行 `status` / `report` / `check` / `start` / `stop` / `config` / `guard` / `serve` 等全部输出、托盘菜单与气泡、`ka.bat lid` 的合盖文案、看门狗与面板进程的控制台行，统一走服务端 zh/en 词典（各 372 键，数是 `ka-core.ps1` 加载后 `$script:KaUi.zh.Count` 读出来的，不是数行数猜的；缺键、占位符对不上、英文值里混进中文，测试直接失败）。两条兜底测试把成品抓在手里：把 `/api/state`（面板每 2 秒轮询的那个负载）按英文渲染后逐字符串叶子查汉字，以及真实跑一遍 `ka.ps1 status` 的英文输出逐行查汉字（两处都放行路径——项目目录名本身就是中文，而路径是你的数据不是我们的话术）。唯一的例外：`ka-guard-missing-core.txt` 那一行天生双语，因为它写下的前提是 `ka-core.ps1` 已经丢了、词典跟着一起丢了。
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
- **不想让它弹浏览器**：`serve`（也就是 `panel.bat`）的最后一步是把地址交给默认浏览器。设 `$env:KA_NO_BROWSER = '1'` 就跳过这一步：服务照样起、`面板地址：…` 照样打印，只是不再说「首次启动，正在打开浏览器…」（一句它并不打算做的事），改说「请手动打开：…」，浏览器由你自己开。布尔的认法与配置项同一套（`1` / `true` / `yes` 之类，`Get-KaBool`）。它主要是给自动化用的：`tests/probe-bat-entry.ps1` 会真的用 cmd 执行 `panel.bat`，在一台本来没开浏览器的机器上（CI runner 就是这种机器），那个标签页是探针自己进程树的真后代，被它的"不许留活口"检查抓个正着（CI run 36256845636：`left 8 descendant(s) alive: 1052:msedge.exe, …`）。本机测不出区别——两个分支都没留下新进程，因为浏览器早就开着；它是由 runner 的留口检查证明的：没修的那一版（`ef62ad1`）在 CI 上红在 `left 8 descendant(s) alive: 1052:msedge.exe, …`，修完这一版（`8a28f0b`，run `36437907563`）同一份 job 日志里 `msedge` 出现 **0 次**、整步绿。
- **两个数据根共用一个解压目录**：面板归属按**数据目录**认，不按程序目录认。同一份程序、两个 `KA_DATA`，就是两套独立的面板：`ka.bat stop-server` 只关自己那一套，绝不跨过去关别人的；`serve` 如果发现端口上已有面板在应答而那不是它的面板，就直说「没有找到我们能停下的面板，但端口 … 仍在应答」，既不接管也不驱逐。停机请求只发给**有凭据的端口**（那块数据目录里的句柄文件写了端口，或那个进程的命令行带了 `-Port`）——猜一个"我本来会用的端口"是上一版把关停请求递给别的数据根的面板的途径，本机实测到过一次：`ka.log` 2026-09-27 01:12:47 `SERVER EXIT pid=28208`，一个临时探针目录的 `stop-server` 把真在跑的面板礼貌地关掉了。现在这套行为由 `tests/probe-server-hint.ps1` 的第 6–9 条钉住，其反向由 `probe-server-hint-selftest.ps1` 的四种突变各自跑红。
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

84 个 `It` 用例（部分内含用例表；最近一轮 2026-09-26 的全量 CI 印出 91 条判定行：86 通过 / 5 跳过 / 0 失败），跑真机、真电源 API、真事件日志、真计划任务，不是 mock：

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

当前状态：**静态 84 个 `It` 用例（部分内含用例表），最后一次全量实机运行是 2026-09-26 的 CI（run 36225438637，sha `90438c3`）——套件自己印出 91 条判定行：通过 86，失败 0，跳过 5**。那次跑在 GitHub 的一次性 Windows runner 上（这就是本套件的既定跑法：不动任何人的真机器），5 条跳过全部署名机器形态：这台机器没有登记看门狗任务（`detail` 在两种语言下都只能为空，缓存文案无从比较）、虚机固件能力位与 `powercfg /a` 文本各说各话、近 14 天没有 506 低功耗会话事件（两条：真实日志无从验证、`Max=5` 撞不到预算）、全新数据根的 `ka.log` 里没有 `STARTED` 行。**每一条"跳过"都说得出"为什么这台机器验不了"，验得了的机器上牙齿原样保留**；换台真笔记本跑，它们会重新变红或变绿，而不是永远绿。
第 6 条跳过不在这份名单里，它是当天查出来的另一个东西：**它排在跳过明细的第一行，用例名就是那第 84 条 `It`（"面板切了语言，活着的那个进程要能知道"），理由是 `KA_LANG` 压过 config——而 `KA_LANG` 正是这个套件在自己文件顶上钉死的**（`tests/ka-tests.ps1:57`，为了让那些比对中文原文的断言在英文机器上也不误红）。也就是说那条 `if ($env:KA_LANG) { Skip }` 在任何一台机器上都恒真，这条用例从来没执行过一次，CI 绿的是"它跳过了"这件事。一条长得和其他机器形态跳过一模一样的红字，就是洞藏身的地方。已改成**用例体内临时清掉再放回**（`try`/`finally` 各自复原文件、缓存与那个环境变量），并补三条断言钉住反面：`KA_LANG` 设着的时候一次 config 写入**不得**盖过它——这正是 `Set-KaConfig` 里那句 push 用 `-Configured` 而不是 `-Explicit` 的理由。改完量了六条腿（`_tmp/check-language-it.ps1`，只抽取 `It` 正文在独立子进程里跑，从不执行 `tests/ka-tests.ps1`；连跑两遍逐字节一致）：新正文在干净代码上**真的求值了 8 条断言**（不是"绿了"，是数出来的），旧正文在同一份代码上**求值 0 条并喊 skip**（把洞量化成一行数字），三个突变体各自点名不同的那一条——去掉写方的 push 死在第 2 条、把 push 改成 `-Explicit` 只死在最后一条（前面 7 条全绿，说明这条新断言是唯一防线）、让缓存自己失效死在第 4 条，另外 `1992a64^` 那份 ka-core 必须红。`grep -c "It '"` 的 84 是静态用例数，与判定行数不是一回事——这条规矩对它自己同样成立：引用哪次运行，就说哪次运行的数。上面那 86 属于 `90438c3` 那一轮（run 36225438637），也就是**修完之后**连续两次 CI 的第二次：`f5b7960` 与 `90438c3` 各印一次 86 / 5 / 0，判定行数没动过——第二次的全部改动是把一条躲在 `if ($running)` 里的断言挪到守卫外面，所以它只可能改变"红不红"，改变不了"跑了几条"。这一条在那台 runner 上第一次印出 `PASS`（`gh run view 36224674886 --log` 里搜用例名，那行就在那 5 条 SKIP 之前），跳过名单回到剩下那 5 条机器形态。

### 独立门禁与实测探针

`tests/` 里除了 `ka-tests.ps1` 还有一批**各自独立、几秒到几分钟跑完、不碰这台机器的电源状态**的检查。它们不进套件是刻意的：有的要一份临时 clone，有的要第二个进程真的去抢互斥体，有的要把成品下载伪装成带 Web 标记的文件，有的要**短暂改坏 `ka-core.ps1` 再改回来**——这些都不该塞进一个"在正在工作的机器上随手跑跑看"的套件里。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\ka-encoding.ps1     # 也可 -Apply：补 BOM、把 .bat/.iss 改回 CRLF
powershell -NoProfile -ExecutionPolicy Bypass -File tests\probe-motw.ps1      # 探针同理
powershell -NoProfile -ExecutionPolicy Bypass -File tests\ka-ci.ps1 -Gates -Probes
                                                                             # 一次跑完五道门禁 + 全部探针
                                                                             # （-Suite 是另一个入口，见上）
```

#### 一条腿的"留口"该怎么认（CI runner 的判定规则，2026-09-29 定案）

`ka-ci.ps1` 每跑完一个脚本都要回答"它留下了哪些进程"。这个问题答错的代价是**一整个 CI 周期**——那一步红了
就意味"产品或测试错了"，而 2026-09-28/29 的四次红里两者都是对的。规则现在是：

1. **每腿一个 Windows Job 对象**（`CreateJobObject` + `AssignProcessToJobObject`），事后一次
   `QueryInformationJobObject` 读成员表。精确、与 pid 回收无关、不需要采样；超时路径用 `TerminateJobObject`。
   它**看不见**壳（shell/浏览器交接）起的进程。
2. **重建**（`tests/ka-procwalk.ps1` 的 `Get-LeakedDescendants`）：每 2 秒采一次 `pid→ppid`，从活进程往上爬。
   它**看得见**第 1 条看不见的那类（历史里记着当时那个脚本是它的父亲），但一条条目只对"写下它时持有该 pid
   的那个进程"成立，所以带两条守卫：**跟着走的每一跳都必须在采样里留下过创建时间**（没采样过就停，不猜），
   且**pid 现在活着的话必须还是那个进程**（创建时间对得上）。"留下过创建时间"必须是**真的时间**：CIM 不给
   `CreationDate` 的镜像（runner 上以标准令牌查 `TiWorker.exe`/`svchost.exe` 就是这一类）记下的是 tick 0，
   而 `0` 是个"看着像真值"的哨兵，两条守卫会被它一起绕过（`ContainsKey` 为 true、`0 -ne 0` 为 false）
   ——这正是 run `36679927952` 那次假红。现在只记正数时间，且"活着却读不出时间"**停走**而不是跳过比较。
3. 两者**取并集**，再过滤年龄窗与 `conhost.exe`/`OpenConsole.exe`。并集是刻意的：任一源缺失只会让报告比真相
   小，不会把无关进程平白算进来。`Assign`/`Query` 失败**抛错**，不当红腿。

夹住它的是两条探针：`tests/probe-procwalk.ps1`（两个源各有判定，两条守卫与采样那一行各有一条注入腿能把
自己那条判红，共四条）与 `tests/probe-ci-harness.ps1`（集成那一半：两个**故意**漏进程的夹具必须照样被点名）。
上面表里那两行写着它们各自的历史与实测数字。

| 文件 | 钉住什么 | 最近一次本机实跑末行（多为 2026-09-04；`probe-iss`、`ka-encoding.ps1` 与其自检、`probe-bat-entry.ps1` 09-26；`probe-ci-harness.ps1` 与其自检、`probe-mutex-identity.ps1` 09-27；`probe-procwalk.ps1` 09-29、09-30 补两条用例与两条注入腿；本机那一整步 28 行 0 红，21m14s，2026-09-30） |
| --- | --- | --- |
| `ka-encoding.ps1` | 按**家族**钉住发出去的每个文本文件的字节形状（2026-09-26 从"只扫三个目录里的 `*.ps1`"改过来）：`.ps1` 要 UTF-8 **带 BOM + 纯 LF**；`.bat`/`.cmd`/`.iss` 要**纯 CRLF、不带 BOM、一个非 ASCII 字节都不许有**——`cmd.exe` 和 ISCC 用系统 ANSI 代码页解码它们，这台机器 ACP 65001 把问题藏住，默认 zh-CN 安装是 936，那里一个 BOM 会让首行打印成 `ÿþ`、一个汉字到达时已经是乱码；`dashboard/**` 和 `*.md` 只报不断（浏览器和人读它们，形状不是它们的契约）；**落不进任何家族却出现在清单里的扩展名直接判失败**。扫的文件集合也是查出来的：发布清单 ∪ `tests/*.ps1` ∪ `packaging/*.ps1` ∪ `packaging/*.iss`。**写这条规则的当天它就不绿**：`git ls-files --eol` 对着 `.gitattributes` 那句"给 .iss 一定吃得下的 CRLF"回答 `i/lf w/lf attr=text eol=crlf packaging/KeepAwake.iss`——磁盘上是 154 个裸 LF，而 `git status` 看着干净（`eol=crlf` 只在检出时改写，事后由工具写入的字节没人管，而 `git diff --numstat` 对这一处一个字都不吐） | `every shipped text file carries the byte shape its family requires` |
| `ka-syntax.ps1` | 递归解析每个 `.ps1`，只解析不执行；能看见自己 | `all files parse clean` |
| `ka-privacy.ps1` | 成品里没有任何非回环 URL、没有未登记的联网能力、监听前缀全在回环、**面板写过的每一个响应头名字都在册**、**每一行交给 Windows shell 的地方都按文件数着点名**。规则 1/2/4/5 扫的都是**通道/家族**而不是"想得到的名字清单"（2026-09-26 实测出三个洞：① 往 `ka-worker.ps1` 副本里塞 `System.Net.Sockets.Socket` 连接 + 拼出来的主机名，旧那份闸门**照样 exit=0**——清单里没有一个名字匹配，规则 1 又看不见由片段拼出的目的地；② 往 `ka-server.ps1` 副本里塞 `'Access-' + 'Control-Allow-Origin'` 拼出的 CORS 头、或一个从没人想到的 `X-Ka-Machine` 头，旧规则 4 只认 `Access-Control` 那一个字串，同样 exit=0；③ `Start-Process 'telemetry.example.com/collect'`——把远端主机交给 Windows shell，浏览器自己会补上 `http://`，这条既没有网络 API 名（规则 2）又没有带 scheme 的字面量（规则 1），旧闸门对着同一个副本 `exit=0`；同一类里 `'http://' + 'collector.example' + '.com/submit'`、`'https:/'+'/keystore.example.org/ping'`、`'http://' + $env:KA_COLLECT` 三种拼法旧规则 1 一个字都不报，它的正则要求 `://` 后面至少还有一个字符，恰好放过了以 scheme 结尾的字面量）。改完之后这些副本分别 `exit=1`，finding 都点名 `ka-worker.ps1` / `ka-server.ps1:346` / `ka.ps1:594`）。BCL 的联网类型全在 `System.Net` 下、P-Invoke 必须写出 DLL 名、外部下载器必须出现在参数里，而 `HttpListener` 能设响应头的写法只有 `Headers.Add/Set`、`Headers['…'] =`、`AddHeader` 三种，能把手边一个参数交给 shell 的写法同样是封闭集（`Start-Process`、`Invoke-Item`、`UseShellExecute`、`WScript.Shell`/`Shell.Application`、`cmd /c start`、`explorer.exe`，加安装器的 `openurl`/`shellexec`）——**写法是封闭集，所以枚举写法是发现，点名坏名字是清单**。规则 5 因此不猜字符串长什么样，只按文件数行：实测 6 个文件 10 处（`ka.ps1` 2、`ka-core.ps1` 2、`ka-tray.ps1` 1、`ka-lid.ps1` 1、`build.ps1` 2、`ka-test-install.ps1` 2），多一处就要求在这里说清它开的是什么；注释和 `<# #>` 里的不算代码路径，否则文档一改这个数就动。读请求头（`$req.Headers['Host']`）不算设响应头；名字读不出来的那种写法按最坏情况报，不静默跳过。**还有一处仍然拦不住，写在规则 5 的注释里而不是藏起来**：已经在册的那 10 处如果只把**参数**换成一个无 scheme 的裸远端主机，行数不变、字面量也没有 scheme 可读，只能靠"面板 URL 是 `ka-core.ps1` 唯一一个回环字面量拼出来的"间接兜住。**扫的是哪些文件也是查出来的**：顶层 `.ps1`/`.bat` + `dashboard/**` + `packaging/**`（2026-09-26 把安装器加进来——它比这些代码先跑，它不是文档；当天 `packaging/` 四个文件里 `http` 出现 0 次，所以这条关的是门、不是已经有人走过去的洞，但"我们扫安装器"这句话要有一条注入替它作证，见下一行） | `PRIVACY GATE OK: ...` |
| `ka-privacy-mutation.ps1` | 上面五条**真的会红**：先跑一遍**未注入**的副本要求它过（不过就说明某条规则太宽，抓的不是缺陷），再一条缺陷一次运行地注入，要求每次 `exit=1`、说出该说的那句、并且**所有 finding 都指向这条腿改的那个文件**（指向别处就是搭了别的注入的便车）。十四条里八条是"拼出来的/没想到的"那类：拼出来的主机名 ×2、拼出来的响应头、一个陌生的响应头、拼出来的整条 URL、跨斜杠切开的 scheme、scheme 后面接变量的目的地、一个只交给 shell 的裸远端主机；第九条往 `packaging\KeepAwake.iss` 里塞一条 `[Run]` 升级检查，专门用来证明扫描真的够得着安装器（旧那份闸门对着同一个副本 `exit=0`）。第十条量的是**规则之间的接力**：规则 3 按文件名只读 `ka-server.ps1`，那就往 `ka-worker.ps1` 里放一个 `HttpListener` + `Prefixes.Add("http://+:…")`，实测三条 finding 全由规则 1 与规则 2 出、规则 3 一言不发——"监听器出现在别的文件也会有人拦"这句以前只是注释里的推理。末尾四条（新加的）各**只**出 1 条 finding，前三条注在 `ka-worker.ps1` 的普通赋值行——那里没有任何 shell 写法，规则 5 保持沉默，所以"这条腿量的就是规则 1"是数出来的而不是声明的；最后一条反过来，只有规则 5 开口 | `MUTATION CHECK OK: all 14 defects each red on their own rule, and the clean copy green` |
| `ka-workflow.ps1` | `.github/workflows/*.yml` 里每个 `run:` 块都能被 PowerShell 5.1 **解析**，且 YAML 缩进里没有 tab（Actions 会整个文件拒绝）。它抓不到的是 Actions 自己的求值器——那一层只有真跑 CI 才知道 | `every run: block parses as PowerShell 5.1 and no YAML indentation tabs were found` |
| `ka-release-files.ps1` | **装了什么，只有一份清单**：便携 zip、Inno 暂存目录、探针的"刚下载目录"、CI 的发布校验都从它取。**代码半边现在是推导出来的**（2026-09-26）：仓库根 `*.ps1` + 根 `*.bat` + 根 `*.cmd` + `dashboard/**` 递归，文档那 6 份仍手写（往根目录扔一个新 `.md` 不等于多了个程序）。以前是 17 个手敲的代码文件名，而手敲的清单只会以一种方式坏：文件在仓库里、不在清单里，于是它**就是不在 release 里**，而 zip↔清单的双向校验全绿（`build.ps1` 多了要 throw、少了也要 throw，两边都只对"清单说了什么"负责）。推导出来第一眼就是 24 ≠ 23：多出的那一个 `dashboard\favicon.svg` 从 v1.0.0 起就没进过 release——发布那份 zip 实测 23 个条目、里面没有任何 `favicon`，而 `index.html:10` 按名字要它、`ka-server.ps1:336` 找不到就回 404。守卫：推导结果里若缺 `ka.ps1`/`ka-core.ps1`/`ka-gate.ps1`/`ka-server.ps1`/`ka-worker.ps1`/五个 `.bat` 中任何一个就 throw（"扫不到东西"长得像通过，比一份清单更坏），dashboard 文件少于 4 个也 throw。**同日补上第二半：推导当时还是三个 glob，而 glob 就是一份穿了"发现"外衣的扩展名清单**——根目录放一个 `run.cmd` 或 `notes.txt`，三个 glob 一个都不匹配，它于是安安静静进了"不在 release 里"那一堆，和 favicon 同一个病、往上一层。现在要求**每个根目录文件都被某条规则认领**（三个 glob / 六份点名文档 / `.gitignore`+`.gitattributes` 这两份仓库管道），没被认领的 throw 并点名它；"哪些是本机运行产物"不抄第二份名单，去问 `git check-ignore`（`.gitignore` 里已经写着理由）。`.cmd` 顺手进 glob：`.gitattributes` 和字节闸门早就把它当程序，只有清单没当 | `-File` 直接跑会打印清单；`probe-build-selftest.ps1` 的 `extrafile` 腿替"没被任何清单点名的根目录脚本照样进 zip"作证，`strayfile` 腿替"没被认领的根目录文件挡住构建"作证，`strayoutside` 是它的对照（同一个文件放进 `tests/` 必须照旧绿） |
| `probe-native.ps1` | 从 `ka-core.ps1` 里按 AST 抠出内嵌 C#，用同一个 csc 真编译，并核对产品调用的 15 个成员都在。**它的突变腿现在每次普通运行都会跑**（2026-09-28）：一次普通运行在绿完之后会自己带 `-SelfTest` 起一个子进程，要求那个孩子印出 `PROBE OK (self-test):`——那条腿只改内存里编译出来的副本、把产品调用的某个 public 成员改个名，要求覆盖检查**点名**它（本机实测 `renaming GetPowerCapabilitiesRaw is caught: [Ka.Native]::GetPowerCapabilitiesRaw is called by the product but does not exist on the compiled type`）。在此之前这条腿只藏在开关后面，而 `ka-ci` 跑所有 glob 到的探针时都不带参数，所以那次破坏性编译**在任何自动化里都没执行过**——上一行那个绿等于没说它会不会红。代价近乎为零：本机整条 5.2 秒（原 5 秒），CI 上 `ok probe-native.ps1 5s`。判据吃孩子自己印的标记而不是退出码：非等待式 `Start-Process` 对象**还在跑**的时候读 `ExitCode` 是静默 `$null`，而这条腿的启动带 `-NoNewWindow` 加一条重定向，孩子退出后读**也还是** `$null`（2026-09-30 第二次更正：`$null` 由**启动开关**决定、不是读位——09-28 那句对**它自己的形状**本来是对的，错在把它当成了通则；`_tmp/exitcode-switch-matrix-20260930.txt` T2/T4） | `... compiles, exposes all 15 members the product calls, and answers when run` + `the embedded C# compiles and covers every member the product calls, and renaming one of them in a compiled copy is caught by name` |
| `probe-culture.ps1` / `-mutation.ps1` | 7 种区域设置下机器可读通道不变味（小数点、佛历、数字替换）；再把三处修复改回旧写法要求它变红 | `machine-readable output holds across 7 cultures` / `all 4 assertions are red on the reverted code and green on the shipped one` |
| `probe-clm-gate.ps1` | CLM 闸门的三条腿：静态接线、真降级后按代码 2 干净拒绝、去掉闸门必须炸在 `Add-Type` 上。**"有几个入口"不再由探针手写**（2026-09-26）：入口集合 = 发布清单 ∩ "可执行行上真的 dot-source `ka-core.ps1`"（`ka-gate.ps1` 只在注释里提到那个名字，自己就落在集合外），清单空了会大声失败而不是回报"0 个入口都接好了"；发现出来 yet 没有对应 CLM 用例的入口同样算红。四条翻转实测：`baseline exit=0`（发现 6 个、6 个有用例）、塞一个没接闸门的 `ka-extra.ps1`→`FAIL ka-extra.ps1 ... no gate dot-source, no exit-2 call, reaches ka-core but no CLM case runs it`、塞一个接了闸门但没用例的→只报后一条、把清单缩到只剩两个库文件→`PROBE FAILED - no shipped script dot-sources ka-core.ps1` | `9 cases green now, 7 red without the gate, 6 entry points gated before ka-core` |
| `probe-tray-selftest.ps1` | **`ka-tray.ps1 -SelfTest` 那个主体有没有人真的跑过**（2026-09-26 查出来：CI 上唯一调它的是 `probe-clm-gate` 的 `tray/clm` 那条腿，而那条腿断的是闸门拒绝——`exit 2` 发生在 `-SelfTest` 主体（`ka-tray.ps1:411`）之前，所以主体一次也没执行过；同位置的 `ka-server.ps1 -SelfTest` 有套件那条 `It` 接着，托盘什么都没有）。**这条声明现在过时了**：run `36227348476`（sha `74db958`）在 runner 上真起了托盘进程，印 `ok   clean        exit=0 lines=7 (3.3s) presetDur en="30 min" zh="30 分钟"`、整轮 `----- 23 run, 0 red`——无头的 GitHub runner 上 `NotifyIcon` 照样建得起来。本机六条腿、约 70 秒（runner 上 25 秒）：先把"退出 0 却什么都没验"的形状钉成一条腿——`KA_LANG` 设着跑同一个入口，主体印 `SELFTEST lang=skip`、再印 `SELFTEST OK`、**照样 exit 0**（实测，不是设想），所以干净那条腿断的不是"OK 与退出码"而是两种语言各自真的渲染过（`presetDur en="30 min" zh="30 分钟"`）且菜单结构在（`durations=5 intervals=4`）；③ **点击交接**（AST，一条进程都不起）——这个仓库里没有任何自动检查真的按过一次托盘菜单：真点一下会起 worker、注册计划任务，落在谁的机器上都不该，而"预设的分钟数离开菜单、进引擎"恰好是本探针要防的单位串线那一类，所以规则写在语法层：恰好一个时长处理器把 `$this.Tag` 交给 `-Minutes`、恰好一个间隔处理器把它写进 `antiLockIntervalSec`，且 `$this.Tag` 与引擎调用之间**不许出现任何算术**（`* 60` 与 `/ 60` 是同一个病换了个符号），五条只在内存里做的破坏各要红在点名自己那一条上、干净那棵树必须一条都点不出来（哪些处理器读了 `$this.Tag` 是从语法树上**发现**的、不是照这份清单点名的：多出一个没人认识的第三个交接会被点名，重复一个也会——`ka-lid` 当年就是漏在写死的清单外）；④-⑥ 三个突变体各红在自己的那条守卫上，同一棵树把注入关掉必须回绿。**谁红在哪条上是量出来的不是推的**：`frozen`（解析出新语言却不改菜单）原本按"该红在语言同文那条"写判据，harness 直接回 `died somewhere else`——文案保真更强，先把它抓走了；于是 `frozen`（菜单停在旧语言）与 `unit`（拿秒格式器去贴分单位的 Tag，就是当年那个 `30 分钟` 显示成 `30 秒`）同归文案保真管，就额外要求**这两条红字不许相同**（相同就说明其中一个在搭另一个的便车）；`nolang`（根本不重新读 config.json，标签和期望一起漂，文案保真看不见它）才归"两种语言不许同文"那条后备管 | `the tray self test body runs here for real - 1 skip shape pinned, 3 mutations each red on their own guard and green with the injection switched off` |
| `probe-motw.ps1` / `-selftest.ps1` | 带 Zone.Identifier 的下载与不带的那份**输出逐行同形**，内嵌 C# 照样编译；`Expand-Archive` 实测不传播标记；自测用 CLM 注入一次真实阻塞证明它会红。那句 `24 files` 是从清单数出来的，清单从 23 变 24 的那一轮本机原话跟着变成 `a Zone-3 download of 24 files behaves exactly like an unmarked one, native layer compiles either way (exit=0)` | `a Zone-3 download of 25 files behaves exactly like an unmarked one, native layer compiles either way (exit=0)` / `catches a blocked native build on the marked leg and stays green when nothing is blocked`（末行随 `PITFALLS.md` 进清单从 24 变 25，2026-09-29 本机重跑 53s 实得） |
| `probe-wow64.ps1` / `-selftest.ps1` | 32 位与 64 位 PowerShell 的逐项差分（37 项）；自测注入一个假的 32 位分歧，要求差分点名它、注入关掉必须回到绿。**2026-09-05 记录一次没查清的红**：整套扫描里 32 位那腿的 `ka.ps1 check` 回了 2、64 位回 0，而它前面和后面各跑一次都是绿的——当时**没法知道它为什么红**，因为子进程说的话只存在于两行之后就被删掉的临时文件里。所以现在失败的那一行会把子进程的原话带出来（`KA_DIAG_*`，刻意不参与差分，内容里全是路径和时间）。这条红的原因仍然未知，下次再出现就有证据了 | `32-bit and 64-bit PowerShell give 37 identical answers...` |
| `probe-migrate.ps1` | 首次迁移：只填空缺、**永不覆盖**数据目录已有的文件。搬进临时程序目录的那份文件清单现在是**推导**出来的（2026-09-26）：`tests/ka-release-files.ps1` 里所有 `*.ps1` 加 `dashboard\*`——`tests/` 里最后一份手写文件清单就是这里，而它抄的那份清单自己记过两次"两份同一个东西的清单漂移过"。清单为空/只剩库文件会大声失败（`the derived program list is not a program directory`），清单指到仓库里没有的文件也会失败（`source tree is missing ... lists a file the repository does not have`）。四次翻转实测：给清单加一个仓库里存在的文件→`DERIVED 13 ... COPIED 13` 仍绿，加一个不存在的→非零退出并点名它，把清单缩到只剩文档→非零退出报"这不是一个程序目录" | `migration brings an old install forward without ever replacing a file the data root already has` |
| `probe-config-value.ps1` | 布尔词表：`"false"`/`"off"`/`"否"` 是假，词表外的值被拒绝且不落盘 | `a hand-edited config.json means what the person who edited it wrote` |
| `probe-fresh-data.ps1` | 按 zip 清单拼一份"刚下载的目录" + 空数据根，看首条命令到底写了什么、只读命令一个文件都不许多写 | `a fresh download runs, writes only what it is told to, survives a hand-mangled config.json, and shows one version` |
| `probe-save-default.ps1` | 面板「存为默认」走真 HTTP、真进程、真文件：存它所显示的，拒它不能兑现的 | `存为默认 over HTTP stores what the form showed, and refuses what it cannot honour` |
| `probe-mutex-identity.ps1` | 单实例互斥体锁的是**数据根 + SID**，不是安装目录；跨进程真的抢得到。**"抢得到"这一条现在有两条路由，由实测选**（2026-09-27）：先问"这个名字此刻被别人持有吗"——`OpenExisting` 只证明名字存在，`WaitOne(0)` 拿到 False 才证明别的进程正持有它；持有就改用更强的证据（本机正在防休眠的那个 worker 自己就是那个"另一个进程"，末行印出它的 pid），并把"起一个 job 去当第一个拿的人"那条控制**明写着 SKIP**——以前它在正在用的机器上必然红（实测 2026-09-25，且从 `git archive HEAD` 的干净副本复现过同样的红），而那句话说的是产品坏了、其实是机器。没有持有者就照旧走 job 那条控制，那条路 CI 每天都在走；**本轮没有把这条改动推上 runner 重测**，所以新末行只在"本机有活着的 worker"这一支上是实测。取到手立刻释放：`ka-worker.ps1:70` 只在启动时拿一次、之后从不重新申请，所以短暂的第二个申请人动不了用户正在跑的保护 | `PROBE OK: the mutex keys on data root + SID, not on the install folder (contention observed against live worker pid 21688)`（本机 `_tmp/mutex-livewholder1.log`；括号里换成交互的对方，所以那句"抢得到"在两种机器上读起来是同一件事） |
| `probe-server-hint.ps1` / `-selftest.ps1` | 两个真面板两个真端口，九条腿（2026-09-28 由五条扩成九条）：①句柄**按端口**各一份、②停掉一个不许把另一个变成孤儿、③什么都停了就不许留句柄、④旧版共享 `.server.json` 仍会被扫掉、⑤端口还在应答就不许说"面板没有在运行"；**⑥–⑨ 是归属**：两个数据根共用同一个程序目录时（`KA_DATA` 一改就是这种形状）——⑥ `Get-KaServer` 要**看得见但拒收**（`ours=False`）且 `stop-server` 不许跨过去停它、⑦ `serve` 要回"端口已被占"而不是接管或驱逐、⑧ 对照：它自己的数据根仍然停得掉它（否则⑥⑦是空的）、⑨ 一个我们自己的面板若**端口无从得知**（句柄不在了、命令行也没有 `-Port`），停机不许退回去猜"我本来会用的端口"——猜的那一版会把关停请求递给正好在听的另一个数据根的面板。第 6 条的措辞里记着真事：`ka.log` 2026-09-27 01:12:47 `SERVER EXIT pid=28208`，用户自己的面板照办了一个只改了 `KA_DATA` 的临时脚本。自测把修复前的**六**种写法各退回一种，每种必须红在自己的断言上、未注入的那棵必须绿：`shared`（共享句柄+退出即删）、`blind`（不探端口）、以及归属那四种——`claim`（按程序目录认领，就是事故本体）、`stopfilter`/`startfilter`（`Ours` 算对了但调用点不用它）、`portfallback`（拿配置端口当凭据）。**每个临时数据根都写自己的 `config.json`**：`Stop-KaServer` 总会探 `[int]$cfg.port`（`ka-core.ps1:2699`），没写就退回内置 8791，而 8791 正是这台机器上真面板的端口——`portfallback` 臂下那不只是 ping，是一次真 POST。代价与形状：**每条臂跑一遍完整九腿**。实测两批四条：`-Only shared,blind,claim` 296.5 秒、`-Only stopfilter,startfilter,portfallback` 293.4 秒（`_tmp/hint-sweep-batch1b.log`、`_tmp/hint-sweep-batch2.log`，每臂约 74 秒）；**CI 的裸跑形状（六臂 + 对照，七次）本机实测 435 秒**，就在整轮 `-Gates -Probes` 的 transcript 里（`_tmp/ci-gates-probes-run3.log`：`ok probe-server-hint-selftest.ps1 435s`，同一轮里 `ok probe-server-hint.ps1 76s`，整轮 `----- 27 run, 0 red`、26m38s）——比每臂 74 秒的算术更小。这与已在 CI 里的 `probe-bat-entry-selftest.ps1`（515 秒）同级、都在 `ka-ci.ps1` 每脚本 600 秒的线下；**runner 上的真数字**（run `36437907563`，job `108980501614`，整 job 21m42s）：`ok probe-server-hint.ps1 50s`、`ok probe-server-hint-selftest.ps1 392s`，比本机还快一点。`-Only a,b` 是给人单独重跑一条臂用的（CI 不带参数，永远跑满六条）。**这条探针自己挂死过一回**：`Invoke-Child` 原先用 `-Wait`，而 .NET 的 `WaitForExit()` 要等被重定向的 stdout 管道到 EOF，`claim` 臂下第 7 条腿的 `serve` 会**真的起一个面板**、那个孙进程继承了写端，于是 EOF 永远不来——实测卡了九分钟（`_tmp/probe-server-hint-mutant.ps1` pid 6944，暂存面板 55196/55141 仍活着），和 `ka-ci.ps1` 那次 `-Wait` 挂死（#65）是同一个病；现在改成 `HasExited` 轮询到 90 秒，超时写成 `CHILD_TIMEOUT after 90s: <args>` 让断言变红而不是静默卡住 | `PROBE OK: two panels hold two handles, a foreign root's panel is never stopped or adopted by us, an unreadable port is never guessed, and a port that answers is never called "not running"` / `PROBE OK: 6 reverted guard(s) each turned this probe red on their own assertion (shared, blind, claim, stopfilter, startfilter, portfallback), and the untouched mutant stays green` |
| `probe-build-selftest.ps1` | 打包冒烟闸门 `build.ps1 -Smoke` **真的会红**：在 `_tmp` 里按清单搭七棵一次性树，前三棵分别注入"数据根指回程序目录"、"入口脚本一跑就炸"、"运行时往自己程序目录里写文件"，要求逐个红在自己那条断言上；第四棵 `strayfile` 坏的是**清单的第二半**——往树根放一个 `build-notes.txt`，三个 glob 都不匹配它，要求冒烟红在 `build-notes.txt is at the repository root`（判据吃的是"单数 is"这个语法：多一个没被认领的文件就变成 `a, b are at...`，那条断言当场不成立，所以它同时是"一条腿一个缺陷"的检查）；第五棵 `strayoutside` 是它的对照——同一个文件放进 `tests/`，根目录扫描读不到，必须**照旧绿**，否则上一条断言说的其实是".txt"而不是"没被认领的根"。第六棵 `extrafile` 问的是**反问题**——往树根放一个任何清单都没点名的 `ka-extra.ps1`，要求冒烟**绿**且 zip 里真的有那一条目（清单改成树推导之前，这一腿红给你看：`ka-extra.ps1 is a program file at the repository root and the portable zip does not carry it (23 entries)`）。两棵绿树的 zip 还要逐条目对照，差集必须正好是 `ka-extra.ps1` 一条——这条也是量出来的：在 `_tmp` 的副本里让 `extrafile` 顺手删掉 `dashboard\favicon.svg`，冒烟照样绿、`-notcontains` 照样过，只有逐条目对照开口说 `the extrafile zip also lost something the clean tree carries: dashboard/favicon.svg`（`exit=1`）。没动过的那棵树必须还是绿的。**这条探针自己抓过自己的红**：2026-09-05，把找编译器的逻辑抽成 `packaging/ka-iscc.ps1` 之后 `build.ps1` 加载了树里不存在的文件，四棵树一律红在同一句 `CommandNotFoundException` 上、绿的那棵也不绿了。2026-09-26 又一处：`strayfile` 那条腿在旧清单（没有认领规则）上跑，harness 必须回 `strayfile tree passed the smoke`——真跑了一遍（`_tmp/mutate-claim.ps1`，把认领检查改成 `if ($false -and ...)`）：四条 `FAIL`、`PROBE FAILED: 4 problem(s)`，而那份 transcript 里 `packaging KeepAwake v1.0.0 (24 files...)` 后面跟着 `ok ... 24 entries`，也就是**没被认领的文件正安静地不在 release 里、全绿**；逐字节还原后回绿（sha256 相同） | `each of the four broken artifacts turns the smoke red on its own assertion, a root script that no list names still ships, a root file no rule claims stops the build, and the intact trees stay green`（外加一行 `info portable zip entries: this tree = 24, with one root script no list names = 25`） |
| `probe-encoding-selftest.ps1` | 上面那道字节闸门**真的会红**（2026-09-26）：在 `_tmp` 里按清单复制一整棵一次性树（整棵，不是单个文件——闸门从自己所在的位置算仓库根、再从清单读要扫的那批文件，只复制一个文件的那条腿是在对一个空目录下判断），一条腿只坏一处：`.ps1` 掉 BOM、`.ps1` 被 CRLF 化、`on.bat` 变裸 LF、`ka.bat` 带 BOM、`panel.bat` 里塞进一个汉字、往 `dashboard/` 放一个没有家族的 `evil.py`。每条腿要求 `exit≠0`、finding 点名**这条腿改的那个文件**、说出该说的那句、并且**不许牵到别的文件**（改一处坏两处，说明其中一条断言在搭便车）。没坏的那棵树必须还是绿的，否则六条红什么都证明不了。判据里的"CRLF"和"BOM"要先过滤掉闸门自己的 `info` 行——那些行本来就带着 `CRLF=0`、`BOM=False`，不过滤会把每个仪表盘资源读成第二条罪状。**这条探针是被自己抓出来的**：`Write` 落盘的第一版 `ka-encoding.ps1` 没有 BOM，是新闸门报的 `ka-encoding.ps1  no BOM`；而它的第一次运行先印 `PROBE FAILED: setup` 再印 `PROBE OK` 并 `exit 0` ——一个会在自己崩溃之后宣布通过的 harness，那次崩溃是 `GetBytes((Get-Body $f) -replace 'a','b')` 里裸逗号被当成分隔符、方法收到 2 个参数 | `six broken byte shapes each turn the encoding gate red on the file this leg broke, and the intact copy stays green` |
| `probe-bat-entry.ps1` | **四个双击入口里那一行命令，现在真的被 cmd 执行过了**（2026-09-26；`on/off/panel/tray.bat` 这四个文件名在 `tests/` 里除了本探针只出现在发布清单和字节自检里，而字节自检只**改**它们、不**跑**它们。`ka.bat` 不是零：`probe-motw.ps1:142` 跑过 `ka.bat status`，可断言薄到只剩 `exit=0` 加"输出不少于 40 个字符"，而且碰的是**带参数**那条分支——`if "%~1"==""` 那条无参数分支是本轮第一次被执行）：按清单复制一棵一次性树到 `_tmp/bat-entry/tree`，`$env:KA_DATA` 在**任何进程起来之前**指到一次性数据根（`ka-core.ps1:354` 读的是它；指错了 `off.bat` 会按数据根找到本机那个活着的 worker、判定"是我们自己的"、然后把用户的防休眠停掉），然后用 `cmd.exe` 真跑 `ka.bat`（无参数 = `status`，两者逐行同形；`-Json` 里的 `dataRoot`/`root` 就是这两棵树的路径）、`off.bat`、`panel.bat`、`tray.bat`。面板那条断言的是**产物**不是退出码（那四个 `.bat` 全以 `pause` 收尾，实测 `pause` 把子脚本的 `exit 5` 变成 cmd 的 **0**）：清单里每一个 `dashboard/**` 文件都要在那个端口 **200 且服务端吐出的字节数等于文件本身的字节数**、`index.html` 里 `src=`/`href=` 要到的每个名字也要 200、一个不存在的名字必须 404、`ka.bat stop-server` 之后端口要下来且 `.server-*.json` 句柄清零。后半句是 favicon 那个洞的**另一半**——进了 zip 却没有一条路由送得出去（`$staticMap`，`ka-server.ps1:49-55`，至今是手写的六行表，而清单已经从树推导）。六条实测把 harness 的形状改了，不是设计出来的：`Start-Process -PassThru` 配 `WaitForExit()` 或 `WaitForExit(ms)` 对 `cmd /c exit 3` 一律报 **0**（`Refresh()` 也救不回来；这句经 2026-09-30 三次重测**仍然成立**——那个 0 来自启动时的 `-NoNewWindow`／重定向开关，同一形状孩子退出后读也还是 `$null`；中间有一轮复跑把开关丢了、在裸形状上读到 3 就宣布"没复现"，那一版更正已被推翻，`_tmp/exitcode-switch-matrix-20260930.txt` T1–T10、`_tmp/exitcode-switch-recheck-20260930.txt` 两轮全格一致），要用 `[Diagnostics.Process]::Start`；cmd 的 `/c "..."` 引号数必须成对，少一个闭引号它只印一句 `The filename, directory name, or volume label syntax is incorrect.` 然后**退出 0**（第一次 `-SelfTest` 五条子进程全没跑成而 harness 全绿），所以判据吃的是子脚本自己写的 `PROBE OK` / `PROBE FAILED` 标记；`Invoke-WebRequest` 在 5.1 上把服务端明明白白的 404 吞成 `Status 0`，换 `HttpWebRequest` + `WebException.Response` 才拿到那个 404 和 body；`tray.bat` 跑第二次会真的多起一个进程再自己退出（本机 `20000` → `20000 + 16564` → 约一秒后又 `20000`），所以那条断言等它 settle、再比 pid，而不是数进程数。`on.bat`（和 `-Minutes` 拼错那条变异体 `badminutes`）只在 runner 上或显式 `-Power` 时才跑——worker 第一拍就发防锁合成键（`ka-worker.ps1:152`），在正在用的机器上跑等于往别人的会话里打字，本机那一条印的是 SKIP 加理由；**`off.bat` 不在跳过之列**，`[off-idle]` 那条腿每次都真跑它（SKIP 那三行末尾现在自己写着"off.bat 没被跳过：上面的 `[off-idle]` 跑过它"）。最后一条腿量的不是产品，是**这个文件自己的收尾**：`Stop-Scratch` 那 10 秒等待以前等完就把结果丢掉——一条挂在睡眠上的断言，等于没有断言——现在等的是实测（还有活着的就是红，并点名 pid 与它是哪个脚本），而新增的 `leakchild` 变异体故意在收尾之前起一个"命令行带着暂存树、名字却不落在任何清理探针够得着的三个 `.ps1` 上"的进程（`hold-open.ps1`），要求它红在 `[cleanup]`。第 6 条实测**是一条还没查清的**：十四次 sweep 里有一次是**没有注入缺陷**的那个子进程印 `an unknown name answered 0, not 404`（端口 58426，同一个文件几分钟前和几分钟后都绿，`_tmp/bat-entry-selftest-cleanup.log` 逐行可重读）。两次受控复现各 0 次偏差（30 对同一连接的 KeepAlive 开与关；40 对再挂一个每 120 ms 打六条路由的第二客户端；`_tmp/panel-keepalive-probe.ps1`、`_tmp/panel-load-flake.ps1`），所以连接池复用与并发负载这两个怀疑对象是**被排除**，不是被解释。机制仍然未知，知道的是形状：`Status 0` 是"一个 HTTP 状态码都没到过"。于是 `-Retry` 只给那一种形状三次机会、每次隔 400 ms，而**真的回了状态码**的请求绝不重试；每条 `[panel]` 红字现在带 `status=/tries=/errors=`，为的是下一次那个红活下来时能读得出它是什么。**代价照实说**：这条改动是让那条腿去容忍一个本文件并不理解的失败，而加上它之后那次 sweep 里每条路由都是 `tries=1`、一行 `note:` 都没有——它至今没被观察到吸收过一次真实的 flake | `every double-click entry that can run here ran for real, and every dashboard file the release ships answered over HTTP - ka/off/panel/tray executed; on.bat runs only with -Power or on a runner (anti-lock pulse on the first tick)` / `5 injected defects each turn their own leg red and the intact run stays green (one of them aims at this file, not at the tree)`（本机整条 sweep 实测 8m35s，六个子进程；单跑一遍 129s。它**不在 CI 里**（2026-09-28 定为长期决定，理由带数字）：`ka-ci.ps1 -Probes` 按 glob 跑 `tests/probe-*.ps1`、每个都不带参数，而这个开关没人传；要接的话代价是每次 push 多约 8.5 分钟（它本机 8m35s，而 CI 上 "Gates and probes" 已是 21m42s 那个 job 里最重的一段），收益是让那 5 个注入缺陷每轮都真的红一次——两条现成的接法（加一个带开关的 CI step，或改造成 `probe-bat-entry-selftest.ps1` 让 glob 捡到）写在前面《独立门禁与实测探针》那一段末尾） |
| `probe-ci-harness.ps1` | **CI 那条等待逻辑自己有没有牙**（2026-09-27）。`tests/ka-ci.ps1` 是本地与 CI 共用的同一个入口，而它以前用 `Start-Process -Wait` 等每个子脚本——本轮两次 CI 被人工取消（run `36242306473` 停在 31 分、`36243977634` 停在 60 分）就是它把面板留下的孙进程一起等了去：`-Wait` 等的是 stdout 管道到 EOF，而那个管道写端在孙进程手里。这条探针不碰产品（不动电源设置、不碰计划任务、不起浏览器、不停用户的 worker 与面板），只把**那个 runner** 放在六个一次性夹具上跑：`ka-a-clean`（退出 0、什么都不留）必须 ok；`ka-b-five` 必须报 `exit=5`，不能是一个悄悄变成 0 的通过——实测 `Start-Process -PassThru` 那个对象对退出 5 的孩子报 `$null`，而 `[int]$null` 是 0；`ka-c-hang`（睡 600 秒）必须在截止点被点名 `TIMEOUT after 8s, tree killed` 而且**循环继续**；`ka-d-leak` 留一个 GUI 活口、`ka-f-ghost` 留一个控制台活口，都要按 pid 与镜像名点出来；`ka-e-nocmd` 先把启动它的那个 cmd 杀掉，"退出码无从得知"必须是红、绝不能当通过。两条腿是**差分**而不是期望：`ka-c-hang` 与 `ka-e-nocmd` 共用一次 runner 调用，汇总行必须同时数到两个（数少了就说明 runner 自己死在截止点上）；`ka-f-ghost` 同一份夹具跑两遍，一遍走发出去的 runner、一遍走修复前那个 `-Wait` 形状，实测 `old shape: 16s, exit code 0` 对 `shipped runner 3s and red`——慢而沉默 vs 快而点名，两个数在同一次运行里。干净那条也不是填充物：runner 的第一版对什么都没留的脚本印 `left 1 descendant(s) alive:`（空结果回来是空字符串，而 `@('')` 有一个元素），还把夹具自己的 `conhost.exe` 一起列出来（本机静息时 402 个进程行里 23 个是 conhost），这两处都会把**没有泄漏的真 CI 步骤**判红，所以它们各自是一条断言。被点名的每个 pid 还必须**晚于本探针的开始时刻**（`$probeBorn`，`probe-ci-harness.ps1:51`；`Assert-NamedAreYoung` 在 180 行，接在 GUI 与控制台那两条泄漏腿上）——一个比探针还老的 pid 是别人的进程，把它当活口报是搭便车。**这一行末尾要说的是成本，不是结论**：`ka-ci.ps1 -Probes` 按 glob 跑 `tests/probe-*.ps1` 且每个都不带参数，所以"文件形状"的自检（这一条和下一条）自动进 CI，而把自检藏在自己文件里那个 `[switch]$SelfTest` 后面的两个（`probe-bat-entry`、`probe-native`）**一次也没进过 CI**——其中 `probe-native` 已于 2026-09-28 改成普通运行自带那条突变腿（每轮 CI 都跑，代价 5.2 秒），`probe-bat-entry` 保持在外并写明代价——前者那条 sweep 本机实测 8m35s，而本机整步 `-Gates -Probes` 实测 23m14s（27 行 0 红，`_tmp/ci-gates-probes-run2.log`），已推上去那一版在 CI 的同一句是 8m10s（run `36237945409`），两台机器不能互加，所以接不接曾是"等推上去量到真实增量再定"——2026-09-28 量到了（该 job 21m42s、这一步最重），结论见 `probe-bat-entry` 那一行 | `PROBE OK: the runner names a wrong exit code, a hang, a GUI leftover, a console leftover and a missing verdict; stays green for the script that leaves nothing; and returns in a fifth of the time the old -Wait shape takes on the same leftover it says nothing about` |
| `probe-ci-harness-selftest.ps1` | 上面那一行**真的会红吗**（2026-09-27）。它检查的不是产品、不是 runner，而是"那条探针有没有在检查 runner"这件事本身：把 `ka-ci.ps1` 复制到 `_tmp/` 的一个副本里（不是就地改仓库那份——改在仓库里的那一份会被下一个读代码的人当成事实），只加两行、两条臂各自用环境变量打开，一条把"还剩活口"的那句报告整个关掉，一条把 pid 的出生时间窗关掉；副本通过 `KA_CIH_RUNNER` / `KA_CIH_FXSUB`（`probe-ci-harness.ps1:46-47`）交给**整条**上游探针去跑，两条臂各占自己的夹具子目录，免得两次的结果算到同一棵树上。判据三块：臂 1 要求**恰好** GUI 与控制台那两条腿红、其余不许多红，而且如果它一条都没红、harness 必须自己喊出"这条断言是空的"（一个抓不到东西的注入不等于通过）；臂 2 把**跑这条自检的那个进程自己的 pid**（实测 `6532`，生于 23:28:31）塞进活口名单，要求探针按出生时间窗拒绝它——实测印出 2 条 finding，逐条写着 `born 23:28:31 - before this probe started at 23:29:14, so it is not a leftover of any leg`；对照组（两个注入都关掉的那一份副本）必须还是绿的，否则上面那两条红什么都证明不了。**为什么值得为一条探针再写一条探针**：这个仓库里最贵的一类错是"闸门绿着，而它要防的那件事正发生在它看不见的地方"——favicon 那个洞（文件在仓库里、不在清单里）、托盘 `-SelfTest` 那个洞（有人调它、没人执行主体）、`ka-ci` 那次 `-Wait` 挂死（两次 CI 被人工取消之前，这条等待逻辑本身没有任何一条断言覆盖它）各是同一个病的第三种写法 | `PROBE OK: probe-ci-harness.ps1 reddens exactly the two leftover legs when the runner stops reporting leftovers, reddens them on the age window when a pid predating the probe is named as a leftover (2 findings), and stays green through the same copy with both reports restored` |
| `probe-procwalk.ps1` | **一条腿的留口该怎么认**（2026-09-29 定案：**两个源取并集**，两条源各有各的盲区，都是量出来的）。四次假红每次烧掉一个 CI 周期，被点名的进程都与被点名的探针无关（那些探针自己都印着 `PROBE OK`）：`wps.exe`/`wpscloudsvr.exe`（office 套件，靠一条过期的父条目被算成某一腿的后代）、本机自己的 worker pid 21688、`CompatTelRunner.exe`、一整批 Windows 维护进程（`TiWorker.exe`、`TrustedInstaller.exe`、`MoUsoCoreWorker.exe`、三个 `svchost.exe`、`CompatTelRunner.exe`），本机还多一次 `sleep.exe`（**Git 自带的 `sleep`**，由正在旁观的工具链拉起）。根都在"用 pid 重建祖先链"：一条 `pid→ppid` 条目只对**写下它时持有该 pid 的那个进程**成立。试过两条补丁（比对创建时间；pid 活着却没记下创建时间就停）——CI 绿过一次（run `36528628613`）但"中间有一跳已经死了又被人拿过"那一类还开着；又试过**只用 Job 对象**（`CreateJobObject` + `AssignProcessToJobObject`，事后一次 `QueryInformationJobObject` 读成员表）——**被集成探针当场否掉**：`probe-ci-harness.ps1` 那个故意的 GUI 留口是夹具用 `Diagnostics.Process` + `UseShellExecute` 起的（浏览器交接就是这种形状），**继承不到 job**，CI 上 `our own look: 1 alive: 5216` 而 runner 报 `1 run, 0 red`（run `36534077753`）；重建恰好看得见它（历史记着当时那个脚本是它的父亲）。所以定案是**并集**：job（精确，但那类看不见）∪ 重建（看得见那类，但需要守卫），再过滤年龄窗与 `conhost/OpenConsole`；而重建那条守卫补成**"跟着走的每一跳都必须有记下来的创建时间"**——没采样过的 pid 等于对它一无所知，停在那里而不是顺着它记录的父进程往上爬（这就是 `sleep.exe` 那一支），同时**采样过**的死跳照旧走通（shell 起的那类留口的父亲就是那一腿自己的脚本，活着并被采到过）。`Assign`/`Query` 失败一律抛错而不是当红腿。探针直接驱动两个源：①本进程起并加入的进程是成员 ②**用 WMI 造的进程不是成员**（它父是 `WmiPrvSE.exe`，正是那些假红的形状）③退出的成员消失 ④年龄窗分内外 ⑤`Kill` 带走成员 ⑥重建：链条点名／pid 易主必须拒／**有记录的**死跳走通／**没记录的**死跳必须停／**活着却读不出创建时间的**必须停／采样不给出时间的行不许被记成 tick 0 ⑦把"问 job"那行换成"所有活进程"，②必须变红 ⑧把"每一跳都要有记录"删掉，⑥的第 4 条必须变红 ⑨把"只记正数时间"删掉，⑥的第 6 条必须变红 ⑩把守卫改回"读到了时间才比较"那句旧写法，⑥的第 5 条必须变红。**⑥ 的第 5、6 条与 ⑨⑩ 是 2026-09-30 为 run `36679927952` 补的**：那一红是一条**只有文档**的提交，红的却是留口归属——`[long]$null.Ticks` 是 `0` 且不抛，于是 CIM 不给 `CreationDate` 的镜像被记成"创建于 tick 0"，两条守卫一起被绕过，一条 6 分钟腿的名单里冒出 11 个无关的系统进程；本机实测 334 行 CIM 里 0 行是 null（`_tmp/procwalk-cim-timing-20260930.txt`），所以那两条用例把这种行**喂**给守卫（`& { function Get-ProcessRows { … } }` 只在块内生效），runner 上它才是自然的。本机整条 15.4→**26 秒**（多出的两个注入腿各要起一个子进程）。集成那一半由 `probe-ci-harness.ps1` 把关（两个**故意**漏进程的夹具必须照样被点名） | 见其末行：每一台机器上都印出上面十条各自的判定 |
| `probe-iss.ps1` | 真编译 `packaging/KeepAwake.iss`：原样字节和 CRLF 那份（`.gitattributes` 交给 clone 的形状）都要过；产物必须叫 `release.yml` 找的那个名字；不给 `/DMyAppVersion` 要被 `#error` 挡下；把卸载回调写成 `procedure` 要被拒（**这就是修复前的写法**）。最后一条是记录盲点：删掉 `Result := True` **照样编译**，所以那行只有这条探针守得住 | `6 assertions - ... refuses a build with no version and a callback with the wrong prototype, and records the one mistake the compiler will not catch for us`。没有 Inno 的机器上它打印 `PROBE SKIPPED` 并按 0 退出——"没跑"不说成"过了" |

探针的脚手架要么写在仓库根的 `_tmp/`（gitignore 里，所以探针自己带 `-Force` 创建——全新 clone 时它并不存在），要么写在
`%TEMP%` 下的独立目录里（`probe-native` / `probe-wow64` 的编译沙箱、`probe-culture-mutation` 捕获的子进程输出走这条）。总之内嵌
C# 的 `.cs`、临时 clone、被改坏的副本都不会落在 `tests/` 旁边，中途被打断也不会留下第二份 `ka-core.ps1`。`probe-culture-mutation.ps1` 会**临时修改** `ka-core.ps1` 与 `ka-lid.ps1` 再逐字节还原，并在还原后用 md5 自查——如果它被打断，`git diff` 里会留下痕迹，别把那当成产品问题。

### 怎么出一次 release

三件套（`portable.zip` / `setup.exe` / `SHA256SUMS`）都由同一份清单产出，本地一条命令：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File packaging\build.ps1 -Stage -Installer -Smoke
```

产物落在 `dist/`，`SHA256SUMS` 是最后一步顺手算的（`-Sum` **单独**用是"只重算哈希、不重新打包"；和 `-Stage` / `-Installer` / `-Smoke` 一起用则什么都不加——完整构建走到末尾本来就会算一遍。这两件事今天才对齐，见《发布前实测修掉的缺陷》最后一条）。`-ShowVersion` 只打印版本号就退出，CI 用它把 tag 和代码里的 `$script:KaVersion` 对起来。

`-Smoke` 是这一步真正值钱的地方：它把刚做好的 zip 解压到 `_tmp` 下的独立目录，把 `KA_DATA` 指到一个**空的**临时数据根，用系统自带的 PowerShell 5.1 跑 `ka.ps1 status -Json`，然后要求——退出码 0、JSON 能解析、报回来的 `version` 就是这次打包的版本、`programRoot`/`dataRoot` 确实是我们递给它的那两个临时路径（不是 `%LOCALAPPDATA%`，也不是解压目录）、`dataError` 为空、**跑完之后程序目录里一个文件都没多**。这一条是"产品绝不往自己的安装目录写东西"这个承诺在发布链路上的复检。它自己被 `probe-build-selftest.ps1` 钉住了会红（见上表），所以下面这句话不是"我们写了个冒烟测试"，而是"这个冒烟测试被证明抓得住三种事故形状，也被证明**看不见**第四种——那种形状现在换成一腿要求它必须绿、并且拿 zip 的条目表来对账"。

`setup.exe` 需要 Inno Setup 6。2026-09-05 在本机装了 **Inno Setup 6.7.3**（winget 下载、哈希由 winget 校验、`/CURRENTUSER /VERYSILENT` 装进 `%LOCALAPPDATA%\Programs\Inno Setup 6`，全程没有提权），`build.ps1 -Installer -Smoke` 第一次真编译过 `KeepAwake.iss`：`Successful compile (3.454 sec)`，出 `dist\KeepAwake-1.0.0-setup.exe`（2.16 MB）。以后这件事由 `tests/probe-iss.ps1` 守着，不再靠人读。

编译确实抓到了一个**人读不出来**的缺陷：卸载回调写成了 `procedure InitializeUninstall()`，而 Inno 要求的是返回 Boolean 的 `function`——ISCC 的原文是 `Invalid prototype for 'InitializeUninstall'`，编译直接中止。同一次审查改掉的另外两处要靠分开说：`{commondesktop}` 换成 `{autodesktop}` 是**实测编译通过**的（每用户安装写不了"所有用户桌面"，那是安装时才炸的问题，ISCC 不管）；删掉一个还不存在的仓库 URL 更是任何编译器都无从判断的东西——这两处只有"读"这一道防线，说清楚免得下次误以为 ISCC 会替我们挡下来。

编译器不在的时候 `-Installer` 也不会假装成功：本机实测退出码 1 + `Inno Setup 6 (or 7) is not installed here. …  the setup.exe is not optional in a release.`。少一个产物的 release 和一次失败的 release 是同一回事，所以这里没有"静默跳过"这个选项。

`setup.exe` 这一块已经不再悬着了：它在**本机**被真装真卸过，20 条断言、开始菜单/注册表/端口/计划任务的前后对比、卸载钩子的耗时、任务导出再逐字节补回，全写在《安装版：setup.exe》那一节，命令是 `packaging/ka-test-install.ps1 -WithWorker -SelfTest`（`-SelfTest` 会连两个突变一起跑，证明这套断言抓得住红）。在这台机器上跑它的代价同样写在那一节里——它会把你的 `KeepAwake-Guard` / `KeepAwake-Logon` 删掉再补回来，所以别在没备份的情况下跑。

上面这些在 GitHub 的一次性 runner 上**已经真跑过**（2026-09-08 起每个 push 都跑，实测记录见本节末尾）。找编译器这一步 `packaging/ka-iscc.ps1` 只有一份实现，`build.ps1` 和探针共用它，CI 装完之后还要用同一个函数再找一遍（机器级安装落在 `Program Files (x86)`，和本机这次的用户级路径不是同一个目录）——这一步在 runner 上实测通过。

CI 侧两个 workflow：

- `ci.yml`（push `main` / 每个 PR）复用 `build-test.yml`：先装 Inno Setup 并用 `Get-KaIscc` 复核找得到编译器（这样 `probe-iss` 在 CI 上永远不会走到"跳过"那个分支），再 `-Gates -Probes`，然后跑 `ka-tests.ps1` 全量行为套件（这一步在 GitHub 的临时 Windows runner 上跑，不动任何人的机器——这正是本地不允许随手跑它的那个理由），接着 `build.ps1 -Stage -Installer -Smoke` 出三件套，然后**把刚做好的那个 `setup.exe` 装上再卸掉**（`packaging/ka-test-install.ps1 -WithWorker -SelfTest`，也就是上面那 20 条断言加两个突变，整轮 2 分 41 秒），最后把包含 `setup.exe` 的 `dist` 作为 artifact 上传。
- `release.yml`（打 `v*` tag 或手动 dispatch）先 `needs: build-test`，再核对 tag 与 `-ShowVersion` 一致、`choco install innosetup`、`build.ps1 -Installer -Smoke`、**当场把 `dist` 里的文件数死锁为三件套并逐个拿 `SHA256SUMS` 重算比对**，然后建 GitHub Release 上传。

上面两个 workflow 从 2026-09-08 起在公开仓库 <https://github.com/faruheaisha/keepawake> 的每个 push 上真跑。`ci.yml` 头三轮各揪出一批只有真跑才看得见的缺陷，全部修掉：

- **首轮（push 136730d）套件 10 条红，修复 d10f1bb**：两条真坏引用（`Get-KaRoot` 在阶段 1 的程序/数据目录分离里改名为 `Get-KaPath`，套件有一处没跟上；`probe-wow64.ps1` 2026-09-04 毕业进 tests/ 之后，撞上了后来才立的 per-thread 电源请求扫描名单）；一条断言消息把自己打崩（`Assert` 的消息串是急切求值的，空数组路径上 `Split-Path -Leaf $null` 抛异常，把一条本来会过的测试打死）；七条机器假设（runner 没有电池、14 天没有 506 待机事件、虚机固件能力位与 `powercfg /a` 文本失配等）——按同一条规矩处理：**这台机器验不了就诚实 `Skip` 并写明为什么**，不放松成永远绿；物理机上牙齿原样保留。
- **第二轮（d10f1bb）套件全绿（84 通过 / 0 失败 / 5 跳过），安装器步骤又揪出一条，修复 d482076**：GitHub runner 的 `%TEMP%` 是 8.3 短路径（`C:\Users\RUNNER~1\...`），`Get-ChildItem` 返回的 `FullName` 却是长拼写（多 3 个字符），按短路径长度 `Substring` 切相对名少切 3 位，每个条目前残留目录名末两位——`ka-test-install-a2b0c748` 装出了 `48/CHANGELOG.md`，23 个清单文件全部被记成"多余"。不是 Inno 装错了地方，是断言切错了字符串。本机造了一个 11 字符父目录（差值同为 3）复现出逐字节相同的红，修复（按枚举器拼写的根切）后同输入转绿。
- **第三轮（d482076）全绿，11 分 49 秒**：门禁+探针约 6 分、套件约 3 分、三件套构建数秒、把做好的 `setup.exe` 在 runner 上装上再卸掉（`-SelfTest` 两个突变照常各红在自家断言上、净装绿）。

`v1.0.0` tag 推上去之后 `release.yml` 又跑了三轮，揪出三条**只有发布这条路才会遇到**的：

- **第四条，探针在说谎（release 首轮，修复 f2193a0）**：红在 `probe-culture` 的 `KA_OFFSET_STABLE=MISMATCH`（de-DE），而**同一个 commit 的 `ci.yml` 全绿**——这个反差就是证据。那条断言原本是取**两次** `Get-Date -Format 'o'` 再比各自的 `ToUnixTimeSeconds()`，负载高的 runner 上两次采样跨过一秒边界，就报一个根本不存在的时区偏移错。现在只采**一次**时刻、用两种解析策略比**同一串**：断言的性质没变（`'o'` 带 UTC 偏移、`'s'` 不带），但不再顺带要求时钟在两次采样之间站住。因为这时还没有任何人拿到过产物，tag 是移过去的（删掉重建到新 commit）而不是升版本。
- **第五条，最后一步没 token（release 次轮）**：前面 11 分钟全绿，`Publish` 回 `gh release create exited 4`——Actions 里的 `gh` 不读运行时自带的那个 job token，只认 `GH_TOKEN` / `GITHUB_TOKEN`。`permissions: contents: write` 一直是对的，缺的只是把 token 递到 `gh` 手上。修完还在版本核对那一步开头加了 `GH_TOKEN` 非空检查：同一类错误下次值 5 秒，不值 11 分钟。
- **第六条，全绿却发了一个空 release（release 第三轮）**：token 补上之后整条流水线绿了，Release 页也真建出来了，`gh api …/releases/latest` 却回答 `assets: 0`。`gh release create` **不带文件路径就是只建 release、不传文件，退出码 0** —— 三个产物从没离开过 runner，而 workflow 只检查了"命令成功"，没检查"页面上有东西"。走 `--clobber` 的那条分支带了 `@files`，可惜这次执行的不是它。现在 create 也带文件，`Publish` 末尾把 release 页**读回来**逐项比对，不是那三个就 throw；这条断言对着当时那个空 release 报 `missing=3`，喂三个正确文件名报 `pass`，混进一个旧版本号的文件报 `extra=1`。

**结果（release 第四轮，2026-09-08 16:30:06Z）**：`v1.0.0` 的 Release 页上真有三个文件，而 GitHub 自己为两个产物算出的摘要与 release 里那份 `SHA256SUMS` **逐字节相同**——下载者照《先核对哈希》那段粘一遍，两个都会印 `OK`。**哈希能回答的到此为止**：CI 编出来的这两个哈希与本机同一次构建算出的**不一样**，因为 zip 和 setup.exe 里嵌了构建时刻，本项目没有可复现构建。也就是说哈希回答"这份文件和他发布的那份是不是同一份"，回答不了"这份是谁编的"——后者要代码签名，v1.0 没有（理由见 SECURITY.md）。

`tests/ka-workflow.ps1` 能保证的只是每个 `run:` 块能被 5.1 解析、YAML 没有 tab 缩进——上面这些是 Actions 求值器那一层的，只有真跑一次才知道。现在知道了。

这一节只管**怎么出**一次 release。**拿到** release 的人看到什么、怎么核对、两条路径各自怎么装和卸，在《拿到 release 之后》。

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

用 `setup.exe` 装过的人：先在"已安装的应用"（或开始菜单那项 `Uninstall KeepAwake`）里卸载——它会先跑 `stop-server` / `stop` / `unguard`，再把程序目录带走。数据目录它**不删**，所以下面那几条删数据目录的命令对这条路径同样适用。便携包用户从下面这四条开始：

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
