# 调研：同类工具与平台一手来源（Research）

这份文件回答"别人做了什么、官方文档究竟怎么说的"，以及**这些结论怎么变成了我们的决定**。
产品决定本身在 [DESIGN.md](DESIGN.md) §决策记录；这里的每条都标了来源类型与复核日期。

## 方法

1. **一手来源优先**：能引官方文档原话就不引二手总结。引用的句子必须是**能重读的**——
   下面 §一手来源 里的句子是 2026-09-30 从 `learn.microsoft.com` 当场取回并逐句核过的。
2. **同类工具看代码与官方文档，不看宣传语**：有没有定时、能不能绑进程、锁屏时还灵不灵，
   这三件事决定了它到底解决谁的问题。
3. **数字都带日期**：star 数与活跃度是时点值（下表的日期是 2026-09-30），会变，别当成长期结论。
4. **没测过的就标 `[推理]`**：本项目只有一台参照机（Dell G15 5511 / Win11 26200 / S0），
   跨机型的判断一律降级标注，见 `README.md` §适配矩阵。

## 同类工具矩阵（2026-09-30 核对）

| 工具 | 机制 | 定时 / 到期 | 绑定进程 | 锁屏时 | 界面 | 其它 |
| --- | --- | --- | --- | --- | --- | --- |
| **PowerToys Awake**（`microsoft/PowerToys`，139,107★） | `ES_SYSTEM_REQUIRED` ± `ES_DISPLAY_REQUIRED`，**纯电源请求、无合成输入** | `--time-limit`（秒）/ `--expire-at`；tray 预设 `customTrayTimes` | `--pid` / `--use-parent-pid` | **不工作**——官方明说锁屏是另一个安全上下文 | 托盘（4 个状态图标）+ 设置页 | 默认状态下显示器仍会关；不改你的电源计划；不阻止用户主动睡 |
| **Mouse Jiggler**（`arkane-systems/mousejiggler`，1,439★） | 合成输入（jiggle） | 无到期概念（开着就是开着） | 无 | 原理上受 UIPI 限制（`[推理]`，未见其官方断言） | 窗口 / CLI | "Zen" 模式在真实鼠标移动时**暂停**；间隔随机化 |
| **NoSleep**（`CHerSun/NoSleep`，266★） | 合成输入（保持会话活跃） | 无到期概念 | 有**被监视应用列表**→按前台应用自动开关 | 未声明支持 | 托盘单击开关 | 自动启动；面向"某些程序运行时才需要" |
| **wakepy**（`fohrloop/wakepy` → `wakepy/wakepy`，262★） | 跨平台抽象（Windows/Linux/macOS 各自的机制） | 上下文管理器（`with` 块） | 跟随进程 | 它把这件事**做成了两种模式**：`keep.running` 允许锁屏、`keep.presenting` 不锁 | Python API + `wakepy methods` 自检报告 | "有哪些方法可用"能被自检打印出来，这个思路值得学 |
| **keepawake-rs**（`segevfiner/keepawake-rs`，47★；最后推送 2026-09-01） | `caffeinate` / `systemd-inhibit` 的翻版 | `-t`（超时） | `-w PID`（跟着进程活） | 未声明 | CLI | 形态最接近"命令行原语" |
| **macOS `caffeinate` / Linux `systemd-inhibit`** | 系统原语 | `-t` | `caffeinate -w PID` | — | CLI | `systemd-inhibit --list` 是一份**具名的抑制者登记表**：谁在拦、用什么理由，一眼可查 |

**读这张表能读出的共性**：大家都停在"我持有了一个请求 / 我在合成输入"。于是都答不出
**"昨晚这台机器到底睡没睡"**——那需要读内核电源日志，市场里做这件事的是 DFIR/取证工具，
不是 keep-awake 工具（2026-08-29 做过一次全局代码检索，未见 keep-awake 项目这么做）。

## 一手来源（2026-09-30 取回，可重读）

### `SetThreadExecutionState`（`learn.microsoft.com/windows/win32/api/winbase/nf-winbase-setthreadexecutionstate`）

- **它管不了用户主动睡**："The SetThreadExecutionState function cannot be used to prevent the user from
  putting the computer to sleep. Applications should respect that the user expects a certain behavior when
  they close the lid on their laptop or press the power button."
- **也管不了屏保**："This function does not stop the screen saver from executing."
- **`ES_USER_PRESENT` 不支持**："This value is not supported. If ES_USER_PRESENT is combined with other
  esFlags values, the call will fail and none of the specified states will be set."
  → 所以我们的掩码里**永不出现**它（`tests/ka-tests.ps1` 有专门断言，见任务"SETS 掩码永不含 ES_USER_PRESENT"）。
- **Away Mode 不是给笔记本的**："Applications that do not require critical background processing or that run
  on portable computers should not enable away mode because it prevents the system from conserving power by
  entering true sleep." 且它必须与 `ES_CONTINUOUS` 同时给。
- `ES_CONTINUOUS` = 一直有效到下一次带 `ES_CONTINUOUS` 的调用清掉它——**这是"持续保护"的实现基础**。

### PowerToys Awake（`learn.microsoft.com/windows/powertoys/awake`）

- **锁屏是硬墙**："PowerToys Awake doesn't work when the lock screen is displayed. This limitation exists
  because the lock screen operates in a separate security context from the user session. When you lock your
  computer, Windows transitions to this secure context, and user-mode applications like PowerToys Awake can't
  maintain their power requests."
- **默认放任熄屏**："in its default state the displays connected to the machine will turn off even if the
  computer stays awake."
- **不替代电源计划**："doesn't modify any of the Windows power plan settings"；官方还建议长期需求直接改电源计划。

## 结论 → 我们的决定

| 调研结论 | 落到哪个决定 |
| --- | --- |
| 睡眠/熄屏与锁屏是两个**不同**的空闲计时器，SETS 只压前一个，屏保它也管不了 | DR-4：双引擎（电源请求 + 防锁屏心跳），并把"锁屏管不住策略锁"写进能力边界 |
| Away Mode 在便携机上官方不建议，且本机无对照实验 | DR-5：`awayMode` 默认关，界面上说明代价 |
| 锁屏是安全上下文切换，用户态请求维持不住 | 能力边界表：锁屏场景如实降级，不承诺"绝不锁屏"（组策略强制时做不到） |
| 同类工具停在"我持有请求"的层面，没有一个能用本机日志证明结果 | 产品差异化第 1 条：`evidence` 读 Kernel-Power 506/507 数出真实待机次数 |
| 同类工具的"远程场景"只到自己进程退出（`--pid`/`-w`） | 产品差异化第 2 条：`intent.json` + 看门狗 + 断电自恢复链，每一环写明什么时候**不会**拉起 |
| `wakepy` 会把"本机可用方法"打印出来；`systemd-inhibit --list` 有具名登记表 | `ka.bat report` / `requests` 的做法：能查就查出来给人看，而不是让用户相信 |
| 无人签名会让 SmartScreen 与 AV 有话要说（同类工具同样面对） | DR-7：不签名，用每版 `SHA256SUMS` 回答"是不是同一份文件"，理由写进 `SECURITY.md` |

## 仍然没查清的（别当已解决）

- **锁屏下心跳到底有没有用**：官方口径是锁屏后用户态输入落不到（UIPI / 独立窗口站），
  我们的实现**跳过**锁屏期间的心跳并在界面上说明；但"心跳能不能阻止**进入**锁屏"这一条，
  本机只在默认策略下观察过，未见组策略强制锁屏的对照实验 → `[推理]`。
- **屏保**：官方明确 SETS 不阻止屏保执行。我们不发合成输入去猜屏保是否已接管屏幕，
  因此"屏保已启动"这一态在界面上只能标降级，不是承诺。
- **跨机型**：Windows 10 与 S3 传统待机机型没测过（适配矩阵里逐行写明哪些是实测、哪些是推理）。
