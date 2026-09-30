# 踩过的坑与调研结论（Pitfalls & Findings）

这份文件只放**别处没有的东西**：这个项目在真机上被咬过、且不写下来下次一定重犯的坑，以及调研出来的
平台事实。产品设计写在 `README.md`，逐轮过程与数字写在 `CHANGELOG.md`，实现里的"为什么"写在各自文件头。

每条都标了**它是怎么来的**：

- `[实测]` 本机或 CI runner 上真跑出来的，附可复跑的入口（探针 / 命令 / 日志）
- `[调研]` 查文档或对比同类工具得到的，附来源类型
- `[推理]` 没测过，明确标出来，别当结论用

---

## 一、Windows / 平台事实（都在这台 Dell G15 5511、Win11 build 26200、S0 Modern Standby 上量过）

| 事实 | 怎么来的 |
| --- | --- |
| 本机只有 **S0 低功耗空闲（Modern Standby）**，没有 S3；休眠被禁用；混合睡眠开着；AC 下允许唤醒定时器 | `[实测]` `powercfg /a`、`powercfg /q SCHEME_CURRENT`（会随系统更新变，用前重测）。见 `tests/ka-tests.ps1` 的环境用例 |
| 机器**真的每隔几分钟进一次 Modern Standby**（Kernel-Power 506/507），所以"要不要防休眠"不是理论问题 | `[实测]` 事件日志；`ka.bat evidence` 就是读它 |
| **显式的熄屏请求会在 5–6 秒内链式进入真睡眠**；而"空闲超时"造成的熄屏在 14 天里一次都没链式睡过。危险的是**显式**熄屏，不是熄屏本身 | `[实测]` 五次独立观察（`CHANGELOG` 里记着时间点） |
| 这台机器的固件**会谎报电池**：`ACLineStatus=1`、`BatteryLifePercent=99`、同时置了 critical 位，导致 worker 起来一秒就退出 | `[实测]` 2026-08-29 事故；结论：任何单次电池读数不可信，判断要带上 AC 状态 |
| `powercfg /requestsoverride` 列表**不需要管理员**；`powercfg /requests`（谁在持请求）**需要管理员**（exit 1） | `[实测]` 标准令牌下逐个试 |
| `Ka.Native` 那 15 个 P/Invoke 调用**标准账户可调**；`Add-Type` 是 CLM 下唯一硬阻断 | `[实测]` `tests/probe-clm-gate.ps1`、`probe-native.ps1` |
| **CLM（受约束语言模式）下工具完全跑不了**：`Add-Type` 被禁。`ka-gate.ps1` + 顶层 `if (-not (Test-KaLanguageMode)) { exit 2 }` 必须写在**每个入口脚本自己的顶层**——`exit N` 在 dot-source 的文件里**不会**中断调用方 | `[实测]` 同上探针 |
| 本机 **`MuiCached`=zh-CN 而 `$PSUICulture`=en-US**：两个值不一样。命令行语言必须读注册表 `MuiCached`，否则中文用户拿到英文 | `[实测]` 本机 |
| `Get-ScheduledTask` 的 `.Xml` 在本机**是空的**，要导任务定义得走 `New-Object -ComObject Schedule.Service` | `[实测]` 安装器实测时发现 |
| 任务计划里 `New-ScheduledTaskTrigger -AtLogOn` **不加 `-User`** 注册的是"任意用户"触发 → 需要管理员；加上当前用户就免提示 | `[实测]` 环境矩阵那次 |
| 强制杀面板会**留下 http.sys 前缀注册**，下一个面板的首请求会卡约 10 秒；优雅停机（`listener.Stop()/Close()`）能让后继面板 1 秒内应答 | `[实测]` `Stop-KaServer` 的注释里有数字 |
| **`pid` 是会被回收的号码，不是身份**：`Get-Process -Id 2044` 前一刻是面板、重启后是 `fontdrvhost.exe`。任何"按 pid 认进程"的判断都要带创建时间 | `[实测]` 2026-09-29 现场抓到 |
| **CIM 对受保护镜像不给 `CreationDate`**（`TrustedInstaller.exe`、`TiWorker.exe` 这类）——于是"比对创建时间"的守卫对它们会被**整段跳过** | `[实测]` CI 假红 run 36528628613 追出来的 |
| **Job 对象管不住"壳起的进程"**：`Diagnostics.Process` + `UseShellExecute`（浏览器交接就是这种形状）起的子进程不继承 job 成员资格 | `[实测]` run 36534077753：`our own look: 1 alive: 5216` 而 runner 报 0 留口 |
| 一次性 runner 的 `%TEMP%` 是 **8.3 短路径**（`C:\Users\RUNNER~1\…`），而 `Get-ChildItem` 给长名：任何拿"你传进去的路径"做 `Substring` 算相对名的代码都会错位（实测差 3 个字符，文件被报成 `48/CHANGELOG.md`） | `[实测]` CI 安装器那次 |

---

## 二、PowerShell 5.1 / cmd 陷阱（这个仓库每次都被咬一遍）

1. **`Start-Process -Wait` 等的是"被重定向的 stdout 管道到 EOF"**，不是那个进程。孩子留下一个继承了写端的
   孙进程（面板就是），EOF 永远不来 → 无限等待。`[实测]`：`ka-ci.ps1` 因此被人工取消两次 CI；probe-server-hint
   因此挂了九分钟。**修法**：轮询 `HasExited` 到截止点，并把超时写进输出当红字。
2. **不等待的 `Start-Process` 对象，孩子一走就给你 `$null` 的 `ExitCode`**（不抛异常）。`[int]$null` 是 `0`，
   于是"退出 5"读成"通过"。**修法**：判据吃孩子自己写的标记/判定文件，或改用 `[Diagnostics.Process]::Start`。
3. **空数组从函数返回会扁平化成 `$null`**。"这一趟什么都没留"看起来和"查询失败"一模一样。**修法**：
   返回 `@{ Ok; Pids; Err }` 这样的显式结构，绝不从值去猜。`[实测]` 2026-09-29，Job 包装第一版在每一腿上抛错。
4. **`Write-Output` 出现在"要有返回值"的 helper 里，会把返回值污染成数组**：拿到的 `$dir` 变成 `[信息行, 路径]`，
   紧接着 `Get-ChildItem -LiteralPath <垃圾> -File` 报的是"没有 `-File` 参数"——像工具 bug，其实是返回值脏了。
5. **`Start-Process -ArgumentList` 不给你引号**：路径带空格（本仓库目录名就带）必须自己加引号；`\"` 不是转义；
   没有 `-Environment`，要传环境变量就在父进程 `$env:X = …` 再 `-File "带引号的路径"`。
6. **函数参数叫 `$Args` 永远绑不上**：自动变量 `$args` 把它遮住。`Invoke-Child $d $data '-Port'` 静默什么都没传。
7. **`New-Item` 没有 `-LiteralPath`**。脚本里写 `New-Item -LiteralPath …` 会直接抛，一句像"参数不存在"的假语法错误。
8. **`| tail` 把退出码吃成 tail 自己的**（bash 侧）；而"上个回合的判定文件"会替你圆谎：脚本在写判定之前就死了，
   文件里还是上一轮的红色。**修法**：自己打印 `EXITCODE=`，并核对判定文件的 mtime 是否落在本轮窗口内。
9. **`-like` 把 `[ ]` 当字符类**：`*[int]$s.Port*` 匹配的不是那串字。要字面匹配用 `.Contains()`。
10. **`.md`/`.ps1`/`.bat` 的字节形状是三套不同的规矩**：`.ps1` 要 **BOM + LF**（5.1 用 ANSI 码页解码无 BOM 的
    `.ps1`）；`.bat`/`.cmd`/`.iss` 要 **CRLF、无 BOM、纯 ASCII**（cmd/ISCC 按系统 ANSI 码页解码，默认 zh-CN
    的 ACP 936 下 BOM 会印出 `ÿþ`、一个汉字会变乱码）；`.md`/`.html`/`dashboard/*` 只报告不断言。
    `git status` 对这类漂移**是瞎的**（clean filter 先归一化再比），所以只能靠闸门扫字节。
11. **`\r\n` 与叙事文本**：用 `[IO.File]::WriteAllLines` 写 `.ps1` 会按 `Environment.NewLine` 塞 CRLF，闸门会红；
    手写文件时明确 `-join "`n"` 并用 `UTF8Encoding($true)` 补 BOM。
12. **`[IO.File]::ReadAllText` 读不了"自己进程还开着写句柄"的文件**（`being used by another process`），
    `Get-Content` 是按共享打开的，能读。重定向 stdout 的场景一律用后者。
13. **`$null -eq 0` 是 `TRUE`**；未赋值的退出码读起来像成功。
14. **逗号比 `-f` 松散**：`$bad.Add("x {0}" -f $a, $b)` 是给 `Add()` 传两个参数。
15. **`exit N` 在 dot-source 的文件里不中断调用方**（CLM 闸门必须写在每个入口脚本顶层的原因）。
16. **文化（区域）会漏进三处**：`(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')` 跟线程日历（th-TH 写出**佛历 2569 年**）；
    `[DateTimeOffset]::Parse` 解析备份文件；`Format-KaDuration` 的字符串解析（fr-FR 把 `1755.0` 读成 "Unknown"）。
    `'o'`/`'s'` 与日历无关，但 `'s'` **不带时区偏移**（本机 Eastern Time 上 4 小时漂移）→ `capturedAt` 用 `'o'`。
17. **两个钟读数不许进同一条等式**：一个探针比"两次独立 `Get-Date -Format 'o'` 的 epoch"，机器一忙跨秒就读成
    "偏移不存在"。**修法**：采样一次，把同一个字符串用两种方式解析。
18. **`Add-Type` 的嵌套 job / 跨进程句柄**：`AssignProcessToJobObject` 在 Win8+ 支持嵌套 job，失败就**抛错**而不是
    当红腿——否则后面每个答案都是猜的。
19. **一个探针"绿过"什么都不能证明**：必须见过它**红**。这个仓库所有的守卫都配一条能把自己那条判红的注入腿
    （`probe-*-selftest.ps1` 与 `probe-procwalk.ps1` 的四条注入腿——第 7、8、9、10 条）。
20. **两次 sweep 不许共用文件名**：突变体名要带 `$PID`、暂存目录要带 GUID，否则先结束的那个会把另一个的
    测试对象删掉，症状是三条臂一起报"`-File` 参数指向的文件不存在"。
21. **`[long]$null.Ticks` 是 `0`，而且不抛**（PS 5.1，2026-09-30 实测）。`try { $Born[$id] = [long]$r.CreationDate.Ticks } catch { }`
    读起来像"读不到就跳过"，实际是给每个 CIM 不给 `CreationDate` 的进程**记下一个看起来是真的时间 0**——runner 上以
    标准令牌查 TiWorker.exe / TrustedInstaller.exe / svchost.exe 就是这一类。于是所有"有没有时间可比"的守卫同时失效：
    `ContainsKey` 是 true、`0 -ne 0` 是 false，pid 回收守卫被整段跳过。`[实测]` CI run 36679927952：一条 6 分钟腿的
    留口名单里冒出 11 个与它无关的系统进程（同一次红里探针自己刚打印过 `PROBE OK`）。**修法**：`$t -gt 0` 才写进 map；
    并且"活着但现在读不到时间"必须**停走**，不是跳过比较（`probe-procwalk.ps1` 第 9、10 条注入各自把这两条钉红）。
    本机实测 334 行 CIM 里 0 行是 null（`_tmp/procwalk-cim-timing-20260930.txt`；这个行数每轮都不同，要紧的是那个 0），
    所以这个形状在本机只能靠"喂给采样器一行没有 CreationDate 的行"来演，runner 上才是真的。

---

## 三、CI / 门禁的经验（都为一个目的：红必须意味着"产品或测试错了"）

- **一个脚本一步，超时 600 秒**（`tests/ka-ci.ps1 -TimeoutSec`）。所以一条 sweep 的代价是"臂数 + 1 次完整探针"：
  `probe-server-hint-selftest.ps1` 六臂 = 7 趟 ≈ 384s（runner 上），`probe-bat-entry.ps1 -SelfTest` 那条
  8m35s **故意不进 CI**，代价与两条替代接法写在 `README.md` 的探针表里。`[实测]`
- **`ka-ci.ps1 -Probes` 按 glob 跑 `probe-*.ps1` 且每个都不带参数**：所以"藏在 `[switch]$SelfTest` 后面的自检"
  一次也不会进 CI。`probe-native.ps1` 因此改成**普通运行自己带那条腿**（5.2 秒）。`[实测]`
- **留口检查**（"这一步留下了哪些进程"）是最难的一块，现在的定案是**两个源取并集**：每腿一个 Windows Job 对象
  ∪ 带两条守卫的 `pid→ppid` 重建。四种假红（office 套件 / 本机 worker / `CompatTelRunner.exe` / 一整批
  Windows 维护进程 / Git 的 `sleep.exe`）与两次修法各为什么不够，写在 `README.md` 的同名小节与
  `CHANGELOG.md`。`[实测]`
- **CI 上的 `gh` 只认 `GH_TOKEN`/`GITHUB_TOKEN`**，不读运行时的 job token；`gh release create <tag>` **不带文件路径
  会建一个空 release 并 exit 0**。`[实测]` release 那次
- **`push` 与"API 通"是两件事**：本机 `github.com` 走代理才通，`gh`/API 通不代表 `git push` 通；代理没起时
  `git push` 会 `Connection was reset`，别循环重试，也**别改用 Contents API 推**（那会毁掉 `.ps1` 的 BOM+LF）。
  `[实测]`
- **`tests/ka-tests.ps1` 不许随手在正在用的机器上跑**：它动真实电源设置与计划任务。它的位置是 CI 的一次性 runner。
  `[实测]`（用户两次拒绝本机跑）

---

## 四、产品侧的调研结论

完整的同类工具矩阵（每个项目的模式 / CLI / 星标那一刻的值）与逐条一手来源见
[docs/RESEARCH.md](docs/RESEARCH.md)；本节只留**影响了决策**的那几条。

- **同类工具对比**（PowerToys Awake / MouseJiggler / NoSleep / wakepy / keepawake-rs）：共同点是"按住电源请求"
  或"模拟输入"。本工具的差异化只有两条——**有效性可被本机事件日志证实**，以及**远程无人值守链**（意图文件 +
  看门狗 + 断电自恢复，每一环写明什么时候不会拉起）。`[调研]`
- **Away Mode 默认不开**：本机从没跑过对照实验（用户决定不停掉手上的保护），所以 `awayMode` 保持 `false`；
  也没有能力位可预检——当前 `SYSTEM_POWER_CAPABILITIES` **没有 AwayMode 字段**。`[实测]`+`[调研]`
- **锁屏管不住"策略要求的锁"**：心跳只能重置空闲计时器；组策略/屏保强制锁屏时如实降级并在界面说清楚。`[调研]`
- **不做代码签名（v1.0）**：测 AV/SmartScreen 要上传样本，不是本机可逆动作；README 明说，`SECURITY.md` 记理由。
  `[推理]`（这是决策，不是测量）

---

## 五、要复跑这些结论，去哪儿

| 想验证什么 | 跑什么 |
| --- | --- |
| 五道门禁 + 全部探针 | `powershell -NoProfile -ExecutionPolicy Bypass -File tests\ka-ci.ps1 -Gates -Probes` |
| 字节形状（BOM/CRLF/ASCII 家族） | `tests\ka-encoding.ps1`（`-Apply` 就地修） |
| 平台能力与证据链 | `ka.bat report` / `ka.bat check` / `ka.bat evidence` |
| CLM / MOTW / WOW64 / 文化 | `tests\probe-clm-gate.ps1`、`probe-motw.ps1`、`probe-wow64.ps1`、`probe-culture.ps1` |
| 留口归属（Job ∪ 重建） | `tests\probe-procwalk.ps1` + `tests\probe-ci-harness.ps1` |
| 安装版真装真卸 | `packaging\ka-test-install.ps1 -WithWorker -SelfTest`（**会动你机器上的计划任务**，先看 README） |

**清 `_tmp/` 之前先 grep 文档。** `_tmp/` 是 gitignore 的（只存在于开发机），但其中一批日志/脚本被
`README.md`、`CHANGELOG.md` 与小节里的"引用哪次运行"**当成取证记录点名**（`_tmp/ci-gates-probes-run3.log`、
`_tmp/hint-sweep-batch2.log`、`_tmp/panel-keepalive-probe.ps1`…）。删掉它们不会让任何门禁变红——只会让
那些引用从此不可复读，而这正是本仓库要求"引用就必须能重读"的原因。所以顺序是**先**：

```powershell
Select-String -Path README.md, CHANGELOG.md, PITFALLS.md, docs\*.md -Pattern '_tmp/' -AllMatches
```

把输出里出现过的路径列成保留名单，**再**删其余。本机 2026-09-30 实做过一次：`_tmp` 从 493 项降到 33 项
（30 MB → 535 KB），留下的正好就是被点名的那些；`dist/`（构建产物）同批清掉，之后 `git status` 干净、
五道门禁 `----- 5 run, 0 red`。**没 grep 过就别删**：这里面没有能被自动化复现的东西，删了就真没了。
