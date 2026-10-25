# Общие функции «Журнала ключей» на Windows-сервере (подключаются в app.ps1 и site.ps1).
# Сайт - это программа на Python. Её запускает задача Планировщика Windows: при включении
# сервера, без входа пользователя, и перезапускает, если она упала. Сайт сразу открывается
# по IP (http://<IP>:8090). Если указать домен и рядом есть CRM «Лаборатория 3Д» с Caddy,
# сайт подключается и к ней - по домену с HTTPS (основной Caddyfile CRM не трогаем).
$ErrorActionPreference = "Stop"

try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false) } catch { }
$env:GIT_TERMINAL_PROMPT = "0"
$env:GCM_INTERACTIVE = "never"
$env:PYTHONUTF8 = "1"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$script:Root = Split-Path -Parent $PSScriptRoot
$script:SettingsFile = Join-Path $PSScriptRoot "app-settings.json"
$script:Venv = Join-Path $script:Root ".venv"
$script:VenvPython = Join-Path $script:Venv "Scripts\python.exe"
$script:ServeScript = Join-Path $PSScriptRoot "serve.py"
$script:LogFile = Join-Path $PSScriptRoot "logs\server.log"
$script:BackupDir = Join-Path $script:Root "backups"
$script:TaskName = "Журнал ключей"
$script:FirewallRule = "Журнал ключей - сайт"
$script:SiteFileName = "keys.caddy"

# Куда писать сообщения: консоль по умолчанию, окно подменяет на свой вывод.
$script:LogSink = { param([string]$Text, [string]$Kind)
    $color = @{ ok = "Green"; warn = "Yellow"; err = "Red"; step = "Cyan" }[$Kind]
    if (-not $color) { $color = "Gray" }
    Write-Host "  $Text" -ForegroundColor $color
}
function Write-Log([string]$Text, [string]$Kind = "info") { & $script:LogSink $Text $Kind }

# ---------------------------------------------------------------- настройки
function Read-Settings {
    $s = [ordered]@{ port = 8090; domain = ""; crmRoot = ""; autostart = $true }
    if (Test-Path $script:SettingsFile) {
        try {
            $json = Get-Content -Path $script:SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $json.PSObject.Properties) { $s[$p.Name] = $p.Value }
        } catch { }
    }
    return $s
}
function Save-Settings($Settings) {
    [IO.File]::WriteAllText($script:SettingsFile, ($Settings | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
}

# ключи.рф -> xn--... (так домен понимают DNS, Caddy и сертификаты)
function ConvertTo-AsciiDomain([string]$Domain) {
    if (-not $Domain) { return "" }
    return (New-Object Globalization.IdnMapping).GetAscii($Domain.Trim().ToLower())
}

function Set-Domain([string]$Domain) {
    $Domain = "$Domain".Trim().ToLower() -replace '^https?://', '' -replace '/.*$', ''
    $s = Read-Settings; $s.domain = $Domain; Save-Settings $s
}

# ---------------------------------------------------------------- вспомогательное
function Find-Executable([string]$Name, [string[]]$ExtraPaths = @()) {
    $command = Get-Command $Name -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -notlike "*\WindowsApps\*" } | Select-Object -First 1
    if ($command) { return $command.Source }
    foreach ($path in $ExtraPaths) { if ($path -and (Test-Path $path)) { return $path } }
    return $null
}

# Внешние программы пишут предупреждения в stderr; под "Stop" PowerShell 5.1 счёл бы это ошибкой.
function Invoke-Native([scriptblock]$Command) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = @(& $Command 2>&1 | ForEach-Object { "$_" })
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    }
    finally { $ErrorActionPreference = $previous }
}

function Read-EnvFile([string]$Path) {
    $values = @{}
    if (-not (Test-Path $Path)) { return $values }
    foreach ($line in Get-Content -Path $Path -Encoding UTF8) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
            $value = $Matches[2]
            if ($value.Length -ge 2 -and $value.StartsWith('"') -and $value.EndsWith('"')) { $value = $value.Substring(1, $value.Length - 2) }
            $values[$Matches[1]] = $value
        }
    }
    return $values
}

function Get-LocalIp {
    $route = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Sort-Object { $_.RouteMetric + $_.InterfaceMetric } | Select-Object -First 1
    if ($route) {
        $address = Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike "169.254.*" } | Select-Object -First 1
        if ($address) { return $address.IPAddress }
    }
    return "127.0.0.1"
}

function Get-PublicIp {
    try { return (Invoke-RestMethod -Uri "https://api.ipify.org" -TimeoutSec 5).ToString().Trim() } catch { return $null }
}

function Resolve-ARecord([string]$Name) {
    if (-not $Name) { return $null }
    $r = Resolve-DnsName -Name $Name -Type A -DnsOnly -ErrorAction SilentlyContinue | Where-Object { $_.Type -eq "A" } | Select-Object -First 1
    if ($r) { return $r.IPAddress }
    return $null
}

# Кто слушает порт: $null - свободен, иначе имя программы.
function Get-PortOwner([int]$Port) {
    $connection = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $connection) { return $null }
    $process = Get-Process -Id $connection.OwningProcess -ErrorAction SilentlyContinue
    if ($process) { return $process.ProcessName }
    return "PID $($connection.OwningProcess)"
}

function Test-Url([string]$Url, [int]$Timeout = 5) {
    try { return ((Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $Timeout -MaximumRedirection 0 -ErrorAction Stop).StatusCode -lt 400) }
    catch {
        # 302 на страницу входа - тоже значит «сайт работает»
        $resp = $_.Exception.Response
        return [bool]($resp -and [int]$resp.StatusCode -ge 300 -and [int]$resp.StatusCode -lt 400)
    }
}

# ---------------------------------------------------------------- Python
function Find-Python {
    $candidates = @()
    $py = Find-Executable "py"
    if ($py) {
        $r = Invoke-Native { & $py -3 -c "import sys; print(sys.executable)" }
        if ($r.ExitCode -eq 0 -and $r.Output) { $candidates += "$($r.Output[-1])".Trim() }
    }
    $candidates += Find-Executable "python"
    $candidates += @(Get-ChildItem -Path "$env:ProgramFiles\Python3*\python.exe", "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe" -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | ForEach-Object { $_.FullName })
    foreach ($c in $candidates) {
        if (-not $c -or -not (Test-Path $c)) { continue }
        $r = Invoke-Native { & $c -c "import sys; print(sys.version_info >= (3, 10))" }
        if ($r.ExitCode -eq 0 -and "$($r.Output[-1])".Trim() -eq "True") { return $c }
    }
    return $null
}

function Install-Python {
    $python = Find-Python
    if ($python) { return $python }
    $winget = Find-Executable "winget" @((Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\winget.exe"))
    if (-not $winget) { throw "Python не найден. Установите Python 3.12 с python.org (галочка «для всех пользователей») и повторите." }
    Write-Log "Python не найден - ставлю Python 3.12 (пару минут)..."
    $r = Invoke-Native { & $winget install -e --id Python.Python.3.12 --scope machine --silent --accept-package-agreements --accept-source-agreements }
    $r.Output | Select-Object -Last 3 | ForEach-Object { Write-Log $_ }
    # PATH обновился только для новых процессов - ищем по известным путям
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
    $python = Find-Python
    if (-not $python) { throw "Не удалось установить Python. Установите его вручную с python.org и повторите." }
    return $python
}

# Отдельное окружение .venv в папке сайта и библиотеки из requirements.txt.
function Install-Requirements {
    if (-not (Test-Path $script:VenvPython)) {
        $python = Install-Python
        Write-Log "Python: $python"
        $r = Invoke-Native { & $python -m venv $script:Venv }
        if ($r.ExitCode -ne 0) { throw ("Не удалось создать .venv: " + ($r.Output -join " ")) }
    }
    Write-Log "Ставлю библиотеки (flask, waitress)..."
    $r = Invoke-Native { & $script:VenvPython -m pip install --disable-pip-version-check -q -r (Join-Path $script:Root "requirements.txt") }
    if ($r.ExitCode -ne 0) { throw ("pip install не удался: " + (($r.Output | Select-Object -Last 3) -join " ")) }
    Write-Log "Библиотеки на месте." "ok"
}

# ---------------------------------------------------------------- автозапуск (Планировщик Windows)
function Get-SiteTask { return Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue }

function Register-SiteTask {
    $action = New-ScheduledTaskAction -Execute $script:VenvPython -Argument "`"$script:ServeScript`"" -WorkingDirectory $script:Root
    # при включении сервера + проверка каждые 5 минут: если сайт упал, задача запустит его снова
    $triggers = @(
        (New-ScheduledTaskTrigger -AtStartup),
        (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5))
    )
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $triggers -Principal $principal -Settings $settings `
        -Description "Сайт «Журнал ключей» ($script:Root)" -Force | Out-Null
}

function Get-ServerProcesses {
    return @(Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pythonw.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($script:ServeScript) })
}

function Stop-Server {
    if (Get-SiteTask) { Stop-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
    foreach ($p in Get-ServerProcesses) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Wait-Server([int]$Port, [int]$Seconds = 20) {
    for ($i = 0; $i -lt $Seconds; $i++) {
        if (Test-Url "http://127.0.0.1:$Port/login" 2) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Test-Ready { return (Test-Path $script:VenvPython) }

# С автозапуском сайт запускает задача Планировщика, без него - обычный скрытый процесс,
# который работает, пока не выключат компьютер.
function Start-Server {
    $port = [int](Read-Settings).port
    if (Get-SiteTask) { Start-ScheduledTask -TaskName $script:TaskName }
    else { Start-Process -FilePath $script:VenvPython -ArgumentList "`"$script:ServeScript`"" -WorkingDirectory $script:Root -WindowStyle Hidden }
    if (Wait-Server $port) { Write-Log "Сайт работает: http://$(Get-LocalIp):$port" "ok" }
    else { Write-Log "Сайт не ответил за 20 секунд. Посмотрите журнал: $script:LogFile" "warn"; Show-ServerLog }
}

function Restart-Server {
    Write-Log "Перезапуск сайта" "step"
    if (-not (Test-Ready)) { throw "Сайт ещё не установлен - нажмите «Установить и запустить»." }
    Stop-Server
    Start-Server
}

function Start-Site {
    Write-Log "Запуск сайта" "step"
    if (-not (Test-Ready)) { Install-Site; return }
    $port = [int](Read-Settings).port
    if (Test-Url "http://127.0.0.1:$port/login" 2) { Write-Log "Сайт уже работает: http://$(Get-LocalIp):$port" "ok"; return }
    Start-Server
}

function Stop-Site {
    Write-Log "Остановка сайта" "step"
    Stop-Server
    Write-Log "Сайт остановлен." "ok"
    if (Get-SiteTask) { Write-Log "Автозапуск включён - через несколько минут сайт запустится снова. Чтобы не запускался, снимите в «...» галочку «Запускать вместе с компьютером»." "warn" }
}

function Set-Autostart([int]$On) {
    $s = Read-Settings; $s.autostart = [bool]$On; Save-Settings $s
    if ($On) {
        Write-Log "Включаю автозапуск" "step"
        if (-not (Test-Ready)) { Write-Log "Сайт ещё не установлен - автозапуск включится при установке." "warn"; return }
        Stop-Server
        Register-SiteTask
        Start-Server
        Write-Log "Готово: сайт будет запускаться сам при включении компьютера." "ok"
    }
    else {
        Write-Log "Выключаю автозапуск" "step"
        $wasRunning = Test-Url "http://127.0.0.1:$([int]$s.port)/login" 2
        if (Get-SiteTask) {
            Stop-Server
            Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false
            if ($wasRunning -and (Test-Ready)) { Start-Server }  # сейчас пусть работает дальше
        }
        Write-Log "Автозапуск выключен. После включения компьютера откройте это окно и нажмите «Запустить сайт»." "ok"
    }
}

function Show-ServerLog([int]$Lines = 8) {
    if (Test-Path $script:LogFile) {
        Get-Content -Path $script:LogFile -Tail $Lines -Encoding UTF8 | ForEach-Object { Write-Log $_ }
    }
}

function Open-FirewallPort([int]$Port) {
    try {
        Remove-NetFirewallRule -DisplayName $script:FirewallRule -ErrorAction SilentlyContinue
        New-NetFirewallRule -DisplayName $script:FirewallRule -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow -Profile Any | Out-Null
        Write-Log "Брандмауэр Windows: порт $Port открыт." "ok"
    }
    catch { Write-Log "Не удалось открыть порт $Port в брандмауэре (нужны права администратора): $($_.Exception.Message)" "warn" }
}

# Порт сайта: сохранённый, если свободен (или уже наш), иначе следующий свободный.
function Select-Port {
    $settings = Read-Settings
    $port = [int]$settings.port
    if ($port -le 0) { $port = 8090 }
    for ($p = $port; $p -lt $port + 20; $p++) {
        $owner = Get-PortOwner $p
        if (-not $owner -or $owner -like "python*") {
            if ($p -ne [int]$settings.port) { $settings.port = $p; Save-Settings $settings; Write-Log "Порт $port занят ($owner) - беру $p." "warn" }
            return $p
        }
    }
    throw "Не нашёл свободный порт рядом с $port."
}

# Установить (или переустановить) сайт: Python, библиотеки, автозапуск, брандмауэр, домен.
function Install-Site {
    Write-Log "Установка сайта" "step"
    Install-Requirements
    Stop-Server
    $port = Select-Port
    if ((Read-Settings).autostart) {
        Register-SiteTask
        Write-Log "Автозапуск: задача «$script:TaskName» в Планировщике Windows (запускается вместе с компьютером)." "ok"
    }
    else {
        if (Get-SiteTask) { Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false }
        Write-Log "Автозапуск выключен - после включения компьютера нажмите «Запустить сайт»." "warn"
    }
    Open-FirewallPort $port
    Start-Server
    if ((Read-Settings).domain) { Connect-Domain }
    $acc = Get-Accounts
    if (-not $acc.Admin -or -not $acc.Staff) { Write-Log "Задайте логины и пароли: кнопка «Логины и пароли»." "warn" }
}

function Uninstall-Site {
    Write-Log "Удаление автозапуска" "step"
    Stop-Server
    if (Get-SiteTask) { Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false }
    Remove-NetFirewallRule -DisplayName $script:FirewallRule -ErrorAction SilentlyContinue
    $crm = Get-Crm
    if ($crm -and (Test-Path $crm.SiteFile)) {
        Remove-Item $crm.SiteFile -Force
        if (Test-CaddyRunning) { [void](Invoke-CaddyReload $crm) }
    }
    Write-Log "Сайт остановлен и убран из автозапуска. База (keys.db) и резервные копии не тронуты." "ok"
}

# ---------------------------------------------------------------- логины
# Аккаунтов два: админ (меняет всё) и общий для сотрудников (примечания, ИБП, Электрон).
function Get-Accounts {
    $acc = [pscustomobject]@{ Admin = ""; Staff = "" }
    if (-not (Test-Path $script:VenvPython)) { return $acc }
    Push-Location $script:Root
    try { $r = Invoke-Native { & $script:VenvPython -m flask --app app accounts } } finally { Pop-Location }
    foreach ($line in $r.Output) {
        if ($line -match '^admin=(.*)$') { $acc.Admin = $Matches[1].Trim() }
        elseif ($line -match '^staff=(.*)$') { $acc.Staff = $Matches[1].Trim() }
    }
    return $acc
}

# Роль, логин и пароль приходят через переменные окружения - так пароль не виден в списке процессов.
function Set-Account {
    $role = if ($env:KEYS_ACCOUNT_ROLE -eq "staff") { "staff" } else { "admin" }
    $user = $env:KEYS_ADMIN_USER
    Write-Log ($(if ($role -eq "admin") { "Логин админа: " } else { "Логин сотрудников: " }) + $user) "step"
    if (-not (Test-Path $script:VenvPython)) { Install-Requirements }
    Push-Location $script:Root
    try { $r = Invoke-Native { & $script:VenvPython -m flask --app app set-account --role $role --username $user } }
    finally { Pop-Location; $env:KEYS_ADMIN_USER = $null; $env:KEYS_ADMIN_PASSWORD = $null; $env:KEYS_ACCOUNT_ROLE = $null }
    $r.Output | Where-Object { $_ } | Select-Object -Last 2 | ForEach-Object { Write-Log $_ $(if ($r.ExitCode -eq 0) { "ok" } else { "err" }) }
}

# ---------------------------------------------------------------- резервные копии
function Backup-Now {
    Write-Log "Резервная копия" "step"
    if (-not (Test-Path $script:VenvPython)) { throw "Сайт ещё не установлен." }
    Push-Location $script:Root
    try { $r = Invoke-Native { & $script:VenvPython $script:ServeScript --backup-now } } finally { Pop-Location }
    if ($r.ExitCode -ne 0) { throw ("Не получилось: " + (($r.Output | Select-Object -Last 2) -join " ")) }
    Write-Log "Сохранено: $($r.Output[-1])" "ok"
}

function Get-LastBackup {
    return Get-ChildItem -Path $script:BackupDir -Filter "keys-*.db" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

# ---------------------------------------------------------------- CRM (New_Lab_3D) и её Caddy - для домена
function Test-CrmRoot([string]$Path) {
    if (-not $Path -or -not (Test-Path $Path)) { return $false }
    return (Test-Path (Join-Path $Path "deploy\lib.ps1")) -and
        ((Test-Path (Join-Path $Path "deploy\Caddyfile")) -or (Test-Path (Join-Path $Path ".env.production")))
}

# Ищет папку CRM: сохранённый путь -> запущенный Caddy -> соседние папки -> корни дисков.
function Find-CrmRoot {
    $settings = Read-Settings
    if (Test-CrmRoot $settings.crmRoot) { return $settings.crmRoot }

    $caddyProcs = Get-CimInstance Win32_Process -Filter "Name='caddy.exe'" -ErrorAction SilentlyContinue
    foreach ($p in @($caddyProcs)) {
        if ($p.CommandLine -match '--config\s+"?([^"]+?Caddyfile)"?(\s|$)') {
            $candidate = Split-Path -Parent (Split-Path -Parent $Matches[1])
            if (Test-CrmRoot $candidate) { return $candidate }
        }
    }

    $places = @(Split-Path -Parent $script:Root)
    foreach ($drive in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if ($drive.Root -and (Test-Path $drive.Root)) {
            $places += $drive.Root
            $places += @(Get-ChildItem -Path $drive.Root -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch '^(Windows|Program Files.*|ProgramData|\$.*|System Volume Information)$' } |
                ForEach-Object { $_.FullName })
        }
    }
    foreach ($place in $places) {
        foreach ($dir in @(Get-ChildItem -Path $place -Directory -ErrorAction SilentlyContinue)) {
            if ($dir.FullName -ne $script:Root -and (Test-CrmRoot $dir.FullName)) { return $dir.FullName }
        }
    }
    return $null
}

function Set-CrmRoot([string]$Path) {
    if (-not (Test-CrmRoot $Path)) { throw "В папке '$Path' не найдена установленная CRM (нет deploy\lib.ps1 и deploy\Caddyfile)." }
    $s = Read-Settings; $s.crmRoot = $Path; Save-Settings $s
}

function Find-Caddy([hashtable]$CrmConfig) {
    if ($CrmConfig -and $CrmConfig["DEPLOY_CADDY"] -and (Test-Path $CrmConfig["DEPLOY_CADDY"])) { return $CrmConfig["DEPLOY_CADDY"] }
    return Find-Executable "caddy" @(
        (Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links\caddy.exe"),
        (Join-Path $env:ProgramFiles "Caddy\caddy.exe"),
        "C:\caddy\caddy.exe"
    )
}

function Test-CaddyRunning { return [bool](Get-Process -Name "caddy" -ErrorAction SilentlyContinue) }

function Get-Crm {
    $root = Find-CrmRoot
    if (-not $root) { return $null }
    $config = Read-EnvFile (Join-Path $root ".env.production")
    return [pscustomobject]@{
        Root      = $root
        Ip        = $config["DEPLOY_IP"]
        Caddy     = Find-Caddy $config
        Caddyfile = Join-Path $root "deploy\Caddyfile"
        SitesDir  = Join-Path $root "deploy\sites.d"
        SiteFile  = Join-Path $root ("deploy\sites.d\" + $script:SiteFileName)
    }
}

# Блок для Caddy: домен с HTTPS (Let's Encrypt) -> наш сайт на этом же сервере.
function New-SiteText([string]$Domain, [string]$Ip, [bool]$WithWww, [int]$Port) {
    $ascii = ConvertTo-AsciiDomain $Domain
    $bind = if ($Ip) { "`tbind $Ip`n" } else { "" }
    $text = @"
# Журнал ключей ($Domain) - создано программой deploy\app.ps1. Правки вручную перезапишутся.
$ascii {
$bind	encode zstd gzip
	reverse_proxy 127.0.0.1:$Port
	header {
		Strict-Transport-Security "max-age=31536000"
		X-Content-Type-Options nosniff
		X-Frame-Options DENY
		Referrer-Policy same-origin
		-Server
	}
}
"@
    if ($WithWww) {
        $text += @"

www.$ascii {
$bind	redir https://$ascii{uri} permanent
}
"@
    }
    return $text + "`n"
}

function Invoke-CaddyReload($Crm) {
    if (-not $Crm.Caddy) { return [pscustomobject]@{ ExitCode = 1; Output = @("caddy.exe не найден") } }
    return Invoke-Native { & $Crm.Caddy reload --config $Crm.Caddyfile --adapter caddyfile }
}

# Подключить домен через Caddy CRM. Кривой конфиг не оставляем: откатываем.
function Connect-Domain {
    $settings = Read-Settings
    $domain = $settings.domain
    if (-not $domain) { throw "Домен не указан (меню «...» -> «Указать домен»)." }
    $ascii = ConvertTo-AsciiDomain $domain
    Write-Log "Подключение домена $domain" "step"

    $crm = Get-Crm
    if (-not $crm) { Write-Log "CRM с Caddy не найдена - сайт работает только по IP. Укажите папку CRM через «...»." "warn"; return }
    Write-Log "CRM: $($crm.Root)"
    if (-not $crm.Caddy) { throw "Не найден caddy.exe (его ставит CRM: winget install CaddyServer.Caddy)." }

    $withWww = [bool](Resolve-ARecord "www.$ascii")
    New-Item -ItemType Directory -Force -Path $crm.SitesDir | Out-Null
    $previous = if (Test-Path $crm.SiteFile) { [IO.File]::ReadAllText($crm.SiteFile) } else { $null }
    [IO.File]::WriteAllText($crm.SiteFile, (New-SiteText $domain $crm.Ip $withWww ([int]$settings.port)), (New-Object Text.UTF8Encoding($false)))

    if (Test-Path $crm.Caddyfile) {
        $check = Invoke-Native { & $crm.Caddy validate --config $crm.Caddyfile --adapter caddyfile }
        if ($check.ExitCode -ne 0) {
            if ($null -ne $previous) { [IO.File]::WriteAllText($crm.SiteFile, $previous, (New-Object Text.UTF8Encoding($false))) }
            else { Remove-Item $crm.SiteFile -ErrorAction SilentlyContinue }
            throw ("Caddy не принял настройки, изменения отменены: " + (($check.Output | Select-Object -Last 3) -join " "))
        }
    }
    Write-Log "Файл для Caddy: $($crm.SiteFile)" "ok"
    if (Test-CaddyRunning) {
        $reload = Invoke-CaddyReload $crm
        if ($reload.ExitCode -eq 0) { Write-Log "Caddy подхватил домен. Сертификат HTTPS он получит сам за 1-2 минуты." "ok" }
        else { Write-Log ("Не удалось перезагрузить Caddy: " + (($reload.Output | Select-Object -Last 2) -join " ")) "warn" }
    }
    else { Write-Log "Caddy сейчас не запущен - домен заработает, когда запустится CRM." "warn" }
}

# ---------------------------------------------------------------- git
function Invoke-Git {
    $git = Find-Executable "git" @((Join-Path $env:ProgramFiles "Git\cmd\git.exe"))
    if (-not $git) { throw "git не установлен (winget install Git.Git)." }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $lines = & $git -c core.quotepath=off -c safe.directory=* -C $script:Root @args 2>&1 | ForEach-Object { "$_" }
        $script:GitExit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previous }
    return @($lines)
}

function Get-VersionInfo([switch]$NoFetch) {
    $info = [ordered]@{ isRepo = $false; head = ""; date = ""; message = ""; behind = 0; commits = @(); error = "" }
    if (-not (Test-Path (Join-Path $script:Root ".git"))) { return $info }
    if (-not (Find-Executable "git" @((Join-Path $env:ProgramFiles "Git\cmd\git.exe")))) { $info.error = "git не установлен"; return $info }
    $info.isRepo = $true
    $log = @(Invoke-Git log -1 "--format=%h|%cd|%s" "--date=format:%d.%m.%Y %H:%M")
    if ($script:GitExit -eq 0 -and $log.Count) {
        $parts = "$($log[0])".Split("|", 3)
        if ($parts.Count -eq 3) { $info.head = $parts[0]; $info.date = $parts[1]; $info.message = $parts[2] }
    }
    if (-not $NoFetch) {
        $fetch = Invoke-Git fetch --quiet
        if ($script:GitExit -ne 0) { $info.error = ("$($fetch -join ' ')").Trim() }
    }
    $behind = Invoke-Git rev-list --count "HEAD..@{u}"
    if ($script:GitExit -eq 0) {
        $info.behind = [int]"$($behind | Select-Object -First 1)"
        $info.commits = @(Invoke-Git log "HEAD..@{u}" "--format=%s" -n 20 | Where-Object { $_ })
    }
    return $info
}

function Update-Site {
    Write-Log "Обновление сайта" "step"
    if (-not (Test-Path (Join-Path $script:Root ".git"))) {
        throw "Папка сайта не из git. Скачайте её заново через git clone - тогда обновление будет в одну кнопку."
    }
    $out = Invoke-Git pull --ff-only
    $out | Where-Object { $_ } | ForEach-Object { Write-Log $_ }
    if ($script:GitExit -ne 0) {
        throw "git pull не удался. Если в папке сайта что-то правили вручную - верните как было (git checkout .) и повторите."
    }
    if (Test-Ready) {
        Install-Requirements
        Restart-Server
        Write-Log "Готово, новая версия работает." "ok"
    }
    else { Write-Log "Код обновлён. Сайт ещё не установлен - нажмите «Установить и запустить»." "warn" }
}

# ---------------------------------------------------------------- проверки для окна / status
function Get-SiteStatus([switch]$NoFetch) {
    $settings = Read-Settings
    $port = [int]$settings.port
    $ip = Get-LocalIp
    $task = Get-SiteTask
    $ascii = ConvertTo-AsciiDomain $settings.domain
    $crm = if ($settings.domain) { Get-Crm } else { $null }

    $domainOnline = $false; $dnsIp = $null; $publicIp = $null
    if ($ascii) {
        $dnsIp = Resolve-ARecord $ascii
        $publicIp = Get-PublicIp
        $domainOnline = Test-Url "https://$ascii/login" 8
    }
    return [pscustomobject]@{
        Ready         = Test-Ready
        Installed     = [bool]$task
        TaskState     = if ($task) { "$($task.State)" } else { "" }
        Online        = Test-Url "http://127.0.0.1:$port/login" 3
        Url           = "http://${ip}:$port"
        Port          = $port
        Accounts      = Get-Accounts
        Domain        = $settings.domain
        Ascii         = $ascii
        Crm           = $crm
        DomainLinked  = [bool]($crm -and (Test-Path $crm.SiteFile))
        CaddyRunning  = Test-CaddyRunning
        DnsIp         = $dnsIp
        PublicIp      = $publicIp
        DomainOnline  = $domainOnline
        LastBackup    = Get-LastBackup
        Version       = Get-VersionInfo -NoFetch:$NoFetch
    }
}
