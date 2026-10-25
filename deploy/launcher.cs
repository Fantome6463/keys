using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

// Тонкий запускатор: сама программа - deploy\app.ps1, поэтому обновление по git
// меняет приложение без пересборки этого файла.
static class Program
{
    [STAThread]
    static void Main()
    {
        string root = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(root, "deploy", "app.ps1");
        if (!File.Exists(script))
        {
            MessageBox.Show("Не найден файл deploy\\app.ps1 рядом с программой.", "Журнал ключей",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        ProcessStartInfo info = new ProcessStartInfo("powershell.exe",
            "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + script + "\"");
        info.WorkingDirectory = root;
        info.UseShellExecute = false;
        info.CreateNoWindow = true;
        Process.Start(info);
    }
}
