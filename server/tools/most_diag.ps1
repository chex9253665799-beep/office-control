'--- папки программ'
Get-ChildItem $env:ProgramFiles, ${env:ProgramFiles(x86)} -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Мост|most|RustDesk' } | ForEach-Object { "$($_.FullName)"; Get-ChildItem $_.FullName -Filter *.exe | ForEach-Object { "   $($_.Name) $($_.Length)" } }
'--- службы'
Get-CimInstance Win32_Service | Where-Object { $_.Name -match 'Мост|most|RustDesk' -or $_.PathName -match 'Мост|most|RustDesk' } | ForEach-Object { "$($_.Name) [$($_.State)] $($_.PathName)" }
'--- процессы'
Get-CimInstance Win32_Process | Where-Object { $_.Name -match 'Мост|most|rustdesk' } | ForEach-Object { "$($_.ProcessId) $($_.Name): $($_.CommandLine)" }
'--- файл установщика'
Get-ChildItem C:\ProgramData\OfficeAgent\tmp -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name) $($_.Length) $($_.LastWriteTime)" }
'--- временные папки'
Get-ChildItem "$env:windir\Temp", "$env:windir\SystemTemp" -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Мост|most|rustdesk' } | ForEach-Object { "$($_.FullName) $($_.LastWriteTime)"; Get-ChildItem $_.FullName -Filter *.exe | Select-Object -First 3 | ForEach-Object { "   $($_.Name)" } }
'--- журналы'
foreach ($b in "$env:windir\ServiceProfiles\LocalService\AppData\Roaming", "$env:windir\System32\config\systemprofile\AppData\Roaming", "$env:ProgramData") {
  Get-ChildItem $b -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Мост|most' } | ForEach-Object {
    "== $($_.FullName)"
    Get-ChildItem "$($_.FullName)\log" -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 2 | ForEach-Object { "-- $($_.FullName)"; Get-Content $_.FullName -Tail 25 } } }
'--- ярлыки'
Get-ChildItem "$env:ProgramData\Microsoft\Windows\Start Menu\Programs" -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Мост|most|RustDesk' } | ForEach-Object { $_.Name }
'конец'
