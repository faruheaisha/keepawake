# 更新日志 / Changelog

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循
[语义化版本](https://semver.org/lang/zh-CN/)。

**版本号的唯一真源是 `ka-core.ps1` 里的 `$script:KaVersion`**，面板页脚、托盘提示、`/api/state`、
`.migrated.json` 都读它。仓库**不放** `VERSION` 文件——两份版本号一定会漂移。CI 在打 tag 时比对
`KaVersion` 与 tag，不一致就构建失败。

## [未发布]

- **留口归属的 0 号哨兵：`[long]$null.Ticks` 是 `0`，而且不抛**（2026-09-30）。CI run `36679927952`（一个**只改了
  文档**的提交）红在 "Gates and probes" 步：`FAIL probe-server-hint-selftest.ps1 371s left 11 descendant(s) alive:
  4224:updater.exe, 4256:svchost.exe, …, 8844:TrustedInstaller.exe, 9712:CompatTelRunner.exe, 10160:svchost.exe`，
  而同一次运行里被点名的探针自己刚打印过 `PROBE OK`。文档改不动行为，所以这是 09-29 那条归属 bug 的**残留分支**：
  采样那一行 `try { $Born[$id] = [long]$r.CreationDate.Ticks } catch { }` 读起来像"读不到就跳过"，实际 PS 5.1 对
  `$null` 求 `.Ticks` 给 `0` 且不抛，于是 runner 上以标准令牌查不到 `CreationDate` 的镜像（`TiWorker.exe`、
  `TrustedInstaller.exe`、`svchost.exe`）被记成"创建于 tick 0"。两条守卫随后一起失效：`ContainsKey` 是 true
  （键在），"现在这个 pid 还是不是那个进程"是 `0 -ne 0`（false）——pid 回收守卫被整段跳过，一条 6 分钟腿的名单里
  冒出 11 个与它无关的系统进程。**修法两处**：只在 `$t -gt 0` 时才写进 map；步行的第二层守卫改成"**活着就必须可证**"
  ——pid 现在活着而当前创建时间读不出来，**停走**而不是跳过比较。本机实测 334 行 CIM 里 0 行没有 `CreationDate`
  （`_tmp/procwalk-cim-timing-20260930.txt`；这个行数每轮都不同，要紧的是那个 0），所以
  这个形状在本机只能靠"喂给采样器一行没有 `CreationDate` 的行"来演（`& { function Get-ProcessRows { … } }`，只在
  块内生效），runner 上它才是自然的。`tests/probe-procwalk.ps1` 加了第 ⑥ 条的两个用例与第 ⑨⑩ 两条注入腿，各自
  把这两条规则钉红；`PITFALLS.md` 的 PowerShell 陷阱表因此从 20 条变 21 条。这次修复没有改产品代码。
  验证：本机 `tests\ka-ci.ps1 -Gates -Probes` 整步 28 行 0 红（15:08:40→15:29:54，`_tmp/ci-local-procwalk-fix.log`）；
  三个改过的文件在冻结字节上另补跑一轮门禁 + 三个探针，各 0 红（`_tmp/postfreeze-rerun-20260930.log`）。

- **知识层里一条对比断言写反了：`$null -eq 0` 是 `FALSE`（`$null -ne 0` 才是 `TRUE`）**（2026-09-30）。`PITFALLS.md`
  第 13 条旧文（"`$null -eq 0` 是 `TRUE`；未赋值的退出码读起来像成功"）两个错：方向反了；"读成成功"的机制其实是
  **转换**——`[int]$null` 是 `0`（正是上一条 0 号哨兵的另一半），不是比较。这句话从知识层流进过三处注释：
  `ka-core.ps1` 判"回到活动会话"的 `$null -ne $Evt.to`（**语义本来就对**，只有括号里的理由写反了：真语义下
  `$null -ne 0` 为真，所以按值比较 `($Evt.to -ne 0)` 才会"缺字段放行、真 0 跳过"，正好反）、
  `packaging/ka-test-install.ps1` 两处（超时返回显式 `$null` 的判据、`$null` 先查的理由）——三处注释与
  `PITFALLS.md` 本条一并改成实测事实，`CHANGELOG` 1.0.0 段落里同源的旧句就地加了更正标注。**行为零变化**：
  `tests/ka-tests.ps1` 的独立重算（`$null -eq $s.to` 跳过、值 0 重置 `lastScreenOffEpoch`）与产品判据在真语义下
  本来就一致，这轮只动注释与文档。全矩阵（含 `AutomationNull`、哈希缺键、`0 -eq ''` 是 `TRUE` 的空串对照）：
  `_tmp/null-semantics-20260930.txt`。
  验证：本机 `tests\ka-ci.ps1 -Gates` 5 行 0 红（`_tmp/gates-nullfix-20260930.log`）。

- **`ExitCode` 这一族的机制第三次定稿：决定它的是**启动开关**，不是读的位置**（2026-09-30）。这一格改过两版、
  两版都不全：09-26 说"不等待的对象孩子一走就回 `$null`"（只对带开关的形状成立）；09-30 的第一次更正说
  "静默 `$null` 来自读得太早、孩子退出后读回真实码"——那一版在复跑时把**开关**这一维丢了（跑的是裸形状），
  结论作废。全矩阵（cmd 与 powershell 两种孩子）：**孩子还在跑** → 任何形状都静默 `$null`（`[int]$null` 是 `0`，
  于是"还在跑"记成"退出 0"）；**你自己等过之后**（轮询 / `WaitForExit()` / `WaitForExit(ms)`）——启动带
  `-NoNewWindow` 或 `-RedirectStandardOutput`/`-RedirectStandardError` 任意一个 → 仍是静默 `$null`，
  `HasExited=True` 也一样，`Refresh()`、再等一次都救不回来（进程已消失，那个码不可追回）；三个都没带 → 真实码
  （`-WorkingDirectory`、`-WindowStyle Hidden` 单项实测不影响）；PowerShell 的 `-Wait` 在任何形状下都给真码；
  `[Diagnostics.Process]::Start` 也给真码。证据：`_tmp/exitcode-switch-matrix-20260930.txt`（T1–T10）、
  `_tmp/exitcode-switch-verify-20260930.txt`（V1a–V2d 直线复跑）、`_tmp/exitcode-switch-recheck-20260930.txt`
  （第三次独立驱动，两轮全格一致）、`_tmp/exitcode-switch-pin-20260930.txt`（W1/W2/W4/W5/W6/W7）、
  `_tmp/exitcode-redirect-iso-20260930.txt`（S1–S5）、`_tmp/exitcode-refresh-20260930.txt`（R1–R7 排除 `Refresh()`）。
  09-26 那张等待表前两行的 `$null -> 0` 与幸存的 `_tmp/exit-semantics-rerun.log` B/C/C2 行由此得到解释而不是被
  推翻：那批形状要收回孩子的文本，带的就是 `-NoNewWindow`（`marker-in-log=yes` 本身就是这个证据）；此前那版
  "读得太早"的差分虽然也能造出同一对值，但解释不了那批行，能同时解释两边的只有开关这一维。被改的知识位点：
  `PITFALLS.md` 第 2 条（第三次改写，含 `ExitTime` 这一支）、`tests/ka-ci.ps1` 头部两段（表下的结论句 +
  `cmd`+判定文件一段的理由；设计不动）、`tests/probe-bat-entry.ps1` 事实 1 与 `Invoke-Cmd` 注释（"那个 0 没复现"
  的结论作废——它把开关丢了）、`tests/probe-native.ps1`（那条"读落在轮询之后所以是真的"的注释是反的：该形状
  读不出来，判据只剩孩子自己印的标记）、`tests/ka-procwalk.ps1` 注释（"退出后 `ExitCode` 读回真实码"对
  `-NoNewWindow` 形状不成立）、`tests/probe-ci-harness.ps1` 注释、`tests/probe-server-hint.ps1` 删掉那个永远读
  `$null` 的死 `Exit` 键（无人消费，留着只会坑下一个读代码的人）、`README.md` 探针表两行、`CHANGELOG.md` 1.0.1
  段落两处就地更正。产品代码零变化。
  验证：本机 `tests\ka-ci.ps1 -Gates` 5 行 0 红（`_tmp/gates-exitswitch-20260930.log`）。

- **清 `_tmp/` 的保留名单规程与引用面不等宽：只扫了文档层，漏掉 `tests/`**（2026-09-30，纯文档与注释）。
  `PITFALLS.md` §五 当日清库的规程只 grep README/CHANGELOG/PITFALLS/docs，于是**只在** `tests/ka-ci.ps1`
  头部被点名的两条取证 `_tmp/ws-outer.log` / `_tmp/ws-outer2.log`（`-Wait` 按活口形状阻塞那次实验的原始日志）
  没进保留名单、如今已不在盘上；规程改成 `git grep` 扫**全部入库文件**（§五内更新，含 `tests\*.ps1`），
  `ka-ci.ps1` 那两处如实标注 "gone from disk"、表下数字原样保留为存活记录。教训：**保留名单的 grep 范围
  必须盖住引用的生长面**——引用长在注释里，扫描只到文档，就等于没扫。
  验证：本机 `tests\ka-ci.ps1 -Gates` 5 行 0 红（`_tmp/gates-tmpkeep-20260930.log`）。

- **核对仓库里被引用的每一个 CI run/job id**（2026-09-30，纯文档）。从 README/PITFALLS/CHANGELOG/docs/tests
  里提取全部 9 位以上的数字共 23 个，逐个 `gh api` 复查：全部可解析，且语义与引用一致（红/绿/取消都对得上）。
  唯一的表面矛盾是 `36440936247` 读出 `cancelled`——它是 `run_attempt=2`：第一次 attempt 正是 `CHANGELOG` 记的
  那次 1 red，第二次（`gh run rerun --failed`）被并发规则取消，run 级结论因此显示后者。据此给 `PITFALLS.md`
  §三 加一条"`conclusion` 是最后一次 attempt 的"，免得下一个读日志的人把 `cancelled` 当成"没红过"。
  证据：`_tmp/runid-audit-20260930.txt`（23 个 id 的 attempt/conclusion/sha 逐行）。
  验证：本机 `tests\ka-ci.ps1 -Gates` 5 行 0 红（`_tmp/gates-runidaudit-20260930.log`）。

- **核了一遍文档里的 `file:line` 引用**（2026-09-30，纯文档）。40 个引用逐个解析：文件全在、行号全在范围内；
  逐行比对后 39 个落点与引用说法一致——包括 `ka-lid.ps1:280`，那指的是**突变体**里的行号：2026-09-30 重跑
  `_tmp/check-log-ascii-rule.ps1`，13 条腿全对，它自己印出 `ka-lid mutant sits at line 280`（该行由
  `Add-KaLog "LID restore …"` 锚点算出，锚点如今在 `ka-lid.ps1:279`），不是笔误。1 个落空：
  `ka-release-files.ps1:16` 那张当年手打的文件清单已被树推导取代、该行成了空行，已在原句就地标注。
  核法写进 `PITFALLS.md` §五。
  输出与逐行内容：`_tmp/fileref-audit-20260930.txt`、`_tmp/logascii-rerun-20260930.log`。
  验证：本机 `tests\ka-ci.ps1 -Gates` 5 行 0 红（`_tmp/gates-fileref-20260930.log`）。

- **那个漏改的"当前数字"：README 的探针数还写着 22**（2026-09-30，纯文档）。同一段里已经解释了"数的是文件名"
  这类数数法的坑，也都还是对的（`ls tests/probe-*selftest*` 是 7、会自己注入缺陷的探针 10 个、带 `-SelfTest`
  开关的 2 个：`probe-native` 与 `probe-bat-entry`），唯独 `tests/probe-*.ps1` 那一行的 22 没跟上——
  `probe-procwalk` 09-29 落地，`ls tests/probe-*.ps1 | wc -l` 现在是 **23**。改成 23 并写明它是哪一轮变成 23 的。
  同一轮里另外几类引用一并核过：28 条相对链接全部可达（`_tmp/link-audit-20260930.txt`，0 断链）、
  `INV-1…10` 与 `DR-1…10` 的每处引用在 `docs/DESIGN.md` 里都有定义、数字断言（P/Invoke 15 个、84 个 `It`、
  便携包 25 个文件、CLM 门禁发现 6 个入口）逐个对过源码与构建全对。
  验证：本机 `tests\ka-ci.ps1 -Gates` 5 行 0 红（`_tmp/gates-readmecount-20260930.log`）；dist 重建 25 项
  （`_tmp/build-readmecount-20260930.log`）。

- **`PITFALLS.md` 的 `[实测]` 行按它自己开头的承诺查了一遍：附不出的就写明附不出**（2026-09-30，纯文档）。
  文件开头（第 8 行）承诺 `[实测]` = "本机或 CI runner 上真跑出来的，**附可复跑的入口**（探针 / 命令 / 日志）"；
  逐行对下来两类不合格：①**指错了地方**——平台事实表里"显式熄屏会在 5–6 秒内链式真睡"那一行写"`CHANGELOG`
  里记着时间点"，可 `CHANGELOG.md` 里 `SC_MONITORPOWER`、`566`、`15:17` 一个都搜不到，五次观测（08-29 事故、
  08-30 三次 `SC_MONITORPOWER`、08-31 的时间戳实验）只记在 `README.md` 的产品叙述里，已改成指向 `README.md`
  并注明 `CHANGELOG` 没有这份记录；②**只有结论没有入口**——六行 `[实测]` 后面写的是"本机""那次"，复不了。
  能给命令的都补上，并且今天就地跑过一遍：`powercfg /requestsoverride` → exit 0 对 `powercfg /requests` → exit 1
  （标准令牌）；`(Get-ScheduledTask -TaskName KeepAwake-Guard).Xml` 读回 **0 字符**、同一个任务的
  `Schedule.Service` COM 导出 **1777 字符**；`HKCU:\Control Panel\Desktop\MuiCached` 与
  `[CultureInfo]::CurrentUICulture` 两行对峙（即 `tests/ka-tests.ps1` 那条 `auto` 语言用例）；pid 易主看
  `probe-procwalk.ps1` 的那条腿；8.3 短路径的落点是 `packaging/ka-test-install.ps1:276` 按
  `$appSeen.Length + 1` 切相对名那句；需要真注册计划任务的那条（`-AtLogOn` 不带 `-User`）如实写明复读用例在
  `tests/ka-tests.ps1`、**只在 CI runner 上跑**。剩下的三行是**事故记录**（08-29 电池谎报、09-29 pid 回收现场、
  CI 安装器那次），本身不可重放，就地标明"现场读数不可重放"并给出同类读数随取随有的取法。
  验证：本机 `tests\ka-ci.ps1 -Gates` 5 行 0 红（`_tmp/gates-pitfallsevid-20260930.log`）。

## [1.0.1] — 2026-09-30

一个补丁版：一条**会停掉你自己面板**的归属 bug（下面第一条），加上三周来所有"闸门绿着、而它要防的
事正发生在它看不见的地方"的补洞（探针、门禁、发布清单），以及把踩过的坑、调研结论、设计约束与环境依赖
分别沉淀到 `PITFALLS.md` 与 `docs/`。
1.0.0 的可执行行为只在这一条上变了：`stop-server` / `serve` 认面板归属的依据从**程序目录**改成**数据目录**。

- **`PITFALLS.md`：把踩过的坑与调研结论收进仓库**（2026-09-29）。这份文件只放别处没有的东西——平台事实（S0/无 S3、
  `MuiCached` 与 `$PSUICulture` 不一致、受保护镜像不给 `CreationDate`、`pid` 会被回收、Job 管不住"壳起的进程"、
  runner 的 8.3 短路径…）、PowerShell 5.1 与 cmd 的 20 条陷阱（`-Wait` 等的是管道 EOF、空数组返回变 `$null`、
  `$Args` 参数绑不上、`-like` 把 `[ ]` 当字符类…）、CI/门禁的经验（600 秒每脚本、glob 跑探针不带参数、
  `gh` 只认 `GH_TOKEN`、`push` 与 API 通不是一回事），以及产品侧的调研结论（同类工具对比、away-mode 为何默认关、
  锁屏管不住策略锁、不做代码签名）。每条都标注了 `[实测]/[调研]/[推理]` 与可复跑入口。
  它进了发布清单，于是便携包从 **24 变 25 个文件**：本机 `packaging/build.ps1 -Stage -Smoke` 实测 
  `KeepAwake-1.0.0-portable.zip : 25 entries, all present with matching byte lengths, 0.31 MB`、
  `staging: 25 files`，`SMOKE exit=0`；README 里两处**当前**数字跟着改，探针表里引用的历史末行保持原样。

- **`docs/`：把设计、环境依赖、同类调研从"叙述"拆成"可查的条目"**（2026-09-30）。之前这些知识散在两处：
  `README.md` 的架构段与适配矩阵（讲"是什么"），以及源码文件头的注释（讲"为什么"）。散着读没问题，但
  **改之前无从查起**——比如"`ka.ps1` 能不能自己起 worker"这个问题，答案只存在于几个函数体的写法里。
  现在补四份，各自只放一种东西：[docs/DESIGN.md](docs/DESIGN.md) 模块边界表（每个文件**负责**什么、**不许**
  做什么）、数据布局、十条不变量（INV-1…INV-10）、十条决策记录（DR-1…DR-10，**每条都写着被否掉的替代方案
  与否掉它的那次事故**）；[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) 三层依赖（运行时只有 Windows 自带的
  5.1；本机工具链 PS 5.1.26100.9444 / git 2.54.0.windows.1 / Inno 6.7.3 / gh 2.93.0；CI 装 `choco innosetup`）、
  每条命令的**实测**耗时与 600 秒/脚本的上限、以及这台开发机的环境事实；[docs/RESEARCH.md](docs/RESEARCH.md)
  五个同类工具的模式/CLI/星标与**逐条一手来源**（引文可在来源页重新读到），外加"仍然没查清的"；
  [docs/README.md](docs/README.md) 是索引：哪个问题翻哪一份、四条证据规则。
  四份都**不进便携包**——`tests/ka-release-files.ps1` 的根目录认领规则只认**文件**，`docs/` 是个目录，
  所以便携包仍是 25 个文件；这是刻意的（DR-10：下载者要的是能跑的东西，不是设计文档）。
  修 `ka-encoding.ps1` 前先确认新 `.md` 的字节形状：四份都是 LF、无 BOM（与 `README.md` 一致）。
  同一轮抓到一个编排缺陷：`CHANGELOG.md` 的 `[1.0.1]` 段当时写在 `[1.0.0]` **下面**，而文件开头就
  声称遵循 Keep a Changelog（最新在最上面）——读者翻到的是上一版，正是这份文件自己警告的"两份版本号
  互相打脸"。已把 `[1.0.1]` 整段移到最前，`sort` 逐行比对证明只换了顺序、一行没丢。

- **`probe-mutex-identity` 的 C 段栽在"固定等待 + 只看一次"上**（2026-09-29）。run `36545465699` 唯一一红就是它：
  C 段用 `Start-Job` 当名字的持有者，先 `Start-Sleep -Seconds 2` 再看一眼是否被别人拿着。冷 runner 上 `Start-Job`
  两秒内还没把名字建出来，`OpenExisting` 抛异常，而那个 `catch` 只报**包装**类型——PowerShell 把 .NET 异常包成
  `MethodInvocationException`，真正的原因埋在 InnerException 里——于是红字写成"观察坏了"，读起来像产品的毛病，
  实际是 harness 的时序。改法：在持有者**真实的持有窗口**里轮询（最多 20 秒、每 250ms 一次），
  `WaitHandleCannotBeOpenedException`（名字还没建出来）与其它异常分开处理，失败文本带上真正的原因；
  `AbandonedMutexException`（有人持有过又死了）本来就该算"有争用"，现在显式认下。本机平时走"活的 worker"那条路
  （保护正在跑），所以用 scratch 数据根复现了 runner 的那条 holder-job 路，三次全绿
  （`holder job said: got=True ; last observation: none` → `ok OpenExisting ... sees the name as taken`）。

- **留口归属定案：两个源取并集（Job 对象 ∪ 带守卫的重建）**（2026-09-29，#70 收口）。四次假红每次都烧掉一个
  CI 周期，被点名的进程都与被点名的探针无关（而那些探针自己都印着 `PROBE OK`）：`wps.exe`/`wpscloudsvr.exe`
  （office 套件，一条过期的父条目把它算成某一腿的后代）、本机自己的 worker pid 21688、`CompatTelRunner.exe`、
  以及一整批 Windows 维护进程（`TiWorker.exe`、`TrustedInstaller.exe`、`MoUsoCoreWorker.exe`、三个
  `svchost.exe`、`CompatTelRunner.exe`），本机还多一次 `sleep.exe`（**Git 自带的 `sleep`**，由正在旁观的工具链
  拉起）。根都在"用 pid 重建祖先链"：一条 `pid→ppid` 条目只对**写下它时持有该 pid 的那个进程**成立。
  中途两条补丁（比对创建时间；pid 活着却没记下创建时间就停）把 CI 弄绿过一次（run `36528628613`），但
  "中间有一跳已经死了又被人拿过"那一类关不掉。接着试了**只用 Windows Job 对象**（`CreateJobObject` +
  `AssignProcessToJobObject`，事后一次 `QueryInformationJobObject`（`JobObjectBasicProcessIdList`）读成员表：
  精确、与 pid 回收无关、不再需要每 2 秒的采样，超时路径也从 `taskkill /T` 换成 `TerminateJobObject`；
  刻意**不**设 `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`——关句柄不许杀掉留口，留口就是结论）——**被集成探针当场
  否掉**：`probe-ci-harness.ps1` 那个故意的 GUI 留口是夹具用 `Diagnostics.Process` + `UseShellExecute` 起的
  （浏览器交接就是这种形状），**它继承不到 job**，于是 CI 上 `our own look: 1 alive: 5216` 而 runner 报
  `ok ka-d-leak.ps1 3s / ----- 1 run, 0 red`（run `36534077753`）；而重建恰好看得见它（历史里记着当时那个脚本
  是它的父亲）。所以定案是**两个源的并集**：job（精确，但那类看不见）∪ 带两条守卫的重建（看得见那类，但需要
  守卫），再过滤年龄窗与 `conhost.exe`/`OpenConsole.exe`。并集是刻意的：任一源缺失都只会让报告比真相**小**，
  不会把无关进程平白算进来。重建那条守卫本轮又补深一层：**跟着走的每一跳都必须有记下来的创建时间**——没采样过
  的 pid 等于对它一无所知，停在那里而不是顺着它记录的父进程往上爬（本机 `sleep.exe` 那一支就是这么进来的）；
  而**采样过**的死跳照旧走通，因为 shell 起的那类留口的父亲就是那一腿自己的脚本（活着、被采到过），所以那一类
  仍然看得见。至此留口归属里被观察到过的假红机制全部关掉，两条规则各自有自己的注入腿
  （`probe-procwalk` 的第 7、8 条）。`Assign` 与 `Query` 任何一步失败都**抛错**而不是当红腿——否则后面每个答案
  都是猜的，
  而"猜着还过了"正是这一轮花四轮在删的那个失败模式。集成那一半仍由 `probe-ci-harness.ps1` 把关：它那两个
  **故意**漏进程的夹具必须照样被点名（否则就是拿假红换了假绿）。
  过程中被自己的两个陷阱咬到并记下：①**空数组从函数返回会扁平化成 `$null`**，于是"这一腿什么都没留"（最常见的
  健康情形）看起来和"查询失败"一模一样——第一版包装就这么在每一腿上抛错；现在包装返回 `@{ Ok; Pids; Err }`，
  `Ok` 显式给出，绝不从值去猜（`tests/probe-procwalk.ps1` 也据此加了断言）。②两个 sweep 同时跑会共用
  `_tmp/probe-server-hint-mutant.ps1`，先结束的那个把它删掉，另一个的三条臂随即以
  `The argument ... to the -File parameter does not exist` 报红——那是"别在两次 sweep 之间共用文件名"这条
  老账，这次真的付出了一次；该突变文件名现在带 `$PID`。

- **留口归属第三次加固：pid 被易主时不许顺着旧条目往上爬**（2026-09-29，#70）。两次 CI 假红逼出来的：
  run `36440936247`（只改文档）把 `4344:CompatTelRunner.exe` 算成 `probe-encoding-selftest` 的留口，
  run `36443663108` 把 `3408:svchost.exe` + `7544:CompatTelRunner.exe` 算成
  `probe-server-hint-selftest` 的留口——两次里**被点名的探针自己都印着 `PROBE OK`**，被点名的是 Windows 的
  兼容性遥测进程和它的服务宿主，与探针毫无关系。年龄窗排不掉它们：它们确实出生在那一腿的窗口内，所以错不在
  窗口，而在那段"从每个活进程往上爬 `pid→ppid` 历史"的走法——一条条目只对**写下它时持有该 pid 的那个进程**
  成立，当一个别的进程现在拿着这个 pid，顺着它往上爬会把两段无关的祖先链缝在一起，链条凭巧合落到这一腿的
  cmd pid 上（同一段 walk 的注释里已记着前两次同族加固：office 套件、本机自己的 worker）。本轮落地的是**守卫**：
  爬之前比对该 pid 的创建时间（记条目时记下的 vs 现在活着的那个），不是同一个进程就**停**，而**死的尾巴照旧
  回落到历史**——那正是这份历史存在的理由。形状上：那段 walk 从 `ka-ci.ps1` 抽成 `tests/ka-procwalk.ps1`
  （`ka-ci.ps1` 从 `$PSScriptRoot` dot-source 它；第一版用 `$here`，被 `probe-ci-harness.ps1` 当场抓住——
  `-Dir` 指向一次性夹具时 `$here` 是夹具目录，那里没有这个库），并新增 `tests/probe-procwalk.ps1`：用手写映射
  直接驱动那个库，五条腿加一条注入——完好链条要点名、同一条目但 pid 已易主必须**不**点名（就是 CI 那次假红）、
  pid 活着却没记下创建时间也必须**不**点名（第二条规则，见下）、中间有死跳的链仍要走通（守卫不许把真留口的死
  尾巴一并砍掉）、年龄窗照旧分内外、以及**把守卫从库副本里删掉那一份必须红在第 2 条上**（本机整条 3.5 秒）。`probe-ci-harness-selftest.ps1` 的突变副本现在连同这个库一起
  放进自己的目录：副本单独躺在 `_tmp` 里会加载不到库，对照腿就会为一个与破坏无关的原因变红。
- **守卫的第二条规则，同一天由 CI 逼出来**（2026-09-29）。上面那版守卫只比对"**拿得到**的创建时间"，等于对
  CIM 不给 `CreationDate` 的镜像（`TrustedInstaller.exe`、`TiWorker.exe` 这类受保护进程）完全不设防：push 上去
  的第一版（`fb34aa9`，run `36457582818`）仍以 `----- 28 run, 1 red` 收场，那一红是
  `RED probe-server-hint-selftest.ps1 returned but left 7 process(es) alive: 2340:TiWorker.exe, 4740:svchost.exe,
  5968:TrustedInstaller.exe, 6276:CompatTelRunner.exe, 6684:MoUsoCoreWorker.exe, 8532:svchost.exe,
  8996:svchost.exe`——一次 Windows 维护突发整批算成了那条 435 秒腿的留口。规则补成"**一个 pid 活着、却没有
  记录过创建时间，就停**（无凭据不跟随）"，并给探针加了第 5 条腿手工构造这个形状。**仍然没关掉的是**"链条
  中间有一跳已经死了、那个 pid 又被别人拿过"（本机 `sleep.exe` 那次），正解是构造性标记（每腿跑在自己的
  Windows Job 对象里，事后问 job 要成员表，见任务 #70）。
- **这个守卫不是全部，而显而易见的修法被实测否掉了**（2026-09-29，#70 继续）。
  守卫只能比对**活着**的 pid，
  所以"链条中间有一跳已经死了、那个 pid 又被别人拿过"仍然能在两条无关的祖先链之间搭桥——本机那次
  `10260:sleep.exe` 假红就是这一支（`sleep.exe` 是 Git 自带的 `sleep`，由正在旁观的工具链拉起）。于是把"只认
  运行期间被现场观测到的后代、与重建取交集"真做了一遍并测掉：**它把 `ka-f-ghost` 那条故意的控制台留口漏掉了**
  ——那个夹具起的进程在 1 秒内就被抛下，2 秒一次的采样看不见它——日志里留下
  `info ka-f-ghost.ps1 1s dropped 1 reconstruction-only candidate(s): 15036:powershell.exe`，紧接着
  `probe-ci-harness.ps1` 变红（`left 1 process(es) alive` 那条期望落空），`TARGETED2 exit=1`。也就是说：任何
  "只认观测"的规则会把**这个功能存在的理由**（抓住快速被抛下的留口）一起丢掉，所以已回退，交集那一版没有留下。
  剩下的正解是**构造性标记**而不是 pid 考古：让每一腿跑在自己的 Windows Job 对象里，事后直接向 job 要成员表
  （`QueryInformationJobObject` 的 pid 列表 / `IsProcessInJob`），孩子自动入 job、与被回收的 pid 无关；这件事
  记在任务 #70 里，连同"守卫前后各有哪些假红"的实测。

- **一次假红：`ka-ci` 的留口归属把一个系统进程算成了探针的后代**（2026-09-28，观测，未修）。run
  `36440936247`（只改文档的 `71b5b4d`）以 `----- 27 run, 1 red` 结束，那一红是
  `RED probe-encoding-selftest.ps1 returned but left 1 process(es) alive: 4344:CompatTelRunner.exe`——
  而那个探针自己印的是 `PROBE OK`。`CompatTelRunner.exe` 是 Windows 的兼容性遥测进程（由系统计划任务
  拉起），与探针没有任何关系。年龄窗排不掉它（它确实出生在这一腿的窗口内），所以错判只能来自那段
  "从每个活进程往上爬 pid→ppid 历史"的走法：`$History` 每 2 秒按当时的值重填、从不做代际校验，一个
  在一次 ~20 分钟运行里被回收的 pid 可以让链条凭巧合落到这一腿的 cmd pid 上。`ka-ci.ps1` 那两处注释
  已经记着同一类的两次加固（wps/office 套件、本机自己的 worker），conhost/OpenConsole 是明着跳过的。
  **代价是一个完整的 CI 周期**——这一步红的语义就是"产品或测试错了"，而这次两者都对。`gh run rerun --failed`
  没能给出可复现性：那次重跑被同一个 ref 上更新的推送按并发规则取消了，但**下一个推送的 run
  `36443663108` 又红在同一种形状上**（`svchost.exe` + `CompatTelRunner.exe`），所以它不是偶发。修法与它自己的
  红都落在上面那条（2026-09-29，#70）。

- **`probe-native` 的突变腿不再藏在开关后面**（2026-09-28，#68）。`ka-ci.ps1 -Probes` 按 glob 跑
  `tests/probe-*.ps1` 且**每个都不带参数**，所以凡是把自检藏在 `[switch]$SelfTest` 后面的探针，那部分
  代码在自动化里从来没执行过——上一行那个"内嵌 C# 与产品调用成员对得上"的绿，因此没有证明它**会不会红**。
  `probe-native` 这条改成普通运行在绿完之后**自己带 `-SelfTest` 起一个子进程**，要求那个孩子印出
  `PROBE OK (self-test):`；孩子只改内存里编译出来的副本、把产品调用的某个 public 成员改名，覆盖检查必须
  **点名**它（本机实测：`renaming GetPowerCapabilitiesRaw is caught: [Ka.Native]::GetPowerCapabilitiesRaw
  is called by the product but does not exist on the compiled type`）。代价近乎为零：本机整条 5.2 秒
  （原 5 秒），CI 上 `ok probe-native.ps1 5s`。期间被两件小事咬到，都记下来因为它正是"绿了也不作数"那类：
  ① 判据原先吃 `$c.ExitCode`，而**非等待式 `Start-Process` 对象在子进程结束后 `ExitCode` 回 `$null`**
  （本机实测，`ka-ci.ps1` 里早写过这条）（2026-09-30 第二次更正：这句对**本条自己的启动形状**是对的——该腿带
  `-NoNewWindow` 与一条重定向，那种形状的孩子退出后读也还是 `$null`，`_tmp/exitcode-switch-matrix-20260930.txt`
  T2/T4；错的是把它当成了通则，中间那版"方向反了、来自读得太早"的更正已被推翻），`$null -ne 0` 把一个正常结束的孩子判成了红——改成吃孩子自己
  印的标记，与 `probe-bat-entry` 的判据同一个形状；② `[IO.File]::ReadAllText` **读不到父进程自己那条
  重定向句柄还开着的文件**（实测 `being used by another process`，而子进程已经退出），`Get-Content`
  是按共享打开的，所以照旧能读。
- **`probe-bat-entry` 的 5 缺陷 sweep 保持不进 CI，这条现在是决定而不是悬着**（2026-09-28）。量到了
  决策需要的那两个数：那条 sweep 本机 8m35s，而 CI 上 `Gates and probes` 已经是整段 job（21m42s，
  run `36437907563`）里最重的一节，加进去等于每次 push 多约 8.5 分钟；收益只是让那 5 个注入缺陷每轮各红
  一次。所以决定：**不进**，但要接随时有两条现成的路——加一个带开关的 CI step（与安装器那步
  `-WithWorker -SelfTest` 同一个形状），或把它改造成不带开关的 `probe-bat-entry-selftest.ps1` 让 glob
  自己捡到；两条的墙钟代价一样。README 那两行与《独立门禁与实测探针》里原来那句"接不接还没定"已按此改写。

- **面板归属按数据根认，不再按程序目录认**（2026-09-28，#69）。这条是拿一次真实事故换来的：一个只把
  `KA_DATA` 指到 `_tmp` 的临时脚本，仍旧按**程序目录**把用户自己的面板认成了"我们的"，从它的命令行
  读出端口，POST 了 `/api/server/stop`，面板礼貌地照办——`ka.log` 里那行是
  `2026-09-27 01:12:47  SERVER EXIT pid=28208`（当时恢复成 pid 724；那台机器 2026-09-28 16:58 重启后
  又换成 pid 2044，都在 8791、`/api/ping` 200。**那次重启与本修复无关**：`LastBootUpTime` 就是那个时刻，
  ka.log 最后一行的 `2026-09-27 02:48:26` 是重启之前的，而两个看门狗任务处于禁用状态，所以重启之后没有
  任何东西把保护拉回来——本机现在是我在验证通过之后手动 `ka.bat start` / `serve` 拉起来的）。
  改法三处：`Get-KaServer` 的 `Ours` = 我们数据根里的句柄 **或** 命令行 `-DataDir` 等于我们的数据根
  （`ka-core.ps1:2562`）；`Stop-KaServer` 与 `Start-KaServer` 只吃 `.Ours`（`ka-core.ps1:2590`、`2645`）；
  停机请求只发给**有凭据的端口**——句柄写了端口，或那个进程的命令行带 `-Port`，不再退回"我本来会用的
  端口"（`ka-core.ps1:2653`）。端口被别人占着时 `serve` 不再接管也不再驱逐，直接说
  `cli.panelAnswering`："没有找到我们能停下的面板，但端口 X 仍在应答——它属于另一个数据根、另一个用户，
  或者不是本工具启动的进程。"全仓只有这两个动作点用 `Get-KaServer`，都已过滤；三个界面（CLI / 托盘 /
  `serve`）共用 `Get-KaStopServerText` 一句判决。
  `tests/probe-server-hint.ps1` 从五条腿扩到九条（⑥看得见但拒收、⑦`serve` 只报告不接管、⑧对照、
  ⑨端口无从得知时不许猜），`tests/probe-server-hint-selftest.ps1` 从两条臂扩到六条（新增 `claim` /
  `stopfilter` / `startfilter` / `portfallback`），六条各自红在自己的断言上、未注入的对照绿。实测两批
  四条各约 74 秒（`-Only shared,blind,claim` 296.5 秒 = `_tmp/hint-sweep-batch1b.log`，
  `-Only stopfilter,startfilter,portfallback` 293.4 秒 = `_tmp/hint-sweep-batch2.log`，两次都 `exit=0`），
  而**CI 的裸跑形状（六臂 + 对照，七次）本机实测 435 秒**，就在整轮 `-Gates -Probes` 的 transcript 里
  （`_tmp/ci-gates-probes-run3.log` 的 `ok probe-server-hint-selftest.ps1 435s`；同一轮 `ok
  probe-server-hint.ps1 76s`、`----- 27 run, 0 red`、26m38s）——比每臂 74 秒的算术更小，与已在 CI 的
  `probe-bat-entry-selftest.ps1`（README 记的 8m35s = 515 秒）同级、都在 `ka-ci.ps1` 每脚本 600 秒的线下。
  **runner 上的真数字**（run `36437907563`，job `108980501614`，整 job **21m42s 全绿**）：
  `ok probe-server-hint.ps1 50s`、`ok probe-server-hint-selftest.ps1 392s`——比本机还快一点，600 秒那条线
  上留了 200 秒余量。同一轮顺带把另一件事结掉了：上一版（`ef62ad1`）的 CI 红在
  `left 8 descendant(s) alive: 1052:msedge.exe, …`，这一版的 job 日志里 `msedge` 出现 **0 次**，
  `KA_NO_BROWSER` 那条修复由 runner 的留口检查本身证明。
- **这条探针自己挂死过一回，成因与 #65 同一个**（2026-09-28）。`Invoke-Child` 原先用
  `Start-Process -Wait`，而 .NET 的 `WaitForExit()` 等的是被重定向的 stdout 管道到 EOF：`claim` 臂下
  第 7 条腿的 `serve` 会真的起一个面板，那个孙进程继承了写端，EOF 永远不来。实测卡住九分钟
  （`_tmp/probe-server-hint-mutant.ps1` pid 6944，它起的暂存面板 55196 / 55141 仍活着，`ps` 与日志
  mtime 都对得上），而且第一版是在**后台**跑的，被当成"跑得慢"放过去了——是第二次单跑才看清它根本没在跑。
  现在改成 `HasExited` 轮询到 90 秒，超时写成 `CHILD_TIMEOUT after 90s: <args>` 进输出，让调用方的断言
  自己变红，绝不静默卡住。教训写进文件里的注释：**任何被重定向 stdout 的 `-Wait`，只要孩子会留下继承
  了写端的孙进程，就是一个没有截止点的等待**——这正是 `ka-ci.ps1` 那次 CI 被人工取消两次的原因，
  这次是同一个病落在自己的探针里。
- **每个临时数据根都必须写自己的 `config.json`**（2026-09-28）。`Stop-KaServer` 无论如何都会把
  `[int]$cfg.port` 放进它要问的端口里（`ka-core.ps1:2699`），所以没写配置的临时数据根会退回内置 8791 ——
  **那正好是这台机器上真面板的端口**。第一次跑就抓到了：第 8 条腿印出 `answering=8791`，也就是一个临时
  数据根的 `stop-server` 刚 ping 过用户的面板。轻的那半是只读 ping；重的那半藏在 `portfallback` 突变的
  臂里——那一臂把关停请求重新瞄准 `$cfg.port`，于是同一个动作会变成一次真 POST。现在四个临时数据根
  （dataA/B/C，加上按腿改写的端口）各自点名自己分配的端口，重跑后 `answering=` 干净。
- **`serve` 不再说一句它不打算做的事**（2026-09-28）。`KA_NO_BROWSER=1` 时原先仍会打印
  「首次启动，正在打开浏览器…」，紧跟着「请手动打开：…」——两句话并排出现（`_tmp/nobrowser-measure.ps1`
  第二次跑抓到）。现在 `panelOpening` 归到 `else` 分支里，设了就不再出现；README 那一条的措辞跟着改。

- **CI 那一步为什么被人工取消过两次，答案在 runner 自己的等待逻辑里**（2026-09-26/27，#65 #66）。
  两次取消（run `36242306473` 停在 31 分、`36243977634` 停在 60 分）都不是产品红，是 `tests/ka-ci.ps1`
  用 `Start-Process -Wait` 等每个子脚本：`.NET` 的 `WaitForExit()` 等的是 stdout 管道到 EOF，
  而被等的脚本留下一个继承写端的孙进程（面板就是那个孙进程），EOF 就永远不来。改完的形状：直接孩子
  是 `cmd.exe`（它随脚本一起退出，对孩子留下的活口是瞎的），脚本的文本走同一个控制台（一路
  `Start-Process -NoNewWindow`），退出码由 cmd 自己写进 verdict 文件，循环只 `HasExited` 轮询到截止点、
  超时就 `taskkill /T` 整棵子树。头一份证据是一张**单一真源**的四行表（`_tmp/wait-table-run1.log`，
  孩子印一行标记 + 起一个活 6 秒的孙进程 + `exit 5`）：`-PassThru` 配 `HasExited` 轮询 0.7 秒返回、
  看得见孙进程、代码回 `$null`→`0`（撒谎）；`-PassThru` 配 `WaitForExit()` 0.8 秒返回、同样撒谎；
  `Start-Process -Wait -PassThru` 8.1 秒返回、代码 5（真话）、**但看不见孙进程**；
  `[Diagnostics.Process]::Start` + 重定向 stdout 而从不读 + `WaitForExit` 0.8 秒返回、代码 5、看得见
  孙进程，**而孩子印的那行标记整个丢了**（`marker-in-log=NO`）。（2026-09-30 第二次更正：前两行的 `$null` 是
  **启动开关**的产物——那两行要让孩子文本进日志（`marker-in-log=yes`，这本身就是开关形状的证据），形状就带
  `-NoNewWindow`；实测这种形状的孩子退出后读也还是 `$null`（孩子还在跑时任何形状都读 `$null`），而 `-Wait` 行
  在任何形状下都读到真码 5。四种形状的"瞎"据此收窄：第 4 行丢文本、第 3 行等活口，前两行是开关造成的读不出
  来，不是"只在读没坐在退出之后时才瞎"；`ka-ci` 选直系 `cmd` + 判定文件 + Job 形状不变，理由改写在该文件头部，
  见 `[未发布]` 本轮条目。）
  所以 `ka-ci.ps1` 顶部那张表把"哪种瞎在哪一列"写成实测行，而不是脚注——上一版这里的几个数字是别处抄来的、
  和本机重测的对不上，本轮是先补出这张单一真源的表才把数字钉死的。收集器本身每行花 8.1 秒，而它检查的
  那个等待逻辑 0.7 秒返回，这句话也写进去了。
  钉它的是两条新探针：`tests/probe-ci-harness.ps1`（六个一次性夹具——干净 / `exit 5` / 睡 600 秒 /
  留一个 GUI 活口 / 把启动它的 cmd 先杀掉 / 留一个控制台活口——交给**真** runner 跑；`ka-c-hang` 与
  `ka-e-nocmd` 共用一次调用所以汇总行必须同时数到两个；同一份"控制台活口"夹具再走一遍**修复前那个
  `-Wait` 形状**做差分，实测 `old shape: 16s, exit code 0` 对发出去的 runner `3s and red`；干净那条
  不是填充物——runner 第一版对什么都没留的脚本印 `left 1 descendant(s) alive:`，因为空结果回来是空
  字符串而 `@('')` 有一个元素，还把夹具自己的 `conhost.exe` 一起列出来，这两处都会把**没有泄漏的真
  CI 步骤**判红；被点名的每个 pid 还必须晚于本探针的开始时刻）和 `tests/probe-ci-harness-selftest.ps1`
  （检查上面那条**会不会红**：把 `ka-ci.ps1` 复制到 `_tmp/` 副本、只加两行、两条臂各自用环境变量打开，
  臂 1 关掉"还剩活口"的报告→要求恰好那两条泄漏腿红且**不许有一条都没红**的情况静默通过，臂 2 把
  **跑这条自检的进程自己的 pid** 塞进活口名单→实测 2 条 finding 逐条写着
  `born 23:28:31 - before this probe started at 23:29:14, so it is not a leftover of any leg`，
  两个注入都关掉的对照副本必须还是绿的）。
  本机全量 `-Gates -Probes`：先 `----- 27 run, 2 red`（`_tmp/ci-gates-probes-run1.log`），两个红都当场
  落实了成因——`probe-server-hint.ps1` 报 `left 1 descendant(s) alive: 21688:powershell.exe`，是出生
  时间窗只有下界、pid 被回收后老进程被认成本轮活口（修完 `ok probe-server-hint.ps1 34s`，
  `_tmp/ci-window-fix1.log` 第 16 行）；`probe-mutex-identity.ps1` 是环境性的，见下下条，
  **不能靠停掉用户的 worker 去把它变绿**。两条都修完之后同一入口重跑：
  **`----- 27 run, 0 red`**（`_tmp/ci-gates-probes-run2.log`，00:19:54 → 00:43:08 = 23m14s，
  与 27 行各自耗时之和 1392s 对得上，所以那个 23 分钟不是排队等出来的），这一轮里
  `probe-bat-entry.ps1` 单跑 69s、`probe-ci-harness.ps1` 39s、它的自检 117s、
  `probe-mutex-identity.ps1` 8s 绿、`probe-server-hint.ps1` 44s 绿。
- **那条 sweep 里唯一没查清的东西：一次 `answered 0`**（2026-09-27，#64 的尾巴）。
  `tests/probe-bat-entry.ps1 -SelfTest` 十四次里有一次是**没有注入缺陷**的那个子进程印
  `an unknown name answered 0, not 404`（端口 58426，同一个文件几分钟前和几分钟后都是绿的，
  `_tmp/bat-entry-selftest-cleanup.log` 逐行可重读；harness 自己也照实说了——
  `the un-defected run did not come out green (verdict=FAILED exit=1) - the reds below would prove nothing`）。
  两次受控复现各 0 次偏差：30 对同一连接的 KeepAlive 开与关（`_tmp/panel-keepalive-probe.ps1`），
  40 对再挂一个每 120 ms 打六条路由的第二客户端（`_tmp/panel-load-flake.ps1`）——所以连接池复用与
  并发负载是**被排除**，不是被解释；那次红字把 `$r.Error` 丢了，所以机制至今未知。能做的是把"形状"
  钉住：`Status 0` 是"一个 HTTP 状态码都没到过"，于是 `Invoke-Route` 只给这一种形状三次机会、每次隔
  400 ms，**真的回了状态码的绝不重试**，每条 `[panel]` 红字现在带 `status=/tries=/errors=`。
  代价与限度一并写明：这是让那条腿去容忍一个本文件并不理解的失败，而加上它之后那次 sweep 每条路由
  都是 `tries=1`、一行 `note:` 都没有——**它至今没被观察到吸收过一次真实的 flake**。
  同一条 sweep 现在收尾是绿的（`_tmp/bat-entry-selftest-retry.log`：干净子进程 `verdict=OK`，五个变异体
  `badentry`/`wrongtarget`/`unreachable`/`missingasset`/`leakchild` 各红在自己那条腿上），
  整条 8m35s（`CreationTime 23:58:31 → LastWriteTime 00:07:06`），单跑 129s。新增的 `leakchild` 那条
  量的不是产品而是**这个文件自己的收尾**：`Stop-Scratch` 以前等满 10 秒就把结果丢掉，等于一条挂在睡眠
  上的断言；现在它等的是实测（还活着就红、点名 pid 与它是哪个脚本）。`off.bat` 也不再挂在 SKIP 里——
  `[off-idle]` 那条腿每次都真跑它，SKIP 那三行末尾自己写着这一句。**顺带查出一个 CI 覆盖洞**（#68）：
  `ka-ci.ps1:96` 的 `-Probes` 按 glob 跑 `tests/probe-*.ps1` 且**每个都不带参数**，所以 9 个会注入缺陷
  的探针里，7 个"文件形状"的自检每轮 CI 都跑，而把自检藏在自己文件那个 `[switch]$SelfTest` 后面的两个
  （`probe-bat-entry`、`probe-native`）**一次也没进过 CI**。接不接还没定，先把单位说清楚：本机那条
  sweep 实测 8m35s，本机整步 `-Gates -Probes` 23m14s，而已推上去那一版在 CI 的同一句是 8m10s
  （run `36237945409` 的日志时间戳）——**这是两台机器，不能把 8m35s 直接加到 8m10s 上**，CI 侧真实
  增量要等这条推上去、在那台一次性 runner 上量一次才知道；新那两个探针也还没在 runner 上跑过。
  这条洞写在 README 的探针清单与表格里，不当它不存在。
- **"跨进程真的抢得到"现在有两条路由，由实测选**（2026-09-27）。`probe-mutex-identity.ps1` 在正在防休眠
  的机器上必然红：那条控制要当"第一个拿的人"，而这台机器上用户的 worker（pid 21688）已经持有
  `Local\KA-Worker-DCA86D0FFFB8`，job 于是印 `got=False`（2026-09-25 实测，且从 `git archive HEAD` 的
  干净副本复现过同一句红——是机器，不是被测代码）。**修法不是把它变绿，是换一个更强的证据**：先问
  `OpenExisting` + `WaitOne(0)`（前者只证明名字存在，后者才证明别的进程正持有），确实被持有就改成
  "和产品自己的 worker 争"，末行印 `contention observed against live worker pid 21688`
  （`_tmp/mutex-livewholder1.log`），并把 job 那条控制**明写着 SKIP**；没有持有者就照旧走 job，CI 那条路
  本轮**没有在 runner 上重测**。取到手立刻释放——`ka-worker.ps1:70` 只在启动时拿一次、之后从不重新申请，
  短暂的第二个申请人动不了正在跑的保护；跑完复查 `state.json` 仍是 `displayActive=True antiLock=True
  pid=21688`，这条是查过的不是假设的。

- **四个双击入口里那一行命令，从来没有一条被真的执行过**（2026-09-26，接上一条）。同一句问句第五次问出去，
  这回不问清单、不问字节形状，问**内容**：`on.bat` 写的是 `start -Minutes %~1` 还是 `start -Minute %~1`？
  上一轮那道闸门钉的是"cmd 会不会读错这份文件"，而它读得懂一个 `serve` 拼成 `serveX`。
  **这句话的第一版写错了，而且是自己查出来才发现的**：我当时写"五个 `.bat` 一个也没被执行过"，证据是
  `git grep -n 'ka\.bat' HEAD -- tests/ka-tests.ps1 packaging/` 只命中 `build.ps1:141` 的一句散文——可那条
  grep 的范围是我自己划的，`tests/probe-motw.ps1` 不在里面，而它的第 142 行
  `cmd /c call "<marked copy>\ka.bat" status` **确确实实把 `ka.bat` 跑过**（断言只有 `exit=0` 和"输出不少于 40 个字符"）。
  划小范围的 grep 给一个"从来没有"当证据，和本轮要抓的那个病是同一个病。所以一个一个数清楚：
  **`on/off/panel/tray` 四个从来没被任何检查执行过**——这四个名字在 `tests/` 里除了本探针只出现在
  `ka-release-files.ps1`（清单）里，`on.bat` 与 `panel.bat` 另在 `probe-encoding-selftest.ps1` 里被**改**过字节
  （改完交给扫描器读，没人跑过它们），`release.yml` 与 `KeepAwake.iss` 里的那几处是给下载者看的文字，
  不是执行；`ka.bat` 跑过一次，跑的还是带参数那条分支——
  **无参数那条分支（`if "%~1"==""` → `status`）是本轮第一次被执行**。
  补的是 `tests/probe-bat-entry.ps1`：按发布清单复制一整棵一次性树到
  `_tmp/bat-entry/tree`，把 `$env:KA_DATA` 指到一次性数据根——**这一行必须在任何进程起来之前**，`ka-core.ps1:354`
  读的就是它，指错了 `off.bat` 会按数据根找到本机那个活着的 worker、判定"这是我们自己的"、然后把用户的防休眠
  关掉。然后拿 `cmd.exe` 把每个入口真跑一遍，断言的是**产物**：`ka.bat` 无参数与 `ka.bat status` 逐行同形，
  `status -Json` 里的 `dataRoot`/`root` 就是这两棵一次性树的路径；`panel.bat` 起的那个端口上**清单里每一个
  `dashboard/**` 文件都要 200，且服务端吐出的字节数等于文件本身的字节数**，`index.html` 里 `src=`/`href=`
  要到的每个名字也要 200，一个不存在的名字必须 404；`ka.bat stop-server` 之后端口要下来、`.server-*.json`
  句柄要清零。后两条是 favicon 那个洞的**另一半**：上一轮补的是"文件没进 zip"，这一轮补的是"进了 zip 却没有
  一条路由能把它送出去"——`$staticMap`（`ka-server.ps1:49-55`）至今是一张手写的六行表，而清单已经从树推导了，
  两者完全可以各说各话而一切照旧全绿。

  **harness 在这一轮里被实测推翻四次**（`_tmp/exit-semantics-rerun.log`，八行都是刚跑的）：① `pause` 把判定
  归零——一个只 `exit 5` 的子脚本，包它的 `.bat` 以 `exit /b %ERRORLEVEL%` 收尾时 cmd 给 **5**（E1），以 `pause`
  收尾时给 **0**（E2），什么都不加也是 **5**（E3）；`on/off/panel/tray` 四个恰恰全以 `pause` 收尾，所以它们的
  断言根本不能是退出码。② `Start-Process -PassThru` 之后自己 `WaitForExit()` 或 `WaitForExit(30000)`，对
  `cmd /c exit 3` 一律报 **0**（B、C 两行），`Refresh()` 也救不回来（C2）；同一个调用加 `-Wait` 报 3（A），
  `[Diagnostics.Process]::Start` + `WaitForExit(ms)` 报 3（D）——探针取后者。③ cmd 的 `/c "..."` 要**引号数成对**：
  少一个闭引号，cmd 只印一句 `The filename, directory name, or volume label syntax is incorrect.` 然后**退出 0**，
  于是第一次 `-SelfTest` 的五个子进程一个都没跑成而 harness 全绿；判据从此不吃退出码，吃子脚本自己写的
  `PROBE OK` / `PROBE FAILED` 标记。**③' 同一条理由抓到这轮自己一次**：那句"没坏的那棵全绿"以前只在**坏掉**
  的时候说话——干净那条子运行跑了、判据也认了，transcript 上却一行都没有，所以它当时的证据是"没人反对"，
  不是"有这一行"（和本轮开头那句"从来没被执行过"是同一个形状）。现在它和四个变异体同表同列印
  `run mutate='(none)      ' verdict=OK exit=0 fails=0`，`_tmp/bat-entry-selftest5.log` 第一行。
  ④ `Invoke-WebRequest` 在 5.1 上会把服务端明明白白返回的 404 吞成
  `Status 0`（`.Response` 不可达），"不存在的名字要 404"这条断言因此在**真面板**上是红的；换
  `[System.Net.HttpWebRequest]` + `WebException.Response` 才拿到那个 404 和 body
  `{"ok":false,"reason":"没有这个文件"}`——这条是本轮唯一一条"探针先把产品测试判错、再去量被测物"的记录。

  两条断言的**形状**也是被实测改掉的，不是设计出来的。**`tray.bat` 跑第二次会真的多起一个进程再自己退出**
  （本机量到 `20000` → `20000 + 16564` → 约一秒后又是 `20000`），所以"托盘进程数不变"是错判据；改法等它 settle，
  再断言活着的那个 pid 还是原来那个。**单位边界会自己造 flake**：干净树第一次跑，`ka.bat`（无参数）与
  `ka.bat status` 之间隔了几秒，本机那个活着的 worker 的空闲读数正好跨过 60，一边印 `62 秒`、一边印 `1.0 分钟`，
  整串折叠的比较把它读成"两条输出不同"；于是判据改成**逐行**比较加单位容错（数字折成 `#`，紧跟的数字单位词
  一起折掉）。同一条规则顺手作了第二次证：同一个原因在 `badentry` 变异体上以**外来腿**的形式又红了一次
  （只该红 `[panel]` 的那棵树上冒出 `[ka]`），"不许牵到别的腿"当场抓住它，说明那条规则不是装饰。

  本机结果（`_tmp/bat-entry-run4.log`、`_tmp/bat-entry-selftest3.log` 逐行可重读）：干净那条印
  `PROBE OK: every double-click entry that can run here ran for real, and every dashboard file the release ships
  answered over HTTP - ka/off/panel/tray executed; on.bat runs only with -Power or on a runner (anti-lock pulse
  on the first tick)`；`-SelfTest` 四个注入缺陷各自红在自己的腿上、没坏的那棵全绿，末行
  `PROBE OK: 4 injected defects each turn their own leg red and the intact run stays green`。四句红话都是量出来的：
  `serve` 拼错 → `[panel] panel.bat never brought a panel up on port 53019`，后面跟着 ValidateSet 的报错原文；
  `ka.bat` 指向不存在的脚本 → 7 条，含 `ka.bat exited -196608` 与 `status -Json is not JSON: Invalid JSON
  primitive: The.`；往 `dashboard/` 放一个没有路由的文件 → `[panel] selftest-extra.svg ships in the release but
  the panel answers it with 404 - a name no route list holds is a file nobody can load`；删掉 `dashboard/i18n.js`
  → `[panel] index.html asks for /i18n.js and the panel answers 404`。`tests/ka-ci.ps1` 是按 `probe-*.ps1` 认领
  的，所以这条探针不用改 workflow 就进了每一轮：CI 那一步跑的是 `-Gates -Probes`（5 道门禁 + 19 个探针 =
  **`----- 24 run, 0 red`**，上一轮 runner 上就是这个数），加上这一条之后下一轮应该是 **`----- 25 run, 0 red`**
  （run `36237945409`；本机只跑门禁是 `----- 5 run, 0 red`，两个数不是一回事）。
  **仍然拦不住的 / 这轮的代价，写在这里而不是藏起来**：`on.bat`、`off.bat`（和 `-Minutes` 那个拼错变异体
  `badminutes`）在有人正在用的机器上不跑——worker 第一拍就发防锁合成键（`ka-worker.ps1:152`，读出来的），
  在这里跑等于往别人的会话里打字，所以本机那两条印的是 SKIP 加理由，只有 runner 上或显式 `-Power` 才真跑；
  每条面板腿会在桌面上**开一个浏览器标签页**（`ka.ps1:594` 的 `Start-Process $r.Url` 无条件执行、没看
  `$r.Newly`；这轮只记下，没改），一次 `-SelfTest` 约四个；断言的是"这一行 cmd 读得懂、指向真实脚本、产物到位"，
  钉不了"worker 真的动了鼠标"；`.cmd` 家族依旧没有真实对象。跑完 `_tmp/bat-entry` 树根下的进程 `count=0` 是查过的，
  机器上原来那台 worker 与面板（pid 21688 / 28208）全程没被碰过——**这轮也没有为了让任何一条腿变绿而停过正在
  防休眠的进程**。

- **`.gitattributes` 里那两句关于字节形状的话，磁盘上一次都没人执行过**（2026-09-26，接上一条）。
  同一句问句第四次问出去：上三轮问的是"闸门在找哪些名字""清单里有什么"，这回问的是**发出去的那些字节
  长什么样**。起点是一句 grep：`grep '\.bat' tests/ka-encoding.ps1` 空的——那道闸门只扫三个目录里的
  `*.ps1`，而 `.gitattributes` 明明白白写着两句断言（".bat 只有 CRLF 才能可靠执行"、"给 .iss 一定吃得下
  的 CRLF"）。拿 `git ls-files --eol` 一量，当场给出两种相反的答案：
  `i/lf w/crlf attr=text eol=crlf ka.bat`（工作树同意）和 `i/lf w/lf attr=text eol=crlf packaging/KeepAwake.iss`
  ——后者工作树里是 **154 个裸 LF**，属性说它是 CRLF。**而 `git status` 看着是干净的**：`eol=crlf` 只在
  git *检出*一个文件时改写行尾，事后由编辑器或脚本写进去的字节没人管，比较时又要先过 clean filter，
  所以这一处测量结果是本轮最好的一条反面证据——`git status --porcelain` 吐 ` M packaging/KeepAwake.iss`
  （stat 缓存过期），`git diff --numstat` 对它**一个字都不吐**（内容归一化后相同）。顺着这个机制还有一层：
  用 `-Apply` 把它修成 `CRLF=154 bareLF=0` 之后，`git diff HEAD -- packaging/KeepAwake.iss` **依旧是空的**
  ——这次修复根本提交不出任何 blob 变化，而原因当场可重读、不必相信任何人的解释：`git show
  HEAD:packaging/KeepAwake.iss` 打出来的原始字节是 **CR=0 / LF=154**（仓库里存的一直是纯 LF，
  `eol=crlf` 是 checkout 那一刻才加上去的）。也就是说洞在**这台机器的工作树**里，不在仓库里；全新 clone
  拿到的是 CRLF（属性会改写），所以 CI 从来没坏过，坏的是"我读过的那份字节、也是本机 ISCC 真吞下去的那份"。
  **可提交的不是修复，是那道能看见它的闸门**——这句话本身就是这轮的全部内容。
  闸门改成按**家族**查：`.ps1` 要 UTF-8 带 BOM + 纯 LF（5.1 用 ANSI 代码页解码无 BOM 的脚本）；
  `.bat`/`.cmd`/`.iss` 要纯 CRLF、**零 BOM**、**零非 ASCII 字节**——`cmd.exe` 和 ISCC 都按系统 ANSI
  代码页解码，本机 ACP 65001 把问题藏住，默认 zh-CN 安装是 936，那里一个 BOM 会让首行打印成 `ÿþ`、
  一个汉字到达时已经是乱码；今天这五份 `.bat` 和那份 `.iss` 的 `nonAscii=0` 是数出来的，所以这个性质
  从此被钉住而不是被假设。`dashboard/**` 与 `*.md` 只报不断（浏览器和人读它们，形状不是它们的契约）；
  **落不进任何家族却出现在清单里的扩展名直接判失败**（"add a rule or stop shipping it"）。扫的文件集合
  同样是查出来的：发布清单 ∪ `tests/*.ps1` ∪ `packaging/*.ps1` ∪ `packaging/*.iss`。
  新闸门**当天就抓到自己人**：`Write` 落盘的第一版 `ka-encoding.ps1` 没有 BOM，是它自己报的
  `ka-encoding.ps1  no BOM`。
  闸门会不会红由 `tests/probe-encoding-selftest.ps1` 作证（第七道自检）：整棵一次性树、一条腿只坏一处、
  六处分别是 `.ps1` 掉 BOM / `.ps1` 被 CRLF 化 / `on.bat` 变裸 LF / `ka.bat` 带 BOM / `panel.bat` 里塞一个
  汉字 / `dashboard/` 放一个没有家族的 `evil.py`，每条腿要求 `exit≠0` + 点名这条腿改的那个文件 +
  说出该说的那句 + **不许牵到别的文件**，没坏的那棵必须绿。判据里"CRLF"和"BOM"两个词要先过滤掉闸门的
  `info` 行——那些行本来就写着 `CRLF=0`、`BOM=False`，不过滤会把每个面板资源读成第二条罪状。
  **harness 在这轮里撒了两次谎，都被当场抓住**：① 第一次运行先印 `PROBE FAILED: setup`、再走到文件底部
  印 `PROBE OK` 并 `exit 0`——`catch` 里没有把异常算成一条罪，于是"探针在自己的注入上崩了"这件事被它
  自己宣布成通过；同样的 fall-through 一并加固到 `probe-build-selftest.ps1`。② 崩的原因是
  `GetBytes((Get-Body $f) -replace 'a','b')`：方法调用里裸逗号是**参数分隔符**，于是实参变成
  `(Get-Body $f)-replace 'a'` 和 `'b'` 两个，`Cannot find an overload for GetBytes and the argument count: 2`。
  本机原话：`PROBE OK: six broken byte shapes each turn the encoding gate red on the file this leg broke,
  and the intact copy stays green`。`probe-iss` 今天重跑，六条断言全绿，其中 `crlf: the CRLF shape a fresh
  clone gets compiles too` 与 `naming: KeepAwake-1.0.0-setup.exe (2,097,762 bytes)`——**形状换了，编译器
  照吃**，所以这轮的修复对产品没有任何风险，风险全在"文档说了一件事而没人检查"这一类。
  同一条问句再往上一层，量出**清单的第二半还是漏的**：上一轮把 17 个手敲名字换成"推导"，可推导当时是
  三个 glob，而 glob 就是一份穿了"发现"外衣的扩展名清单——根目录放一个 `run.cmd` 或 `notes.txt`，三个
  glob 一个都不匹配，它就安静地进了"不在 release 里"那一堆，**和 favicon.svg 同一个病、往上一层**。
  现在 `Get-KaReleaseFile` 反过来要求**每个根目录文件都被某条规则认领**（三个 glob / 六份点名文档 /
  `.gitignore`+`.gitattributes` 两份仓库管道），没被认领的 throw 并点名它；"哪些是本机运行产物"不再抄
  第二份名单，去问 `git check-ignore`（`.gitignore` 里连理由都写好了，两份同一个清单正是这个仓库存在的
  理由）。`.cmd` 顺手进 glob：`.gitattributes` 和字节闸门早就把它当程序，只有清单没当。两条新腿加在
  `probe-build-selftest.ps1`：`strayfile`（树根一个 `build-notes.txt` → 冒烟必须红在
  `build-notes.txt is at the repository root`）和 `strayoutside`（同一个文件放进 `tests/` → 必须照旧绿，
  否则那条断言说的其实是".txt"而不是"没被认领的根"）。判据吃的是消息自己的语法——**单数 is 就是"只怪了一个
  文件"**，多一个会变成 `a, b are at...`，于是这条断言顺手也是"一条腿一个缺陷"的检查。这条腿的绿不算证据，
  所以把认领检查改成 `if ($false -and $stray.Count)` 重跑整条探针（`_tmp/mutate-claim.ps1`，注入后先证明
  needle 落地、还原后比对 sha256）：`mutant run exit=1`、四条 `FAIL`，其中最要命的一条是
  `strayfile tree passed the smoke`，而那份 transcript 里 `packaging KeepAwake v1.0.0 (24 files ...)` 后面
  跟着 `ok ... 24 entries` ——**没被认领的文件正安静地不在 release 里，全绿**；逐字节还原后 `exit=0` 回绿。
  本机数字（都在磁盘上可重读）：五道门禁 `----- 5 run, 0 red`、`every shipped text file carries the byte
  shape its family requires`；探针 `----- 19 run, 1 red`，唯一那条红仍然是 `probe-mutex-identity.ps1` 的
  环境红，原话一字未变（`holder job said: got=False ; OpenExisting error: none`，握着默认数据根的就是本机
  那个活着的 worker），**没有为了让它绿而停掉正在防休眠的进程**。文档计数又自己抓自己一次：README 那句
  "外加六个『自检』"在 `077bbfd` 上对着 `git ls-tree HEAD tests/` 回答 **5**，手抄的第三个数说谎；这一轮
  补上的正是缺的那一个，现在 19 个探针、六个自检，`ls tests/probe-*selftest* | wc -l` 当场对得上。
  runner 的数字回来了（run `36237945409`，sha `3d826c8`，`_tmp/ci63.log` 逐行可重读）：CI 那一步跑的是
  `-Gates -Probes`，印 `----- 24 run, 0 red`（5 道门禁 + 19 个探针），门禁末行仍是
  `every shipped text file carries the byte shape its family requires`；**本机那条唯一红的
  `probe-mutex-identity` 在那里是 `ok   probe-mutex-identity.ps1       8s`**——这条差异正是上一条"环境红"
  诊断的反证：握着那个互斥体的是**本机**活着的 worker，一次性 runner 上没有 worker，所以它真的跑完了，
  而不是被跳过。套件那一步 `----- 1 run, 0 red` + `通过 86，失败 0，跳过 5`。"清单从树推导"在 runner 上被
  三个独立数字同时钉住：`staging: 24 files in D:\a\keepawake\keepawake\dist\staging`、
  `ok   KeepAwake-1.0.0-portable.zip : 24 entries, all present with matching byte lengths, 0.28 MB`，
  以及安装腿红的时候自己吐出的那道算术（`got 26 files`，26 减掉 Inno 自己的 `unins000.dat` 与
  `unins000.exe` 正好 24）；`Successful compile (0.813 sec)` 和 `SHA256SUMS <- 2 file(s)` 照旧。三条安装腿
  `run mutate='          ' exit=0 fails=0`、`precreate exit=1 fails=1`、`expectfiles exit=1 fails=1`，
  后者那句红字 `install directory: expected the 25 manifest files + Inno's own 2, got 26 files, missing [],
  unexpected [unins000.dat, unins000.exe]` 里那个 25 是**注入本身**（`$want = $manifest.Count + 1`，
  `packaging/ka-test-install.ps1:276`）——它证明的是"多要一个文件的检查真的会拦"，不是产品少发了一个文件；
  这句话之所以要写，是因为那条红字单独抄出来看，长得和一条真缺陷一模一样。
  **仍然拦不住的写在这里而不是藏起来**：`on.bat`/`off.bat`/`panel.bat`/`tray.bat` 到现在没有任何检查
  真的执行过一次（跑一次就真起保护，落在谁的机器上都不该），字节形状钉的是"cmd 会不会读错这份文件"，
  钉不了"这一行命令对不对"——**这一条在本轮收尾时关掉了，见上方 `probe-bat-entry` 那一条；那四个点得准，
  没被列入的 `ka.bat` 也确实不是没跑过**（`probe-motw.ps1:142` 跑的是 `ka.bat status`，只是断言薄到
  `exit=0` + 输出长度，且没碰无参数那条分支）；`.cmd` 家族规则已经就位，而仓库今天**一个 `.cmd` 都没有**，所以那条臂
  目前没有真实对象，替"没被认领"作证的是 `strayfile` 那条腿；认领检查走的是工作树，`git` 不在或不是
  仓库时（`_tmp` 里探针拼的副本）不-ignore 任何东西，那时"未认领"直接 throw——这是刻意的方向选择；
  `.gitattributes` 自己不在任何家族里（它 `w/lf` 是量出来的，不是断言的）。这一轮**没有**动已发布的
  v1.0.0。

- **最后一份手写的清单，也正是"发出去的是什么"那一份**（2026-09-26，接上一条）。同一句问句问到第三
  次，这回不问闸门，问发布：`tests/ka-release-files.ps1` 里那 17 个代码文件名是我一个个敲的。敲的清单
  只会以一种方式坏——**文件在仓库里、不在清单里，于是它就不在 release 里，而链路上一切照旧全绿**：
  `build.ps1` 把 zip 与清单双向对账（多出条目 throw、条目字节数不对 throw、`Copy-ManifestTo` 撞上清单
  点名而树上没有的文件也 throw），可对的是"清单说了什么"，清单没说过的那个名字对它三处都是透明的。
  改法与前两轮同一路：**不问"清单里有什么"，去看"树里有什么"**——根 `*.ps1` + 根 `*.bat` + `dashboard/**`
  递归；文档那 6 份仍然手写（往根目录扔一个新 `.md` 是编辑决定，不是多出一个程序）。推导第一眼就给出
  `24 ≠ 23`，多的那一个正是洞：**`dashboard\favicon.svg`**。已发布那份 zip 是**逐条目量过的**（`gh api`
  下载 v1.0.0 的 `KeepAwake-1.0.0-portable.zip`，246,246 字节，`ZipFile::OpenRead` 列全表）：23 个条目，
  `favicon` 一个都没有；而 `dashboard/index.html:10` 按名字要它（`<link rel="icon" href="/favicon.svg">`），
  `ka-server.ps1:336-337` 找不到文件就回 `404 api.dashMissing`。`KeepAwake.iss` 的 `[Files]` 自己写明
  "没有文件表，装的是 `build.ps1` 按清单暂存的那份"（第 91-93 行），所以 `setup.exe` 走的是同一份清单、
  同一个洞——这半句是**读出来的**，没有把 2.3MB 的 exe 拆开验。时间线也照着仓库：文件 `37fb023`
  （2026-09-03）进仓库，清单最后一次被碰是 `b2b55b1`（2026-09-04），**晚一天的文件，清单永远不会知道**。
  红态两对，都是跑出来的：① 老那份手写清单配新腿（`probe-build-selftest` 的 `extrafile`：往一次性树根
  放一个没有任何清单点名的 `ka-extra.ps1`，要求冒烟**绿**且 zip 里**有**那一条目）→ `exit=1`、
  `FAIL ka-extra.ps1 is a program file at the repository root and the portable zip does not carry it
  (23 entries)`；换成推导那份 → `exit=0`。② 这轮新加的"两棵绿树的 zip 逐条目对照，差集必须正好是注入
  的那一条"——在 `_tmp` 的探针副本里让 `extrafile` 顺手删掉 `dashboard\favicon.svg`：**冒烟照样绿**
  （少一个面板资源不影响 `status -Json`）、`-notcontains` 照样过，只有逐条目对照开口
  `FAIL the extrafile zip also lost something the clean tree carries: dashboard/favicon.svg`、`exit=1`。
  也就是说"漏发一个文件"这件事在上一轮之前**没有任何一层看得见**，现在不仅看得见，而且被证明看得见。
  顺带同一形状的检查：推导若扫不到 `ka.ps1`/`ka-core.ps1`/`ka-gate.ps1`/`ka-server.ps1`/`ka-worker.ps1`
  或五个 `.bat` 里任何一个就 throw，dashboard 文件少于 4 个也 throw——"扫不到东西"长得最像通过。
  本机数字（都在磁盘上可重读）：`info portable zip entries: this tree = 24, with one root script no list
  names = 25`、`PROBE OK: ... a root script that no list names still ships ...`、`probe-motw` 那句跟着
  变成 `a Zone-3 download of 24 files ...`、五道门禁 `----- 5 run, 0 red`。文档里那几个 23/25 一起改：
  README 三处计数、`dashboard/` 那行目录树（它自己也少写了 favicon.svg——**文档里的清单是同一种洞的
  第三个身体**）、`build-test.yml` 注释里那个 23 换成"断言是 `$manifest.Count + 2`，跟着清单走"，
  免得下一次再敲错一个数（`ka-test-install.ps1` 本来就是从清单算的，所以它这一轮自动变成 26）。
  一条**本机红**记清楚，不是产品红：整轮 `----- 18 run, 1 red`，唯一那条红是 `probe-mutex-identity.ps1`
  的争用对照 `holder job said: got=False ; OpenExisting error: none`——名字找得到却拿不到，说明有人正
  持着默认数据根的 `Local\KA-Worker-DCA86D0FFFB8`，而它就是这台机器上活着的那个 worker（pid 21688，
  `-DataDir C:\Users\DELL\AppData\Local\KeepAwake`，当场从 `Win32_Process` 读到的命令行）。探针自己在
  100-104 行把这条写成了已知环境事实（2026-09-25 从 `git archive HEAD` 的干净副本复现过同样一次红）。
  **没有为了让它绿而停掉正在防休眠的进程**——那是这台机器的用途，不是测试的障碍；runner 那一步照旧绿，
  因为那儿没有任何东西在保护。**runner 的数字回填完了**（run `36234920150`，sha `077bbfd`，`completed
  success`）：那一轮 `----- 23 run, 0 red`（五道门禁 + 当时 18 条探针全绿），套件 `通过 86，失败 0，跳过 5`，
  `probe-mutex-identity` 在 runner 上印的是 `PROBE OK: the mutex keys on data root + SID, not on the
  install folder`——本机那条红因此被量化成"环境"而不是"产品"，两个同源检查唯一的差别就是有没有人在保护。
  清单推导后的三个数都在日志里可重读：`ok KeepAwake-1.0.0-portable.zip : 24 entries, all present with
  matching byte lengths, 0.27 MB`、`ok staging: 24 files in D:\a\keepawake\keepawake\dist\staging`、
  `PROBE OK: a Zone-3 download of 24 files ...`；**装到盘上**那一个是 26——它是从 `ka-test-install.ps1
  -SelfTest` 那条 `expectfiles` 突变腿自己的话里读出来的（`expected the 25 manifest files + Inno's own 2,
  got 26 files, missing [], unexpected [unins000.dat, unins000.exe]`），而同一轮里干净那腿
  （`run mutate='          ' exit=0 fails=0`）是绿的，所以 26 = 24 份清单 + Inno 自己的两个卸载器文件，
  `unins000.dat`/`unins000.exe` 正是它按名字排除的那两个。这一轮**没有**动已发布的 v1.0.0：重打包要重打 tag，那是另一件事。

- **同一个病根第三次量出来：内容被拆开写、或者压根不需要内容可读**（2026-09-26，接上一条）。
  上三条把"找什么名字"改成"管哪种通道"之后，剩下的问句是：**通道里的内容如果拼开来写呢？如果这条通道
  根本不看内容呢？**实测（`_tmp/shell-open-check.ps1`：往暂存副本注 5 种写法，`git show HEAD:tests/ka-privacy.ps1`
  那份旧闸门与改后的各跑一遍）——① 规则 1 的正则要求 `://` 后面**至少还有一个字符**，于是
  `'http://' + 'collector.example' + '.com/submit'` 与 `'https:/'+'/keystore.example.org/ping'` 两种拼法
  旧闸门**一个字都不报**（同一个副本 旧 `exit=0` / 新 `exit=1`），跟规则 4 那个 `'Access-' + 'Control-Allow-Origin'`
  是同一个病：清单认得整词，认不得碎片；② 更空的一条是**把地址交给 Windows shell**：
  `Start-Process 'telemetry.example.com/collect'` 没有 scheme（浏览器自己会补 `http://`）、没有任何
  `System.Net` 名字，规则 1~4 全都够不着，旧闸门对着同一份副本 `exit=0`。这条不是虚构出来的假想敌——产品
  自己就有两处这样打开面板（`ka.ps1`、`ka-tray.ps1` 的 `Start-Process $r.Url`）。
  修法还是那一路：**①规则 1 每行读两遍**，第二遍先把相邻字面量之间的 `' + '` 接回去再接着读主机名，读出来的
  主机照样必须回环；干净树实测 `rule 1: 12 URL literal(s), 0 only visible once adjacent literals are joined,
  0 dangling scheme(s), hosts = 127.0.0.1 x11, localhost x1`——数字与改之前逐字相同，也就是**零误伤**（这条
  要是不量，"加一遍归一化"完全可能悄悄把 `xmlns` 那两处豁免算成新洞）。只写到 `://` 就断开的
  （`'http://' + $env:KA_COLLECT`，拼接帮不上忙）按"读不出它要去哪儿"直接报。**②新增规则 5**：能交给 shell
  的写法是封闭集（`Start-Process`/`Invoke-Item`/`UseShellExecute`/`WScript.Shell`/`Shell.Application`/
  `cmd /c start`/`explorer.exe`，加安装器的 `openurl`/`shellexec`），所以**不猜字符串长什么样，只按文件数行**：
  实测 6 个文件 10 处，多一处就得在闸门里点名它开的是什么。弯路也记着：第一版把 `ka-test-install.ps1` 数成
  3 处、干净树直接跑红，差的那一处是它自己的 docstring 写着"never with Start-Process -Wait"——注释不是代码
  路径，于是补了 `<# #>` 状态机，10/10 才对上。
  变异腿从 10 条加到 **14 条**，末尾四条**各只出 1 条 finding**：前三条注在 `ka-worker.ps1` 的普通赋值行
  （那里没有任何 shell 写法，规则 5 全程沉默），最后一条反过来只有规则 5 开口——"这条腿量的就是这条规则"仍旧
  是数出来的，不是我在注释里推的。本机 `----- 5 run, 0 red`、14 条腿全红、`MUTATION CHECK OK: all 14 defects
  each red on their own rule, and the clean copy green`。**仍然拦不住的照旧写明白**（README/PRIVACY/闸门注释
  三处都写了）：已经在册那 10 处如果只把**参数**换成一个不带 scheme 的裸主机，行数不变、也没有 scheme 可读，
  这一层只能靠"面板 URL 是 `ka-core.ps1` 里唯一一个回环字面量拼出来的"间接兜。
  **runner 的数字到齐了，与本机逐字相同**：run `36233069528`（head `46b765e`，`conclusion=success`，
  job `108379761010`）在一次性 Windows runner 上印 `scanning 22 shipped files`、
  `ok rule 1: 12 URL literal(s), 0 only visible once adjacent literals are joined, 0 dangling scheme(s),
  hosts = 127.0.0.1 x11, localhost x1`、
  `ok rule 5: 10 shell hand-off(s) in 6 file(s), counts named = build.ps1 x2, ka.ps1 x2, ka-core.ps1 x2,
  ka-lid.ps1 x1, ka-test-install.ps1 x2, ka-tray.ps1 x1`、`PRIVACY GATE OK`、
  `MUTATION CHECK OK: all 14 defects each red on their own rule, and the clean copy green`、
  套件 `通过 86，失败 0，跳过 5`。那两处 `x2`/`x1` 的分布在 runner 上也是同一份 `$shellAllow` 在对账，
  不是巧合——这台机器与那台机器上的树是同一份 checkout。

- **"扫的是哪些文件"也是同一份问句，只是升了一级：安装器从来没被扫过**（2026-09-26，接上一条）。
  上两条把"找什么名字"改成"管哪种通道"，改完立刻用同一个问句问自己：这条闸门的 `$files` 是怎么来的？
  答案是"顶层 `*.ps1` + `*.bat` + `dashboard/**`"——**`packaging/` 不在里面**，而 `KeepAwake.iss` 是下载者
  双击的第一个东西：它里面一条 `[Run] ... openurl` 就是出网路径，而且发生在本产品任何一行代码运行之前。
  说实话的一半：**当天 `packaging/` 四个文件里字符串 `http` 出现 0 次**，所以这一条关的是一扇门、不是
  已经有人走过的洞；但"我们现在也扫安装器"这句话本身不值得信，除非有一条注入替它作证。于是给变异腿加第
  九条（往暂存副本的 `.iss` 里塞一条升级检查），并给暂存函数加一条守卫：`packaging\KeepAwake.iss` 没跟着
  复制过去就 throw（否则这条腿就是关于虚无的断言，跟托盘那轮"改了没跑过的检查"同罪）。
  A/B 拿旧那份闸门对照（`git show 4669f3c:tests/ka-privacy.ps1`）：同一个注入副本 **旧 exit=0、新 exit=1**，
  `rule 1: 13 URL literal(s), hosts = 127.0.0.1 x11, localhost x1, update.example.com x1`，
  finding 原话 `KeepAwake.iss:66 non-loopback URL literal: https://update.example.com/v1/check (host=update.example.com)`；
  扫描面从 18 个文件变成 22 个，干净树照旧 `PRIVACY GATE OK`。再补第十条腿，量的是**规则之间的接力**而不
  是单条规则：规则 3 按文件名只读 `ka-server.ps1`，那么"监听器出现在别的文件里"到底谁来拦？往
  `ka-worker.ps1` 的副本里塞一个 `New-Object System.Net.HttpListener` + `Prefixes.Add("http://+:$Port/")`，
  实测三条 finding（规则 1 读出 `http://+`、规则 2 两次点名 `HttpListener`/`System.Net` 出现在不该出现的
  文件里），而规则 3 一言不发——**"别人会管"这件事现在也有腿替它作证**，不再是我在注释里推的。
  十条腿全红在各自规则上：`MUTATION CHECK OK: all 10 defects each red on their own rule, and the clean copy green`
  （上一条那句 `all 8 defects` 从这一轮起是旧账）。
  **CI 的账也如实记，而且要记对**：`cc2a23f`（规则 2 那一版）那一轮被 workflow 并发**取消**了（我推 `4669f3c`
  时它还在跑），它验的文件集是 `4669f3c` 的子集，所以覆盖没丢、但那一版的 runner 数字拿不到。而
  `4669f3c`（run `36231033681`，`success`）在 runner 上打的是 `scanning 18 shipped files`、
  `ok rule 4: 1 response header write(s), 0 CORS grant(s), names allowed = Cache-Control`、
  `MUTATION CHECK OK: all 8 defects ...`——**那一版还没有安装器扫描**，所以它只能替规则 4 那一条作证，
  上面"22 个文件 / 第九条腿"的数字不在它的账上（这句先前写得含糊，现在改准）。真正覆盖 `f6c1af6`+`82990e3`
  的是 head `3d81f22`（run `36231766517`，`success`）：runner 上 `scanning 22 shipped files`、
  `----- 23 run, 0 red`、`MUTATION CHECK OK: all 10 defects each red on their own rule, and the clean copy green`、
  `通过 86，失败 0，跳过 5`。上面这些数字到这儿才不只是本机的。

- **同一个洞在隔壁那条规则上又量出来一次：规则 4 只认 `Access-Control` 这一个字串**（2026-09-26，接上一条）。
  上一条讲的是规则 2 的"要去找的 API 名字"清单；改完之后顺手用同一个问法去问规则 4——"如果出网/发头
  用的名字不在你的清单里呢？"。答案当场量出来（`_tmp/privacy-hole-check.ps1`，副本注两行进 `ka-server.ps1`）：
  `$KaCors = 'Access-' + 'Control-Allow-Origin'; Headers.Add($KaCors, '*')` 与
  `Headers.Add('X-Ka-Machine', $env:COMPUTERNAME)` 两种写法，**闸门都 exit=0**、一条 finding 都没有：
  旧规则 4 是"三条调用形状 + 一个字串 `Access-Control`"，拼起来的头名不叫这个名字，陌生的头名它压根不关心。
  前一个是 CSRF 边界被一句话换掉（面板是本机唯一对任意网页敞开的口，`X-Ka-Client` 那条防线整个失效而门禁全绿），
  后一个是把机器名塞进响应头——`PRIVACY.md` 说"不发任何标识符"，而这条规则看不见任何非 `Access-Control` 的头。
  改成管**通道**：`HttpListener` 能设响应头的写法只有 `Headers.Add` / `Headers.Set` / `Headers['…'] =` /
  `AddHeader`，写法是封闭集，所以把每一处写入都枚举出来、每个头名都必须在册（今天在册的就一个
  `Cache-Control`，实测 `ka-server.ps1:346`），`Access-Control*` 永远不许在册，**名字读不出来的写法按最坏情况报**
  （跟规则 3 对读不懂的 `Prefixes.Add` 的处理一模一样：宁可红，不许静默跳过）。读请求头不算设响应头
  （`$req.Headers['Host']` 那四处是这个产品的正经防线，不能被这条规则误伤）。
  量出来的两面：干净树 `rule 4: 1 response header write(s), 0 CORS grant(s), names allowed = Cache-Control`
  照旧 exit=0；两份注入副本分别
  `ka-server.ps1:346 sets a response header whose name this gate cannot read: ...` 与
  `ka-server.ps1:346 sets response header 'X-Ka-Machine'; the allow-list says Cache-Control`，`exit=1`。
  变异腿加到八条（一次一个缺陷、每个缺陷只准点名自己改过的文件），上一条那句 `all 6 defects` 从这一轮起是旧账：
  `MUTATION CHECK OK: all 8 defects each red on their own rule, and the clean copy green`，门禁
  `----- 5 run, 0 red`。**这条规则的边界**：管的是响应头通道，不管 `ContentType` / `StatusCode` 这些强类型属性
  （那里塞不进任意头名）；至于 `HttpListener` 自己默认带出去的 `Server:` 头，那是内核的行为，不在源码文本里。
  **CI 已接上**（run `36231033681`，sha `4669f3c`）：runner 上印
  `ok   rule 4: 1 response header write(s), 0 CORS grant(s), names allowed = Cache-Control`、
  `MUTATION CHECK OK: all 8 defects ...`、整轮 `----- 23 run, 0 red`、套件 `通过 86，失败 0，跳过 5`
  ——家族标记在干净检出上零误伤，这条最有价值的就是它不是在开发机上验的。
  （再往后的第九条、第十条腿属于下一轮，`cc2a23f` 那一轮被并发取消，见下一条。）

- **隐私闸门 rule 2 的 fail-open：这次不是"清单会过期"，是"清单本来就漏"**（2026-09-26，接上一条）。
  前三条讲的是检查内部的手写清单——风险在"将来"。这一条是**今天就摸得到的洞**，而且摸它的是产品对用户
  的头号承诺（`PRIVACY.md`：数据不会离开这台机器）。`tests/ka-privacy.ps1` 规则 2 原来拿一份**要去找的
  API 名字**清单去扫：清单外的名字不会被看见，这是"名单式扫描"的定义而不是疏忽。实测（`_tmp/privacy-hole-check.ps1`，
  把成品面抄进 `_tmp/privacy-hole/` 再往 `ka-worker.ps1` 的副本里加两行）：
  一行 `System.Net.Sockets.Socket(...).Connect(('telemetry' + '.example' + '.com'), 80)`、一行
  `[System.Net.Dns]::GetHostAddresses('collector' + '.example.net')`——**两份旧闸门都 exit=0**，
  连一句 finding 都没有：规则 2 没有一个名字匹配，规则 1 只认 `https?://` 字面量、看不见拼出来的目的地。
  改成扫**家族**：`System.Net` / `Sockets` / `Net.Dns` / `WebRequest` / `WebClient` / `HttpListener` /
  `Smtp` / `TcpListener` / `certutil` / `bitsadmin` / `mshta` / `regsvr32` / `urlmon` / `winhttp` /
  `wininet` / `ws2_32` / `xmlhttp`……理由是结构性的：BCL 的联网类型全在 `System.Net` 底下，P-Invoke 必须
  把 DLL 名写进字符串，外部下载器必须出现在参数里——想不出名字不要紧，**躲不出家族**。改完同一个副本上
  A/B：`socket exit=1`（`'Sockets' appears in ka-worker.ps1 and is not allow-listed` +
  `'System.Net' used by ka-worker.ps1; allow-list says ka-server.ps1`）、`dns exit=1`（`'Net.Dns' appears ...`），
  干净副本 `exit=0` 且 `rule 2: network APIs in shipped code = HttpListener, Invoke-WebRequest, System.Net, WebRequest`
  ——新标记在真代码里的命中就是这 4 个、2 个文件，没有一条是误伤（挑标记时先量过全树命中数，
  `Dns` 这种会撞上 `ka-server.ps1:17` 注释里"DNS rebinding"的写法一律不收）。
  再补两条防空转的：`allow-list names 'X' but the scan never looks for it`（登记了一个扫描不找的标记
  等于假覆盖）、`no System.Net hit anywhere - the scanner itself stopped working`（原来只对
  `Invoke-WebRequest` 有这条哨兵）。
  变异腿顺带从"四个缺陷一起注入"改成**一条腿一个缺陷**：一起注入时分不清哪条 finding 是谁的，
  一个缺陷可以搭另一个的便车照样绿；现在每条腿要求 `exit=1` + 说出该说的那句 + **所有 finding 都指向
  这条腿改的文件**，并在最前面跑一次**未注入**的副本要求它过（不过就说明某条规则太宽）。六条腿实测
  findings=1/2/2/2/2/1：`MUTATION CHECK OK: all 6 defects each red on their own rule, and the clean copy green`，
  门禁 `----- 5 run, 0 red`。`PRIVACY.md` 那句"没有上报代码可跑"跟着补了扫描的是家族不是名字清单。
  **这个洞的边界仍然要说清楚**：家族前缀兜的是**出口**，规则 1 兜的是**目的地字面量**，一个运行时从用户
  配置里读出来的主机名两条都看不见——那条路归 `config.json` 的取值校验管，不归这里。

- **第三份、也是最后一份手写的文件清单：`probe-migrate` 自己抄了一份"程序目录里有什么"**（2026-09-26，接上一条）。
  上两条把托盘 sink 和 CLM 入口改成了发现，`tests/` 里还剩一处 12 行的写死数组——而被抄的那份
  `ka-release-files.ps1` 的头注释记着它**已经被抄过两次、并因此漂移过一次**（`PRIVACY.md` / `SECURITY.md` /
  `CHANGELOG.md` 落地时只有两份探针里的一份跟上了）。现在程序目录 = 发布清单 ∩ "代码自己会打开的东西"
  （`*.ps1` 与 `dashboard\*`），`.bat` 启动器和文档不在里面：迁移逻辑读的是脚本和被面板取用的前端，
  往夹具里塞 `LICENSE` 不会让哪条断言多测到东西。空清单或只捞出库文件一律不许当绿：
  `the derived program list is not a program directory`；清单指到仓库里没有的文件也直接失败
  （`source tree is missing ... lists a file the repository does not have`）。
  线检 `_tmp/wire-check-migrate.ps1`：把探针**从文件头到 `New-Data` 之前**的那段原样切出来（也就是真跑的那段
  推导与 `New-Program`），配一份改过清单的假发布清单，落在 `_tmp/mig-wire/` 的假仓库根上，真仓库一个字节没动。
  四次翻转实测：`baseline exit=0 / DERIVED 12 / COPIED 12`、清单里加一个仓库里**存在**的 `ka-extra.ps1` →
  `exit=0 / DERIVED 13 / COPIED 13`（新脚本自动进来，不用改探针）、加一个**不存在**的 → `exit=1` 点名它、
  清单缩到只剩 `ka-core.ps1` + `README.md` → `exit=1` 报"这不是一个程序目录"。整条探针本机重跑
  `PROBE OK: migration brings an old install forward without ever replacing a file the data root already has`
  （A-D 四段全绿）。**这轮的边界照旧说清楚**：推导的范围仍是那份清单，一个"该随包发出去却漏进清单"的文件
  不归这里管——那是打包规则的地盘，不是夹具的地盘。

- **同一条规矩用到探针自己头上：`probe-clm-gate` 的"有哪几个入口"也是手写的**（2026-09-26，接上一条）。
  A 段拿一份写死的 6 个文件名去查闸门接没接。规则没错，错在它假设"这 6 个就是全部"——今天成立，第七个
  入口落地那天就不成立，而 CLM 闸门恰恰是下载者环境里最容易被半路降级的那道（`ka-gate.ps1` 存在的理由）。
  改成**发现**：入口集合 = 发布清单里的顶层 `.ps1` ∩ "在可执行行上真的 dot-source `ka-core.ps1`"。两个细节
  是实测出来的：`ka-gate.ps1` 只在文档注释里提过一次 `ka-core.ps1`，用行首点源判据它自然落在集合外；
  `ka-guard.ps1` 不点字面量，它先 `$core = Join-Path ...` 再 `. $core`（为了在库缺失时自己印一条告警），
  所以成员测试认这两种写法。顺手把 A 段原来的 `*'<name>'*` 宽松匹配收紧成行首点源——注释里出现文件名再
  也不会被读成"它在第 42 行加载了库"。发现只做一半不够：新加一条 `reaches ka-core but no CLM case runs it`，
  **找到了却没跑过**必须同样算红，否则清单只是把洞从"没看见"改成"看见了但假装没事"；空清单不许当绿，直接
  `PROBE FAILED - no shipped script dot-sources ka-core.ps1`。
  线检 `_tmp/wire-check-clm.ps1`：在 `_tmp/clm-wire/` 里搭一个**假仓库根**（复制 `ka*.ps1` + 一份只留 A 段
  的探针 + 一份改过的发布清单），真仓库一个字节没动。四次翻转：
  `baseline exit=0`（`discovered 6 ... A GREEN: 6 entries, 6 covered`）、塞进没接闸门的 `ka-extra.ps1` →
  `exit=1` 且 `FAIL ka-extra.ps1  gate=- exit=- core=3 no gate dot-source, no exit-2 call, reaches ka-core
  but no CLM case runs it`、塞进**接了闸门但没有用例**的 → `exit=1` 只报后一条（证明两条判据各自独立）、
  把发布清单缩到只剩两个库文件 → `exit=1` 且印那条"成员测试坏了"。整条探针本机
  `PROBE OK: 9 cases green now, 7 red without the gate, 6 entry points gated before ka-core`，门禁
  `----- 5 run, 0 red`。集合的边界也说清楚：**发现的范围是发布清单**，一个存在但从不随包发出去的文件不在
  这里被查——那是另一条规则（什么该进清单）的地盘。
  **CI 已接上**：run `36229452100`（sha `d4ab27a`）在 runner 上印 `discovered 6 shipped scripts that reach
  ka-core.ps1: ka.ps1, ka-worker.ps1, ka-server.ps1, ka-guard.ps1, ka-lid.ps1, ka-tray.ps1`、
  `PROBE OK: 9 cases green now, 7 red without the gate, 6 entry points gated before ka-core`、
  `ok   probe-clm-gate.ps1  15s`、`ok   probe-tray-selftest.ps1  34s`，整轮 `----- 23 run, 0 red`，
  套件 `通过 86，失败 0，跳过 5`。

- **上一条那条腿自己也带着一份写死的清单——这是 `ka-lid` 那个错的第三种犯法**（2026-09-26，接上一条）。
  上一条留下的点击交接判据点名了两处出口（duration 走 `-Minutes`、interval 走 `antiLockIntervalSec`），可
  "菜单还能把数字交给谁"这件事如果是手写的，那第三个交接冒出来时没有任何东西会拦——跟当年 `ka-lid` 漏在
  写死清单外是同一件事。改成先问语法树"**哪些**处理器读了 `$this.Tag`"，每一条都必须被某条 sink 规则认领，
  认领不上就点名整段文字；再补两条破坏：把时长处理器改成 `Set-KaSomething -Seconds ([double]$this.Tag)`（陌生
  出口）、把那一行原样复制一遍（重复出口）。
  第一次跑出来红的是我自己的 harness，三处：
  ① 复制出来的两行文本一模一样，发现循环遍历 `$blocks` 全体，于是同一句碰撞消息印了两遍——
  `FAIL duplicate  problems=3 want 2`。**计数集合和点名集合不能互相污染**，发现集合要 `Select-Object -Unique`。
  ② 拿线检去单独关掉 discovery 那根电线时，删掉一行之后子进程直接炸在
  `elseif : The term 'elseif' is not recognized as the name of a cmdlet` 上——`if/elseif` 是一条链，
  没法只拆一半。**判据要写成各自独立的 `if`**，否则"只关掉其中一条"这个实验根本不存在。
  ③ 线检的驱动脚本又把已知那条教训犯了一遍：父进程 `$ErrorActionPreference='Stop'` 遇上子进程 `2>&1` 的
  stderr 就当场终止，driver 死在第一个**本该红**的翻转上、后面几次全看不到（`NativeCommandError`）。把子调用
  包成 `Continue` 之后才拿到全部六次翻转。
  六次翻转实测（`_tmp/wire-check-t3.ps1`：只抠出这条腿和末尾的 exit-code 判断，跳过所有起进程的腿）：
  `none exit=0 FAILlines=0`（干净树不报警）、把 `Expect` 改错 `exit=1`、把 `Want` 从 0 改成 5 `exit=1`、
  把破坏锚点改成对不上的串 `exit=1` 并印 `sabotage anchor matched 0 times, want 1`、
  **删掉 discovery 那行 → `FAIL unknown sink  problems=1 want 2`**、
  **把"恰好一个"的判断关掉 → `FAIL duplicate  problems=1 want 2`**。后两条是这两根电线能红的证据，
  前四条是它们没在搭便车的证据。
  整条探针 `----- 1 run, 0 red`、`ok   probe-tray-selftest.ps1       62s`（本机，`-Probes -Only tray-selftest`），
  五条破坏各点名自己、干净那棵树一条都点不出来。**仍然没覆盖的部分照旧说实话**：没有任何自动检查真的按过一次
  托盘菜单，这条腿证明的是语法，不是"点一下能起 worker"。

- **上一条那句"CI 一次也没跑过"从这一轮起是旧账；顺手审自己刚写的那条腿，审出两个 harness 骗我**
  （2026-09-26，接上一条）。先闭环：run `36227348476`（sha `74db958`，就是把探针接上去的那个提交）
  `conclusion=success`，`ok   probe-tray-selftest.ps1       25s`，整轮 `----- 23 run, 0 red`，runner 上
  托盘进程真的起来了并印出 `ok   clean        exit=0 lines=7 (3.3s) presetDur en="30 min" zh="30 分钟"`，
  三个突变体各自红在自己的守卫上——`frozen` 在 runner 上印的是
  `preset reads "30 min" but its Tag 30 min is "30 分钟"`，两种语言的位置与本机相反，因为 runner 的界面语言是
  en，判据两侧都读同一份 catalog，所以换语言不影响它红。**顺带一条省事的实测结论**：无头的 GitHub runner 上
  `NotifyIcon` 和 `ContextMenuStrip` 都建得起来，托盘这个面不需要再为 CI 写一个 headless 替身。
  然后回头审我往探针里新加的那条**点击交接**腿——`ka-tray.ps1` 里把 `$this.Tag` 交给引擎的两个处理器，是"预设的
  分钟数离开菜单、进引擎"的唯一出口，也正是本探针要防的单位串线那一类；但**这个仓库里没有任何自动检查真的按过一次
  托盘菜单**（真点一下会起 worker、注册计划任务，落在谁的机器上都不该），所以它只能读语法树：恰好一个时长处理器把
  `$this.Tag` 交给 `-Minutes`、恰好一个间隔处理器把它写进 `antiLockIntervalSec`、且两者之间不许出现任何算术
  （`* 60` 与 `/ 60` 是同一个病换了个符号）。第一版带着两个 bug，都不是产品红，是**我的检查自己不会红**：
  ① **`$bad = 0` 排在这条腿之后**。腿里的 `$bad++` 加在一个尚未初始化的变量上，紧接着被 `$bad = 0` 抹掉——
  FAIL 照样印在屏幕上，探针**照样 exit 0**，这条腿当时纯属装饰。修法是把整条腿挪到计数器初始化之后，并且不再靠
  "我看过顺序了"，而是拿索引钉死：`order: badInit=8209 leg3=10554 tail=11682`，三者不满足这个次序脚本直接 throw。
  ② **"点名点错了就该红"那句判据恒假**：写成 `$probs[0] -notlike '*handler*'`，而所有问题文案里都带 `handler`
  这个词，于是整条 `and` 链永远为假，那句 `did not name` 一次也不会触发。判据不能"大概能抓到"，得能红：改成每条破坏
  自带一个 `Expect` 子串（`duration handler does arithmetic` / `interval handler does arithmetic` /
  `duration handler no longer contains $this.Tag`），再跑一次线检（`_tmp/wire-check-t3.ps1`：只抠出这条腿和末尾
  的 exit-code 判断，跳过所有起进程的腿）——`none`→exit 0、把 `Expect` 改错→exit 1 并印
  `did not name "interval handler does something else entirely"`、把 `Want` 从 0 改成 5→exit 1、把破坏的锚点改成
  对不上的串→exit 1 并印 `sabotage anchor matched 0 times, want 1`。四次翻转就是这根线的四段，挨个通。
  本机门禁 `----- 5 run, 0 red`，整条探针本机 `PROBE OK: ... 3 mutations each red on their own guard and green
  with the injection switched off`（约 70 秒，runner 上 25 秒）。**这条腿没覆盖的部分留着说实话**：它是语法层的，
  证明的是"没有算术夹在 `$this.Tag` 和引擎之间"，**不证明真按一次菜单能起 worker**；"真的点击一次托盘菜单"这件事
  本仓库至今仍然没有任何自动检查做过。

- **`ka-tray.ps1 -SelfTest` 那个主体，CI 一次也没跑过**（2026-09-26，接上两条）。先记账：上一条推上去之后
  run `36225438637`（sha `90438c3`）全绿——门禁+探针 `----- 22 run, 0 red`，套件 `通过 86，失败 0，跳过 5`，
  被挪出 `if ($running)` 的那半条在 runner 上印 `PASS`（用例名"英文界面上不会有中文：ka.ps1 status 的真实输出"）。
  然后回头查上一条自己在托盘里加的那条"预设文字必须等于 Tag 真值"的检查到底由谁执行：`grep -rn ka-tray tests/`
  当时只有四处——两份文件清单（`ka-release-files.ps1:16`、`probe-migrate.ps1:14`；前者那张手打清单此后被
  `ka-release-files.ps1` 头部的树推导取代，2026-09-30 核时该行已是空行）、`probe-clm-gate.ps1` 的
  `$entries` 数组、和 case `tray/clm`。其中**只有最后一处会真的启动一个托盘进程**，而那条腿断的是**闸门拒绝**
  （`ok tray/clm exit=2 lines=4`），`exit 2` 发生在 `ka-gate.ps1` 调用处、远在 `-SelfTest` 主体（`ka-tray.ps1:411`）
  之前。也就是说：**CI 上唯一会启动托盘自检的那条腿，恰恰是永远走不进自检主体的那条**。同一个位置上的
  `ka-server.ps1 -SelfTest` 有套件那条 `It 'ka-server.ps1 -SelfTest 通过'` 接着，托盘什么都没有。上一条把
  "第 84 条从来没执行过"当教训，两天后自己在另一个面上犯了同一件错——**"我改了一段能跑的检查"和"那段检查被跑过"
  是两件事，后者要有进程证据。**
  补了一条 `tests/probe-tray-selftest.ps1`（八条腿，本机约 58 秒）：
  ① 先把"exit 0 不等于验过"这个形状钉成一条腿——`KA_LANG` 设着跑同一个入口，主体印
  `SELFTEST lang=skip(KA_LANG outranks config by design)`、再印 `SELFTEST OK`、**照样 exit 0**（实测，不是设想）。
  所以干净那条腿断的不是"OK 与退出码"，而是两种语言各自真的渲染过（`presetDur en="30 min" zh="30 分钟"`）、
  菜单结构在（`durations=5 intervals=4`）。② 三个突变体各红在自己那条守卫上，且同一棵树把注入关掉必须回绿：
  `frozen`（解析出新语言却不调 `Update-TrayLabels`）死在文案保真——`preset reads "30 分钟" but its Tag 30 min is
  "30 min"`；`nolang`（根本不重新读 config.json）文案保真看不见它（标签和期望一起漂），只有"两种语言不许同文"
  那条后备拦得住；`unit`（拿秒格式器去贴分单位的 Tag）就是当年那个 `30 分钟` 显示成 `30 秒`。
  **这条腿的顺序是量出来的，不是推出来的**：`frozen` 一开始我按"它该红在语言同文那条上"写判据，harness 直接回
  `died somewhere else, not on "kept their text across a language change"`——文案保真更强，先把它抓走了。于是
  两条判据分开：`frozen`/`unit` 同归文案保真管，就额外要求**这两条红字不许相同**（相同就说明其中一个在搭另一个的
  便车），`nolang` 才归后备管。顺带把"每棵突变树都要有注错关闭的对照"用满：八份 `ka*.ps1` 全量拷贝逐字节 sha256
  核对，只有被注入的 `ka-tray.ps1` 允许不同，而且必须只差在被点上那几行——差多了就抛，不等结果出来再说"可能是副本的问题"。

- **两条"红"都不是产品红，但各值一次记录**（2026-09-26，接上一条）。
  ① 上一条的探针写完之后我起了**两条同时跑的** `tests/ka-ci.ps1 -Gates -Probes`：第一条在后台，我看它的输出文件是
  空的就以为它停了，于是又开一条。两条都红，红得毫无道理：`ka-syntax.ps1` 在 `Get-Content` 一个
  `_tmp\motw-run-<guid>\web\ka-core.ps1` 时报 `PathNotFound`（它递归扫全仓 `.ps1`，扫到一半被另一条的 `probe-motw`
  把脚手架删了），`ka-privacy.ps1` 报 `ka-core.ps1:305 non-loopback URL literal:
  https://telemetry.example.com/v1/event`——**而工作树里的 ka-core.ps1:305 是一行注释**，那条 URL 是
  `ka-privacy-mutation.ps1` 注入进副本的诱饵，被另一条同时扫盘的门禁读了去。先钉"是不是产品真的坏了"：
  `git status --porcelain` 只有我在改的那三个文件，`git diff HEAD -- ka-core.ps1 ka-lid.ps1 ka.ps1` 空——
  **没有一个就地突变体没被还原**。教训落在流程上：门禁与探针**不可重入**，`_tmp/` 是共享的，而
  `probe-culture-mutation` / `ka-privacy-mutation` 还会就地改真文件再还原，所以一台机器上同一时刻只允许一条 `ka-ci`；
  后台任务"没有输出"不等于"已经结束"。
  ② 单条重跑之后 `----- 23 run, 1 red`，唯一那条红是 `probe-mutex-identity.ps1` 自己拒绝下结论：
  `FAIL control failed: the holder never got the mutex, so contention proves nothing (got=False) - 若这台机器正在防休眠，
  先停掉再跑本探针`。原因在它自己的 B 段：那条腿拿**默认数据根**算互斥体名（为的就是证明"两个安装目录共用一个数据根
  = 同一个互斥体"），算出来正是这台机器**正在跑的那份保护**占着的那个名字，对照组抢不到，于是它按设计拒绝——
  不是回归，也不会偶发。**正在跑的保护是这台机器的用途本身，不会因为一条探针想绿就把它停掉**；这条在 CI 的一次性
  runner 上每轮都是绿的（那里没有人在防休眠）。新增的 `probe-tray-selftest.ps1` 在这一轮里印 `ok 64s`。

- **同一条规矩用到断言身上：躲在一个 `if ($running)` 里的那半条牙齿**（2026-09-26，接上一条）。上一条
  推上去之后 run `36224674886` 全绿，那条用例第一次印出 `PASS`（套件 `通过 86，失败 0，跳过 5`，跳过名单
  回到剩下 5 条机器形态；门禁+探针 `----- 22 run, 0 red`）。顺手把同一类洞在**整个套件与 17 条探针**里扫了
  一遍——`_tmp/scan-conditional-asserts.ps1` 走语法树：从每个 `Assert*` 调用往 `.Parent` 上爬，落在某个
  `IfStatementAst` 里的就列出来（PS 5.1 里这个节点叫 `IfStatementAst`，7.x 才改名 `IfStatement`；
  `$if.Statements` 是普通 `List[StatementAst]`，没有 `FindAll`，所以只能从断言往上爬而不是从 `if` 往下找）。
  结果：**探针 17 条 0 个**，套件 20 个（其中 15 个是"这台机器读不到 X 就不比"的环境闸，与那 5 条跳过同源），
  真正值得改的是一个：`status` 那条用例里"屏幕画到底部没有"的检查（`Assert ($out -match 'Watchdog\s')`）
  **写在 `if ($running)` 里面**——也就是说，**恰恰在机器没在保护的那一半状态下，这条断言不做任何事**，
  而那一屏正是用户最常看到的。它守的原始缺陷就是"中途崩了但前半屏看着正常"（`activeFlags` 的 `[int]` 溢出）。
  把它挪出守卫（`flags=0x…` 留在里面：没有 worker 时本来就不该有标志位，本机实测印证：空数据根下
  `Watchdog=True / flags=False`）。**这条挪动值多少，用一个突变量出来**（`_tmp/check-watchdog-assert.ps1`，
  连跑两遍一致）：在 `Show-Status` 的状态分发之后注入 `if (-not $s.running) { return $null }`——**安静地**
  截断（退出码 0、无报错文本、State 行还在），干净树上 `Watchdog=True`、突变树上 `Watchdog=False`，而
  `$running` 两边都是 `False`，所以旧写法连"跳过"都不算、直接当没事。四条判据各盯一件事：干净树画到底 /
  突变体确实"安静"（否则同一用例里更早那条 `Assert-Eq $rc 0` 会先红，这次挪动就不是唯一防线）/ 新断言抓到 /
  旧断言看不见。**两次被自己的 harness 纠正**，都记下来：① 第一次把 `return` 注在 `st.notRunning` 那一行
  后面，本机根本没走那条分支（这台机器有别的目录的 worker，走的是 `st.foreign`）——突变体打印出来仍然
  `Watchdog=True`，harness 喊"WIDENED ASSERT CATCHES IT = WRONG"，是它告诉我注入没生效，而不是我看代码猜；
  ② 第二次改注在分支分发**之前**，结果 State 行也跟着没了，太狠，会被更早的断言抓住，于是加一条"突变体必须
  仍然安静"的判据把它挡回来。同一个教训第二次出现：**突变要红在那条守卫上，红在别处等于没测。**

- **CI 全绿，而绿名单里第一条"跳过"是一条永远跑不到的用例**（2026-09-26，接上一条）。上一条推上去之后
  run `36223375699` 每一步都绿（门禁+探针 `----- 22 run, 0 red`，套件 `通过 85，失败 0，跳过 6`，安装/卸载
  与打包全过），但把跳过明细逐条读了一遍——**第一行就是上一条新加的那第 84 条 `It`**，理由写着"`KA_LANG`
  压过 config，这两条量的正是 config 那一路"。而 `KA_LANG` 是这个套件自己在 `tests/ka-tests.ps1:57` 钉死的
  （钉它本身有理由：一批断言直接比对中文原文，英文机器上不钉就会误红）。所以那句 `if ($env:KA_LANG) { Skip }`
  **在任何一台机器上恒真**：这条用例从写下那天起一次都没执行过，CI 绿的是"它跳过了"。上一条 README 里写的
  "它要等下一次 CI 才有自己的执行结果"，等的结果就是这一条。洞的长相值得记下来：**它和其他 5 条货真价实的
  机器形态跳过排在一起，措辞也一样**，只有把它和钉死的那行环境变量对读才看得出是恒真。
  **改法**：删掉那条守卫，改成用例体内 `Remove-Item Env:KA_LANG` 起手、`finally` 里按原值放回（连同 config
  文件与 `$script:KaUiLang` 三样一起复原），并补三条断言钉住**反面**——`KA_LANG` 设着时一次 config 写入
  **不得**盖过它。这一条正是 `Set-KaConfig` 里那句 push 用 `-Configured` 而不用 `-Explicit` 的全部理由：
  写成 `-Explicit`，用户文档里那条逃生门会被一次面板点击永久关掉，而原来的 6 条断言一条都看不见。
  **六条腿量过才算改完**（`_tmp/check-language-it.ps1` + `_tmp/run-language-it-child.ps1`：只抽取 `It` 正文、
  在独立子进程里对着临时 `KA_DATA` 跑，`tests/ka-tests.ps1` 本身从不执行；每条腿打印"求值了几条断言"，
  绿不再是"没红"而是数出来的；连跑两遍逐字节一致）：① 新正文 / 工作树 ka-core → PASS 且**求值 8 条**
  （下限 8 本身就是防空转的闸）；② **旧正文 / 同一份代码 → SKIP 且求值 0 条**，把洞量化成一个数字；
  ③ 去掉写方 push → 红在第 2 条；④ `Set-KaUiLanguage` 内部改 `-Explicit` → **前面 7 条全绿，只红在最后一条**
  （证明那三条新断言是这条缺陷的唯一防线，不是锦上添花）；⑤ 让缓存每次自己重读文件 → 红在第 4 条（那条
  "不许自己失效"的断言真的有牙齿）；⑥ `1992a64^` 那份 ka-core → 红在第 2 条。
  **两处 harness 自己的 bug，都是"绿了也不作数"那一类**：其一，`$results += ...` 写在函数里——PowerShell
  的 `+=` 在函数作用域读的是脚本变量、写的却是**新建的局部变量**，驱动末尾那句 `LEGS WRONG: 0 of 0` 于是
  永远成立，第一版跑出来的"六条腿全对"是一行假绿（现在改 `$script:results` 并加了 `results.Count -ne 6`
  直接抛）；其二，子进程里 `$script:KaUiLang` 是冷的，`Get-KaUiLanguage` 第一次调用会**顺手把缓存填上**，
  于是突变体 ③ 逃过第 2 条断言、死在第 3 条——真套件跑到那一条时缓存早被前面一百个用例焐热了。harness 缺
  的不只是代码，还得有**被测代码当时所处的状态**；现在子进程先 `$null = Get-KaUiLanguage` 焐热再跑正文，
  ③ 才按声明死在第 2 条。另外这次又踩了一次自己写错的锚点：突变 pattern 的缩进数了 8 个空格（实际 4 个），
  守卫"必须恰好命中一次"当场拒绝写入——那条守卫是它自己救过场面的地方。
  **README 里那条数字也跟着说实话**：上一条写的"执行 90 次 / 跳过 5"是我拿 85+5 反推的，按 `== 汇总 ==`
  之前逐行数 `PASS`/`SKIP`/`FAIL` 行实际是 **91 条判定行 / 85 / 6 / 0**；三处引用统一改成"数出来的行"，
  并且写明那 85 属于改之前的正文。门禁 `----- 5 run, 0 red`（含 `tests/ka-tests.ps1` 在 PowerShell 5.1 下
  可解析）。按惯例不在本机跑全量套件；这条用例自己的下一次 CI 结果在上一条里：run `36224674886` 第一次印出
  `PASS`。

- **面板切了语言，活着的那个进程不跟着切**（2026-09-26，托盘是活的读者）。`dashboard/app.js` 的注释写着
  语言存进 config.json"所以命令行和面板都跟着面板走"——命令行那半是对的（每次调用都是新进程），**托盘那半是
  错的**：`Get-KaUiLanguage` 把解析结果缓在 `$script:KaUiLang`，一个进程一辈子只解析一次，没有任何东西去动
  它。本机实测（`_tmp/check-language-cache.ps1`，两遍一字不差）：磁盘上 `config.json` 已写着 `"language":
  "en"`，同一进程里 `Get-KaUiLanguage` 仍回 `zh`、`Get-KaText tray.mi.stop` 仍印 `停止保护`（4 个非 ASCII），
  而同一时刻新起的进程回 `en`。落到界面上就是：面板里切成 English 之后，托盘**表头和 tooltip 换了、菜单项
  还是中文**——比整块中文或整块英文都糟。
  修法是三个机制，每个各留一条红的：① 写的一方 `Set-KaConfig` 落盘成功后把自己进程修正（那行的 `[void]`
  是承重的：字符串一旦漏进成功流，所有 `if (-not (Set-KaConfig ...))` 调用点就变成了跟数组比）；②
  `Set-KaUiLanguage -Configured` 解析并**返回**解析结果——用 `-Configured` 而不是 `-Explicit`，否则 `KA_LANG`
  这个写明可以强制语言的后门会被文件值悄悄缴械；③ 读的双方在**本来就读配置的地方**推一把：托盘
  `Refresh-State`（每 tick）、面板请求循环里"`X-Ka-Lang` 缺席"那一支（CLI 和探针不带那个头，正是文件说了算
  的那批）。缓存本身不加 TTL、也不改成"每句话查一次盘"：面板已经用 `KaReqLang` 证明"外部推"这条路走得通，
  反过来做代价在每条路径上。
  验证是一次性 harness `_tmp/check-language-fix.ps1` 十腿，两遍一致；`tests/ka-tests.ps1` 全程没执行过。
  1 工作树绿；2 关掉写方自修 → 新那条 `It` 红在「连着改两次语言，第二次没跟上」；3 去掉 `Set-KaUiLanguage`
  的返回 → 红在「没把文件里的语言解析出来」；4 把字符串放进成功流 → 红在「返回值不再是布尔，而是
  `[en True]`」；5 拿 **HEAD 那份 ka-core**（也就是发出去的 v1.0.0 的库）跑同一条正文 → 红在第二句，所以
  「那一版确实会冻」是量出来的不是推的；6 真托盘 `-SelfTest` 两条 lang 腿绿（`en` 行零非 ASCII、`zh` 行有）；
  7 把托盘那两行推换成 `$want = $script:TrayLang` → 两条腿全中文、自测红在 `kept their text`；8 活着的面板
  收到不带语言的请求、文件由 zh 改 en → `reason` 从 10 个汉字变成零非 ASCII 且点名 `language`；9 对
  ka-server 那三行做同样突变 → 改完文件它仍然中文（这一腿**写的时候先错位过**：最初复用了托盘的突变树，而
  那三行是面板走的、托盘根本不走，跑之前换成给面板自己的突变才真的有牙齿）；10 见下一条。
  **第 10 腿抓到的是本轮自己写进去的缺陷**：`Update-TrayLabels` 用 `Format-KaDuration ($item.Tag)` 重建时长
  预设文案，而 **Tag 存的是分钟、`Format-KaDuration` 收的是秒**——换一次语言把「30 分钟」重贴成「30 秒」，
  数字没变、时长少了六十倍。第一版九腿看不见它（那五条只问「en 和 zh 是否不同」），所以它当时是绿的；现在
  预设表把两个单位分开存（`Sec` 给文案、`Min` 给点击），`Format-DurationPreset` 是唯一一处换算，自测另加
  一条「每个菜单项写的必须还是它 Tag 那一段时长」，第 10 腿把这个缺陷重新注入回去，红在
  `preset reads "30 s" but its Tag 30 min is "30 min"`。顺带去掉一处老脆弱：预设原本是「本地化文案当字典键」
  的 `[ordered]@{}`，两个文案一旦撞车就静悄悄少一项，现在是数组，实测 `durations=5 intervals=4`。
  过程里被自己的 harness 咬到两次（记下来因为它还是「绿了也不作数」那一类）：① 子进程用 `2>&1` 收，红腿的
  stderr 在 `$ErrorActionPreference='Stop'` 下变成**本进程**的终止错误，harness 死在第一条它本该量化的红上；
  ② 打点用 `Write-Output` 的函数同时返回哈希表，统计行被 `$results +=` 一起收进数组，那些字符串既没露面也
  不会自己喊——本轮第一次跑只出到第 2 腿，看着像修复崩了，其实是量具崩了。现在打点走 `Write-Host`，
  子进程调用外面单独降级 `$ErrorActionPreference`。
  **本轮在本地跑了什么**：十腿两遍一致（`_tmp/langfix-out.txt`）；`tests/ka-ci.ps1 -Gates -Probes` 22 跑
  1 红，红的还是那条 `probe-mutex-identity`——本机保护正在跑（`state.json` `pid=21688`、`Test-KaWorkerMutex`
  实测 `True`、`Local\KA-Worker-DCA86D0FFFB8` 实测 `created=False got=False`，而 `Global\` 同名拿得到），
  C 段要做默认数据根 mutex 的第一个持有者，前提不成立；与 2026-09-25/26 那两轮的记录同一条红，不是回归，
  也不去动那个 worker（CI 的 runner 上没有活 worker）。`tray -SelfTest` 这次是第一次在本机 FullLanguage 下
  真跑通全绿。全量套件按惯例不在本机跑，新加的第 84 条 `It` 要等下一次 CI 才有自己的执行结果。

- **那三条"别把句子送上线路"的规则，自己的文件清单是写死的**（2026-09-26，接上一条）。上一条修完，顺手
  回头审规则本身，量出来的第一件事就是**覆盖不全**：三条规则各自硬编码一份文件清单，而 `ka-lid.ps1`
  有 3 个 `Add-KaLog` 调用点（实测 46 个点里它占 3），却不在日志规则那份六文件清单里——也就是说
  "往 ka.log 写 Windows 原话"这个刚修完的缺陷，**在合盖那条路径上照样能悄悄溜过去**。清单现在改成
  从仓库根目录扫 `*.ps1`（实测 8 个：ka / ka-core / ka-gate / ka-guard / ka-lid / ka-server / ka-tray /
  ka-worker），并且每条规则带一道**防空转下限**：扫不到 `ka-core.ps1` 就红、`Add-KaLog` 调用点数不到
  40 个（实测 46）就红、`Reason`/`action` 赋值行数不到 60 就红（实测 86 与 70）。下限不是为了卡别人，
  是为了"脚本搬家以后规则一行也扫不到、却报绿"这件事自己出声。
  **突变腿从 7 条扩到 13 条**（`_tmp/check-log-ascii-rule.ps1`，只抽取 `It` 正文跑，从不执行
  `tests/ka-tests.ps1`）：新增的三条是关键——第 8 腿拿 `daa5ced` 那份六文件清单跑同一个 ka-lid 突变体，
  **它必须绿**（这就是"洞是真的"而非"代码碰巧干净"）；第 9 腿换成发现式清单，同一个突变体必须红且
  **只点 `ka-lid.ps1:280`**；11a/b/c 把三条规则指向空目录，必须各自喊出来而不是绿。另外两条老腿的基准
  从"HEAD"改成钉死的 `daa5ced^`：修完提交之后 HEAD 已经含修复，还拿 HEAD 当"改前"就是自己跟自己比。
  **连跑两遍 13 腿全对，门禁 5 道 0 红**（`tests/ka-tests.ps1` 仍 83 条 `It`，2452 → 2468 行）；探针
  17 条跑完仍是那 1 条红——`probe-mutex-identity` 的 C 段要做默认数据根 mutex 的第一个持有者，而这台
  机器上保护正在跑（`state.json` 的 `pid=23496` 存活、文件 mtime 2026-09-26 01:40:21，`Test-KaWorkerMutex`
  实测 `True`，`Local\KA-Worker-DCA86D0FFFB8` 被它占着）。红得和上一轮一字不差，不是回归，也不去动那个
  worker。github.com 还没通（api 200 / github 000，代理端口没人监听），所以**在本地替 CI 先看了一遍**：
  `git clone` 一份干净副本（`bad35e7`），用**那份副本自己检出的规则文本**跑它的源码，三条全绿
  （副本里 `tests/ka-tests.ps1` 实测 BOM 在、CRLF 计数 0）。
  也就是说推送之后 CI 那三条不该出意外，真出意外就是 runner 环境而不是规则本身。
  过程中被自己的 harness 咬到两次，都记在这里因为它正是"绿了也不作数"的那一类：① harness 函数用
  `Write-Output` 打统计行，返回值就变成了 `[信息, 目录]` 数组，`$root` 拿到那句中文，`Get-ChildItem`
  对一个不存在的驱动器**报的是"-File 参数不存在"**而不是路径错——一个纯工具 bug 长得像语法不支持；
  ② `Invoke-It` 会设 `$script:root`，而建树函数恰好也叫 `$root`，于是第 8/9 腿的"干净突变树"其实是从
  上一腿的泄漏树复制来的，两腿因此同时错位。现在建树逐个文件比 `Get-FileHash` 与仓库现状，不字节相同
  就直接抛。同一次复核还改掉上一条里的一个数：**12 句原话落在 11 个 `Get-KaErrorToken` 调用点上**
  （看门狗的 `action` 与 `GUARD-FAILED` 共用一个 token），上一条写"12 处调用点"是把函数定义也数进去了。

- **`ka.log` 里的本地化句子换成错误码**（2026-09-25）。README 与 PRIVACY 承诺日志是 ASCII 机器词汇，
  实际却在失败行上食言：`server request error: 无法连接到 CIM 服务器。` ——Windows 会按系统显示语言翻译
  `Exception.Message`，而**异常类型名、HRESULT、Win32 错误码、cmdlet 的 `FullyQualifiedErrorId` 它不翻译**。
  新增 `Get-KaErrorToken`，只留这几样，形状 `<类型>#<HRESULT>[#win32=<码>][#<错误 id>]`；改前那一版上 12 处
  往日志或面板 `Reason`/`action` 里写原话的语句全部改掉，落在 **11 个调用点**上（ka-core 4：boot-task 拒绝、
  guard 装/卸、evidence；ka-server 4：json 序列化、两处启动失败、请求循环；ka-worker 2；ka-guard 1——
  `action` 与 `GUARD-FAILED` 那行共用同一个 token，看门狗的 `action` 从 `"error: <句子>"` 变成 `'error'` +
  `err=<代码>`）。**本机对着真 CIM 失败复算**：旧那行 6 个
  汉字，新那行 `err=CimException#0x80131500#HRESULT 0x8004100e,GetCimInstanceCommand` 零非 ASCII；手工
  `throw` 的中文 → `RuntimeException#0x80131501`（这条说明为什么不能指望 id：它可能就是句子本身，所以
  token 只在类型/HResult/Win32 码之后追加 id，且 id 含非 ASCII 时直接丢弃）；被包一层的 .NET 异常取最
  内层 → `IOException#0x80070020`；端口被占 → `HttpListenerException#0x80004005#win32=183`（HRESULT 一律
  是 `0x80004005`，只有 Win32 码说得出"已经存在"，故 `ExternalException` 额外取 `NativeErrorCode`）。
  测试加了两条能咬的：`Add-KaLog` 从"数源码里的汉字"扩成**看语法树**、出现 `Exception.Message` 就红；
  另一条管 `Reason` / `action`。后者唯一的豁免是配置被拒那一行——`Set-KaConfig` 抛的句子本来就是我们
  自己的词典、按请求语言出，豁免靠行尾 `# refusal-wording only` 标记，**把标记删掉测试必须变红**（这条
  也核了）。七条腿一次性核完并连跑两遍一致：工作树绿 / HEAD 红且点名 / **旧规则对 HEAD 绿**（证明 v1.0.0
  的检查是瞎的，不是被测的代码碰巧干净）/ 单行突变只点那一行 / 删标记红。
  **同类问题还没修的那一半**：19 处把 Windows 原话塞进词典句子的 `{msg}` 占位符仍然在（`proc.noStart`、
  `server.noStart`、`guard.defFail`、`ka-core.ps1:335`、`ka-lid.ps1` 四处、面板 `api.badJson`、托盘 8 处
  （气泡副文本 6、状态读取失败的标题 1、`SELFTEST FAILED` 输出 1）、`ka.ps1` 两处）。句子是翻对的，插进去那一截不是——英文面板上会中英混排。这次没动它：
  改成"只给代码"还是"代码 + 可翻译句子"是个协议决定，得连面板怎么显示一起定，不顺手改。
  **看得见的变化**（同一决定的另一面，先记下）：看门狗装不上时，面板气泡与 CLI 那行现在末尾是一串
  代码（`guard.fail {op} {msg}` 的 `{msg}`、`cli.guardBootDenied` 的 `{reason}`），不再是一句 Windows 的
  话——跟 `config.writeFail` 用 `Get-KaLastWriteCode` 是同一个形状。代码能 grep、能贴进 issue，但它不
  "读得懂"；中文 CLI 用户在中文机器上拿到的确实比原来生涩一点（原来是"拒绝访问。"，现在是
  `...UnauthorizedAccessException#0x80070005,...`），换回来的是同一条消息在英文面板上不再混进中文。
  下一步该给这两个表面补一句"把这串代码贴到 issue 里"的提示，属于 v1.1 的面板打磨，不混进这次修复。
  **本轮在本地跑了什么**：门禁 5 道全绿（含改过的 `tests/ka-tests.ps1` 能被 PowerShell 5.1 解析）；探针 17 条跑完
  1 条红——`probe-mutex-identity` 的 C 段要做默认数据根 mutex 的第一个持有者，而这台机器上保护正在跑
  （worker pid 23496 持有 `Local\KA-Worker-DCA86D0FFFB8`，`Test-KaWorkerMutex=True`）。用 `git archive HEAD`
  摊开一份**纯 HEAD** 跑同一个探针，红得一字不差（`got=False`），所以是机器状态不是回归；这条前提现在写进了
  探针注释（CI 的 runner 上没有活的 worker，那条腿在那里本来就是绿的）。全量套件按惯例不在本机跑。
- **README 里两个自己被磁盘证伪的数字**（2026-09-25）。面板词典写"两套词典 459 个键"，实测
  `dashboard/i18n.js` 的 zh 块与 en 块各 470 行键（`awk` 按两个块的行范围数）；服务端词典没有直接写数，
  就按套件自己的口径写 `$script:KaUi.zh.Count` = 372（加载后读，不是数行数）。另一处是把执行数当静态数
  用："89 个行为测试（82 个 It）"——静态数早就是 82 之外的数了，本轮加了一条测试后 `grep -c "It '"` = 83，
  而 89 是 2026-09-08 那轮 CI **实际执行**的次数。现在三处统一写成"静态 83 / 最近一轮执行 89"，并且明说
  那句"通过 84"属于 2026-09-08 那一轮、它跑的时候第 83 条还不存在——新加的那条要等下一次 CI 才有自己的
  结果。同一条规矩对它自己成立：数字要写口径，引用哪次运行就说哪次运行的数。
- **发布这一侧：成了**（2026-09-08 16:30:06Z）。在那道读回 release 页的断言之上再发一次，
  `v1.0.0` 的 Release 页上真有三个文件，而 GitHub 自己算出的资产摘要与 release 里那份 `SHA256SUMS`
  **逐字节相同**（zip `7f460cd8…4e15`、setup.exe `6769efea…ebfc`）——也就是说下载者照 README《先核对哈希》
  那段粘一遍，两个产物都会印 `OK`。**一处别说满**：CI 编出来的这两个哈希和本机同一次构建的
  （`384db759…` / `34b2a2a9…`）**不一样**，zip 与 setup.exe 里嵌了构建时刻，本项目没有可复现构建。
  哈希能回答"这份文件和他发布的那份是否一致"，回答不了"这份是谁编的"——后者要代码签名，v1.0 没有，
  理由写在 SECURITY.md。winget 清单是下一件事。
- **release notes 模板与 README 的第一步对齐**（2026-09-08）：模板里 portable 那条写的是"解压后双击
  `panel.bat`"，而 README《30 秒上手》第 4 步是 `on.bat`——下载者先看到的两句话给了两个不同的第一动作。
  现在模板写的是双击 `on.bat`、`off.bat` 结束，`panel.bat` 降为"要看面板就开它"。**已经发出去的 `v1.0.0`
  页面没有手改**：那条 notes 是流水线在 tag 那一版上渲染出来的，绕过流水线去 `gh release edit` 会让页面上的
  文字不属于任何一次构建。措辞随下一次 release 生效。要核的是这条不变量：**release notes 里 portable 那条
  的第一动作必须和 README《30 秒上手》第 4 步是同一个**（现在是 `on.bat`，`off.bat` 收尾，围栏和两个带版本号
  的文件名都在）。本机用一个一次性脚本核的——把 `release.yml` 里那个 `Release notes` 步骤**原样抽出来执行**
  （不是抄一份模板来验），再要求三处突变各自变红：`@VERSION@` 没替换、旧的 `panel.bat` 优先措辞、线上那一版
  真实 notes（它照旧措辞，所以必须红在 on.bat 与 off.bat 两条上，同时代码围栏和两个文件名必须仍然绿，
  否则是在验自己抄错的模板）。**那个脚本在 `_tmp/` 里，gitignore 之外没有它，不属于门禁**——留在这里的是
  不变量本身和十行就能重搭的核法，不是某个文件的权威。
- **README 开头重写为说人话**（2026-09-08）：原来那七条密不透风的 bullet 是写给自己看的——零依赖、
  免登录、分发路径、面板、说真话、许可，每一条都对，但没有一条回答"这到底是不是我要的东西"。现在是
  四块：它解决哪一种具体的烦、适合谁（以及**不适合**谁，包括 ConstrainedLanguage 那台根本跑不起来的机器）、
  一张硬事实表（系统要求 / 权限 / 联网 / 分发 / 控制 / 有效性 / 卸载 / 文档 / 许可）、四步从下载到
  `on.bat`。所有数字和"实测"字样都往后指，指向本文里那些能对着磁盘复算的章节，开头不立新的证据。
  同一份介绍的短版写进了仓库的 About（description + 指向 Releases 的 homepage + 11 个 topic）。
- 面向下载者的那一节已经写进 README（《拿到 release 之后》：三件套、怎么核对哈希、第一次运行 Windows
  会说什么、两条分发路径各自的行为）。**机器支持矩阵刻意不再独立成页**：同一台机器的适配结论写两处
  迟早互相打脸，这和"发布清单只留一份"是同一个理由。
- v1.1 候选：PID 绑定、`PowerCreateRequest`/`PowerSetRequest` 熄屏模式、全局热键、托盘预设、
  被守护应用、全屏自动释放、更多语言、更新检查（那会是这个工具第一次对外发请求，会写进 PRIVACY.md）。

## [1.0.0] — 2026-09-08

第一个对外发布的版本。定位就两件事：**说实话** + **装得上、卸得掉**。

### 新增

- **双引擎防休眠**：`SetThreadExecutionState` 电源请求（防睡眠、防熄屏，进程退出即释放）
  + 防锁屏心跳（F15 按键或 1 像素鼠标移动，重置系统空闲计时器）。
- **本地面板**（`panel.bat`）：只监听回环，状态台 / 心跳波形 / 对账条 / 时长预设 / 运行日志 /
  合盖预报。任意网页不能替你改电源设置（`X-Ka-Client` 头 + Origin/Host 双重固定 + 无 CORS 批准）。
- **有效性是实测的**：`ka.bat evidence` 直接读内核电源日志，给出最近 N 小时"到底待机过几次"，
  并区分屏幕熄灭与真睡眠；面板上"有没有效"不是猜的。S3 传统待机 / 读不到日志的机器上如实降级，
  不给你一块假绿。
- **远程无人值守链**：`intent.json` + 看门狗计划任务（`KeepAwake-Logon` / `KeepAwake-Guard`，
  标准账户可装）+ 可选 `KeepAwake-Boot`（S4U，需管理员）。断电自恢复链条每一环都写明"什么时候会拉起、
  什么时候不会"。
- **程序目录 / 数据目录分离**：程序在解压目录，状态在 `%LOCALAPPDATA%\KeepAwake`
  （`KA_DATA` 可改），合盖原值备份在 `%ProgramData%\KeepAwake`。旧版本的"写在脚本旁边"会自动迁移，
  **且永不覆盖数据目录里已有的文件**。
- **界面语言**：中 / 英全量。`auto` 下面板跟随浏览器语言，命令行跟随 Windows 显示语言
  （注册表 `MuiCached`，不是 `CurrentUICulture`——本机这两个值不一样，用错了会让中文用户拿到英文命令行）。
  词典之外的语言一律给英文。日志与 `state.json` 永远是 ASCII 机器标记，换语言只换措辞、不改行为。
- **托盘**（`tray.bat`）与 CLI（`ka.bat <子命令>`，不传参数等于 `status`）。
- **合盖动作**（`ka.bat lid -LidAction apply|restore`）：唯一需要管理员的功能；先取消隐藏再改，
  自动备份原值，失败时打印一条让管理员代跑的命令而不是假装成功。
- 文档：`README.md`（含适配矩阵：哪些是**一台机器上实测**、哪些**只是推理**）、
  `SECURITY.md`、`PRIVACY.md`、`CHANGELOG.md`。
- 测试：89 次行为测试执行（82 个 `It` 用例，部分内含用例表），跑真电源 API、真事件日志、真计划任务；
  2026-09-08 起 CI 每轮在 GitHub 的一次性 Windows runner 上全量实跑（首轮实测：通过 84，失败 0，跳过 5，
  每条跳过都署名机器形态——没有看门狗任务、虚机固件能力位与本地化文本失配、14 天无 506 事件等，
  物理机上这些牙齿原样保留）。另有五道**独立门禁**——
  `tests/ka-encoding.ps1`（BOM + 纯 LF）、`tests/ka-syntax.ps1`（能解析）、`tests/ka-privacy.ps1`（不外传）、
  `tests/ka-privacy-mutation.ps1`（证明隐私门禁真的会红）、`tests/ka-workflow.ps1`（`.github/workflows` 里
  每个 `run:` 块能被 PowerShell 5.1 解析、YAML 里没有 tab 缩进）；一份文件清单 `tests/ka-release-files.ps1`
  （zip / Inno 暂存 / 探针脚手架 / CI 发布校验共用，不再各抄一份）；`tests/ka-ci.ps1` 是本地与 CI 共用的
  同一个入口；以及 17 个 `tests/probe-*.ps1` 实测探针，各自独立、几分钟跑完、
  不碰本机电源状态。其中六个是**自检**：往被测对象里注入一个真实缺陷，要求它点名变红——
  只见过绿色的检查等于没做过检查。红也必须看得懂：2026-09-05 一次扫描里 `probe-wow64` 红了一回
  （32 位那腿的 `ka.ps1 check` 回 2、64 位回 0，紧挨着的前后两次都是绿的），而**当时无法判断原因**——
  子进程说的话只存在两行之后就被删掉的临时文件里。现在它的失败行会把子进程的原话带出来，这条红
  仍然挂着"原因未知"，下次再红就有证据。逐个判定记在 README《独立门禁与实测探针》。
- 发布链路（阶段 5）：`packaging/build.ps1` 出 `dist/KeepAwake-<ver>-portable.zip`、`-Stage` 出 Inno 的
  暂存目录、`-Sum` 出 `SHA256SUMS`；`-Smoke` 把做好的 zip 解压到临时目录、用系统自带 5.1 实跑
  `status -Json`，核对退出码 / 版本 / `programRoot` / `dataRoot` / `dataError`，并要求**程序目录里一个文件都不许多**。
  这个闸门被 `tests/probe-build-selftest.ps1` 证明会红：三种事故（数据根指回程序目录、入口脚本一跑就炸、
  运行时往程序目录里写文件）在 2026-09-04 那次 42 秒的实跑里各红在自己那条断言上，未注入的那一棵保持绿。
  2026-09-05 它又红了一次，这回是**我自己弄出来的回退**：把找编译器的逻辑抽成 `packaging/ka-iscc.ps1` 之后
  `build.ps1` 加载了树里不存在的那个文件，四棵树一律红在同一句 `CommandNotFoundException` 上、连绿的那棵都不绿。
  一次性树从此显式列出"build.ps1 会加载但不进 zip 的那几个文件"。
  `packaging/KeepAwake.iss`（每用户、不提权、文件表从清单派生）在 2026-09-05 用本机装的 **Inno Setup 6.7.3**
  第一次真编译通过（用户级安装，`/CURRENTUSER /VERYSILENT`，全程没要管理员）：`Successful compile (3.454 sec)`
  → `dist\KeepAwake-1.0.0-setup.exe`，2.16 MB。第一次编译就抓到一个读不出来的缺陷——卸载回调写成了
  `procedure InitializeUninstall()`，ISCC 回 `Invalid prototype for 'InitializeUninstall'` 并中止。
  守这件事的换成了 `tests/probe-iss.ps1`（六条断言：原样字节和 CRLF 那份都要过、产物文件名要和 `release.yml`
  找的一致、缺 `/DMyAppVersion` 必须被 `#error` 挡下、回调原型写错必须被拒，再加一条记录"Inno 6.7.3 看不出
  漏写 `Result`"这个盲点——所以那行 `Result := True` 只有探针守得住）。找编译器的搜索顺序抽成
  `packaging/ka-iscc.ps1` 一份，`build.ps1` 和探针共用，CI 装完 Inno 后还要用同一个函数再找一遍——
  这一步已在 runner 上实测通过（机器级安装落在 `Program Files (x86)`，与本机的用户级路径不同目录）。
  workflow 三个（`ci.yml` + 可复用 `build-test.yml` + `release.yml`）自 2026-09-08 起每个 push 真跑，
  头两轮揪出的缺陷记在《README》CI 一节与下一条。
- **CI 首跑揪出的缺陷（2026-09-08）**：第一次在 Actions 求值器那一层真跑，两轮各揪出一批只有真跑才
  看得见的问题，各自修掉。首轮套件 10 红（修复 d10f1bb）：两条坏引用（`Get-KaRoot` 在阶段 1 改名
  `Get-KaPath` 后的残留、`probe-wow64.ps1` 毕业进 tests/ 后撞上 per-thread 电源请求扫描名单）、
  一条断言消息急切求值把自己打崩（空数组路径上 `Split-Path -Leaf $null`）、七条机器假设改为诚实
  `Skip` 并署名机器形态；第二轮套件全绿（84/0/5）后安装器步骤又揪出一条（修复 d482076）：runner 的
  `%TEMP%` 是 8.3 短路径而 `Get-ChildItem` 的 `FullName` 是长拼写，差 3 字符让相对名 `Substring`
  切错位，装出 `48/CHANGELOG.md` 这样的幽灵前缀——本机造 11 字符父目录（差值同为 3）复现出逐字节
  相同的红再修，`-SelfTest` 两个突变照常各红在自家断言上；第三轮全绿（11 分 49 秒）。
- **`release.yml` 自己跑出来的三条（2026-09-08，tag 推上去之后）**：只有走发布那条路才会遇到的东西，
  `ci.yml` 一轮都碰不到。**第四条**是探针在说谎：release 首轮红在 `probe-culture` 的
  `KA_OFFSET_STABLE=MISMATCH`（de-DE），而**同一个 commit 的 `ci.yml` 那一轮是全绿**——这个反差就是
  证据。`$newA`/`$newB` 各调一次 `Get-Date -Format 'o'` 再比 `ToUnixTimeSeconds()`，负载高的 runner 上
  两次采样跨过一秒边界就报一个根本不存在的偏移错。现在只取**一次**时刻、用两种解析策略比**同一个**
  字符串（f2193a0）：被断言的性质还是"`'o'` 带着 UTC 偏移、`'s'` 不带"，不再顺带要求时钟在两次采样
  之间站住；本地探针与它的突变自测重跑照旧各红各绿。**第五条**在最后一步：前 11 分钟全绿，
  `Publish` 回 `gh release create exited 4`——Actions 的 `gh` 不读运行时自带的那个 job token，
  它只认 `GH_TOKEN` / `GITHUB_TOKEN`，两个都没有就打印该设哪一行然后走人。`permissions: contents: write`
  一直在，缺的只是把 token 递到 `gh` 手上（`release.yml` 现在 job 级 `env: GH_TOKEN`）。顺手把这一类
  错误的代价从 11 分钟压到 5 秒：版本核对那一步开头就检查 `GH_TOKEN` 非空，空则拒绝起跑——
  失败点离原因越近，越不容易被误读成"发布系统坏了"。
- **第六条，最难堪的一条（2026-09-08）：绿色的 CI 发布了一个空 release。**token 修好之后
  `release.yml` 全绿、`v1.0.0` 的 Release 页确实建出来了——然后 `gh api …/releases/latest` 回答
  `assets: 0`。原因在 `Publish` 的 else 分支：`gh release create` **不带文件路径就是只建 release、
  不传文件，而且退出码 0**，三个产物从头到尾没离开过 runner。走 `--clobber` 的 if 分支倒是带了
  `@files`，可那条分支这次根本没执行。"**release 发出去了**"和"**release 里有东西**"是两件事，
  而 workflow 之前只检查了前一件。现在 create 分支补上 `@files`，末尾那句只是打印的
  `gh release view` 换成硬断言：把 release 页读回来，文件不是我们要的那三个就 throw。
  这条断言四向可反证（`_tmp/check-release-assets.ps1`，2026-09-08 实跑）：对着**当下这个空的线上
  release** 报 `missing=3`；喂三个正确文件名报 `pass`；混进一个 `KeepAwake-0.9.0-portable.zip` 报
  `extra=1`；`{"assets":[]}` 也报 `missing=3`——最后这条藏着 PowerShell 的坑：
  `@((ConvertFrom-Json $j).assets.name)` 在空数组上得到的是**一个 `$null`、Count 1**，不拿
  `Where-Object { $_ }` 滤掉，"空 release"会读成"有一个资产且不是我们的"。
- 面向下载者的文档（阶段 6）：README 新增《拿到 release 之后》——三件套各自是什么、怎么核对 `SHA256SUMS`、
  第一次运行 Windows 会说什么（SmartScreen 那段明确标成"照微软公开行为写的、不是本机截图"，MOTW 那段才是实测）、
  便携包与安装版各自的行为，以及装过之后怎么卸。核对哈希的那段脚本**先跑过再贴**：2026-09-05 对 `dist/` 里
  这次的 zip 和 setup.exe 都是 `OK`，两个红分支也在副本上各踩过一次（翻掉 zip 中间一个字节 → `MISMATCH`，
  把 `SHA256SUMS` 里列着的文件拿走 → `MISSING`）。安装版那一节整段戴着"从未执行过"的帽子：里面的每一条都写明是
  照着 `.iss` 读的，不是照着一次真安装说的（这顶帽子由下一条摘掉）。
- **真装真卸（阶段 7）**：`packaging/ka-test-install.ps1` 把"下载者双击的那个 `setup.exe`"变成一条可重复、
  会红的断言，而不是一个人的口头保证。静默装进 `%TEMP%` 下一个新建目录（`/DIR` 实测能覆盖 `DefaultDirName`，
  含空格的路径必须整体加引号，否则 ISCC 出的安装器在写日志之前就回 4）、用装好的那份起一次真保护（worker
  攥着电源请求）、再跑真卸载器，20 条断言覆盖：25 个文件不多不少、装进去的脚本无 MOTW、开始菜单恰好那五项、
  桌面快捷方式**默认勾上**且落在 OneDrive 重定向后的桌面、HKCU 卸载项的 `UninstallString` 是带引号的完整路径、
  安装不注册任务也不开端口、钩子按 `stop-server,stop,unguard` 顺序在第一条删除之前跑完、四处痕迹一起消失、
  真实数据目录逐文件 SHA256 前后一致。两个突变各自红在正确的那一条上（先建出安装目录 → "install directory
  survived the uninstall"，这一条顺便量出 Inno 只删它自己创建的目录；清单多算一个 → 文件数那条）。
  这一轮把三条 Windows 语义量成了事实而不是猜测：`Start-Process -Wait` **会等一个已经 detach 的孙进程**
  （父 → 立刻退出的子 → 藏起来的 40 秒孙 = 42.3 秒，改成轮询 `HasExited` 后 2.6 秒拿到 ExitCode 0——这正是
  `ka.ps1 start` 的形状）；未赋值的退出码经 `[int]` 读成 `0` 会假绿（2026-09-30 更正：这里原写"`$null -eq 0` 为真"，
  方向反了——实测 `$null -eq 0` 为假、`$null -ne 0` 为真，见 `PITFALLS.md` 第 13 条），四处调用点现在先查 `$null`、
  超时改写成一条点名的红；`& script *> log` 会丢退出码（里面 `exit 7` 外面读到 1），要 `; exit $LASTEXITCODE`。
  顺带挖出两个自己写的 bug：构造子进程命令行时一个未闭合的单引号让三棵树全部红在解析错误上、而**日志文件根本没生出来**
  （于是两个突变"看起来"红得正确），补了缺日志即硬失败；`$bad.Add("..." -f $a, $b)` 里逗号比 `-f` 松，
  把两个参数喂给了 `Add()` → FormatError。在本机跑它的代价写进 README：`unguard` 删的是固定任务名，
  所以脚本先用 `Schedule.Service` COM 把每个 KeepAwake 任务导出成 XML（`Get-ScheduledTask`.Xml 在本机是空的），
  跑完补注册缺失的并逐字节比对定义——实测两份都补回、`State` 仍是 `Disabled`、根任务数 27 → 27。
  这一步现在也是 CI 的一步（`build-test.yml` 里 Package 之后，带 `-WithWorker -SelfTest`），`release.yml` 经
  `needs: build-test` 间接依赖它。

### 发布前实测修掉的缺陷

这六条都没有对应的已发布版本——它们是发布前压测挖出来的。写在这里是为了把**行为契约**钉死，
而不是充当回归记录。

- **配置被自己覆盖**（2026-09-04）：把新解压的 clone 盖在已有安装上时，自动迁移用 `Copy-Item -Force`
  把用户改过的 `%LOCALAPPDATA%\KeepAwake\config.json` 换成了压缩包里那份。现在迁移**只补空缺、
  绝不覆盖**，跳过的文件记进 `.migrated.json` 的 `skipped` 并写一行 `MIGRATE-SKIP` 日志。
- **布尔值读反**（2026-09-04，安全相关）：手改 `config.json` 写 `"keepDisplayOn": "false"` 或
  `"antiLock": "off"` 会被 `[bool]` 转换读成 **True**——PowerShell 里任何非空字符串都是 True。
  也就是说一个人手动关掉假按键，结果假按键继续发。现在读取端走 `Get-KaBool`（`true/1/yes/on/是` 为真、
  `false/0/no/off/否` 为假、认不出的值回落到**该键自己的**默认值），写入端直接拒绝词表外的值并列出可接受值。
- **只读命令创建了文件**（2026-09-04）：全新安装上一次 `status` 就会留下 `.migrated.json`，
  记录"什么都没搬"。现在没有任何文件被复制或跳过时不写标记。
- **`config.json` 现在只存与默认值不同的键**：把全部默认值抄进用户文件的写法会让本版本的默认值
  冻结在未来每个版本上，并让"这个键我没动过"变成假话。
- **两个面板共用一份句柄，`stop-server` 于是撒谎**（2026-09-04，#41）：`.server.json` 只有一份。
  起第二个面板时它在启动那一刻覆盖了第一个面板记的 pid，而**先退出的那个**又把文件删了——于是
  一个还在跑、还在应答的面板变成"没有句柄"，`stop-server` 找不到它。更糟的是它把两件事说成一句话：
  "我没找到我的进程"和"没有任何端口在应答"都印成绿色的**面板没有在运行**，而后者的判定依据根本没测过。
  现在：句柄**按端口一份**（一个 TCP 端口只可能被一个活监听者占着，按端口就是按面板），旧的共享文件
  仍然读（改版前起来的面板还得找得回来）但只在它的进程确实没了之后才扫掉；句柄里的 pid 只在
  `startedEpoch` 与进程创建时间对得上（±900 秒）时才可信，防的是 pid 回收后被拿去杀无辜进程；
  `Stop-KaServer` 返回一个**实测**出来的 `Answering`（真的拿 `X-Ka-Client` 去 `/api/ping` 问出来的端口），
  CLI 与托盘共用同一份判定文案，端口还在应答就绝不说"没有在运行"。
  钉住它的是 `tests/probe-server-hint.ps1`（两个真面板、两个真端口），而 `tests/probe-server-hint-selftest.ps1`
  把修复的两半分别退回旧写法——共享一份 `.server.json` + 退出即删、以及压根不探端口——
  要求各红在自己那条断言上，不设注入的那一份必须还是绿的。2026-09-04 实跑：两种红各点名 4 条 / 2 条，对照绿。
- **`-Sum` 把整次构建吃掉了**（2026-09-05）：`build.ps1` 里 `if ($Sum) { Set-KaSums; exit 0 }` 排在
  打 zip **之前**，于是 `build.ps1 -Stage -Installer -Smoke -Sum` 一行日志不响，把三个开关全当没有——
  实测那一刻 `dist/` 里 zip 和 setup.exe 还是 08:21 / 08:22 的旧字节，而 `SHA256SUMS` 已经盖上 12:23 的时间戳
  和旧产物的哈希。**这份哈希是真的，对着的却是上一版的产物**，正是发布链路最不肯出的一种错。现在早退只发生在
  `-Sum` 是唯一诉求时（单独跑 `-Sum` 实测仍然只重算哈希、不动 zip），带上任何构建开关就走到末尾那次 `Set-KaSums`。
  修完实跑：zip 12:25:43、setup.exe 12:25:55（`Successful compile (2.891 sec)`）、`SHA256SUMS` 12:25:56 对得上，
  README《先核对哈希》那段照抄跑一遍两个产物都印 `OK`。同一次复查还抓到 README 的"一条命令出三件套"漏了
  `-Installer`——照它写的那条命令根本产不出 `setup.exe`；现在那行就是刚跑过的这条。
