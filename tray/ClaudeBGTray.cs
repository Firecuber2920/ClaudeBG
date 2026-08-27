// ClaudeBGTray - system tray front-end for ClaudeBG.ps1
//
// Builds with the .NET Framework 4.8 compiler that ships with Windows:
//   C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe
// so it needs no SDK install and produces a single self-contained .exe.
//
// All the real work lives in ClaudeBG.ps1 (kept next to this .exe). The tray is
// deliberately thin: pick an image, set opacity, re-patch after a Claude update.

using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;

static class Program
{
    static NotifyIcon Tray;
    static Control Sync;               // invoke target - see EnsureSync()
    static double CurrentOpacity = 0.35;
    static readonly string DataDir    = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ClaudeBG");
    static readonly string ConfigPath = Path.Combine(DataDir, "config.json");
    static readonly string ScriptPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "ClaudeBG.ps1");
    static bool Busy = false;

    [DllImport("user32.dll", SetLastError = true)]
    static extern bool DestroyIcon(IntPtr handle);

    [STAThread]
    static void Main()
    {
        // One tray icon per machine; a second launch would otherwise stack a
        // duplicate icon that fights the first one over the same config file.
        bool isFirst;
        using (var mutex = new Mutex(true, "Local\\ClaudeBGTray", out isFirst))
        {
            if (!isFirst)
            {
                MessageBox.Show("ClaudeBG is already running - look for its icon in the notification area "
                              + "(click the ^ arrow next to the clock if you don't see it).",
                    "ClaudeBG", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            Run();
        }
    }

    static void Run()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        // Without these the tray icon simply disappears on any unhandled error,
        // leaving no window, no message and nothing in the notification area.
        Application.ThreadException += (s, e) => Fatal(e.Exception);
        AppDomain.CurrentDomain.UnhandledException += (s, e) => Fatal(e.ExceptionObject as Exception);

        if (!File.Exists(ScriptPath))
        {
            MessageBox.Show("ClaudeBG.ps1 was not found next to this executable.\n\nExpected at:\n" + ScriptPath,
                "ClaudeBG", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        LoadOpacity();
        EnsureSync();

        Tray = new NotifyIcon();
        Tray.Icon = MakeIcon();
        Tray.Text = "ClaudeBG";
        Tray.ContextMenuStrip = BuildMenu();
        Tray.DoubleClick += (s, e) => ChooseImage();
        Tray.Visible = true;

        Tray.BalloonTipTitle = "ClaudeBG";
        Tray.BalloonTipText  = "Running in the notification area. Right-click the icon to change your background.";
        Tray.ShowBalloonTip(3000);

        Application.Run();

        Tray.Visible = false;
        Tray.Dispose();
    }

    // A NotifyIcon is not a Control, so background work has nothing to marshal
    // back onto. The old code used Tray.ContextMenuStrip, whose window handle
    // only exists while the menu is open - invoking through it after the menu
    // had closed (or before it was ever opened) threw on the worker thread and
    // killed the whole tray app. This control is created once, on the UI thread,
    // and its handle lives for the life of the process.
    static void EnsureSync()
    {
        Sync = new Control();
        IntPtr force = Sync.Handle;
        GC.KeepAlive(force);
    }

    static void Fatal(Exception ex)
    {
        try
        {
            MessageBox.Show("ClaudeBG hit an unexpected error and will keep running if it can:\n\n"
                          + (ex == null ? "(unknown)" : ex.ToString()),
                "ClaudeBG", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
        catch { }
    }

    // Draw the tray icon at runtime so there's no separate asset file to ship.
    static Icon MakeIcon()
    {
        using (var bmp = new Bitmap(32, 32))
        {
            using (var g = Graphics.FromImage(bmp))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                var rect = new Rectangle(2, 2, 28, 28);
                using (var brush = new LinearGradientBrush(rect, Color.FromArgb(150, 60, 200), Color.FromArgb(255, 130, 60), 45f))
                    g.FillEllipse(brush, rect);
                using (var pen = new Pen(Color.FromArgb(230, 255, 255, 255), 2f))
                    g.DrawEllipse(pen, rect);
            }
            // GetHicon hands back a handle we own; clone into a managed Icon and
            // release it rather than leaking the HICON for the whole session.
            IntPtr h = bmp.GetHicon();
            try
            {
                using (var tmp = Icon.FromHandle(h)) return (Icon)tmp.Clone();
            }
            finally { DestroyIcon(h); }
        }
    }

    static ContextMenuStrip BuildMenu()
    {
        var menu = new ContextMenuStrip();

        var change = new ToolStripMenuItem("Change background...");
        change.Font = new Font(menu.Font, FontStyle.Bold);
        change.Click += (s, e) => ChooseImage();
        menu.Items.Add(change);

        var opacity = new ToolStripMenuItem("Opacity");
        foreach (var v in new[] { 0.15, 0.25, 0.35, 0.50, 0.65 })
        {
            double val = v;
            var item = new ToolStripMenuItem(((int)Math.Round(val * 100)) + "%");
            item.Checked = Math.Abs(val - CurrentOpacity) < 0.001;
            item.Click += (s, e) => SetOpacity(val, opacity);
            opacity.DropDownItems.Add(item);
        }
        menu.Items.Add(opacity);

        menu.Items.Add(new ToolStripSeparator());

        var repatch = new ToolStripMenuItem("Reapply patch (after a Claude update)");
        repatch.Click += (s, e) => RunScript("-Patch", "Patch reapplied. Claude Desktop restarted.");
        menu.Items.Add(repatch);

        var restore = new ToolStripMenuItem("Restore original Claude");
        restore.Click += (s, e) =>
        {
            var answer = MessageBox.Show(
                "This removes the background, restores the original claude.exe (signature and integrity fuse back) and the original app.asar.\n\nContinue?",
                "ClaudeBG", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            if (answer == DialogResult.Yes) RunScript("-Restore", "Original Claude Desktop restored.");
        };
        menu.Items.Add(restore);

        var status = new ToolStripMenuItem("Status...");
        status.Click += (s, e) => ShowStatus();
        menu.Items.Add(status);

        menu.Items.Add(new ToolStripSeparator());

        var exit = new ToolStripMenuItem("Exit");
        exit.Click += (s, e) => Application.Exit();
        menu.Items.Add(exit);

        return menu;
    }

    static void ChooseImage()
    {
        if (Busy) { Notify("Still working on the last request..."); return; }
        using (var dlg = new OpenFileDialog())
        {
            dlg.Title = "Pick a background image";
            dlg.Filter = "Images|*.png;*.jpg;*.jpeg;*.bmp;*.gif|All files|*.*";
            dlg.InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.MyPictures);
            if (dlg.ShowDialog() != DialogResult.OK) return;

            string op = CurrentOpacity.ToString(CultureInfo.InvariantCulture);
            RunScript("-SetImage \"" + dlg.FileName + "\" -Opacity " + op,
                      "Background updated: " + Path.GetFileName(dlg.FileName));
        }
    }

    static void SetOpacity(double value, ToolStripMenuItem parent)
    {
        CurrentOpacity = value;
        foreach (ToolStripMenuItem item in parent.DropDownItems)
            item.Checked = item.Text == ((int)Math.Round(value * 100)) + "%";

        // -SetOpacity only rewrites config.json. It used to re-run -SetImage
        // against current.png, which made GDI+ decode and re-encode a file it
        // had just locked - every opacity change failed with "A generic error
        // occurred in GDI+".
        RunScript("-SetOpacity " + value.ToString(CultureInfo.InvariantCulture),
                  "Opacity set to " + ((int)Math.Round(value * 100)) + "%.");
    }

    static void LoadOpacity()
    {
        try
        {
            if (!File.Exists(ConfigPath)) return;
            var m = Regex.Match(File.ReadAllText(ConfigPath), "\"opacity\"\\s*:\\s*([0-9.]+)");
            if (m.Success)
            {
                double parsed;
                if (double.TryParse(m.Groups[1].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out parsed))
                    CurrentOpacity = parsed;
            }
        }
        catch { /* a missing or malformed config just means defaults */ }
    }

    // Patching closes and relaunches Claude Desktop and can take ~a minute, so it
    // runs off the UI thread and reports back with a balloon tip.
    static void RunScript(string args, string successMessage)
    {
        if (Busy) { Notify("Still working on the last request..."); return; }
        Busy = true;
        Tray.Text = "ClaudeBG (working...)";

        var worker = new Thread(() =>
        {
            string output = "";
            int exitCode = -1;
            try
            {
                var psi = new ProcessStartInfo
                {
                    FileName = "powershell.exe",
                    Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + ScriptPath + "\" " + args,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                };
                using (var p = Process.Start(psi))
                {
                    output = p.StandardOutput.ReadToEnd() + p.StandardError.ReadToEnd();
                    p.WaitForExit();
                    exitCode = p.ExitCode;
                }
            }
            catch (Exception ex) { output = ex.Message; }

            int code = exitCode;
            string text = output;
            try
            {
                Sync.BeginInvoke((MethodInvoker)(() =>
                {
                    Busy = false;
                    Tray.Text = "ClaudeBG";
                    if (code == 0) Notify(successMessage);
                    else MessageBox.Show("Something went wrong:\n\n" + text, "ClaudeBG",
                                         MessageBoxButtons.OK, MessageBoxIcon.Error);
                }));
            }
            catch (Exception) { Busy = false; }   // shutting down; never take the tray with us
        });
        worker.IsBackground = true;
        worker.Start();
    }

    static void ShowStatus()
    {
        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = "-NoProfile -ExecutionPolicy Bypass -NoExit -File \"" + ScriptPath + "\" -Status",
            UseShellExecute = true
        };
        Process.Start(psi);
    }

    static void Notify(string message)
    {
        Tray.BalloonTipTitle = "ClaudeBG";
        Tray.BalloonTipText = message;
        Tray.ShowBalloonTip(3000);
    }
}
