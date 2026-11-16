# Установка «Агента офиса» на ПК. Запускать от имени администратора (команда из панели «Добавить ПК»).
# Что делает: кладёт агента в C:\ProgramData\OfficeAgent, регистрирует ПК в панели,
# создаёт задачу Windows «OfficeAgent» (от SYSTEM, при включении и каждые 5 минут — если агент упал, поднимет).
# RustDesk со своим сервером и паролем агент поставит сам в первую минуту.

$ErrorActionPreference = 'Stop'
$Panel = '__PANEL__'
$Thumb = '__THUMB__'
$Token = '__TOKEN__'
$Dir   = "$env:ProgramData\OfficeAgent"

function Say($t, $c = 'Gray') { Write-Host $t -ForegroundColor $c }

$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Say 'Нужно запустить PowerShell от имени администратора (правой кнопкой → «Запуск от имени администратора»).' Red
    return
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Net.ServicePointManager]::ServerCertificateValidationCallback = { param($a, $c) $c.GetCertHashString() -eq $Thumb }

Say 'Агент офиса: установка…' Cyan
New-Item -ItemType Directory -Force -Path $Dir, "$Dir\tmp" | Out-Null
# папка агента — только система и администраторы; tmp — ещё и пользователи (для команд в их сеансе)
icacls $Dir /inheritance:r /grant:r 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' | Out-Null
icacls "$Dir\tmp" /grant 'Users:(OI)(CI)M' | Out-Null

$wc = New-Object Net.WebClient
$wc.Encoding = [Text.Encoding]::UTF8
$agent = $wc.DownloadString("$Panel/agent.ps1?t=$Token")
[IO.File]::WriteAllText("$Dir\agent.ps1", $agent, (New-Object Text.UTF8Encoding $true))

# регистрация в панели (тот же ПК при переустановке остаётся той же записью — по MachineGuid)
$guid = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid
$body = @{ token = $Token; guid = $guid; hostname = $env:COMPUTERNAME } | ConvertTo-Json
$r = Invoke-RestMethod -Method Post -Uri "$Panel/a/enroll" -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8'
$cfg = @{ id = $r.id; secret = $r.secret; panel = $Panel; thumb = $Thumb; token = $Token }
if (Test-Path "$Dir\agent.json") {   # пароль RustDesk с прошлой установки сохраняем
    try { $old = Get-Content "$Dir\agent.json" -Raw | ConvertFrom-Json; if ($old.rd_pass) { $cfg.rd_pass = $old.rd_pass } } catch { }
}
[IO.File]::WriteAllText("$Dir\agent.json", ($cfg | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
Say "Зарегистрирован в панели: $env:COMPUTERNAME" Green

# задача Windows: при включении и каждые 5 минут (если агент уже работает — второй не запускается)
$act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Dir\agent.ps1`""
$t1 = New-ScheduledTaskTrigger -AtStartup
$t2 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
$set = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
$pr = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName 'OfficeAgent' -Action $act -Trigger $t1, $t2 -Settings $set -Principal $pr -Force | Out-Null
Start-ScheduledTask -TaskName 'OfficeAgent'

Say 'Готово! ПК появится в панели в течение минуты. RustDesk агент поставит сам (пара минут).' Green
