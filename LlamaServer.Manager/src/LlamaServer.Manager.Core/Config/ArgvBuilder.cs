using LlamaServer.Manager.Core.Flags;

namespace LlamaServer.Manager.Core.Config;

public sealed class ArgvBuilder
{
    public IReadOnlyList<string> BuildFromEnv(EnvFile env, LlamaServerPaths paths)
    {
        var args = new List<string>();
        var exe = paths.ResolveServerBinary();
        if (string.Equals(System.IO.Path.GetFileName(exe), "llama.exe", StringComparison.OrdinalIgnoreCase))
            args.Add("serve");

        void AddPair(string flag, string? value)
        {
            if (string.IsNullOrWhiteSpace(value)) return;
            args.Add(flag);
            args.Add(value);
        }

        // UseRouter=0 + Model= → single process (-m); default keeps models-preset router
        var useRouter = env.Get("UseRouter") is null || env.IsTruthy("UseRouter", true);
        var modelPath = env.Get("Model") ?? env.Get("ModelPath");
        if (useRouter)
        {
            args.Add("--models-preset");
            args.Add(paths.ModelsPreset);
        }
        else
        {
            if (string.IsNullOrWhiteSpace(modelPath))
                throw new InvalidOperationException("UseRouter=0 requires Model= path to GGUF in server.env");
            AddPair("-m", modelPath);
            AddPair("--alias", env.Get("DefaultModel"));
        }

        AddPair("--host", env.Get("Host") ?? "127.0.0.1");
        AddPair("--port", env.Get("Port") ?? "11434");
        AddPair("-ngl", env.Get("GpuLayers") ?? "99");
        AddPair("-c", env.Get("CtxSize") ?? "65536");
        AddPair("--n-predict", env.Get("NPredict") ?? "32768");
        AddPair("--parallel", env.Get("Parallel") ?? "1");
        if (useRouter)
        {
            AddPair("--models-max", env.Get("ModelsMax") ?? "1");
            if (env.IsTruthy("ModelsAutoload"))
                args.Add("--models-autoload");
            else if (env.Get("ModelsAutoload") is not null && !env.IsTruthy("ModelsAutoload"))
                args.Add("--no-models-autoload");
        }
        AddPair("-fa", env.Get("FlashAttn") ?? "on");
        AddPair("--threads", env.Get("Threads") ?? "1");
        AddPair("-ctk", env.Get("CacheTypeK") ?? "q4_0");
        AddPair("-ctv", env.Get("CacheTypeV") ?? "q4_0");
        AddPair("--device", env.Get("Device"));
        var splitMode = env.Get("SplitMode") ?? "none";
        AddPair("--split-mode", splitMode);
        if (!string.Equals(splitMode, "none", StringComparison.OrdinalIgnoreCase))
            AddPair("--tensor-split", env.Get("TensorSplit"));
        AddPair("--main-gpu", env.Get("MainGpu"));
        var fit = env.Get("Fit");
        if (!string.IsNullOrWhiteSpace(fit))
            AddPair("--fit", fit);
        if (env.IsTruthy("KvUnified")) args.Add("--kv-unified");
        if (env.Get("CachePrompt") is null || env.IsTruthy("CachePrompt", true))
            args.Add("--cache-prompt");

        var cr = env.Get("CacheReuse") ?? "512";
        if (int.TryParse(cr, out var cri) && cri > 0)
        {
            args.Add("--cache-reuse");
            args.Add(cr);
        }

        AddPair("--slot-prompt-similarity", env.Get("SlotPromptSimilarity") ?? "0.30");
        args.Add("--jinja");
        AddPair("--reasoning", env.Get("Reasoning") ?? "auto");
        AddPair("--reasoning-effort", env.Get("ReasoningEffort") ?? "medium");
        AddPair("--reasoning-budget", env.Get("ReasoningBudget") ?? "4096");
        if (env.IsTruthy("ReasoningPreserve", true)) args.Add("--reasoning-preserve");
        if (env.IsTruthy("Agent", true)) args.Add("--agent");
        AddPair("--tools", env.Get("Tools") ?? "all");

        var mp = env.Get("MediaPath");
        if (!string.IsNullOrWhiteSpace(mp))
        {
            if (mp.EndsWith('\\')) mp = mp.TrimEnd('\\') + "/";
            args.Add("--media-path");
            args.Add(mp);
        }

        var ui = env.Get("UiPath");
        if (!string.IsNullOrWhiteSpace(ui))
        {
            args.Add("--path");
            args.Add(ui);
        }

        if (env.Get("WebUI") is null || env.IsTruthy("WebUI", true))
            args.Add("--webui");

        var extra = env.Get("ExtraArgs");
        if (!string.IsNullOrWhiteSpace(extra))
            args.AddRange(SplitArgs(extra));

        return args;
    }

    public string FormatCommandLine(string exe, IEnumerable<string> args) =>
        Quote(exe) + " " + string.Join(" ", args.Select(Quote));

    public static IEnumerable<string> SplitArgs(string commandLine)
    {
        var result = new List<string>();
        var current = new System.Text.StringBuilder();
        var inQuotes = false;
        foreach (var ch in commandLine)
        {
            if (ch == '"') { inQuotes = !inQuotes; continue; }
            if (char.IsWhiteSpace(ch) && !inQuotes)
            {
                if (current.Length > 0) { result.Add(current.ToString()); current.Clear(); }
                continue;
            }
            current.Append(ch);
        }
        if (current.Length > 0) result.Add(current.ToString());
        return result;
    }

    private static string Quote(string s) =>
        s.Contains(' ') || s.Contains('"') ? $"\"{s.Replace("\"", "\\\"")}\"" : s;
}
