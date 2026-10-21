using System.Text.Json;
using LlamaServer.Manager.Core.Runtime;

namespace LlamaServer.Manager.Core.Config;

/// <summary>Shared settings for Manager + Tray (%LocalAppData%\LlamaServerManager\settings.json).</summary>
public sealed class ManagerSettings
{
    public string? LlamaServerRoot { get; set; }
    public RuntimeMode RuntimeMode { get; set; } = RuntimeMode.Service;
    public bool StartTrayWithWindows { get; set; } = true;

    public static string SettingsDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LlamaServerManager");

    public static string SettingsPath => Path.Combine(SettingsDirectory, "settings.json");

    public static ManagerSettings Load()
    {
        try
        {
            if (File.Exists(SettingsPath))
                return JsonSerializer.Deserialize<ManagerSettings>(File.ReadAllText(SettingsPath)) ?? new();
        }
        catch { /* ignore */ }
        return new();
    }

    public void Save()
    {
        Directory.CreateDirectory(SettingsDirectory);
        File.WriteAllText(SettingsPath, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
    }
}
