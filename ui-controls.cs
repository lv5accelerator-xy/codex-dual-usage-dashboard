using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace CodexUsage {
    public static class NativeDisplay {
        [DllImport("user32.dll")] private static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")] private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
        public static void EnableDpi() {
            try { if (SetThreadDpiAwarenessContext(new IntPtr(-4)) != IntPtr.Zero) return; } catch (EntryPointNotFoundException) { }
            try { SetProcessDPIAware(); } catch { }
        }
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

    public class FloatingForm : DpiForm {
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

    // Native window integration shared by script and packaged UI.
    public static class DesktopIntegration {
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern IntPtr GetShellWindow();
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr handle, out RECT rect);
        [DllImport("user32.dll")] static extern bool IsIconic(IntPtr handle);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr handle, System.Text.StringBuilder name, int count);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr handle, out uint pid);
        [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
        public static bool IsFullScreen(Rectangle window, Rectangle monitor) {
            return window.Left <= monitor.Left && window.Top <= monitor.Top && window.Right >= monitor.Right && window.Bottom >= monitor.Bottom;
        }
        public static bool FullScreenOn(Form form) {
            IntPtr foreground = GetForegroundWindow();
            if (foreground == IntPtr.Zero || foreground == GetShellWindow() || IsIconic(foreground)) return false;
            uint pid; GetWindowThreadProcessId(foreground, out pid);
            if (pid == System.Diagnostics.Process.GetCurrentProcess().Id) return false;
            var name = new System.Text.StringBuilder(256); GetClassName(foreground, name, 256);
            if (name.ToString() == "Progman" || name.ToString() == "WorkerW") return false;
            RECT rect; if (!GetWindowRect(foreground, out rect)) return false;
            return IsFullScreen(Rectangle.FromLTRB(rect.Left, rect.Top, rect.Right, rect.Bottom), Screen.FromControl(form).Bounds);
        }
        public static Rectangle Clamp(Rectangle window, Rectangle area) {
            int width = Math.Min(window.Width, area.Width), height = Math.Min(window.Height, area.Height);
            return new Rectangle(Math.Max(area.Left, Math.Min(window.X, area.Right - width)), Math.Max(area.Top, Math.Min(window.Y, area.Bottom - height)), width, height);
        }
        public static void KeepVisible(Form form) {
            var area = Screen.FromRectangle(form.Bounds).WorkingArea;
            var bounds = Clamp(form.Bounds, area);
            if (form.Bounds != bounds) form.Bounds = bounds;
        }
        public static string StartupCommand(string exe) {
            if (exe.IndexOf('"') >= 0 || !System.IO.Path.IsPathRooted(exe)) throw new ArgumentException("Invalid executable path.");
            return "\"" + exe + "\"";
        }
        public static bool IsStartupEnabled(string exe) {
            using (var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"))
                return key != null && string.Equals(key.GetValue("CodexUsage") as string, StartupCommand(exe), StringComparison.OrdinalIgnoreCase);
        }
        public static void SetStartup(string exe, bool enabled) {
            using (var key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run")) {
                if (enabled) key.SetValue("CodexUsage", StartupCommand(exe));
                else key.DeleteValue("CodexUsage", false);
            }
        }
    }

    public class DpiForm : Form {
        public int DisplayDpi { get; set; }
        public event EventHandler ScaleChanged;
        public DpiForm() { DisplayDpi = 96; AutoScaleMode = AutoScaleMode.None; }
        static Padding ResizePadding(Padding p, float factor) { return new Padding((int)Math.Round(p.Left * factor), (int)Math.Round(p.Top * factor), (int)Math.Round(p.Right * factor), (int)Math.Round(p.Bottom * factor)); }
        readonly System.Collections.Generic.List<Font> dpiFonts = new System.Collections.Generic.List<Font>();
        void ScaleTree(Control control, float factor) {
            control.SuspendLayout();
            try {
                foreach (Control child in control.Controls) ScaleTree(child, factor);
                control.Bounds = new Rectangle((int)Math.Round(control.Left * factor), (int)Math.Round(control.Top * factor), (int)Math.Round(control.Width * factor), (int)Math.Round(control.Height * factor));
                control.Padding = ResizePadding(control.Padding, factor);
                control.Margin = ResizePadding(control.Margin, factor);
                var font = new Font(control.Font.FontFamily, control.Font.Size * factor, control.Font.Style, control.Font.Unit);
                dpiFonts.Add(font);
                control.Font = font;
                var table = control as TableLayoutPanel;
                if (table != null) {
                    foreach (RowStyle row in table.RowStyles) if (row.SizeType == SizeType.Absolute) row.Height *= factor;
                    foreach (ColumnStyle column in table.ColumnStyles) if (column.SizeType == SizeType.Absolute) column.Width *= factor;
                }
            } finally { control.ResumeLayout(false); }
        }
        public void ApplyDpi(int dpi, Rectangle suggested) {
            if (dpi < 48 || dpi > 768) return;
            float factor = (float)dpi / Math.Max(48, DisplayDpi);
            SuspendLayout();
            try {
                foreach (Control child in Controls) ScaleTree(child, factor);
                Padding = ResizePadding(Padding, factor);
                MinimumSize = new Size((int)Math.Round(MinimumSize.Width * factor), (int)Math.Round(MinimumSize.Height * factor));
                DisplayDpi = dpi;
                Bounds = suggested;
                PerformLayout();
            } finally { ResumeLayout(true); }
            if (ScaleChanged != null) ScaleChanged(this, EventArgs.Empty);
            Invalidate(true);
        }
        protected override void Dispose(bool disposing) {
            base.Dispose(disposing);
            if (disposing) { foreach (var font in dpiFonts) font.Dispose(); dpiFonts.Clear(); }
        }
        protected override void WndProc(ref Message message) {
            if (message.Msg == 0x02E0) { // WM_DPICHANGED, per-window suggested physical bounds.
                var rect = (DesktopIntegration.RECT)Marshal.PtrToStructure(message.LParam, typeof(DesktopIntegration.RECT));
                ApplyDpi((int)(message.WParam.ToInt64() & 0xffff), Rectangle.FromLTRB(rect.Left, rect.Top, rect.Right, rect.Bottom));
                message.Result = IntPtr.Zero;
                return;
            }
            base.WndProc(ref message);
        }
    }

    public sealed class SplitQuotaLabel : Control {
        public string AccountName { get; set; }
        public string FiveText { get; set; }
        public string LongText { get; set; }
        public Color FiveColor { get; set; }
        public Color LongColor { get; set; }
        public SplitQuotaLabel() { DoubleBuffered = true; ResizeRedraw = true; AccountName = ""; FiveText = LongText = "—"; FiveColor = LongColor = Color.White; }
        protected override void OnPaint(PaintEventArgs e) {
            base.OnPaint(e);
            var flags = TextFormatFlags.VerticalCenter | TextFormatFlags.HorizontalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix;
            int nameWidth = Width * 32 / 100, valueWidth = (Width - nameWidth - 10) / 2;
            TextRenderer.DrawText(e.Graphics, AccountName, Font, new Rectangle(0, 0, nameWidth, Height), ForeColor, flags);
            TextRenderer.DrawText(e.Graphics, FiveText, Font, new Rectangle(nameWidth, 0, valueWidth, Height), FiveColor, flags);
            TextRenderer.DrawText(e.Graphics, "/", Font, new Rectangle(nameWidth + valueWidth, 0, 10, Height), Color.Gray, flags);
            TextRenderer.DrawText(e.Graphics, LongText, Font, new Rectangle(nameWidth + valueWidth + 10, 0, valueWidth, Height), LongColor, flags);
        }
    }
}
