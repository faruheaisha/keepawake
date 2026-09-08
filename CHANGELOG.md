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
