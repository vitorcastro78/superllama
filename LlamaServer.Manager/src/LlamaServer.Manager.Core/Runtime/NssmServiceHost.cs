using System.Diagnostics;
using System.ServiceProcess;
using LlamaServer.Manager.Core.Config;

namespace LlamaServer.Manager.Core.Runtime;

public sealed class NssmServiceHost
{
    public const string DefaultServiceName = "LlamaServer";

    public string ServiceName { get; }
    public LlamaServerPaths Paths { get; }

    public NssmServiceHost(LlamaServerPaths paths, string serviceName = DefaultServiceName)
    {
        Paths = paths;
        ServiceName = serviceName;
    }

    public string? FindNssm()
    {
        // Packaged SuperLlama ships nssm next to the install root
        foreach (var candidate in new[]
                 {
                     Path.Combine(Paths.Root, "tools", "nssm.exe"),
                     Path.Combine(Paths.Bin, "nssm.exe"),
                     @"C:\LlamaServer\tools\nssm.exe",
                 })
        {
            if (File.Exists(candidate)) return candidate;
        }

        var fromPath = FindOnPath("nssm.exe");
        if (fromPath is not null) return fromPath;

        var winget = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            @"Microsoft\WinGet\Links\nssm.exe");
        if (File.Exists(winget)) return winget;

        foreach (var candidate in new[]
                 {
                     Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "nssm", "nssm.exe"),
                     Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "nssm", "win64", "nssm.exe"),
                 })
        {
            if (File.Exists(candidate)) return candidate;
        }

        return null;
    }

    public ServiceControllerStatus? GetStatus()
    {
        try
        {
            using var sc = new ServiceController(ServiceName);
            return sc.Status;
        }
        catch { return null; }
    }

    public bool IsRunning() => GetStatus() == ServiceControllerStatus.Running;

    public (int exitCode, string output) Control(string action, bool elevate = true)
    {
        // action: start|stop|restart
        var nssm = FindNssm();
        if (string.IsNullOrWhiteSpace(nssm))
            return (-1, "nssm.exe nao encontrado (esperado em " + Path.Combine(Paths.Root, "tools", "nssm.exe") + ")");

        var nssmEsc = nssm.Replace("'", "''");
        var toolsNssm = Path.Combine(Paths.Root, "tools", "nssm.exe").Replace("'", "''");
        var envEsc = Paths.ServerEnv.Replace("'", "''");
        var script = $@"
$ErrorActionPreference='Stop'
$nssm = '{nssmEsc}'
if (-not (Test-Path -LiteralPath $nssm)) {{
  $cmd = (Get-Command nssm.exe -EA SilentlyContinue | Select-Object -ExpandProperty Source -EA SilentlyContinue)
  foreach ($c in @('{toolsNssm}', 'C:\LlamaServer\tools\nssm.exe', $cmd)) {{
    if ($c -and (Test-Path -LiteralPath $c)) {{ $nssm = $c; break }}
  }}
}}
if (-not $nssm -or -not (Test-Path -LiteralPath $nssm)) {{ throw ""nssm.exe nao encontrado"" }}
& $nssm {action} {ServiceName}
$m = Select-String -Path '{envEsc}' -Pattern '^CudaVisibleDevices=(.+)$' -EA SilentlyContinue
$cuda = if ($m) {{ $m.Matches.Groups[1].Value }} else {{ $null }}
if ($cuda) {{ & $nssm set {ServiceName} AppEnvironmentExtra ""CUDA_VISIBLE_DEVICES=$cuda"" }}
Write-Output ""exit=$LASTEXITCODE status=$((Get-Service {ServiceName} -EA SilentlyContinue).Status)""
";
        return RunPowerShell(script, elevate);
    }

    public (int exitCode, string output) SyncCudaVisibleDevices()
    {
        var env = EnvFile.Load(Paths.ServerEnv);
        var cuda = env.Get("CudaVisibleDevices") ?? "0";
        var nssm = FindNssm();
        if (string.IsNullOrWhiteSpace(nssm))
            return (-1, "nssm.exe nao encontrado (esperado em " + Path.Combine(Paths.Root, "tools", "nssm.exe") + ")");

        var nssmEsc = nssm.Replace("'", "''");
        var toolsNssm = Path.Combine(Paths.Root, "tools", "nssm.exe").Replace("'", "''");
        var script = $@"
$ErrorActionPreference='Stop'
$nssm = '{nssmEsc}'
if (-not (Test-Path -LiteralPath $nssm)) {{
  $cmd = (Get-Command nssm.exe -EA SilentlyContinue | Select-Object -ExpandProperty Source -EA SilentlyContinue)
  foreach ($c in @('{toolsNssm}', 'C:\LlamaServer\tools\nssm.exe', $cmd)) {{
    if ($c -and (Test-Path -LiteralPath $c)) {{ $nssm = $c; break }}
  }}
}}
if (-not $nssm -or -not (Test-Path -LiteralPath $nssm)) {{ throw ""nssm.exe nao encontrado"" }}
& $nssm set {ServiceName} AppEnvironmentExtra ""CUDA_VISIBLE_DEVICES={cuda.Replace("\"", "")}""
Write-Output ""set cuda=$cuda exit=$LASTEXITCODE""
";
        return RunPowerShell(script, elevate: true);
    }

    private static (int exitCode, string output) RunPowerShell(string script, bool elevate)
    {
        var tmp = Path.Combine(Path.GetTempPath(), "lsm-" + Guid.NewGuid().ToString("N") + ".ps1");
        File.WriteAllText(tmp, script);
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = $"-NoProfile -ExecutionPolicy Bypass -File \"{tmp}\"",
                UseShellExecute = elevate,
                Verb = elevate ? "runas" : "",
                RedirectStandardOutput = !elevate,
                RedirectStandardError = !elevate,
                CreateNoWindow = !elevate,
            };
            if (elevate)
            {
                using var p = Process.Start(psi)!;
                p.WaitForExit(120000);
                return (p.ExitCode, $"elevated exit={p.ExitCode}");
            }
            else
            {
                psi.UseShellExecute = false;
                using var p = Process.Start(psi)!;
                var o = p.StandardOutput.ReadToEnd() + p.StandardError.ReadToEnd();
                p.WaitForExit(120000);
                return (p.ExitCode, o);
            }
        }
        catch (Exception ex)
        {
            return (-1, ex.Message);
        }
        finally
        {
            try { File.Delete(tmp); } catch { /* ignore */ }
        }
    }

    private static string? FindOnPath(string file)
    {
        var path = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var dir in path.Split(Path.PathSeparator))
        {
            try
            {
                var candidate = Path.Combine(dir.Trim('"'), file);
                if (File.Exists(candidate)) return candidate;
            }
            catch { /* ignore */ }
        }
        return null;
    }
}
