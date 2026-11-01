using System;
using System.Collections;
using System.Collections.Generic;
using System.Drawing;
using System.Text;
using System.Windows.Forms;

namespace KeepAwakeDesktop
{
    partial class DesktopForm
    {
        void ShowTasks()
        {
            var leaseStatus = Value.Map(state, "leases");
            if (Value.Get(leaseStatus, "readable") != null && !Value.Bool(leaseStatus, "readable")) {
                MessageBox.Show(this, T("无法读取任务状态。", "Task status could not be read."), "KeepAwake", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }
            using (var dialog = new Form { Text = T("任务保护", "Task protection"), Font = Font, BackColor = Background,
                StartPosition = FormStartPosition.CenterParent, MinimizeBox = false, MaximizeBox = false,
                ClientSize = new Size((int)(620 * uiScale), (int)(410 * uiScale)) })
            {
                var list = new ListView { View = View.Details, FullRowSelect = true, MultiSelect = false, HideSelection = false,
                    AccessibleName = T("任务保护列表", "Task protection list") };
                list.SetBounds(24, 24, 572, 300);
                list.Columns.Add(T("任务", "Task"), 250); list.Columns.Add(T("来源", "Source"), 145); list.Columns.Add(T("结束时间", "Ends"), 160);
                dialog.Controls.Add(list);
                var release = ButtonAt(dialog, T("结束所选任务", "Release selected"), 24, 342, 168, 42, null);
                Action populateTasks = null;
                var watch = ButtonAt(dialog, T("绑定进程", "Watch process"), 202, 342, 150, 42, delegate {
                    ShowWatchProcess();
                    if (!dialog.IsDisposed) populateTasks();
                });
                var close = ButtonAt(dialog, T("关闭", "Close"), 470, 342, 126, 42, delegate { dialog.Close(); });
                populateTasks = delegate {
                    list.Items.Clear();
                    var leases = Value.Map(state, "leases");
                    var items = Value.Get(leases, "items") as IEnumerable;
                    if (items != null) foreach (var raw in items) {
                        var task = raw as Dictionary<string, object>;
                        if (task == null) continue;
                        string reason = Value.Text(task, "reason");
                        var row = new ListViewItem(String.IsNullOrWhiteSpace(reason) ? T("外部任务", "External task") : reason);
                        row.Tag = Value.Text(task, "id");
                        string owner = Value.Text(task, "owner");
                        row.SubItems.Add(owner.StartsWith("mcp_", StringComparison.Ordinal) ? T("AI 客户端", "AI client") :
                            owner.StartsWith("cli_", StringComparison.Ordinal) ? T("命令", "Command") :
                            owner.StartsWith("watch_", StringComparison.Ordinal) ? T("进程", "Process") :
                            owner.StartsWith("auto_", StringComparison.Ordinal) ? T("自动规则", "Rule") : owner);
                        long epoch = Value.Number(task, "expiresEpoch");
                        row.SubItems.Add(epoch > 0 ? new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddSeconds(epoch).ToLocalTime().ToString("g") : "—");
                        list.Items.Add(row);
                    }
                    release.Enabled = false;
                };
                list.SelectedIndexChanged += delegate { release.Enabled = list.SelectedItems.Count == 1 && !commandBusy && !commandQueued; };
                release.Click += async delegate {
                    if (list.SelectedItems.Count != 1) return;
                    string id = Convert.ToString(list.SelectedItems[0].Tag);
                    release.Enabled = false;
                    await Execute("release", new Dictionary<string, object> { { "id", id } }, true);
                    if (!dialog.IsDisposed) populateTasks();
                };
                foreach (Control child in dialog.Controls) child.Scale(new SizeF(uiScale, uiScale));
                dialog.CancelButton = close; populateTasks(); dialog.ShowDialog(this);
            }
        }

        void ShowWatchProcess()
        {
            using (var dialog = new Form { Text = T("绑定进程", "Watch process"), Font = Font, BackColor = Background,
                StartPosition = FormStartPosition.CenterParent, MinimizeBox = false, MaximizeBox = false,
                FormBorderStyle = FormBorderStyle.FixedDialog, ClientSize = new Size((int)(460 * uiScale), (int)(280 * uiScale)) })
            {
                LabelAt(dialog, T("进程 ID", "Process ID"), 24, 25, 170, 30, 10, Ink);
                var pid = new NumericUpDown { Minimum = 1, Maximum = Int32.MaxValue, Value = 1, Font = Font };
                pid.SetBounds(24, 60, 410, 34); dialog.Controls.Add(pid);
                var displayOption = new CheckBox { Text = T("保持屏幕开启", "Keep display on"), AutoSize = true, Font = Font };
                displayOption.SetBounds(24, 115, 280, 28); dialog.Controls.Add(displayOption);
                var lockOption = new CheckBox { Text = T("防止自动锁屏", "Prevent idle lock"), AutoSize = true, Font = Font };
                lockOption.SetBounds(24, 153, 280, 28); dialog.Controls.Add(lockOption);
                Pill start = null;
                start = ButtonAt(dialog, T("开始", "Start"), 288, 215, 146, 42, async delegate {
                    var request = new Dictionary<string, object> { { "pid", (int)pid.Value }, { "keepDisplayOn", displayOption.Checked }, { "antiLock", lockOption.Checked } };
                    start.Enabled = false;
                    await Execute("watch", request, true);
                    if (lastOperationSucceeded && !dialog.IsDisposed) dialog.DialogResult = DialogResult.OK;
                    else if (!dialog.IsDisposed) { start.Enabled = true; MessageBox.Show(dialog, lastError, "KeepAwake", MessageBoxButtons.OK, MessageBoxIcon.Error); }
                });
                var cancel = ButtonAt(dialog, T("取消", "Cancel"), 156, 215, 122, 42, delegate { dialog.DialogResult = DialogResult.Cancel; });
                foreach (Control child in dialog.Controls) child.Scale(new SizeF(uiScale, uiScale));
                dialog.AcceptButton = start; dialog.CancelButton = cancel; dialog.ShowDialog(this);
            }
        }

        void ShowDiagnostic(Dictionary<string, object> diagnostic)
        {
            string json = Program.Json.Serialize(diagnostic);
            using (var dialog = new Form { Text = T("诊断预览", "Diagnostic preview"), Font = Font, BackColor = Background,
                StartPosition = FormStartPosition.CenterParent, MinimizeBox = false, MaximizeBox = false,
                ClientSize = new Size((int)(620 * uiScale), (int)(410 * uiScale)) })
            {
                var preview = new TextBox { Text = Pretty(diagnostic, 0), Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical,
                    BackColor = Color.White, ForeColor = Ink, Font = Font, AccessibleName = T("诊断预览", "Diagnostic preview") };
                preview.SetBounds(24, 24, 572, 300); dialog.Controls.Add(preview);
                var save = ButtonAt(dialog, T("保存 JSON", "Save JSON"), 24, 342, 150, 42, delegate {
                    using (var file = new SaveFileDialog { Filter = "JSON (*.json)|*.json", FileName = "keepawake-diagnostics.json" }) {
                        if (file.ShowDialog(dialog) == DialogResult.OK) {
                            try { System.IO.File.WriteAllText(file.FileName, json, new UTF8Encoding(false)); }
                            catch (Exception ex) { MessageBox.Show(dialog, ex.Message, "KeepAwake", MessageBoxButtons.OK, MessageBoxIcon.Error); }
                        }
                    }
                });
                var close = ButtonAt(dialog, T("关闭", "Close"), 470, 342, 126, 42, delegate { dialog.Close(); });
                foreach (Control child in dialog.Controls) child.Scale(new SizeF(uiScale, uiScale));
                dialog.AcceptButton = save; dialog.CancelButton = close; dialog.ShowDialog(this);
            }
        }
    }
}
