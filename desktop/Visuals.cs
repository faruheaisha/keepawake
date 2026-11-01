using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Text.RegularExpressions;
using System.Xml;
using System.Windows.Forms;

namespace KeepAwakeDesktop
{
    enum ProductScene { Idle, Active, Complete, Settings, Activity, About }
    // Offline SVG primitives only. No external resources or browser/runtime dependency.
    static class Artwork
    {
        static readonly Dictionary<string, Bitmap> Icons = new Dictionary<string, Bitmap>();
        internal static readonly Image Brand;
        internal static readonly Image Dawn;
        static readonly Image ActiveArt, CompleteArt, SettingsArt, ActivityArt, AboutArt;
        static readonly Image[] ScenarioArt;
        internal static readonly Icon AppIcon;
        static Artwork()
        {
            using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("KeepAwake.Brand")) using (var image = Image.FromStream(stream)) Brand = new Bitmap(image);
            using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("KeepAwake.AppIcon")) AppIcon = new Icon(stream);
            Dawn = ReadIllustration("KeepAwake.Dawn");
            ActiveArt = ReadArt("active"); CompleteArt = ReadArt("complete"); SettingsArt = ReadArt("settings"); ActivityArt = ReadArt("activity"); AboutArt = ReadArt("about");
            ScenarioArt = new[] { ReadArt("focus"), ReadArt("presentation"), ReadArt("longtask") };
        }
        static Image ReadArt(string name)
        { return ReadIllustration("KeepAwake.Art." + name); }
        static Image ReadIllustration(string resource)
        {
            using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(resource))
            using (var original = Image.FromStream(stream))
            {
                int width = Math.Min(512, original.Width), height = width * original.Height / original.Width;
                var bitmap = new Bitmap(width, height, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
                using (var graphics = Graphics.FromImage(bitmap))
                { graphics.InterpolationMode = InterpolationMode.HighQualityBicubic; graphics.DrawImage(original, new Rectangle(0, 0, width, height)); }
                return bitmap;
            }
        }
        internal static Image SceneImage(ProductScene scene)
        {
            switch (scene)
            {
                case ProductScene.Active: return ActiveArt;
                case ProductScene.Complete: return CompleteArt;
                case ProductScene.Settings: return SettingsArt;
                case ProductScene.Activity: return ActivityArt;
                case ProductScene.About: return AboutArt;
                default: return Dawn;
            }
        }
        internal static void DrawScenario(Graphics graphics, int scenario, Rectangle bounds)
        {
            string key = "art:" + scenario + ":" + bounds.Width + ":" + bounds.Height; Bitmap bitmap;
            if (!Icons.TryGetValue(key, out bitmap))
            {
                Image original = ScenarioArt[scenario]; bitmap = new Bitmap(bounds.Width, bounds.Height, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
                using (var raster = Graphics.FromImage(bitmap))
                {
                    raster.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    float factor = Math.Min(bounds.Width / (float)original.Width, bounds.Height / (float)original.Height);
                    int width = (int)(original.Width * factor), height = (int)(original.Height * factor);
                    raster.DrawImage(original, new Rectangle((bounds.Width - width) / 2, (bounds.Height - height) / 2, width, height));
                }
                Icons.Add(key, bitmap);
            }
            graphics.DrawImageUnscaled(bitmap, bounds.Location);
        }
        internal static void Draw(Graphics graphics, string name, Rectangle bounds, Color color)
        {
            string key = name + ":" + bounds.Width + ":" + color.ToArgb(); Bitmap bitmap;
            if (!Icons.TryGetValue(key, out bitmap))
            {
                bitmap = Render(name, bounds.Width, color); Icons.Add(key, bitmap);
            }
            graphics.DrawImage(bitmap, bounds);
        }
        static float N(XmlElement node, string attr, float fallback)
        { float value; return Single.TryParse(node.GetAttribute(attr), NumberStyles.Float, CultureInfo.InvariantCulture, out value) ? value : fallback; }
        static Color Paint(string value, Color ink) { return value == "currentColor" ? ink : ColorTranslator.FromHtml(value); }
        static Bitmap Render(string name, int size, Color ink)
        {
            var xml = new XmlDocument { XmlResolver = null };
            using (var input = Assembly.GetExecutingAssembly().GetManifestResourceStream("KeepAwake.Icon." + name + ".svg"))
            { if (input == null) throw new IOException("Missing SVG icon: " + name); xml.Load(input); }
            var root = xml.DocumentElement;
            var bitmap = new Bitmap(size, size);
            using (var g = Graphics.FromImage(bitmap))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias; g.ScaleTransform(size / 24F, size / 24F);
                foreach (XmlNode child in root.ChildNodes)
                {
                    var e = child as XmlElement; if (e == null) continue;
                    using (var path = new GraphicsPath())
                    {
                        switch (e.LocalName)
                        {
                            case "rect":
                                float x = N(e, "x", 0), y = N(e, "y", 0), w = N(e, "width", 0), h = N(e, "height", 0), r = N(e, "rx", 0);
                                if (r == 0) path.AddRectangle(new RectangleF(x, y, w, h));
                                else { float d = r * 2; path.AddArc(x, y, d, d, 180, 90); path.AddArc(x + w - d, y, d, d, 270, 90); path.AddArc(x + w - d, y + h - d, d, d, 0, 90); path.AddArc(x, y + h - d, d, d, 90, 90); path.CloseFigure(); } break;
                            case "circle": float radius = N(e, "r", 0); path.AddEllipse(N(e, "cx", 0) - radius, N(e, "cy", 0) - radius, radius * 2, radius * 2); break;
                            case "line": path.AddLine(N(e, "x1", 0), N(e, "y1", 0), N(e, "x2", 0), N(e, "y2", 0)); break;
                            case "path": ReadPath(path, e.GetAttribute("d")); break;
                            default: throw new IOException("Unsupported SVG primitive: " + e.LocalName);
                        }
                        string fill = e.HasAttribute("fill") ? e.GetAttribute("fill") : root.GetAttribute("fill");
                        string stroke = e.HasAttribute("stroke") ? e.GetAttribute("stroke") : root.GetAttribute("stroke");
                        if (!String.IsNullOrEmpty(fill) && fill != "none") using (var brush = new SolidBrush(Paint(fill, ink))) g.FillPath(brush, path);
                        if (!String.IsNullOrEmpty(stroke) && stroke != "none") using (var pen = new Pen(Paint(stroke, ink), N(e, "stroke-width", N(root, "stroke-width", 1.8F))))
                        { pen.StartCap = LineCap.Round; pen.EndCap = LineCap.Round; pen.LineJoin = LineJoin.Round; g.DrawPath(pen, path); }
                    }
                }
            }
            return bitmap;
        }
        static void ReadPath(GraphicsPath path, string source)
        {
            var tokens = Regex.Matches(source, "[A-Za-z]|[-+]?[0-9]*\\.?[0-9]+");
            int i = 0; char command = ' '; PointF current = PointF.Empty;
            Func<float> number = () => Single.Parse(tokens[i++].Value, CultureInfo.InvariantCulture);
            while (i < tokens.Count)
            {
                if (Char.IsLetter(tokens[i].Value[0])) command = tokens[i++].Value[0];
                if (command == 'Z') { path.CloseFigure(); command = ' '; continue; }
                if (command == 'M') { current = new PointF(number(), number()); path.StartFigure(); command = 'L'; }
                else if (command == 'L') { var end = new PointF(number(), number()); path.AddLine(current, end); current = end; }
                else if (command == 'C') { var a = new PointF(number(), number()); var b = new PointF(number(), number()); var end = new PointF(number(), number()); path.AddBezier(current, a, b, end); current = end; }
                else throw new IOException("Unsupported SVG path command: " + command);
            }
        }
        internal static void Verify()
        {
            foreach (ProductScene scene in Enum.GetValues(typeof(ProductScene)))
                using (var artwork = new Bitmap(SceneImage(scene)))
                    if (artwork.GetPixel(0, 0).A != 0) throw new IOException("The illustration does not preserve a transparent background: " + scene);
            for (int scenario = 0; scenario < ScenarioArt.Length; scenario++)
                using (var artwork = new Bitmap(ScenarioArt[scenario]))
                    if (artwork.GetPixel(0, 0).A != 0) throw new IOException("The scenario illustration does not preserve a transparent background: " + scenario);
            foreach (string name in new[] { "home", "settings", "activity", "focus", "present", "download", "monitor", "lock", "timer", "play", "stop", "refresh", "tray", "check", "shield", "copy", "sparkle" })
                using (var bitmap = Render(name, 48, Color.FromArgb(1, 135, 95)))
                {
                    int painted = 0;
                    for (int y = 0; y < bitmap.Height; y++) for (int x = 0; x < bitmap.Width; x++) if (bitmap.GetPixel(x, y).A > 0) painted++;
                    if (painted < 20) throw new IOException("Empty SVG output: " + name);
                }
        }
    }
    class GlyphView : Control
    {
        internal string IconName;
        internal Color Ink;
        internal GlyphView() { SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor, true); }
        protected override void OnPaint(PaintEventArgs e) { Artwork.Draw(e.Graphics, IconName, new Rectangle(0, 0, Math.Min(Width, Height), Math.Min(Width, Height)), Ink); }
    }
    class ScenarioTile : Pill
    {
        readonly System.Windows.Forms.Timer hoverAnimation = new System.Windows.Forms.Timer { Interval = 30 };
        float hover, hoverTarget;
        internal ScenarioTile()
        {
            hoverAnimation.Tick += delegate
            {
                hover += (hoverTarget - hover) * .28F; Invalidate();
                if (!Visible || Math.Abs(hoverTarget - hover) < .02F) { hover = hoverTarget; hoverAnimation.Stop(); }
            };
        }
        void AnimateHover(float target)
        { hoverTarget = target; if (SystemInformation.UIEffectsEnabled && Visible) hoverAnimation.Start(); else { hover = target; Invalidate(); } }
        protected override void OnMouseEnter(EventArgs e) { base.OnMouseEnter(e); if (Enabled) AnimateHover(1); }
        protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); AnimateHover(0); }
        protected override void Dispose(bool disposing) { if (disposing) hoverAnimation.Dispose(); base.Dispose(disposing); }
        internal string Description;
        internal int ScenarioIndex;
        internal string IconName;
        internal Color Accent;
        internal Color Surface;
        internal float IconScale = 1;
        protected override void OnPaint(PaintEventArgs e)
        {
            OnPaintBackground(e);
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (var path = Card.Shape(new Rectangle(1, 1, Width - 3, Height - 3), (int)(18 * IconScale)))
            {
                Color surface = Selected ? Color.FromArgb(239, 249, 243) : Color.White;
                if (Enabled && ClientRectangle.Contains(PointToClient(Cursor.Position))) surface = Color.FromArgb(232, 244, 236);
                using (var brush = new LinearGradientBrush(ClientRectangle, surface, Selected ? Color.FromArgb(225, 242, 232) : Color.FromArgb(248, 250, 249), 70F)) e.Graphics.FillPath(brush, path);
                using (var pen = new Pen(Selected ? Color.FromArgb(1, 135, 95) : Color.FromArgb(226, 230, 227), Selected ? 2 * IconScale : IconScale)) e.Graphics.DrawPath(pen, path);
            }
            if (Width / IconScale >= 180) Artwork.DrawScenario(e.Graphics, ScenarioIndex, new Rectangle(Width - (int)(135 * IconScale), (int)(8 * IconScale), (int)(96 * IconScale), (int)(76 * IconScale)));
            Rectangle badge = new Rectangle((int)(18 * IconScale), (int)((16 - hover * 3) * IconScale), (int)(58 * IconScale), (int)(58 * IconScale));
            using (var path = Card.Shape(badge, (int)(16 * IconScale))) using (var brush = new SolidBrush(Surface)) e.Graphics.FillPath(brush, path);
            Artwork.Draw(e.Graphics, IconName, new Rectangle(badge.X + (int)(8 * IconScale), badge.Y + (int)(8 * IconScale), (int)(42 * IconScale), (int)(42 * IconScale)), Accent);
            using (var titleFont = new Font(Font.FontFamily, 11F)) TextRenderer.DrawText(e.Graphics, Text, titleFont, new Rectangle((int)(18 * IconScale), (int)(80 * IconScale), Width - (int)(28 * IconScale), (int)(25 * IconScale)), Color.FromArgb(32, 33, 36), TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
            TextRenderer.DrawText(e.Graphics, Description, Font, new Rectangle((int)(18 * IconScale), (int)(105 * IconScale), Width - (int)(28 * IconScale), (int)(23 * IconScale)), Color.FromArgb(95, 99, 104), TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
            if (Selected) Artwork.Draw(e.Graphics, "check", new Rectangle(Width - (int)(39 * IconScale), (int)(18 * IconScale), (int)(23 * IconScale), (int)(23 * IconScale)), Color.FromArgb(1, 135, 95));
            if (Focused) ControlPaint.DrawFocusRectangle(e.Graphics, new Rectangle(7, 7, Width - 14, Height - 14));
        }
    }
    class SwitchOption : CheckBox
    {
        internal string Glyph;
        internal float IconScale = 1;
        internal SwitchOption()
        {
            AutoSize = false; Cursor = Cursors.Hand;
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor, true);
            BackColor = Color.Transparent; UseVisualStyleBackColor = false;
        }
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
        protected override void OnPaint(PaintEventArgs e)
        {
            OnPaintBackground(e);
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Artwork.Draw(e.Graphics, Glyph, new Rectangle(0, (Height - (int)(25 * IconScale)) / 2, (int)(25 * IconScale), (int)(25 * IconScale)), Color.FromArgb(70, 91, 80));
            TextRenderer.DrawText(e.Graphics, Text, Font, new Rectangle((int)(38 * IconScale), 0, Width - (int)(100 * IconScale), Height), ForeColor, TextFormatFlags.Left | TextFormatFlags.VerticalCenter);
            Rectangle track = new Rectangle(Width - (int)(48 * IconScale), (Height - (int)(25 * IconScale)) / 2, (int)(44 * IconScale), (int)(25 * IconScale));
            using (var path = Card.Shape(track, track.Height / 2)) using (var brush = new SolidBrush(Checked ? Color.FromArgb(1, 135, 95) : Color.FromArgb(218, 224, 219))) e.Graphics.FillPath(brush, path);
            using (var brush = new SolidBrush(Color.White)) e.Graphics.FillEllipse(brush, Checked ? track.Right - 22 * IconScale : track.Left + 3 * IconScale, track.Top + 3 * IconScale, 19 * IconScale, 19 * IconScale);
            if (Focused) ControlPaint.DrawFocusRectangle(e.Graphics, new Rectangle(3, 3, Width - 6, Height - 6));
        }
        protected override void OnCheckedChanged(EventArgs e) { base.OnCheckedChanged(e); Invalidate(); }
    }
}
