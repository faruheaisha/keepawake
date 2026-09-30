# 环境依赖与工作流（Environment & Workflow）

改这个仓库要装什么、跑什么、花多久。**产品本身对下载者的依赖只有一条**（系统自带的 PowerShell 5.1），
下面区分三层，别把开发机的依赖当产品依赖。

## 依赖（三层，互相不能混）

### 一、运行产品（下载者）

| 要什么 | 版本 | 怎么来 | 缺了会怎样 |
| --- | --- | --- | --- |
| Windows | 10 / 11 | — | 产品是 Windows 专属（`SetThreadExecutionState`、`HttpListener`、计划任务） |
| Windows PowerShell | **5.1**（`$PSVersionTable.PSVersion`） | 系统自带，`C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe` | 没有它就没有任何东西可跑。**我们不支持也不测试 pwsh 7 作为产品运行时**：CI 的 `shell:` 固定在 `powershell`（5.1），因为换个引擎绿了，测的是别人装不上的东西 |
| 管理员 | 不需要 | — | 只有 `lid apply`（改合盖动作）和 `powercfg /requests` 需要 |

不依赖：.NET 安装（`Add-Type` 用的是 5.1 自带的编译器）、Node、Python、任何 CDN、任何联网行为。

### 二、构建产物 / 本地开发

| 要什么 | 本机实测版本／位置 | 干什么用 | 缺了会怎样 |
| --- | --- | --- | --- |
| PowerShell 5.1 | `5.1.26100.9444` | 跑一切 | — |
| git | `2.54.0.windows.1` | `tests/ka-release-files.ps1` 用 `git check-ignore --no-index` 问"哪些是本机运行产物"（不抄第二份名单） | 非 git 树上该函数返回空，于是根目录里任何一个没被认领的文件都会让构建 **throw**（安全方向：宁可挡构建，不肯静默少一个文件） |
| Inno Setup **6** | 本机 `6.7.3`，`%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe`（winget 下载、`/CURRENTUSER /VERYSILENT`，全程未提权） | 只有 `-Installer` 与 `tests/probe-iss.ps1` 需要 | `build.ps1 -Installer` 退出码 1 并打印"没装"；`probe-iss` 走 SKIPPED，于是那个"下载者会双击的产物"就没人验证——所以 CI 一定会装它 |
| `gh` CLI | 本机 `2.93.0` | 看 CI、看 release；**发布动作本身由 CI 里的 `gh release create` 执行** | 本地看不了流水线；发布不受影响（CI 自带） |

找编译器只有一份实现：`packaging/ka-iscc.ps1` 的 `Get-KaIscc`。`build.ps1` 与探针共用它——
否则会出现"打包说没装、门禁说装了"这种两边都自以为是的状态（本机与 runner 的安装路径不同：
用户级在 `%LOCALAPPDATA%`，CI 的 `choco install innosetup` 落在 `Program Files (x86)`）。

### 三、CI（GitHub Actions）

| 要什么 | 现状 |
| --- | --- |
| runner | `windows-latest`，`timeout-minutes: 60`（build-test）/ `30`（release） |
| shell | `powershell`（5.1，理由同上） |
| 步骤 | `actions/checkout@v4` → `choco install innosetup` + `Get-KaIscc` 复核 → `tests\ka-ci.ps1 -Gates -Probes` → `ka-tests.ps1` 全量 → `build.ps1 -Stage -Installer -Smoke` → `ka-test-install.ps1 -WithWorker -SelfTest`（真装真卸） |
| 发布 | `release.yml`：核对 tag 与 `-ShowVersion` 一致 → 重建三件套 → 逐项与 `SHA256SUMS` 比对 → `gh release create` 带文件 → 把 release 页**读回来**对数 |
| 密钥 | `GH_TOKEN`（job token 不会被 `gh` 自动读取，缺了 `Publish` 会以 exit 4 死在最后一步） |

`ci.yml` 与 `release.yml` **复用同一个** `build-test.yml`：一次 release 被验的，和一次 push 被验的，
是同一份东西——同一条规矩的另一半是 `tests/ka-release-files.ps1` 只有一份清单。

## 命令与预算（数字都是实测）

| 想干的事 | 命令 | 本机实测 | CI 实测 |
| --- | --- | --- | --- |
| 五道门禁 | `tests\ka-ci.ps1 -Gates` | **67s**（encoding 1s / privacy 3s / privacy-mutation 60s / syntax 2s / workflow 1s；末行 `----- 5 run, 0 red`） | 同一入口 |
| 门禁 + 全部探针 | `tests\ka-ci.ps1 -Gates -Probes` | **21m14s**（28 行 0 红，2026-09-30） | **21m45s**（run `36553833882`，末行 `----- 28 run, 0 red`） |
| 全量行为套件 | `tests\ka-tests.ps1` | **不要在本机随手跑**（动真电源设置与计划任务） | 每轮都跑（84 个 `It`，最近一轮印 91 条判定行：86 通过 / 5 跳过 / 0 失败） |
| 字节形状 | `tests\ka-encoding.ps1`（`-Apply` 就地修） | 1s | 每轮 |
| 某个探针单跑 | `tests\probe-<名字>.ps1` | 见 `README.md` 探针表（`probe-native` 5.2s、`probe-procwalk` 15.4→26s、`probe-server-hint` 50–76s、`probe-server-hint-selftest` 384–435s、`probe-bat-entry -SelfTest` 8m35s） | 前四类每轮；`probe-bat-entry` 不进 CI（理由与代价见 README 表内） |
| 出三件套 | `packaging\build.ps1 -Stage -Installer -Smoke` | zip 25 条目 / 0.31 MB；`setup.exe` 2.16 MB（Inno 编译 3.454s） | 每轮 |
| 真装真卸 | `packaging\ka-test-install.ps1 -WithWorker -SelfTest` | **会删掉再补回你的 `KeepAwake-Guard`/`KeepAwake-Logon`**，别在没备份时跑 | 每轮（20 条断言 + 2 个突变，2m41s） |
| 只打印版本 | `packaging\build.ps1 -ShowVersion` | 版本号真源是 `ka-core.ps1` 的 `$script:KaVersion` | 发布前比对 tag |

每脚本的上限是 `tests\ka-ci.ps1 -TimeoutSec`（默认 **600 秒**），所以一条 sweep 的代价 ≈ 臂数 + 一次完整探针。
这是"探针要不要进 CI"这类决定里的硬成本，写在这里，避免下次重新估。

## 出一版发布（流程本身）

1. 改 `ka-core.ps1` 的 `$script:KaVersion`（**唯一真源**，面板页脚/托盘/`/api/state` 都读它）。
2. 把 `CHANGELOG.md` 的「未发布」段转正成 `## [<版本>] — <日期>`，并写清**行为变化**（没有就写没有）。
3. 提交并推 `main`，**然后**打 tag `v<版本>` 再推 tag。
4. `release.yml` 自动跑：先 `needs: build-test` 全量验证，再重建三件套、对数、建 release。
   手动重试同一版本用 `workflow_dispatch`（不必重新打 tag）。

版本号不一致会被 CI 挡在第二步之前（`-ShowVersion` 与 `${{ github.ref }}` 比对），
所以"文件名里的版本和产品里的版本各说各话"这种 release 发布不出去。

## 这台开发机的环境事实（[实测]，换机器要重测）

- `PowerShell 5.1.26100.9444`；`HKLM:\...\Nls\CodePage` 的 **ACP = 65001**。
  后者决定了写文件的姿势：`.ps1` 必须 **BOM + LF**、`.bat`/`.cmd`/`.iss` 必须 **CRLF + 纯 ASCII**，
  原因与踩坑见 `PITFALLS.md` §二 第 10、11 条。
- `git 2.54.0.windows.1`、`gh 2.93.0`、Inno Setup `6.7.3`（路径见上）。
- 仓库目录名含空格与中文（`E:\claude code\防休眠`），所以任何传路径的地方都要自己加引号
  （`Start-Process -ArgumentList` 不替你加，见 `PITFALLS.md` §二 第 5 条）。

## 摩擦点

全部写在 `PITFALLS.md`（PowerShell 5.1 与 cmd 的 21 条、CI/门禁经验、平台事实），这里不重抄。
