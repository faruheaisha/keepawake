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
- 测试：82 个行为测试跑真电源 API、真事件日志、真计划任务。另有四道**独立门禁**——
  `tests/ka-encoding.ps1`（BOM + 纯 LF）、`tests/ka-syntax.ps1`（能解析）、`tests/ka-privacy.ps1`（不外传）、
  `tests/ka-privacy-mutation.ps1`（证明隐私门禁真的会红）；一份 zip 文件清单 `tests/ka-release-files.ps1`
  （打包与探针共用，不再各抄一份）；以及 13 个 `tests/probe-*.ps1` 实测探针，各自独立、几分钟跑完、
  不碰本机电源状态。其中三个是**自检**：往探针里注入一个真实缺陷，要求它点名变红——
  只见过绿色的检查等于没做过检查。逐个判定记在 README《独立门禁与实测探针》。

### 发布前实测修掉的缺陷

这四条都没有对应的已发布版本——它们是发布前压测挖出来的。写在这里是为了把**行为契约**钉死，
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

## 未发布 / 下一步

- **两个面板实例互相覆盖句柄**（#41）：`.server.json` 只有一份，`stop-server` 因此会撒谎——
  起第二个面板会覆盖第一个的记录，而"找不到进程"时它说的是"已停止"，但端口还在应答。
  改法是按端口记录（或只删自己那条）+ `Stop-KaServer` 说实话。
- CI 一键 release（tag → 测试门禁 → zip → per-user 安装器 → `SHA256SUMS` → GitHub Release）与
  winget 清单。
- README 面向下载者的安装章节 + 机器支持矩阵独立成页。
- v1.1 候选：PID 绑定、`PowerCreateRequest`/`PowerSetRequest` 熄屏模式、全局热键、托盘预设、
  被守护应用、全屏自动释放、更多语言、更新检查（那会是这个工具第一次对外发请求，会写进 PRIVACY.md）。
