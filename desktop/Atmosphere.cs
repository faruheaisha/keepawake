using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace KeepAwakeDesktop
{
    // Quiet background depth; all controls and text remain on opaque, readable surfaces.
    sealed class AtmospherePanel : Panel
    {
        internal AtmospherePanel() { DoubleBuffered = true; ResizeRedraw = true; }
        protected override void OnPaintBackground(PaintEventArgs e)
        {
            if (Width < 1 || Height < 1) return;
            using (var wash = new LinearGradientBrush(ClientRectangle, Color.FromArgb(246, 250, 247), Color.FromArgb(237, 245, 239), 40F)) e.Graphics.FillRectangle(wash, ClientRectangle);
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (var pen = new Pen(Color.FromArgb(30, 159, 194, 167), 1))
            {
                e.Graphics.DrawEllipse(pen, Width - 200, -180, 370, 370);
                e.Graphics.DrawEllipse(pen, Width - 163, -143, 296, 296);
            }
        }
    }

    sealed class DawnCard : Card
    {
        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (var path = Shape(new Rectangle(0, 0, Width - 1, Height - 1), Radius))
            using (var wash = new LinearGradientBrush(ClientRectangle, Color.FromArgb(228, 244, 233), Color.FromArgb(249, 246, 231), 12F))
            using (var edge = new Pen(Color.FromArgb(207, 230, 215)))
            { e.Graphics.FillPath(wash, path); e.Graphics.DrawPath(edge, path); }
            // Do not call Card.OnPaint: its flat fill would cover this surface.
        }
    }

    sealed class DawnIllustration : Control
    {
        readonly System.Windows.Forms.Timer animation = new System.Windows.Forms.Timer { Interval = 60 };
        readonly Stopwatch time = Stopwatch.StartNew();
        Bitmap preparedArtwork;
        double phase;
        ProductScene scene;
        internal ProductScene Scene
        {
            get { return scene; }
            set { if (scene == value) return; scene = value; if (preparedArtwork != null) { preparedArtwork.Dispose(); preparedArtwork = null; } Invalidate(); }
        }
        internal bool IsAnimating { get { return animation.Enabled; } }
        internal long FrameCount { get; private set; }
        internal DawnIllustration()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor, true);
            BackColor = Color.Transparent; TabStop = false; AccessibleRole = AccessibleRole.None;
            animation.Tick += delegate
            {
                var form = FindForm();
                if (!Visible || form == null || !form.Visible || !SystemInformation.UIEffectsEnabled) { animation.Stop(); return; }
                if (form.WindowState == FormWindowState.Minimized) return;
                phase = time.Elapsed.TotalSeconds; FrameCount++; Invalidate();
            };
        }
        protected override void OnVisibleChanged(EventArgs e)
        { base.OnVisibleChanged(e); RefreshMotion(); }
        protected override void OnParentChanged(EventArgs e)
        { base.OnParentChanged(e); RefreshMotion(); }
        protected override void OnHandleCreated(EventArgs e)
        { base.OnHandleCreated(e); RefreshMotion(); }
        void RefreshMotion()
        {
            if (animation == null) return;
            if (Visible && FindForm() != null && SystemInformation.UIEffectsEnabled) animation.Start(); else animation.Stop();
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaintBackground(e);
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            e.Graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
            float scale = Height / 164F;
            float drift = (float)Math.Sin(phase * .75) * 2 * scale;
            Image original = Artwork.SceneImage(Scene);
            int imageHeight = (int)(Height * .94F), imageWidth = (int)(imageHeight * original.Width / (float)original.Height);
            if (preparedArtwork == null || preparedArtwork.Width != imageWidth || preparedArtwork.Height != imageHeight)
            {
                if (preparedArtwork != null) preparedArtwork.Dispose();
                preparedArtwork = new Bitmap(imageWidth, imageHeight, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
                using (var raster = Graphics.FromImage(preparedArtwork))
                { raster.InterpolationMode = InterpolationMode.HighQualityBicubic; raster.DrawImage(original, new Rectangle(0, 0, imageWidth, imageHeight)); }
            }
            e.Graphics.DrawImageUnscaled(preparedArtwork, (Width - imageWidth) / 2, (int)((Height - imageHeight) / 2 + drift));
            // SVG glints float independently from the raster artwork, with no text underneath.
            int sparkle = Math.Max(12, (int)(18 * scale));
            Artwork.Draw(e.Graphics, "sparkle", new Rectangle((int)(Width * .78F), (int)(Height * .15F - drift), sparkle, sparkle), Color.FromArgb(185, 161, 126, 46));
            Artwork.Draw(e.Graphics, "sparkle", new Rectangle((int)(Width * .13F), (int)(Height * .59F + drift), sparkle * 2 / 3, sparkle * 2 / 3), Color.FromArgb(115, 1, 135, 95));
            if (Scene == ProductScene.Active)
            {
                float radius = (float)(4 + Math.Sin(phase * 1.4) * .8) * scale;
                using (var glow = new SolidBrush(Color.FromArgb(32, 1, 135, 95))) e.Graphics.FillEllipse(glow, Width * .88F - radius, Height * .72F - radius, radius * 2, radius * 2);
                using (var dot = new SolidBrush(Color.FromArgb(1, 135, 95))) e.Graphics.FillEllipse(dot, Width * .88F - 2 * scale, Height * .72F - 2 * scale, 4 * scale, 4 * scale);
            }
        }
        protected override void Dispose(bool disposing) { if (disposing) { animation.Dispose(); time.Stop(); if (preparedArtwork != null) preparedArtwork.Dispose(); } base.Dispose(disposing); }
    }
}
