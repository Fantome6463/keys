<#
.SYNOPSIS
  Окно управления «Журналом ключей» (запускается через Keys.exe / keys.bat).
  Устанавливает сайт в автозапуск, показывает, работает ли он, обновляет из GitHub.

.NOTES
  Сайт работает в фоне (задача Планировщика Windows), закрытие окна на него не влияет.
  Долгие проверки идут в отдельном потоке - окно не зависает.
#>
. (Join-Path $PSScriptRoot "lib.ps1")
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, Microsoft.VisualBasic
[Windows.Forms.Application]::EnableVisualStyles()

# ---------------------------------------------------------------- палитра
function New-Color([int]$R, [int]$G, [int]$B) { return [Drawing.Color]::FromArgb($R, $G, $B) }
$ColBg = New-Color 15 18 24
$ColCard = New-Color 24 29 38
$ColLine = New-Color 41 49 64
$ColInk = New-Color 233 237 245
$ColMuted = New-Color 154 163 182
$ColAccent = New-Color 37 99 235
$ColAccentHi = New-Color 59 130 246
$ColGreen = New-Color 79 209 143
$ColYellow = New-Color 247 185 85
$ColRed = New-Color 240 110 110

$FontUi = New-Object Drawing.Font("Segoe UI", 10)
$FontBold = New-Object Drawing.Font("Segoe UI Semibold", 10)
$FontTitle = New-Object Drawing.Font("Segoe UI Semibold", 17)
$FontMono = New-Object Drawing.Font("Consolas", 9.5)

# ---------------------------------------------------------------- окно
$form = New-Object Windows.Forms.Form
$form.Text = "Журнал ключей - управление сайтом"
$form.StartPosition = "CenterScreen"
$form.ClientSize = New-Object Drawing.Size(860, 660)
$form.MinimumSize = New-Object Drawing.Size(660, 540)
$form.BackColor = $ColBg
$form.ForeColor = $ColInk
$form.Font = $FontUi
$icon = Join-Path $PSScriptRoot "app.ico"
if (Test-Path $icon) { $form.Icon = New-Object Drawing.Icon($icon) }

# шапка
$header = New-Object Windows.Forms.Panel
$header.Dock = "Top"; $header.Height = 86; $header.BackColor = $ColAccent
$header.Add_Paint({
    param($s, $e)
    $rect = $s.ClientRectangle
    $brush = New-Object Drawing.Drawing2D.LinearGradientBrush($rect, (New-Color 37 99 235), (New-Color 13 148 136), 0.0)
    $e.Graphics.FillRectangle($brush, $rect); $brush.Dispose()
})
$title = New-Object Windows.Forms.Label
$title.Text = "Журнал ключей"; $title.Font = $FontTitle; $title.ForeColor = [Drawing.Color]::White
$title.BackColor = [Drawing.Color]::Transparent; $title.AutoSize = $true; $title.Location = New-Object Drawing.Point(22, 14)
$subtitle = New-Object Windows.Forms.Label
$subtitle.Text = "управление сайтом"; $subtitle.ForeColor = (New-Color 214 232 255)
$subtitle.BackColor = [Drawing.Color]::Transparent; $subtitle.AutoSize = $true; $subtitle.Location = New-Object Drawing.Point(25, 52)
$header.Controls.AddRange(@($title, $subtitle))

# карточка статуса
$card = New-Object Windows.Forms.TableLayoutPanel
$card.Dock = "Top"; $card.AutoSize = $true; $card.AutoSizeMode = "GrowAndShrink"; $card.BackColor = $ColCard
$card.Padding = New-Object Windows.Forms.Padding(20, 14, 20, 10)
$card.ColumnCount = 2; $card.RowCount = 7
[void]$card.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle("Absolute", 150)))
[void]$card.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle("Percent", 100)))

$script:StatusLabels = @{}
foreach ($row in @(@("site", "Сайт"), @("auto", "Автозапуск"), @("admin", "Логины"), @("domain", "Домен"),
        @("backup", "Резервная копия"), @("ver", "Версия"), @("hint", ""))) {
    $name = New-Object Windows.Forms.Label
    $name.Text = $row[1]; $name.ForeColor = $ColMuted; $name.AutoSize = $true; $name.Margin = New-Object Windows.Forms.Padding(0, 5, 0, 5)
    $value = New-Object Windows.Forms.Label
    $value.Text = "проверяю..."; $value.ForeColor = $ColMuted; $value.AutoSize = $true; $value.Font = $FontBold
    $value.MaximumSize = New-Object Drawing.Size(580, 0); $value.Margin = New-Object Windows.Forms.Padding(0, 5, 0, 5)
    $card.Controls.Add($name); $card.Controls.Add($value)
    $script:StatusLabels[$row[0]] = $value
}
$script:StatusLabels["hint"].Font = $FontUi

# кнопки
$bar = New-Object Windows.Forms.FlowLayoutPanel
# высота по содержимому: при масштабе экрана 125-150% кнопки переносятся на вторую строку
$bar.Dock = "Top"; $bar.AutoSize = $true; $bar.AutoSizeMode = "GrowAndShrink"; $bar.WrapContents = $true
$bar.BackColor = $ColBg
$bar.Padding = New-Object Windows.Forms.Padding(16, 14, 16, 0)

function New-Button([string]$Text, [bool]$Primary = $false) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $Text; $b.AutoSize = $true; $b.Height = 38
    $b.Padding = New-Object Windows.Forms.Padding(12, 2, 12, 2)
    $b.Margin = New-Object Windows.Forms.Padding(0, 0, 10, 10)
    $b.FlatStyle = "Flat"; $b.Cursor = "Hand"; $b.Font = $FontBold
    $b.FlatAppearance.BorderSize = 1
    if ($Primary) {
        $b.BackColor = $ColAccent; $b.ForeColor = [Drawing.Color]::White
        $b.FlatAppearance.BorderColor = $ColAccent; $b.FlatAppearance.MouseOverBackColor = $ColAccentHi
    }
    else {
        $b.BackColor = $ColCard; $b.ForeColor = $ColInk
        $b.FlatAppearance.BorderColor = $ColLine; $b.FlatAppearance.MouseOverBackColor = $ColLine
    }
    return $b
}
$btnInstall = New-Button "Установить и запустить" $true
$btnUpdate = New-Button "Обновить сайт"
$btnOpen = New-Button "Открыть сайт"
$btnAdmin = New-Button "Логины и пароли"
$btnCheck = New-Button "Проверить"
$btnMore = New-Button "..."
$bar.Controls.AddRange(@($btnInstall, $btnUpdate, $btnOpen, $btnAdmin, $btnCheck, $btnMore))
$script:BusyButtons = @($btnInstall, $btnUpdate, $btnAdmin, $btnCheck, $btnMore)

$menu = New-Object Windows.Forms.ContextMenuStrip
$miAuto = $menu.Items.Add("Запускать вместе с компьютером")
$miRestart = $menu.Items.Add("Перезапустить сайт")
$miStop = $menu.Items.Add("Остановить сайт")
$miReinstall = $menu.Items.Add("Переустановить")
[void]$menu.Items.Add("-")
$miBackup = $menu.Items.Add("Сделать резервную копию сейчас")
$miBackupDir = $menu.Items.Add("Открыть папку с копиями")
[void]$menu.Items.Add("-")
$miDomain = $menu.Items.Add("Указать домен...")
$miCrm = $menu.Items.Add("Указать папку CRM (для домена)...")
[void]$menu.Items.Add("-")
$miCopy = $menu.Items.Add("Скопировать адрес сайта")
$miLog = $menu.Items.Add("Открыть журнал сервера")
$miFolder = $menu.Items.Add("Открыть папку сайта")


# журнал
$log = New-Object Windows.Forms.RichTextBox
$log.Dock = "Fill"; $log.ReadOnly = $true; $log.BorderStyle = "None"
$log.BackColor = (New-Color 10 12 17); $log.ForeColor = $ColMuted; $log.Font = $FontMono
$logWrap = New-Object Windows.Forms.Panel
$logWrap.Dock = "Fill"; $logWrap.Padding = New-Object Windows.Forms.Padding(16, 4, 16, 16); $logWrap.BackColor = $ColBg
$logWrap.Controls.Add($log)

# порядок Dock: сначала Fill, потом верхние снизу вверх
$form.Controls.Add($logWrap)
$form.Controls.Add($bar)
$form.Controls.Add($card)
$form.Controls.Add($header)

function Add-LogLine([string]$Text, [string]$Kind = "info") {
    $color = switch ($Kind) { "ok" { $ColGreen } "warn" { $ColYellow } "err" { $ColRed } "step" { $ColAccentHi } default { $ColMuted } }
    $log.SelectionStart = $log.TextLength
    $log.SelectionColor = $color
    $prefix = if ($Kind -eq "step") { "`n> " } else { "  " }
    $log.AppendText($prefix + $Text + "`n")
    $log.ScrollToCaret()
}
$script:LogSink = { param([string]$Text, [string]$Kind) Add-LogLine $Text $Kind }

# ---------------------------------------------------------------- фоновые задачи
# Установка, проверки и обновление идут в отдельном потоке PowerShell,
# сообщения приходят через очередь, таймер переносит их в окно.
$script:Queue = [Collections.Concurrent.ConcurrentQueue[object]]::new()
$script:Job = $null
$script:OnDone = $null
$libPath = Join-Path $PSScriptRoot "lib.ps1"

function Start-Background([string]$Body, [scriptblock]$OnDone) {
    if ($script:Job) { return $false }
    foreach ($b in $script:BusyButtons) { $b.Enabled = $false }
    $form.Cursor = "AppStarting"
    $ps = [powershell]::Create()
    $script_ = @"
param(`$lib, `$queue)
. `$lib
`$script:LogSink = { param([string]`$t, [string]`$k) `$queue.Enqueue(@('log', `$t, `$k)) }
try { `$result = & { $Body }; `$queue.Enqueue(@('result', `$result)) }
catch { `$queue.Enqueue(@('log', `$_.Exception.Message, 'err')); `$queue.Enqueue(@('result', `$null)) }
"@
    [void]$ps.AddScript($script_).AddArgument($libPath).AddArgument($script:Queue)
    $script:Job = @{ Ps = $ps; Handle = $ps.BeginInvoke() }
    $script:OnDone = $OnDone
    return $true
}

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 150
$timer.Add_Tick({
    $item = $null
    while ($script:Queue.TryDequeue([ref]$item)) {
        if ($item[0] -eq "log") { Add-LogLine $item[1] $item[2] }
        elseif ($item[0] -eq "result") { $script:LastResult = $item[1] }
    }
    if ($script:Job -and $script:Job.Handle.IsCompleted) {
        try { [void]$script:Job.Ps.EndInvoke($script:Job.Handle) } catch { }
        $script:Job.Ps.Dispose()
        $script:Job = $null
        foreach ($b in $script:BusyButtons) { $b.Enabled = $true }
        $form.Cursor = "Default"
        $done = $script:OnDone; $script:OnDone = $null
        if ($done) { & $done $script:LastResult }
    }
})

# ---------------------------------------------------------------- статус
function Set-Status([string]$Key, [string]$Text, $Color) {
    $script:StatusLabels[$Key].Text = $Text
    $script:StatusLabels[$Key].ForeColor = $Color
}

function Show-Status($s) {
    if (-not $s) { return }
    $script:Status = $s
    if ($s.Online) { Set-Status "site" ("● $($s.Url) - работает") $ColGreen }
    elseif ($s.Ready) { Set-Status "site" ("● остановлен - нажмите «Запустить сайт»") $ColYellow }
    else { Set-Status "site" "● не установлен" $ColRed }

    if ($s.Installed) { Set-Status "auto" "включён - сайт сам запускается вместе с компьютером" $ColGreen }
    else { Set-Status "auto" "выключен - после включения компьютера нажмите «Запустить сайт»" $ColMuted }

    $acc = $s.Accounts
    $parts = @(("админ: " + $(if ($acc.Admin) { $acc.Admin } else { "не задан" })),
               ("сотрудники: " + $(if ($acc.Staff) { $acc.Staff } else { "не задан" })))
    $color = if ($acc.Admin -and $acc.Staff) { $ColGreen } elseif ($acc.Admin -or $acc.Staff) { $ColYellow } else { $ColRed }
    Set-Status "admin" ($parts -join "   ·   ") $color

    if (-not $s.Domain) { Set-Status "domain" "не указан - сайт открывается по IP в сети работы" $ColMuted }
    elseif ($s.DomainOnline) { Set-Status "domain" "https://$($s.Domain) - работает" $ColGreen }
    elseif (-not $s.Crm) { Set-Status "domain" "$($s.Domain): CRM с Caddy не найдена - укажите её папку через «...»" $ColYellow }
    elseif (-not $s.DnsIp) { Set-Status "domain" "$($s.Domain): записи A в DNS пока нет" $ColYellow }
    elseif ($s.PublicIp -and $s.DnsIp -ne $s.PublicIp) { Set-Status "domain" "$($s.Domain) -> $($s.DnsIp), а у сервера $($s.PublicIp)" $ColYellow }
    elseif (-not $s.DomainLinked) { Set-Status "domain" "$($s.Domain): не подключён - нажмите «Установить и запустить»" $ColYellow }
    else { Set-Status "domain" "$($s.Domain): подключён, пока не отвечает" $ColYellow }

    if ($s.LastBackup) {
        $age = (Get-Date) - $s.LastBackup.LastWriteTime
        $color = if ($age.TotalDays -lt 2) { $ColGreen } else { $ColYellow }
        Set-Status "backup" ("$($s.LastBackup.LastWriteTime.ToString('dd.MM.yyyy HH:mm')) - делается сама раз в сутки, хранятся 30 последних") $color
    }
    else { Set-Status "backup" "ещё нет (появится после запуска сайта)" $ColMuted }

    $v = $s.Version
    if (-not $v.isRepo) { Set-Status "ver" "папка не из git - обновление недоступно" $ColYellow }
    elseif ($v.behind -gt 0) { Set-Status "ver" ("$($v.date) - доступно обновлений: $($v.behind)") $ColYellow }
    elseif ($v.error) { Set-Status "ver" ("$($v.date) - не удалось проверить обновления") $ColYellow }
    else { Set-Status "ver" ("$($v.date) - последняя версия") $ColGreen }

    # подсказка: что сделать дальше
    $hint = ""
    if (-not $s.Ready) { $hint = "Нажмите «Установить и запустить» - поставится всё нужное. Автозапуск включается в «...»." }
    elseif (-not $acc.Admin -or -not $acc.Staff) { $hint = "Нажмите «Логины и пароли» и задайте два входа: для админа (меняет всё) и общий для сотрудников (только примечания, ИБП, Электрон)." }
    elseif (-not $s.Online) { $hint = "Сайт не запущен. Нажмите «Запустить сайт», а если не запускается - «...» -> «Открыть журнал сервера»." }
    elseif ($v.behind -gt 0) { $hint = "Нажмите «Обновить сайт»: " + (($v.commits | Select-Object -First 3) -join "; ") }
    else { $hint = "Откройте на любом компьютере или телефоне в сети работы: $($s.Url)" }
    Set-Status "hint" $hint $ColMuted
    $btnInstall.Text = if (-not $s.Ready) { "Установить и запустить" } elseif (-not $s.Online) { "Запустить сайт" } else { "Перезапустить" }
    $miAuto.Checked = $s.Installed
    $miRestart.Enabled = $s.Ready
    $miStop.Enabled = $s.Online
    $miReinstall.Enabled = $s.Ready
}

function Start-Check {
    if ($script:Job) { return }
    foreach ($k in @("site", "auto", "admin", "domain", "backup", "ver")) { Set-Status $k "проверяю..." $ColMuted }
    [void](Start-Background "Get-SiteStatus" { param($r) Show-Status $r })
}

# Окошко «логины и пароли»: кому (админ / сотрудники), логин, пароль два раза.
function Show-AccountDialog {
    $acc = if ($script:Status) { $script:Status.Accounts } else { [pscustomobject]@{ Admin = ""; Staff = "" } }
    $dlg = New-Object Windows.Forms.Form
    $dlg.Text = "Логины и пароли"; $dlg.StartPosition = "CenterParent"; $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false; $dlg.ClientSize = New-Object Drawing.Size(400, 330)
    $dlg.BackColor = $ColCard; $dlg.ForeColor = $ColInk; $dlg.Font = $FontUi
    $rbAdmin = New-Object Windows.Forms.RadioButton; $rbAdmin.Text = "Админ - может всё добавлять и менять"
    $rbAdmin.Location = New-Object Drawing.Point(16, 14); $rbAdmin.AutoSize = $true; $rbAdmin.Checked = [bool]$acc.Admin -or -not $acc.Staff
    $rbStaff = New-Object Windows.Forms.RadioButton; $rbStaff.Text = "Сотрудники - общий вход, только примечания"
    $rbStaff.Location = New-Object Drawing.Point(16, 40); $rbStaff.AutoSize = $true
    if ($acc.Admin -and -not $acc.Staff) { $rbStaff.Checked = $true }
    $dlg.Controls.AddRange(@($rbAdmin, $rbStaff))
    $fields = @{}
    $y = 76
    foreach ($f in @(@("user", "Логин", $false), @("pass", "Новый пароль (не короче 6 символов)", $true), @("pass2", "Пароль ещё раз", $true))) {
        $l = New-Object Windows.Forms.Label; $l.Text = $f[1]; $l.AutoSize = $true; $l.ForeColor = $ColMuted
        $l.Location = New-Object Drawing.Point(16, $y)
        $t = New-Object Windows.Forms.TextBox; $t.Location = New-Object Drawing.Point(16, ($y + 20)); $t.Width = 368
        $t.UseSystemPasswordChar = $f[2]
        $dlg.Controls.AddRange(@($l, $t)); $fields[$f[0]] = $t
        $y += 58
    }
    # логин подставляем текущий для выбранной роли - обычно меняют только пароль
    $fill = { $fields["user"].Text = if ($rbAdmin.Checked) { $acc.Admin } else { $acc.Staff } }
    & $fill
    $rbAdmin.Add_CheckedChanged($fill)
    $ok = New-Object Windows.Forms.Button; $ok.Text = "Сохранить"; $ok.DialogResult = "OK"
    $ok.Location = New-Object Drawing.Point(204, ($y + 6)); $ok.Size = New-Object Drawing.Size(90, 30)
    $cancel = New-Object Windows.Forms.Button; $cancel.Text = "Отмена"; $cancel.DialogResult = "Cancel"
    $cancel.Location = New-Object Drawing.Point(294, ($y + 6)); $cancel.Size = New-Object Drawing.Size(90, 30)
    foreach ($b in @($ok, $cancel)) { $b.FlatStyle = "Flat"; $b.BackColor = $ColLine; $b.ForeColor = $ColInk }
    $dlg.Controls.AddRange(@($ok, $cancel)); $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel
    if ($dlg.ShowDialog($form) -ne "OK") { return $null }
    $user = $fields["user"].Text.Trim(); $pass = $fields["pass"].Text
    if (-not $user -or $pass.Length -lt 6) { Add-LogLine "Логин обязателен, пароль - не короче 6 символов." "err"; return $null }
    if ($pass -ne $fields["pass2"].Text) { Add-LogLine "Пароли не совпадают." "err"; return $null }
    return @{ Role = $(if ($rbAdmin.Checked) { "admin" } else { "staff" }); User = $user; Password = $pass }
}

# ---------------------------------------------------------------- действия
$btnCheck.Add_Click({ Start-Check })
$btnInstall.Add_Click({
    $body = if (-not $script:Status -or -not $script:Status.Ready) { "Install-Site" }
            elseif (-not $script:Status.Online) { "Start-Site" } else { "Restart-Server" }
    [void](Start-Background $body { Start-Check })
})
$btnUpdate.Add_Click({ [void](Start-Background "Update-Site" { Start-Check }) })
$btnOpen.Add_Click({
    $url = if ($script:Status -and $script:Status.DomainOnline) { "https://$($script:Status.Ascii)" }
           elseif ($script:Status) { $script:Status.Url } else { "http://127.0.0.1:$((Read-Settings).port)" }
    Start-Process "$url/"
})
$btnAdmin.Add_Click({
    $a = Show-AccountDialog
    if (-not $a) { return }
    # фоновый поток - в этом же процессе, поэтому видит эти переменные; Set-Account их сразу стирает
    $env:KEYS_ACCOUNT_ROLE = $a.Role; $env:KEYS_ADMIN_USER = $a.User; $env:KEYS_ADMIN_PASSWORD = $a.Password
    if (-not (Start-Background "Set-Account" { Start-Check })) {
        $env:KEYS_ACCOUNT_ROLE = $null; $env:KEYS_ADMIN_USER = $null; $env:KEYS_ADMIN_PASSWORD = $null
    }
})
$btnMore.Add_Click({ $menu.Show($btnMore, (New-Object Drawing.Point(0, $btnMore.Height))) })

$miRestart.Add_Click({ [void](Start-Background "Restart-Server" { Start-Check }) })
$miBackup.Add_Click({ [void](Start-Background "Backup-Now" { Start-Check }) })
$miBackupDir.Add_Click({
    New-Item -ItemType Directory -Force -Path $script:BackupDir | Out-Null
    Start-Process explorer.exe $script:BackupDir
})
$miDomain.Add_Click({
    $current = (Read-Settings).domain
    $answer = [Microsoft.VisualBasic.Interaction]::InputBox("Домен сайта, например ключи.рф (пусто - без домена, только по IP).`nНужна CRM с Caddy на этом сервере и запись A в DNS.", "Журнал ключей", $current)
    if ($answer -eq $current) { return }
    Set-Domain $answer
    Add-LogLine ("Домен: " + $(if ($answer) { $answer } else { "не указан" })) "ok"
    if ($answer) { [void](Start-Background "Connect-Domain" { Start-Check }) } else { Start-Check }
})
$miCrm.Add_Click({
    $dialog = New-Object Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Выберите папку CRM (New_Lab_3D) - в ней есть deploy\Caddyfile"
    if ($dialog.ShowDialog($form) -eq "OK") {
        try { Set-CrmRoot $dialog.SelectedPath; Add-LogLine "Папка CRM: $($dialog.SelectedPath)" "ok"; Start-Check }
        catch { Add-LogLine $_.Exception.Message "err" }
    }
})
$miCopy.Add_Click({
    if ($script:Status) { [Windows.Forms.Clipboard]::SetText($script:Status.Url); Add-LogLine "Скопировано: $($script:Status.Url)" "ok" }
})
$miLog.Add_Click({
    if (Test-Path $script:LogFile) { Start-Process notepad.exe $script:LogFile } else { Add-LogLine "Журнала ещё нет - сайт не запускался." "warn" }
})
$miFolder.Add_Click({ Start-Process explorer.exe $script:Root })
$miAuto.Add_Click({
    $on = if ($miAuto.Checked) { 0 } else { 1 }
    [void](Start-Background "Set-Autostart $on" { Start-Check })
})
$miStop.Add_Click({ [void](Start-Background "Stop-Site" { Start-Check }) })
$miReinstall.Add_Click({ [void](Start-Background "Install-Site" { Start-Check }) })

$form.Add_Shown({
    Add-LogLine "Журнал ключей" "step"
    Add-LogLine "Папка сайта: $script:Root"
    $timer.Start()
    Start-Check
})
$form.Add_FormClosing({ $timer.Stop() })

[void]$form.ShowDialog()
