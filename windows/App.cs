using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows;
using System.Windows.Threading;
using Microsoft.Win32;
using SD = System.Drawing;
using WF = System.Windows.Forms;

namespace Satsuma;

static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        if (args.Contains("--selftest")) { AttachConsole(-1); return SelfTest.Run(); }
        if (args.FirstOrDefault() == "--shots") { SelfTest.Shots(args[1]); return 0; }

        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        // "Send To → Satsuma" launches us with the files; show the menu, run the job, exit.
        if (args.FirstOrDefault() == "--pick")
        {
            var files = args.Skip(1).Where(f => File.Exists(f) || Directory.Exists(f)).ToList();
            if (files.Count == 0) return 0;
            var picker = new Controller(tray: false);
            app.Startup += (_, _) => picker.ShowPickMenu(files, exitWhenDone: true);
            app.Run();
            return 0;
        }

        using var mutex = new Mutex(true, "Satsuma.Tray", out bool first);
        if (!first)
        {
            MessageBox.Show("Satsuma is already running. Look for the orange icon in the system tray (bottom right, maybe under ^).", "Satsuma");
            return 0;
        }
        var controller = new Controller(tray: true);
        app.Run();
        GC.KeepAlive(controller);
        return 0;
    }

    [DllImport("kernel32.dll")] static extern bool AttachConsole(int pid);
}

class Controller
{
    readonly WheelWindow wheel = new();
    readonly Hud hud = new();
    readonly WF.NotifyIcon tray;
    bool wasDown, moved, lastShift, lastCtrl, lastAlt;
    POINT start;

    public Controller(bool tray)
    {
        wheel.OnPick = (op, files, mode) => Perform(op, files, mode);
        if (!tray) return;

        var menu = new WF.ContextMenuStrip();
        menu.Opening += (_, _) => BuildMenu(menu);
        this.tray = new WF.NotifyIcon
        {
            Icon = SD.Icon.ExtractAssociatedIcon(Environment.ProcessPath),
            Text = "Satsuma: drag a file, tap Shift / Ctrl / Alt",
            ContextMenuStrip = menu,
            Visible = true,
        };
        // Left-click opens the same menu as right-click.
        this.tray.MouseUp += (_, e) =>
        {
            if (e.Button == WF.MouseButtons.Left)
                typeof(WF.NotifyIcon).GetMethod("ShowContextMenu", BindingFlags.Instance | BindingFlags.NonPublic)?.Invoke(this.tray, null);
        };
        Application.Current.Exit += (_, _) => this.tray.Visible = false;

        var settings = Registry.CurrentUser.CreateSubKey(@"Software\Satsuma");
        if (settings.GetValue("Welcomed") == null)
        {
            this.tray.ShowBalloonTip(8000, "Satsuma is running",
                "Drag any file, then tap Shift (convert), Ctrl (tools) or Alt (actions) without letting go.", WF.ToolTipIcon.Info);
            settings.SetValue("Welcomed", 1);
        }

        // ponytail: polls mouse and modifier state at 30 Hz instead of installing a global hook.
        // Any drag counts, so tapping Shift while dragging a window shows an empty wheel until release.
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(33) };
        timer.Tick += (_, _) => Tick();
        timer.Start();
    }

    void Tick()
    {
        bool Down(int vk) => (GetAsyncKeyState(vk) & 0x8000) != 0;
        bool down = Down(GetSystemMetrics(23) != 0 ? 0x02 : 0x01);  // honour swapped mouse buttons
        GetCursorPos(out var pos);
        if (down && !wasDown) { start = pos; moved = false; }
        if (down && Math.Abs(pos.X - start.X) + Math.Abs(pos.Y - start.Y) > 10) moved = true;
        if (!down && wasDown && wheel.IsVisible) After(300, () => { if (!Down(0x01) && !Down(0x02)) wheel.Hide(); });
        wasDown = down;

        bool shift = Down(0x10), ctrl = Down(0x11), alt = Down(0x12);
        bool pShift = shift && !lastShift, pCtrl = ctrl && !lastCtrl, pAlt = alt && !lastAlt;
        (lastShift, lastCtrl, lastAlt) = (shift, ctrl, alt);
        if (!down || !moved) return;

        // Only a key tapped mid-drag opens the wheel, so Ctrl-dragging to copy still works normally.
        Mode? mode = pShift ? Mode.Convert : pCtrl ? Mode.Tools : pAlt ? Mode.Actions : null;
        if (mode is Mode m && (!wheel.IsVisible || wheel.Mode != m))
        {
            double scale = GetDpiForSystem() / 96.0;
            wheel.ShowAt(m, null, new Point(pos.X / scale, pos.Y / scale));
        }
    }

    static void After(int ms, Action a)
    {
        var t = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(ms) };
        t.Tick += (_, _) => { t.Stop(); a(); };
        t.Start();
    }

    public void Perform(Op op, List<string> files, Mode mode, Action done = null)
    {
        if (op.OnUiThread)
        {
            try { Reveal(op.Run(files)); } catch (Exception e) { Error(op.Title, e); }
            done?.Invoke();
            return;
        }
        hud.Start($"{op.Title}: {(files.Count == 1 ? Path.GetFileName(files[0]) : $"{files.Count} files")}");
        var worker = new Thread(() =>
        {
            List<string> outs = null;
            Exception err = null;
            try { outs = op.Run(files); } catch (Exception e) { err = e; }
            Application.Current.Dispatcher.Invoke(() =>
            {
                hud.Finish();
                if (err != null) Error(op.Title, err); else Reveal(outs);
                done?.Invoke();
            });
        }) { IsBackground = true };
        worker.SetApartmentState(ApartmentState.STA);  // WPF imaging and RTF need STA
        worker.Start();
    }

    static void Reveal(List<string> outs)
    {
        if (outs.Count > 0) Process.Start("explorer.exe", $"/select,\"{outs[0]}\"");
    }

    static void Error(string title, Exception e)
    {
        while (e is AggregateException or TargetInvocationException && e.InnerException != null) e = e.InnerException;
        MessageBox.Show(e.Message, $"{title} failed", MessageBoxButton.OK, MessageBoxImage.Warning);
    }

    void BuildMenu(WF.ContextMenuStrip menu)
    {
        menu.Items.Clear();
        menu.Items.Add(new WF.ToolStripMenuItem("Drag a file, then tap Shift · Ctrl · Alt") { Enabled = false });
        menu.Items.Add("Choose Files…", null, (_, _) => ChooseFiles());
        menu.Items.Add(new WF.ToolStripSeparator());

        var themes = new WF.ToolStripMenuItem("Theme");
        foreach (var t in Theme.All)
        {
            var item = new WF.ToolStripMenuItem(t.Name + (t.IsGlass ? "" : " (solid)"), Swatch(t.Accent), (_, _) => { Theme.Current = t; Preview(); })
            { Checked = t.Name == Theme.Current.Name };
            themes.DropDownItems.Add(item);
        }
        menu.Items.Add(themes);
        menu.Items.Add("Preview Wheel", null, (_, _) => Preview());
        menu.Items.Add(new WF.ToolStripMenuItem("Click Sound on Hover", null, (_, _) => { Click.Enabled = !Click.Enabled; Click.Play(); })
            { Checked = Click.Enabled });
        menu.Items.Add(new WF.ToolStripSeparator());

        foreach (var (name, path, id) in new[] { ("ffmpeg", Shell.FFmpeg, "Gyan.FFmpeg"), ("pandoc", Shell.Pandoc, "JohnMacFarlane.Pandoc") })
        {
            if (path != null) menu.Items.Add(new WF.ToolStripMenuItem($"{name} found ✓") { Enabled = false });
            else menu.Items.Add($"Install {name} for more formats…", null, (_, _) =>
                Process.Start(new ProcessStartInfo("powershell.exe", $"-NoExit -Command winget install -e --id {id}") { UseShellExecute = true }));
        }
        menu.Items.Add(new WF.ToolStripSeparator());

        var sendTo = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.SendTo), "Satsuma.lnk");
        menu.Items.Add(new WF.ToolStripMenuItem("Show in Send To menu", null, (_, _) => ToggleSendTo(sendTo)) { Checked = File.Exists(sendTo) });
        var run = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true);
        menu.Items.Add(new WF.ToolStripMenuItem("Start with Windows", null, (_, _) =>
        {
            if (run.GetValue("Satsuma") != null) run.DeleteValue("Satsuma");
            else run.SetValue("Satsuma", $"\"{Environment.ProcessPath}\"");
        }) { Checked = run.GetValue("Satsuma") != null });
        menu.Items.Add("Quit Satsuma", null, (_, _) => Application.Current.Shutdown());
    }

    static SD.Bitmap Swatch(System.Windows.Media.Color c)
    {
        var bmp = new SD.Bitmap(14, 14);
        using var g = SD.Graphics.FromImage(bmp);
        g.SmoothingMode = SD.Drawing2D.SmoothingMode.AntiAlias;
        using var brush = new SD.SolidBrush(SD.Color.FromArgb(c.R, c.G, c.B));
        g.FillEllipse(brush, 1, 1, 12, 12);
        return bmp;
    }

    static void ToggleSendTo(string lnk)
    {
        if (File.Exists(lnk)) { File.Delete(lnk); return; }
        dynamic shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell"));
        dynamic shortcut = shell.CreateShortcut(lnk);
        shortcut.TargetPath = Environment.ProcessPath;
        shortcut.Arguments = "--pick";
        shortcut.Save();
    }

    /// <summary>Shows the wheel mid-screen for a moment, as if a photo were being dragged.</summary>
    void Preview()
    {
        var area = SystemParameters.WorkArea;
        wheel.ShowAt(Mode.Convert, new() { @"C:\Preview.jpg" }, new Point(area.Left + area.Width / 2, area.Top + area.Height / 2), previewHover: 1);
        After(2000, () => { if ((GetAsyncKeyState(0x01) & 0x8000) == 0) wheel.Hide(); });
    }

    void ChooseFiles()
    {
        using var dlg = new WF.OpenFileDialog { Multiselect = true, Title = "Choose files for Satsuma" };
        if (dlg.ShowDialog() == WF.DialogResult.OK) ShowPickMenu(dlg.FileNames.ToList(), exitWhenDone: false);
    }

    /// <summary>Click-based alternative to the drag wheel: Convert / Tools / Actions submenus at the pointer.</summary>
    public void ShowPickMenu(List<string> files, bool exitWhenDone)
    {
        var menu = new WF.ContextMenuStrip();
        foreach (var mode in new[] { Mode.Convert, Mode.Tools, Mode.Actions })
        {
            var parent = new WF.ToolStripMenuItem(mode.Title());
            foreach (var op in Catalog.Ops(mode, files))
                parent.DropDownItems.Add(op.Title, null, (_, _) => Perform(op, files, mode, exitWhenDone ? () => Application.Current.Shutdown() : null));
            parent.Enabled = parent.DropDownItems.Count > 0;
            menu.Items.Add(parent);
        }
        menu.Closed += (_, e) =>
        {
            if (exitWhenDone && e.CloseReason != WF.ToolStripDropDownCloseReason.ItemClicked) Application.Current.Shutdown();
        };
        menu.Show(WF.Cursor.Position);
    }

    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
    [DllImport("user32.dll")] static extern uint GetDpiForSystem();
}
