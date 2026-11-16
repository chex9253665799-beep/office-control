$Dir = "$env:ProgramData\OfficeAgent"
$src = Get-Content "$Dir\agent.ps1" -Raw -Encoding UTF8
$a = $src.IndexOf('$cfg = Get-Content'); $b = $src.IndexOf('# ------------------------------------------------------------------ главный цикл')
$body = $src.Substring($a, $b - $a)
$global:TRACE = New-Object System.Collections.Generic.List[string]
. ([scriptblock]::Create($body))
function Log($t) { $global:TRACE.Add("LOG: $t") }
function Save-Cfg { $global:TRACE.Add('SAVE-CFG') }
function Remove-OldRustDesk { $global:TRACE.Add('REMOVE-OLD вызван') }
"клиент: $script:Client / exe: $script:RdExe / есть: $(Test-Path $script:RdExe)"
"rd_id в cfg: длина $("$($cfg.rd_id)".Length); rd_pass: длина $("$($cfg.rd_pass)".Length)"
$raw = Rd '--get-id'
"get-id: длина $("$raw".Length), только цифры: $(($raw -replace '\s','') -match '^\d{6,}$')"
try { $r = Ensure-RustDesk; "Ensure вернул: $r" } catch { "ОШИБКА: $($_.Exception.Message) строка $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())" }
$global:TRACE | ForEach-Object { $_ -replace '\b\d{7,}\b', '#######' }
'конец'
