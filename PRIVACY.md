# 隐私说明 / Privacy

> **English (summary).** KeepAwake has no telemetry, no analytics, no accounts, no update check and no
> server of any kind. It never opens an outbound connection. Everything it writes stays in two folders
> on your own machine, listed file by file below. The only HTTP traffic in the whole product is the
> built-in dashboard talking to itself on `127.0.0.1`. Anything that could identify you is a *path*
> (your Windows user name is in it) or a timestamp — recorded locally, for you to read.

**这个工具不收集任何东西。**没有遥测、没有统计、没有崩溃上报、没有"检查更新"、没有服务器、没有账号。
产品代码里出现的**每一个 URL 都是 `http://127.0.0.1:*`**（本地面板）——包括由片段拼出来的那些，见下文；
这一点由 `tests/ka-privacy.ps1` 在 CI 与本地把守，不是靠人承诺。

下面把"写在磁盘上的每一个文件、每一个字段"列全。这是本机 `%LOCALAPPDATA%\KeepAwake` 与
`%ProgramData%\KeepAwake` 在 2026-09-04 的实测内容，不是设计意图。

## 东西写在哪儿

| 路径 | 谁写 | 内容 |
| --- | --- | --- |
| `%LOCALAPPDATA%\KeepAwake\config.json` | 你（面板「存为默认」/ `ka.bat config -Set` / 手改） | 你的配置。**只存与默认值不同的键**，其余键下次读时按当时版本的默认值现算 |
| `%LOCALAPPDATA%\KeepAwake\machine.json` | `ka.bat check` | 本机电源画像：电源计划名与各档超时、`powercfg /a` 报告的可用睡眠状态、`GetPwrCapabilities` 能力位、Windows 版本字符串、生成时刻、建议心跳间隔 |
| `%LOCALAPPDATA%\KeepAwake\intent.json` | `start` / `stop` | 你要什么：`desired`（`awake`/`off`）、`minutes`、`expiresEpoch`、`updatedAt`。看门狗靠它对账，"重启后自动恢复"就是靠它 |
| `%LOCALAPPDATA%\KeepAwake\state.json` | worker 每 tick | 现场读数：`pid`、电源请求 flags、`pulses` / `lastPulseEpoch` / `lastPulseResult`、`lockSkips` / `ilSkips`、`batteryPercent` / `acOnline` / `batteryFloor`、`startedEpoch` / `expiresEpoch`、`note`（机器标记，如 `lock-screen`、`il-mismatch`、`battery-floor`） |
| `%LOCALAPPDATA%\KeepAwake\ka.log`（超上限轮转成 `ka.log.1`） | 所有进程 | ASCII 事件行。词汇：`STARTED` / `STOPPED` / `STOP` / `STOP-REQUEST` / `STOP-UNCOOPERATIVE` / `STOP-INTENT-UNRECORDED` / `PULSE` / `PULSE-SKIP` / `HEARTBEAT` / `DOWNGRADE` / `SKIP` / `RESUMED` / `EARLY-EXIT` / `EXIT` / `SERVER` / `SERVER EXIT` / `REJECT` / `GUARD` / `GUARD-FAILED` / `LID` / `RESTORE` / `WARN` / `FAIL` / `STARTED-UNRECORDED` / `INTENT-WRITE-FAILED` / `MIGRATE-SKIP` / `LOG-FAILED`。失败细节写成 `err=<异常类型>#<HRESULT>[#win32=<码>][#<cmdlet 错误 id>]`（例：`err=CimException#0x80131500#HRESULT 0x8004100e,GetCimInstanceCommand`）——这几样 Windows 自己都不翻译，所以永远是 ASCII；**不写异常消息**，因为那是一句本地化了的话（中文系统上是中文，还可能带着含用户名的路径），日志只给代码，句子由各界面按自己的语言查词典生成 |
| `%LOCALAPPDATA%\KeepAwake\.server-<端口>.json` | `serve` | 面板进程的握手信息：`pid`、`port`、`url`、`data`、`root`、`startedEpoch`（`ka.bat stop-server` 用它找人）。**按端口一份**，所以同时开两个面板不会互相抹掉对方的句柄。改版前那份共享的 `.server.json` 仍然**只读**（否则先起来的面板就找不回来了），它的进程一旦确实没了就被扫掉 |
| `%LOCALAPPDATA%\KeepAwake\.migrated.json` | 首次升级 | 迁移记录：`from`（旧程序目录）、`copied`、`skipped`、`at`、`version`。只有在确实搬动了文件时才会写出来 |
| `%LOCALAPPDATA%\KeepAwake\stop.flag` | 停 worker 的握手 | 生命周期极短，正常路径下会被消费掉 |
| `%ProgramData%\KeepAwake\ka-lid-backup.json` | `ka.bat lid -LidAction apply` | 改合盖动作**之前**的原值：`schemeGuid`、`schemeName`、`dc`、`ac`、`capturedAt`、`found`。`restore` 靠它还回去 |
| 计划任务 `KeepAwake-Logon` / `KeepAwake-Guard` / （可选）`KeepAwake-Boot` | `ka.bat guard`（`-Boot` 需管理员） | 任务动作里存的是**脚本的绝对路径** |

`KA_DATA=<目录>` 可以把上面第一组整体挪到别处。想知道当前生效的是哪个目录：`ka.bat config` 会打印
它实际读写的 `config.json` 全路径（它的所在目录就是数据根）；数据根不可写时 `status` 与面板会把那个路径
连同原因一起报出来（`alert.dataDirUnwritable`），不会静默降级。

## 这里面唯一算得上"和个人有关"的东西

诚实版，一条不漏：

1. **你的 Windows 用户名和目录名会以"路径"的形式留下痕迹。**数据根本身就在 `C:\Users\<你>\AppData\...`
   下面，所以 `.server-<端口>.json` 的 `data`、`.migrated.json` 的 `from`、`ka.log` 里的报错行、计划任务里注册的
   执行路径都含用户名。程序目录名同理（本仓库作者的那份就叫 `E:\claude code\防休眠`）。这是"文件放在
   哪里"的自然结果，不是记录下来的行为。
2. **`machine.json` 存 Windows 版本字符串**，实测形如
   `Microsoft Windows 11 家庭版 中文版 10.0.26200 build 26200`；以及**电源计划名**（如「平衡」）。
   企业自定义过的计划名会原样写进文件。
3. **时间序列。**`ka.log` 与 `state.json` 合起来能看出这台机器什么时候插着电、什么时候在跑保护、
   电池大概多少。这是本机自查"到底有没有效"的必要材料（见 README《有效性是实测的》），但它确实是行为节律。
4. **心跳被拦截时，`ka.log` 会留一个 PID 数字。**当 UIPI（前台进程完整性高于本工具）导致某次心跳被跳过时，
   日志写 `PULSE-SKIP pid=... selfIl=0x... fgIl=0x... fgPid=...`。这里**只有数字**：工具用
   `GetForegroundWindow` + `GetWindowThreadProcessId` 取前台进程的 PID 和完整性 RID 做判定，
   **不取进程名、不取窗口标题、不读任何输入内容**，也不把这两个数字写进 `state.json`。
5. **`REJECT` 行只记录被拒的请求路径和原因**（如 `REJECT /api/report GET : deny=client`），
   不记录来源地址、不记录 User-Agent —— 服务端代码里根本没有读这两个字段。

反过来说，**工具不记录也不采集**：键盘输入内容（心跳只"发"一个固定的 F15 虚拟键码，从不读键盘）、
鼠标轨迹、屏幕内容、窗口标题、进程列表、文件内容、剪贴板、网络状态、你的 IP、账号或设备标识符。
它不生成任何唯一 ID，也没有能承载唯一 ID 的地方。

## 数据会不会离开这台机器

不会，而且是结构性的原因，不是"我们承诺不会"：

- **没有上报代码可跑。**整个产品里唯一的网络客户端调用是面板进程访问 `http://127.0.0.1:<port>` 的
  `stop` 握手。没有 `Invoke-WebRequest`/`WebClient`/`HttpClient` 指向任何非回环地址——由
  `tests/ka-privacy.ps1` 把守，扫的是随包发出去的每一份文本：顶层 `.ps1`/`.bat`、`dashboard/**`、
  以及**安装器** `packaging/**`（`.iss` 里一条"打开更新页"的 `[Run]` 也是出网路径，而它在这些代码
  之前就会被运行）。它盯的是**网络能力的家族**
  （`System.Net`、`Sockets`、`Net.Dns`、`WebRequest`、`certutil`/`bitsadmin`/`curl` 这类外部下载器、
  `winhttp`/`wininet`/`ws2_32` 这类 DLL 名），不是"想得出来的 API 清单"：用没见过的写法出网，也得先
  在那份闸门文件里登记过才行。
- **不假设"URL 一定写得完整"。**`'http://' + 'collector.example' + '.com/submit'`、`'https:/'` 拼
  `'/keystore.example.org/ping'` 这类由片段组成的目的地，会被先把相邻字面量接回去再读一遍；只写到
  `://` 就断开的（`'http://' + $host`）直接按"读不出它要去哪儿"报。这些洞是 2026-09-26 用注入实测出来
  的，旧那份闸门对同一份副本 `exit=0`。
- **还有一条不需要联网 API 的通道：把地址交给 Windows shell。**`Start-Process 'telemetry.example.com/collect'`
  里没有 scheme（浏览器自己补上 `http://`）、没有任何 `System.Net` 名字，规则 1~4 都够不着。所以规则 5
  把成品里**每一处"交给 shell"的写法按文件数着登记**：实测 6 个文件 10 处，多一处就得在闸门里说清它开的是
  什么。仍然拦不住的那种情况也写在闸门注释里而不是藏起来——已经在册的 10 处如果只把**参数**换成一个不带
  scheme 的裸主机，行数不变、也没有 scheme 可读，这一层只能靠"面板 URL 是 `ka-core.ps1` 里唯一一个回环
  字面量拼出来的"间接兜住。
- **没有需要上传的东西。**不激活、不验授权、不比对版本号。
- **离线可用。**断网、防火墙全拒、无网卡的情况下，起停、面板、看门狗、`evidence` 全部照常工作
  （面板只监听回环，本来就不需要网络出口）。

## 面板只监听回环，但"只监听回环"不是安全边界的全部

服务绑定在 `127.0.0.1` 与 `localhost` 前缀上，**不监听 `0.0.0.0`**，所以局域网和互联网都到不了它。
同一台机器上的**任意网页**默认也能向 `127.0.0.1` 发请求，这一层由两条请求头规则挡掉（见
[SECURITY.md](SECURITY.md)《面板的暴露面》）。

要说清楚的是：**同一个用户账户下运行的程序从来不是"外部攻击者"。**它能直接改 `config.json`、能
`Stop-Process` 掉 worker、能自己调用 `SetThreadExecutionState`。面板的头规则挡的是"你打开的一个恶意网页
顺手改你的电源设置"，不是挡"已经以你的身份跑起来的恶意软件"——后者在这个账户下不需要经过我们的面板。
`config.json`、`state.json`、`ka.log` 都**不是机密文件**，别把里面的内容当凭证保管，也别把它们放进
会同步/会共享的目录（把数据根指到云盘里就等于是把电源画像和你的用户名同步出去了）。

## 把日志贴到 issue 之前

提 bug 时如果需要附 `ka.log` 或 `ka.bat report` 的输出，请注意它们含**你的用户名、目录名、机器名相关的
版本字符串**。这些行是本地文件，工具没有替你可能对外发送；但你自己贴出去就算对外发布了。
建议手工把 `C:\Users\<你>\` 与程序目录替换掉再贴。

## 要全部清掉

```powershell
off.bat                                   # 停保护，电源请求随进程消失
ka.bat unguard                            # 删计划任务
ka.bat stop-server                        # 关面板进程
ka.bat lid -LidAction restore             # 仅当曾改过合盖动作
Remove-Item -LiteralPath "$env:LOCALAPPDATA\KeepAwake" -Recurse -Force
Remove-Item -LiteralPath "$env:ProgramData\KeepAwake" -Recurse -Force   # 仅当存在（改过合盖动作才会有）
```

删完这两个目录，这个工具在这台机器上就没有留下任何它自己写下的东西了。不需要"撤销同意"、没有云端残留、
没有注册表策略、没有服务、没有驱动。

上面是**便携包**的口径。用 `setup.exe` 装过的机器上另有两处痕迹，都由 Inno 而不是本工具的代码写下：
`%APPDATA%\Microsoft\Windows\Start Menu\Programs\KeepAwake`（开始菜单那五项，桌面快捷方式默认是勾上的，不取消它就有）
和 `HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall` 下以 AppId `{8B7C1F4E-2D9A-4C3B-9E57-6A18D3F0C4B2}`
开头、后缀 `_is1` 的那一条（"已安装的应用"里看到的正是它）。**走一次正常卸载会把这两处一起带走**，跳过卸载
直接删程序目录就会留下它们——而卸载本身**不碰**上面那两个数据目录。

这两处不再是"按文档推"：`setup.exe` 已在本机被真装真卸过（`packaging/ka-test-install.ps1`，2026-09-05），
上面那两个路径就是那轮断言里"装完应当在、卸完应当不在"的两个检查项。同一轮还实测了
安装**不**注册计划任务（根任务目录 27 → 27）、**不**开监听端口，而卸载会连 worker 的电源请求一起带走。
细节和它在 CI 里的位置见 README《安装版：setup.exe》。
