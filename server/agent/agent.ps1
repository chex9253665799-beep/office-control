# Агент офиса. Работает от SYSTEM (задача Windows «OfficeAgent»).
# Каждые 20 секунд: отчёт в панель (состояние ПК) и получение заданий. Задания выполняются в фоне.
# Связь только с панелью по HTTPS, сертификат панели сверяется по отпечатку.

$AgentVersion = '1.11'
$Dir = "$env:ProgramData\OfficeAgent"
$ErrorActionPreference = 'Continue'

# один агент на ПК
$mutex = New-Object Threading.Mutex($false, 'Global\OfficeAgentMutex')
if (-not $mutex.WaitOne(0)) { exit }

$cfg = Get-Content "$Dir\agent.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$Panel = $cfg.panel

# --- проверка сертификата панели по отпечатку (через C#, надёжно в фоне)
Add-Type -TypeDefinition @"
using System.Net; using System.Net.Security; using System.Security.Cryptography.X509Certificates;
public static class OfficePin {
    public static string Thumb;
    public static bool Check(object s, X509Certificate c, X509Chain ch, SslPolicyErrors e) {
        return c != null && c.GetCertHashString().ToUpperInvariant() == Thumb;
    }
}
"@
[OfficePin]::Thumb = $cfg.thumb.ToUpperInvariant()
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Net.ServicePointManager]::ServerCertificateValidationCallback = [Delegate]::CreateDelegate([Net.Security.RemoteCertificateValidationCallback], [OfficePin].GetMethod('Check'))

function Log($t) {
    $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $t
    Add-Content -Path "$Dir\agent.log" -Value $line -Encoding UTF8
    if ((Get-Item "$Dir\agent.log").Length -gt 2MB) { Move-Item "$Dir\agent.log" "$Dir\agent.old.log" -Force }
}

function Save-Cfg { [IO.File]::WriteAllText("$Dir\agent.json", ($cfg | ConvertTo-Json), (New-Object Text.UTF8Encoding $false)) }

function Api($path, $obj) {
    $json = $obj | ConvertTo-Json -Depth 6 -Compress
    Invoke-RestMethod -Method Post -Uri "$Panel$path" -Headers @{ 'X-Agent' = "$($cfg.id):$($cfg.secret)" } `
        -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 60
}

function Download($path, $file) {
    $wc = New-Object Net.WebClient
    $wc.Headers.Add('X-Agent', "$($cfg.id):$($cfg.secret)")
    $wc.DownloadFile("$Panel$path", $file)
}

# ------------------------------------------------------------------ состояние ПК

function Get-Info {
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $bios = Get-CimInstance Win32_BIOS
    $disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
        @{ name = $_.DeviceID; size_gb = [math]::Round($_.Size / 1GB, 1); free_gb = [math]::Round($_.FreeSpace / 1GB, 1) } })
    $ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } | ForEach-Object { $_.IPAddress })
    $mac = (Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up' | Select-Object -First 1).MacAddress
    $av = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction SilentlyContinue | ForEach-Object { $_.displayName })
    $user = $cs.UserName
    @{
        hostname = $env:COMPUTERNAME
        user = $user
        os = "$($os.Caption) $($os.Version)"
        build = $os.BuildNumber
        uptime_h = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1)
        cpu = ($cpu.Name -replace '\s+', ' ').Trim()
        cores = $cpu.NumberOfLogicalProcessors
        cpu_load = $cpu.LoadPercentage
        ram_gb = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        ram_free_gb = [math]::Round($os.FreePhysicalMemory * 1KB / 1GB, 1)
        disks = $disks
        ips = $ips
        mac = $mac
        vendor = "$($cs.Manufacturer) $($cs.Model)".Trim()
        serial = $bios.SerialNumber
        antivirus = $av
        agent = $AgentVersion
        rustdesk = [bool](Get-Service $script:C.svc -ErrorAction SilentlyContinue)
        client = $script:Client
        log = @(Get-Content "$Dir\agent.log" -Tail 12 -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object { [string]$_ })
    }
}

function Get-Programs {
    $keys = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    @(Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -and -not $_.SystemComponent } |
        Sort-Object DisplayName -Unique | ForEach-Object { @{ n = $_.DisplayName; v = $_.DisplayVersion; p = $_.Publisher } })
}

# ------------------------------------------------------------------ программа удалённого доступа: «Мост» (наша) или RustDesk

# «Мост» — наша сборка RustDesk: сервер и ключ вшиты, имя программы «Мост»
$Clients = @{
    rustdesk = @{ title = 'RustDesk'; dir = "$env:ProgramFiles\RustDesk"; exe = 'rustdesk.exe'; svc = 'RustDesk'; proc = 'rustdesk'; cfgName = 'RustDesk'; dl = '/dl/rustdesk.exe'; builtin = $false }
    # внутреннее имя «Моста» — латиницей (папка, служба); «Мост» — только в окне и текстах
    most     = @{ title = 'Мост'; dir = "$env:ProgramFiles\Most"; exe = 'Most.exe'; svc = 'Most'; proc = 'Most'; cfgName = 'Most'; dl = '/dl/most.exe'; builtin = $true }
}

# какая программа сейчас используется (выбирается в панели; по умолчанию RustDesk)
function Use-Client([string]$name) {
    if (-not $Clients.ContainsKey($name)) { $name = 'rustdesk' }
    $c = $Clients[$name]
    $script:Client = $name
    $script:C = $c
    # exe: «Мост.exe» (по имени программы) или most.exe (как в сборке)
    $script:RdExe = Join-Path $c.dir $c.exe

    $script:RdCfgDir = "$env:windir\ServiceProfiles\LocalService\AppData\Roaming\$($c.cfgName)\config"
}
Use-Client $(if ($cfg.client) { $cfg.client } else { 'rustdesk' })

# ВНИМАНИЕ: не называть функцию Rd — в PowerShell это встроенное имя Remove-Item.
# команда программы с ограничением по времени (иначе может зависнуть навсегда).
# Как в официальном скрипте RustDesk: из папки программы, вывод через конвейер.
function Invoke-RdCli([string[]]$a, [int]$sec = 30, [string]$exe = $script:RdExe) {
    $j = Start-Job -ScriptBlock {
        param($exe, $args2)
        Set-Location (Split-Path $exe)
        (& $exe @args2 | Out-String)
    } -ArgumentList $exe, $a
    if (-not (Wait-Job $j -Timeout $sec)) {
        Stop-Job $j -ErrorAction SilentlyContinue; Remove-Job $j -Force -ErrorAction SilentlyContinue
        Log "$($script:C.title) $($a[0]): нет ответа за $sec с"
        return ''
    }
    $o = Receive-Job $j -ErrorAction SilentlyContinue | Out-String
    Remove-Job $j -Force -ErrorAction SilentlyContinue
    return "$o".Trim()
}

function New-Pass {
    $chars = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    -join (1..12 | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
}

# записать key = 'value' в файл настроек (в раздел [section] или в начало, если раздела нет)
function Set-Toml([string]$file, [string]$section, [hashtable]$values) {
    New-Item -ItemType Directory -Force -Path (Split-Path $file) | Out-Null
    $lines = New-Object System.Collections.Generic.List[string]
    if (Test-Path $file) { foreach ($l in [IO.File]::ReadAllLines($file)) { $lines.Add($l) } }
    foreach ($k in $values.Keys) {
        $line = "$k = '$($values[$k])'"
        $from = 0; $to = $lines.Count
        if ($section) {
            $h = $lines.IndexOf("[$section]")
            if ($h -lt 0) { $lines.Add(''); $lines.Add("[$section]"); $h = $lines.Count - 1 }
            $from = $h + 1; $to = $lines.Count
            for ($i = $from; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*\[') { $to = $i; break } }
        } else {
            for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*\[') { $to = $i; break } }
        }
        $done = $false
        for ($i = $from; $i -lt $to; $i++) { if ($lines[$i] -match "^\s*$([regex]::Escape($k))\s*=") { $lines[$i] = $line; $done = $true; break } }
        if (-not $done) { $lines.Insert($to, $line) }
    }
    [IO.File]::WriteAllLines($file, $lines, (New-Object Text.UTF8Encoding $false))
}

# правка настроек: только при остановленной программе, иначе при выходе она перезапишет файл своими старыми настройками
function Edit-RdConfig([scriptblock]$edit) {
    Stop-Service $script:C.svc -Force -ErrorAction SilentlyContinue
    Start-Sleep 2
    Get-Process $script:C.proc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep 2
    & $edit
    Start-Service $script:C.svc -ErrorAction SilentlyContinue
    Start-Sleep 8
}

function Get-TomlValue([string]$file, [string]$key) {
    if (-not (Test-Path $file)) { return '' }
    $m = Select-String -Path $file -Pattern "^\s*$([regex]::Escape($key))\s*=\s*'([^']*)'" | Select-Object -First 1
    if ($m) { return $m.Matches[0].Groups[1].Value } else { return '' }
}

# Новый постоянный пароль. Возвращает пароль.
function Set-RdPassword {
    $p = New-Pass
    $res = Invoke-RdCli '--password', $p
    if ($res -notmatch 'Done') {
        Log "$($script:C.title) --password: '$res' — пишу пароль в файл"
        Edit-RdConfig { Set-Toml "$script:RdCfgDir\$($script:C.cfgName).toml" '' @{ 'password' = $p } }
    }
    $cfg | Add-Member -NotePropertyName rd_pass -NotePropertyValue $p -Force
    Save-Cfg
    Log "пароль $($script:C.title) задан"
    return $p
}

function Install-Client {
    Log "$($script:C.title) не найден — ставлю"
    $f = "$Dir\tmp\$($script:Client)-setup.exe"
    Download $script:C.dl $f
    # не ждём установщик: после установки он сам запускает программу и «не завершается»
    Start-Process $f -ArgumentList '--silent-install' | Out-Null
    for ($i = 0; $i -lt 90; $i++) {
        Use-Client $script:Client
        if ((Test-Path $script:RdExe) -and (Get-Service $script:C.svc -ErrorAction SilentlyContinue)) { break }
        Start-Sleep 2
    }
    Start-Sleep 10
    Use-Client $script:Client
    if (-not (Test-Path $script:RdExe)) { Log "$($script:C.title) не установился"; return $false }
    Log "$($script:C.title) установлен"
    return $true
}

# После перехода на «Мост» — убрать RustDesk полностью: программу, службу, настройки, журналы, ярлыки, записи в реестре
function Remove-OldRustDesk {
    $old = Join-Path $Clients.rustdesk.dir $Clients.rustdesk.exe
    $users = @(Get-ChildItem "$env:SystemDrive\Users" -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin 'Public', 'Default', 'Default User', 'All Users' })
    $paths = @(
        $Clients.rustdesk.dir,
        "${env:ProgramFiles(x86)}\RustDesk",
        "$env:ProgramData\RustDesk",
        "$env:windir\ServiceProfiles\LocalService\AppData\Roaming\RustDesk",
        "$env:windir\ServiceProfiles\LocalService\AppData\Roaming\Мост",          # пробная установка с русским именем
        "$env:windir\System32\config\systemprofile\AppData\Roaming\RustDesk",
        "$env:windir\System32\config\systemprofile\AppData\Local\rustdesk",
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\RustDesk",
        "$env:PUBLIC\Desktop\RustDesk.lnk",
        "$Dir\tmp\rustdesk.exe"
    ) + ($users | ForEach-Object {
        "$($_.FullName)\AppData\Roaming\RustDesk", "$($_.FullName)\AppData\Local\rustdesk",
        "$($_.FullName)\Desktop\RustDesk.lnk", "$($_.FullName)\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\RustDesk.lnk",
        "$($_.FullName)\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\RustDesk"
    })
    $left = @($paths | Where-Object { $_ -and (Test-Path $_) })
    $svc = Get-Service RustDesk -ErrorAction SilentlyContinue
    if (-not $left -and -not $svc) { return }
    Log 'удаляю RustDesk полностью (заменён «Мостом»)'
    # 1) штатное удаление
    if (Test-Path $old) { Invoke-RdCli '--uninstall' 120 $old | Out-Null; Start-Sleep 5 }
    # 2) служба и процессы
    Stop-Service RustDesk -Force -ErrorAction SilentlyContinue
    & sc.exe delete RustDesk 2>&1 | Out-Null
    Get-Process rustdesk -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep 2
    # 3) папки, настройки, журналы, ярлыки
    foreach ($p in $paths) { if ($p -and (Test-Path $p)) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue } }
    # 4) реестр: «Программы и компоненты», ссылки rustdesk://, автозапуск
    foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\RustDesk', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\RustDesk',
                   'Registry::HKEY_CLASSES_ROOT\rustdesk', 'HKLM:\SOFTWARE\Classes\rustdesk') {
        if (Test-Path $k) { Remove-Item $k -Recurse -Force -ErrorAction SilentlyContinue }
    }
    foreach ($run in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run') {
        $item = Get-ItemProperty $run -ErrorAction SilentlyContinue
        if ($item) { $item.PSObject.Properties | Where-Object { $_.Name -match 'rustdesk' -or "$($_.Value)" -match 'rustdesk' } | ForEach-Object { Remove-ItemProperty $run -Name $_.Name -ErrorAction SilentlyContinue } }
    }
    $still = @($paths | Where-Object { $_ -and (Test-Path $_) })
    if ($still -or (Get-Service RustDesk -ErrorAction SilentlyContinue)) { Log "RustDesk удалён не полностью, осталось: $($still -join '; ')" }
    else { Log 'RustDesk удалён полностью' }
}

# Поставить программу (если нет), направить на наш сервер, задать постоянный пароль. Возвращает $true, если что-то изменилось.
function Ensure-RustDesk([bool]$newPass = $false) {
    if (-not (Test-Path $script:RdExe)) { if (-not (Install-Client)) { return $false } }
    $cfg2 = "$script:RdCfgDir\$($script:C.cfgName)2.toml"
    $cfg1 = "$script:RdCfgDir\$($script:C.cfgName).toml"

    # 1) сервер офиса (у «Моста» он вшит при сборке)
    if (-not $script:C.builtin -and ((Get-TomlValue $cfg2 'custom-rendezvous-server') -ne '__RD_HOST__' -or (Get-TomlValue $cfg2 'key') -ne '__RD_KEY__')) {
        $r = Invoke-RdCli '--option', 'custom-rendezvous-server', '__RD_HOST__'
        Invoke-RdCli '--option', 'relay-server', '__RD_HOST__' | Out-Null
        Invoke-RdCli '--option', 'key', '__RD_KEY__' | Out-Null
        Start-Sleep 2
        if ((Get-TomlValue $cfg2 'custom-rendezvous-server') -ne '__RD_HOST__') {
            Log "RustDesk --option не сработал ($r) — пишу настройки в файл"
            Edit-RdConfig { Set-Toml $cfg2 'options' @{ 'custom-rendezvous-server' = '__RD_HOST__'; 'relay-server' = '__RD_HOST__'; 'key' = '__RD_KEY__' } }
        }
        Log 'RustDesk направлен на сервер офиса'
    }

    # 2) постоянный пароль
    $changed = $false
    if ($newPass -or -not $cfg.rd_pass) { Set-RdPassword | Out-Null; $changed = $true }
    if ((Get-Service $script:C.svc -ErrorAction SilentlyContinue).Status -ne 'Running') { Start-Service $script:C.svc -ErrorAction SilentlyContinue; Start-Sleep 5 }

    # 3) ID
    $rawId = Invoke-RdCli '--get-id'
    $id = $rawId -replace '\s', ''
    if ($id -notmatch '^\d{6,}$') {
        Log "$($script:C.title) --get-id ответил: '$rawId'"
        $id = Get-TomlValue $cfg1 'id'
        if ($id -notmatch '^\d{6,}$') { Log "$($script:C.title): ID пока нет"; $script:RdRetry = $true }
    }
    if ($id -match '^\d{6,}$' -and $id -ne $cfg.rd_id) {
        $cfg | Add-Member -NotePropertyName rd_id -NotePropertyValue $id -Force; Save-Cfg; $changed = $true; Log "$($script:C.title) ID $id"
    }
    # 4) перешли на «Мост» и он работает — RustDesk больше не нужен
    if ($script:Client -eq 'most' -and $id -match '^\d{6,}$') { Remove-OldRustDesk }
    return $changed
}

# Панель велела сменить программу (RustDesk → «Мост» или обратно)
function Switch-Client([string]$name) {
    if (-not $Clients.ContainsKey($name) -or $name -eq $script:Client) { return }
    Log "переход: $($script:C.title) → $($Clients[$name].title)"
    $cfg | Add-Member -NotePropertyName client -NotePropertyValue $name -Force
    $cfg | Add-Member -NotePropertyName rd_id -NotePropertyValue '' -Force
    $cfg | Add-Member -NotePropertyName rd_pass -NotePropertyValue '' -Force
    Save-Cfg
    Use-Client $name
    $script:ForceRd = $true
}

# ------------------------------------------------------------------ задания

$Running = @{}   # id задания -> @{ proc; out; err; deadline; kind }

function Write-Script($text, $file) {
    $pre = "[Console]::OutputEncoding=[Text.Encoding]::UTF8; `$OutputEncoding=[Text.Encoding]::UTF8; `$ProgressPreference='SilentlyContinue'`r`n"
    [IO.File]::WriteAllText($file, $pre + $text, (New-Object Text.UTF8Encoding $true))
}

function Start-Task($t) {
    $base = "$Dir\tmp\task_$($t.id)"
    switch ($t.kind) {
        'ps' {
            Write-Script $t.payload "$base.ps1"
            $p = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$base.ps1`"" `
                -RedirectStandardOutput "$base.out" -RedirectStandardError "$base.err" -WindowStyle Hidden -PassThru
            $Running[$t.id] = @{ proc = $p; out = "$base.out"; err = "$base.err"; deadline = (Get-Date).AddMinutes(30); files = @("$base.ps1") }
        }
        'user' {
            # команда в сеансе вошедшего пользователя (сообщение, блокировка экрана)
            $u = (Get-CimInstance Win32_ComputerSystem).UserName
            if (-not $u) { Send-Result $t.id $false 'Никто не вошёл в Windows — показать некому' 1; return }
            Write-Script $t.payload "$base.ps1"
            Get-ScheduledTask -TaskName 'OfficeAgentUser_*' -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
            $name = "OfficeAgentUser_$($t.id)"
            $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$base.ps1`""
            $pr = New-ScheduledTaskPrincipal -UserId $u -LogonType Interactive
            Register-ScheduledTask -TaskName $name -Action $act -Principal $pr -Force | Out-Null
            Start-ScheduledTask -TaskName $name
            Start-Sleep 3
            Send-Result $t.id $true "Выполнено в сеансе пользователя $u" 0
        }
        'file' {
            $f = $t.payload | ConvertFrom-Json
            try {
                New-Item -ItemType Directory -Force -Path $f.dest | Out-Null
                $target = Join-Path $f.dest $f.name
                Download "/a/file/$($f.id)" $target
                if ($f.run) {
                    $ext = [IO.Path]::GetExtension($target).ToLower()
                    if ($ext -eq '.msi') { $p = Start-Process msiexec.exe -ArgumentList "/i `"$target`" /qn /norestart $($f.args)" -PassThru }
                    else { $p = Start-Process $target -ArgumentList $f.args -PassThru }
                    $Running[$t.id] = @{ proc = $p; out = $null; err = $null; deadline = (Get-Date).AddMinutes(30); files = @(); note = "Файл сохранён: $target`r`n" }
                } else { Send-Result $t.id $true "Файл сохранён: $target" 0 }
            } catch { Send-Result $t.id $false "Ошибка: $($_.Exception.Message)" 1 }
        }
        'rd_reset' {
            $p = Set-RdPassword
            Send-Result $t.id $true 'Новый пароль задан' 0 @{ rd_pass = $p }
        }
        default { Send-Result $t.id $false "Неизвестный тип задания: $($t.kind)" 1 }
    }
}

function Send-Result($id, $ok, $out, $code, $extra = @{}) {
    $body = @{ id = $id; ok = $ok; output = "$out"; code = $code }
    foreach ($k in $extra.Keys) { $body[$k] = $extra[$k] }
    try { Api '/a/result' $body | Out-Null } catch { Log "не отправил результат $id : $($_.Exception.Message)" }
}

function Check-Running {
    foreach ($id in @($Running.Keys)) {
        $r = $Running[$id]
        $done = $r.proc.HasExited
        if (-not $done -and (Get-Date) -gt $r.deadline) { try { $r.proc.Kill() } catch { }; $done = $true; $r.timeout = $true }
        if (-not $done) { continue }
        $out = "$($r.note)"
        if ($r.out -and (Test-Path $r.out)) { $out += [IO.File]::ReadAllText($r.out, [Text.Encoding]::UTF8) }
        if ($r.err -and (Test-Path $r.err)) { $e = [IO.File]::ReadAllText($r.err, [Text.Encoding]::UTF8); if ($e.Trim()) { $out += "`r`n--- ошибки ---`r`n" + $e } }
        if ($r.timeout) { $out += "`r`n(остановлено: дольше 30 минут)" }
        $code = if ($r.timeout) { -1 } else { $r.proc.ExitCode }
        Send-Result $id ((-not $r.timeout) -and ($code -eq 0 -or $code -eq $null)) $out.Trim() $code
        foreach ($f in @($r.out, $r.err) + $r.files) { if ($f) { Remove-Item $f -Force -ErrorAction SilentlyContinue } }
        $Running.Remove($id)
    }
}

# ------------------------------------------------------------------ главный цикл

Log "агент $AgentVersion запущен"
$lastRd = [datetime]::MinValue
$ForceRd = $true
$NeedPrograms = $true
$interval = 20
while ($true) {
    try {
        $rep = @{ info = Get-Info }
        if ($cfg.rd_id) { $rep.rd_id = $cfg.rd_id }
        if ($cfg.rd_pass) { $rep.rd_pass = $cfg.rd_pass }
        if ($script:NeedPrograms) { $rep.programs = Get-Programs }
        $resp = Api '/a/report' $rep
        $script:NeedPrograms = [bool]$resp.need_programs
        if ($resp.client) { Switch-Client ([string]$resp.client) }
        # на сервере новая сборка «Моста» — обновить (установщик ставит поверх, ID и настройки сохраняются)
        if ($script:Client -eq 'most' -and $resp.most_ver -and (Test-Path $script:RdExe) -and $cfg.most_ver -and $cfg.most_ver -ne $resp.most_ver) {
            Log "новая сборка «Моста» ($($resp.most_ver)) — обновляю"
            if (Install-Client) { $script:ForceRd = $true }
        }
        if ($script:Client -eq 'most' -and $resp.most_ver -and (Test-Path $script:RdExe) -and $cfg.most_ver -ne $resp.most_ver) {
            $cfg | Add-Member -NotePropertyName most_ver -NotePropertyValue ([string]$resp.most_ver) -Force; Save-Cfg
        }
        if ($resp.interval) { $interval = [int]$resp.interval }
        foreach ($t in @($resp.tasks)) { if ($t) { Log "задание $($t.id): $($t.title)"; try { Start-Task $t } catch { Send-Result $t.id $false "Ошибка: $($_.Exception.Message)" 1 } } }
        Check-Running
        # RustDesk — после отчёта, чтобы ПК сразу был виден в панели
        if ($ForceRd -or ((Get-Date) - $lastRd).TotalMinutes -ge $(if ($script:RdRetry) { 2 } else { 30 })) {
            $script:RdRetry = $false
            $ForceRd = $false; $lastRd = Get-Date
            try { Ensure-RustDesk | Out-Null } catch { Log "$($script:C.title): $($_.Exception.Message) (строка $($_.InvocationInfo.ScriptLineNumber))" }
        }
        if ($resp.agent_version -and $resp.agent_version -ne $AgentVersion -and $Running.Count -eq 0) {
            # самообновление агента: новая версия с панели, задача Windows перезапустит через ≤5 минут
            $wc = New-Object Net.WebClient; $wc.Encoding = [Text.Encoding]::UTF8
            $new = $wc.DownloadString("$Panel/agent.ps1?t=$($cfg.token)")
            if ($new -match 'AgentVersion') {
                [IO.File]::WriteAllText("$Dir\agent.ps1", $new, (New-Object Text.UTF8Encoding $true))
                Log "обновлён до $($resp.agent_version) — перезапуск"
                # перезапуск сразу, а не через 5 минут по расписанию: отдельный процесс подождёт выхода и запустит задачу
                Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile -ExecutionPolicy Bypass -Command "Start-Sleep 5; Start-ScheduledTask -TaskName OfficeAgent"' | Out-Null
                $mutex.ReleaseMutex(); exit
            }
        }
    } catch {
        Log "нет связи с панелью: $($_.Exception.Message)"
        Check-Running
    }
    # до следующего отчёта — каждые 3 секунды проверяем, нет ли срочных заданий (подключение и т.п.)
    $until = (Get-Date).AddSeconds($interval)
    while ((Get-Date) -lt $until) {
        Start-Sleep -Seconds 3
        try {
            $pr = Api '/a/poll' @{}
            foreach ($t in @($pr.tasks)) { if ($t) { Log "задание $($t.id): $($t.title)"; try { Start-Task $t } catch { Send-Result $t.id $false "Ошибка: $($_.Exception.Message)" 1 } } }
        } catch { }
        Check-Running
    }
}
