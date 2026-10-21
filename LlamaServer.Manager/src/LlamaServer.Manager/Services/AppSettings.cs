using LlamaServer.Manager.Core.Config;
using LlamaServer.Manager.Core.Runtime;

namespace LlamaServer.Manager.Services;

/// <summary>Compat wrapper — settings partilhadas com o Tray via ManagerSettings.</summary>
public sealed class AppSettings
{
    private readonly ManagerSettings _inner;

    public AppSettings() : this(new ManagerSettings()) { }
    public AppSettings(ManagerSettings inner) => _inner = inner;

    public string? LlamaServerRoot
    {
        get => _inner.LlamaServerRoot;
        set => _inner.LlamaServerRoot = value;
    }

    public RuntimeMode RuntimeMode
    {
        get => _inner.RuntimeMode;
        set => _inner.RuntimeMode = value;
    }

    public bool StartTrayWithWindows
    {
        get => _inner.StartTrayWithWindows;
        set => _inner.StartTrayWithWindows = value;
    }

    public static AppSettings Load() => new(ManagerSettings.Load());

    public void Save() => _inner.Save();
}
