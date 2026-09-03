'use strict';

/*
  i18n.js — the whole language layer of the dashboard. One global: window.KA.

  Contract
    KA.lang                 currently applied language, 'zh' | 'en'
    KA.dict.{zh,en}[key]    the two dictionaries. Identical, complete key sets.
    KA.t(key, vars)         translate + substitute {name} placeholders from vars.
                            Unknown key -> zh entry -> the key itself. Never throws,
                            never returns undefined, so a missing translation degrades
                            to readable text instead of a blank node.
    KA.has(key)             true when wording exists for the key (en, else zh). Used
                            for machine tokens arriving over the API, where echoing
                            the raw token beats echoing a dictionary key.
    KA.apply(root)          repaints [data-i18n] textContent, [data-i18n-title] title,
                            [data-i18n-placeholder] placeholder and [data-i18n-aria]
                            aria-label inside root (default: document).
    KA.set(lang)            apply 'zh' | 'en' document-wide, sync <html lang>, mark the
                            #langSeg switcher, then fire a 'ka-lang' CustomEvent on
                            document with detail = { lang } so app.js can re-render the
                            values it builds in JS.
    KA.detect()             'zh' when navigator.language starts with 'zh', else 'en'.

    zh is the authored language: every entry is the exact string that used to be
    hard-coded in index.html / app.js, so switching to zh reproduces the original UI
    byte for byte and app.js has a real source of truth. en is the translation, and
    also the fallback every Windows whose UI language is neither Chinese nor English
    gets - on a German or Japanese machine English strings beat Chinese ones.

    Inline markup: writing textContent into an element that contains <b>/<em>/<small>/
    <span> children would delete them, so a [data-i18n] element that has element
    children is rewritten through its own direct text nodes (leading and trailing
    whitespace of each node is kept, so " label <small>hint</small>" survives intact).
    Where a sentence is broken across several text nodes, app.js instead walks them by
    order using the data-i18n-inline attribute it declares on that element.

    Zero dependency, no network, no build step. UTF-8 without BOM. Must stay loadable
    in a bare JS host (no document, no navigator) so the dictionaries can be checked.
*/

(function () {

  var zh = {

    /* page + masthead */
    'page.title': '防休眠控制台 · Keep-Awake Console',
    'page.name': '防休眠控制台',
    'mast.sub': 'Keep-Awake Console · 本机 127.0.0.1 · 不联网 / 免登录 / 免安装',
    'mast.clockTip': '面板进程时钟',
    'nav.aria': '面板导航',
    'nav.control': '控制',
    'nav.evidence': '有效性',
    'nav.machine': '本机环境',
    'nav.guard': '无人值守',
    'nav.log': '日志',
    'nav.limits': '能力边界',
    'conn.connecting': '连接中…',
    'conn.ok': '面板在线',
    'conn.gone': '面板已退出',
    'conn.dead': '面板不可达',

    /* language switcher */
    'lang.aria': '界面语言',
    'lang.tip': '自动 = 跟随浏览器语言；选择会写入 config.json，同时作用于命令行与托盘。',
    'lang.auto': '自动',
    'lang.zh': '中文',
    'lang.en': 'English',
    'lang.fail': '语言写入 config.json 失败：{msg}',

    /* dais: signal + gauge */
    'dais.eyebrow': '当前状态 / LIVE',
    'dais.reading': '正在读取状态…',
    'gauge.tip': '定时保护的剩余时间',
    'gauge.eyebrow': '剩余',
    'gauge.hint.idle': '未在运行',
    'gauge.hint.expires': '到期 {at} 自动释放',
    'gauge.hint.infinite': '不限时长 · 手动停止为止',
    'gauge.hint.intentOrphan': 'intent 仍要求保护，但没有 worker',
    'gauge.meta.duration': '时长',
    'gauge.meta.intentAwake': 'awake · 看门狗会维持',
    'gauge.meta.unlimited': '不限',
    'gauge.meta.notSet': '未设定',
    'gauge.meta.intentWritten': 'intent 写入',
    'gauge.meta.never': '从未',
    'gauge.meta.orphans': '{n} 个未上报（孤儿）',
    'gauge.meta.none': '无',
    'gauge.meta.alien': ' · 外部 worker {n}（{root}，此处停不掉）',
    'gauge.meta.otherRoot': '其他目录',
    'gauge.meta.lastReport': '最近上报',
    'gauge.meta.ago': '{n}s 前',

    /* dais: engines */
    'engine1.num': '引擎 1',
    'engine2.num': '引擎 2',
    'engine1.heading': '电源请求',
    'engine2.heading': '防锁屏心跳',
    'engine.bit.live': '当前生效',
    'engine.bit.requested': '已请求但未生效',
    'engine.bit.off': '未请求',
    'engine.bitTip': '{label} {hex} — {state}',
    'engine1.none': '未持有请求',
    'engine1.state': 'pid {pid} · 活动 {hex}',
    'engine1.noteIdle': '没有 worker 就没有电源请求。电源计划（03）在本机怎么生效，取决于它的空闲计时器。',
    'engine.unrecordedState': '无从核对（记录写不下）',
    'engine.unrecordedNote': 'worker 进程活着，只是 state.json 写不下来 —— 这里的灰位与「关闭」都是读数缺失，不是引擎被关掉了。',
    'engine1.noteOk': '内核返回的位掩码：请求已被接受。若 OEM 电源管理中途抢占，worker 会按「重新声明」周期重新申请 —— 上面变灰即说明当下没压住。',
    'engine1.noteRejected': 'Windows 拒绝了 SYSTEM_REQUIRED。这是真问题，不是显示问题：机器该睡还是会睡。',
    /* 首轮 /api/state 到达前的占位文案，比上面的运行文案短 / first-paint placeholder, intentionally shorter than the live note */
    'engine1.noteStatic': '位掩码是内核返回的事实，不是界面推测。',
    'engine2.off': '关闭',
    'engine2.every': '每 {sec}s',
    'engine2.spec.state': '状态',
    'engine2.spec.method': '方式',
    'engine2.spec.sent': '已发出',
    'engine2.spec.last': '上次',
    'engine2.spec.next': '下次',
    'engine2.spec.result': '结果',
    'engine2.spec.skips': '锁屏跳过',
    'engine2.spec.lastLock': '最后锁屏',
    'engine2.spec.effect': '作用',
    'engine2.spec.resetOnly': '仅重置空闲计时',
    'engine2.spec.notEnabled': '本次运行未启用',
    'engine2.spec.notRunning': '未运行',
    'engine2.spec.unrecorded': '记录写不下',
    'engine2.spec.none': '尚未发送',
    'engine2.times': '{n} 次',
    'engine2.noteIdle': '关掉引擎 2 时，防锁屏完全依赖电源请求；有组策略空闲锁屏计时的机器上这会输。',
    'engine2.noteFailed': '最近一次心跳没能重置空闲计时 —— 系统当时处于锁屏或安全桌面。此时心跳无效，只有电源请求还在起作用。',
    'engine2.noteOk': '心跳只重置空闲计时，穿透不了 Win+L、合盖与已锁定的会话。',
    'engine2.noteStatic': '心跳只重置空闲计时，穿透不了 Win+L 与合盖。',

    /* dais: heartbeat trace */
    'trace.eyebrow': '心跳波形 / 一个周期 = 一个 antiLockIntervalSec',
    'trace.lg.sent': '已发出',
    'trace.lg.next': '下一次',
    'trace.lg.gap': '未运行',
    'trace.idle': '未运行 —— 没有心跳周期可画',
    'trace.unrecorded': '记录写不下 —— 没有可画的心跳周期',
    'trace.idleNoEngine': '引擎 2 关闭 —— 只有电源请求在起作用，无心跳周期',
    'trace.next': '下一次 ~{at}（{left}s 后）',
    'trace.window': '窗口 {span} · 周期 {sec}s',
    'trace.silent': '静默基线',
    'trace.now': '{at} 现在',
    'trace.aria': '心跳波形：每 {sec} 秒一次，窗口 {span}，可见 {n} 个脉冲',

    /* dais: readouts */
    'ro.elapsed': '已运行',
    'ro.pulses': '心跳',
    'ro.idle': '当前空闲',
    'ro.battery': '电源',
    'ro.efficacy': '有效性',
    'ro.idleSub': '无真实键鼠输入',
    'ro.efficacySub': '读内核电源日志，不自我宣称',

    /* 01 control */
    'panel.control.title': '控制台',
    'panel.control.desc': '参数改完直接点「启动保护」。若已有 worker 在跑且参数不同，它会按新参数重启 —— 不会回一句「已在运行」然后什么都不做。',
    'kbd.start': '启动',
    'kbd.stop': '停止',
    'kbd.refresh': '刷新',
    'ctl.duration': '运行时长',
    'ctl.min30': '30 分',
    'ctl.hour1': '1 小时',
    'ctl.hour2': '2 小时',
    'ctl.hour8': '8 小时',
    'ctl.custom': '自定义',
    'ctl.customPh': '分钟',
    'unit.min': '分',
    'unit.sec': '秒',
    'unit.pct': '%',
    'sw.display.title': '保持屏幕常亮',
    'sw.display.desc': 'ES_DISPLAY_REQUIRED —— 显示器不熄灭。插电时生效；电池低于阈值会自动降级（见下）',
    'sw.antiLock.title': '防锁屏心跳',
    'sw.antiLock.desc': '按周期发送一次无害输入，把空闲计时清零 —— 这是唯一能压住空闲锁屏的引擎',
    'sw.away.title': '离场模式 ES_AWAYMODE',
    'sw.away.desc': '微软给台式机媒体录制留的口子，明确写了便携机不该开，也不影响睡眠空闲计时器。现代待机机型上等于空操作，默认关闭',
    'sw.battOff.title': '电池上允许熄屏',
    'sw.battOff.desc': '掉电时优先保住续航：只禁系统休眠、放行显示器熄灭。关掉它就始终常亮（会明显更耗电、更热）',
    'row.method': '心跳方式',
    'method.key': 'F15 键',
    'method.mouse': '鼠标微移',
    'row.interval': '间隔',
    'row.reassert': '重新声明',
    'hint.reassert': 'OEM 电源管理会抢占请求，按此周期重新申请一次',
    'row.floor': '电池阈值',
    'btn.start': '启动保护',
    'btn.stop': '停止',
    'btn.save': '存为默认',
    'btn.saveSub': '写 config.json',
    'btn.refresh': '刷新',
    'busy.text': '与 worker 通信中',
    'panel.control.foot': '保护跑在独立 worker 进程里：关掉这个页面、关掉浏览器都不影响它。真正决定机器睡不睡的是那个进程，不是这个窗口。',

    /* 02 evidence */
    'panel.evidence.title': '保护是否真的有效',
    'panel.evidence.desc': '数据来自内核电源日志（Kernel-Power 506/507、Power-Troubleshooter），普通用户权限即可读。软件说自己没睡不算证据 —— 睡过就是睡过。',
    'ev.h6': '6 小时',
    'ev.h24': '24 小时',
    'ev.d3': '3 天',
    'btn.reread': '重读',
    'timeline.aria': '待机 / 唤醒事件时间轴',
    'tl.enter': '真睡眠（请求正被持有 → 被绕过）',
    'tl.enterOut': '真睡眠（当时没有任何请求）',
    'tl.enterUnknown': '真睡眠（ka.log 够不到，无法判定）',
    'tl.s3': '菱形 = Kernel-Power 42 的入睡转换（经典 S3 / 休眠）：填充、空心、虚线的含义与上面三个圆点相同',
    'tl.dim': '仅熄屏，未睡',
    'tl.exit': '唤醒 / 恢复',
    'tl.run': '保护区间',
    'ev.empty': '这段时间内没有任何待机 / 唤醒事件',
    'ev.spanTip': '保护区间：{from} → {to}',
    'ev.failed': '无法读取系统事件日志：{reason}',
    'ev.reasonUnknown': '未知原因',
    'ev.clean': '最近 {hours} 小时：0 次进入待机',
    'ev.cleanSome': '（另有 {n} 条唤醒类事件）',
    'ev.cleanNone': ' —— 电源请求没有被绕过过',
    'ev.hit': '最近 {hours} 小时：{enters} 次真睡眠发生在保护区间内 —— 那些时刻请求正被持有，平台把它绕过了',
    'ev.unprotected': '最近 {hours} 小时：{n} 次真睡眠落在保护区间之外（那些时刻没有任何请求，不算本工具的失败）',
    'ev.plusUnknown': '；另有 {n} 次无法判定（ka.log 保留的历史没这么长）',
    'ev.spanUnknown': '最近 {hours} 小时：{n} 次真睡眠无法判定（ka.log 保留的历史没这么长，说不出那些时刻有没有请求）',
    'ev.enterOnly': '最近 {hours} 小时：{n} 次低功耗会话，但本机不写 566 会话记录 —— 说不出这些时刻它是真走了还是只熄了屏',
    'ev.screenOnly': '最近 {hours} 小时：{n} 次熄屏、0 次真睡眠 —— 屏幕灭了，机器一直没走',
    'ev.unproven': '最近 {hours} 小时：无法证实 —— 本机声明的睡眠态里至少有一种不会留下本工具读得到的记录，「0 次」只代表「没有记录」，不代表「没有睡」',
    'ev.s3Counts': '42 入睡记录 {n}（恢复报告 {exits}）· 区间内 {bypass} · 区间外 {out} · 无法判定 {unknown}',
    'ev.readout': '读数源：{name}',
    'ev.instrument.full': '566 会话事件：能区分熄屏与真睡',
    'ev.instrument.both': '566 会话事件 + Kernel-Power 42（混合机型，两套计数各算各的）',
    'ev.instrument.s3-only': '只有 Kernel-Power 42：本机不写 506/566',
    'ev.instrument.no-session-events': '无 566 会话事件，本机也未声明需要它的睡眠态',
    'ev.instrument.blind': '盲区：本机声明的睡眠态至少有一种留不下本工具可读的记录',
    'ev.counts': 'enter {enters} · exit {exits} · 事件 {events} 条 · 查询 {result}',
    'ev.sessions': '熄屏会话 {screenOff} · 真睡眠 {sleeps}',
    'ev.spanCounts': '保护区间 {spans} 段 · 区间内 {bypass} · 区间外 {out} · 无法判定 {unknown}',
    'ev.spansPartial': 'ka.log 只保留到 {time}，更早的区间无从判断',
    'ev.spansNone': '无保护区间数据（ka.log 为空或不可读）',
    'ev.offToSleep': '{n} 次熄屏后 2 分钟内入睡（最近一次 {secs}s）',
    'ev.truncated': '事件已达 {n} 条上限，更早的没算进来',
    // 令牌名跟随微软 POWER_MONITOR_REQUEST_REASON 枚举；同一枚既标 506 的入睡原因，也标
    // 507 的唤醒来源，所以措辞不带方向 —— 哪一行显示它，哪一行就说明了方向。
    'ev.reason.unknown': '内核未给出原因',
    'ev.reason.no-reason': '事件未附带原因字段',
    'ev.reason.remote-connection': '远程连接',
    'ev.reason.sc-monitorpower': '应用请求熄屏（SC_MONITORPOWER）',
    'ev.reason.sets': '电源请求变更（SETS）',
    'ev.reason.screen-off-request': '屏幕熄灭请求（来源未文档化）',
    'ev.reason.video-idle': '屏幕空闲超时',
    'ev.reason.lid': '合盖',
    'ev.reason.sx-transition': '休眠/关机转换',
    'ev.reason.system-idle': '系统空闲超时',
    'ev.reason.input-keyboard': '键盘输入',
    'ev.reason.input-mouse': '鼠标输入',
    'ev.reason.input-touchpad': '触摸板输入',
    'ev.note': '「被绕过」只指那些时刻 ka.log 证明请求正被持有；区间外的真睡眠是本工具没在跑，不是它被忽略。合盖、电池耗尽、组策略强制维护、平台自带的现代待机超时都可能绕过电源请求；这里只报告事实，不给解释性保证。',
    'ev.fail': '读取失败：{msg}',

    /* 03 machine */
    'panel.machine.title': '本机环境适配',
    'panel.machine.desc': '逐条从 powercfg / 注册表实读，交流电与电池分开。心跳建议值由本机最短锁屏计时推导，不是抄来的通用数字。',
    'btn.recheck': '重新检测并写入 machine.json',
    'report.sleepState': '睡眠状态',
    'report.sleep': 'S0 现代待机={ms}  S3={s3}  休眠={hib}',
    'report.planSleep': '计划休眠',
    'report.planVideo': '计划熄屏',
    'report.acDc': '交流 {ac} / 电池 {dc}',
    'report.unattended': '无人值守待机',
    'report.lid': '合盖动作',
    'report.lidHidden': '隐藏 / 不可读（只能实测确认）',
    'report.lidVals': '交流 {ac} / 电池 {dc}（0=不采取任何操作）',
    'report.consoleLock': '唤醒后需登录',
    'report.consoleLockHidden': '不可读（平台隐藏该设置）',
    'report.lockNo': '不会锁屏',
    'report.lockYes': '会锁屏',
    'report.gpo': '组策略锁屏',
    'report.gpoIdle': '{dur} 无人操作',
    'report.gpoNone': '未发现',
    'report.screensaver': '屏保',
    'report.ssSecure': ' · 需要密码',
    'report.ssOpen': ' · 不锁屏',
    'report.eng1': '引擎 1 目标',
    'report.eng1Tight': '需压制的待机/熄屏计时最短 {dur}',
    'report.eng1Never': '本机计划本就是从不 —— 电源请求只是保险',
    'report.eng2': '引擎 2 依据',
    'report.eng2Tight': '最短空闲锁屏计时 {dur}',
    'report.eng2None': '未发现空闲锁屏计时器（动态锁读不到）',
    'report.reco': '建议心跳',
    'report.recoVal': '{sec} 秒（{why}）',
    'report.noRisk': '本机没有发现会绕过电源请求的配置。合盖与动态锁仍需实测确认。',
    'report.fail': '环境检测失败：{msg}',
    /* 后端只发 id 与数字，不发句子：这几个键名与 ka-core.ps1 里的完全一致。 */
    'report.why.no-lock-timer': '未发现空闲锁屏计时器，使用默认 240 秒',
    'report.why.half-of-lock-timer': '最短锁屏计时 {secs} 秒的一半（上限 240 秒）',
    'report.risk.modern-standby': '本机为 S0 现代待机（Modern Standby）：SetThreadExecutionState 可抑制空闲待机，但合盖、电池耗尽或平台策略仍可能强制进入待机。',
    'report.risk.lid-hidden': '合盖动作设置在本机被隐藏/不可读：合盖行为只能实测确认，无人值守时请保持开盖或外接显示器。',
    'report.risk.lid-action': '合盖动作当前为 {value}（并非 0=不采取任何操作）：合盖即待机，任何防休眠软件都无法阻止。',
    'lid.title': '现在合盖会发生什么',
    'lid.hidden': '档位读不出来（powercfg 查询失败），合盖会发生什么未知',
    'lid.tierAc': '当前插着电（电量 {pct}），交流档生效',
    'lid.tierDc': '当前用电池（电量 {pct}），电池档生效',
    'lid.now': '{tier} —— 合盖会执行：{action}',
    'lid.act.0': '不采取任何操作',
    'lid.act.1': '睡眠',
    'lid.act.2': '休眠',
    'lid.act.3': '关机',
    'lid.unknown': '未知值 {v}',
    'lid.verify.none': '没有「lid apply 写入」的记录（从没改过）—— 上面就是系统原配',
    'lid.verify.unobserved': '上次写入 {apply}，之后没有合盖时刻可复核 —— 写入成功不等于平台遵守，合一次盖再回来看这里',
    'lid.verify.no-sleep': '上次写入 {apply}；写入后最近一次合盖时刻 {when}（事件口径），那一次没有跟着合盖待机 —— 只证明那一次，不是永久保证',
    'lid.verify.slept': '上次写入 {apply}；写入后 {when} 仍发生过合盖待机（事件口径）—— 平台没有遵守写入，或动作本身就是睡眠',
    'lid.verify.unknown': '事件日志读取失败，实测状态未知',
    'lid.last': '最近一次合盖待机：{when}',
    'lid.note': '「合盖时刻」是事件日志的历史口径（每条 506/507 自带 LidOpenState），不是实时读数 —— 实时开合状态没有标准的免管理员读法。SETS 拦不住合盖，本工具不承诺阻止合盖。',
    'lid.nolid': '内核能力位确认本机没有盖开关（台式机或虚拟机）：合盖动作不适用。',
    'lid.presenceUnknown': '无法判定本机是否有盖开关（内核能力位读不到）：下面的合盖动作是照实读来的配置，但说不出这台机器到底有没有盖可合。',
    'report.risk.hybrid-sleep': '启用了快速启动/混合睡眠：关机并非完全断电，唤醒行为可能异常。',
    'report.risk.lock-policy': '存在无人操作锁屏策略（{minutes} 分钟）：多为组织策略，心跳只能延后不能永久压制。',
    'report.risk.battery': '当前使用电池（{pct}%）：达到 {floor}% 阈值后显示保护会自动降级。',
    'report.risk.override-self': 'requestsoverride 命中了本工具的镜像（{names}）：内核会静默忽略本工具发出的全部电源请求，保护名存实亡；需要管理员权限重新配置或清除该条目。',
    'machine.os': '系统',
    'machine.battery': '电池',
    'machine.laptop': '笔记本（有电池）',
    'machine.desktop': '台式机（无电池）',
    'machine.unknown': '无法判定（电源状态读不到）',
    'machine.checkedAt': '检测时间',
    'machine.store': '配置文件',
    'machine.storeNote': '面板默认值取自 config.json；machine.json 只是本机事实快照',
    'hint.intervalBig': '本机最短空闲计时约 {tight}，当前 {cur}s 偏大 —— 建议 {rec}s',
    'hint.intervalOk': '依据本机实测：建议 {rec} 秒',
    'check.running': '正在重读本机配置…',
    'check.done': '建议心跳 {sec} 秒（{why}）已写入 machine.json',
    'check.toast': '本机环境已重新检测并写入 machine.json。',
    'check.fail': '检测失败：{msg}',

    /* 04 guard */
    'panel.guard.title': '远程无人值守',
    'panel.guard.desc': '看门狗是计划任务，不靠面板窗口活着：登录自动启动、每 10 分钟按 intent.json 对账。人对不上机器的时候，自愈就是主功能而不是附加项。',
    'btn.guard.install': '安装看门狗',
    'btn.guard.reinstall': '重新安装看门狗',
    'btn.guard.uninstall': '卸载看门狗',
    'guard.installed': '已安装并启用：登录自动启动，每 10 分钟按 intent 对账。重启后保护会自己回来。',
    'guard.disabled': '已安装但处于禁用（{names}）：计划任务不会被触发，重启或进程被强杀后不会自动恢复保护。点「重新安装看门狗」重新注册并启用。',
    'guard.missing': '未安装：重启或进程被强杀后不会自动恢复保护。',
    'guard.unknown': '状态未知：读不到计划任务',
    'guard.headTask': '任务',
    'guard.headState': '状态 / 上次 / 下次 / 上次结果',
    'guard.tasks': '计划任务',
    'guard.notInstalled': '未安装',
    'guard.row': '{state} · 上次 {last} · 下次 {next} · 结果 {result}',
    'guard.toastInstalled': '看门狗已安装：登录自动启动，每 10 分钟按 intent.json 对账。不需要管理员权限。',
    'guard.toastUninstalled': '看门狗已卸载：重启后不会再自动拉起保护。',
    'guard.fail': '{op}失败：{msg}',
    'verb.install': '安装',
    'verb.uninstall': '卸载',
    'recon.title': '对账规则',
    'recon.1head': 'intent=awake 且未到期',
    'recon.1body': '且没有 worker → 拉起，并恢复剩余时长。',
    'recon.2head': 'intent=off',
    'recon.2body': '→ 看门狗什么都不做。你手动停止后它不会把你停的东西又开起来。',
    'recon.3head': '定时保护到期',
    'recon.3body': '→ 视为已了结，不会再被复活（到期不是故障）。',
    'recon.4head': '参数不写 intent',
    'recon.4body': '→ 重启后按 config.json 起。要让某组参数长期生效，点「存为默认」。',

    /* 05 log */
    'panel.log.title': '运行日志',
    'panel.log.desc': '启动、心跳、降级、恢复、退出原因都会落在这里。远程排障时，这台机器上的日志本身没用 —— 但它解释了上一次为什么没连上。',
    'btn.log': '刷新日志',
    'check.autoLog': '自动跟随',
    'log.aria': '运行日志',
    'log.empty': '（暂无日志）',
    'log.note': '日志按 logMaxKb 自动轮转（超限即截断保留后半）。',
    'btn.stopServer': '关闭面板进程',
    'btn.stopServerTip': '只关闭面板进程，保护会继续运行',
    'confirm.stopServer': '只关闭面板进程（保护本身会继续运行）。继续？',
    'gone.title': '面板进程已退出',
    'gone.detail': '保护仍在运行。需要再看面板时运行 panel.bat 或 ka.ps1 serve。',

    /* 06 limits */
    'panel.limits.title': '能力边界',
    'panel.limits.desc': '这一栏写的是「做不到什么」。防休眠软件最常见的失败是让人以为它无所不能。',
    'panel.limits.hint': '对照 PowerToys Awake / Caffeine / mouse jiggler 的公开行为整理',
    'limits.can': '能压住',
    'limits.cant': '压不住',
    'limits.verify': '怎么验证',
    'limits.can.1a': '空闲时自动进入的系统休眠 / 现代待机（',
    'limits.can.2a': '空闲时显示器熄灭（',
    'punct.close': '）',
    'limits.can.3': '空闲锁屏计时与需密码的屏保（心跳重置空闲计时）',
    'limits.can.4': 'OEM 电源管理中途抢占请求（按「重新声明」周期再申请）',
    'limits.can.5': '重启、崩溃、被强杀后的自动恢复（计划任务看门狗）',
    'limits.cant.1body': '、开始菜单→电源→锁屏：显式操作，任何软件都不该去拦',
    'limits.cant.2head': '合上屏幕盖',
    'limits.cant.2body': '：传感器触发，除非改掉合盖动作本身',
    'limits.cant.3a': '心跳',
    'limits.cant.3b': '穿透不了锁屏',
    'limits.cant.3c': '：已锁屏时输入不会送到会话里，只会显示在锁屏界面上',
    'limits.cant.4': '组策略强制维护窗口、电池耗尽保护、平台强制待机',
    'limits.cant.5': '动态锁（手机蓝牙）、第三方安全软件的自行锁定 —— 本机读不到',
    'limits.verify.1a': '启动保护 → 让机器空闲 10 分钟 → 看',
    'limits.verify.1b': '的「进入待机」次数',
    'limits.verify.2a': '合盖实测：',
    'limits.verify.2b': '（自带备份，',
    'limits.verify.2c': '可还原）',
    'limits.verify.3a': '到底是谁在起作用：',
    'limits.verify.3b': '的「同类软件」一行',
    'limits.verify.4a': '是待机还是只是熄屏：',
    'limits.verify.4b': '两者成因不同',

    /* footer + shared */
    'foot.right': '所有请求只走向 127.0.0.1 · 面板不带跨域许可，外部页面无法驱动它',
    'foot.info': 'root {root} · 会话 {session} · {priv} · 面板时钟 {clock}',
    'foot.elevated': '已提升权限',
    'foot.user': '普通用户权限（够用）',
    'docTitle.running': '● 保护运行中 · {name}',
    'docTitle.idle': '○ 未运行 · {name}',
    'docTitle.gone': '面板已退出 · {name}',
    'state.running': '保护运行中 · pid {pid}',
    'state.notRunning': '未运行',
    'state.detail': '系统不会进入空闲休眠；{disp} 关闭本页面不影响它。',
    'state.detailDisplayOn': '显示器保持点亮。',
    'state.detailDisplayOff': '显示器仍可按电源计划熄灭。',
    'state.detailExpired': '上次定时保护已到期并自行释放（不是故障）。',
    'state.detailIdle': '电脑会按系统电源计划休眠 / 熄屏，锁屏计时也照常走。',
    'state.unrecorded': '有 worker 在运行（pid {pid}）· 无状态记录',
    'state.detailUnrecorded': '电源请求大概率仍然有效，只是状态写不下来——检查数据目录是否可写（默认 %LOCALAPPDATA%\\KeepAwake）。',
    'state.unrecordedSub': '记录写不下',
    'state.unrecordedEfficacySub': '无从核对：状态记录没写下来，保护区间无法重建',
    'state.since': '起 {at}',
    'state.pulseSub': '间隔 {sec}s · {method}',
    'state.pulseSubOff': '引擎 2 未启用',
    'state.pulseNone': '无心跳',
    'state.elapsedNone': '没有 worker 在跑',
    'state.efficacyOk': '有效',
    'state.efficacySleeps': '待机 {n} 次',
    'state.efficacyBypass': '被绕过 {n} 次',
    'state.efficacyUnproven': '无法证实',
    'state.efficacySub': '本次运行期间内核日志：低功耗会话 {enters} · 真睡眠 {sleeps} · 其中被绕过 {bypass} · 唤醒 {exits}',
    'state.efficacySubS3': 'Kernel-Power 42 入睡 {n} · 恢复 {exits}',
    'state.efficacySubBlind': '读数源：{name}',
    'state.efficacySubIdle': '未运行时无从谈有效性 —— 看 02 的历史窗口',
    'state.evFailed': '事件日志查询失败',
    'state.idleSub': '距上次真实键鼠输入 · 心跳不算真实输入',
    'state.noPanel': '读不到面板进程',
    'state.battAc': '交流 · {p}',
    'state.battDc': '电池 · {p}',
    'state.battUnknown': '读不到电源状态（原生调用失败），无法判断有无电池',
    'state.battNone': '无电池',
    'state.battNoneSub': '台式机或虚拟机 —— 电池阈值与低电降档不适用',
    'state.battNoneOdd': '台式机或虚拟机，但交流电读作断开（常见于虚拟机）：电源相关建议仅供参考',
    'state.battAcOk': '已插电，保护不会因续航降级',
    'state.battDcFloor': '未插电 · 阈值 {floor}%',
    'state.battDcLow': '未插电 · 已低于阈值 {floor}%，显示保护按策略降级',
    'pill.displayOn': '屏幕常亮',
    'pill.displayDowngraded': '屏幕常亮 · 电池降级中',
    'pill.systemOnly': '仅禁止系统休眠',
    'pill.heartbeat': '心跳 {method} @ {sec}s',
    'pill.heartbeatOff': '心跳关闭',
    'pill.away': '离场模式 ES_AWAYMODE',
    'pill.reassert': '重新声明 {sec}s',
    'pill.lockSkips': '锁屏跳过 {n} 次',
    'pill.ilSkips': 'UIPI 跳过 {n} 次',
    'pill.note.lock-screen': '锁屏/安全桌面：心跳到不了用户会话（电源请求仍然有效）',
    'pill.note.il-mismatch': '前台为更高完整性（管理员）进程：心跳输入被 UIPI 丢弃（电源请求仍然有效）',
    'pill.note.battery-floor': '电池 {pct}% 低于阈值 {floor}%：已允许熄屏',
    'pill.error.settes-zero': '电源请求被拒（返回 0，{why}）',
    'pill.error.settes-throw': '电源请求调用异常（{why}）',
    'pill.drift': 'config.json 与运行参数不同（{keys}）：本次运行按上方参数，重启后按 config.json —— 需要长期生效请点「存为默认」',
    'pill.idlePlan': '空闲时按系统电源计划行动',
    'pill.unrecorded': '记录写不下 · 引擎读数缺失',
    'pill.standby': '待用配置：心跳 {method} @ {sec}s',
    'pill.competitors': '检测到同类软件：{list}',
    'alert.foreignWorkers': '另有 {count} 个 worker 属于别的目录（{roots}），本工具无法停止它 —— 关掉这里后电脑仍不会休眠',
    'alert.batteryFloor': '电池 {pct}% 且未插电，显示保护已按策略降级',
    'alert.sleepEvidence': '保护运行期间有 {n} 次真睡眠发生在电源请求正被持有时 —— 平台在这些时刻绕过了它',
    'alert.evidenceBlind': '本机声明的睡眠态里至少有一种不会留下本工具读得到的记录 —— 界面上的绿色只代表「没有记录」，不代表「没有睡」；本机能读到什么写在证据区',
    'alert.multiWorker': '检测到 {count} 个 worker 进程，正常应为 1 个',
    'alert.standbyLid': '其中 {count} 次由合盖触发 —— 合盖会绕过电源请求直接进待机，唤醒后 Windows 默认要求登录；需要远程访问请保持开盖（但开盖只是必要不充分：本机大多数待机是盖子开着时的空闲超时，那一半才是本工具管得住的），或运行 ka.bat lid apply 把合盖动作改成「不进行操作」（改完请真的合一次盖验证：部分平台接受写入却仍然进待机）',
    'alert.sessionLocked': '会话当前处于锁屏/安全桌面：电源请求仍然有效、电脑不会休眠，但远程接入只会看到锁屏（心跳已跳过 {count} 次）',
    'alert.uipiBlocked': '心跳输入正被 UIPI 丢弃：前台是更高完整性（管理员）的程序，空闲锁屏计时压不住（电源请求仍有效，电脑不会休眠）。要么关掉那个管理员程序，要么以管理员身份重新运行本工具 —— 已跳过 {count} 次，前台解除后下一次心跳自动恢复',
    'alert.staleState': 'worker 已停止上报状态，保护可能已经失效',
    'alert.dataDirUnwritable': '数据目录 {path} 不可写（{error}）：状态、意图与停止信号都落不了地，面板会把正在运行的保护显示成没在跑',
    'alert.machineDirUnwritable': '机器数据目录 {path} 不可写（{error}）：合盖备份与机器级状态无法保存',
    'alert.stateUnrecorded': '{count} 个 worker 正在运行，但读不到 {path} —— 电源请求仍然有效，只是没有记录（保护是真的，只是看不见）',
    'alert.guardDisabled': '看门狗计划任务处于禁用（{names}）：它不会被触发，重启或 worker 被强杀之后没有东西会把保护拉回来。点「重新安装看门狗」重新注册即可恢复',
    'competitor.powerToys': 'PowerToys（可能包含 Awake 模块）',
    'competitor.presentation': 'Windows 演示模式（presentationsettings）',
    'competitor.confirm': 'powercfg /requests（需以管理员身份运行）',
    'common.unreadable': '不可读',
    'common.now': '现在',
    'common.never': '从不',
    'common.none': '无',
    'common.unknown': '未知',
    'common.unlimited': '不限时长',
    'common.yes': '是',
    'common.no': '否',
    'common.supported': '支持',
    'common.unsupported': '不支持',
    'common.listSep': '、',
    'dur.sec': '{n} 秒',
    'dur.h': ' 小时',
    'dur.m': ' 分',
    'dur.min': ' 分钟',
    'dur.d': ' 天 ',
    'api.notJson': '响应不是 JSON (HTTP {status})',
    'api.http': 'HTTP {status}',
    'err.render': '界面渲染异常：{msg}',
    'refresh.done': '已刷新：控制区恢复为 config.json 的值。',
    'save.done': '已写入 config.json。正在运行的 worker 不会被改动 —— 但看门狗与重启后的默认值现在是这套参数。',
    'save.fail': '写入失败：{msg}',
    'start.restarted': 'worker 已按新参数重启',
    'start.already': '保护已在运行（参数未变化）',
    'start.started': '保护已启动',
    'start.unrecorded': '保护已启动，但状态写不下来',
    'start.summary': '{head} · pid {pid} · {disp} · {hb} · {dur}{clamp}',
    'start.dispOff': '仅禁休眠',
    'start.hb': '{method}@{sec}s',
    'start.hbOff': '无心跳',
    'start.endsIn': '{dur}后自动结束',
    'start.clamped': '（部分取值被边界修正，见参数区）',
    'start.fail': '启动失败：{msg}',
    'stop.done': '已停止 {n} 个 worker{forced}，电源请求随进程释放。',
    'stop.forced': '（{n} 个未响应协作退出，其收尾未执行）',
    'stop.uncoop': '，且协作退出不可用（stop.flag 写不下），进程是被直接结束的',
    'stop.fail': '停止失败：{msg}',

    /* first-visit guide */
    'guide.title': '第一次来？这个面板管三件事',
    'guide.p1': '启动保护：在「控制台」选时长、点「启动保护」。之后关掉这个页面保护也不会停 —— 真正干活的是独立的 worker 进程。',
    'guide.p2': '验证效果：「有效性」里的证据直接读内核电源日志，把「只是熄屏」和「真的睡了」分开计数。软件自己说没睡不算证据。',
    'guide.p3': '无人值守：「无人值守」的看门狗是计划任务，登录自动启动，每 10 分钟按 intent 对账。',
    'guide.dismiss': '知道了，不再显示',

    /* explainers */
    'help.aria': '展开解释',
    'help.ev.label': '这些结论是什么意思？',
    'help.ev.body': '结论按内核电源日志逐条归因：「被绕过」= 电源请求还在被持有，机器却睡了，这是平台无视请求的唯一实锤；「睡眠时无请求持有」= 睡过，但那一刻没人要求保持清醒，责任不在保护；「无从判断」= 时间早于保留日志的覆盖范围，既不自证清白也不归罪；「仅熄屏」= 屏幕黑了但系统没有离场，506 事件也会计入它，所以不能只看 506 的数字。下方的筛选只是观察视角，不改变上面任何一个数字。',
    'help.dais.label': '这些读数是什么？',
    'help.dais.body': '心跳 = worker 实际发出的防锁屏动作次数；空闲 = 系统上报的无输入时长，心跳生效时会不断把它推回去；有效性 = 本窗口内「睡没睡过」的结论，与「有效性」一栏的证据同源。',
    'help.report.label': '这些风险从哪来？',
    'help.report.body': '每一条都从 powercfg / 注册表 / 系统能力实时读取，不是缓存。标红的项会真实打断无人值守（比如合盖睡眠，任何软件都拦不住）；标黄的项需要注意但不必然出问题。心跳建议值由本机最短锁屏计时推导，不是通用数字。',

    /* preview before start */
    'preview.title': '启动前确认',
    'preview.note': '确认前改动参数，下面的预览会同步更新；点「确认启动」才真正发送电源请求。',
    'preview.dur': '时长',
    'preview.ends': '{at} 自动释放',
    'preview.unlimited': '不限时长 · 手动停止为止',
    'preview.flags': '将发送的电源请求',
    'preview.flagsHint': 'SetThreadExecutionState(ES_CONTINUOUS | 以下标志)',
    'preview.flag.system': '阻止系统睡眠',
    'preview.flag.display': '保持屏幕常亮',
    'preview.flag.away': '允许离开模式（屏幕可灭、系统不睡）',
    'preview.flag.continuous': '持续生效，直到进程退出',
    'preview.hb': '防锁屏心跳',
    'preview.hbOn': '每 {sec} 秒 {method}',
    'preview.hbOff': '无 · 只靠电源请求',
    'preview.away': '离开模式',
    'preview.awayOn': '开 · 屏幕可灭、系统不睡',
    'preview.awayOff': '关',
    'preview.battery': '电池行为',
    'preview.battAllow': '电池低于 {floor}% 时降级为允许熄屏（仍禁睡眠）',
    'preview.battKeep': '电池下也保持亮屏（直到 {floor}%）',
    'preview.risks': '本机适用风险',
    'preview.noRisks': '无',
    'preview.confirm': '确认启动',
    'preview.cancel': '返回修改',

    /* evidence filter */
    'evf.aria': '证据筛选',
    'evf.all': '全部',
    'evf.sleep': '真睡眠',
    'evf.screenOff': '仅熄屏',
    'evf.lid': '合盖',
    'evf.bypass': '被绕过',
    'evf.out': '无请求持有',
    'evf.search': '搜索：原因 / lid / id…',
    'evf.hits': '命中 {hit}/{total}',
    'evf.empty': '没有事件符合这个筛选',
    'evf.lens': '筛选只是查看视角，上方结论与统计仍按整个时间窗计算'
  };

  var en = {

    /* page + masthead */
    'page.title': 'Keep-Awake Console',
    'page.name': 'Keep-Awake Console',
    'mast.sub': 'Keep-Awake Console · local 127.0.0.1 · no network / no login / no install',
    'mast.clockTip': 'Clock of the panel process',
    'nav.aria': 'Dashboard navigation',
    'nav.control': 'Control',
    'nav.evidence': 'Evidence',
    'nav.machine': 'This machine',
    'nav.guard': 'Unattended',
    'nav.log': 'Log',
    'nav.limits': 'Limits',
    'conn.connecting': 'Connecting…',
    'conn.ok': 'Panel online',
    'conn.gone': 'Panel exited',
    'conn.dead': 'Panel unreachable',

    /* language switcher */
    'lang.aria': 'Interface language',
    'lang.tip': 'Auto follows the browser language. The choice is saved to config.json and also applies to the command line and the tray.',
    'lang.auto': 'Auto',
    'lang.zh': 'Chinese',
    'lang.en': 'English',
    'lang.fail': 'Could not save the language to config.json: {msg}',

    /* dais: signal + gauge */
    'dais.eyebrow': 'Current state / LIVE',
    'dais.reading': 'Reading state…',
    'gauge.tip': 'Time left on the timed protection',
    'gauge.eyebrow': 'Left',
    'gauge.hint.idle': 'Not running',
    'gauge.hint.expires': 'Releases on its own at {at}',
    'gauge.hint.infinite': 'No limit · until stopped by hand',
    'gauge.hint.intentOrphan': 'intent still asks for protection, but no worker is running',
    'gauge.meta.duration': 'Length',
    'gauge.meta.intentAwake': 'awake · the watchdog keeps it',
    'gauge.meta.unlimited': 'Unlimited',
    'gauge.meta.notSet': 'Not set',
    'gauge.meta.intentWritten': 'intent written',
    'gauge.meta.never': 'Never',
    'gauge.meta.orphans': '{n} unreported (orphaned)',
    'gauge.meta.none': 'None',
    'gauge.meta.alien': ' · foreign worker {n} ({root}, cannot be stopped from here)',
    'gauge.meta.otherRoot': 'another folder',
    'gauge.meta.lastReport': 'Last report',
    'gauge.meta.ago': '{n}s ago',

    /* dais: engines */
    'engine1.num': 'Engine 1',
    'engine2.num': 'Engine 2',
    'engine1.heading': 'Power request',
    'engine2.heading': 'Anti-lock heartbeat',
    'engine.bit.live': 'currently active',
    'engine.bit.requested': 'requested but not active',
    'engine.bit.off': 'not requested',
    'engine.bitTip': '{label} {hex} — {state}',
    'engine1.none': 'No request held',
    'engine1.state': 'pid {pid} · active {hex}',
    'engine1.noteIdle': 'No worker means no power request. How the plan in (03) plays out here depends on its own idle timers.',
    'engine.unrecordedState': 'Cannot be checked (record unwritable)',
    'engine.unrecordedNote': 'The worker process is alive; only state.json could not be written — the greyed chips and the "off" here are missing readings, not engines that were switched off.',
    'engine1.noteOk': 'Bit mask as returned by the kernel: the request was accepted. If OEM power management takes it away mid-run, the worker re-asserts it on the Re-assert interval — a greyed chip above means it is not being held right now.',
    'engine1.noteRejected': 'Windows refused SYSTEM_REQUIRED. That is a real failure, not a display one: the machine will still sleep.',
    'engine1.noteStatic': 'The bit mask is what the kernel returned, not a guess made by this interface.',
    'engine2.off': 'Off',
    'engine2.every': 'every {sec}s',
    'engine2.spec.state': 'State',
    'engine2.spec.method': 'Method',
    'engine2.spec.sent': 'Sent',
    'engine2.spec.last': 'Last',
    'engine2.spec.next': 'Next',
    'engine2.spec.result': 'Result',
    'engine2.spec.skips': 'Lock skips',
    'engine2.spec.lastLock': 'Last lock',
    'engine2.spec.effect': 'Effect',
    'engine2.spec.resetOnly': 'Resets the idle timer only',
    'engine2.spec.notEnabled': 'Not enabled for this run',
    'engine2.spec.notRunning': 'Not running',
    'engine2.spec.unrecorded': 'Record unwritable',
    'engine2.spec.none': 'Not sent yet',
    'engine2.times': '{n}',
    'engine2.noteIdle': 'With engine 2 off, anti-lock rests entirely on the power request; on a machine with a group-policy idle lock timer that loses.',
    'engine2.noteFailed': 'The last heartbeat did not reset the idle timer — the system was on the lock screen or a secure desktop. A heartbeat is useless there; only the power request still works.',
    'engine2.noteOk': 'The heartbeat only resets the idle timer. It cannot cross Win+L, a closed lid or an already locked session.',
    'engine2.noteStatic': 'The heartbeat only resets the idle timer; it cannot cross Win+L or a closed lid.',

    /* dais: heartbeat trace */
    'trace.eyebrow': 'Heartbeat trace / one cycle = one antiLockIntervalSec',
    'trace.lg.sent': 'Sent',
    'trace.lg.next': 'Next',
    'trace.lg.gap': 'Not running',
    'trace.idle': 'Not running — no heartbeat cycle to draw',
    'trace.unrecorded': 'Record unwritable — no heartbeat cycle to draw',
    'trace.idleNoEngine': 'Engine 2 is off — only the power request works, so there is no heartbeat cycle',
    'trace.next': 'next ~{at} ({left}s away)',
    'trace.window': 'window {span} · period {sec}s',
    'trace.silent': 'Silent baseline',
    'trace.now': '{at} now',
    'trace.aria': 'Heartbeat trace: one pulse every {sec} seconds over a window of {span}, {n} pulses visible',

    /* dais: readouts */
    'ro.elapsed': 'Running',
    'ro.pulses': 'Heartbeat',
    'ro.idle': 'Idle now',
    'ro.battery': 'Power',
    'ro.efficacy': 'Efficacy',
    'ro.idleSub': 'No real keyboard or mouse input',
    'ro.efficacySub': 'From the kernel power log, never self-reported',

    /* 01 control */
    'panel.control.title': 'Console',
    'panel.control.desc': 'Change the values and press Start protection. If a worker is already running with different settings it restarts on the new ones — it will not answer "already running" and do nothing.',
    'kbd.start': 'start',
    'kbd.stop': 'stop',
    'kbd.refresh': 'refresh',
    'ctl.duration': 'Run length',
    'ctl.min30': '30 min',
    'ctl.hour1': '1 hour',
    'ctl.hour2': '2 hours',
    'ctl.hour8': '8 hours',
    'ctl.custom': 'Custom',
    'ctl.customPh': 'minutes',
    'unit.min': 'min',
    'unit.sec': 's',
    'unit.pct': '%',
    'sw.display.title': 'Keep the display on',
    'sw.display.desc': 'ES_DISPLAY_REQUIRED — the monitor never blanks. Works while plugged in; below the battery threshold it downgrades on its own (see below)',
    'sw.antiLock.title': 'Anti-lock heartbeat',
    'sw.antiLock.desc': 'Sends one harmless input per cycle to zero the idle timer — the only engine that beats the idle lock screen',
    'sw.away.title': 'Away mode ES_AWAYMODE',
    'sw.away.desc': 'A door Microsoft left open for desktop media recording. It explicitly says portable machines should not use it, and it does not touch the sleep idle timer. A no-op on Modern Standby machines, off by default',
    'sw.battOff.title': 'Allow display off on battery',
    'sw.battOff.desc': 'On battery, runtime wins: system sleep stays blocked but the display may blank. Turn this off to always keep the display lit (clearly more power, clearly hotter)',
    'row.method': 'Heartbeat',
    'method.key': 'F15 key',
    'method.mouse': 'Mouse jiggle',
    'row.interval': 'Interval',
    'row.reassert': 'Re-assert',
    'hint.reassert': 'OEM power management steals the request, so ask for it again on this interval',
    'row.floor': 'Battery floor',
    'btn.start': 'Start protection',
    'btn.stop': 'Stop',
    'btn.save': 'Save as default',
    'btn.saveSub': 'writes config.json',
    'btn.refresh': 'Refresh',
    'busy.text': 'Talking to the worker',
    'panel.control.foot': 'Protection runs in its own worker process: closing this page or the browser does not affect it. That process decides whether the machine sleeps, not this window.',

    /* 02 evidence */
    'panel.evidence.title': 'Is the protection actually working',
    'panel.evidence.desc': 'The data comes from the kernel power log (Kernel-Power 506/507, Power-Troubleshooter) and is readable at normal user rights. Software saying it never slept is not evidence — a sleep that happened is a sleep that happened.',
    'ev.h6': '6 h',
    'ev.h24': '24 h',
    'ev.d3': '3 d',
    'btn.reread': 'Re-read',
    'timeline.aria': 'Timeline of sleep and wake events',
    'tl.enter': 'Reached sleep while a request was held (bypassed)',
    'tl.enterOut': 'Reached sleep with no request held',
    'tl.enterUnknown': 'Reached sleep, not placeable from ka.log',
    'tl.s3': 'Diamond = a Kernel-Power 42 sleep-entry transition (classic S3 / hibernate). Filled, hollow and dashed mean the same as the three dots above.',
    'tl.dim': 'Display off only',
    'tl.exit': 'Wake / resume',
    'tl.run': 'Protected span',
    'ev.empty': 'No sleep or wake events at all in this window',
    'ev.spanTip': 'Protected span: {from} → {to}',
    'ev.failed': 'Cannot read the system event log: {reason}',
    'ev.reasonUnknown': 'unknown reason',
    'ev.clean': 'Last {hours} h: 0 entries into sleep',
    'ev.cleanSome': ' ({n} wake-type events)',
    'ev.cleanNone': ' — the power request was never bypassed',
    'ev.hit': 'Last {hours} h: {enters} real sleep(s) inside a protected span — the request was held at those moments and the platform bypassed it',
    'ev.unprotected': 'Last {hours} h: {n} real sleep(s) outside a protected span — nothing was asking at those moments, so this tool did not fail',
    'ev.plusUnknown': '; plus {n} that cannot be placed (ka.log does not reach back that far)',
    'ev.spanUnknown': 'Last {hours} h: {n} real sleep(s) cannot be placed — ka.log does not reach back that far, so nobody knows whether a request was held',
    'ev.enterOnly': 'Last {hours} h: {n} low-power session(s), but this machine writes no 566 session records — nothing here can say whether it left or only blanked the screen',
    'ev.screenOnly': 'Last {hours} h: {n} display-off(s), 0 real sleeps — the screen went dark, the machine never left',
    'ev.unproven': 'Last {hours} h: cannot be proven — at least one sleep state this machine declares leaves no record this tool reads, so the 0 below means nothing was logged, not that it did not sleep',
    'ev.s3Counts': '{n} Kernel-Power 42 entries ({exits} resume reports) · {bypass} inside a span · {out} outside · {unknown} unplaceable',
    'ev.readout': 'Readout: {name}',
    'ev.instrument.full': '566 session events: tells a display-off from a real sleep',
    'ev.instrument.both': '566 session events + Kernel-Power 42 (hybrid machine, the two counters kept apart)',
    'ev.instrument.s3-only': 'Kernel-Power 42 only: this machine writes no 506/566',
    'ev.instrument.no-session-events': 'no 566 session events, and this machine declares no sleep state that would need them',
    'ev.instrument.blind': 'blind: at least one sleep state this machine declares leaves no record this tool reads',
    'ev.counts': 'enter {enters} · exit {exits} · {events} events · query {result}',
    'ev.sessions': 'display-off sessions {screenOff} · real sleeps {sleeps}',
    'ev.spanCounts': '{spans} protected span(s) · {bypass} inside · {out} outside · {unknown} unplaceable',
    'ev.spansPartial': 'ka.log only reaches back to {time}; spans before that cannot be known',
    'ev.spansNone': 'no protected-span data (ka.log empty or unreadable)',
    'ev.offToSleep': '{n} slept within 2 min of a display off (last one {secs}s)',
    'ev.truncated': 'Query hit the {n}-record cap; older events were left out',
    // Tokens are Microsoft's POWER_MONITOR_REQUEST_REASON names, kept direction-neutral:
    // one token labels the cause on a 506 and the wake source on a 507.
    'ev.reason.unknown': 'kernel gave no reason',
    'ev.reason.no-reason': 'record carried no reason field',
    'ev.reason.remote-connection': 'remote connection',
    'ev.reason.sc-monitorpower': 'app requested display off (SC_MONITORPOWER)',
    'ev.reason.sets': 'power request change (SETS)',
    'ev.reason.screen-off-request': 'screen off request (caller not documented)',
    'ev.reason.video-idle': 'display idle timeout',
    'ev.reason.lid': 'lid closed',
    'ev.reason.sx-transition': 'hibernate/shutdown transition',
    'ev.reason.system-idle': 'system idle timeout',
    'ev.reason.input-keyboard': 'keyboard input',
    'ev.reason.input-mouse': 'mouse input',
    'ev.reason.input-touchpad': 'touchpad input',
    'ev.note': '“Bypassed” means only that ka.log proves a request was held at those moments. A real sleep outside a protected span means this tool was not running then, not that it was ignored. A closed lid, a flat battery, forced maintenance from group policy or the platform’s own Modern Standby timeout can all bypass the power request. This reports facts only and offers no explanatory assurances.',
    'ev.fail': 'Read failed: {msg}',

    /* 03 machine */
    'panel.machine.title': 'How it fits this machine',
    'panel.machine.desc': 'Read item by item from powercfg and the registry, AC and battery kept apart. The suggested heartbeat interval is derived from this machine’s shortest lock timer, not copied from a generic number.',
    'btn.recheck': 'Re-detect and write machine.json',
    'report.sleepState': 'Sleep states',
    'report.sleep': 'S0 Modern Standby={ms}  S3={s3}  Hibernate={hib}',
    'report.planSleep': 'Plan sleep',
    'report.planVideo': 'Plan display off',
    'report.acDc': 'AC {ac} / battery {dc}',
    'report.unattended': 'Unattended sleep',
    'report.lid': 'Lid action',
    'report.lidHidden': 'hidden / unreadable (only a real test settles it)',
    'report.lidVals': 'AC {ac} / battery {dc} (0 = take no action)',
    'report.consoleLock': 'Sign-in after wake',
    'report.consoleLockHidden': 'unreadable (the platform hides it)',
    'report.lockNo': 'Will not lock',
    'report.lockYes': 'Will lock',
    'report.gpo': 'Policy lock screen',
    'report.gpoIdle': '{dur} idle',
    'report.gpoNone': 'Not found',
    'report.screensaver': 'Screen saver',
    'report.ssSecure': ' · needs a password',
    'report.ssOpen': ' · does not lock',
    'report.eng1': 'Engine 1 target',
    'report.eng1Tight': 'Shortest sleep/display timer to beat: {dur}',
    'report.eng1Never': 'This plan is already Never — the power request is only insurance',
    'report.eng2': 'Engine 2 basis',
    'report.eng2Tight': 'Shortest idle lock timer {dur}',
    'report.eng2None': 'No idle lock timer found (dynamic lock is invisible here)',
    'report.reco': 'Suggested heartbeat',
    'report.recoVal': '{sec} s ({why})',
    'report.noRisk': 'Nothing on this machine bypasses a power request. The lid and dynamic lock still need a real test.',
    'report.fail': 'Environment check failed: {msg}',
    'report.why.no-lock-timer': 'No idle lock timer found, so the 240 s default is used',
    'report.why.half-of-lock-timer': 'Half of the shortest lock timer ({secs} s), capped at 240 s',
    'report.risk.modern-standby': 'This machine uses S0 Modern Standby: SetThreadExecutionState suppresses idle standby, but closing the lid, a flat battery or a platform policy can still force it.',
    'report.risk.lid-hidden': 'The lid-close action is hidden or unreadable here: only a real test shows what the lid does, so leave the lid open or attach an external display for unattended runs.',
    'report.risk.lid-action': 'The lid-close action is currently {value} (not 0 = do nothing): closing the lid sleeps the machine and no keep-awake software can prevent that.',
    'lid.title': 'What happens if the lid closes now',
    'lid.hidden': 'LIDACTION unreadable (powercfg query failed) - what a lid close does is unknown',
    'lid.tierAc': 'on AC now (battery {pct}), the AC tier applies',
    'lid.tierDc': 'on battery now ({pct}), the battery tier applies',
    'lid.now': '{tier} - closing the lid runs: {action}',
    'lid.act.0': 'do nothing',
    'lid.act.1': 'sleep',
    'lid.act.2': 'hibernate',
    'lid.act.3': 'shut down',
    'lid.unknown': 'unknown value {v}',
    'lid.verify.none': 'No lid-apply write on record (never changed) - the values above are the machine\'s factory setting',
    'lid.verify.unobserved': 'Last write {apply}; no lid-closed moment since, inside the 14-day window, to inspect - a successful write is not a honored setting; close the lid once and check back here',
    'lid.verify.no-sleep': 'Last write {apply}; the most recent lid-closed moment after it ({when}, event log) did not lead to a lid standby - that proves that one moment, not forever',
    'lid.verify.slept': 'Last write {apply}; a lid standby still happened at {when} after the write (event log) - the platform ignored it, or the configured action is sleep itself',
    'lid.verify.unknown': 'Event log unreadable; tested state unknown',
    'lid.last': 'Most recent lid standby: {when}',
    'lid.note': 'Lid-closed moments are event-log history (per-event LidOpenState on 506/507), not a live reading - there is no standard unprivileged way to read lid state in real time. SETS cannot intercept a lid close; this tool promises no prevention.',
    'lid.nolid': 'The kernel capability bit confirms this machine has no lid switch (desktop or virtual machine): the lid action does not apply.',
    'lid.presenceUnknown': 'Cannot tell whether this machine has a lid (the capability bit could not be read): the lid action below is the configuration as read, but nobody knows if there is a lid to close.',
    'report.risk.hybrid-sleep': 'Fast Startup / hybrid sleep is on: shutdown is not a full power-off, so resume behaviour can look odd.',
    'report.risk.lock-policy': 'An inactivity lock policy exists ({minutes} min): usually pushed by a domain policy, and a heartbeat can only delay it, not beat it forever.',
    'report.risk.battery': 'Running on battery ({pct}%): display protection steps down automatically once the {floor}% floor is reached.',
    'report.risk.override-self': 'A requestsoverride entry names this product\'s image ({names}): the kernel silently ignores every power request the tool makes - protection is gone without any error. Removing or reconfiguring the entry needs elevation.',
    'machine.os': 'System',
    'machine.battery': 'Battery',
    'machine.laptop': 'Laptop (has a battery)',
    'machine.desktop': 'Desktop (no battery)',
    'machine.unknown': 'Cannot tell (power status unreadable)',
    'machine.checkedAt': 'Detected',
    'machine.store': 'Setting files',
    'machine.storeNote': 'The panel defaults come from config.json; machine.json is only a snapshot of this machine',
    'hint.intervalBig': 'Shortest idle timer here is about {tight}; {cur}s is too long — {rec}s is suggested',
    'hint.intervalOk': 'Measured on this machine: {rec} s suggested',
    'check.running': 'Re-reading this machine’s settings…',
    'check.done': 'Suggested heartbeat {sec} s ({why}) written to machine.json',
    'check.toast': 'This machine was re-detected and written to machine.json.',
    'check.fail': 'Detection failed: {msg}',

    /* 04 guard */
    'panel.guard.title': 'Unattended, from a distance',
    'panel.guard.desc': 'The watchdog is a scheduled task, not something that lives in this window: it starts at logon and reconciles against intent.json every 10 minutes. When nobody is at the machine, self-healing is the main feature rather than an extra.',
    'btn.guard.install': 'Install watchdog',
    'btn.guard.reinstall': 'Re-install watchdog',
    'btn.guard.uninstall': 'Uninstall watchdog',
    'guard.installed': 'Installed and enabled: starts at logon and reconciles against intent every 10 minutes. After a reboot protection comes back on its own.',
    'guard.disabled': 'Registered but disabled ({names}): the scheduled tasks will not fire, so nothing recovers protection after a reboot or a force-kill. Press "Re-install watchdog" to register them again, enabled.',
    'guard.missing': 'Not installed: nothing recovers protection after a reboot or a force-kill.',
    'guard.unknown': 'Unknown: the scheduled tasks cannot be read',
    'guard.headTask': 'Task',
    'guard.headState': 'State / last / next / last result',
    'guard.tasks': 'Scheduled tasks',
    'guard.notInstalled': 'Not installed',
    'guard.row': '{state} · last {last} · next {next} · result {result}',
    'guard.toastInstalled': 'Watchdog installed: starts at logon and reconciles against intent.json every 10 minutes. No administrator rights needed.',
    'guard.toastUninstalled': 'Watchdog removed: protection will not be started again after a reboot.',
    'guard.fail': '{op} failed: {msg}',
    'verb.install': 'Install',
    'verb.uninstall': 'Uninstall',
    'recon.title': 'Reconciliation rules',
    'recon.1head': 'intent=awake and not expired',
    'recon.1body': 'and there is no worker → start one and restore the remaining time.',
    'recon.2head': 'intent=off',
    'recon.2body': '→ the watchdog does nothing. After you stop protection by hand it will not turn back on what you switched off.',
    'recon.3head': 'Timed protection expired',
    'recon.3body': '→ considered settled, it will not be resurrected (expiry is not a fault).',
    'recon.4head': 'Settings are not written to intent',
    'recon.4body': '→ after a restart it starts from config.json. To make a set of values permanent, press Save as default.',

    /* 05 log */
    'panel.log.title': 'Run log',
    'panel.log.desc': 'Starts, heartbeats, downgrades, recoveries and exit reasons all land here. When debugging from a distance the log on this machine is of little use — but it does explain why the last attempt failed.',
    'btn.log': 'Refresh log',
    'check.autoLog': 'Follow automatically',
    'log.aria': 'Run log',
    'log.empty': '(no log lines yet)',
    'log.note': 'The log rotates itself at logMaxKb (over the limit it is truncated, keeping the later half).',
    'btn.stopServer': 'Close panel process',
    'btn.stopServerTip': 'Closes only the panel process; protection keeps running',
    'confirm.stopServer': 'This closes only the panel process (protection itself keeps running). Continue?',
    'gone.title': 'The panel process has exited',
    'gone.detail': 'Protection is still running. To look at the panel again, run panel.bat or ka.ps1 serve.',

    /* 06 limits */
    'panel.limits.title': 'Limits of what it does',
    'panel.limits.desc': 'This section is about what it cannot do. The most common failure of a keep-awake tool is making people believe it can do anything.',
    'panel.limits.hint': 'Compiled against the published behaviour of PowerToys Awake, Caffeine and mouse jigglers',
    'limits.can': 'It holds off',
    'limits.cant': 'It cannot hold off',
    'limits.verify': 'How to verify',
    'limits.can.1a': 'System sleep / Modern Standby entered while idle (',
    'limits.can.2a': 'The display blanking while idle (',
    'punct.close': ')',
    'limits.can.3': 'The idle lock timer and password-protected screen savers (the heartbeat resets the idle timer)',
    'limits.can.4': 'OEM power management stealing the request mid-run (asked for again on the Re-assert interval)',
    'limits.can.5': 'Automatic recovery after a reboot, a crash or a force-kill (the scheduled watchdog)',
    'limits.cant.1body': ', Start → Power → Lock: an explicit action, and no tool should intercept it',
    'limits.cant.2head': 'Closing the lid',
    'limits.cant.2body': ': sensor-driven, unless the lid action itself is changed',
    'limits.cant.3a': 'Heartbeat input ',
    'limits.cant.3b': 'cannot cross the lock screen',
    'limits.cant.3c': ': once the session is locked the input never reaches it, it only paints the lock screen',
    'limits.cant.4': 'Forced maintenance windows from group policy, low-battery protection, platform-forced standby',
    'limits.cant.5': 'Dynamic lock (phone Bluetooth) and third-party security tools locking on their own — invisible from this machine',
    /* a trailing space inside a value is deliberate: these fragments are spliced into
       text nodes that sit flush against a <b> or a <span class="mono"> command, and
       Chinese punctuation needs no gap where English does */
    'limits.verify.1a': 'Start protection → leave the machine idle for 10 minutes → look at',
    'limits.verify.1b': 'for the count of Entered sleep',
    'limits.verify.2a': 'Lid test: ',
    'limits.verify.2b': '(it makes its own backup, ',
    'limits.verify.2c': 'to undo it)',
    'limits.verify.3a': 'What is actually doing it: ',
    'limits.verify.3b': 'for the similar-software line',
    'limits.verify.4a': 'Standby, or only a blank screen? ',
    'limits.verify.4b': 'the two have different causes',

    /* footer + shared */
    'foot.right': 'Every request goes to 127.0.0.1 only · the panel sends no cross-origin permission, so external pages cannot drive it',
    'foot.info': 'root {root} · session {session} · {priv} · panel clock {clock}',
    'foot.elevated': 'elevated token',
    'foot.user': 'normal user token (enough)',
    'docTitle.running': '● Protection running · {name}',
    'docTitle.idle': '○ Not running · {name}',
    'docTitle.gone': 'Panel exited · {name}',
    'state.running': 'Protection running · pid {pid}',
    'state.notRunning': 'Not running',
    'state.detail': 'The system will not idle into sleep; {disp} Closing this page does not affect it.',
    'state.detailDisplayOn': 'The display stays lit.',
    'state.detailDisplayOff': 'The display may still blank per the power plan.',
    'state.detailExpired': 'The last timed protection expired and released itself (not a fault).',
    'state.detailIdle': 'The PC sleeps and blanks according to the system power plan, and the lock timer keeps running.',
    'state.unrecorded': 'A worker is running (pid {pid}) with no state record',
    'state.detailUnrecorded': 'The power request most likely still holds - only the record could not be written. Check that the data directory is writable (default %LOCALAPPDATA%\\KeepAwake).',
    'state.unrecordedSub': 'record not written',
    'state.unrecordedEfficacySub': 'Nothing to check against: the state record was not written, so the protected window cannot be rebuilt',
    'state.since': 'since {at}',
    'state.pulseSub': 'every {sec}s · {method}',
    'state.pulseSubOff': 'Engine 2 not enabled',
    'state.pulseNone': 'No heartbeat',
    'state.elapsedNone': 'No worker is running',
    'state.efficacyOk': 'Working',
    'state.efficacySleeps': '{n} sleeps',
    'state.efficacyBypass': '{n} bypassed',
    'state.efficacyUnproven': 'Cannot prove',
    'state.efficacySub': 'Kernel log for this run: low-power sessions {enters} · real sleeps {sleeps} · of which bypassed {bypass} · woke {exits}',
    'state.efficacySubS3': 'Kernel-Power 42 entries {n} · {exits} resumes',
    'state.efficacySubBlind': 'Readout: {name}',
    'state.efficacySubIdle': 'Nothing to measure while it is not running — see the history window in 02',
    'state.evFailed': 'Event log query failed',
    'state.idleSub': 'Since the last real keyboard or mouse input · a heartbeat is not real input',
    'state.noPanel': 'The panel process cannot be reached',
    'state.battAc': 'AC · {p}',
    'state.battDc': 'Battery · {p}',
    'state.battUnknown': 'Power state unreadable (the native call failed) - cannot tell whether there is a battery',
    'state.battNone': 'No battery',
    'state.battNoneSub': 'Desktop or virtual machine - the battery floor and the low-charge downgrade do not apply',
    'state.battNoneOdd': 'Desktop or virtual machine, but the AC line reads disconnected (typical of virtual machines): treat the power advice with care',
    'state.battAcOk': 'Plugged in, protection will not downgrade for runtime',
    'state.battDcFloor': 'On battery · floor {floor}%',
    'state.battDcLow': 'On battery · below the {floor}% floor, display protection has downgraded',
    'pill.displayOn': 'Display on',
    'pill.displayDowngraded': 'Display on · downgraded on battery',
    'pill.systemOnly': 'System sleep only',
    'pill.heartbeat': 'heartbeat {method} @ {sec}s',
    'pill.heartbeatOff': 'heartbeat off',
    'pill.away': 'away mode ES_AWAYMODE',
    'pill.reassert': 're-assert {sec}s',
    'pill.lockSkips': '{n} lock skips',
    'pill.ilSkips': '{n} UIPI skips',
    'pill.note.lock-screen': 'Locked / secure desktop: the heartbeat cannot reach the session (the power request still holds)',
    'pill.note.il-mismatch': 'Foreground is a higher-integrity (elevated) process: the heartbeat input is dropped by UIPI (the power request still holds)',
    'pill.note.battery-floor': 'Battery {pct}% under the {floor}% floor: the display may now blank',
    'pill.error.settes-zero': 'Power request refused (returned 0, {why})',
    'pill.error.settes-throw': 'Power request call failed ({why})',
    'pill.drift': 'config.json differs from what is running ({keys}): this run uses the values above, after a restart config.json wins — press Save as default to make them permanent',
    'pill.idlePlan': 'Acts per the system power plan when idle',
    'pill.unrecorded': 'Record unwritable · engine readings missing',
    'pill.standby': 'Standby config: heartbeat {method} @ {sec}s',
    'pill.competitors': 'Similar software detected: {list}',
    'alert.foreignWorkers': '{count} worker(s) belong to another folder ({roots}); this tool cannot stop them - the machine stays awake after you stop this one',
    'alert.batteryFloor': 'On battery at {pct}%: display protection stepped down as configured',
    'alert.sleepEvidence': 'While protection ran, {n} real sleep(s) happened with the power request held - the platform bypassed it at those moments',
    'alert.evidenceBlind': 'At least one sleep state this machine declares leaves no record this tool reads - green on the panel means nothing was logged, not that it did not sleep; what this machine does leave readable is written in the evidence section',
    'alert.multiWorker': '{count} worker processes detected; there should be exactly 1',
    'alert.standbyLid': 'Of those, {count} came from the lid - closing the lid bypasses power requests and Windows asks for sign-in on wake; keep the lid open for unattended remote access, but that is necessary and not sufficient - most standbys on this box are idle timeouts with the lid open, and that half is what this tool can hold. Or run ka.bat lid apply to set the lid action to "do nothing" (verify it with a real lid close - some platforms accept the write and still enter standby)',
    'alert.sessionLocked': 'The session is on the lock screen / secure desktop right now: the power request still holds and the machine stays up, but a remote client only sees the lock screen ({count} heartbeats skipped)',
    'alert.uipiBlocked': 'The heartbeat input is being dropped by UIPI: the foreground app runs at higher integrity (elevated), so the idle lock-screen timer cannot be reset (the power request still holds - the machine does not sleep). Either close that elevated app or re-run this tool elevated - {count} pulses skipped, and the next successful pulse clears this',
    'alert.staleState': 'The worker stopped reporting state - protection may no longer be held',
    'alert.dataDirUnwritable': 'The data directory {path} is not writable ({error}): state, intent and the stop signal cannot be recorded, so the panel shows a running protection as stopped',
    'alert.machineDirUnwritable': 'The machine data directory {path} is not writable ({error}): the lid backup and machine-level state cannot be saved',
    'alert.stateUnrecorded': '{count} worker(s) are running but {path} cannot be read - the power request still holds, only the record is missing (the protection is real, just invisible)',
    'alert.guardDisabled': 'The watchdog scheduled tasks are disabled ({names}): they will not fire, so nothing brings protection back after a reboot or a force-killed worker. Press "Re-install watchdog" to register them again.',
    'competitor.powerToys': 'PowerToys (may include the Awake module)',
    'competitor.presentation': 'Windows presentation mode (presentationsettings)',
    'competitor.confirm': 'powercfg /requests (run it elevated)',
    'common.unreadable': 'Unreadable',
    'common.now': 'now',
    'common.never': 'Never',
    'common.none': 'None',
    'common.unknown': 'Unknown',
    'common.unlimited': 'No limit',
    'common.yes': 'yes',
    'common.no': 'no',
    'common.supported': 'supported',
    'common.unsupported': 'not supported',
    'common.listSep': ', ',
    'dur.sec': '{n}s',
    'dur.h': 'h',
    'dur.m': 'm',
    'dur.min': 'min',
    'dur.d': 'd ',
    'api.notJson': 'response is not JSON (HTTP {status})',
    'api.http': 'HTTP {status}',
    'err.render': 'UI render failed: {msg}',
    'refresh.done': 'Refreshed: the controls are back to the values in config.json.',
    'save.done': 'Written to config.json. The running worker is left alone — but the watchdog and the values after a restart are now this set.',
    'save.fail': 'Write failed: {msg}',
    'start.restarted': 'worker restarted on the new settings',
    'start.already': 'Protection is already running (settings unchanged)',
    'start.started': 'Protection started',
    'start.unrecorded': 'Protection started, but its state could not be recorded',
    'start.summary': '{head} · pid {pid} · {disp} · {hb} · {dur}{clamp}',
    'start.dispOff': 'sleep blocked only',
    'start.hb': '{method}@{sec}s',
    'start.hbOff': 'no heartbeat',
    'start.endsIn': 'ends in {dur}',
    'start.clamped': ' (some values were corrected to their bounds, see the controls)',
    'start.fail': 'Start failed: {msg}',
    'stop.done': 'Stopped {n} worker{forced}, the power request went with the process.',
    'stop.forced': ' ({n} ignored the cooperative exit, so their cleanup did not run)',
    'stop.uncoop': ', and the cooperative exit was unavailable (stop.flag could not be written) - the process was killed outright',
    'stop.fail': 'Stop failed: {msg}',

    /* first-visit guide */
    'guide.title': 'First time here? This panel does three things',
    'guide.p1': 'Start protection: pick a duration in "Control" and press "Start protection". You can close this page afterwards — protection lives in a separate worker process, not in this window.',
    'guide.p2': 'Verify it: the evidence under "Evidence" is read straight from the kernel power log, counting "the screen only went dark" apart from "it really slept". The software saying it never slept is not evidence.',
    'guide.p3': 'Leave it alone: the watchdog under "Unattended" is a scheduled task — it starts at login and reconciles intent every 10 minutes.',
    'guide.dismiss': 'Got it, do not show again',

    /* explainers */
    'help.aria': 'Show explanation',
    'help.ev.label': 'What do these verdicts mean?',
    'help.ev.body': 'Every verdict is attributed against the kernel power log: "bypassed" = a power request was held and the machine slept anyway — the only hard proof the platform ignored it; "slept without a held request" = it slept, but nobody asked it to stay awake at that moment, so protection is not to blame; "cannot tell" = earlier than the retained log covers — no self-acquittal, no blame either; "screen off only" = the display went dark but the system never left, and 506 events count these too, which is why the raw 506 number is not the verdict. The filters below are a lens only; they change none of the numbers above.',
    'help.dais.label': 'What are these readouts?',
    'help.dais.body': 'Heartbeats = anti-lock actions the worker actually sent; Idle = the system-reported time without input, which a working heartbeat keeps pushing back; Efficacy = the verdict for this window, drawn from the same evidence as the Evidence panel.',
    'help.report.label': 'Where do these risks come from?',
    'help.report.body': 'Each row is read live from powercfg / registry / system capabilities, never cached. Red rows genuinely break unattended runs (lid-close sleep cannot be stopped by any software); yellow rows deserve care but do not always bite. The recommended heartbeat interval is derived from the shortest lock timer on this machine, not a generic number.',

    /* preview before start */
    'preview.title': 'Confirm before starting',
    'preview.note': 'Change the controls before confirming and this preview updates live; the power request is only sent when you confirm.',
    'preview.dur': 'Duration',
    'preview.ends': 'released automatically at {at}',
    'preview.unlimited': 'No limit · until stopped by hand',
    'preview.flags': 'Power request about to be sent',
    'preview.flagsHint': 'SetThreadExecutionState(ES_CONTINUOUS | flags below)',
    'preview.flag.system': 'keeps the system from sleeping',
    'preview.flag.display': 'keeps the display on',
    'preview.flag.away': 'allows away mode (display may go dark, system stays)',
    'preview.flag.continuous': 'stays in effect until the process exits',
    'preview.hb': 'Anti-lock heartbeat',
    'preview.hbOn': '{method} every {sec}s',
    'preview.hbOff': 'none · power request only',
    'preview.away': 'Away mode',
    'preview.awayOn': 'on · display may go dark, system stays',
    'preview.awayOff': 'off',
    'preview.battery': 'Battery behaviour',
    'preview.battAllow': 'below {floor}% battery the display may step down to off (sleep stays blocked)',
    'preview.battKeep': 'display stays on even on battery (until {floor}%)',
    'preview.risks': 'Risks that apply on this machine',
    'preview.noRisks': 'none',
    'preview.confirm': 'Confirm and start',
    'preview.cancel': 'Back to editing',

    /* evidence filter */
    'evf.aria': 'Evidence filters',
    'evf.all': 'All',
    'evf.sleep': 'Real sleeps',
    'evf.screenOff': 'Screen-off only',
    'evf.lid': 'Lid closed',
    'evf.bypass': 'Bypassed',
    'evf.out': 'No request held',
    'evf.search': 'Search: reason / lid / id…',
    'evf.hits': '{hit}/{total} shown',
    'evf.empty': 'No events match this filter',
    'evf.lens': 'Filters are a lens only — the verdict and counts above still cover the whole window'
  };

  /* --------------------------------------------------------------- internals */

  var current = 'zh';

  function lookup(lang1, key) {
    var d = dict[lang1];
    if (d && typeof d[key] === 'string') return d[key];
    if (typeof key === 'string' && dict.zh && typeof dict.zh[key] === 'string') return dict.zh[key];
    return null;
  }

  /*
    {name} only. An unknown placeholder is left exactly as written: a hole in `vars`
    should read as {pid} on screen, not as the empty string that hides the fact.
  */
  function fill(str, vars) {
    if (typeof str !== 'string' || str.indexOf('{') < 0) return str;
    var src = (vars && typeof vars === 'object') ? vars : {};
    return str.replace(/\{([^\s{}]+)\}/g, function (whole, name) {
      var v = src[name];
      return (v === undefined || v === null) ? whole : String(v);
    });
  }

  function t(key, vars) {
    var raw = lookup(current, key);
    if (raw === null) raw = (typeof key === 'string' && key) ? key : '';
    return fill(raw, vars);
  }

  /*
    Whether wording exists for this key at all. Values the worker sends as machine
    tokens (note=lock-screen) go through this: an unknown token is better shown raw
    than shown as a dictionary key.
  */
  function has(key) {
    return lookup(current, key) !== null;
  }

  /*
    textContent is only safe on a leaf: writing it into <h4>Title <small>x</small></h4>
    would delete the <small>. For a container the translation goes into its own first
    non-blank text node and the rest are emptied, keeping each node's original leading
    and trailing spaces so " label <small>hint</small>" still reads the same.
  */
  function writeInto(el, str) {
    if (el.children.length === 0) { el.textContent = str; return; }
    var nodes = [];
    for (var n = el.firstChild; n; n = n.nextSibling) {
      if (n.nodeType === 3 && /\S/.test(n.nodeValue)) nodes.push(n);
    }
    if (!nodes.length) { el.insertBefore(el.ownerDocument.createTextNode(str), el.firstChild); return; }
    setNodeText(nodes[0], str);
    for (var i = 1; i < nodes.length; i++) nodes[i].nodeValue = '';
  }

  function setNodeText(node, str) {
    var lead = /^\s*/.exec(node.nodeValue)[0];
    var trail = /\s*$/.exec(node.nodeValue)[0];
    node.nodeValue = lead + str + trail;
  }

  function scan(root, selector, fn) {
    var list = root.querySelectorAll(selector);
    for (var i = 0; i < list.length; i++) fn(list[i]);
  }

  function apply(root) {
    var scope = root || (typeof document === 'undefined' ? null : document);
    if (!scope || typeof scope.querySelectorAll !== 'function') return;
    scan(scope, '[data-i18n]', function (el) {
      writeInto(el, t(el.getAttribute('data-i18n')));
    });
    scan(scope, '[data-i18n-title]', function (el) {
      el.setAttribute('title', t(el.getAttribute('data-i18n-title')));
    });
    scan(scope, '[data-i18n-placeholder]', function (el) {
      el.setAttribute('placeholder', t(el.getAttribute('data-i18n-placeholder')));
    });
    scan(scope, '[data-i18n-aria]', function (el) {
      el.setAttribute('aria-label', t(el.getAttribute('data-i18n-aria')));
    });
  }

  function markSwitcher() {
    if (typeof document === 'undefined') return;
    var seg = document.getElementById('langSeg');
    if (!seg) return;
    scan(seg, '[data-lang]', function (b) {
      b.classList.toggle('is-on', b.getAttribute('data-lang') === current);
    });
  }

  function set(lang) {
    if (lang !== 'zh' && lang !== 'en') return current;
    current = lang;
    KA.lang = lang;
    apply(typeof document === 'undefined' ? null : document);
    if (typeof document !== 'undefined' && document.documentElement) {
      document.documentElement.lang = (lang === 'zh') ? 'zh-CN' : 'en';
    }
    markSwitcher();
    if (typeof document !== 'undefined' && typeof CustomEvent === 'function') {
      document.dispatchEvent(new CustomEvent('ka-lang', { detail: { lang: lang } }));
    }
    return lang;
  }

  function detect() {
    var name = '';
    try { name = (typeof navigator === 'undefined' ? '' : String(navigator.language || '')); } catch (e) { name = ''; }
    return name.toLowerCase().indexOf('zh') === 0 ? 'zh' : 'en';
  }

  /* zh first so an English machine still falls back to the authored wording
     whenever a key is missing from `en` - see t(). */
  var dict = { zh: zh, en: en };

  var KA = {
    lang: 'zh',
    dict: dict,
    t: t,
    has: has,
    apply: apply,
    set: set,
    detect: detect
  };

  if (typeof window !== 'undefined') window.KA = KA;
  if (typeof module !== 'undefined' && module.exports) module.exports = KA;   // tests only
}());
