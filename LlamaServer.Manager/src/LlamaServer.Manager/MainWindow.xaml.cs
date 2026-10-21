using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using LlamaServer.Manager.Core.Config;
using LlamaServer.Manager.Core.Flags;
using LlamaServer.Manager.Core.Runtime;
using LlamaServer.Manager.Services;
using Microsoft.Win32;

namespace LlamaServer.Manager;

public partial class MainWindow : Window
{
    private AppSettings _settings = null!;
    private LlamaServerPaths _paths = null!;
    private EnvFile _env = null!;
    private ModelsPresetFile _presets = null!;
    private RunBatWriter _bat = null!;
    private NssmServiceHost _nssm = null!;
    private LocalProcessHost _local = null!;
    private readonly HealthClient _health = new();
    private readonly GpuInfoService _gpu = new();
    private List<FlagDefinition> _allFlags = new();
    private readonly DispatcherTimer _timer;
    private bool _loadingUi;

    public MainWindow()
    {
        InitializeComponent();
        _timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(5) };
        _timer.Tick += async (_, _) =>
        {
            if (AutoTailChk.IsChecked == true && Tabs.SelectedItem is TabItem { Header: string h } && h == "Logs")
                TailServiceLogs_Click(this, new RoutedEventArgs());
            await RefreshDashboardAsync(silent: true);
            if (Tabs.SelectedItem is TabItem { Header: string rh } && rh == "Router")
                await RefreshRouterAsync(silent: true);
        };
        Loaded += OnLoaded;
        Closed += (_, _) =>
        {
            _timer.Stop();
            if (_settings.RuntimeMode == RuntimeMode.Process)
                _local.Stop();
        };
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        _settings = AppSettings.Load();
        ReloadPaths(_settings.LlamaServerRoot);
        SelectRuntimeMode(_settings.RuntimeMode);
        LoadEnvToUi();
        LoadPresetsToUi();
        RefreshFlagsCatalog();
        _timer.Start();
        await RefreshDashboardAsync();
        Status("Carregado");
    }

    private void ReloadPaths(string? root)
    {
        _paths = LlamaServerPaths.Detect(root);
        _env = EnvFile.Load(_paths.ServerEnv);
        _presets = ModelsPresetFile.Load(_paths.ModelsPreset);
        _bat = new RunBatWriter(_paths);
        _nssm = new NssmServiceHost(_paths);
        _local = new LocalProcessHost(_paths);
        RootPathBox.Text = _paths.Root;
        PathStatusText.Text = _paths.Root;
        var host = _env.Get("Host") ?? "127.0.0.1";
        var port = _env.Get("Port") ?? "11434";
        EndpointHintText.Text = $"http://{host}:{port}";
        DetectInfoText.Text =
            $"Binary: {_paths.ResolveServerBinary()}\n" +
            $"Env: {_paths.ServerEnv}  ·  exists={File.Exists(_paths.ServerEnv)}\n" +
            $"Presets: {_paths.ModelsPreset}  ·  exists={File.Exists(_paths.ModelsPreset)}\n" +
            $"Write-RunServerBat: {File.Exists(_paths.WriteRunServerBatPs1)}";
    }

    private void SelectRuntimeMode(RuntimeMode mode)
    {
        _loadingUi = true;
        RuntimeModeCombo.SelectedIndex = mode == RuntimeMode.Process ? 1 : 0;
        _loadingUi = false;
    }

    private RuntimeMode CurrentMode()
    {
        if (RuntimeModeCombo.SelectedItem is ComboBoxItem { Tag: string tag } &&
            Enum.TryParse<RuntimeMode>(tag, out var m))
            return m;
        return RuntimeMode.Service;
    }

    private void RuntimeModeCombo_OnSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loadingUi || _settings is null) return;
        _settings.RuntimeMode = CurrentMode();
        _settings.Save();
        _ = RefreshDashboardAsync();
    }

    private void Status(string msg) => StatusText.Text = msg;

    // --- Dashboard ---
    private async void RefreshDashboard_Click(object sender, RoutedEventArgs e) =>
        await RefreshDashboardAsync();

    private async Task RefreshDashboardAsync(bool silent = false)
    {
        try
        {
            var st = _nssm.GetStatus();
            ServiceStatusText.Text = st is null ? "Não instalado" : FriendlyServiceStatus(st.ToString()!);
            ProcessStatusText.Text = _local.IsRunning
                ? $"A correr  ·  PID {_local.ProcessId}"
                : "Parado";

            var host = _env.Get("Host") ?? "127.0.0.1";
            var port = int.TryParse(_env.Get("Port"), out var p) ? p : 11434;
            EndpointHintText.Text = $"http://{host}:{port}";
            var health = await _health.CheckAsync(host, port);
            SetHealthUi(health.Ok, health.Ok ? "Online" : "Offline",
                health.Ok ? "Resposta OK do endpoint /health" : (health.Error ?? "Sem resposta"));

            var models = await _health.ListModelsAsync(host, port);
            ModelsStatusText.Text = models.Count == 0
                ? "Nenhum modelo reportado"
                : string.Join("\n", models.Select(FriendlyModelLine));

            GpuGrid.ItemsSource = _gpu.QueryNvidiaSmi();
            if (!silent) Status("Dashboard actualizado");
        }
        catch (Exception ex)
        {
            SetHealthUi(false, "Erro", ex.Message);
            if (!silent) Status("Erro: " + ex.Message);
        }
    }

    private void SetHealthUi(bool ok, string pill, string detail)
    {
        var okBrush = (Brush)FindResource("Ok");
        var badBrush = (Brush)FindResource("Bad");
        var muted = (Brush)FindResource("Muted");
        HealthDot.Fill = ok ? okBrush : badBrush;
        HealthPillText.Text = "API " + pill;
        HealthPill.Background = ok
            ? new SolidColorBrush(Color.FromArgb(0x33, 0x34, 0xD3, 0x99))
            : new SolidColorBrush(Color.FromArgb(0x33, 0xF8, 0x71, 0x71));
        HealthStatusText.Text = detail;
        HealthStatusText.Foreground = ok ? okBrush : (detail.Contains("Erro", StringComparison.OrdinalIgnoreCase) ? badBrush : muted);
    }

    private static string FriendlyServiceStatus(string status) => status switch
    {
        "Running" => "A correr",
        "Stopped" => "Parado",
        "StartPending" => "A iniciar…",
        "StopPending" => "A parar…",
        "Paused" => "Em pausa",
        _ => status,
    };

    private static string FriendlyModelLine(string raw)
    {
        // "id [status]" → "id  ·  status"
        var i = raw.LastIndexOf('[');
        if (i > 0 && raw.EndsWith(']'))
        {
            var id = raw[..i].Trim();
            var st = raw[(i + 1)..^1].Trim();
            var stPt = st.ToLowerInvariant() switch
            {
                "loaded" => "carregado",
                "unloaded" => "em disco",
                "loading" => "a carregar",
                _ => st,
            };
            return $"{id}  ·  {stPt}";
        }
        return raw;
    }

    private void ListDevices_Click(object sender, RoutedEventArgs e)
    {
        DevicesText.Text = _gpu.ListDevices(_paths.ResolveServerBinary());
    }

    private void Start_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            CollectUiToEnv();
            if (CurrentMode() == RuntimeMode.Service)
            {
                _bat.Regenerate(_env);
                var (code, outp) = _nssm.Control("start", elevate: true);
                Status($"Start serviço: {outp} (code={code})");
            }
            else
            {
                _local.Start(_env);
                Status($"Processo iniciado PID {_local.ProcessId}");
            }
            _ = RefreshDashboardAsync();
        }
        catch (Exception ex) { MessageBox.Show(ex.Message, "Start", MessageBoxButton.OK, MessageBoxImage.Error); }
    }

    private void Stop_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            if (CurrentMode() == RuntimeMode.Service)
            {
                var (code, outp) = _nssm.Control("stop", elevate: true);
                Status($"Stop serviço: {outp} (code={code})");
            }
            else
            {
                _local.Stop();
                Status("Processo parado");
            }
            _ = RefreshDashboardAsync();
        }
        catch (Exception ex) { MessageBox.Show(ex.Message, "Stop", MessageBoxButton.OK, MessageBoxImage.Error); }
    }

    private void Restart_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            CollectUiToEnv();
            if (CurrentMode() == RuntimeMode.Service)
            {
                _bat.Regenerate(_env);
                _nssm.SyncCudaVisibleDevices();
                var (code, outp) = _nssm.Control("restart", elevate: true);
                Status($"Restart serviço: {outp} (code={code})");
            }
            else
            {
                _local.Start(_env);
                Status($"Processo relançado PID {_local.ProcessId}");
            }
            _ = RefreshDashboardAsync();
        }
        catch (Exception ex) { MessageBox.Show(ex.Message, "Restart", MessageBoxButton.OK, MessageBoxImage.Error); }
    }

    private void UpdateBinary_Click(object sender, RoutedEventArgs e)
    {
        if (!File.Exists(_paths.UpdateLlamaPs1))
        {
            MessageBox.Show("Update-Llama.ps1 não encontrado em " + _paths.Scripts, "Update");
            return;
        }
        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = $"-NoProfile -ExecutionPolicy Bypass -File \"{_paths.UpdateLlamaPs1}\"",
            UseShellExecute = true,
            Verb = "runas",
        };
        try { Process.Start(psi); Status("Update-Llama.ps1 lançado (admin)"); }
        catch (Exception ex) { MessageBox.Show(ex.Message, "Update"); }
    }

    // --- Dual-GPU Router ---
    private sealed class RouterRow
    {
        public string Id { get; set; } = "";
        public string Device { get; set; } = "";
        public string GpuName { get; set; } = "";
        public string Status { get; set; } = "";
    }

    private void UpdateRouterCurlExamples()
    {
        var host = HostBox?.Text?.Trim();
        if (string.IsNullOrEmpty(host)) host = _env?.Get("Host") ?? "127.0.0.1";
        var port = PortBox?.Text?.Trim();
        if (string.IsNullOrEmpty(port)) port = _env?.Get("Port") ?? "11434";
        var baseUrl = $"http://{host}:{port}/v1/chat/completions";
        if (RouterCurlFastBox is not null)
            RouterCurlFastBox.Text =
                $"curl -s {baseUrl} -H \"Content-Type: application/json\" -d \"{{\\\"model\\\":\\\"bonsai-27b\\\",\\\"messages\\\":[{{\\\"role\\\":\\\"user\\\",\\\"content\\\":\\\"ola\\\"}}],\\\"max_tokens\\\":64}}\"";
        if (RouterCurlHeavyBox is not null)
            RouterCurlHeavyBox.Text =
                $"curl -s {baseUrl} -H \"Content-Type: application/json\" -d \"{{\\\"model\\\":\\\"bonsai-2-27b\\\",\\\"messages\\\":[{{\\\"role\\\":\\\"user\\\",\\\"content\\\":\\\"ola\\\"}}],\\\"max_tokens\\\":64}}\"";
        if (RouterHintText is not null)
            RouterHintText.Text =
                "Mapa: bonsai-27b / fast → CUDA1 (RTX 3050) · bonsai-2-27b / heavy → CUDA0 (RTX 3060)\n" +
                "ModelsMax=2 e CudaVisibleDevices=0,1 sao obrigatorios. Autoload carrega os dois ao arrancar o servico.";
    }

    private async void RefreshRouter_Click(object sender, RoutedEventArgs e) =>
        await RefreshRouterAsync();

    private async Task RefreshRouterAsync(bool silent = false)
    {
        try
        {
            UpdateRouterCurlExamples();
            var host = _env.Get("Host") ?? "127.0.0.1";
            var port = int.TryParse(_env.Get("Port"), out var p) ? p : 11434;
            var models = await _health.ListModelDetailsAsync(host, port);
            var gpus = _gpu.QueryNvidiaSmi();
            string GpuLabel(string device)
            {
                // CUDA0 → index 0 with CUDA_VISIBLE_DEVICES=0,1
                if (device.StartsWith("CUDA", StringComparison.OrdinalIgnoreCase) &&
                    int.TryParse(device.AsSpan(4), out var idx) &&
                    idx >= 0 && idx < gpus.Count)
                    return $"{gpus[idx].Name}";
                return device;
            }
            var rows = models.Select(m => new RouterRow
            {
                Id = m.Id,
                Device = m.Device,
                GpuName = GpuLabel(m.Device),
                Status = m.Status switch
                {
                    "loaded" => "carregado",
                    "unloaded" => "em disco",
                    "loading" => "a carregar",
                    _ => m.Status,
                },
            }).ToList();

            // Fallback from presets if API empty
            if (rows.Count == 0)
            {
                foreach (var pr in _presets.Presets)
                {
                    var dev = pr.Get("device") ?? "?";
                    rows.Add(new RouterRow
                    {
                        Id = pr.Name,
                        Device = dev,
                        GpuName = GpuLabel(dev),
                        Status = "(preset)",
                    });
                }
            }

            RouterGrid.ItemsSource = rows;
            var loaded = rows.Count(r => r.Status is "carregado" or "loaded");
            RouterStatusText.Text =
                $"API {host}:{port} · {rows.Count} modelo(s) · {loaded} carregado(s) · ModelsMax={_env.Get("ModelsMax") ?? "?"} · CUDA={_env.Get("CudaVisibleDevices") ?? "?"}";
            if (!silent) Status("Router actualizado");
        }
        catch (Exception ex)
        {
            RouterStatusText.Text = "Erro: " + ex.Message;
            if (!silent) Status("Erro router: " + ex.Message);
        }
    }

    private async void WarmLoadBoth_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            RouterStatusText.Text = "A carregar modelos (pode demorar alguns minutos)...";
            Status("Warm-load dual-GPU...");
            var host = _env.Get("Host") ?? "127.0.0.1";
            var port = int.TryParse(_env.Get("Port"), out var p) ? p : 11434;
            var ids = (await _health.ListModelDetailsAsync(host, port)).Select(m => m.Id).ToList();
            if (ids.Count == 0)
                ids = _presets.Presets.Select(x => x.Name).ToList();

            var sb = new System.Text.StringBuilder();
            foreach (var id in ids)
            {
                sb.Append($"{id}: a carregar... ");
                RouterStatusText.Text = sb.ToString();
                var (ok, detail) = await _health.WarmLoadAsync(id, host, port);
                sb.AppendLine(ok ? "OK" : "FALHOU — " + detail);
                RouterStatusText.Text = sb.ToString();
            }
            await RefreshRouterAsync();
            GpuGrid.ItemsSource = _gpu.QueryNvidiaSmi();
            Status("Warm-load concluido");
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "Warm-load", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void ApplyRouter_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            // Garante dual-GPU
            _env.Set("ModelsMax", "2");
            _env.Set("CudaVisibleDevices", "0,1");
            _env.Set("ModelsAutoload", ModelsAutoloadChk.IsChecked == true ? "1" : "0");
            _env.Set("MainGpu", null); // nao forcar GPU global
            if (ModelsMaxBox is not null) ModelsMaxBox.Text = "2";
            if (CudaBox is not null) CudaBox.Text = "0,1";
            if (MainGpuBox is not null) MainGpuBox.Text = "";

            _presets.Save();
            var bat = _bat.Regenerate(_env);
            _settings.Save();

            if (CurrentMode() == RuntimeMode.Service)
            {
                _nssm.SyncCudaVisibleDevices();
                var (code, outp) = _nssm.Control("restart", elevate: true);
                RouterStatusText.Text = $"Router aplicado + restart servico.\nbat={bat}\n{outp} (code={code})";
            }
            else
            {
                _local.Start(_env);
                RouterStatusText.Text = $"Router aplicado + processo PID {_local.ProcessId}";
            }
            Status("Router aplicado");
            _ = RefreshDashboardAsync();
            _ = RefreshRouterAsync(silent: true);
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "Apply router", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    // --- Global env UI ---
    private void LoadEnvToUi()
    {
        _loadingUi = true;
        HostBox.Text = _env.Get("Host") ?? "127.0.0.1";
        PortBox.Text = _env.Get("Port") ?? "11434";
        CudaBox.Text = _env.Get("CudaVisibleDevices") ?? "0";
        ModelsMaxBox.Text = _env.Get("ModelsMax") ?? "1";
        if (ModelsAutoloadChk is not null)
            ModelsAutoloadChk.IsChecked = _env.IsTruthy("ModelsAutoload");
        ParallelBox.Text = _env.Get("Parallel") ?? "1";
        UpdateRouterCurlExamples();
        _ = RefreshRouterAsync(silent: true);
        CtxBox.Text = _env.Get("CtxSize") ?? "65536";
        NglBox.Text = _env.Get("GpuLayers") ?? "99";
        ThreadsBox.Text = _env.Get("Threads") ?? "1";
        FaBox.Text = _env.Get("FlashAttn") ?? "on";
        CtkBox.Text = _env.Get("CacheTypeK") ?? "q4_0";
        CtvBox.Text = _env.Get("CacheTypeV") ?? "q4_0";
        DeviceBox.Text = _env.Get("Device") ?? "";
        SplitBox.Text = _env.Get("SplitMode") ?? "none";
        MainGpuBox.Text = _env.Get("MainGpu") ?? "";
        CacheReuseBox.Text = _env.Get("CacheReuse") ?? "512";
        SlotSimBox.Text = _env.Get("SlotPromptSimilarity") ?? "0.30";
        ReasoningBox.Text = _env.Get("Reasoning") ?? "auto";
        EffortBox.Text = _env.Get("ReasoningEffort") ?? "medium";
        BudgetBox.Text = _env.Get("ReasoningBudget") ?? "4096";
        ToolsBox.Text = _env.Get("Tools") ?? "all";
        MediaPathBox.Text = _env.Get("MediaPath") ?? "";
        UiPathBox.Text = _env.Get("UiPath") ?? "";
        ExtraArgsBox.Text = _env.Get("ExtraArgs") ?? "";
        KvUnifiedChk.IsChecked = _env.IsTruthy("KvUnified");
        CachePromptChk.IsChecked = _env.Get("CachePrompt") is null || _env.IsTruthy("CachePrompt", true);
        ReasoningPreserveChk.IsChecked = _env.Get("ReasoningPreserve") is null || _env.IsTruthy("ReasoningPreserve", true);
        AgentChk.IsChecked = _env.Get("Agent") is null || _env.IsTruthy("Agent", true);
        WebUiChk.IsChecked = _env.Get("WebUI") is null || _env.IsTruthy("WebUI", true);
        JinjaChk.IsChecked = _env.Get("Jinja") is null || _env.IsTruthy("Jinja", true);
        _loadingUi = false;
    }

    private void CollectUiToEnv()
    {
        void Set(string k, string? v) => _env.Set(k, string.IsNullOrWhiteSpace(v) ? null : v.Trim());
        Set("Host", HostBox.Text);
        Set("Port", PortBox.Text);
        Set("CudaVisibleDevices", CudaBox.Text);
        Set("ModelsMax", ModelsMaxBox.Text);
        if (ModelsAutoloadChk is not null)
            _env.Set("ModelsAutoload", ModelsAutoloadChk.IsChecked == true ? "1" : "0");
        Set("Parallel", ParallelBox.Text);
        Set("CtxSize", CtxBox.Text);
        Set("GpuLayers", NglBox.Text);
        Set("Threads", ThreadsBox.Text);
        Set("FlashAttn", FaBox.Text);
        Set("CacheTypeK", CtkBox.Text);
        Set("CacheTypeV", CtvBox.Text);
        Set("Device", DeviceBox.Text);
        Set("SplitMode", SplitBox.Text);
        Set("MainGpu", MainGpuBox.Text);
        Set("CacheReuse", CacheReuseBox.Text);
        Set("SlotPromptSimilarity", SlotSimBox.Text);
        Set("Reasoning", ReasoningBox.Text);
        Set("ReasoningEffort", EffortBox.Text);
        Set("ReasoningBudget", BudgetBox.Text);
        Set("Tools", ToolsBox.Text);
        Set("MediaPath", MediaPathBox.Text);
        Set("UiPath", UiPathBox.Text);
        Set("ExtraArgs", ExtraArgsBox.Text);
        _env.Set("KvUnified", KvUnifiedChk.IsChecked == true ? "1" : "0");
        _env.Set("CachePrompt", CachePromptChk.IsChecked == true ? "1" : "0");
        _env.Set("ReasoningPreserve", ReasoningPreserveChk.IsChecked == true ? "1" : "0");
        _env.Set("Agent", AgentChk.IsChecked == true ? "1" : "0");
        _env.Set("WebUI", WebUiChk.IsChecked == true ? "1" : "0");
        _env.Set("Jinja", JinjaChk.IsChecked == true ? "1" : "0");
        _env.Set("RuntimeMode", CurrentMode().ToString());
    }

    private void RefreshFlags_Click(object sender, RoutedEventArgs e) => RefreshFlagsCatalog();

    private void RefreshFlagsCatalog()
    {
        var exe = _paths.ResolveServerBinary();
        if (File.Exists(exe))
            _allFlags = HelpParser.ParseFromBinary(exe).ToList();
        else
        {
            var fallback = Path.Combine(AppContext.BaseDirectory, "llama-server-help.txt");
            var tools = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "tools", "llama-server-help.txt"));
            var path = File.Exists(fallback) ? fallback : tools;
            _allFlags = File.Exists(path)
                ? HelpParser.Parse(File.ReadAllText(path)).ToList()
                : new List<FlagDefinition>();
        }
        ApplyFlagFilter();
        Status($"Catálogo: {_allFlags.Count} flags");
    }

    private void FlagFilter_OnTextChanged(object sender, TextChangedEventArgs e) => ApplyFlagFilter();

    private void ApplyFlagFilter()
    {
        var q = (FlagFilterBox.Text ?? "").Trim();
        IEnumerable<FlagDefinition> src = _allFlags;
        if (q.Length > 0)
            src = src.Where(f =>
                f.Flag.Contains(q, StringComparison.OrdinalIgnoreCase) ||
                f.Description.Contains(q, StringComparison.OrdinalIgnoreCase) ||
                f.Category.Contains(q, StringComparison.OrdinalIgnoreCase));
        FlagsGrid.ItemsSource = src.OrderBy(f => f.Category).ThenBy(f => f.Flag).ToList();
    }

    // --- Presets ---
    private void LoadPresetsToUi()
    {
        PresetList.ItemsSource = null;
        PresetList.ItemsSource = _presets.Presets.Select(p => p.Name).ToList();
        if (_presets.Presets.Count > 0)
            PresetList.SelectedIndex = 0;
    }

    private void PresetList_OnSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (PresetList.SelectedItem is not string name) return;
        var p = _presets.Find(name);
        if (p is null) return;
        PresetNameBox.Text = p.Name;
        PresetModelBox.Text = p.Get("model") ?? "";
        PresetMmprojBox.Text = p.Get("mmproj") ?? "";
        PresetDeviceBox.Text = p.Get("device") ?? "";
        PresetCtxBox.Text = p.Get("ctx-size") ?? p.Get("c") ?? "";
        PresetNglBox.Text = p.Get("n-gpu-layers") ?? p.Get("ngl") ?? "";
        var known = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
            { "model", "mmproj", "device", "ctx-size", "c", "n-gpu-layers", "ngl" };
        PresetExtraBox.Text = string.Join("\n",
            p.Values.Where(kv => !known.Contains(kv.Key)).Select(kv => $"{kv.Key}={kv.Value}"));
    }

    private void AddPreset_Click(object sender, RoutedEventArgs e)
    {
        var name = $"model-{_presets.Presets.Count + 1}";
        _presets.Add(name);
        LoadPresetsToUi();
        PresetList.SelectedItem = name;
    }

    private void RemovePreset_Click(object sender, RoutedEventArgs e)
    {
        if (PresetList.SelectedItem is not string name) return;
        if (MessageBox.Show($"Remover preset [{name}]?", "Presets", MessageBoxButton.YesNo) != MessageBoxResult.Yes)
            return;
        _presets.Remove(name);
        LoadPresetsToUi();
    }

    private void ReloadPresets_Click(object sender, RoutedEventArgs e)
    {
        _presets = ModelsPresetFile.Load(_paths.ModelsPreset);
        LoadPresetsToUi();
        Status("Presets recarregados");
    }

    private void SavePresetFields_Click(object sender, RoutedEventArgs e)
    {
        var name = (PresetNameBox.Text ?? "").Trim();
        if (name.Length == 0) return;
        var old = PresetList.SelectedItem as string;
        var p = old is not null ? _presets.Find(old) : null;
        if (p is null) p = _presets.Add(name);
        else p.Name = name;

        p.Values.Clear();
        void Put(string k, string? v) { if (!string.IsNullOrWhiteSpace(v)) p.Set(k, v.Trim()); }
        Put("model", PresetModelBox.Text);
        Put("mmproj", PresetMmprojBox.Text);
        Put("device", PresetDeviceBox.Text);
        Put("ctx-size", PresetCtxBox.Text);
        Put("n-gpu-layers", PresetNglBox.Text);
        foreach (var line in (PresetExtraBox.Text ?? "").Split('\n'))
        {
            var t = line.Trim();
            if (t.Length == 0 || t.StartsWith('#') || t.StartsWith(';')) continue;
            var eq = t.IndexOf('=');
            if (eq <= 0) continue;
            p.Set(t[..eq].Trim(), t[(eq + 1)..].Trim());
        }
        LoadPresetsToUi();
        PresetList.SelectedItem = name;
        Status($"Preset [{name}] actualizado na memória — usa Apply para gravar");
    }

    // --- Apply ---
    private void Preview_Click(object sender, RoutedEventArgs e)
    {
        CollectUiToEnv();
        PreviewBox.Text = _bat.PreviewCommand(_env);
        ApplyStatusText.Text = "Preview gerado (ainda não gravado).";
    }

    private void SaveAll_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            CollectUiToEnv();
            _presets.Save();
            var bat = _bat.Regenerate(_env);
            _settings.LlamaServerRoot = _paths.Root;
            _settings.RuntimeMode = CurrentMode();
            _settings.Save();
            PreviewBox.Text = _bat.PreviewCommand(_env);
            ApplyStatusText.Text = $"Guardado.\nserver.env + llama.env + presets\nbat: {bat}";
            Status("Configuração guardada");
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "Save", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void ApplyRestart_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            CollectUiToEnv();
            _presets.Save();
            var bat = _bat.Regenerate(_env);
            _settings.Save();
            PreviewBox.Text = _bat.PreviewCommand(_env);

            if (CurrentMode() == RuntimeMode.Service)
            {
                _nssm.SyncCudaVisibleDevices();
                var (code, outp) = _nssm.Control("restart", elevate: true);
                ApplyStatusText.Text = $"Apply + restart serviço.\nbat={bat}\n{outp} (code={code})";
            }
            else
            {
                _local.Start(_env);
                ApplyStatusText.Text = $"Apply + processo relançado PID {_local.ProcessId}\nbat={bat}";
            }
            Status("Apply concluído");
            _ = RefreshDashboardAsync();
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "Apply", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    // --- Logs ---
    private void TailServiceLogs_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            if (!Directory.Exists(_paths.Logs))
            {
                LogsBox.Text = "(pasta logs inexistente)";
                return;
            }
            var files = Directory.GetFiles(_paths.Logs, "service*.log")
                .Concat(Directory.GetFiles(_paths.Logs, "*.log"))
                .Distinct()
                .OrderByDescending(File.GetLastWriteTimeUtc)
                .Take(3)
                .ToList();
            if (files.Count == 0)
            {
                LogsBox.Text = "(sem ficheiros de log)";
                return;
            }
            var sb = new System.Text.StringBuilder();
            foreach (var f in files)
            {
                sb.AppendLine("===== " + f + " =====");
                sb.AppendLine(TailFile(f, 200));
                sb.AppendLine();
            }
            LogsBox.Text = sb.ToString();
            LogsBox.ScrollToEnd();
        }
        catch (Exception ex) { LogsBox.Text = ex.Message; }
    }

    private void TailProcessLogs_Click(object sender, RoutedEventArgs e)
    {
        LogsBox.Text = _local.GetOutputSnapshot();
        if (string.IsNullOrWhiteSpace(LogsBox.Text))
            LogsBox.Text = "(sem stdout do processo local — inicia em modo Processo)";
        LogsBox.ScrollToEnd();
    }

    private void ClearLogs_Click(object sender, RoutedEventArgs e) => LogsBox.Clear();

    private static string TailFile(string path, int lines)
    {
        using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        using var sr = new StreamReader(fs);
        var all = new LinkedList<string>();
        while (sr.ReadLine() is { } line)
        {
            all.AddLast(line);
            if (all.Count > lines) all.RemoveFirst();
        }
        return string.Join(Environment.NewLine, all);
    }

    // --- Settings ---
    private void BrowseRoot_Click(object sender, RoutedEventArgs e)
    {
        var dlg = new OpenFolderDialog { Title = "Seleccionar pasta LlamaServer" };
        if (dlg.ShowDialog() == true)
            RootPathBox.Text = dlg.FolderName;
    }

    private void ApplyRoot_Click(object sender, RoutedEventArgs e)
    {
        var root = RootPathBox.Text.Trim();
        if (!Directory.Exists(root))
        {
            MessageBox.Show("Pasta inválida", "Settings");
            return;
        }
        _settings.LlamaServerRoot = root;
        _settings.Save();
        ReloadPaths(root);
        LoadEnvToUi();
        LoadPresetsToUi();
        RefreshFlagsCatalog();
        _ = RefreshDashboardAsync();
        Status("Root actualizado: " + root);
    }
}
