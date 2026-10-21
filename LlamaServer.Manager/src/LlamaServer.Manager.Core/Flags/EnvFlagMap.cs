namespace LlamaServer.Manager.Core.Flags;

/// <summary>Maps well-known server.env keys to llama-server CLI flags (Write-RunServerBat parity).</summary>
public static class EnvFlagMap
{
    public static readonly IReadOnlyDictionary<string, string> EnvToFlag = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
    {
        ["Host"] = "--host",
        ["Port"] = "--port",
        ["GpuLayers"] = "-ngl",
        ["CtxSize"] = "-c",
        ["NPredict"] = "--n-predict",
        ["Parallel"] = "--parallel",
        ["ModelsMax"] = "--models-max",
        ["FlashAttn"] = "-fa",
        ["Threads"] = "--threads",
        ["CacheTypeK"] = "-ctk",
        ["CacheTypeV"] = "-ctv",
        ["Device"] = "--device",
        ["SplitMode"] = "--split-mode",
        ["TensorSplit"] = "--tensor-split",
        ["MainGpu"] = "--main-gpu",
        ["Fit"] = "--fit",
        ["CacheReuse"] = "--cache-reuse",
        ["SlotPromptSimilarity"] = "--slot-prompt-similarity",
        ["Reasoning"] = "--reasoning",
        ["ReasoningEffort"] = "--reasoning-effort",
        ["ReasoningBudget"] = "--reasoning-budget",
        ["Tools"] = "--tools",
        ["MediaPath"] = "--media-path",
        ["UiPath"] = "--path",
        ["ExtraArgs"] = "", // special
    };

    public static readonly IReadOnlyDictionary<string, string> BoolEnvFlags = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
    {
        ["KvUnified"] = "--kv-unified",
        ["CachePrompt"] = "--cache-prompt",
        ["ReasoningPreserve"] = "--reasoning-preserve",
        ["Agent"] = "--agent",
        ["WebUI"] = "--webui",
        ["Jinja"] = "--jinja",
    };

    /// <summary>Env keys that are Manager/meta, not CLI.</summary>
    public static readonly HashSet<string> MetaKeys = new(StringComparer.OrdinalIgnoreCase)
    {
        "ModelsDir", "DefaultModel", "CudaVisibleDevices", "Repo", "AssetMatch", "CudartMatch",
        "TagMatch", "Profile", "RuntimeMode", "ExtraArgs", "UseRouter", "Model", "ModelPath",
    };
}
