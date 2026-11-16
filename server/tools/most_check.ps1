$d = "$env:ProgramFiles\Most"
'--- папка'; Get-ChildItem $d -Filter *.exe -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name) $($_.Length)" }
'--- службы'; Get-CimInstance Win32_Service | Where-Object { $_.Name -match 'Most|RustDesk' } | ForEach-Object { "$($_.Name) [$($_.State)] $($_.PathName)" }
'--- процессы'; Get-CimInstance Win32_Process | Where-Object { $_.Name -match 'most|rustdesk' } | ForEach-Object { "$($_.Name) сеанс $($_.SessionId): $($_.CommandLine)" }
'--- настройки Most'
$c = "$env:windir\ServiceProfiles\LocalService\AppData\Roaming\Most\config"
Get-ChildItem $c -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name) $($_.Length) $($_.LastWriteTime)" }
Get-Content "$c\Most.toml" -ErrorAction SilentlyContinue | ForEach-Object { if ($_ -match "^\s*(password|salt|enc_id|id)\s*=\s*'(.*)'") { "$($Matches[1]) длина $($Matches[2].Length)" } }
'--- get-id'
$j = Start-Job { Set-Location "$env:ProgramFiles\Most"; (& .\Most.exe --get-id | Out-String) }; if (Wait-Job $j -Timeout 25) { 'get-id: [' + ((Receive-Job $j) -join '').Trim() + ']' } else { 'get-id: нет ответа'; Stop-Job $j }
'--- журнал Most (служба/сервер)'
Get-ChildItem "$env:windir\ServiceProfiles\LocalService\AppData\Roaming\Most\log" -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 2 | ForEach-Object { "-- $($_.Directory.Name)/$($_.Name)"; Get-Content $_.FullName -Tail 15 | Where-Object { $_ -notmatch 'clipboard' } }
'--- журнал агента'; Get-Content C:\ProgramData\OfficeAgent\agent.log -Tail 8
'конец'
