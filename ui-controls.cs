using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace CodexUsage {
    public static class NativeDisplay {
        [DllImport("user32.dll")] private static extern bool SetProcessDPIAware();
        public static void EnableDpi() { try { SetProcessDPIAware(); } catch { } }
    }

    public static class Shapes {
        public static GraphicsPath Round(RectangleF bounds, float radius) {
            var path = new GraphicsPath();
            float d = Math.Min(radius * 2, Math.Min(bounds.Width, bounds.Height));
            if (d <= 0) return path;
            path.AddArc(bounds.Left, bounds.Top, d, d, 180, 90);
            path.AddArc(bounds.Right - d, bounds.Top, d, d, 270, 90);
            path.AddArc(bounds.Right - d, bounds.Bottom - d, d, d, 0, 90);
            path.AddArc(bounds.Left, bounds.Bottom - d, d, d, 90, 90);
            path.CloseFigure();
            return path;
        }
    }

    public class Surface : Panel {
        public int Radius { get; set; }
        public Color BorderColor { get; set; }
        public Surface() {
            DoubleBuffered = true;
            ResizeRedraw = true;
            Radius = 12;
            BorderColor = Color.FromArgb(52, 55, 64);
        }
        protected override void OnPaint(PaintEventArgs e) {
            base.OnPaint(e);
            if (Width < 2 || Height < 2) return;
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (var path = Shapes.Round(new RectangleF(0.5f, 0.5f, Width - 1, Height - 1), Radius))
            using (var pen = new Pen(BorderColor)) e.Graphics.DrawPath(pen, path);
        }
        protected override void OnSizeChanged(EventArgs e) {
            base.OnSizeChanged(e);
            if (Width < 2 || Height < 2) return;
            using (var path = Shapes.Round(new RectangleF(0, 0, Width, Height), Radius)) {
                var old = Region;
                Region = new Region(path);
                if (old != null) old.Dispose();
            }
        }
    }

    public class FloatingForm : Form {
        public int Radius { get; set; }
        public FloatingForm() { DoubleBuffered = true; Radius = 16; }
        protected override void OnSizeChanged(EventArgs e) {
            base.OnSizeChanged(e);
            if (Width < 2 || Height < 2) return;
            using (var path = Shapes.Round(new RectangleF(0, 0, Width, Height), Radius)) {
                var old = Region;
                Region = new Region(path);
                if (old != null) old.Dispose();
            }
        }
        protected override void OnPaint(PaintEventArgs e) {
            base.OnPaint(e);
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (var path = Shapes.Round(new RectangleF(0.5f, 0.5f, Width - 1, Height - 1), Radius))
            using (var pen = new Pen(Color.FromArgb(65, 68, 78))) e.Graphics.DrawPath(pen, path);
        }
    }

    public class QuotaBar : Control {
        public double Value { get; set; }
        public Color FillColor { get; set; }
        public QuotaBar() {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            FillColor = Color.FromArgb(138, 158, 214);
        }
        protected override void OnPaint(PaintEventArgs e) {
            base.OnPaint(e);
            if (Width < 2 || Height < 2) return;
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (var path = Shapes.Round(new RectangleF(0, 0, Width, Height), Height / 2f)) {
                using (var track = new SolidBrush(Color.FromArgb(48, 51, 60))) e.Graphics.FillPath(track, path);
                var state = e.Graphics.Save();
                e.Graphics.SetClip(new RectangleF(0, 0, (float)(Width * Math.Max(0, Math.Min(100, Value)) / 100), Height));
                using (var fill = new SolidBrush(FillColor)) e.Graphics.FillPath(fill, path);
                e.Graphics.Restore(state);
            }
        }
    }
}
