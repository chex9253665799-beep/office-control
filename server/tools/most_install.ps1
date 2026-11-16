'--- где распакован «Мост»'
$cands = Get-ChildItem "$env:windir\System32\config\systemprofile\AppData\Local", "$env:windir\Temp", "$env:windir\SystemTemp", "$env:ProgramData" -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^most' }
$cands | ForEach-Object { "$($_.FullName) $($_.LastWriteTime)" }
$exe = $cands | ForEach-Object { Get-ChildItem $_.FullName -Filter 'most.exe' -ErrorAction SilentlyContinue } | Select-Object -First 1
if (-not $exe) { 'most.exe не найден среди распакованных'; 'конец'; return }
"exe: $($exe.FullName)"
'--- установка с выводом'
$j = Start-Job { param($e) Set-Location (Split-Path $e); (& $e --silent-install | Out-String) } -ArgumentList $exe.FullName
if (Wait-Job $j -Timeout 150) { 'вывод: [' + ((Receive-Job $j) -join ' ').Trim() + ']' } else { 'нет ответа за 150 с'; Stop-Job $j }
Start-Sleep 5
'--- после'
Get-ChildItem $env:ProgramFiles -Directory | Where-Object { $_.Name -match 'Мост|most' } | ForEach-Object { "$($_.FullName)"; Get-ChildItem $_.FullName -Filter *.exe | ForEach-Object { "   $($_.Name)" } }
Get-CimInstance Win32_Service | Where-Object { $_.Name -match 'Мост|most' } | ForEach-Object { "служба $($_.Name) [$($_.State)] $($_.PathName)" }
'--- журнал'
Get-ChildItem "$env:windir\ServiceProfiles\LocalService\AppData\Roaming\Мост\log", "$env:windir\System32\config\systemprofile\AppData\Roaming\Мост\log" -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 3 | ForEach-Object { "-- $($_.FullName)"; Get-Content $_.FullName -Tail 30 | Where-Object { $_ -notmatch 'clipboard' } }
'конец'
