using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using LlamaServer.Manager.Core.Config;
using LlamaServer.Manager.Core.Runtime;
using Microsoft.Win32;

namespace LlamaServer.Tray;

internal sealed class TrayApplicationContext : ApplicationContext
{
    private readonly NotifyIcon _tray;
    private readonly System.Windows.Forms.Timer _timer;
    private readonly HealthClient _health = new();
    private readonly ContextMenuStrip _menu;
    private readonly ToolStripMenuItem _statusItem;
    private readonly ToolStripMenuItem _modelsItem;
    private readonly ToolStripMenuItem _autostartItem;
    private ManagerSettings _settings;
    private LlamaServerPaths _paths;
    private NssmServiceHost _nssm = null!;
    private bool _apiOk;
    private string _statusText = "A verificar…";
    private Icon? _iconOnline;
    private Icon? _iconOffline;

    public TrayApplicationContext(string[] args)
    {
        _settings = ManagerSettings.Load();
        _paths = LlamaServerPaths.Detect(_settings.LlamaServerRoot);
        RebuildHosts();

        _iconOnline = MakeIcon(Color.FromArgb(45, 212, 191));
        _iconOffline = MakeIcon(Color.FromArgb(248, 113, 113));

        _statusItem = new ToolStripMenuItem("Estado: …") { Enabled = false };
        _modelsItem = new ToolStripMenuItem("Modelos: …") { Enabled = false };
        _autostartItem = new ToolStripMenuItem("Iniciar com o Windows", null, OnToggleAutostart)
        {
            Checked = IsAutostartEnabled() || _settings.StartTrayWithWindows,
        };

        _menu = new ContextMenuStrip();
        _menu.Items.Add(_statusItem);
        _menu.Items.Add(_modelsItem);
        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add("Abrir Manager", null, (_, _) => OpenManager());
        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add("Iniciar", null, async (_, _) => await ControlAsync("start"));
        _menu.Items.Add("Parar", null, async (_, _) => await ControlAsync("stop"));
        _menu.Items.Add("Reiniciar", null, async (_, _) => await ControlAsync("restart"));
        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add(_autostartItem);
        _menu.Items.Add("Sair", null, (_, _) => ExitThread());

        _tray = new NotifyIcon
        {
            Icon = _iconOffline,
            Text = "LlamaServer",
            Visible = true,
            ContextMenuStrip = _menu,
        };
        _tray.DoubleClick += (_, _) => OpenManager();

        _timer = new System.Windows.Forms.Timer { Interval = 5000 };
        _timer.Tick += async (_, _) => await RefreshAsync();
        _timer.Start();

        if (_autostartItem.Checked && !IsAutostartEnabled())
            SetAutostart(true);

        _ = RefreshAsync();

        if (args.Any(a => string.Equals(a, "--open-manager", StringComparison.OrdinalIgnoreCase)))
            OpenManager();
    }

    private void RebuildHosts()
    {
        _settings = ManagerSettings.Load();
        _paths = LlamaServerPaths.Detect(_settings.LlamaServerRoot);
        _nssm = new NssmServiceHost(_paths);
    }

    private async Task RefreshAsync()
    {
        try
        {
            RebuildHosts();
            var env = EnvFile.Load(_paths.ServerEnv);
            var host = env.Get("Host") ?? "127.0.0.1";
            var port = int.TryParse(env.Get("Port"), out var p) ? p : 11434;

            var svc = _nssm.GetStatus();
            var svcText = svc is null ? "serviço n/d" : FriendlySvc(svc.ToString()!);
            var health = await _health.CheckAsync(host, port);
            _apiOk = health.Ok;

            var models = await _health.ListModelsAsync(host, port);
            var modelShort = models.Count == 0
                ? "nenhum"
                : string.Join(", ", models.Select(m => m.Split(' ')[0]).Take(3));

            _statusText = _apiOk
                ? $"API online · {svcText}"
                : $"API offline · {svcText}";

            _statusItem.Text = _statusText;
            _modelsItem.Text = "Modelos: " + modelShort;
            _tray.Text = Truncate("LlamaServer — " + _statusText, 63);
            _tray.Icon = _apiOk ? _iconOnline : _iconOffline;
        }
        catch (Exception ex)
        {
            _apiOk = false;
            _statusItem.Text = "Erro: " + Truncate(ex.Message, 40);
            _tray.Icon = _iconOffline;
            _tray.Text = "LlamaServer — erro";
        }
    }

    private async Task ControlAsync(string action)
    {
        try
        {
            RebuildHosts();
            if (_settings.RuntimeMode == RuntimeMode.Service)
            {
                if (action is "start" or "restart")
                {
                    var env = EnvFile.Load(_paths.ServerEnv);
                    new RunBatWriter(_paths).Regenerate(env);
                    _nssm.SyncCudaVisibleDevices();
                }
                var (code, outp) = _nssm.Control(action, elevate: true);
                _tray.ShowBalloonTip(2500, "LlamaServer", $"{action}: {outp} (code={code})",
                    code == 0 ? ToolTipIcon.Info : ToolTipIcon.Warning);
            }
            else
            {
                _tray.ShowBalloonTip(3000, "LlamaServer",
                    "Modo Processo: usa o Manager para Iniciar/Parar.", ToolTipIcon.Info);
                OpenManager();
            }
        }
        catch (Exception ex)
        {
            _tray.ShowBalloonTip(3000, "LlamaServer", ex.Message, ToolTipIcon.Error);
        }
        await RefreshAsync();
    }

    private void OpenManager()
    {
        var candidates = new[]
        {
            Path.Combine(AppContext.BaseDirectory, "LlamaServer.Manager.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                "LlamaServer Manager", "LlamaServer.Manager.exe"),
            Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "LlamaServer.Manager",
                "LlamaServer.Manager.exe")),
        };
        var exe = candidates.FirstOrDefault(File.Exists);
        if (exe is null)
        {
            _tray.ShowBalloonTip(3000, "LlamaServer", "Manager não encontrado.", ToolTipIcon.Warning);
            return;
        }

        foreach (var p in Process.GetProcessesByName("LlamaServer.Manager"))
        {
            try
            {
                // already open — just focus best-effort
                NativeMethods.ShowWindow(p.MainWindowHandle, 9);
                NativeMethods.SetForegroundWindow(p.MainWindowHandle);
                return;
            }
            catch { /* ignore */ }
        }

        Process.Start(new ProcessStartInfo(exe) { UseShellExecute = true });
    }

    private void OnToggleAutostart(object? sender, EventArgs e)
    {
        var enable = !_autostartItem.Checked;
        SetAutostart(enable);
        _autostartItem.Checked = enable;
        _settings.StartTrayWithWindows = enable;
        _settings.Save();
    }

    private static string AutostartValue =>
        $"\"{Path.Combine(AppContext.BaseDirectory, "LlamaServer.Tray.exe")}\"";

    private static bool IsAutostartEnabled()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", false);
        var v = key?.GetValue("LlamaServerTray") as string;
        return !string.IsNullOrEmpty(v);
    }

    private static void SetAutostart(bool enable)
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true)
                        ?? Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        if (enable) key.SetValue("LlamaServerTray", AutostartValue);
        else key.DeleteValue("LlamaServerTray", false);
    }

    private static string FriendlySvc(string s) => s switch
    {
        "Running" => "a correr",
        "Stopped" => "parado",
        "StartPending" => "a iniciar",
        "StopPending" => "a parar",
        _ => s,
    };

    private static string Truncate(string s, int max) =>
        s.Length <= max ? s : s[..(max - 1)] + "…";

    private static Icon MakeIcon(Color fill)
    {
        var bmp = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);
            using var brush = new SolidBrush(fill);
            g.FillEllipse(brush, 2, 2, 28, 28);
            using var inner = new SolidBrush(Color.FromArgb(255, 15, 20, 28));
            g.FillEllipse(inner, 11, 11, 10, 10);
        }
        var hIcon = bmp.GetHicon();
        var icon = (Icon)Icon.FromHandle(hIcon).Clone();
        NativeMethods.DestroyIcon(hIcon);
        bmp.Dispose();
        return icon;
    }

    protected override void ExitThreadCore()
    {
        _timer.Stop();
        _tray.Visible = false;
        _tray.Dispose();
        _menu.Dispose();
        _iconOnline?.Dispose();
        _iconOffline?.Dispose();
        base.ExitThreadCore();
    }
}

internal static class NativeMethods
{
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Auto)]
    public static extern bool DestroyIcon(IntPtr handle);
}
