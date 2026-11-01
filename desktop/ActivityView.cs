using System;
using System.Collections.Generic;
using System.Drawing;
using System.Text.RegularExpressions;
using System.Windows.Forms;

namespace KeepAwakeDesktop
{
    sealed class ActivityEvent
    {
        internal string Time, Title, Description, Glyph;
        internal static List<ActivityEvent> Parse(string text, bool english)
        {
            var entries = new List<ActivityEvent>();
            foreach (string line in (text ?? "").Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries))
            {
                var match = Regex.Match(line, @"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:[+-]\d{2}:\d{2})?)\s+(\S+)(.*)$");
                if (!match.Success) { entries.Add(new ActivityEvent { Time = "", Title = english ? "Log entry" : "日志记录", Description = line, Glyph = "activity" }); continue; }
                string kind = match.Groups[2].Value, details = match.Groups[3].Value;
                if (kind == "STOP-REQUEST" || (kind == "STOP" && !details.Contains("forced=1"))) continue;
                var entry = new ActivityEvent { Time = match.Groups[1].Value, Glyph = "activity", Description = "" };
                if (kind == "STARTED")
                {
                    entry.Title = english ? "Protection started" : "保护已开启"; entry.Glyph = "play";
                    entry.Description = details.Contains("display=on") ? (english ? "Screen stays on" : "屏幕常亮") : (english ? "Screen can turn off" : "允许屏幕熄灭");
                    var duration = Regex.Match(details, @"duration=([0-9.]+) min");
                    if (duration.Success) entry.Description += " · " + duration.Groups[1].Value + (english ? " minutes" : " 分钟");
                }
                else if (kind == "STOPPED" || kind == "STOP")
                {
                    entry.Title = english ? "Protection stopped" : "保护已停止"; entry.Glyph = "stop";
                    var reason = Regex.Match(details, @"reason=(\S+)").Groups[1].Value;
                    entry.Description = reason.Contains("expir") || reason.Contains("duration") ? (english ? "Timer ended" : "定时结束") : reason.Contains("battery") ? (english ? "Battery critically low" : "电池电量严重不足") : reason == "stopped" ? (english ? "Stopped on request" : "停止请求已执行") : reason;
                }
                else if (kind == "DOWNGRADE") { entry.Title = english ? "Screen protection paused" : "已允许屏幕熄灭"; entry.Description = english ? "Low battery; background work continues" : "电量较低，后台任务继续"; entry.Glyph = "monitor"; }
                else if (kind == "RESTORE") { entry.Title = english ? "Screen protection restored" : "已恢复屏幕常亮"; entry.Glyph = "monitor"; }
                else if (kind == "RESUMED") { entry.Title = english ? "Protection rechecked" : "保护已重新检查"; entry.Glyph = "refresh"; }
                else { entry.Title = english ? "Background event" : "后台事件"; entry.Description = kind; }
                entries.Add(entry);
            }
            entries.Reverse();
            if (entries.Count > 100) entries.RemoveRange(100, entries.Count - 100);
            return entries;
        }
    }
    sealed class ActivityRow : Control
    {
        internal ActivityEvent Entry;
        internal float IconScale;
        internal ActivityRow() { SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true); }
        protected override void OnPaint(PaintEventArgs e)
        {
            int pad = (int)(14 * IconScale), glyph = (int)(26 * IconScale);
            Artwork.Draw(e.Graphics, Entry.Glyph, new Rectangle(pad, (int)(23 * IconScale), glyph, glyph), Color.FromArgb(1, 135, 95));
            int x = (int)(57 * IconScale), dateWidth = (int)(240 * IconScale);
            using (var title = new Font(Font.FontFamily, 10F))
                TextRenderer.DrawText(e.Graphics, Entry.Title, title, new Rectangle(x, (int)(12 * IconScale), Math.Max(120, Width - x - dateWidth), (int)(28 * IconScale)), Color.FromArgb(31, 31, 31), TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
            TextRenderer.DrawText(e.Graphics, Entry.Description, Font, new Rectangle(x, (int)(43 * IconScale), Width - x - pad, (int)(24 * IconScale)), Color.FromArgb(95, 99, 104), TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
            TextRenderer.DrawText(e.Graphics, Entry.Time, Font, new Rectangle(Width - dateWidth - pad, (int)(12 * IconScale), dateWidth, (int)(28 * IconScale)), Color.FromArgb(95, 99, 104), TextFormatFlags.Right | TextFormatFlags.VerticalCenter);
            using (var pen = new Pen(Color.FromArgb(238, 241, 238))) e.Graphics.DrawLine(pen, x, Height - 1, Width - pad, Height - 1);
        }
    }
}
