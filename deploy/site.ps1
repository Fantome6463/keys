<#
.SYNOPSIS
  «Журнал ключей» из консоли (то же, что кнопки в окне).

.EXAMPLE
  keys.bat status        # работает ли сайт, автозапуск, админ, домен, копии, версия
  keys.bat install       # установить: Python, библиотеки, автозапуск, брандмауэр
  keys.bat admin         # логин и пароль админа (спросит)
  keys.bat staff         # логин и пароль сотрудников (спросит)
  keys.bat update        # обновить сайт из GitHub и перезапустить
  keys.bat restart       # перезапустить сайт
  keys.bat start | stop  # запустить / остановить сайт
  keys.bat autostart on|off  # запускать ли сайт вместе с компьютером
  keys.bat backup        # резервная копия базы прямо сейчас
  keys.bat domain ключи.рф   # указать домен (пусто - без домена)
  keys.bat crm D:\New_Lab_3D # указать папку CRM вручную
  keys.bat uninstall     # убрать из автозапуска (база остаётся)
#>
param(
    [Parameter(Position = 0)][string]$Command = "status",
    [Parameter(Position = 1)][string]$Value = ""
)

. (Join-Path $PSScriptRoot "lib.ps1")

try {
    switch ($Command.ToLower()) {
        "install" { Install-Site }
        "update" { Update-Site }
        "restart" { Restart-Server }
        "start" { Start-Site }
        "stop" { Stop-Site }
        "autostart" { Set-Autostart ([int]($Value -in "on", "1", "да", "вкл")) }
        "backup" { Backup-Now }
        "uninstall" { Uninstall-Site }
        "domain" { Set-Domain $Value; if ($Value) { Connect-Domain } else { Write-Log "Домен убран." "ok" } }
        "crm" { Set-CrmRoot $Value; Write-Log "Папка CRM: $Value" "ok" }
        { $_ -in "admin", "staff" } {
            if (-not (Test-Path $script:VenvPython)) { Install-Requirements }
            Push-Location $script:Root
            try { & $script:VenvPython -m flask --app app set-account --role $Command.ToLower() } finally { Pop-Location }
        }
        "status" {
            $s = Get-SiteStatus
            Write-Log "Журнал ключей" "step"
            Write-Log ("Сайт       : " + $(if ($s.Online) { "$($s.Url) работает" } else { "не отвечает" })) $(if ($s.Online) { "ok" } else { "warn" })
            Write-Log ("Автозапуск : " + $(if ($s.Installed) { "да ($($s.TaskState))" } else { "нет" })) $(if ($s.Installed) { "ok" } else { "warn" })
            $acc = $s.Accounts
            Write-Log ("Админ      : " + $(if ($acc.Admin) { $acc.Admin } else { "нет (keys.bat admin)" })) $(if ($acc.Admin) { "ok" } else { "warn" })
            Write-Log ("Сотрудники : " + $(if ($acc.Staff) { $acc.Staff } else { "нет (keys.bat staff)" })) $(if ($acc.Staff) { "ok" } else { "warn" })
            if ($s.Domain) { Write-Log ("Домен      : $($s.Domain) " + $(if ($s.DomainOnline) { "работает" } else { "не отвечает" })) $(if ($s.DomainOnline) { "ok" } else { "warn" }) }
            Write-Log ("Копия базы : " + $(if ($s.LastBackup) { $s.LastBackup.Name } else { "ещё нет" }))
            $v = $s.Version
            if ($v.isRepo) { Write-Log ("Версия     : $($v.head) от $($v.date), обновлений: $($v.behind)") }
        }
        default { throw "Неизвестная команда '$Command'. Есть: status, install, start, stop, autostart on|off, admin, staff, update, restart, backup, domain, crm, uninstall." }
    }
}
catch {
    Write-Log $_.Exception.Message "err"
    exit 1
}
