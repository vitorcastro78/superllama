namespace LlamaServer.Manager.Core.Config;

public sealed class ModelPreset
{
    public string Name { get; set; } = "";
    public Dictionary<string, string> Values { get; } = new(StringComparer.OrdinalIgnoreCase);

    public string? Get(string key) => Values.TryGetValue(key, out var v) ? v : null;
    public void Set(string key, string? value)
    {
        if (value is null) Values.Remove(key);
        else Values[key] = value;
    }
}

/// <summary>INI-style models-preset.ini for llama-server router.</summary>
public sealed class ModelsPresetFile
{
    public string Path { get; }
    public List<ModelPreset> Presets { get; } = new();
    public List<string> HeaderComments { get; } = new();

    public ModelsPresetFile(string path) => Path = path;

    public static ModelsPresetFile Load(string path)
    {
        var file = new ModelsPresetFile(path);
        if (!File.Exists(path)) return file;

        ModelPreset? current = null;
        foreach (var raw in File.ReadAllLines(path))
        {
            var line = raw.TrimEnd();
            var t = line.Trim();
            if (t.Length == 0)
            {
                continue;
            }
            if (t.StartsWith(';') || t.StartsWith('#'))
            {
                if (current is null) file.HeaderComments.Add(line);
                continue;
            }
            if (t.StartsWith('[') && t.EndsWith(']'))
            {
                current = new ModelPreset { Name = t[1..^1].Trim() };
                file.Presets.Add(current);
                continue;
            }
            if (current is null) continue;
            var eq = t.IndexOf('=');
            if (eq <= 0) continue;
            current.Values[t[..eq].Trim()] = t[(eq + 1)..].Trim();
        }
        return file;
    }

    public ModelPreset? Find(string name) =>
        Presets.FirstOrDefault(p => string.Equals(p.Name, name, StringComparison.OrdinalIgnoreCase));

    public ModelPreset Add(string name)
    {
        var p = new ModelPreset { Name = name };
        Presets.Add(p);
        return p;
    }

    public bool Remove(string name)
    {
        var p = Find(name);
        if (p is null) return false;
        Presets.Remove(p);
        return true;
    }

    public void Save()
    {
        var dir = System.IO.Path.GetDirectoryName(Path);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);

        using var w = new StreamWriter(Path);
        foreach (var c in HeaderComments) w.WriteLine(c);
        if (HeaderComments.Count > 0) w.WriteLine();

        foreach (var p in Presets)
        {
            w.WriteLine($"[{p.Name}]");
            foreach (var (k, v) in p.Values.OrderBy(x => x.Key, StringComparer.OrdinalIgnoreCase))
                w.WriteLine($"{k} = {v}");
            w.WriteLine();
        }
    }
}
