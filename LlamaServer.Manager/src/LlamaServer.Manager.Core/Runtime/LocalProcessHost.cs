using System.Diagnostics;
using System.Text;
using LlamaServer.Manager.Core.Config;

namespace LlamaServer.Manager.Core.Runtime;

public sealed class LocalProcessHost
{
    private readonly LlamaServerPaths _paths;
    private readonly ArgvBuilder _argv = new();
    private Process? _process;
    private readonly StringBuilder _output = new();
    private readonly object _lock = new();

    public LocalProcessHost(LlamaServerPaths paths) => _paths = paths;

    public bool IsRunning
    {
        get
        {
            try { return _process is { HasExited: false }; }
            catch { return false; }
        }
    }

    public int? ProcessId => IsRunning ? _process!.Id : null;

    public string GetOutputSnapshot()
    {
        lock (_lock) return _output.ToString();
    }

    public void ClearOutput()
    {
        lock (_lock) _output.Clear();
    }

    public void Start(EnvFile env)
    {
        Stop();
        ClearOutput();
        var exe = _paths.ResolveServerBinary();
        if (!File.Exists(exe)) throw new FileNotFoundException("llama-server.exe not found", exe);

        var args = _argv.BuildFromEnv(env, _paths);
        var psi = new ProcessStartInfo
        {
            FileName = exe,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            WorkingDirectory = _paths.Bin,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);
        var cuda = env.Get("CudaVisibleDevices") ?? "0";
        psi.Environment["CUDA_VISIBLE_DEVICES"] = cuda;
        psi.Environment["PATH"] = _paths.Bin + Path.PathSeparator + Environment.GetEnvironmentVariable("PATH");

        _process = new Process { StartInfo = psi, EnableRaisingEvents = true };
        _process.OutputDataReceived += (_, e) => { if (e.Data is not null) Append(e.Data); };
        _process.ErrorDataReceived += (_, e) => { if (e.Data is not null) Append(e.Data); };
        _process.Start();
        _process.BeginOutputReadLine();
        _process.BeginErrorReadLine();
    }

    public void Stop()
    {
        if (_process is null) return;
        try
        {
            if (!_process.HasExited)
            {
                _process.Kill(entireProcessTree: true);
                _process.WaitForExit(10000);
            }
        }
        catch { /* ignore */ }
        finally
        {
            _process.Dispose();
            _process = null;
        }
    }

    private void Append(string line)
    {
        lock (_lock)
        {
            _output.AppendLine(line);
            if (_output.Length > 500_000)
                _output.Remove(0, _output.Length - 400_000);
        }
    }
}
