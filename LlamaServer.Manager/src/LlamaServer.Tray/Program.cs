using System.Threading;

namespace LlamaServer.Tray;

internal static class Program
{
    private const string MutexName = "Global\\LlamaServer.Tray.Singleton";

    [STAThread]
    private static void Main(string[] args)
    {
        using var mutex = new Mutex(true, MutexName, out var created);
        if (!created)
        {
            // Already running — ignore second launch
            return;
        }

        ApplicationConfiguration.Initialize();
        Application.Run(new TrayApplicationContext(args));
    }
}
