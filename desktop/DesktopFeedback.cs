using System;
using System.Drawing;
using System.Windows.Forms;

namespace KeepAwakeDesktop
{
    partial class DesktopForm
    {
        readonly Card notice = new Card();
        readonly Label noticeText = new Label();
        readonly Pill noticeDetails = new Pill();
        readonly Pill noticeRetry = new Pill();
        readonly System.Windows.Forms.Timer noticeTimer = new System.Windows.Forms.Timer { Interval = 3500 };
        bool noticeIsError;
        string lastError = "";
        void InitializeNotices()
        {
            notice.Visible = false; notice.Radius = (int)(14 * uiScale); workspace.Controls.Add(notice);
            noticeText.Font = Font; noticeText.BackColor = Color.Transparent; notice.Controls.Add(noticeText);
            noticeDetails.Text = T("详情", "Details"); noticeDetails.Font = Font;
            noticeDetails.Click += delegate { ShowDetails(T("操作详情", "Operation details"), lastError); }; notice.Controls.Add(noticeDetails);
            noticeRetry.Text = T("重试", "Retry"); noticeRetry.Font = Font;
            noticeRetry.Click += async delegate { await Execute("state", null, false); }; notice.Controls.Add(noticeRetry);
            var dismiss = new Pill { Text = "×", Font = new Font(Font.FontFamily, 12F), Tag = "dismiss" };
            dismiss.Click += delegate { ClearNotice(); }; notice.Controls.Add(dismiss);
            noticeTimer.Tick += delegate { ClearNotice(); };
            workspace.Resize += delegate { LayoutNotice(); };
            LayoutNotice();
        }
        void LayoutNotice()
        {
            int width = Math.Max(320, workspace.ClientSize.Width - (int)(48 * uiScale));
            notice.SetBounds((int)(24 * uiScale), Math.Max(0, workspace.Height - (actionBar.Visible ? actionBar.Height : 0) - (int)(76 * uiScale)), width, (int)(56 * uiScale));
            noticeText.SetBounds((int)(18 * uiScale), (int)(17 * uiScale), width - (int)((noticeIsError ? 230 : 70) * uiScale), (int)(27 * uiScale));
            noticeDetails.SetBounds(width - (int)(212 * uiScale), (int)(9 * uiScale), (int)(76 * uiScale), (int)(38 * uiScale));
            noticeRetry.SetBounds(width - (int)(130 * uiScale), (int)(9 * uiScale), (int)(76 * uiScale), (int)(38 * uiScale));
            notice.Controls[notice.Controls.Count - 1].SetBounds(width - (int)(45 * uiScale), (int)(9 * uiScale), (int)(36 * uiScale), (int)(38 * uiScale));
        }
        void ClearNotice() { noticeTimer.Stop(); notice.Visible = false; }
        void Notify(string message, bool error)
        {
            noticeTimer.Stop(); noticeIsError = error;
            if (error) lastError = message;
            noticeText.Text = error ? T("操作未完成", "The operation could not be completed") : message;
            noticeText.ForeColor = error ? Color.FromArgb(160, 44, 34) : Ink;
            notice.Fill = error ? Color.FromArgb(255, 235, 231) : Color.FromArgb(222, 243, 230);
            foreach (Control control in notice.Controls)
            {
                var button = control as Pill;
                if (button != null) { button.Fill = notice.Fill; button.Ink = noticeText.ForeColor; }
            }
            noticeDetails.Visible = error; noticeRetry.Visible = error && !known;
            tips.SetToolTip(noticeText, error ? message : "");
            LayoutNotice(); notice.Visible = true; notice.BringToFront(); notice.Invalidate();
            if (!error) noticeTimer.Start();
        }
        void ShowDetails(string title, string details)
        {
            using (var dialog = new Form { Text = title, Font = Font, AutoScaleMode = AutoScaleMode.None, BackColor = Background, StartPosition = FormStartPosition.CenterParent, MinimizeBox = false, MaximizeBox = false, FormBorderStyle = FormBorderStyle.FixedDialog, ClientSize = new Size((int)(610 * uiScale), (int)(340 * uiScale)) })
            {
                var box = new TextBox { Text = details, Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, BorderStyle = BorderStyle.None, BackColor = Color.White, ForeColor = Ink, Font = Font }; box.SetBounds(24, 24, 562, 234); dialog.Controls.Add(box);
                var close = ButtonAt(dialog, T("关闭", "Close"), 464, 278, 122, 40, delegate { dialog.DialogResult = DialogResult.OK; }); dialog.AcceptButton = close; dialog.CancelButton = close;
                foreach (Control child in dialog.Controls) child.Scale(new SizeF(uiScale, uiScale));
                dialog.ShowDialog(this);
            }
        }
    }
}
