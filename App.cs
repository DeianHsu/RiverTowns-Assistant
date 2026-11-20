using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("河畔小镇闯关助手")]
[assembly: AssemblyProduct("河畔小镇闯关助手")]

internal static class App
{
    private const string Title = "河畔小镇闯关助手";

    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            if (args.Length != 0 && (args.Length != 2 ||
                    !string.Equals(args[0], "-GamePath", StringComparison.OrdinalIgnoreCase)))
            {
                throw new ArgumentException("请直接打开应用，或用 -GamePath 指定游戏安装目录。");
            }

            using (var instance = new Mutex(false, @"Local\RiverTownsAssistant"))
            {
                bool acquired;
                try { acquired = instance.WaitOne(0); }
                catch (AbandonedMutexException) { acquired = true; }

                if (!acquired)
                    throw new InvalidOperationException(Title + "已经在运行。");

                try
                {
                    string localData = Environment.GetEnvironmentVariable("LOCALAPPDATA");
                    if (string.IsNullOrEmpty(localData))
                        localData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

                    string directory = Path.Combine(localData, "RiverTownsAssistant");
                    ExtractFiles(directory);
                    ShowAssistant(directory, args.Length == 2 ? args[1] : null);
                }
                finally
                {
                    instance.ReleaseMutex();
                }
            }
            return 0;
        }
        catch (Exception error)
        {
            MessageBox.Show(error.Message, Title, MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    private static void ExtractFiles(string directory)
    {
        Assembly package = Assembly.GetExecutingAssembly();
        foreach (string file in package.GetManifestResourceNames())
        {
            string path = Path.Combine(directory, file);
            string next = path + ".next";
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            using (Stream source = package.GetManifestResourceStream(file))
            using (Stream target = File.Create(next))
                source.CopyTo(target);

            // 游戏启动时可能正在读取现有脚本，写完后再替换。
            if (File.Exists(path))
                File.Replace(next, path, null);
            else
                File.Move(next, path);
        }
    }

    private static void ShowAssistant(string directory, string gamePath)
    {
        var settings = InitialSessionState.CreateDefault();
        settings.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
        // 使用 Windows PowerShell 自带的校验和解压命令。
        string modules = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\Modules");
        settings.ImportPSModule(new[]
        {
            Path.Combine(modules, @"Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1"),
            Path.Combine(modules, @"Microsoft.PowerShell.Archive\Microsoft.PowerShell.Archive.psd1")
        });
        using (Runspace runspace = RunspaceFactory.CreateRunspace(settings))
        using (PowerShell shell = PowerShell.Create())
        {
            // 启动脚本与应用在同一线程可重入同一个互斥锁，也可直接显示窗口。
            runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
            runspace.Open();
            shell.Runspace = runspace;
            shell.AddCommand(Path.Combine(directory, "Start.ps1"));
            if (gamePath != null)
                shell.AddParameter("GamePath", gamePath);
            shell.Invoke();
        }
    }
}
