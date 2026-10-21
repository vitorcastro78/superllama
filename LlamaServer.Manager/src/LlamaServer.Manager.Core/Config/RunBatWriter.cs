using System.Diagnostics;

namespace LlamaServer.Manager.Core.Config;

public sealed class RunBatWriter
{
    private readonly LlamaServerPaths _paths;
    private readonly ArgvBuilder _argv = new();

    public RunBatWriter(LlamaServerPaths paths) => _paths = paths;

    /// <summary>Prefer official PowerShell generator; fall back to C# writer.</summary>
    public string Regenerate(EnvFile env)
    {
        env.Save();
        env.SaveCopyTo(_paths.LlamaEnv);

        if (File.Exists(_paths.WriteRunServerBatPs1))
        {
            var psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = $"-NoProfile -ExecutionPolicy Bypass -File \"{_paths.WriteRunServerBatPs1}\" -Root \"{_paths.Root}\"",
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
            };
            using var p = Process.Start(psi)!;
            var stdout = p.StandardOutput.ReadToEnd();
            var stderr = p.StandardError.ReadToEnd();
            p.WaitForExit(60000);
            if (p.ExitCode == 0 && File.Exists(_paths.RunServerBat))
                return _paths.RunServerBat;
            // fall through on failure
            Debug.WriteLine($"Write-RunServerBat failed: {stderr}\n{stdout}");
        }

        return WriteBatFromEnv(env);
    }

    public string WriteBatFromEnv(EnvFile env)
    {
        var exe = _paths.ResolveServerBinary();
        var args = _argv.BuildFromEnv(env, _paths);
        var cuda = env.Get("CudaVisibleDevices") ?? "0";
        // Flatten args the same way as Write-RunServerBat (space-joined with quoted preset/paths)
        var flat = new List<string>();
        for (var i = 0; i < args.Count; i++)
        {
            var a = args[i];
            if (a.StartsWith('-') && i + 1 < args.Count && !args[i + 1].StartsWith('-'))
            {
                var v = args[i + 1];
                if (v.Contains(' ') || a is "--models-preset" or "--media-path" or "--path")
                    flat.Add($"{a} \"{v}\"");
                else
                    flat.Add($"{a} {v}");
                i++;
            }
            else flat.Add(a);
        }
        var joined = string.Join(" ", flat);
        var bat = $@"@echo off
setlocal
set ROOT=%~dp0..
set PATH=%ROOT%\bin;%PATH%
cd /d ""%ROOT%\bin""
set CUDA_VISIBLE_DEVICES={cuda}
""{exe}"" {joined}
";
        Directory.CreateDirectory(_paths.Scripts);
        File.WriteAllText(_paths.RunServerBat, bat.Replace("\n", "\r\n"), System.Text.Encoding.ASCII);
        return _paths.RunServerBat;
    }

    public string PreviewCommand(EnvFile env)
    {
        var exe = _paths.ResolveServerBinary();
        var args = _argv.BuildFromEnv(env, _paths);
        var cuda = env.Get("CudaVisibleDevices") ?? "0";
        return $"CUDA_VISIBLE_DEVICES={cuda}\r\n{_argv.FormatCommandLine(exe, args)}";
    }
}
