// Tiny launcher that turns PrinterDriverInstaller.ps1 into a single .exe.
// The script is embedded inside the exe as a resource. On start the exe:
//   1. asks for administrator rights (one UAC prompt),
//   2. unpacks the script into a protected folder under ProgramData,
//   3. runs it with the Windows PowerShell that ships with Windows (window hidden),
//   4. deletes the unpacked copy when the window closes.
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Principal;

static class Launcher
{
    static bool IsAdmin()
    {
        using (WindowsIdentity id = WindowsIdentity.GetCurrent())
        {
            return new WindowsPrincipal(id).IsInRole(WindowsBuiltInRole.Administrator);
        }
    }

    [STAThread]
    static int Main()
    {
        if (!IsAdmin())
        {
            try
            {
                ProcessStartInfo relaunch = new ProcessStartInfo(Process.GetCurrentProcess().MainModule.FileName);
                relaunch.UseShellExecute = true;
                relaunch.Verb = "runas";
                Process.Start(relaunch);
                return 0;
            }
            catch (Win32Exception)
            {
                return 1; // user pressed "No" on the UAC prompt
            }
        }

        // ProgramData is not writable by normal users, so nothing unprivileged can swap the script
        // between unpacking it and running it with admin rights.
        string dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            "PrinterDriverInstaller", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        try
        {
            string ps1 = Path.Combine(dir, "PrinterDriverInstaller.ps1");
            using (Stream src = Assembly.GetExecutingAssembly().GetManifestResourceStream("payload.ps1"))
            {
                if (src == null) return 2;
                using (FileStream dst = File.Create(ps1)) { src.CopyTo(dst); }
            }

            string powershell = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
            ProcessStartInfo psi = new ProcessStartInfo(powershell,
                "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + ps1 + "\"");
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            using (Process p = Process.Start(psi))
            {
                p.WaitForExit();
                return p.ExitCode;
            }
        }
        finally
        {
            try { Directory.Delete(dir, true); } catch (Exception) { }
        }
    }
}
