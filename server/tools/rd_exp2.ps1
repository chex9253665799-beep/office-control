$fs = @("$env:windir\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config\RustDesk.toml", "$env:windir\System32\config\systemprofile\AppData\Roaming\RustDesk\config\RustDesk.toml") + @(Get-ChildItem C:\Users -Directory -ErrorAction SilentlyContinue | ForEach-Object { "$($_.FullName)\AppData\Roaming\RustDesk\config\RustDesk.toml" })
function St { foreach ($f in $fs) { if (Test-Path $f) { $l = (Get-Content $f | Select-String "^password\s*=\s*'(.*)'").Matches; "  {0}: пароль длина {1}, изменён {2}" -f ($f -replace '^.*\\(ServiceProfiles|System32|Users)\\', '$1\'), $(if ($l) { $l[0].Groups[1].Value.Length } else { '-' }), (Get-Item $f).LastWriteTime.ToString('HH:mm:ss') } } }
'--- каналы'; [IO.Directory]::GetFiles('\\.\pipe\') | Where-Object { $_ -match 'RustDesk' }
'--- до'; St
$pw = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 12 | ForEach-Object { [char]$_ })
$j = Start-Job { param($p) Set-Location "$env:ProgramFiles\RustDesk"; (& .\rustdesk.exe --password $p | Out-String) } -ArgumentList $pw
if (Wait-Job $j -Timeout 30) { 'ответ: [' + ((Receive-Job $j) -join ' ').Trim() + ']' } else { 'нет ответа'; Stop-Job $j }
Start-Sleep 5; '--- после'; St
'--- журнал службы (последние строки)'
Get-ChildItem "$env:windir\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\log" -Recurse -File | Sort-Object LastWriteTime -Descending | Select-Object -First 2 | ForEach-Object { "== $($_.Directory.Name)/$($_.Name)"; Get-Content $_.FullName -Tail 15 | Where-Object { $_ -notmatch 'clipboard' } }
'конец'
