using System;
using System.Collections.Generic;
using System.Drawing;
using System.Windows.Forms;

namespace KeepAwakeDesktop
{
    // Product pages own layout; engine state and commands live in DesktopForm's controller.
    partial class DesktopForm
    {
        int PageWidth { get { return Math.Max(480, (int)(content.ClientSize.Width / uiScale) - 48); } }
        Label timerCaption;
        DawnIllustration dawnIllustration;
        bool timerFinished;
        Pill statusDetails, activityLog, activityReport;
        Pill pauseProtection;
        Panel activityFeed;
        int activityMode;
        bool activityLoaded;
        string logText = "", reportText = "", statusDetailText = "";
        bool preferencesDirty;
        Pill aboutNavigation, taskNavigation;

        void BuildNavigation()
        {
            while (sidebar.Controls.Count > 0) sidebar.Controls[0].Dispose(); navigation.Clear();
            noticeDetails.Text = T("详情", "Details"); noticeRetry.Text = T("重试", "Retry");
            if (noticeIsError) noticeText.Text = T("操作未完成", "The operation could not be completed");
            var logo = new PictureBox { Image = Artwork.Brand, SizeMode = PictureBoxSizeMode.Zoom, BackColor = Color.Transparent };
            logo.SetBounds(20, 27, 36, 36); sidebar.Controls.Add(logo);
            LabelAt(sidebar, "KeepAwake", 64, 28, 128, 33, 11, Ink);
            string[] labels = { T("保持唤醒", "Keep awake"), T("设置", "Settings"), T("活动", "Activity") };
            string[] glyphs = { "home", "settings", "activity" };
            for (int i = 0; i < labels.Length; i++)
            {
                int page = i;
                var button = ButtonAt(sidebar, labels[i], 12, 112 + i * 58, 176, 46, async delegate
                {
                    BuildPage(page);
                    if (page == 2 && !activityLoaded) await Execute("log", null, false);
                });
                button.Glyph = glyphs[i]; button.GlyphSize = (int)(25 * uiScale); button.AlignLeft = true;
                button.Fill = Background; button.Ink = Ink; navigation.Add(button);
            }
            taskNavigation = ButtonAt(sidebar, T("任务", "Tasks"), 12, 286, 176, 46, delegate { ShowTasks(); });
            taskNavigation.Glyph = "activity"; taskNavigation.GlyphSize = (int)(25 * uiScale);
            taskNavigation.AlignLeft = true; taskNavigation.Fill = Background; taskNavigation.Ink = Ink;
            var rules = ButtonAt(sidebar, T("自动保护", "Automation"), 12, 344, 176, 46, delegate { ShowAutomation(); });
            rules.Glyph = "timer"; rules.GlyphSize = (int)(25 * uiScale); rules.AlignLeft = true; rules.Fill = Background; rules.Ink = Ink;
            aboutNavigation = ButtonAt(sidebar, T("关于", "About"), 12, 620, 176, 42, delegate { BuildPage(3); });
            aboutNavigation.Glyph = "shield"; aboutNavigation.GlyphSize = (int)(23 * uiScale); aboutNavigation.AlignLeft = true;
            aboutNavigation.Fill = Background; aboutNavigation.Ink = Muted;
            foreach (Control child in sidebar.Controls) child.Scale(new SizeF(uiScale, uiScale));
            LayoutSidebar();
        }
        void LayoutSidebar() { if (aboutNavigation != null) aboutNavigation.Top = sidebar.Height - (int)(66 * uiScale); }
        void PageTitle(string title)
        { LabelAt(content, title, 24, 25, Math.Min(320, PageWidth - 220), 46, 22, Ink); }
        void BuildPage(int page)
        {
            currentPage = page;
            foreach (var b in navigation) { b.Selected = navigation.IndexOf(b) == page; b.Invalidate(); }
            if (aboutNavigation != null) { aboutNavigation.Selected = page == 3; aboutNavigation.Invalidate(); }
            if (initialized) config = Draft();
            foreach (Control persistent in new Control[] { status, elapsed, remaining, power })
                if (persistent.Parent != null) persistent.Parent.Controls.Remove(persistent);
            while (content.Controls.Count > 0) content.Controls[0].Dispose();
            display = null; antiLock = null; closeToTray = null; autoStart = null; hotkey = null; method = null; language = null;
            interval = null; floor = null; custom = null; records = null; save = null; durationSummary = null;
            emptyActivity = null; copyRecords = null; activityFeed = null; activityLog = null; activityReport = null;
            timerCaption = null; statusDetails = null; dawnIllustration = null; pauseProtection = null;
            durations.Clear(); scenarios.Clear();
            content.AutoScrollPosition = Point.Empty; content.AutoScrollMinSize = Size.Empty;
            actionBar.Visible = page == 0;
            if (page == 0) BuildHome(); else if (page == 1) BuildSettings(); else if (page == 2) BuildActivity(); else BuildAbout();
            foreach (Control child in content.Controls) child.Scale(new SizeF(uiScale, uiScale));
            RenderState(); SetBusyControls(); LayoutNotice();
        }
        void BuildHome()
        {
            int width = PageWidth;
            PageTitle(T("保持唤醒", "Keep awake"));
            PutLabel(content, status, T("连接中", "Connecting"), width - 104, 36, 126, 30, 10, Muted); status.TextAlign = ContentAlignment.MiddleRight;
            statusDetails = ButtonAt(content, T("详情", "Details"), width - 196, 31, 82, 36, delegate { ShowDetails(T("保护状态", "Protection status"), statusDetailText); });
            statusDetails.Visible = false;
            var session = new DawnCard { Radius = (int)(22 * uiScale) }; session.SetBounds(24, 92, width, 164); content.Controls.Add(session);
            var clockIcon = new GlyphView { IconName = "timer", Ink = Blue, BackColor = Color.Transparent }; clockIcon.SetBounds(25, 40, 48, 48); session.Controls.Add(clockIcon);
            timerCaption = LabelAt(session, "", 100, 23, 280, 24, 9, Muted);
            PutLabel(session, remaining, "", 97, 51, Math.Max(192, width - (width < 660 ? 280 : 500)), 49, 25, Ink);
            PutLabel(session, elapsed, "", width - 358, 42, 138, 62, 10, Muted);
            PutLabel(session, power, "", 100, 114, width - 260, 30, 9, Muted);
            dawnIllustration = new DawnIllustration(); dawnIllustration.SetBounds(width - 224, 0, 224, 164); session.Controls.Add(dawnIllustration);
            if (width < 660) { dawnIllustration.SetBounds(width - 174, 0, 174, 164); }

            LabelAt(content, T("场景", "Scenario"), 27, 277, 420, 30, 13, Ink);
            string[] names = { T("日常工作", "Focus"), T("演示投屏", "Presentation"), T("长任务", "Long task") };
            string[] descriptions = { T("专注与阅读", "Work and reading"), T("会议与分享", "Meetings and sharing"), T("允许屏幕熄灭", "Screen can turn off") };
            string[] icons = { "focus", "present", "download" };
            Color[] accents = { Blue, Color.FromArgb(49, 102, 189), Color.FromArgb(168, 102, 18) };
            Color[] surfaces = { Color.FromArgb(218, 241, 227), Color.FromArgb(227, 236, 254), Color.FromArgb(255, 242, 211) };
            int tileWidth = (width - 24) / 3;
            for (int i = 0; i < names.Length; i++)
            {
                int preset = i;
                var b = new ScenarioTile { Text = names[i], Description = descriptions[i], ScenarioIndex = i, IconName = icons[i], Accent = accents[i], Surface = surfaces[i], IconScale = uiScale, Font = Font, Selected = i == selectedScenario };
                b.SetBounds(24 + i * (tileWidth + 12), 314, tileWidth, 132); b.Click += delegate { SetScenario(preset); }; content.Controls.Add(b); scenarios.Add(b);
            }
            LabelAt(content, T("时长", "Duration"), 27, 461, 230, 30, 13, Ink);
            durationSummary = LabelAt(content, "", width - 270, 464, 292, 25, 9, Muted); durationSummary.TextAlign = ContentAlignment.MiddleRight;
            double[] mins = { 30, 60, 120, 0, -1 };
            string[] titles = { T("30 分钟", "30 min"), T("1 小时", "1 hour"), T("2 小时", "2 hours"), T("直到停止", "Until stopped"), T("自定义", "Custom") };
            int durationWidth = (width - 32) / 5;
            for (int i = 0; i < mins.Length; i++)
            {
                double m = mins[i]; var b = ButtonAt(content, titles[i], 24 + i * (durationWidth + 8), 501, durationWidth, 40, delegate
                {
                    if (m == -1 && !ShowDurationDialog()) return;
                    timerFinished = false; SelectDuration(m); durationTouched = true; dirty = true; UpdatePrimary();
                }); b.Tag = m; durations.Add(b);
            }
            var options = CardAt(561, 86, Color.White);
            display = new SwitchOption { Text = T("屏幕常亮", "Keep screen on"), Glyph = "monitor", IconScale = uiScale, Checked = !initialized || Value.Bool(config, "keepDisplayOn") };
            antiLock = new SwitchOption { Text = T("防止自动锁屏", "Prevent idle lock"), Glyph = "lock", IconScale = uiScale, Checked = !initialized || Value.Bool(config, "antiLock") };
            display.SetBounds(25, 26, (width - 90) / 2, 34); antiLock.SetBounds(width / 2 + 16, 26, (width - 90) / 2, 34);
            display.CheckedChanged += DraftChanged; antiLock.CheckedChanged += DraftChanged;
            options.Controls.Add(display); options.Controls.Add(antiLock);
            tips.SetToolTip(antiLock, T("通过输入心跳防止空闲锁屏；企业策略和手动锁屏仍然有效。", "Uses an input heartbeat. Device policy and manual locking still apply."));
            var taskButton = ButtonAt(content, T("任务", "Tasks"), 24, 662, 145, 42, delegate { ShowTasks(); });
            taskButton.Glyph = "activity"; taskButton.GlyphSize = (int)(22 * uiScale);
            pauseProtection = ButtonAt(content, T("暂停 15 分钟", "Pause for 15 min"), 177, 662, 162, 42, async delegate {
                await Execute(IsPaused() ? "resume" : "pause", null, true);
            });
            var diagnostic = ButtonAt(content, T("导出诊断", "Export diagnostics"), 347, 662, 157, 42, async delegate { await Execute("diagnostic", null, true); });
            diagnostic.Glyph = "download"; diagnostic.GlyphSize = (int)(22 * uiScale);
            content.AutoScrollMinSize = new Size(0, (int)(720 * uiScale));
            BuildActionBar(width); SelectDuration(selectedMinutes);
        }
        void BuildActionBar(int width)
        {
            actionBar.Controls.Clear();
            PutLabel(actionBar, subtitle, "", 28, 26, Math.Max(60, width - 398), 36, 10, Muted); subtitle.AutoEllipsis = true; subtitle.TextAlign = ContentAlignment.MiddleLeft;
            primary.SetBounds(width - 172, 20, 196, 46); primary.Font = new Font(Font.FontFamily, 10F);
            primary.Fill = Blue; primary.Ink = Color.White; primary.GlyphSize = (int)(23 * uiScale);
            primary.Click -= PrimaryClick; primary.Click += PrimaryClick; actionBar.Controls.Add(primary);
            applySession.SetBounds(width - 356, 20, 170, 46); applySession.Text = T("应用更改", "Apply changes");
            applySession.Glyph = "check"; applySession.GlyphSize = (int)(22 * uiScale); applySession.Click -= ApplyClick; applySession.Click += ApplyClick; actionBar.Controls.Add(applySession);
            foreach (Control child in actionBar.Controls) child.Scale(new SizeF(uiScale, uiScale));
        }
        void BuildSettings()
        {
            int width = PageWidth;
            PageTitle(T("设置", "Settings"));
            save = ButtonAt(content, T("保存", "Save"), width - 104, 29, 128, 42, async delegate { await SavePreferences(); });
            save.Fill = Blue; save.Ink = Color.White; save.Glyph = "check"; save.GlyphSize = (int)(22 * uiScale);
            var general = CardAt(92, 312, Color.White);
            LabelAt(general, T("通用", "General"), 24, 17, width - 260, 30, 13, Ink);
            var art = new DawnIllustration { Scene = ProductScene.Settings }; art.SetBounds(width - 212, 0, 196, 106); general.Controls.Add(art);
            LabelAt(general, T("语言", "Language"), 26, 113, 280, 29, 10, Ink);
            language = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, FlatStyle = FlatStyle.Flat, Font = new Font(Font.FontFamily, 10F) };
            language.SetBounds(width - 294, 110, 268, 32); language.Items.AddRange(new object[] { T("跟随系统", "System default"), "简体中文", "English" });
            string draftLanguage = Value.Text(config, "language"); language.SelectedIndex = draftLanguage == "zh" ? 1 : draftLanguage == "en" ? 2 : 0; general.Controls.Add(language);
            closeToTray = new SwitchOption { Text = T("关闭窗口时收起到托盘", "Close to system tray"), Checked = Value.Get(config, "closeToTray") == null ? closePreference : Value.Bool(config, "closeToTray"), Glyph = "tray", IconScale = uiScale };
            closeToTray.SetBounds(26, 161, width - 52, 34); general.Controls.Add(closeToTray);
            tips.SetToolTip(closeToTray, T("关闭界面不会停止保护。", "Closing the interface does not stop protection."));
            autoStart = new SwitchOption { Text = T("登录后启动到托盘", "Start in tray at sign-in"), Checked = Value.Get(config, "autoStart") == null ? IsAutoStart() : Value.Bool(config, "autoStart"), Glyph = "tray", IconScale = uiScale };
            autoStart.SetBounds(26, 209, width - 52, 34); general.Controls.Add(autoStart);
            hotkey = new SwitchOption { Text = T("全局快捷键 Ctrl + Alt + K", "Global shortcut Ctrl + Alt + K"), Checked = Value.Get(config, "hotkeyEnabled") == null ? hotkeyPreference : Value.Bool(config, "hotkeyEnabled"), Glyph = "timer", IconScale = uiScale };
            hotkey.SetBounds(26, 257, width - 52, 34); general.Controls.Add(hotkey);
            var protection = CardAt(424, 242, Color.White);
            LabelAt(protection, T("保护", "Protection"), 24, 17, 380, 30, 13, Ink);
            LabelAt(protection, T("防锁屏方式", "Idle lock method"), 26, 65, 300, 29, 10, Ink);
            method = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, FlatStyle = FlatStyle.Flat, Font = new Font(Font.FontFamily, 10F) };
            method.SetBounds(width - 294, 62, 268, 32); method.Items.AddRange(new object[] { T("F15 按键", "F15 key"), T("鼠标心跳", "Mouse heartbeat") }); method.SelectedIndex = Value.Text(config, "antiLockMethod") == "mouse" ? 1 : 0; protection.Controls.Add(method);
            LabelAt(protection, T("心跳间隔", "Heartbeat interval"), 26, 121, width - 266, 29, 10, Ink);
            interval = new NumberField { Minimum = 10, Maximum = 3600, Value = Math.Max(10, Math.Min(3600, initialized ? Value.Number(config, "antiLockIntervalSec") : 240)), Unit = T("秒", "s"), Font = new Font(Font.FontFamily, 10F) };
            interval.SetBounds(width - 216, 111, 190, 44); protection.Controls.Add(interval);
            interval.AccessibleName = T("心跳间隔（秒）", "Heartbeat interval in seconds");
            LabelAt(protection, T("低电量允许熄屏", "Allow screen off below"), 26, 177, width - 266, 29, 10, Ink);
            floor = new NumberField { Minimum = 0, Maximum = 90, Value = Math.Max(0, Math.Min(90, initialized ? Value.Number(config, "batteryFloorPercent") : 20)), Unit = "%", Font = new Font(Font.FontFamily, 10F) };
            floor.SetBounds(width - 216, 167, 190, 44); protection.Controls.Add(floor);
            floor.AccessibleName = T("低电量阈值（百分比）", "Low battery threshold in percent");
            tips.SetToolTip(floor, T("使用电池时，低于此电量允许熄屏，后台任务继续。", "On battery, allow the display to turn off below this level. Background work continues."));
            method.SelectedIndexChanged += DraftChanged; interval.ValueChanged += DraftChanged; floor.ValueChanged += DraftChanged;
            language.SelectedIndexChanged += DraftChanged; closeToTray.CheckedChanged += DraftChanged;
            autoStart.CheckedChanged += DraftChanged; hotkey.CheckedChanged += DraftChanged;
            ButtonAt(content, T("电池策略…", "Battery policy…"), 24, 686, 210, 42, delegate { ShowSupplyPolicy(); });
            content.AutoScrollMinSize = new Size(0, (int)(754 * uiScale));
        }
        void BuildActivity()
        {
            int width = PageWidth;
            PageTitle(T("活动", "Activity"));
            copyRecords = ButtonAt(content, T("复制", "Copy"), width - 92, 29, 116, 42, delegate
            {
                string text = activityMode == 0 ? logText : reportText;
                if (!String.IsNullOrWhiteSpace(text)) { Clipboard.SetText(text); Notify(T("已复制", "Copied"), false); }
            }); copyRecords.Glyph = "copy"; copyRecords.GlyphSize = (int)(22 * uiScale);
            activityLog = ButtonAt(content, T("日志", "Log"), 24, 97, 132, 40, async delegate { activityMode = 0; await Execute("log", null, false); }); activityLog.Glyph = "activity"; activityLog.GlyphSize = (int)(23 * uiScale);
            activityReport = ButtonAt(content, T("诊断", "Diagnostics"), 168, 97, 145, 40, async delegate { activityMode = 1; await Execute("report", null, false); }); activityReport.Glyph = "shield"; activityReport.GlyphSize = (int)(23 * uiScale);
            var refresh = ButtonAt(content, T("刷新", "Refresh"), width - 88, 97, 112, 40, async delegate { await Execute(activityMode == 0 ? "log" : "report", null, false); }); refresh.Glyph = "refresh"; refresh.GlyphSize = (int)(23 * uiScale);
            int height = Math.Max(330, (int)(content.ClientSize.Height / uiScale) - 180);
            var panel = CardAt(157, height, Color.White);
            records = new TextBox { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, WordWrap = true, BorderStyle = BorderStyle.None, BackColor = Color.White, ForeColor = Ink, Font = new Font(Font.FontFamily, 10F) };
            records.SetBounds(22, 20, width - 44, height - 40); panel.Controls.Add(records);
            activityFeed = new Panel { BackColor = Color.White, AutoScroll = true }; activityFeed.SetBounds(16, 16, width - 32, height - 32); panel.Controls.Add(activityFeed);
            emptyActivity = new Card { Fill = Color.White, Radius = (int)(22 * uiScale) }; emptyActivity.SetBounds(0, 0, width, height); panel.Controls.Add(emptyActivity);
            var art = new DawnIllustration { Scene = ProductScene.Activity }; art.SetBounds((width - 192) / 2, height / 2 - 164, 192, 144); emptyActivity.Controls.Add(art);
            var title = LabelAt(emptyActivity, T("暂无活动", "No activity yet"), 24, height / 2 - 14, width - 48, 34, 14, Ink); title.TextAlign = ContentAlignment.MiddleCenter;
            var hint = LabelAt(emptyActivity, T("保护记录将在这里显示", "Your protection history appears here"), 24, height / 2 + 29, width - 48, 28, 10, Muted); hint.TextAlign = ContentAlignment.MiddleCenter;
            PresentActivity(false);
        }
        void PresentActivity(bool scaled)
        {
            if (records == null || activityFeed == null) return;
            activityEmpty = String.IsNullOrWhiteSpace(activityMode == 0 ? logText : reportText);
            records.Text = activityMode == 0 ? logText : reportText;
            records.Visible = activityMode == 1 && !activityEmpty;
            activityFeed.Visible = activityMode == 0 && !activityEmpty;
            emptyActivity.Visible = activityEmpty;
            activityLog.Selected = activityMode == 0; activityReport.Selected = activityMode == 1; activityLog.Invalidate(); activityReport.Invalidate();
            while (activityFeed.Controls.Count > 0) activityFeed.Controls[0].Dispose();
            float factor = scaled ? uiScale : 1F;
            int rowWidth = scaled ? (int)(activityFeed.ClientSize.Width / uiScale) - 20 : activityFeed.Width - 20;
            var entries = ActivityEvent.Parse(logText, english);
            for (int i = 0; i < entries.Count; i++)
            {
                var row = new ActivityRow { Entry = entries[i], Font = Font, IconScale = uiScale, BackColor = Color.White };
                row.SetBounds(0, i * 80, rowWidth, 80); activityFeed.Controls.Add(row);
                if (factor != 1) row.Scale(new SizeF(factor, factor));
            }
            if (copyRecords != null) copyRecords.Enabled = !activityEmpty && !commandBusy && !commandQueued;
        }
        void BuildAbout()
        {
            int width = PageWidth;
            PageTitle(T("关于", "About"));
            var product = CardAt(92, 156, Color.White);
            var logo = new PictureBox { Image = Artwork.Brand, SizeMode = PictureBoxSizeMode.Zoom, BackColor = Color.White }; logo.SetBounds(24, 28, 88, 88); product.Controls.Add(logo);
            LabelAt(product, "KeepAwake", 135, 35, width - 310, 38, 19, Ink);
            LabelAt(product, T("版本 ", "Version ") + Value.Text(state, "version"), 138, 84, width - 313, 26, 10, Muted);
            var aboutArt = new DawnIllustration { Scene = ProductScene.About }; aboutArt.SetBounds(width - 176, 0, 160, 156); product.Controls.Add(aboutArt);
            var privacy = CardAt(270, 190, Color.White);
            LabelAt(privacy, T("数据与隐私", "Data and privacy"), 24, 18, width - 48, 30, 13, Ink);
            LabelAt(privacy, T("桌面版无遥测或自动更新。可选 MCP 客户端可能将收到的信息发送给 AI 服务。", "No desktop telemetry or automatic updates. An optional MCP client may send received information to an AI service."), 26, 63, width - 52, 56, 10, Muted);
            var path = new TextBox { ReadOnly = true, BorderStyle = BorderStyle.None, BackColor = Color.White, ForeColor = Muted, Text = Program.DataRoot, Font = Font }; path.SetBounds(26, 131, width - 175, 28); privacy.Controls.Add(path);
            var copyPath = ButtonAt(privacy, T("复制路径", "Copy path"), width - 141, 123, 115, 38, delegate { Clipboard.SetText(Program.DataRoot); Notify(T("已复制", "Copied"), false); }); copyPath.Glyph = "copy"; copyPath.GlyphSize = (int)(21 * uiScale);
            var boundaries = CardAt(482, 104, Color.White);
            LabelAt(boundaries, T("使用说明", "Usage"), 24, 16, width - 48, 29, 13, Ink);
            LabelAt(boundaries, T("主动睡眠、合盖与企业策略仍由 Windows 管理。关闭界面不会停止保护。", "Windows still controls manual sleep, lid actions and device policy. Closing the interface keeps protection running."), 26, 55, width - 52, 40, 10, Muted);
            ButtonAt(content, T("许可与版权", "License and notices"), 24, 608, 210, 42, delegate {
                try { ShowDetails(T("许可与版权", "License and notices"), System.IO.File.ReadAllText(System.IO.Path.Combine(Program.EngineRoot, "LICENSE")) + "\r\n\r\n" + System.IO.File.ReadAllText(System.IO.Path.Combine(Program.EngineRoot, "NOTICE"))); }
                catch (Exception ex) { Notify(ex.Message, true); }
            });
            content.AutoScrollMinSize = new Size(0, (int)(674 * uiScale));
        }
    }
}
