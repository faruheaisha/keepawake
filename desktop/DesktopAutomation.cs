using System;
using System.Collections;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Windows.Forms;

namespace KeepAwakeDesktop
{
    partial class DesktopForm
    {
        List<Dictionary<string, object>> automationRules = new List<Dictionary<string, object>>();
        bool automationEnabled;
        Dictionary<string, object> supplyPolicy = new Dictionary<string, object>();
        void ReadAutomation(Dictionary<string, object> response)
        {
            supplyPolicy = Value.Map(response, "supplyPolicy");
            automationRules.Clear(); automationEnabled = false;
            var items = Value.Get(Value.Map(response, "automation"), "rules") as IEnumerable;
            if (items == null) return;
            foreach (var item in items) {
                var rule = item as Dictionary<string, object>;
                if (rule == null) continue;
                automationRules.Add(rule); automationEnabled |= Value.Bool(rule, "enabled");
            }
        }
        void ShowSupplyPolicy()
        {
            using (var dialog = RuleDialog(T("电池策略", "Battery policy"), 560, 310)) {
                LabelAt(dialog, T("使用电池时", "On battery"), 24, 24, 180, 32, 10, Ink);
                var mode = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Font = Font, AccessibleName = T("电池策略", "Battery policy") };
                mode.Items.AddRange(new object[] { T("继续当前保护", "Continue protection"), T("允许熄屏和自动锁屏", "Allow display off and idle lock"), T("停止全部保护", "Stop all protection") });
                string current = Value.Text(supplyPolicy, "mode"); mode.SelectedIndex = current == "screen-off" ? 1 : current == "stop" ? 2 : 0;
                mode.SetBounds(220, 24, 312, 34); dialog.Controls.Add(mode);
                LabelAt(dialog, T("最长保护时间（分钟）", "Maximum minutes"), 24, 86, 190, 32, 10, Ink);
                var limit = new NumericUpDown { Minimum = 0, Maximum = 1440, Value = Math.Max(0, Math.Min(1440, Value.Number(supplyPolicy, "limitMinutes"))), Font = Font,
                    AccessibleName = T("电池最长保护分钟数", "Maximum protection minutes on battery") };
                limit.SetBounds(220, 86, 312, 34); dialog.Controls.Add(limit);
                LabelAt(dialog, T("0 表示不额外限时。拔电状态确认后生效，危急电量始终停止保护。", "0 adds no time limit. Changes apply after battery power is confirmed. Critical charge always stops protection."), 24, 144, 508, 76, 10, Muted);
                var savePolicy = ButtonAt(dialog, T("保存", "Save"), 382, 246, 150, 42, null);
                savePolicy.Click += async delegate {
                    savePolicy.Enabled = false;
                    string[] modes = { "continue", "screen-off", "stop" };
                    await Execute("supply-save", new Dictionary<string, object> { { "mode", modes[mode.SelectedIndex] }, { "limitMinutes", (int)limit.Value } }, true);
                    if (!dialog.IsDisposed) {
                        if (lastOperationSucceeded) dialog.DialogResult = DialogResult.OK;
                        else { savePolicy.Enabled = true; MessageBox.Show(dialog, lastError, "KeepAwake", MessageBoxButtons.OK, MessageBoxIcon.Error); }
                    }
                };
                var cancel = ButtonAt(dialog, T("取消", "Cancel"), 222, 246, 150, 42, delegate { dialog.DialogResult = DialogResult.Cancel; });
                dialog.AcceptButton = savePolicy; dialog.CancelButton = cancel; ScaleRuleDialog(dialog); dialog.ShowDialog(this);
            }
        }
        Form RuleDialog(string title, int width, int height)
        {
            return new Form { Text = title, Font = Font, BackColor = Background, StartPosition = FormStartPosition.CenterParent,
                MinimizeBox = false, MaximizeBox = false, AutoScroll = true,
                ClientSize = new Size(Math.Min((int)(width * uiScale), Screen.FromControl(this).WorkingArea.Width - 60),
                    Math.Min((int)(height * uiScale), Screen.FromControl(this).WorkingArea.Height - 100)) };
        }
        void ScaleRuleDialog(Form dialog)
        {
            foreach (Control child in dialog.Controls) child.Scale(new SizeF(uiScale, uiScale));
        }
        void TestRuleDialog(Action open, string suffix)
        {
            bool shown = false;
            using (var closeDialog = new System.Windows.Forms.Timer { Interval = 250 }) {
                closeDialog.Tick += delegate {
                    closeDialog.Stop();
                    foreach (Form dialog in Application.OpenForms) if (dialog != this) {
                        shown = true;
                        if (!dialog.SelectNextControl(null, true, true, true, true)) throw new InvalidOperationException("The rule dialog has no keyboard focus target.");
                        if (screenshot != null) SaveWindowPreview(dialog, screenshot + suffix);
                        dialog.DialogResult = DialogResult.Cancel; dialog.Close(); break;
                    }
                };
                closeDialog.Start(); open();
            }
            if (!shown) throw new InvalidOperationException("The rule dialog did not open.");
        }
        void ShowAutomation()
        {
            var drafts = new List<Dictionary<string, object>>();
            foreach (var rule in automationRules) drafts.Add(new Dictionary<string, object>(rule));
            using (var dialog = RuleDialog(T("自动保护", "Automatic protection"), 660, 460)) {
                LabelAt(dialog, T("保持桌面应用或托盘运行，规则才会生效。", "Rules run while the desktop app or tray is open."), 24, 18, 610, 32, 10, Muted);
                var list = new ListView { View = View.Details, FullRowSelect = true, MultiSelect = false, HideSelection = false,
                    AccessibleName = T("自动保护规则", "Automatic protection rules") };
                list.SetBounds(24, 60, 610, 286); dialog.Controls.Add(list);
                list.Columns.Add(T("规则", "Rule"), 270); list.Columns.Add(T("类型", "Type"), 140); list.Columns.Add(T("状态", "Status"), 150);
                Action populate = delegate {
                    list.Items.Clear();
                    foreach (var rule in drafts) {
                        var row = new ListViewItem(Value.Text(rule, "name")); row.Tag = rule;
                        row.SubItems.Add(Value.Text(rule, "type") == "program" ? T("指定程序", "Program") : T("时间表", "Schedule"));
                        row.SubItems.Add(Value.Bool(rule, "enabled") ? T("已启用", "Enabled") : T("已停用", "Disabled")); list.Items.Add(row);
                    }
                };
                ButtonAt(dialog, T("添加", "Add"), 24, 365, 110, 40, delegate {
                    if (drafts.Count >= 32) return;
                    var rule = EditAutomation(null); if (rule != null) { drafts.Add(rule); populate(); }
                });
                var edit = ButtonAt(dialog, T("编辑", "Edit"), 144, 365, 110, 40, delegate {
                    if (list.SelectedItems.Count != 1) return;
                    var old = (Dictionary<string, object>)list.SelectedItems[0].Tag;
                    var rule = EditAutomation(old); if (rule != null) { drafts[drafts.IndexOf(old)] = rule; populate(); }
                });
                var remove = ButtonAt(dialog, T("删除", "Delete"), 264, 365, 110, 40, delegate {
                    if (list.SelectedItems.Count == 1) { drafts.Remove((Dictionary<string, object>)list.SelectedItems[0].Tag); populate(); }
                });
                edit.Enabled = remove.Enabled = false;
                list.SelectedIndexChanged += delegate { edit.Enabled = remove.Enabled = list.SelectedItems.Count == 1; };
                var apply = ButtonAt(dialog, T("保存", "Save"), 504, 365, 130, 40, null);
                apply.Click += async delegate {
                    apply.Enabled = false;
                    await Execute("automation-save", new Dictionary<string, object> { { "rules", drafts } }, true);
                    if (!dialog.IsDisposed) {
                        if (lastOperationSucceeded) dialog.DialogResult = DialogResult.OK;
                        else { apply.Enabled = true; MessageBox.Show(dialog, lastError, "KeepAwake", MessageBoxButtons.OK, MessageBoxIcon.Error); }
                    }
                };
                LabelAt(dialog, T("手动停止会跳过当前时段或程序实例。", "Stopping skips the current time slot or process instance."), 24, 416, 610, 27, 9, Muted);
                ScaleRuleDialog(dialog); populate(); dialog.ShowDialog(this);
            }
        }
        Dictionary<string, object> EditAutomation(Dictionary<string, object> old)
        {
            using (var dialog = RuleDialog(T("保护规则", "Protection rule"), 580, 590)) {
                LabelAt(dialog, T("名称", "Name"), 24, 20, 170, 28, 10, Ink);
                var name = new TextBox { Text = old == null ? "" : Value.Text(old, "name"), MaxLength = 100, Font = Font,
                    AccessibleName = T("规则名称", "Rule name") };
                name.SetBounds(200, 20, 350, 32); dialog.Controls.Add(name);
                LabelAt(dialog, T("类型", "Type"), 24, 70, 170, 28, 10, Ink);
                var type = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Font = Font, AccessibleName = T("规则类型", "Rule type") };
                type.Items.AddRange(new object[] { T("时间表", "Schedule"), T("指定程序", "Program") });
                type.SelectedIndex = old != null && Value.Text(old, "type") == "program" ? 1 : 0;
                type.SetBounds(200, 70, 350, 32); dialog.Controls.Add(type);
                var schedule = new Panel(); schedule.SetBounds(24, 120, 526, 250); dialog.Controls.Add(schedule);
                LabelAt(schedule, T("开始", "Start"), 0, 0, 150, 28, 10, Ink);
                LabelAt(schedule, T("结束", "End"), 0, 48, 150, 28, 10, Ink);
                var from = new DateTimePicker { Format = DateTimePickerFormat.Custom, CustomFormat = "HH:mm", ShowUpDown = true, AccessibleName = T("开始时间", "Start time") };
                var until = new DateTimePicker { Format = DateTimePickerFormat.Custom, CustomFormat = "HH:mm", ShowUpDown = true, AccessibleName = T("结束时间", "End time") };
                from.Value = DateTime.Today.AddHours(9); until.Value = DateTime.Today.AddHours(18);
                DateTime parsed;
                if (old != null && DateTime.TryParse(Value.Text(old, "start"), out parsed)) from.Value = parsed;
                if (old != null && DateTime.TryParse(Value.Text(old, "end"), out parsed)) until.Value = parsed;
                from.SetBounds(176, 0, 350, 32); until.SetBounds(176, 48, 350, 32); schedule.Controls.Add(from); schedule.Controls.Add(until);
                var days = new CheckedListBox { CheckOnClick = true, Font = Font, AccessibleName = T("星期", "Weekdays"), Height = 154 };
                days.Items.AddRange(english ? new object[] { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" } : new object[] { "周日", "周一", "周二", "周三", "周四", "周五", "周六" });
                days.SetBounds(176, 96, 350, 154); schedule.Controls.Add(days);
                var selectedDays = old == null ? null : Value.Get(old, "days") as IEnumerable;
                if (selectedDays != null) foreach (var day in selectedDays) days.SetItemChecked(Convert.ToInt32(day), true);
                else for (int i = 1; i <= 5; i++) days.SetItemChecked(i, true);
                var program = new Panel(); program.SetBounds(24, 120, 526, 250); dialog.Controls.Add(program);
                var path = new TextBox { Text = old == null ? "" : Value.Text(old, "path"), ReadOnly = true, Font = Font, AccessibleName = T("程序路径", "Program path") };
                path.SetBounds(0, 0, 526, 32); program.Controls.Add(path);
                ButtonAt(program, T("选择程序…", "Choose program…"), 0, 50, 200, 40, delegate {
                    using (var chooser = new OpenFileDialog { Filter = "Windows program (*.exe)|*.exe", CheckFileExists = true })
                        if (chooser.ShowDialog(dialog) == DialogResult.OK) { path.Text = chooser.FileName; if (String.IsNullOrWhiteSpace(name.Text)) name.Text = Path.GetFileNameWithoutExtension(path.Text); }
                });
                LabelAt(program, T("只匹配此完整路径的程序实例，不读取窗口标题。", "Matches instances at this full path without reading window titles."), 0, 106, 526, 70, 10, Muted);
                Action visibility = delegate { schedule.Visible = type.SelectedIndex == 0; program.Visible = type.SelectedIndex == 1; };
                type.SelectedIndexChanged += delegate { visibility(); }; visibility();
                var enabled = new CheckBox { Text = T("启用规则", "Enable rule"), Checked = old == null || Value.Bool(old, "enabled"), AutoSize = true, Font = Font };
                var screen = new CheckBox { Text = T("保持屏幕开启", "Keep display on"), Checked = old != null && Value.Bool(old, "keepDisplayOn"), AutoSize = true, Font = Font };
                var idle = new CheckBox { Text = T("防止自动锁屏", "Prevent idle lock"), Checked = old != null && Value.Bool(old, "antiLock"), AutoSize = true, Font = Font };
                enabled.SetBounds(24, 390, 500, 30); screen.SetBounds(24, 430, 500, 30); idle.SetBounds(24, 470, 500, 30);
                dialog.Controls.Add(enabled); dialog.Controls.Add(screen); dialog.Controls.Add(idle);
                Dictionary<string, object> result = null;
                var saveRule = ButtonAt(dialog, T("确定", "OK"), 400, 530, 150, 40, delegate {
                    var selected = new List<int>(); foreach (int day in days.CheckedIndices) selected.Add(day);
                    if (String.IsNullOrWhiteSpace(name.Text) || (type.SelectedIndex == 0 && (selected.Count == 0 || from.Value.TimeOfDay >= until.Value.TimeOfDay)) ||
                        (type.SelectedIndex == 1 && !File.Exists(path.Text))) {
                        MessageBox.Show(dialog, T("请填写名称，并选择有效的时间或程序。", "Enter a name and choose valid times or a program."), "KeepAwake"); return;
                    }
                    // An edited rule is a new authorization; old stopped occurrences stay stopped.
                    result = new Dictionary<string, object> { { "id", Guid.NewGuid().ToString("N") }, { "name", name.Text.Trim() }, { "enabled", enabled.Checked },
                        { "type", type.SelectedIndex == 0 ? "schedule" : "program" }, { "keepDisplayOn", screen.Checked }, { "antiLock", idle.Checked },
                        { "start", from.Value.ToString("HH:mm", System.Globalization.CultureInfo.InvariantCulture) }, { "end", until.Value.ToString("HH:mm", System.Globalization.CultureInfo.InvariantCulture) },
                        { "days", selected }, { "path", path.Text } };
                    dialog.DialogResult = DialogResult.OK;
                });
                var cancel = ButtonAt(dialog, T("取消", "Cancel"), 240, 530, 150, 40, delegate { dialog.DialogResult = DialogResult.Cancel; });
                dialog.AcceptButton = saveRule; dialog.CancelButton = cancel;
                ScaleRuleDialog(dialog); return dialog.ShowDialog(this) == DialogResult.OK ? result : null;
            }
        }
    }
}
