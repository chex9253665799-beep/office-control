$c = Get-Content C:\ProgramData\OfficeAgent\agent.json -Raw | ConvertFrom-Json
"client=[$($c.client)] rd_id длина=$("$($c.rd_id)".Length) rd_pass длина=$("$($c.rd_pass)".Length) most_ver=[$($c.most_ver)]"
$j = Start-Job { Set-Location "$env:ProgramFiles\Most"; (& "$env:ProgramFiles\Most\Most.exe" --get-id | Out-String) }; if (Wait-Job $j -Timeout 25) { $o = ((Receive-Job $j) -join '').Trim(); "get-id длина=$($o.Length) цифры=$($o -match '^\d{6,}$') совпадает с agent.json=$($o -eq "$($c.rd_id)")" } else { 'get-id: нет ответа' }
'--- конец журнала'; Get-Content C:\ProgramData\OfficeAgent\agent.log -Tail 5
'конец'
