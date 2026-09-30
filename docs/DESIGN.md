# 设计与不变量（Design & Invariants）

给改代码的人：**边界、不变量、决策记录**。产品能力与用法在 `README.md`；逐文件的局部理由在各文件头；
踩过的坑在 `PITFALLS.md`。这里只写"跨文件、且破了就要出事"的那些东西。

## 设计目标（按优先级）

1. **远程无人值守**：人不在键盘前时，机器别睡、屏别黑、会话别锁，且**断电重启后自己回来**
   （`intent.json` + 两个计划任务）。这是它存在的理由，其它特性都排在它后面。
2. **有效性必须能被本机证实**：读内核电源日志数 506/507，而不是说"我已经调用了 API"。
   同类工具都把"调用了 API"当结论，因此它们答不出"昨晚到底睡没睡"（`docs/RESEARCH.md`）。
3. **下载即用、零依赖**：只要求系统自带的 PowerShell 5.1，不联网、不装服务、不注册驱动、
   不需要管理员（唯一的例外是改合盖动作）。
4. **说清做不到什么**：锁屏由组策略强制、显式熄屏、用户按键睡、合盖——做不到就写在界面上，
   不用模糊词盖过去。这条是产品约束，不是修辞：`README.md` 的《能力边界》《适配矩阵》两张表就是它的产物。

## 模块边界（谁做什么、尤其**不许**做什么）

| 文件 | 职责 | 不许做的事 |
| --- | --- | --- |
| `ka.bat` / `on.bat` / `off.bat` / `panel.bat` / `tray.bat` | 双击入口，纯转调 `ka.ps1` | 不含任何业务逻辑（内容纯 ASCII，只做 cmd→PowerShell 的转接） |
| `ka.ps1` | 命令行入口：参数解析、调用、把人话渲染出来 | 不实现业务逻辑；语言只影响**措辞** |
| `ka-core.ps1` | 共享库，也是**唯一**写状态文件、起进程、调原生电源 API 的地方 | 不做界面；不接受 argv；不假定调用方是 CLI（面板与托盘共用它） |
| `ka-worker.ps1` | 保护本体：独立进程 + 命名互斥体，持续持有电源请求，按间隔发心跳 | 不改 `config.json`/`intent.json`；只写 `state.json` 与 `ka.log` |
| `ka-guard.ps1` | 看门狗：计划任务的载体，只做 `intent` ↔ 实况**对账** | 不把 `intent=off` 的保护自作主张开回来；不写 `intent.json` |
| `ka-server.ps1` | 本地 HTTP 面板（`HttpListener`，只监听回环） | 不直接实现电源逻辑（调 `ka-core` 的同一套函数）；不监听 `0.0.0.0`；GET 永不改状态 |
| `ka-lid.ps1` | 合盖动作的读/改/还原，**唯一**需要管理员的路径 | 改之前必须先把原值备份进 `%ProgramData%\KeepAwake\ka-lid-backup.json` |
| `ka-tray.ps1` | WinForms 托盘图标，右键菜单起停 | 不自己发电源请求（同样只调核心函数） |
| `dashboard/*` | 面板前端：原生 JS，无框架、无 CDN、无构建步骤 | 不引入外部资源；所有副作用走 `POST` 且带 `X-Ka-Client` |
| `tests/*` | 门禁与实测探针 | **不许**在正在使用的机器上动电源设置/计划任务（CI 的一次性 runner 才是它们的家；两个例外在 `README.md` 写明并需显式开关） |
| `packaging/*` | 出 zip / staging / `SHA256SUMS` / `setup.exe`，以及真装真卸 | build-time only，不进便携包 |
| `_legacy/*` | v2 之前的实现，原样归档 | 不参与构建、不进清单、不被现行代码引用 |

一句话版本：**状态与进程的写方只有 `ka-core.ps1`；`ka.ps1`/面板/托盘都只是它的三个界面。**
所以"同一个问题在命令行和面板上有两种答案"是结构上不可能发生的——它们读同一个函数。

## 进程与数据布局

| | 位置 | 里面有什么 | 谁写 |
| --- | --- | --- | --- |
| 程序 | 脚本所在目录 | `.ps1` / `.bat` / `dashboard/` | 只有打包与升级 |
| 数据（按用户） | `%LOCALAPPDATA%\KeepAwake`（`KA_DATA` 可改） | `config.json`、`intent.json`、`state.json`、`ka.log`(+`.1`)、`machine.json`、`.server-<端口>.json`、`stop.flag`、`.migrated.json` | 运行中的进程 |
| 数据（按机器） | `%ProgramData%\KeepAwake` | `ka-lid-backup.json`（合盖动作原值，全机设置） | 只有 `lid apply` |

进程之间**不靠 PID 文件通信**：谁活着由"进程命令行里的 `-DataDir` + 创建时间"判定，
面板另有按端口一份的句柄文件兜底。细节与实测在 `README.md` §架构。

## 不变量（破了就要出事；每条都有东西在守）

| # | 不变量 | 为什么 | 谁在守 |
| --- | --- | --- | --- |
| INV-1 | 单实例锁的是**数据根 + 用户 SID**（`Local\KA-<角色>-<hash>`），不是安装目录 | 一份 `state.json`/`stop.flag` 天然只属于一个 worker；同一用户复制两份目录必须撞锁而不是留下两份谁也停不掉的请求 | `ka-worker.ps1` 启动路径；`tests/probe-mutex-identity.ps1` |
| INV-2 | 归属判定（谁是我的人）以**数据根**为主键，程序目录只作兜底 | 认程序目录会让一个只改了 `KA_DATA` 的脚本停掉别人的面板（2026-09-27 真发生过） | `ka-core.ps1` 的 `Get-KaServer`/`Get-KaWorker`；`tests/probe-server-hint.ps1` 第 6–9 条 |
| INV-3 | **程序目录只读**：跑完不在里面多一个文件 | 目录可替换、可覆盖升级；状态不跟着程序走 | `packaging/build.ps1 -Smoke` 每轮复检；`tests/probe-build-selftest.ps1` |
| INV-4 | 所有 JSON 写入是 write-then-move | 读方永远看不到半截文件 | `ka-core.ps1` 的写 JSON 路径 |
| INV-5 | `ka.log` 与 `state.json` 里**只有 ASCII 机器标记**，语言只换措辞 | 换语言不改行为；日志可 grep；测试可以从发出端查三本词典的覆盖 | `tests/ka-tests.ps1`（词典覆盖面）；`PITFALLS.md` §二 第 10 条 |
| INV-6 | 每个**入口脚本自己的顶层**有 CLM 闸门（`if (-not (Test-KaLanguageMode)) { exit 2 }`） | `exit N` 在 dot-source 的文件里不中断调用方 | `ka-gate.ps1`；`tests/probe-clm-gate.ps1` |
| INV-7 | 面板只回环 + Host/Origin 固定 + `/api/*` 要 `X-Ka-Client` | 任意网页都能向 `127.0.0.1` 发请求，"只在本地"不等于安全 | `ka-server.ps1`；`tests/ka-tests.ps1` 的面板用例 |
| INV-8 | 发布清单**从仓库树推导**，根目录每个文件都必须被某条规则认领 | 手敲的清单只会以一种方式坏：文件在仓库里、不在清单里，于是它从来不在 release 里（`favicon.svg`） | `tests/ka-release-files.ps1`（认领规则会 throw）；`tests/probe-build-selftest.ps1` |
| INV-9 | 每条断言必须有一条**能把它弄红**的注入腿 | 只绿过的东西不能证明什么 | 各 `tests/probe-*-selftest.ps1` |
| INV-10 | `.ps1` = BOM + LF；`.bat`/`.cmd`/`.iss` = CRLF 无 BOM 纯 ASCII | 5.1 用 ANSI 码页解码无 BOM 脚本；cmd/ISCC 会印出 `ÿþ` 或乱码 | `tests/ka-encoding.ps1`（发出去的每个文本文件） |

## 决策记录（含**被否掉**的方案）

格式：决策 → 被否的替代 → 为什么 → 证据。被否的部分留着，是为了下次有人提同样的方案时不必重新吵一遍。

| # | 决策 | 被否的替代 | 为什么 | 证据 |
| --- | --- | --- | --- | --- |
| DR-1 | 程序目录与数据目录分离 | 状态写在脚本旁边（v1 的做法） | 解压即可用、目录可整体替换；`%LOCALAPPDATA%` 才是你的选择该待的地方 | 迁移路径与"现有文件永不覆盖"写在 `README.md` §东西写在哪儿 |
| DR-2 | 面板/worker 归属按**数据目录**认 | 按程序目录认领 | 事故：2026-09-27 一个只改 `KA_DATA` 的临时脚本的 `stop-server` 把用户自己的面板停掉了（`ka.log` `SERVER EXIT pid=28208`） | `tests/probe-server-hint.ps1` 第 6–9 条 + 自检的四种突变各自弄红 |
| DR-3 | 一条腿的"留口"= **Windows Job 对象 ∪ 带两条守卫的 pid→ppid 重建** | ①只用 pid 重建 → 四种假红（office 套件、本机 worker、`CompatTelRunner`、一整批维护进程）②只用 Job 对象 → 看不见 `UseShellExecute` 起的进程（浏览器交接就是这种形状）③只取两者交集 → 漏掉重建独有的那只 | 两个源各有盲区且**不重叠**；交集会把真实留口过滤掉 | `README.md` §一条腿的"留口"该怎么认；`tests/ka-procwalk.ps1` + `probe-ci-harness.ps1` |
| DR-4 | 双引擎：电源请求 + 防锁屏心跳 | 只用 `SetThreadExecutionState`；或只用合成输入 | 两个**不同的**空闲计时器：SETS 管睡眠/熄屏，锁屏由输入空闲决定，SETS 官方明说它不阻止屏保 | `docs/RESEARCH.md` §一手来源 |
| DR-5 | `awayMode` 默认**关** | 默认打开 Away Mode | 官方说便携机不应启用（它反而阻止真正省电），且本机从没跑过对照实验（用户决定不停掉手上的保护） | `PITFALLS.md` §四；`README.md` §能力边界 |
| DR-6 | 普通账户即可，不做 Windows 服务、不装驱动 | 装成服务/S4U 常驻 | 服务要管理员、要安装动作，与"下载即用"冲突；`S4U` 只在可选的 `KeepAwake-Boot` 里提供并写明代价 | `README.md` §硬事实 的"权限"行、§断电自恢复链 |
| DR-7 | v1.0 **不做代码签名** | 买证书、签名 | 测 AV/SmartScreen 要上传样本，不是本机可逆动作；改用"每版附 `SHA256SUMS`"回答"这份文件是不是他发的那份" | `SECURITY.md`；`PITFALLS.md` §四 |
| DR-8 | 心跳默认 **F15 按键**（`antiLockMethod='key'`），鼠标是选项 | 默认合成鼠标移动 | 键盘路径对多数场景更轻、更少被当成"连点器"特征；两种都留成配置项 | `ka-core.ps1:635`（默认值真源）；`README.md` §配置 的 `antiLockMethod` 行 |
| DR-9 | 不联网、不上传、不检查更新 | 遥测 / 自动更新 | 隐私面为零是可验证的承诺，也是它敢被下载的理由 | `PRIVACY.md`；`tests/ka-privacy.ps1`（含"隐私门禁真的会红"） |
| DR-10 | 维护者文档（本目录）**不进便携包** | 把 `docs/**` 加进发布清单 | 根目录规则是"根部文件都会被认领、被认领的就进 zip"；下载者要的是产品不是维护笔记 | `tests/ka-release-files.ps1` 的认领规则；`docs/README.md` 末节 |

## 明确不做的事（写下来，避免被当成遗漏）

- 不接管锁屏（组策略/屏保强制锁屏时如实降级并说明）。
- 不阻止用户主动睡（合盖、电源键）——那是 `lid apply` 的领域，且默认不动。
- 不做跨机器同步、云账号、遥测。
- 不提供可复现构建（zip/`setup.exe` 里嵌构建时刻），因此哈希只回答"是不是同一份"。
- 不替用户做"该不该保护"的判断：`intent.json` 是你说的，看门狗只对账。
