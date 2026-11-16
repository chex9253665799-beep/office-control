"""Диагностика RustDesk на ПК офиса: ставит задание агенту и печатает ответ (секреты скрыты).
Запуск на сервере: python3 rd_diag.py <часть имени ПК>"""
import json, re, sqlite3, sys, time

PS = r'''
$d = "$env:windir\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config"
'--- файлы настроек'; Get-ChildItem $d -ErrorAction SilentlyContinue | ForEach-Object { "{0}  {1} байт  {2}" -f $_.Name, $_.Length, $_.LastWriteTime }
'--- RustDesk2.toml (значения ключей скрыты)'
Get-Content "$d\RustDesk2.toml" -ErrorAction SilentlyContinue | ForEach-Object {
  if ($_ -match "^\s*(verification-method|approve-mode|allow-|enable-|access-mode|whitelist|direct-server|stop-service)") { $_ }
  elseif ($_ -match "^\s*([\w-]+)\s*=") { "$($Matches[1]) = …" } else { $_ } }
'--- RustDesk.toml'
Get-Content "$d\RustDesk.toml" -ErrorAction SilentlyContinue | ForEach-Object {
  if ($_ -match "^\s*(password|salt|enc_id|id)\s*=\s*'(.*)'") { "$($Matches[1]) = длина $($Matches[2].Length), начало '$($Matches[2].Substring(0, [Math]::Min(2, $Matches[2].Length)))'" }
  elseif ($_ -match "^\s*([\w-]+)\s*=") { "$($Matches[1]) = …" } elseif ($_ -match "^\s*\[") { $_ } } # прочие строки (ключи, массивы) не выводим
'--- процессы RustDesk'
Get-CimInstance Win32_Process -Filter "name='rustdesk.exe'" | ForEach-Object { "pid $($_.ProcessId) сеанс $($_.SessionId): $($_.CommandLine)" }
(Get-Item "$env:ProgramFiles\RustDesk\rustdesk.exe").VersionInfo.ProductVersion
'--- журнал RustDesk (вход/пароль)'
$logs = @("$env:windir\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\log", "$env:windir\System32\config\systemprofile\AppData\Roaming\RustDesk\log", "$env:ProgramData\RustDesk\log")
foreach ($l in $logs) { if (Test-Path $l) { Get-ChildItem $l -Recurse -File | Sort-Object LastWriteTime -Descending | Select-Object -First 3 | ForEach-Object {
  "== $($_.FullName)"; Get-Content $_.FullName -Tail 400 | Select-String -Pattern 'password|Password|login|Login|auth|verif|approve|salt|denied|wrong' | Select-Object -Last 25 | ForEach-Object { $_.Line } } } }
'--- проверка команды --password (без смены: пустой аргумент)'
$j = Start-Job { Set-Location "$env:ProgramFiles\RustDesk"; (& .\rustdesk.exe --get-id | Out-String) }; if (Wait-Job $j -Timeout 20) { 'get-id: ' + (Receive-Job $j) } else { 'get-id: нет ответа' }
'конец'
'''


def mask(t):
    t = re.sub(r"\b\d{7,}\b", "#######", t)
    return re.sub(r"[A-Za-z0-9+/=_-]{14,}", lambda m: m.group(0) if re.search(r"[а-я]|Program|ServiceProfiles|AppData|Roaming|rustdesk", m.group(0), re.I) else "<скрыто>", t)


name = sys.argv[1] if len(sys.argv) > 1 else ""
c = sqlite3.connect("/opt/office/office.db", timeout=30)
c.row_factory = sqlite3.Row
pc = c.execute("SELECT id, hostname FROM pcs WHERE hostname LIKE ? ORDER BY last_seen DESC LIMIT 1", (f"%{name}%",)).fetchone()
if not pc:
    sys.exit("ПК не найден")
cur = c.execute("INSERT INTO tasks(pc_id, created, title, kind, payload) VALUES(?,?,?,?,?)",
                (pc["id"], int(time.time()), "Диагностика RustDesk", "ps", PS))
c.commit()
tid = cur.lastrowid
print("ПК:", pc["hostname"], "| задание", tid)
for _ in range(60):
    time.sleep(3)
    r = c.execute("SELECT status, output FROM tasks WHERE id=?", (tid,)).fetchone()
    if r["status"] in ("done", "error"):
        print("статус:", r["status"])
        out = "\n".join(l for l in (r["output"] or "").splitlines() if not re.fullmatch(r"\s*\d+,?\s*|\s*[\[\]],?\s*", l))
        print(mask(out))
        break
else:
    print("нет ответа за 3 минуты")
