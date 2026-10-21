using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace LlamaServer.Manager.Core.Runtime;

public sealed class HealthClient
{
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(3) };
    private readonly HttpClient _longHttp = new() { Timeout = TimeSpan.FromMinutes(10) };

    public async Task<HealthResult> CheckAsync(string host = "127.0.0.1", int port = 11434, CancellationToken ct = default)
    {
        var url = $"http://{host}:{port}/health";
        try
        {
            var resp = await _http.GetAsync(url, ct);
            var body = await resp.Content.ReadAsStringAsync(ct);
            return new HealthResult(resp.IsSuccessStatusCode, body, null);
        }
        catch (Exception ex)
        {
            return new HealthResult(false, null, ex.Message);
        }
    }

    public async Task<IReadOnlyList<string>> ListModelsAsync(string host = "127.0.0.1", int port = 11434, CancellationToken ct = default)
    {
        var models = await ListModelDetailsAsync(host, port, ct);
        return models.Select(m => $"{m.Id} [{m.Status}]").ToList();
    }

    public async Task<IReadOnlyList<ModelInfo>> ListModelDetailsAsync(string host = "127.0.0.1", int port = 11434, CancellationToken ct = default)
    {
        try
        {
            var doc = await _http.GetFromJsonAsync<ModelsResponse>($"http://{host}:{port}/v1/models", ct);
            return doc?.Data?.Select(d =>
            {
                var device = ExtractArg(d.Status?.Args, "--device") ?? "?";
                var mainGpu = ExtractArg(d.Status?.Args, "--main-gpu");
                return new ModelInfo(d.Id ?? "?", d.Status?.Value ?? "?", device, mainGpu);
            }).ToList() ?? new List<ModelInfo>();
        }
        catch { return Array.Empty<ModelInfo>(); }
    }

    /// <summary>Força o router a carregar o modelo (pedido mínimo chat/completions).</summary>
    public async Task<(bool ok, string detail)> WarmLoadAsync(string modelId, string host = "127.0.0.1", int port = 11434, CancellationToken ct = default)
    {
        var payload = JsonSerializer.Serialize(new
        {
            model = modelId,
            messages = new[] { new { role = "user", content = "ping" } },
            max_tokens = 1,
            stream = false,
        });
        try
        {
            using var content = new StringContent(payload, Encoding.UTF8, "application/json");
            var resp = await _longHttp.PostAsync($"http://{host}:{port}/v1/chat/completions", content, ct);
            var body = await resp.Content.ReadAsStringAsync(ct);
            if (!resp.IsSuccessStatusCode)
                return (false, $"HTTP {(int)resp.StatusCode}: {Truncate(body, 200)}");
            return (true, "carregado");
        }
        catch (Exception ex)
        {
            return (false, ex.Message);
        }
    }

    private static string? ExtractArg(List<string>? args, string flag)
    {
        if (args is null) return null;
        for (var i = 0; i < args.Count - 1; i++)
            if (string.Equals(args[i], flag, StringComparison.OrdinalIgnoreCase))
                return args[i + 1];
        return null;
    }

    private static string Truncate(string s, int n) => s.Length <= n ? s : s[..n] + "…";

    private sealed class ModelsResponse
    {
        [JsonPropertyName("data")] public List<ModelItem>? Data { get; set; }
    }
    private sealed class ModelItem
    {
        [JsonPropertyName("id")] public string? Id { get; set; }
        [JsonPropertyName("status")] public StatusObj? Status { get; set; }
    }
    private sealed class StatusObj
    {
        [JsonPropertyName("value")] public string? Value { get; set; }
        [JsonPropertyName("args")] public List<string>? Args { get; set; }
    }
}

public sealed record HealthResult(bool Ok, string? Body, string? Error);
public sealed record ModelInfo(string Id, string Status, string Device, string? MainGpu);
