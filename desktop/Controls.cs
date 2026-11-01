using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.Windows.Forms;

namespace KeepAwakeDesktop
{
    class Card : Panel
    {
        internal int Radius = 22;
        internal Color Fill = Color.White;
        internal static GraphicsPath Shape(Rectangle r, int radius)
        {
            var path = new GraphicsPath(); int d = Math.Min(radius * 2, Math.Min(r.Width, r.Height));
            path.AddArc(r.Left, r.Top, d, d, 180, 90); path.AddArc(r.Right - d, r.Top, d, d, 270, 90);
            path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); path.AddArc(r.Left, r.Bottom - d, d, d, 90, 90); path.CloseFigure(); return path;
        }
        internal Card() { DoubleBuffered = true; BackColor = Color.Transparent; }
        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (var path = Shape(new Rectangle(0, 0, Width - 1, Height - 1), Radius))
            using (var brush = new SolidBrush(Fill)) e.Graphics.FillPath(brush, path);
            base.OnPaint(e);
        }
    }
    class Pill : Button
    {
        internal Color Fill = Color.FromArgb(239, 245, 240);
        internal Color Ink = Color.FromArgb(1, 110, 77);
        internal bool Selected;
        internal string Glyph;
        internal int GlyphSize = 24;
        internal bool AlignLeft;
        internal Pill()
        {
            FlatStyle = FlatStyle.Flat; FlatAppearance.BorderSize = 0; Cursor = Cursors.Hand;
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor, true);
            BackColor = Color.Transparent; UseVisualStyleBackColor = false;
        }
        // ButtonBase's themed background is unsuitable for a completely owner-drawn button.
        // Paint the parent surface first so every pixel outside the rounded shape is defined.
        protected override void OnPaintBackground(PaintEventArgs e)
        {
            if (Parent == null) { e.Graphics.Clear(SystemColors.Control); return; }
            var saved = e.Graphics.Save();
            try
            {
                e.Graphics.TranslateTransform(-Left, -Top);
                using (var background = new PaintEventArgs(e.Graphics, Bounds))
                { InvokePaintBackground(Parent, background); InvokePaint(Parent, background); }
            }
            finally { e.Graphics.Restore(saved); }
        }
        protected override void OnMouseEnter(EventArgs e) { base.OnMouseEnter(e); Invalidate(); }
        protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); Invalidate(); }
        protected override void OnPaint(PaintEventArgs e)
        {
            OnPaintBackground(e);
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Color fill = Enabled ? (Selected ? Color.FromArgb(220, 241, 229) : Fill) : Color.FromArgb(232, 234, 237);
            if (Enabled && ClientRectangle.Contains(PointToClient(Cursor.Position))) fill = ControlPaint.Dark(fill, .04f);
            using (var path = Card.Shape(new Rectangle(0, 0, Width - 1, Height - 1), Height / 2))
            using (var brush = new SolidBrush(fill)) e.Graphics.FillPath(brush, path);
            Rectangle textBounds = ClientRectangle;
            if (!String.IsNullOrEmpty(Glyph))
            {
                int gap = Math.Max(8, GlyphSize / 3);
                int textWidth = TextRenderer.MeasureText(Text, Font).Width;
                int start = AlignLeft ? GlyphSize * 2 / 3 : Math.Max(gap, (Width - textWidth - GlyphSize - gap) / 2);
                Artwork.Draw(e.Graphics, Glyph, new Rectangle(start, (Height - GlyphSize) / 2, GlyphSize, GlyphSize), Enabled ? Ink : Color.Gray);
                textBounds = new Rectangle(start + GlyphSize + gap, 0, Width - start - GlyphSize - gap, Height);
                TextRenderer.DrawText(e.Graphics, Text, Font, textBounds, Enabled ? Ink : Color.Gray, TextFormatFlags.Left | TextFormatFlags.VerticalCenter);
            }
            else TextRenderer.DrawText(e.Graphics, Text, Font, textBounds, Enabled ? Ink : Color.Gray, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
            if (Focused) ControlPaint.DrawFocusRectangle(e.Graphics, new Rectangle(6, 6, Width - 12, Height - 12));
        }
    }

    // A borderless editor inside a fully painted surface; no native up/down frame.
    class NumberField : UserControl
    {
        protected override bool ScaleChildren { get { return false; } }
        protected override void ScaleControl(SizeF factor, BoundsSpecified specified) { base.ScaleControl(factor, specified); Arrange(); }
        readonly TextBox editor = new TextBox { BorderStyle = BorderStyle.None, TextAlign = HorizontalAlignment.Center };
        readonly Pill decrease = new Pill { Text = "−" }, increase = new Pill { Text = "+" };
        readonly Label unit = new Label { TextAlign = ContentAlignment.MiddleLeft };
        decimal number, minimum, maximum = 100;
        bool updating;
        internal event EventHandler ValueChanged;
        internal string Unit { get { return unit.Text; } set { unit.Text = value; Arrange(); } }
        internal decimal Minimum { get { return minimum; } set { minimum = value; Value = number; } }
        internal decimal Maximum { get { return maximum; } set { maximum = value; Value = number; } }
        internal decimal Value
        {
            get { return number; }
            set
            {
                decimal next = Math.Max(minimum, Math.Min(maximum, value)); bool changed = next != number;
                number = next; updating = true; editor.Text = number.ToString(CultureInfo.InvariantCulture); updating = false;
                decrease.Enabled = Enabled && number > minimum; increase.Enabled = Enabled && number < maximum;
                if (changed && ValueChanged != null) ValueChanged(this, EventArgs.Empty);
            }
        }
        internal NumberField()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor, true);
            BackColor = Color.Transparent; AccessibleRole = AccessibleRole.SpinButton; Height = 44;
            editor.BackColor = Color.White; editor.ForeColor = Color.FromArgb(32, 33, 36); editor.Text = "0";
            decrease.Fill = increase.Fill = Color.FromArgb(239, 245, 240);
            decrease.AccessibleName = "Decrease"; increase.AccessibleName = "Increase";
            unit.BackColor = Color.White; unit.ForeColor = Color.FromArgb(95, 99, 104);
            Controls.AddRange(new Control[] { editor, unit, decrease, increase });
            decrease.Click += delegate { Value -= 1; }; increase.Click += delegate { Value += 1; };
            editor.TextChanged += delegate
            {
                decimal parsed;
                if (!updating && Decimal.TryParse(editor.Text, NumberStyles.None, CultureInfo.InvariantCulture, out parsed) && parsed >= minimum && parsed <= maximum)
                {
                    bool changed = number != parsed; number = parsed;
                    decrease.Enabled = Enabled && number > minimum; increase.Enabled = Enabled && number < maximum;
                    if (changed && ValueChanged != null) ValueChanged(this, EventArgs.Empty);
                }
            };
            editor.KeyPress += delegate(object sender, KeyPressEventArgs e) { if (!Char.IsControl(e.KeyChar) && !Char.IsDigit(e.KeyChar)) e.Handled = true; };
            editor.KeyDown += delegate(object sender, KeyEventArgs e)
            {
                if (e.KeyCode == Keys.Up || e.KeyCode == Keys.Down) { Value += e.KeyCode == Keys.Up ? 1 : -1; e.SuppressKeyPress = true; }
            };
            editor.Leave += delegate { Value = number; Invalidate(); };
            editor.Enter += delegate { Invalidate(); };
            Enter += delegate { Invalidate(); }; Leave += delegate { Invalidate(); };
            Resize += delegate { Arrange(); }; FontChanged += delegate { Arrange(); };
            EnabledChanged += delegate { editor.BackColor = unit.BackColor = Enabled ? Color.White : Color.FromArgb(245, 247, 245); Value = number; Invalidate(); };
        }
        protected override void OnCreateControl()
        {
            base.OnCreateControl();
            editor.AccessibleName = AccessibleName ?? "Value";
        }
        void Arrange()
        {
            if (editor == null || Height < 1) return;
            int inset = Math.Max(4, Height / 7), button = Height - inset * 2;
            decrease.SetBounds(inset, inset, button, button); increase.SetBounds(Width - inset - button, inset, button, button);
            int unitWidth = String.IsNullOrEmpty(Unit) ? 0 : TextRenderer.MeasureText(Unit, Font).Width + inset;
            int available = Width - 2 * (inset + button) - unitWidth;
            editor.Font = Font; unit.Font = Font; decrease.Font = increase.Font = Font;
            editor.SetBounds(inset + button + 3, (Height - editor.PreferredHeight) / 2, Math.Max(18, available - 6), editor.PreferredHeight);
            unit.SetBounds(inset + button + available, inset, unitWidth, Height - inset * 2);
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (var path = Card.Shape(new Rectangle(1, 1, Width - 3, Height - 3), Math.Max(8, Height / 4)))
            using (var brush = new SolidBrush(Enabled ? Color.White : Color.FromArgb(245, 247, 245)))
            using (var pen = new Pen(ContainsFocus ? Color.FromArgb(1, 135, 95) : Color.FromArgb(218, 225, 220), ContainsFocus ? 2 : 1))
            { e.Graphics.FillPath(brush, path); e.Graphics.DrawPath(pen, path); }
            base.OnPaint(e);
        }
    }

    class DateTimeField : UserControl
    {
        protected override bool ScaleChildren { get { return false; } }
        protected override void ScaleControl(SizeF factor, BoundsSpecified specified) { base.ScaleControl(factor, specified); Arrange(); }
        readonly TextBox editor = new TextBox { BorderStyle = BorderStyle.None };
        readonly Pill calendarButton = new Pill { Glyph = "timer", Text = "" };
        readonly ToolStripDropDown calendarPopup = new ToolStripDropDown { Padding = Padding.Empty };
        readonly MonthCalendar calendar = new MonthCalendar { MaxSelectionCount = 1 };
        DateTime selected = DateTime.Now.AddHours(2), minDate = DateTime.Today, maxDate = DateTime.Now.AddDays(7);
        internal DateTime MinDate { get { return minDate; } set { minDate = value; calendar.MinDate = value; } }
        internal DateTime MaxDate { get { return maxDate; } set { maxDate = value; calendar.MaxDate = value; } }
        internal DateTime Value { get { DateTime parsed; return TryGetValue(out parsed) ? parsed : selected; } set { selected = value; editor.Text = value.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture); } }
        internal bool TryGetValue(out DateTime parsed)
        { return DateTime.TryParseExact(editor.Text, "yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture, DateTimeStyles.None, out parsed) && parsed >= minDate && parsed <= maxDate; }
        internal DateTimeField()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor, true);
            BackColor = Color.Transparent; Height = 44; editor.BackColor = Color.White;
            editor.ForeColor = Color.FromArgb(32, 33, 36); editor.MaxLength = 16; editor.AccessibleName = "yyyy-MM-dd HH:mm";
            calendarButton.Fill = Color.FromArgb(239, 245, 240); calendarButton.AccessibleName = "Calendar";
            Controls.AddRange(new Control[] { editor, calendarButton });
            calendarPopup.Items.Add(new ToolStripControlHost(calendar) { Padding = Padding.Empty, Margin = Padding.Empty });
            calendarButton.Click += delegate
            { calendar.SetDate(Value.Date); calendarPopup.Show(this, new Point(0, Height + 4)); };
            calendar.DateSelected += delegate { Value = calendar.SelectionStart.Date.Add(Value.TimeOfDay); calendarPopup.Close(); editor.Focus(); };
            editor.Enter += delegate { Invalidate(); }; editor.Leave += delegate { Invalidate(); };
            EnabledChanged += delegate { editor.BackColor = Enabled ? Color.White : Color.FromArgb(245, 247, 245); Invalidate(); };
            Resize += delegate { Arrange(); }; FontChanged += delegate { Arrange(); }; Value = selected;
        }
        void Arrange()
        {
            if (editor == null || Height < 1) return;
            int inset = Math.Max(5, Height / 7), button = Height - inset * 2;
            editor.Font = Font; editor.SetBounds(inset * 2, (Height - editor.PreferredHeight) / 2, Width - button - inset * 4, editor.PreferredHeight);
            calendarButton.GlyphSize = button * 2 / 3; calendarButton.SetBounds(Width - button - inset, inset, button, button);
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (var path = Card.Shape(new Rectangle(1, 1, Width - 3, Height - 3), Math.Max(8, Height / 4)))
            using (var brush = new SolidBrush(Enabled ? Color.White : Color.FromArgb(245, 247, 245)))
            using (var pen = new Pen(ContainsFocus ? Color.FromArgb(1, 135, 95) : Color.FromArgb(218, 225, 220), ContainsFocus ? 2 : 1))
            { e.Graphics.FillPath(brush, path); e.Graphics.DrawPath(pen, path); }
            base.OnPaint(e);
        }
        protected override void Dispose(bool disposing) { if (disposing) calendarPopup.Dispose(); base.Dispose(disposing); }
    }

}
