namespace LlamaServer.Manager.Core.Config;

/// <summary>Read/write KEY=VALUE env files (server.env / llama.env).</summary>
public sealed class EnvFile
{
    private readonly Dictionary<string, string> _values = new(StringComparer.OrdinalIgnoreCase);
    private readonly List<string> _lines = new();

    public string Path { get; }
    public IReadOnlyDictionary<string, string> Values => _values;

    public EnvFile(string path) => Path = path;

    public static EnvFile Load(string path)
    {
        var env = new EnvFile(path);
        if (!File.Exists(path)) return env;
        foreach (var line in File.ReadAllLines(path))
        {
            env._lines.Add(line);
            var t = line.Trim();
            if (t.Length == 0 || t.StartsWith('#')) continue;
            var eq = t.IndexOf('=');
            if (eq <= 0) continue;
            var k = t[..eq].Trim();
            var v = t[(eq + 1)..].Trim();
            env._values[k] = v;
        }
        return env;
    }

    public string? Get(string key) => _values.TryGetValue(key, out var v) ? v : null;

    public void Set(string key, string? value)
    {
        if (value is null)
        {
            _values.Remove(key);
            return;
        }
        _values[key] = value;
    }

    public void SetMany(IEnumerable<KeyValuePair<string, string?>> pairs)
    {
        foreach (var (k, v) in pairs) Set(k, v);
    }

    public bool IsTruthy(string key, bool defaultValue = false)
    {
        var v = Get(key);
        if (v is null) return defaultValue;
        return v is "1" or "true" or "on" or "yes" or "True" or "ON" or "YES";
    }

    public void Save()
    {
        var dir = System.IO.Path.GetDirectoryName(Path);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);

        var written = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var outLines = new List<string>();

        foreach (var line in _lines)
        {
            var t = line.Trim();
            if (t.Length == 0 || t.StartsWith('#') || !t.Contains('='))
            {
                outLines.Add(line);
                continue;
            }
            var eq = t.IndexOf('=');
            var k = t[..eq].Trim();
            if (_values.TryGetValue(k, out var v))
            {
                outLines.Add($"{k}={v}");
                written.Add(k);
            }
            // else drop removed keys
        }

        foreach (var (k, v) in _values.OrderBy(x => x.Key, StringComparer.OrdinalIgnoreCase))
        {
            if (written.Contains(k)) continue;
            outLines.Add($"{k}={v}");
        }

        File.WriteAllLines(Path, outLines);
    }

    public void SaveCopyTo(string otherPath)
    {
        Save();
        var dir = System.IO.Path.GetDirectoryName(otherPath);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        File.Copy(Path, otherPath, overwrite: true);
    }
}
