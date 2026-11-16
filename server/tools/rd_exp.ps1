$d = "$env:windir\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config"
function St { $l = (Get-Content "$d\RustDesk.toml" | Select-String "^password\s*=\s*'(.*)'").Matches; "  пароль в файле: длина " + $(if ($l) { $l[0].Groups[1].Value.Length } else { 'нет строки' }) + ", файл изменён " + (Get-Item "$d\RustDesk.toml").LastWriteTime.ToString('HH:mm:ss') }
'--- каналы RustDesk'; [IO.Directory]::GetFiles('\\.\pipe\') | Where-Object { $_ -match 'RustDesk' }
'--- до'; St
$pw = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 12 | ForEach-Object { [char]$_ })
'--- 1) как сейчас делает агент (фоновая задача от системы)'
$j = Start-Job { param($p) Set-Location "$env:ProgramFiles\RustDesk"; (& .\rustdesk.exe --password $p | Out-String) } -ArgumentList $pw
if (Wait-Job $j -Timeout 30) { 'ответ: [' + ((Receive-Job $j) -join ' ').Trim() + ']' } else { 'нет ответа' }
Start-Sleep 3; St
'--- 2) через cmd | more (как в документации)'
$o = cmd /c "cd /d `"%ProgramFiles%\RustDesk`" && rustdesk.exe --password $pw | more" 2>&1 | Out-String
'ответ: [' + $o.Trim() + ']'
Start-Sleep 3; St
'--- 3) --get-option verification-method / approve-mode'
foreach ($k in 'verification-method', 'approve-mode') { $o = cmd /c "cd /d `"%ProgramFiles%\RustDesk`" && rustdesk.exe --get-option $k | more" 2>&1 | Out-String; "$k = [" + $o.Trim() + "]" }
'конец'
