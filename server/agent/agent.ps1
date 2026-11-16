# Агент офиса. Работает от SYSTEM (задача Windows «OfficeAgent»).
# Каждые 20 секунд: отчёт в панель (состояние ПК) и получение заданий. Задания выполняются в фоне.
# Связь только с панелью по HTTPS, сертификат панели сверяется по отпечатку.

$AgentVersion = '1.1'
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
        rustdesk = [bool](Get-Service RustDesk -ErrorAction SilentlyContinue)
    }
}

function Get-Programs {
    $keys = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    @(Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -and -not $_.SystemComponent } |
        Sort-Object DisplayName -Unique | ForEach-Object { @{ n = $_.DisplayName; v = $_.DisplayVersion; p = $_.Publisher } })
}

# ------------------------------------------------------------------ RustDesk со своим сервером

$RdExe = "$env:ProgramFiles\RustDesk\rustdesk.exe"

# команда RustDesk с ограничением по времени (иначе может зависнуть навсегда)
function Rd([string[]]$a, [int]$sec = 30) {
    $o = "$Dir\tmp\rd.out"; $e = "$Dir\tmp\rd.err"
    Remove-Item $o, $e -Force -ErrorAction SilentlyContinue
    $p = Start-Process $RdExe -ArgumentList $a -NoNewWindow -PassThru -RedirectStandardOutput $o -RedirectStandardError $e
    if (-not $p.WaitForExit($sec * 1000)) {
        try { $p.Kill() } catch {}
        Log "RustDesk $($a[0]): нет ответа за $sec с"
        return ''
    }
    return ("$(Get-Content $o -Raw -ErrorAction SilentlyContinue)$(Get-Content $e -Raw -ErrorAction SilentlyContinue)").Trim()
}

function New-Pass {
    $chars = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    -join (1..12 | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
}

# Поставить RustDesk (если нет), направить на наш сервер, задать постоянный пароль. Возвращает $true, если пароль новый.
function Ensure-RustDesk([bool]$newPass = $false) {
    if (-not (Test-Path $RdExe)) {
        Log 'RustDesk не найден — ставлю'
        $f = "$Dir\tmp\rustdesk.exe"
        Download '/dl/rustdesk.exe' $f
        # не ждём установщик: после установки он сам запускает RustDesk и «не завершается»
        Start-Process $f -ArgumentList '--silent-install' | Out-Null
        for ($i = 0; $i -lt 90 -and -not ((Test-Path $RdExe) -and (Get-Service RustDesk -ErrorAction SilentlyContinue)); $i++) { Start-Sleep 2 }
        Start-Sleep 10
        if (-not (Test-Path $RdExe)) { Log 'RustDesk не установился'; return $false }
    }
    if ((Get-Service RustDesk -ErrorAction SilentlyContinue).Status -ne 'Running') { Start-Service RustDesk -ErrorAction SilentlyContinue; Start-Sleep 3 }
    if ((Rd '--option', 'custom-rendezvous-server') -ne '__RD_HOST__') {
        Rd '--option', 'custom-rendezvous-server', '__RD_HOST__' | Out-Null
        Rd '--option', 'relay-server', '__RD_HOST__' | Out-Null
        Rd '--option', 'key', '__RD_KEY__' | Out-Null
        Log 'RustDesk направлен на сервер офиса'
    }
    $changed = $false
    if ($newPass -or -not $cfg.rd_pass) {
        $p = New-Pass
        $res = Rd '--password', $p
        if ($res -match 'Done') {
            $cfg | Add-Member -NotePropertyName rd_pass -NotePropertyValue $p -Force
            Save-Cfg; $changed = $true; Log 'пароль RustDesk задан'
        } else { Log "пароль RustDesk не задан: $res" }
    }
    $id = Rd '--get-id'
    if ($id -notmatch '^\d{6,}$') {   # запасной путь: ID из настроек службы RustDesk
        $toml = "$env:windir\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config\RustDesk.toml"
        if (Test-Path $toml) { $m = Select-String -Path $toml -Pattern "^id\s*=\s*'(\d+)'" | Select-Object -First 1; if ($m) { $id = $m.Matches[0].Groups[1].Value } }
    }
    if ($id -match '^\d{6,}$' -and $id -ne $cfg.rd_id) { $cfg | Add-Member -NotePropertyName rd_id -NotePropertyValue $id -Force; Save-Cfg; $changed = $true }
    return $changed
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
            $ok = Ensure-RustDesk $true
            Send-Result $t.id $ok $(if ($ok) { 'Новый пароль задан, он уже в панели' } else { 'Не удалось сменить пароль, см. журнал агента' }) $(if ($ok) { 0 } else { 1 })
            $script:ForceRd = $true
        }
        default { Send-Result $t.id $false "Неизвестный тип задания: $($t.kind)" 1 }
    }
}

function Send-Result($id, $ok, $out, $code) {
    try { Api '/a/result' @{ id = $id; ok = $ok; output = "$out"; code = $code } | Out-Null } catch { Log "не отправил результат $id : $($_.Exception.Message)" }
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
        if ($resp.interval) { $interval = [int]$resp.interval }
        foreach ($t in @($resp.tasks)) { if ($t) { Log "задание $($t.id): $($t.title)"; try { Start-Task $t } catch { Send-Result $t.id $false "Ошибка: $($_.Exception.Message)" 1 } } }
        Check-Running
        # RustDesk — после отчёта, чтобы ПК сразу был виден в панели
        if ($ForceRd -or ((Get-Date) - $lastRd).TotalMinutes -ge 30) {
            $ForceRd = $false; $lastRd = Get-Date
            try { Ensure-RustDesk | Out-Null } catch { Log "RustDesk: $($_.Exception.Message)" }
        }
        if ($resp.agent_version -and $resp.agent_version -ne $AgentVersion -and $Running.Count -eq 0) {
            # самообновление агента: новая версия с панели, задача Windows перезапустит через ≤5 минут
            $wc = New-Object Net.WebClient; $wc.Encoding = [Text.Encoding]::UTF8
            $new = $wc.DownloadString("$Panel/agent.ps1?t=$($cfg.token)")
            if ($new -match 'AgentVersion') {
                [IO.File]::WriteAllText("$Dir\agent.ps1", $new, (New-Object Text.UTF8Encoding $true))
                Log "обновлён до $($resp.agent_version) — перезапуск"
                $mutex.ReleaseMutex(); exit
            }
        }
    } catch {
        Log "нет связи с панелью: $($_.Exception.Message)"
        Check-Running
    }
    Start-Sleep -Seconds $interval
}
