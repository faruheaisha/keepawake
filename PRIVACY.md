# 隐私说明 / Privacy

> **English (summary).** KeepAwake has no telemetry, no analytics, no accounts, no update check and no
> server of any kind. It never opens an outbound connection. Everything it writes stays in two folders
> on your own machine, listed file by file below. The only HTTP traffic in the whole product is the
> built-in dashboard talking to itself on `127.0.0.1`. Anything that could identify you is a *path*
> (your Windows user name is in it) or a timestamp — recorded locally, for you to read.

**这个工具不收集任何东西。**没有遥测、没有统计、没有崩溃上报、没有"检查更新"、没有服务器、没有账号。
产品代码里出现的**每一个 URL 字面量都是 `http://127.0.0.1:*`**（本地面板），这一点由 `tests/ka-privacy.ps1`
在 CI 与本地把守，不是靠人承诺。

下面把"写在磁盘上的每一个文件、每一个字段"列全。这是本机 `%LOCALAPPDATA%\KeepAwake` 与
`%ProgramData%\KeepAwake` 在 2026-09-04 的实测内容，不是设计意图。

## 东西写在哪儿

| 路径 | 谁写 | 内容 |
| --- | --- | --- |
| `%LOCALAPPDATA%\KeepAwake\config.json` | 你（面板「存为默认」/ `ka.bat config -Set` / 手改） | 你的配置。**只存与默认值不同的键**，其余键下次读时按当时版本的默认值现算 |
| `%LOCALAPPDATA%\KeepAwake\machine.json` | `ka.bat check` | 本机电源画像：电源计划名与各档超时、`powercfg /a` 报告的可用睡眠状态、`GetPwrCapabilities` 能力位、Windows 版本字符串、生成时刻、建议心跳间隔 |
| `%LOCALAPPDATA%\KeepAwake\intent.json` | `start` / `stop` | 你要什么：`desired`（`awake`/`off`）、`minutes`、`expiresEpoch`、`updatedAt`。看门狗靠它对账，"重启后自动恢复"就是靠它 |
| `%LOCALAPPDATA%\KeepAwake\state.json` | worker 每 tick | 现场读数：`pid`、电源请求 flags、`pulses` / `lastPulseEpoch` / `lastPulseResult`、`lockSkips` / `ilSkips`、`batteryPercent` / `acOnline` / `batteryFloor`、`startedEpoch` / `expiresEpoch`、`note`（机器标记，如 `lock-screen`、`il-mismatch`、`battery-floor`） |
| `%LOCALAPPDATA%\KeepAwake\ka.log`（超上限轮转成 `ka.log.1`） | 所有进程 | ASCII 事件行。词汇：`STARTED` / `STOPPED` / `STOP` / `STOP-REQUEST` / `STOP-UNCOOPERATIVE` / `STOP-INTENT-UNRECORDED` / `PULSE` / `PULSE-SKIP` / `HEARTBEAT` / `DOWNGRADE` / `SKIP` / `RESUMED` / `EARLY-EXIT` / `EXIT` / `SERVER` / `SERVER EXIT` / `REJECT` / `GUARD` / `GUARD-FAILED` / `LID` / `RESTORE` / `WARN` / `FAIL` / `STARTED-UNRECORDED` / `INTENT-WRITE-FAILED` / `MIGRATE-SKIP` / `LOG-FAILED` |
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

不会，而且有三重结构性原因，不是"我们承诺不会"：

- **没有上报代码可跑。**整个产品里唯一的网络客户端调用是面板进程访问 `http://127.0.0.1:<port>` 的
  `stop` 握手。没有 `Invoke-WebRequest`/`WebClient`/`HttpClient` 指向任何非回环地址——由
  `tests/ka-privacy.ps1` 扫描全部 `.ps1`/`.js`/`.html`/`.bat` 字面量把守。
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
