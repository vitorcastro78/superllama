namespace LlamaServer.Manager.Core.Config;

public sealed class LlamaServerPaths
{
    public string Root { get; }
    public string Bin => System.IO.Path.Combine(Root, "bin");
    public string Config => System.IO.Path.Combine(Root, "config");
    public string Scripts => System.IO.Path.Combine(Root, "scripts");
    public string Logs => System.IO.Path.Combine(Root, "logs");
    public string ServerEnv => System.IO.Path.Combine(Config, "server.env");
    public string LlamaEnv => System.IO.Path.Combine(Config, "llama.env");
    public string ModelsPreset => System.IO.Path.Combine(Config, "models-preset.ini");
    public string RunServerBat => System.IO.Path.Combine(Scripts, "run-server.bat");
    public string WriteRunServerBatPs1 => System.IO.Path.Combine(Scripts, "Write-RunServerBat.ps1");
    public string UpdateLlamaPs1 => System.IO.Path.Combine(Scripts, "Update-Llama.ps1");
    public string LlamaServerExe => System.IO.Path.Combine(Bin, "llama-server.exe");
    public string LlamaExe => System.IO.Path.Combine(Bin, "llama.exe");

    public LlamaServerPaths(string root) => Root = System.IO.Path.GetFullPath(root);

    public static LlamaServerPaths Detect(string? overrideRoot = null)
    {
        if (!string.IsNullOrWhiteSpace(overrideRoot) && Directory.Exists(overrideRoot))
            return new LlamaServerPaths(overrideRoot);

        var candidates = new[]
        {
            @"C:\LlamaServer",
            System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "LlamaServer"),
            System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LlamaServer"),
        };
        foreach (var c in candidates)
        {
            if (File.Exists(System.IO.Path.Combine(c, "bin", "llama-server.exe")) ||
                File.Exists(System.IO.Path.Combine(c, "config", "server.env")))
                return new LlamaServerPaths(c);
        }
        return new LlamaServerPaths(@"C:\LlamaServer");
    }

    public string ResolveServerBinary()
    {
        if (File.Exists(LlamaServerExe)) return LlamaServerExe;
        if (File.Exists(LlamaExe)) return LlamaExe;
        return LlamaServerExe;
    }
}
