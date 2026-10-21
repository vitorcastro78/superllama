using System.Diagnostics;
using System.Text;

namespace LlamaServer.Manager.Core.Runtime;

public sealed class GpuInfoService
{
    public IReadOnlyList<GpuRow> QueryNvidiaSmi()
    {
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "nvidia-smi",
                Arguments = "--query-gpu=index,name,memory.used,memory.total,utilization.gpu --format=csv,noheader,nounits",
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            using var p = Process.Start(psi)!;
            var output = p.StandardOutput.ReadToEnd();
            p.WaitForExit(8000);
            var rows = new List<GpuRow>();
            foreach (var line in output.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            {
                var parts = line.Split(',', StringSplitOptions.TrimEntries);
                if (parts.Length < 5) continue;
                rows.Add(new GpuRow(
                    parts[0],
                    parts[1],
                    parts[2] + " / " + parts[3] + " MiB",
                    parts[4] + " %"));
            }
            return rows;
        }
        catch (Exception ex)
        {
            return new[] { new GpuRow("-", "nvidia-smi unavailable: " + ex.Message, "-", "-") };
        }
    }

    public string ListDevices(string llamaServerExe)
    {
        if (!File.Exists(llamaServerExe)) return "(binary missing)";
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = llamaServerExe,
                Arguments = "--list-devices",
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            using var p = Process.Start(psi)!;
            var sb = new StringBuilder();
            sb.Append(p.StandardOutput.ReadToEnd());
            sb.Append(p.StandardError.ReadToEnd());
            p.WaitForExit(10000);
            return sb.ToString();
        }
        catch (Exception ex) { return ex.Message; }
    }
}

public sealed record GpuRow(string Index, string Name, string Memory, string Util);
