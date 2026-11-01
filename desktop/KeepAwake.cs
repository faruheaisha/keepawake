using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace KeepAwakeDesktop
{
    static class Program
    {
        internal static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = 4000000 };
        internal static string DataRoot;
        internal static string EngineRoot;
        internal static uint ActivateMessage;
        internal static uint CloseMessage;
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern uint RegisterWindowMessage(string name);
        [DllImport("user32.dll")] static extern bool PostMessage(IntPtr handle, uint msg, IntPtr w, IntPtr l);
        [STAThread] static int Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            try
            {
                DataRoot = Path.GetFullPath(Environment.GetEnvironmentVariable("KA_DATA") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "KeepAwake"));
                string identity = WindowsIdentity.GetCurrent().User.Value + "|" + DataRoot.TrimEnd('\\').ToUpperInvariant();
                string key = Hash(Encoding.UTF8.GetBytes(identity));
                ActivateMessage = RegisterWindowMessage("KeepAwake.Desktop." + key);
                CloseMessage = RegisterWindowMessage("KeepAwake.Desktop.Close." + key);
                if (args.Length > 0 && args[0] == "--shutdown")
                {
                    PostMessage(new IntPtr(0xffff), CloseMessage, IntPtr.Zero, IntPtr.Zero);
                    using (var closing = new Mutex(false, "Local\\KA-Desktop-" + key))
                    {
                        bool released;
                        try { released = closing.WaitOne(20000); } catch (AbandonedMutexException) { released = true; }
                        if (!released) return 1;
                        closing.ReleaseMutex(); return 0;
                    }
                }
                bool test = args.Length > 0 && args[0] == "--self-test";
                if (test) {
                    Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
                    Application.ThreadException += delegate(object sender, ThreadExceptionEventArgs e) {
                        DesktopForm.TestExitCode = 1;
                        if (args.Length > 1) File.WriteAllText(args[1] + ".error.txt", e.Exception.ToString());
                        Application.ExitThread();
                    };
                }
                bool acquired;
                using (var instance = new Mutex(true, "Local\\KA-Desktop-" + key, out acquired))
                {
                    if (!acquired && !test) { PostMessage(new IntPtr(0xffff), ActivateMessage, IntPtr.Zero, IntPtr.Zero); return 0; }
                    try
                    {
                        EngineRoot = ExtractEngine();
                        using (var form = new DesktopForm(test, args.Length > 1 ? args[1] : null, Array.IndexOf(args, "--tray") >= 0)) Application.Run(form);
                        return DesktopForm.TestExitCode;
                    }
                    finally { if (acquired) instance.ReleaseMutex(); }
                }
            }
            catch (Exception ex)
            {
                if (args.Length > 0 && args[0] == "--self-test")
                {
                    if (args.Length > 1) File.WriteAllText(args[1] + ".error.txt", ex.ToString());
                    return 1;
                }
                MessageBox.Show(ex.Message, "KeepAwake", MessageBoxButtons.OK, MessageBoxIcon.Error); return 1;
            }
        }
        static string Hash(byte[] bytes)
        {
            using (var sha = SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", "").ToLowerInvariant();
        }
        static string ExtractEngine()
        {
            byte[] payload;
            using (var input = Assembly.GetExecutingAssembly().GetManifestResourceStream("KeepAwake.Payload"))
            using (var memory = new MemoryStream()) { input.CopyTo(memory); payload = memory.ToArray(); }
            string hash = Hash(payload);
            string root = Path.Combine(DataRoot, "app", hash);
            using (var extraction = new Mutex(false, "Local\\KA-Extract-" + Hash(Encoding.UTF8.GetBytes(root))))
            {
                try { if (!extraction.WaitOne(30000)) throw new IOException("Another instance is preparing the application. Try again shortly."); }
                catch (AbandonedMutexException) { }
                try
                {
                    Directory.CreateDirectory(root);
                    using (var zip = new ZipArchive(new MemoryStream(payload), ZipArchiveMode.Read))
                    foreach (var entry in zip.Entries)
                    {
                        string target = Path.GetFullPath(Path.Combine(root, entry.FullName));
                        if (!target.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) throw new IOException("Invalid application resource path.");
                        Directory.CreateDirectory(Path.GetDirectoryName(target));
                        using (var source = entry.Open())
                        using (var memory = new MemoryStream())
                        {
                            source.CopyTo(memory);
                            byte[] bytes = memory.ToArray();
                            if (File.Exists(target) && Hash(File.ReadAllBytes(target)) == Hash(bytes)) continue;
                            string temporary = target + "." + Guid.NewGuid().ToString("N") + ".tmp";
                            File.WriteAllBytes(temporary, bytes);
                            if (File.Exists(target)) File.Delete(target);
                            File.Move(temporary, target);
                        }
                    }
                }
                finally { extraction.ReleaseMutex(); }
            }
            return root;
        }
        internal static Task<Dictionary<string, object>> Call(string action, Dictionary<string, object> request)
        {
            return Task.Run(() =>
            {
                string script = Path.Combine(EngineRoot, "ka-desktop.ps1").Replace("'", "''");
                string body = Convert.ToBase64String(Encoding.UTF8.GetBytes(Json.Serialize(request ?? new Dictionary<string, object>())));
                string command = "& '" + script + "' -Action '" + action + "' -Request '" + body + "'";
                string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
                string system = Environment.Is64BitOperatingSystem && !Environment.Is64BitProcess ? "Sysnative" : "System32";
                var info = new ProcessStartInfo(Path.Combine(windows, system, "WindowsPowerShell", "v1.0", "powershell.exe"),
                    "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " + Convert.ToBase64String(Encoding.Unicode.GetBytes(command)));
                info.UseShellExecute = false;
                info.CreateNoWindow = true;
                info.RedirectStandardOutput = true;
                info.RedirectStandardError = true;
                info.StandardOutputEncoding = Encoding.UTF8;
                info.StandardErrorEncoding = Encoding.UTF8;
                info.EnvironmentVariables["KA_DATA"] = DataRoot;
                using (var process = Process.Start(info))
                {
                    Task<string> output = process.StandardOutput.ReadToEndAsync();
                    Task<string> error = process.StandardError.ReadToEndAsync();
                    if (!process.WaitForExit(60000)) { process.Kill(); throw new IOException("The operation timed out. Refresh the status before trying again."); }
                    if (!Task.WaitAll(new Task[] { output, error }, 5000))
                        throw new IOException("The engine did not close its response. Refresh the status before trying again.");
                    string text = output.Result.Trim();
                    Dictionary<string, object> response;
                    try { response = Json.Deserialize<Dictionary<string, object>>(text); }
                    catch { throw new IOException(String.IsNullOrWhiteSpace(error.Result + text) ? "No response from the engine." : (error.Result + text).Trim()); }
                    if (process.ExitCode != 0 || !Value.Bool(response, "ok")) throw new IOException(Value.Text(response, "error"));
                    return response;
                }
            });
        }
    }

    static class Value
    {
        internal static object Get(Dictionary<string, object> d, string key) { object v; return d != null && d.TryGetValue(key, out v) ? v : null; }
        internal static string Text(Dictionary<string, object> d, string key) { return Convert.ToString(Get(d, key), CultureInfo.InvariantCulture); }
        internal static bool Bool(Dictionary<string, object> d, string key) { return Get(d, key) != null && Convert.ToBoolean(Get(d, key), CultureInfo.InvariantCulture); }
        internal static long Number(Dictionary<string, object> d, string key) { return Get(d, key) == null ? 0 : Convert.ToInt64(Get(d, key), CultureInfo.InvariantCulture); }
        internal static Dictionary<string, object> Map(Dictionary<string, object> d, string key) { return Get(d, key) as Dictionary<string, object> ?? new Dictionary<string, object>(); }
    }
    partial class DesktopForm : Form
    {
        internal static int TestExitCode;
        static readonly Color Background = Color.FromArgb(250, 252, 250);
        static readonly Color Ink = Color.FromArgb(31, 31, 31);
        static readonly Color Muted = Color.FromArgb(95, 99, 104);
        static readonly Color Blue = Color.FromArgb(1, 135, 95);
        readonly bool selfTest;
        readonly string screenshot;
        readonly Panel sidebar = new Panel();
        readonly Panel content = new AtmospherePanel();
        readonly Panel workspace = new Panel();
        readonly Panel actionBar = new Panel();
        readonly Label status = new Label();
        readonly Label subtitle = new Label();
        readonly Label elapsed = new Label();
        readonly Label remaining = new Label();
        readonly Label power = new Label();
        readonly Pill primary = new Pill();
        readonly Pill applySession = new Pill();
        readonly List<Pill> durations = new List<Pill>();
        readonly List<Pill> scenarios = new List<Pill>();
        readonly List<Pill> navigation = new List<Pill>();
        readonly System.Windows.Forms.Timer poll = new System.Windows.Forms.Timer { Interval = 10000 };
        readonly System.Windows.Forms.Timer clock = new System.Windows.Forms.Timer { Interval = 1000 };
        readonly System.Windows.Forms.Timer layout = new System.Windows.Forms.Timer { Interval = 150 };
        readonly ToolTip tips = new ToolTip { AutoPopDelay = 12000 };
        NotifyIcon tray;
        CheckBox display, antiLock, closeToTray, autoStart, hotkey;
        ComboBox method, language;
        NumberField interval, floor, custom;
        DateTimeField until;
        RadioButton timedMinutes, timedUntil;
        TextBox records;
        bool activityEmpty = true;
        Card emptyActivity;
        Pill copyRecords;
        Pill save;
        Dictionary<string, object> state = new Dictionary<string, object>();
        Dictionary<string, object> config = new Dictionary<string, object>();
        bool busy, commandBusy, commandQueued, running, known, initialized, quit, dirty, balloonShown, english;
        bool closePreference = true;
        bool shutdownPending;
        bool lastOperationSucceeded;
        double selectedMinutes = 60;
        int selectedScenario;
        bool durationTouched;
        Label durationSummary;
        long startedEpoch, expiresEpoch, snapshotEpoch;
        readonly Stopwatch statusAge = new Stopwatch();
        string previousNotice;
        SessionDraft confirmedSession;
        int currentPage;
        string languagePreference = "auto";
        readonly float uiScale;
        string T(string zh, string en) { return english ? en : zh; }
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr handle, int command);

        internal DesktopForm(bool test, string image, bool startHidden)
        {
            selfTest = test; screenshot = image;
            if (selfTest) TestExitCode = 1;
            using (var graphics = CreateGraphics()) uiScale = Math.Max(1F, graphics.DpiX / 96F);
            english = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName != "zh";
            Text = "KeepAwake";
            Font = new Font("Microsoft YaHei UI", 9F);
            BackColor = Background; ForeColor = Ink;
            AutoScaleMode = AutoScaleMode.None;
            Rectangle screen = Screen.PrimaryScreen.WorkingArea;
            MinimumSize = new Size(Math.Min((int)(860 * uiScale), screen.Width - 32), Math.Min((int)(560 * uiScale), screen.Height - 48));
            ClientSize = new Size(Math.Min((int)(1060 * uiScale), screen.Width - 48), Math.Min((int)(760 * uiScale), screen.Height - 80));
            StartPosition = FormStartPosition.CenterScreen; KeyPreview = true;
            Icon = Artwork.AppIcon;
            sidebar.Dock = DockStyle.Left; sidebar.Width = (int)(205 * uiScale); sidebar.BackColor = Background;
            content.Dock = DockStyle.Fill; content.BackColor = Background; content.AutoScroll = true;
            workspace.Dock = DockStyle.Fill;
            actionBar.Dock = DockStyle.Bottom; actionBar.Height = (int)(88 * uiScale); actionBar.BackColor = Color.White;
            workspace.Controls.Add(content); workspace.Controls.Add(actionBar);
            Controls.Add(workspace); Controls.Add(sidebar);
            InitializeNotices();
            sidebar.Resize += delegate { LayoutSidebar(); };
            BuildNavigation(); BuildPage(0);
            CreateTray();
            Shown += async delegate
            {
                if (startHidden && !selfTest) Hide(); else ShowWindow(Handle, 9);
                if (selfTest)
                {
                    foreach (Control button in navigation) VerifyPaintBackground(button);
                    foreach (Control button in scenarios) VerifyPaintBackground(button);
                    foreach (Control button in durations) VerifyPaintBackground(button);
                    VerifyPaintBackground(display); VerifyPaintBackground(antiLock); VerifyPaintBackground(primary);
                    if (screenshot != null) SavePreview(screenshot + ".loading.png");
                }
                await Execute("state", null, false); if (selfTest) await TestUI();
            };
            poll.Tick += async delegate { if (!busy) await Execute(automationEnabled && !selfTest ? "automation-tick" : "state", null, false); };
            clock.Tick += delegate { UpdateClock(); };
            poll.Start(); clock.Start();
            Resize += delegate { if (initialized && WindowState != FormWindowState.Minimized) { layout.Stop(); layout.Start(); } };
            layout.Tick += delegate { layout.Stop(); if (busy) { layout.Start(); return; } if (initialized && WindowState != FormWindowState.Minimized) BuildPage(currentPage); };
            FormClosing += delegate(object sender, FormClosingEventArgs e)
            {
                if (selfTest && !quit) { e.Cancel = true; return; }
                if ((busy || commandQueued) && (quit || !closePreference) && !selfTest) { e.Cancel = true; quit = false; Notify(T("操作进行中", "An operation is in progress"), false); return; }
                if (!quit && !selfTest && closePreference) { e.Cancel = true; HideWindow(); }
            };
            FormClosed += delegate { ConfigureHotkey(false); poll.Dispose(); clock.Dispose(); layout.Dispose(); noticeTimer.Dispose(); tips.Dispose(); tray.Visible = false; tray.Dispose(); };
            KeyDown += async delegate(object sender, KeyEventArgs e)
            {
                if (e.Control && e.KeyCode == Keys.Enter) { e.SuppressKeyPress = true; if (known && (Value.Number(state, "workerCount") > 0 || IsPaused())) await Execute("stop", null, true); else await ToggleProtection(); }
                if (e.KeyCode == Keys.Escape) { e.SuppressKeyPress = true; HideWindow(); }
                if (e.KeyCode == Keys.F5) { e.SuppressKeyPress = true; await Execute("state", null, false); }
            };
        }
        void PutLabel(Control parent, Label label, string text, int x, int y, int width, int height, float size, Color color)
        {
            label.Text = text; label.SetBounds(x, y, width, height); label.Font = new Font(Font.FontFamily, size);
            label.ForeColor = color; label.BackColor = Color.Transparent; parent.Controls.Add(label);
        }
        Label LabelAt(Control p, string text, int x, int y, int w, int h, float size, Color color)
        { var l = new Label(); PutLabel(p, l, text, x, y, w, h, size, color); return l; }
        Pill ButtonAt(Control p, string text, int x, int y, int w, int h, EventHandler click)
        { var b = new Pill { Text = text, Font = Font }; b.SetBounds(x, y, w, h); b.Click += click; p.Controls.Add(b); return b; }
        Card CardAt(int y, int height, Color color)
        {
            var c = new Card { Fill = color, Radius = (int)(22 * uiScale) }; c.SetBounds(24, y, PageWidth, height);
            c.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right; content.Controls.Add(c); return c;
        }
        async void ApplyClick(object sender, EventArgs e) { if (known && !commandBusy && !commandQueued) await StartSession(); }
        void SetScenario(int preset)
        {
            timerFinished = false;
            display.Checked = preset != 2; antiLock.Checked = preset != 2;
            selectedScenario = preset;
            for (int i = 0; i < scenarios.Count; i++) { scenarios[i].Selected = i == preset; scenarios[i].Invalidate(); }
            if (!durationTouched) SelectDuration(preset == 2 ? 120 : 60);
            dirty = true; preferencesDirty = true; UpdatePrimary();
        }
        void SelectDuration(double minutes)
        {
            selectedMinutes = minutes;
            foreach (var b in durations) { b.Selected = (double)b.Tag == minutes; b.Invalidate(); }
            if (durationSummary != null) durationSummary.Text = minutes != -1 ? "" : customUntil != null ? customUntil : customMinutes + T(" 分钟", " minutes");
            UpdateClock(); UpdatePrimary();
        }
        bool ShowDurationDialog()
        {
            bool accepted;
            using (var dialog = new Form { Text = T("自定义时长", "Custom duration"), AutoScaleMode = AutoScaleMode.None, ClientSize = new Size((int)(460 * uiScale), (int)(344 * uiScale)), FormBorderStyle = FormBorderStyle.FixedDialog, StartPosition = FormStartPosition.CenterParent, MaximizeBox = false, MinimizeBox = false, Font = Font, BackColor = Background, Icon = Artwork.AppIcon })
            {
                var minutesCard = new Card { Radius = (int)(18 * uiScale) }; minutesCard.SetBounds(20, 20, 420, 106); dialog.Controls.Add(minutesCard);
                var untilCard = new Card { Radius = (int)(18 * uiScale) }; untilCard.SetBounds(20, 142, 420, 118); dialog.Controls.Add(untilCard);
                timedMinutes = new RadioButton { Text = T("持续时间", "For a duration"), Checked = customUntil == null, AutoSize = true, Location = new Point(18, 17), BackColor = Color.White };
                custom = new NumberField { Minimum = 1, Maximum = 10080, Value = (decimal)customMinutes, Unit = T("分钟", "min"), Font = new Font(Font.FontFamily, 10F) }; custom.SetBounds(196, 48, 206, 44);
                LabelAt(minutesCard, T("运行多久", "Duration"), 20, 57, 160, 26, 10, Muted);
                timedUntil = new RadioButton { Text = T("结束时刻", "Until a time"), Checked = customUntil != null, AutoSize = true, Location = new Point(18, 17), BackColor = Color.White };
                until = new DateTimeField { MinDate = DateTime.Today, MaxDate = DateTime.Now.AddDays(7), Value = DateTime.Now.AddHours(2), Font = new Font(Font.FontFamily, 10F) }; until.SetBounds(18, 57, 384, 44);
                // A resize may rebuild the main page while this modal dialog is open.
                // Keep its input controls local instead of consulting page fields that rebuild clears.
                var durationInput = custom; var untilInput = until;
                DateTime previousUntil;
                if (customUntil != null && DateTime.TryParseExact(customUntil, "yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture, DateTimeStyles.None, out previousUntil) && previousUntil > DateTime.Now && previousUntil < untilInput.MaxDate) untilInput.Value = previousUntil;
                durationInput.Enabled = timedMinutes.Checked; untilInput.Enabled = timedUntil.Checked;
                timedMinutes.CheckedChanged += delegate { if (timedMinutes.Checked) timedUntil.Checked = false; durationInput.Enabled = timedMinutes.Checked; untilInput.Enabled = timedUntil.Checked; };
                timedUntil.CheckedChanged += delegate { if (timedUntil.Checked) timedMinutes.Checked = false; durationInput.Enabled = timedMinutes.Checked; untilInput.Enabled = timedUntil.Checked; };
                var ok = ButtonAt(dialog, T("确定", "Use timer"), 298, 280, 142, 44, delegate
                {
                    DateTime end;
                    if (timedUntil.Checked && (!untilInput.TryGetValue(out end) || end <= DateTime.Now)) { MessageBox.Show(dialog, T("请输入未来七天内的时间，格式为 yyyy-MM-dd HH:mm。", "Enter a time within the next seven days as yyyy-MM-dd HH:mm."), T("结束时刻", "End time"), MessageBoxButtons.OK, MessageBoxIcon.Information); return; }
                    customMinutes = (double)durationInput.Value; customUntil = timedUntil.Checked ? untilInput.Value.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture) : null;
                    dialog.DialogResult = DialogResult.OK;
                });
                ok.Fill = Blue; ok.Ink = Color.White;
                var cancel = ButtonAt(dialog, T("取消", "Cancel"), 170, 280, 110, 44, delegate { dialog.DialogResult = DialogResult.Cancel; });
                minutesCard.Controls.AddRange(new Control[] { timedMinutes, durationInput }); untilCard.Controls.AddRange(new Control[] { timedUntil, untilInput }); dialog.AcceptButton = ok; dialog.CancelButton = cancel;
                foreach (Control child in dialog.Controls) child.Scale(new SizeF(uiScale, uiScale));
                accepted = dialog.ShowDialog(this) == DialogResult.OK;
                custom = null;
            }
            return accepted;
        }
        double customMinutes = 90;
        string customUntil;
        void DraftChanged(object sender, EventArgs e)
        {
            if (initialized)
            {
                preferencesDirty = true;
                if (sender != language && sender != closeToTray && sender != autoStart && sender != hotkey) dirty = true;
                if (sender == display || sender == antiLock)
                {
                    selectedScenario = !display.Checked && !antiLock.Checked ? 2 : display.Checked && antiLock.Checked ? (selectedScenario == 1 ? 1 : 0) : -1;
                    for (int i = 0; i < scenarios.Count; i++) { scenarios[i].Selected = i == selectedScenario; scenarios[i].Invalidate(); }
                }
            }
            SetBusyControls();
        }
        Dictionary<string, object> Draft()
        {
            var draft = new Dictionary<string, object>(config);
            if (display != null) { draft["keepDisplayOn"] = display.Checked; draft["antiLock"] = antiLock.Checked; }
            if (method != null) { draft["antiLockMethod"] = method.SelectedIndex == 1 ? "mouse" : "key"; draft["antiLockIntervalSec"] = (int)interval.Value; draft["batteryFloorPercent"] = (int)floor.Value; }
            if (language != null) draft["language"] = new[] { "auto", "zh", "en" }[language.SelectedIndex];
            if (closeToTray != null) draft["closeToTray"] = closeToTray.Checked;
            if (autoStart != null) draft["autoStart"] = autoStart.Checked;
            if (hotkey != null) draft["hotkeyEnabled"] = hotkey.Checked;
            return draft;
        }
        async void PrimaryClick(object sender, EventArgs e) { await ToggleProtection(); }
        async Task ToggleProtection()
        {
            if (commandBusy || commandQueued || !known) return;
            if (running || Value.Number(state, "workerCount") > 0 || IsPaused()) { await Execute("stop", null, true); return; }
            await StartSession();
        }
        async Task StartSession()
        {
            DateTime end;
            if (selectedMinutes == -1 && customUntil != null && (!DateTime.TryParseExact(customUntil, "yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture, DateTimeStyles.None, out end) || end <= DateTime.Now))
            {
                if (!ShowDurationDialog()) return;
                SelectDuration(-1);
            }
            var draft = Draft(); draft["minutes"] = selectedMinutes == -1 ? customMinutes : selectedMinutes;
            if (selectedMinutes == -1 && customUntil != null) draft["until"] = customUntil;
            await Execute("start", draft, true);
        }
        async Task Execute(string action, Dictionary<string, object> request, bool userAction)
        {
            if (action == "state" || action == "automation-tick") { if (busy || commandBusy || commandQueued) return; }
            else
            {
                if (commandBusy || commandQueued) return;
                commandQueued = true; SetBusyControls();
                while (busy && !IsDisposed) await Task.Delay(50);
                commandQueued = false;
            }
            if (IsDisposed) return;
            busy = true; commandBusy = action != "state"; lastOperationSucceeded = false; SetBusyControls();
            try
            {
                var response = await Program.Call(action, request);
                if (IsDisposed) return;
                lastOperationSucceeded = true;
                bool previousRunning = running;
                long previousExpiry = expiresEpoch;
                long previousStarted = startedEpoch;
                state = Value.Map(response, "state"); running = Value.Bool(state, "running"); known = true;
                ReadAutomation(response);
                Text = "KeepAwake";
                if (noticeIsError) ClearNotice();
                bool languageChanged = false;
                if (!initialized || action == "save")
                {
                    config = Value.Map(state, "config"); languagePreference = Value.Text(config, "language");
                    if (!initialized && running)
                    {
                        var live = Value.Map(state, "worker");
                        foreach (string key in new[] { "keepDisplayOn", "antiLock", "antiLockMethod" }) config[key] = Value.Get(live, key);
                        config["antiLockIntervalSec"] = Value.Get(live, "antiLockInterval");
                        config["batteryFloorPercent"] = Value.Get(live, "batteryFloor");
                    }
                    bool nextEnglish = Value.Text(response, "language") != "zh";
                    languageChanged = english != nextEnglish; english = nextEnglish;
                    var desktop = Value.Map(response, "desktop");
                    closePreference = Value.Get(desktop, "closeToTray") == null || Value.Bool(desktop, "closeToTray");
                    hotkeyPreference = Value.Bool(desktop, "hotkeyEnabled");
                    if (!initialized && hotkeyPreference && !ConfigureHotkey(true))
                        Notify(T("快捷键被其他程序占用。", "The shortcut is already in use."), true);
                }
                if (!initialized)
                {
                    if (running)
                    {
                        var live = Value.Map(state, "worker");
                        double end = Value.Number(live, "expiresEpoch"), start = Value.Number(live, "startedEpoch");
                        double minutes = end > 0 ? Math.Max(1, Math.Min(10080, Math.Round((end - start) / 60))) : 0;
                        if (minutes == 0 || minutes == 30 || minutes == 60 || minutes == 120) selectedMinutes = minutes;
                        else { selectedMinutes = -1; customMinutes = minutes; }
                    }
                    initialized = true; display = null; antiLock = null;
                    if (languageChanged) { BuildNavigation(); tray.Visible = false; tray.Dispose(); CreateTray(); } BuildPage(currentPage);
                }
                if (action == "save")
                {
                    preferencesDirty = false;
                    if (languageChanged) { BuildNavigation(); BuildPage(currentPage); tray.Visible = false; tray.Dispose(); CreateTray(); }
                }
                if (action == "start" || action == "stop") { dirty = false; timerFinished = false; }
                var worker = Value.Map(state, "worker"); startedEpoch = Value.Number(worker, "startedEpoch"); expiresEpoch = Value.Number(worker, "expiresEpoch");
                if (running && (confirmedSession == null || startedEpoch != previousStarted || action == "start")) confirmedSession = new SessionDraft(worker, action == "start" ? request : null);
                if (!running) confirmedSession = null;
                snapshotEpoch = Value.Number(state, "nowEpoch"); statusAge.Restart();
                if (action == "start" && request != null)
                {
                    double minutes = Convert.ToDouble(Value.Get(request, "minutes"), CultureInfo.InvariantCulture);
                    customUntil = String.IsNullOrEmpty(Value.Text(request, "until")) ? null : Value.Text(request, "until");
                    if (customUntil == null && (minutes == 0 || minutes == 30 || minutes == 60 || minutes == 120)) SelectDuration(minutes);
                    else { customMinutes = minutes; SelectDuration(-1); }
                    durationTouched = true;
                }
                bool timerEnded = !userAction && previousRunning && !running && previousExpiry > 0 && Value.Number(state, "nowEpoch") >= previousExpiry;
                if (timerEnded) timerFinished = true;
                RenderState();
                if (timerEnded)
                {
                    string ended = T("定时已结束", "Timer ended");
                    Notify(ended, false);
                    if (!Visible && !selfTest) tray.ShowBalloonTip(3500, "KeepAwake", ended, ToolTipIcon.Info);
                }
                if (action == "log")
                {
                    logText = Convert.ToString(Value.Get(response, "result")); activityLoaded = true; activityMode = 0;
                }
                if (action == "report") { reportText = Pretty(Value.Get(response, "result"), 0); activityMode = 1; }
                if (action == "diagnostic") ShowDiagnostic(Value.Map(response, "result"));
                if ((action == "log" || action == "report") && currentPage == 2) PresentActivity(true);
                if (userAction)
                {
                    var result = Value.Map(response, "result");
                    if (Value.Get(result, "intentWritten") != null && !Value.Bool(result, "intentWritten")) Notify(T("恢复设置未能保存，请检查数据目录权限。", "Recovery settings could not be saved. Check data directory permissions."), true);
                    else if (action == "save") Notify(T("设置已保存", "Settings saved"), false);
                }
            }
            catch (Exception ex)
            {
                if (IsDisposed) return;
                lastOperationSucceeded = false;
                if (action == "state" || action == "start" || action == "stop")
                {
                    known = false; status.Text = T("状态不可用", "Unavailable"); status.ForeColor = Color.FromArgb(160, 44, 34);
                }
                UpdateClock();
                tray.Text = "KeepAwake · ?";
                Notify(ex.Message, true);
                if (selfTest) TestExitCode = 1;
            }
            finally { if (!IsDisposed) { busy = false; commandBusy = false; SetBusyControls(); if (shutdownPending) { quit = true; Close(); } } }
        }
        static string Pretty(object value, int level)
        {
            var map = value as Dictionary<string, object>;
            if (map == null) return Program.Json.Serialize(value);
            var output = new StringBuilder(); foreach (var pair in map) { output.Append(new string(' ', level * 2)).Append(pair.Key).Append(": "); var child = pair.Value as Dictionary<string, object>; if (child != null) output.AppendLine().Append(Pretty(child, level + 1)); else output.AppendLine(Program.Json.Serialize(pair.Value)); } return output.ToString();
        }
        bool IsPaused() { return Value.Bool(Value.Map(state, "leases"), "paused"); }
        void RenderState()
        {
            if (!known) { UpdateClock(); UpdatePrimary(); return; }
            statusDetailText = "";
            status.Text = IsPaused() ? T("已暂停", "Paused") : running ? T("●  保护中", "●  Active") : T("未开启", "Inactive");
            status.ForeColor = IsPaused() ? Color.FromArgb(156, 83, 0) : running ? Color.FromArgb(20, 108, 46) : Ink;
            if (!running && Value.Number(state, "workerCount") > 0) statusDetailText = T("保护进程的状态需要核实。可以停止保护后重新开启。", "The protection worker's state needs checking. Stop protection and start it again.");
            if (!running && !IsPaused() && Value.Text(Value.Map(state, "intent"), "desired") == "awake")
                statusDetailText = T("保护进程未运行，请检查后重新开启。", "The protection worker is not running. Check it before restarting.");
            var workerState = Value.Map(state, "worker");
            if (running && !String.IsNullOrEmpty(Value.Text(workerState, "error")))
                statusDetailText = T("保护进程报告错误。", "The protection worker reported an error.");
            else if (running && Value.Bool(workerState, "displayDowngrade"))
                statusDetailText = T("电池策略已允许熄屏和自动锁屏。", "Battery policy allows the screen to turn off and idle lock.");
            var battery = Value.Map(state, "battery");
            power.Text = T("电源 · ", "Power · ") + (!Value.Bool(battery, "acKnown") ? T("未知", "Unknown") : Value.Bool(battery, "acOnline") ? T("已接通", "Plugged in") : T("电池供电", "On battery"));
            if (Value.Bool(battery, "hasBattery") && Value.Number(battery, "percent") >= 0) power.Text += " · " + Value.Number(battery, "percent") + "%";
            tray.Text = IsPaused() ? "KeepAwake · " + T("暂停", "Paused") : running ? "KeepAwake · " + T("保护中", "On") : "KeepAwake · " + T("待机", "Off");
            tray.Icon = Artwork.AppIcon;
            if (Value.Get(state, "alert") is object[] && ((object[])Value.Get(state, "alert")).Length > 0)
            {
                var messages = new List<string>();
                foreach (var item in (object[])Value.Get(state, "alert"))
                {
                    var alert = item as Dictionary<string, object>; string id = Value.Text(alert, "id");
                    string message;
                    switch (id)
                    {
                        case "alert.sessionLocked": message = T("当前会话已锁屏", "The session is locked"); break;
                        case "alert.staleState": message = T("后台心跳已延迟", "The worker heartbeat is delayed"); break;
                        case "alert.uipiBlocked": message = T("高权限窗口阻止了防锁屏心跳", "An elevated window blocked the heartbeat"); break;
                        case "alert.foreignWorkers": message = T("其他数据目录中也有保护进程", "Another data directory has active workers"); break;
                        case "alert.batteryFloor": message = T("低电量保护已允许熄屏，后台任务继续", "Low battery protection allows the screen to turn off. Background work continues."); break;
                        case "alert.batteryCritical": message = T("电池电量危急，保护已停止", "Protection stopped because the battery charge is critical"); break;
                        case "alert.batteryPolicy": message = T("已按电池策略停止保护", "Protection stopped by the battery policy"); break;
                        case "alert.stateUnrecorded": message = T("保护进程无法记录状态", "The worker cannot record its state"); break;
                        case "alert.dataDirUnwritable": message = T("数据目录无法写入", "The data directory is not writable"); break;
                        case "alert.guardDisabled": message = T("自动恢复任务已禁用", "Recovery tasks are disabled"); break;
                        default: message = T("后台状态需要检查", "The engine needs attention"); break;
                    }
                    messages.Add(message);
                }
                if (statusDetailText.Length > 0) messages.Insert(0, statusDetailText);
                statusDetailText = String.Join(Environment.NewLine, messages);
            }
            if (statusDetails != null) statusDetails.Visible = statusDetailText.Length > 0;
            if (statusDetailText.Length > 0) { status.Text = T("需要关注", "Attention"); status.ForeColor = Color.FromArgb(156, 83, 0); }
            string notice = statusDetailText.Length > 0 ? statusDetailText : (running ? "healthy" : IsPaused() ? "paused" : "off");
            if (!selfTest && previousNotice != null && previousNotice != notice && tray != null) {
                if (statusDetailText.Length > 0) tray.ShowBalloonTip(4000, "KeepAwake", statusDetailText, ToolTipIcon.Warning);
                else if (notice == "healthy" && previousNotice != "off" && previousNotice != "paused" && previousNotice != "healthy")
                    tray.ShowBalloonTip(3000, "KeepAwake", T("保护状态已恢复", "Protection has recovered"), ToolTipIcon.Info);
            }
            previousNotice = notice;
            tips.SetToolTip(status, statusDetailText);
            UpdateClock(); UpdatePrimary();
        }
        string DurationText()
        {
            if (selectedMinutes == 0) return T("直到停止", "Until stopped");
            if (selectedMinutes == -1 && customUntil != null)
            {
                DateTime end;
                if (DateTime.TryParseExact(customUntil, "yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture, DateTimeStyles.None, out end)) return end.ToString("HH:mm");
            }
            double minutes = selectedMinutes == -1 ? customMinutes : selectedMinutes;
            return minutes % 60 == 0 ? (minutes / 60).ToString("0.##") + T(" 小时", minutes == 60 ? " hour" : " hours") : minutes.ToString("0.##") + T(" 分钟", " minutes");
        }
        string ScenarioText() { return selectedScenario == 0 ? T("日常工作", "Focus") : selectedScenario == 1 ? T("演示投屏", "Presentation") : selectedScenario == 2 ? T("长任务", "Long task") : T("自定义", "Custom"); }
        void UpdateClock()
        {
            long now = snapshotEpoch + (long)statusAge.Elapsed.TotalSeconds;
            if (timerCaption != null) timerCaption.Text = running && known ? T("剩余时间", "Time remaining") : timerFinished && known ? T("定时已完成", "Timer complete") : T("保护时长", "Duration");
            if (dawnIllustration != null) dawnIllustration.Scene = running && known ? ProductScene.Active : timerFinished && known ? ProductScene.Complete : ProductScene.Idle;
            elapsed.Text = running && known ? T("已运行\n", "Elapsed\n") + FormatSpan(now - startedEpoch) : T("状态\n", "Status\n") + (known ? T("未开启", "Inactive") : T("连接中", "Connecting"));
            elapsed.Visible = running && known && PageWidth >= 660;
            remaining.Text = !known ? "—" : !running ? DurationText() : expiresEpoch == 0 ? T("持续保护", "Continuous") : FormatSpan(expiresEpoch - now);
            float size = 25F;
            using (var font = new Font(Font.FontFamily, size)) if (TextRenderer.MeasureText(remaining.Text, font).Width > remaining.Width) size = 19F;
            if (remaining.Font.SizeInPoints != size) remaining.Font = new Font(Font.FontFamily, size);
            if (running && known && expiresEpoch > 0 && now >= expiresEpoch) { remaining.Text = "00:00:00"; if (!busy) { var ignored = Execute("state", null, false); } }
        }
        string FormatSpan(long seconds)
        {
            var span = TimeSpan.FromSeconds(Math.Max(0, seconds));
            return (span.Days > 0 ? span.Days + T(" 天 ", "d ") : "") + span.ToString(@"hh\:mm\:ss");
        }
        void UpdatePrimary()
        {
            if (running && confirmedSession != null) dirty = confirmedSession.Differs(Draft(), selectedMinutes == -1 ? customMinutes : selectedMinutes, selectedMinutes == -1 ? customUntil : null);
            bool active = running || Value.Number(state, "workerCount") > 0 || IsPaused();
            primary.Text = commandBusy || commandQueued ? T("请稍候…", "Please wait…") : active ? T("停止保护", "Stop protection") : T("开始保护", "Start protection");
            primary.Glyph = active ? "stop" : "play";
            primary.Enabled = known && !commandBusy && !commandQueued; primary.Invalidate();
            applySession.Visible = running && dirty;
            applySession.Enabled = known && !commandBusy && !commandQueued;
            if (pauseProtection != null && !pauseProtection.IsDisposed) {
                pauseProtection.Text = IsPaused() ? T("恢复保护", "Resume") : T("暂停 15 分钟", "Pause for 15 min");
                pauseProtection.Enabled = known && active && !commandBusy && !commandQueued;
            }
            var worker = Value.Map(state, "worker");
            bool displayActive = Value.Get(worker, "displayActive") != null ? Value.Bool(worker, "displayActive") : Value.Bool(worker, "keepDisplayOn");
            string liveOptions = displayActive ? T("屏幕常亮", "Screen stays on") : T("允许熄屏", "Screen can turn off");
            if (Value.Bool(worker, "antiLock")) liveOptions += T(" · 防止自动锁屏", " · Prevent idle lock");
            subtitle.Text = running && dirty ? T("更改尚未应用", "Changes not applied") : !known ? "" : running ? liveOptions : ScenarioText() + " · " + DurationText();
            subtitle.ForeColor = running && dirty ? Color.FromArgb(156, 83, 0) : Muted;
        }
        void SetBusyControls()
        {
            foreach (Control control in content.Controls) control.Enabled = initialized && !commandBusy && !commandQueued;
            foreach (var button in navigation) button.Enabled = initialized && !commandBusy && !commandQueued;
            if (taskNavigation != null) taskNavigation.Enabled = initialized && !commandBusy && !commandQueued;
            if (aboutNavigation != null) aboutNavigation.Enabled = initialized && !commandBusy && !commandQueued;
            noticeRetry.Enabled = !busy && !commandQueued;
            if (save != null && !save.IsDisposed) save.Enabled = !commandBusy && !commandQueued && initialized && preferencesDirty;
            if (copyRecords != null) copyRecords.Enabled = !commandBusy && !commandQueued && !activityEmpty;
            if (tray != null)
            {
                foreach (int index in new[] { 1, 2, 3, 5, 6 }) tray.ContextMenuStrip.Items[index].Enabled = !commandBusy && !commandQueued;
                tray.ContextMenuStrip.Items[1].Enabled &= known;
                tray.ContextMenuStrip.Items[3].Enabled &= known && (running || IsPaused());
                tray.ContextMenuStrip.Items[3].Text = IsPaused() ? T("恢复保护", "Resume") : T("暂停 15 分钟", "Pause for 15 minutes");
            }
            UpdatePrimary();
        }
        void CreateTray()
        {
            var menu = new ContextMenuStrip();
            menu.Items.Add(T("打开 KeepAwake", "Open KeepAwake"), null, delegate { RestoreWindow(); });
            menu.Items.Add(T("保护 30 分钟", "Protect for 30 minutes"), null, async delegate { var draft = Draft(); draft["minutes"] = 30; await Execute("start", draft, true); });
            menu.Items.Add(T("停止保护", "Stop protection"), null, async delegate { await Execute("stop", null, true); });
            menu.Items.Add(T("暂停 15 分钟", "Pause for 15 minutes"), null, async delegate { await Execute(IsPaused() ? "resume" : "pause", null, true); });
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(T("退出界面（保护继续）", "Exit UI (keep protection)"), null, delegate { quit = true; Close(); });
            menu.Items.Add(T("停止保护并退出", "Stop protection and exit"), null, async delegate { await Execute("stop", null, true); if (known && Value.Number(state, "workerCount") == 0) { quit = true; Close(); } });
            tray = new NotifyIcon { Icon = Artwork.AppIcon, Text = "KeepAwake", ContextMenuStrip = menu, Visible = !selfTest };
            tray.DoubleClick += delegate { RestoreWindow(); };
        }
        void HideWindow()
        {
            if (selfTest) return;
            Hide();
            if (!balloonShown) { tray.ShowBalloonTip(3500, "KeepAwake", T("已收起到托盘，双击图标可打开。", "In the system tray. Double-click to open."), ToolTipIcon.Info); balloonShown = true; }
        }
        void RestoreWindow() { Show(); if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal; Activate(); }
        protected override void WndProc(ref Message m)
        {
            if ((uint)m.Msg == Program.ActivateMessage) RestoreWindow();
            if ((uint)m.Msg == Program.CloseMessage && !selfTest) { shutdownPending = true; if (!busy && !commandQueued) { quit = true; Close(); } }
            if (m.Msg == 0x0312 && m.WParam.ToInt32() == HotkeyId && !commandBusy && !commandQueued && known) {
                var ignored = IsPaused() ? Execute("resume", null, true) : running ? Execute("pause", null, true) : ToggleProtection();
            }
            base.WndProc(ref m);
        }
        async Task TestUI()
        {
            try
            {
                if (!known || !initialized || busy) throw new Exception("The desktop could not read engine state.");
                Artwork.Verify();
                TestStartupAndShortcut();
                TestRuleDialog(delegate { ShowAutomation(); }, ".automation.png");
                TestRuleDialog(delegate { EditAutomation(null); }, ".rule.png");
                TestRuleDialog(delegate { ShowSupplyPolicy(); }, ".battery.png");
                WindowState = FormWindowState.Normal; Show(); ShowWindow(Handle, 9); ClientSize = new Size((int)(1060 * uiScale), (int)(760 * uiScale)); Activate();
                await Task.Delay(250);
                BuildPage(1); if (interval.Minimum != 10 || floor.Maximum != 90 || language.Items.Count != 3) throw new Exception("Preferences do not match engine limits.");
                decimal initialInterval = interval.Value;
                ((Button)interval.Controls[3]).PerformClick();
                if (interval.Value != initialInterval + 1) throw new Exception("The time field increment action failed.");
                ((Button)interval.Controls[2]).PerformClick();
                if (interval.Value != initialInterval) throw new Exception("The time field decrement action failed.");
                if (screenshot != null) SavePreview(screenshot + ".settings.png");
                bool originalAutoStart = autoStart.Checked, originalHotkey = hotkey.Checked;
                language.SelectedIndex = 1; closeToTray.Checked = false; interval.Value = 180;
                autoStart.Checked = !originalAutoStart; hotkey.Checked = !originalHotkey;
                BuildPage(0); BuildPage(1);
                if (language.SelectedIndex != 1 || closeToTray.Checked || interval.Value != 180 || autoStart.Checked == originalAutoStart || hotkey.Checked == originalHotkey) throw new Exception("Navigation lost advanced preferences.");
                language.SelectedIndex = 0; closeToTray.Checked = true; interval.Value = 240;
                autoStart.Checked = originalAutoStart; hotkey.Checked = originalHotkey;
                BuildPage(2); await Execute("log", null, false); if (!known) throw new Exception("Activity failed.");
                string activityBefore = records.Text; BuildPage(0); BuildPage(2);
                if (records.Text != activityBefore) throw new Exception("Navigation lost activity output.");
                if (screenshot != null) SavePreview(screenshot + ".activity.png");
                await Execute("report", null, false); if (!known || activityMode != 1 || String.IsNullOrWhiteSpace(records.Text)) throw new Exception("Device diagnostics failed.");
                if (screenshot != null) SavePreview(screenshot + ".diagnostics.png");
                BuildPage(0); SetScenario(2); if (display.Checked || antiLock.Checked) throw new Exception("Long-task preset did not apply.");
                SetScenario(0); SelectDuration(60); if (!durations[1].Selected) throw new Exception("Duration selection failed.");
                durationTouched = true; SelectDuration(30); SetScenario(1); if (selectedMinutes != 30) throw new Exception("Changing scenario lost the chosen duration.");
                BuildPage(1); BuildPage(0); if (!scenarios[1].Selected || !durations[0].Selected) throw new Exception("Navigation lost the draft.");
                double priorMinutes = selectedMinutes;
                using (var cancelDialog = new System.Windows.Forms.Timer { Interval = 200 })
                {
                    cancelDialog.Tick += delegate
                    {
                        cancelDialog.Stop();
                        foreach (Form dialog in Application.OpenForms) if (dialog != this)
                        {
                            BuildPage(0); // Reproduce a resize-triggered page rebuild while the dialog is open.
                            timedUntil.Checked = true;
                            if (screenshot != null) SaveWindowPreview(dialog, screenshot + ".timer.png");
                            dialog.DialogResult = DialogResult.Cancel; break;
                        }
                    };
                    cancelDialog.Start();
                    if (ShowDurationDialog() || selectedMinutes != priorMinutes) throw new Exception("Cancelling the timer dialog changes the draft.");
                }
                running = true; dirty = true; UpdatePrimary();
                if (primary.Glyph != "stop" || !applySession.Visible) throw new Exception("Stop and apply actions are not distinct.");
                running = Value.Bool(state, "running"); SetScenario(0); SelectDuration(60);
                var leaseState = Value.Map(state, "leases");
                bool wasPaused = Value.Bool(leaseState, "paused");
                leaseState["paused"] = true; RenderState();
                if (!IsPaused() || primary.Glyph != "stop" || pauseProtection == null || !pauseProtection.Enabled) throw new Exception("Paused protection has no stop or resume action.");
                leaseState["paused"] = wasPaused; RenderState();
                bool taskDialogShown = false;
                using (var closeTasks = new System.Windows.Forms.Timer { Interval = 200 }) {
                    closeTasks.Tick += delegate {
                        closeTasks.Stop();
                        foreach (Form dialog in Application.OpenForms) if (dialog != this) {
                            foreach (Control control in dialog.Controls) if (control is ListView) taskDialogShown = true;
                            dialog.Close(); break;
                        }
                    };
                    closeTasks.Start(); ShowTasks();
                }
                if (!taskDialogShown) throw new Exception("The desktop task list did not open.");
                dirty = false; UpdatePrimary(); ClearNotice();
                ShowWindow(Handle, 9); WindowState = FormWindowState.Normal;
                ClientSize = new Size((int)(1060 * uiScale), (int)(760 * uiScale));
                BuildPage(0); PerformLayout(); Refresh();
                if (dawnIllustration == null || (SystemInformation.UIEffectsEnabled && !dawnIllustration.IsAnimating)) throw new Exception("The ambient illustration is missing or its motion is not running.");
                if (SystemInformation.UIEffectsEnabled)
                {
                    long priorFrames = dawnIllustration.FrameCount; await Task.Delay(180);
                    if (dawnIllustration.FrameCount <= priorFrames) throw new Exception("The visible illustration does not advance its animation.");
                    dawnIllustration.Visible = false;
                    if (dawnIllustration.IsAnimating) throw new Exception("The hidden illustration keeps animating.");
                    dawnIllustration.Visible = true;
                    if (!dawnIllustration.IsAnimating) throw new Exception("The illustration does not resume after being shown.");
                }
                foreach (Control control in scenarios) VerifyPaintBackground(control);
                foreach (Control control in durations) VerifyPaintBackground(control);
                VerifyPaintBackground(display); VerifyPaintBackground(antiLock); VerifyPaintBackground(primary);
                if (ClientSize.Width < 900 || ClientSize.Height < 680) throw new Exception("The desktop window did not open at a usable size: " + ClientSize + "; " + WindowState + "; desktop " + SystemInformation.VirtualScreen);
                if (screenshot != null) SavePreview(screenshot);
                long liveStarted = startedEpoch, liveExpiry = expiresEpoch;
                running = true; startedEpoch = snapshotEpoch - 120; expiresEpoch = snapshotEpoch + 3480; RenderState();
                if (dawnIllustration.Scene != ProductScene.Active) throw new Exception("The active state does not select its own artwork.");
                if (screenshot != null) SavePreview(screenshot + ".active.png");
                running = false; timerFinished = true; RenderState();
                if (dawnIllustration.Scene != ProductScene.Complete) throw new Exception("The completed state does not select its own artwork.");
                if (screenshot != null) SavePreview(screenshot + ".complete.png");
                running = Value.Bool(state, "running"); startedEpoch = liveStarted; expiresEpoch = liveExpiry; timerFinished = false; RenderState();
                if (notice.Visible) throw new Exception("The default product view contains an unnecessary notification.");
                var entries = ActivityEvent.Parse("2026-10-03 10:00:00  STARTED pid=123 display=off duration=30 min\n2026-10-03 10:30:00  STOPPED pid=123 reason=expired\n2026-10-03 10:30:00  STOP pid=456 forced=0", false);
                if (entries.Count != 2 || entries[0].Title != "保护已停止" || entries[1].Description.Contains("pid=")) throw new Exception("Activity is not presented as product events.");
                var sampleWorker = new Dictionary<string, object> { { "keepDisplayOn", true }, { "antiLock", false }, { "antiLockMethod", "key" }, { "antiLockInterval", 240 }, { "batteryFloor", 20 } };
                var sampleDraft = new Dictionary<string, object> { { "keepDisplayOn", true }, { "antiLock", false }, { "antiLockMethod", "key" }, { "antiLockIntervalSec", 240 }, { "batteryFloorPercent", 20 }, { "minutes", 60 } };
                var session = new SessionDraft(sampleWorker, sampleDraft);
                if (session.Differs(sampleDraft, 60, null)) throw new Exception("An unchanged session is marked dirty.");
                sampleDraft["keepDisplayOn"] = false;
                if (!session.Differs(sampleDraft, 60, null)) throw new Exception("An edited session is not marked dirty.");
                sampleDraft["keepDisplayOn"] = true;
                if (session.Differs(sampleDraft, 60, null)) throw new Exception("Reverting an edit leaves a false pending change.");
                BuildPage(3); if (screenshot != null) SavePreview(screenshot + ".about.png");
                bool previousEnglish = english; english = true; BuildNavigation(); BuildPage(0);
                if (screenshot != null) SavePreview(screenshot + ".en.png");
                english = previousEnglish; BuildNavigation(); BuildPage(0);
                ClientSize = new Size((int)(860 * uiScale), (int)(560 * uiScale)); BuildPage(0);
                if (!content.VerticalScroll.Visible || primary.Bottom > actionBar.Height || actionBar.Top < 0) throw new Exception("Compact-window navigation or primary action is inaccessible.");
                if (primary.Right > actionBar.Width || content.HorizontalScroll.Visible) throw new Exception("The compact layout overflows horizontally.");
                if (screenshot != null) SavePreview(screenshot + ".compact.png", false);
                TestExitCode = 0;
            }
            catch (Exception ex) { TestExitCode = 1; if (screenshot != null) File.WriteAllText(screenshot + ".error.txt", ex.ToString()); }
            finally { quit = true; Close(); }
        }
        void SavePreview(string path, bool standardSize = true)
        {
            ShowWindow(Handle, 9); WindowState = FormWindowState.Normal;
            if (standardSize) ClientSize = new Size((int)(1060 * uiScale), (int)(760 * uiScale));
            PerformLayout(); Refresh();
            SaveWindowPreview(this, path);
        }
        static void SaveWindowPreview(Form window, string path)
        {
            window.Activate(); window.PerformLayout(); window.Refresh();
            using (var bitmap = new Bitmap(window.Width, window.Height))
            { window.DrawToBitmap(bitmap, new Rectangle(Point.Empty, window.Size)); bitmap.Save(path, System.Drawing.Imaging.ImageFormat.Png); }
            // Capture only our client area after the compositor has presented it. Activation alone
            // can race with another foreground window; the temporary test-only topmost flag avoids that.
            bool priorTopMost = window.TopMost;
            try
            {
                window.TopMost = true; window.Activate(); window.Refresh(); Application.DoEvents(); Thread.Sleep(100);
                using (var live = new Bitmap(window.ClientSize.Width, window.ClientSize.Height))
                using (var graphics = Graphics.FromImage(live))
                { graphics.CopyFromScreen(window.PointToScreen(Point.Empty), Point.Empty, window.ClientSize); live.Save(path + ".live.png", System.Drawing.Imaging.ImageFormat.Png); }
            }
            finally { window.TopMost = priorTopMost; }
        }
        static void VerifyPaintBackground(Control control)
        {
            using (var bitmap = new Bitmap(control.Width, control.Height))
            {
                control.DrawToBitmap(bitmap, control.ClientRectangle);
                Color corner = bitmap.GetPixel(2, 2);
                if (corner.R < 60 && corner.G < 60 && corner.B < 60) throw new Exception("An owner-drawn control contains an unpainted black background: " + control.Text);
            }
        }
    }
}
