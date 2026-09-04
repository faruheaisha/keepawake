# 安全说明 / Security

> **English (summary).** KeepAwake is a local PowerShell utility with one listening socket bound to the
> loopback interface, no outbound network calls, no auto-elevation except behind one explicit command
> (`lid apply`, which raises a single UAC prompt), no service, no driver, no registry policy writes.
> Binaries are unsigned in v1.0 by design — see《没有代码签名》。To report an issue, use the private
> vulnerability reporting on this repository's Security tab.

先说清这份文档的边界：这个工具的定位是**"让一台你自己有权限的机器别睡着"**。它不是安全产品，不守护任何
机密，也不提供任何认证/授权能力。安全上真正需要关心的三件事是：面板监听的端口、它合成输入的行为、以及它
在系统里留下了什么。下面逐个说，并区分**已实测**与**只是设计意图**。

## 面板的暴露面

面板（`panel.bat` / `ka.bat serve`）是唯一开口的东西。

- **只绑回环**：`ka-server.ps1` 的 `Prefixes.Add` 只有 `http://127.0.0.1:<port>/` 与 `http://localhost:<port>/`
  两种，**没有** `+`、`*` 或 `0.0.0.0`。局域网与互联网不可达，不需要防火墙规则。
  这条由 `tests/ka-privacy.ps1` 规则 3 把守，配 `tests/ka-privacy-mutation.ps1` 证明它真会红。
- **不发出 `Access-Control-Allow-*`**：服务端代码里没有任何一处设置 CORS 响应头（规则 4 扫描三种写法）。
- **任意网页能不能替你改电源设置？** 这是本地端口最现实的威胁：浏览器里打开的一个恶意页面完全可以
  `fetch('http://127.0.0.1:8791/api/start')`。挡它的是两条请求头规则：
  1. `/api/*` 必须带自定义头 `X-Ka-Client: ka-dashboard`。跨源页面发不出这个头——浏览器会先发 CORS
     预检，而服务端从不批准，请求在到达业务逻辑前就死了。这是真正的 CSRF 边界。
  2. 带 `Origin` 时必须指向本机回环源（含端口），`Host` 必须是 `127.0.0.1` / `localhost`——后者顺带挡住
     DNS 重绑定（把某个外域 A 记录解析到 127.0.0.1 再借那个源发请求）。
- **静态文件走固定白名单**：只发 `dashboard/` 下按名字列举的那几个文件，未知名字一律 404，不存在路径穿越。
- **GET 不改变任何东西**，所有副作用都在 POST 里。
- **未加密**：HTTP 而非 HTTPS。回环上的面板没有跨网络的窃听面，所以本工具选择不加密；但请把
  "这个端口上的内容在本机可读"当作事实——本机任何进程都能看，别把敏感东西打进面板表单。

**这条边界挡不住谁**（写清楚，免得把它当成访问控制）：同一个 Windows 用户账户下运行的任何程序。
那个程序可以直接编辑 `config.json`、可以 `Stop-Process` 掉 worker、也可以自己调用
`SetThreadExecutionState`。面板的头规则防的是"顺手被你打开的网页改了设置"，不是"已经以你的身份跑起来的
恶意软件"。同一个管理员账户下的其他用户、以及能物理接触这台机器的人，本来就在威胁模型之外。

## 它合成的输入

引擎二每 `antiLockIntervalSec`（默认 240 秒）发一次无害输入：

- `key` = 一次 **F15** 虚拟键码按下+抬起。绝大多数键盘上没有这个物理键，常规应用也不处理它。
  **工具不读键盘**：它只发这一个固定键码，不注入字符串、不映射其他键、不查询剪贴板、不记录你打了什么。
- `mouse` = 光标移动 1 像素再**精确**移回原位（不是"大概回原点"）。

安全后果要如实说：**这个工具的设计目的就是让屏幕常亮、让系统不锁屏。**所以：

- 人走开时，如果你依赖"Windows 空闲自动锁屏"来保护会话，开着防休眠就等于放弃了这层保护。
  需要锁屏时按 Win+L，或者停掉保护。**工具不会拦 Win+L，也不拦**：那需要注册表策略级别的改动，
  属于削弱系统安全的机器级操作，一个脚本偷偷做这种事是不可接受的（见 README《能力边界》）。
- 安全桌面（锁屏 / UAC 提示）之下合成输入到不了你的会话。worker 检测到锁屏会**跳过心跳并计数**
  （`lockSkips`），不会假装成功。
- 前台进程完整性更高时（例如管理员权限的窗口），UIPI 会静默丢掉心跳。工具对此的处理是**如实报告**
  （`PULSE-SKIP reason=il-mismatch`，日志里带双方完整性 RID 和前台 PID 数字），不会尝试提权来绕过它。

## 提权：全文只有一处

`ka-lid.ps1` 的 `Invoke-KaLidElevation` 用 `Start-Process powershell.exe -Verb RunAs` 重新拉起自己——
**仅**当你明确执行 `ka.bat lid -LidAction apply`（改合盖动作，电源计划属性需要管理员）时才会触发一次 UAC。

- 受 `-NoElevate` 开关控制；非交互会话（`[Environment]::UserInteractive` 为假，例如计划任务里）直接返回
  失败说明，不会弹一个没人看得见的 UAC 窗口。
- 重启参数只带一个动作名和 `-DataDir`，都是固定参数名，值里没有分词空间（Windows 文件名也不允许 `"`）。
- 标准账户点"取消"或根本没有管理员凭据时，工具**失败并打印一条让管理员代跑一次的命令**，
  不会静默假装改成功了。
- 除此之外全文没有第二处提权：worker、面板、看门狗、CLI 全部跑在你的标准令牌上。README 里逐项列了
  15 个 P/Invoke 调用，都在非提升令牌上实测跑通。

**合盖动作是这台机器上唯一的"会被别的程序读到"的系统级改动**（电源计划属性，AC/DC 两档）。它自带备份
（`%ProgramData%\KeepAwake\ka-lid-backup.json`），`restore` 能还原，面板"合盖预报"会用事件日志告诉你
**写了 ≠ 平台遵守**：改完之后是否真的没睡，看证据不看承诺。

## 它在系统里留下什么

| 面 | 实际做的事 |
| --- | --- |
| 注册表 | **只读三处**：`HKLM\...\Control\Power` 的 `HibernateEnabled`、`HKLM\...\Policies\System` 的 `InactivityTimeoutSecs`、`HKLM\...\CurrentVersion` 的 `CurrentBuildNumber`。全文没有 `Set-ItemProperty` / `New-ItemProperty` / `reg add`。**不改任何策略**。 |
| 电源计划 | 默认**不改**。`powercfg` 只用于读取；`lid apply` 是唯一写入路径，需要管理员、自带备份。 |
| 内核电源请求 | `SetThreadExecutionState`，**进程作用域**——worker 退出即消失，重启即消失，不会残留在系统里。 |
| 计划任务 | `ka.bat guard` 注册 `KeepAwake-Logon` / `KeepAwake-Guard`（当前用户范围，标准账户可装）；`-Boot` 额外注册 `KeepAwake-Boot`（需管理员，实测标准账户 `Access is denied`，此时给一行明确拒绝而不是假绿）。`ka.bat unguard` 删除。 |
| 服务 / 驱动 / 启动目录 / Run 键 | 无。 |
| 文件 | 只有 `%LOCALAPPDATA%\KeepAwake`（可用 `KA_DATA` 改）和 `%ProgramData%\KeepAwake` 两个目录，逐文件清单见 [PRIVACY.md](PRIVACY.md)《东西写在哪儿》。这些文件**不是机密**，别同步进云盘。 |

## 没有代码签名

v1.0 **不做 Authenticode 签名**，这是明确的产品决定，不是没做完。后果写在这里：

- **SmartScreen**：下载来的 `.zip` / 安装器带 Mark-of-the-Web，首次运行会弹"Windows 已保护你的电脑 →
  仍要运行"，浏览器也可能提示"典型的下载文件/不常见"。这是未签名软件的正常表现，与代码是否有问题无关。
- **杀软**：`SendInput` 合成输入 + `Add-Type` 现场编译 C# + 无签名，是"鼠标连点器/jiggle 类"工具的共性
  特征，存在被误报的可能。遇到拦截请核对你手上的哈希（见下）后做排除项，**不要**从来路不明的镜像下载。
- **你能用什么来判断完整性**：每个 release 附 `SHA256SUMS`。发布产物由 CI 在 tag 上构建并给出哈希
  （产物名约定为 `KeepAwake-<版本>-windows-x64.zip` 与对应的 per-user 安装器），你可以在本机自己算一遍比对：

  ```powershell
  Get-FileHash -Algorithm SHA256 .\KeepAwake-1.0.0-windows-x64.zip
  ```

  签名解决的是"这个 exe 是谁编译的"，哈希解决的是"这个文件和我下载的那份是否一致"。v1.0 只给后者。

- **不要相信的东西**：任何声称"官方中文版安装包"的第三方站点、任何要求你先关 Defender 再安装的说明、
  任何 `.exe` 而不在 `SHA256SUMS` 里能对上号的产物。

## 运行环境：Constrained Language Mode

`ka-gate.ps1` 的 `Test-KaLanguageMode` 在 CLM / AllSigned 策略下**直接拒绝启动**（退出码 2），并指一段
README 给你看原因。**这是安全设计**：`Add-Type` 在现场编译 C#，CLM 下这条路径会被拦，而一个"部分功能
静默失效"的防休眠工具比一个明确拒绝启动的工具危险得多——它会让你在以为受保护的状态下把机器睡掉。
WDAC / AppLocker / Smart App Control 环境因此用不了本工具，这一点写在 README 的适配矩阵里。

## 依赖与供应链

**零第三方依赖**：只有 Windows 自带的 PowerShell 5.1、`powercfg` 与 .NET Framework 类型。
没有运行时下载、没有包管理器、没有 CDN、没有子模块。审计面就是仓库里那几个 `.ps1` 和 `dashboard/`。

## 支持哪个版本 / 怎么报问题

- 只修**最新版**。复现前请先确认你在最新 release 上，并附上 `ka.bat report` 的输出
  （**注意**：它含你的用户名、目录名和 Windows 版本字符串，贴到公开 issue 前请自行打码）。
- 报告渠道：本仓库 GitHub 的 **Security → Report a vulnerability**（私有漏洞报告）。
  在补丁发布前请不要公开利用细节，也不要开普通 issue。
- 什么算问题：面板头规则可被绕过、非回环前缀能被绑上、任意路径文件读取、`lid apply` 之外的注册表/策略
  写入、状态撒谎（明明没在保护却显示在保护）。
- 什么不算问题：本工具不做认证（它不是服务）、同一用户下的进程可以改它的文件、
  SmartScreen 对未签名产物的提示（见上节，这是明确决定）、以及 Win+L / 安全桌面这类系统安全机制压不住。
