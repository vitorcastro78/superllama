using System.Text.RegularExpressions;

namespace LlamaServer.Manager.Core.Flags;

/// <summary>Parse llama-server --help into flag definitions (no GPL deps).</summary>
public static partial class HelpParser
{
    [GeneratedRegex(@"^\s*(?<flags>-[\w,-]+(?:\s+[^\s]+)?)\s{2,}(?<desc>.+)$", RegexOptions.Compiled)]
    private static partial Regex FlagLineRegex();

    [GeneratedRegex(@"\[(?<opts>[^\]]+)\]", RegexOptions.Compiled)]
    private static partial Regex BracketEnumRegex();

    public static IReadOnlyList<FlagDefinition> Parse(string helpText)
    {
        var results = new List<FlagDefinition>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        string category = "Misc";

        foreach (var raw in helpText.Split('\n'))
        {
            var line = raw.TrimEnd('\r');
            if (line.Length == 0) continue;

            // Section headers often end with ':' and have no leading dash
            var trimmed = line.Trim();
            if (!trimmed.StartsWith('-') && trimmed.EndsWith(':') && trimmed.Length < 60)
            {
                category = NormalizeCategory(trimmed.TrimEnd(':'));
                continue;
            }

            // Continuation description lines
            if (!trimmed.StartsWith('-')) continue;

            // Collect multi-flag first token groups: -h, --help
            var flagsPart = trimmed;
            var desc = "";
            var m = FlagLineRegex().Match(line);
            if (m.Success)
            {
                flagsPart = m.Groups["flags"].Value.Trim();
                desc = m.Groups["desc"].Value.Trim();
            }
            else
            {
                // Fallback: split on 2+ spaces
                var idx = trimmed.IndexOf("  ", StringComparison.Ordinal);
                if (idx > 0)
                {
                    flagsPart = trimmed[..idx].Trim();
                    desc = trimmed[(idx + 2)..].Trim();
                }
            }

            foreach (var flagTok in SplitFlags(flagsPart))
            {
                var (flag, valueHint) = SplitFlagAndHint(flagTok);
                if (flag.Length < 2 || !flag.StartsWith('-')) continue;
                if (!seen.Add(flag)) continue;

                var id = flag.TrimStart('-').Replace('-', '_');
                var type = InferType(flag, valueHint, desc);
                var enums = ExtractEnums(valueHint, desc);

                results.Add(new FlagDefinition
                {
                    Id = id,
                    Flag = flag,
                    Category = Categorize(flag, category, desc),
                    ValueType = type,
                    Description = desc,
                    EnumValues = enums,
                    IsFromHelp = true,
                });
            }
        }

        return results;
    }

    public static IReadOnlyList<FlagDefinition> ParseFromBinary(string exePath)
    {
        if (!File.Exists(exePath)) return Array.Empty<FlagDefinition>();
        var psi = new System.Diagnostics.ProcessStartInfo
        {
            FileName = exePath,
            Arguments = "-h",
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        using var p = System.Diagnostics.Process.Start(psi)!;
        var stdout = p.StandardOutput.ReadToEnd();
        var stderr = p.StandardError.ReadToEnd();
        p.WaitForExit(15000);
        var text = string.IsNullOrWhiteSpace(stdout) ? stderr : stdout + "\n" + stderr;
        return Parse(text);
    }

    private static IEnumerable<string> SplitFlags(string flagsPart)
    {
        // e.g. "-m, --model FNAME" or "-fa, --flash-attn [on|off]"
        var parts = flagsPart.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        foreach (var part in parts)
        {
            if (part.StartsWith('-')) yield return part;
        }
    }

    private static (string flag, string hint) SplitFlagAndHint(string token)
    {
        var bits = token.Split(' ', 2, StringSplitOptions.RemoveEmptyEntries);
        if (bits.Length == 1) return (bits[0], "");
        return (bits[0], bits[1]);
    }

    private static FlagValueType InferType(string flag, string hint, string desc)
    {
        var h = (hint + " " + desc).ToLowerInvariant();
        if (string.IsNullOrWhiteSpace(hint) && !h.Contains("enable") && !h.Contains("disable"))
        {
            // bool flags often have no value token; also --foo / --no-foo
            if (!hint.Contains('N') && !hint.Contains("PATH") && !hint.Contains("FILE") &&
                !hint.Contains("STRING") && !hint.Contains('[') &&
                !Regex.IsMatch(hint, @"\bN\b"))
            {
                if (hint.Length == 0) return FlagValueType.Bool;
            }
        }
        if (hint.Length == 0) return FlagValueType.Bool;
        if (BracketEnumRegex().IsMatch(hint) || h.Contains("on|off") || h.Contains("true|false"))
            return FlagValueType.Enum;
        if (h.Contains("path") || h.Contains("file") || h.Contains("dir") || hint.Contains("FNAME") || hint.Contains("PATH"))
            return FlagValueType.Path;
        if (Regex.IsMatch(hint, @"\bN\b") || h.Contains("number") || h.Contains("size") || h.Contains("count"))
            return FlagValueType.Int;
        if (h.Contains("float") || h.Contains("threshold") || hint.Contains("N.M"))
            return FlagValueType.Float;
        return FlagValueType.String;
    }

    private static IReadOnlyList<string> ExtractEnums(string hint, string desc)
    {
        var m = BracketEnumRegex().Match(hint.Length > 0 ? hint : desc);
        if (!m.Success) return Array.Empty<string>();
        return m.Groups["opts"].Value.Split('|', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
    }

    private static string NormalizeCategory(string header)
    {
        var h = header.Trim();
        if (h.Contains("server", StringComparison.OrdinalIgnoreCase)) return "Server";
        if (h.Contains("sampling", StringComparison.OrdinalIgnoreCase)) return "Sampling";
        if (h.Contains("context", StringComparison.OrdinalIgnoreCase) || h.Contains("KV", StringComparison.OrdinalIgnoreCase)) return "ContextKV";
        if (h.Contains("speculat", StringComparison.OrdinalIgnoreCase)) return "Speculative";
        if (h.Contains("hardware", StringComparison.OrdinalIgnoreCase) || h.Contains("GPU", StringComparison.OrdinalIgnoreCase)) return "Hardware";
        if (h.Contains("model", StringComparison.OrdinalIgnoreCase)) return "Model";
        return h.Length > 0 ? h : "Misc";
    }

    private static string Categorize(string flag, string section, string desc)
    {
        var f = flag.ToLowerInvariant();
        var d = desc.ToLowerInvariant();
        if (f is "--host" or "--port" or "--path" or "--api-prefix" or "--webui" or "--no-webui" or "--models-preset" or "--models-max")
            return "Server";
        if (f.Contains("gpu") || f.Contains("device") || f.Contains("ngl") || f.Contains("split") || f.Contains("tensor") || f.Contains("cuda") || f.Contains("threads"))
            return "Hardware";
        if (f.Contains("ctx") || f.Contains("cache") || f.Contains("kv") || f.Contains("batch") || f.Contains("ubatch") || f.Contains("parallel") || f.Contains("slot"))
            return "ContextKV";
        if (f.Contains("spec") || f.Contains("draft") || f.Contains("ngram"))
            return "Speculative";
        if (f.Contains("reason") || f.Contains("agent") || f.Contains("tool") || f.Contains("jinja"))
            return "AgentTools";
        if (f.Contains("temp") || f.Contains("top-") || f.Contains("sample") || f.Contains("mirostat") || f.Contains("penalty") || f.Contains("dry-"))
            return "Sampling";
        if (f.Contains("model") || f.Contains("mmproj") || f.Contains("lora") || f.Contains("alias"))
            return "Model";
        if (f.Contains("log") || f.Contains("verbose") || f.Contains("metric"))
            return "Logging";
        if (!string.IsNullOrEmpty(section) && section != "Misc") return section;
        if (d.Contains("sampling")) return "Sampling";
        return "Misc";
    }
}
