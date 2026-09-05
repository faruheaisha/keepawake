# 更新日志 / Changelog

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循
[语义化版本](https://semver.org/lang/zh-CN/)。

**版本号的唯一真源是 `ka-core.ps1` 里的 `$script:KaVersion`**，面板页脚、托盘提示、`/api/state`、
`.migrated.json` 都读它。仓库**不放** `VERSION` 文件——两份版本号一定会漂移。CI 在打 tag 时比对
`KaVersion` 与 tag，不一致就构建失败。

## [1.0.0] — 尚未发布

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
- 测试：82 个行为测试跑真电源 API、真事件日志、真计划任务。另有五道**独立门禁**——
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
  `packaging/ka-iscc.ps1` 一份，`build.ps1` 和探针共用，CI 装完 Inno 后还要用同一个函数再找一遍。
  **还有两件事没验证**，各自的原因都写明：`setup.exe` 从未被执行安装过（卸载钩子会跑 `ka.ps1 unguard`，
  它删的任务名是固定字符串 `KeepAwake-Guard` / `KeepAwake-Logon`，在本机会连带删掉用户留着的那两份停用任务），
  `.github/workflows/`（`ci.yml` + 可复用 `build-test.yml` + `release.yml`）一次都没跑过——这个仓库还没有 git remote。
- 面向下载者的文档（阶段 6）：README 新增《拿到 release 之后》——三件套各自是什么、怎么核对 `SHA256SUMS`、
  第一次运行 Windows 会说什么（SmartScreen 那段明确标成"照微软公开行为写的、不是本机截图"，MOTW 那段才是实测）、
  便携包与安装版各自的行为，以及装过之后怎么卸。核对哈希的那段脚本**先跑过再贴**：2026-09-05 对 `dist/` 里
  这次的 zip 和 setup.exe 都是 `OK`，两个红分支也在副本上各踩过一次（翻掉 zip 中间一个字节 → `MISMATCH`，
  把 `SHA256SUMS` 里列着的文件拿走 → `MISSING`）。安装版那一节整段戴着"从未执行过"的帽子：里面的每一条都写明是
  照着 `.iss` 读的，不是照着一次真安装说的。

### 发布前实测修掉的缺陷

这五条都没有对应的已发布版本——它们是发布前压测挖出来的。写在这里是为了把**行为契约**钉死，
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

## 未发布 / 下一步

- **把 release 真跑一次**：建仓 + 加 remote + 推 `v1.0.0` tag，看第一次 Actions 到底过不过。`setup.exe`
  这边还差一步、也只剩这一步：**执行它**。编译已经在本机做过了（2026-09-05，Inno Setup 6.7.3），
  装和卸没有——卸载钩子会跑 `unguard`，它删的任务名是固定字符串，在本机会连带带走用户留着的那两份停用任务。
  跑通之后再补 winget 清单。
- 面向下载者的那一节已经写进 README（《拿到 release 之后》：三件套、怎么核对哈希、第一次运行 Windows
  会说什么、两条分发路径各自的行为）。**机器支持矩阵刻意不再独立成页**：同一台机器的适配结论写两处
  迟早互相打脸，这和"发布清单只留一份"是同一个理由。
- v1.1 候选：PID 绑定、`PowerCreateRequest`/`PowerSetRequest` 熄屏模式、全局热键、托盘预设、
  被守护应用、全屏自动释放、更多语言、更新检查（那会是这个工具第一次对外发请求，会写进 PRIVACY.md）。
