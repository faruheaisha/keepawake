# 更新日志 / Changelog

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循
[语义化版本](https://semver.org/lang/zh-CN/)。

**版本号的唯一真源是 `ka-core.ps1` 里的 `$script:KaVersion`**，面板页脚、托盘提示、`/api/state`、
`.migrated.json` 都读它。仓库**不放** `VERSION` 文件——两份版本号一定会漂移。CI 在打 tag 时比对
`KaVersion` 与 tag，不一致就构建失败。

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
  `ka.ps1 start` 的形状）；`$null -eq 0` 为真，所以一个从没被赋值的退出码会读成成功，四处调用点现在先查 `$null`、
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

## 未发布 / 下一步

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
  当时只有四处——两份文件清单（`ka-release-files.ps1:16`、`probe-migrate.ps1:14`）、`probe-clm-gate.ps1` 的
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
