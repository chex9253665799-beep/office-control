#!/usr/bin/env python3
"""
Панель офиса: учёт ПК, удалённые действия, связка со своим сервером RustDesk.
Только стандартная библиотека Python 3.8+ (ничего не ставим через pip), данные — SQLite.
Запуск: python3 panel.py /opt/office/config.json
"""
import base64
import struct
import hashlib
import hmac
import http.cookies
import json
import os
import re
import secrets
import sqlite3
import ssl
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "1.0"
CFG_PATH = sys.argv[1] if len(sys.argv) > 1 else "/opt/office/config.json"
CFG = json.load(open(CFG_PATH, encoding="utf-8"))
HOME = os.path.dirname(os.path.abspath(CFG_PATH))
WEB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "web")
AGENT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "agent")
FILES = os.path.join(HOME, "files")
UPLOADS = os.path.join(FILES, "up")
os.makedirs(UPLOADS, exist_ok=True)
DB_PATH = os.path.join(HOME, "office.db")
ONLINE_SEC = 90          # ПК «в сети», если отчитывался за последние 90 секунд
MAX_UPLOAD = 2 * 1024 ** 3
LOCK = threading.Lock()
SESSIONS = {}            # токен -> {"exp": срок, "full": вход завершён (с кодом из приложения)}
PENDING_TOTP = {}        # токен -> секрет, пока настраивается код
LAST_TOTP = [0]          # последний принятый шаг кода — один код дважды не принимается
FAILS = {}               # ip -> (кол-во, время) — защита от перебора пароля


# ------------------------------------------------------------------ база

def db():
    c = sqlite3.connect(DB_PATH, timeout=30)
    c.row_factory = sqlite3.Row
    return c


def init_db():
    with db() as c:
        c.executescript("""
        CREATE TABLE IF NOT EXISTS pcs(
            id TEXT PRIMARY KEY, secret TEXT, guid TEXT, hostname TEXT, alias TEXT DEFAULT '', notes TEXT DEFAULT '',
            grp TEXT DEFAULT '', first_seen INTEGER, last_seen INTEGER, ip TEXT DEFAULT '', info TEXT DEFAULT '{}',
            programs TEXT DEFAULT '[]', programs_at INTEGER DEFAULT 0, rd_id TEXT DEFAULT '', rd_pass TEXT DEFAULT '');
        CREATE TABLE IF NOT EXISTS tasks(
            id INTEGER PRIMARY KEY AUTOINCREMENT, pc_id TEXT, created INTEGER, title TEXT, kind TEXT, payload TEXT,
            status TEXT DEFAULT 'pending', sent_at INTEGER, done_at INTEGER, output TEXT DEFAULT '', code INTEGER);
        CREATE INDEX IF NOT EXISTS tasks_pc ON tasks(pc_id, status);
        CREATE TABLE IF NOT EXISTS log(id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER, who TEXT, text TEXT);
        CREATE TABLE IF NOT EXISTS files(id TEXT PRIMARY KEY, name TEXT, size INTEGER, created INTEGER);
        """)


def log(who, text):
    with db() as c:
        c.execute("INSERT INTO log(ts, who, text) VALUES(?,?,?)", (int(time.time()), who, text))


# ------------------------------------------------------------------ библиотека действий
# kind: ps — PowerShell от SYSTEM; user — команда в сеансе пользователя; file — положить файл; reboot/…
# {арг} подставляются из формы (экранируются для PowerShell).

SCRIPTS = [
    {"id": "msg", "group": "Пользователь", "title": "Сообщение на экран", "kind": "user",
     "args": [{"name": "text", "label": "Текст сообщения"}],
     "payload": "Add-Type -AssemblyName PresentationFramework; [System.Windows.MessageBox]::Show({text}, 'Сообщение от администратора') | Out-Null"},
    {"id": "lock", "group": "Пользователь", "title": "Заблокировать экран (Win+L)", "kind": "user",
     "payload": "rundll32.exe user32.dll,LockWorkStation"},
    {"id": "logoff", "group": "Пользователь", "title": "Выйти из учётной записи", "kind": "ps", "danger": True,
     "payload": "quser 2>$null | Select-Object -Skip 1 | ForEach-Object { $id = ($_ -split '\\s+' | Where-Object { $_ -match '^\\d+$' } | Select-Object -First 1); if ($id) { logoff $id } }; 'готово'"},

    {"id": "reboot", "group": "Питание", "title": "Перезагрузить (через 1 минуту, с предупреждением)", "kind": "ps", "danger": True,
     "payload": "shutdown.exe /r /t 60 /c 'Администратор перезагрузит компьютер через 1 минуту. Сохраните работу.'; 'перезагрузка через 60 сек'"},
    {"id": "reboot_now", "group": "Питание", "title": "Перезагрузить сейчас", "kind": "ps", "danger": True,
     "payload": "shutdown.exe /r /t 0 /f; 'перезагружаю'"},
    {"id": "shutdown", "group": "Питание", "title": "Выключить (через 1 минуту)", "kind": "ps", "danger": True,
     "payload": "shutdown.exe /s /t 60 /c 'Администратор выключит компьютер через 1 минуту.'; 'выключение через 60 сек'"},
    {"id": "cancel_shutdown", "group": "Питание", "title": "Отменить перезагрузку/выключение", "kind": "ps",
     "payload": "shutdown.exe /a; 'отменено'"},

    {"id": "cleanup", "group": "Обслуживание", "title": "Очистить временные файлы и корзину", "kind": "ps",
     "payload": "$b=(Get-PSDrive C).Free; Get-ChildItem 'C:\\Users\\*\\AppData\\Local\\Temp\\*','C:\\Windows\\Temp\\*' -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue; Clear-RecycleBin -Force -ErrorAction SilentlyContinue; Start-Sleep 2; 'освобождено, МБ: ' + [math]::Round(((Get-PSDrive C).Free-$b)/1MB)"},
    {"id": "procs", "group": "Обслуживание", "title": "Что занимает память (топ-15 процессов)", "kind": "ps",
     "payload": "Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 15 Name, Id, @{n='Память, МБ';e={[math]::Round($_.WorkingSet64/1MB)}}, @{n='CPU, c';e={[math]::Round($_.CPU)}} | Format-Table -AutoSize | Out-String -Width 200"},
    {"id": "kill", "group": "Обслуживание", "title": "Закрыть программу", "kind": "ps",
     "args": [{"name": "name", "label": "Имя процесса (например chrome или excel)"}],
     "payload": "$n={name} -replace '\\.exe$',''; $p=Get-Process -Name $n -ErrorAction SilentlyContinue; if($p){$p|Stop-Process -Force; 'закрыто процессов: ' + @($p).Count}else{'не запущено: ' + $n}"},
    {"id": "updates", "group": "Обслуживание", "title": "Запустить проверку и установку обновлений Windows", "kind": "ps",
     "payload": "Start-Process UsoClient.exe -ArgumentList 'StartScan' -WindowStyle Hidden; Start-Sleep 5; Start-Process UsoClient.exe -ArgumentList 'StartDownload' -WindowStyle Hidden; Start-Process UsoClient.exe -ArgumentList 'StartInstall' -WindowStyle Hidden; 'обновления запущены (идут в фоне)'"},
    {"id": "spooler", "group": "Обслуживание", "title": "Перезапустить печать (если принтер завис)", "kind": "ps",
     "payload": "Stop-Service Spooler -Force; Remove-Item 'C:\\Windows\\System32\\spool\\PRINTERS\\*' -Force -ErrorAction SilentlyContinue; Start-Service Spooler; Get-Printer | Select-Object Name, PrinterStatus, PortName | Format-Table -AutoSize | Out-String -Width 200"},
    {"id": "net", "group": "Обслуживание", "title": "Сеть: IP, DNS, интернет", "kind": "ps",
     "payload": "Get-NetIPConfiguration | Format-List InterfaceAlias, IPv4Address, IPv4DefaultGateway, DNSServer | Out-String -Width 200; 'ya.ru: ' + (Test-Connection ya.ru -Count 2 -Quiet); 'google.com: ' + (Test-Connection google.com -Count 2 -Quiet)"},
    {"id": "dnsflush", "group": "Обслуживание", "title": "Сбросить DNS и сеть (если сайты не открываются)", "kind": "ps",
     "payload": "ipconfig /flushdns | Out-String; netsh winsock reset | Out-String; 'для полного сброса — перезагрузить ПК'"},

    {"id": "install_chrome", "group": "Программы", "title": "Установить / обновить Google Chrome", "kind": "ps",
     "payload": "$f=\"$env:TEMP\\chrome.msi\"; Invoke-WebRequest 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi' -OutFile $f -UseBasicParsing; $p=Start-Process msiexec.exe -ArgumentList \"/i `\"$f`\" /qn /norestart\" -Wait -PassThru; 'код установки: ' + $p.ExitCode"},
    {"id": "install_7zip", "group": "Программы", "title": "Установить 7-Zip", "kind": "ps",
     "payload": "$f=\"$env:TEMP\\7z.msi\"; Invoke-WebRequest 'https://www.7-zip.org/a/7z2409-x64.msi' -OutFile $f -UseBasicParsing; $p=Start-Process msiexec.exe -ArgumentList \"/i `\"$f`\" /qn /norestart\" -Wait -PassThru; 'код установки: ' + $p.ExitCode"},
    {"id": "install_url", "group": "Программы", "title": "Установить программу по ссылке (MSI или EXE)", "kind": "ps",
     "args": [{"name": "url", "label": "Ссылка на установщик"},
              {"name": "silent", "label": "Ключ тихой установки для EXE (для MSI не нужен), например /S", "default": "/S"}],
     "payload": "$u={url}; $ext=if($u -match '\\.msi(\\?|$)'){'msi'}else{'exe'}; $f=\"$env:TEMP\\setup_$([guid]::NewGuid().ToString('N').Substring(0,6)).$ext\"; Invoke-WebRequest $u -OutFile $f -UseBasicParsing; if($ext -eq 'msi'){$p=Start-Process msiexec.exe -ArgumentList \"/i `\"$f`\" /qn /norestart\" -Wait -PassThru}else{$p=Start-Process $f -ArgumentList {silent} -Wait -PassThru}; 'код установки: ' + $p.ExitCode"},
    {"id": "uninstall", "group": "Программы", "title": "Удалить программу (по названию)", "kind": "ps", "danger": True,
     "args": [{"name": "name", "label": "Часть названия из списка программ"}],
     "payload": "$n={name}; $k=Get-ItemProperty 'HKLM:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*','HKLM:\\Software\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like \"*$n*\" } | Select-Object -First 1; if(-not $k){'не найдено: ' + $n; return}; 'удаляю: ' + $k.DisplayName; if($k.UninstallString -match 'msiexec'){ $g=[regex]::Match($k.UninstallString,'\\{[^}]+\\}').Value; $p=Start-Process msiexec.exe -ArgumentList \"/x $g /qn /norestart\" -Wait -PassThru } else { $s=if($k.QuietUninstallString){$k.QuietUninstallString}else{$k.UninstallString + ' /S'}; $p=Start-Process cmd.exe -ArgumentList \"/c $s\" -Wait -PassThru }; 'код: ' + $p.ExitCode"},

    {"id": "usb_block", "group": "Безопасность", "title": "Запретить флешки (USB-накопители)", "kind": "ps", "danger": True,
     "payload": "Set-ItemProperty 'HKLM:\\SYSTEM\\CurrentControlSet\\Services\\USBSTOR' -Name Start -Value 4; 'флешки запрещены (мышь и клавиатура работают)'"},
    {"id": "usb_allow", "group": "Безопасность", "title": "Разрешить флешки", "kind": "ps",
     "payload": "Set-ItemProperty 'HKLM:\\SYSTEM\\CurrentControlSet\\Services\\USBSTOR' -Name Start -Value 3; 'флешки разрешены'"},
    {"id": "site_block", "group": "Безопасность", "title": "Заблокировать сайт", "kind": "ps",
     "args": [{"name": "domain", "label": "Сайт, например vk.com"}],
     "payload": "$d=({domain} -replace '^https?://','' -replace '/.*$','').ToLower(); $h='C:\\Windows\\System32\\drivers\\etc\\hosts'; $add=@(\"0.0.0.0 $d # office\",\"0.0.0.0 www.$d # office\") | Where-Object { -not (Select-String -Path $h -SimpleMatch $_ -Quiet) }; if($add){Add-Content $h $add}; ipconfig /flushdns | Out-Null; 'заблокирован: ' + $d"},
    {"id": "site_unblock", "group": "Безопасность", "title": "Разблокировать сайт", "kind": "ps",
     "args": [{"name": "domain", "label": "Сайт"}],
     "payload": "$d=({domain} -replace '^https?://','' -replace '/.*$','').ToLower(); $h='C:\\Windows\\System32\\drivers\\etc\\hosts'; (Get-Content $h) | Where-Object { $_ -notmatch (\"^0\\.0\\.0\\.0\\s+(www\\.)?\" + [regex]::Escape($d) + \"\\s+# office\") } | Set-Content $h; ipconfig /flushdns | Out-Null; 'разблокирован: ' + $d"},
    {"id": "defender_scan", "group": "Безопасность", "title": "Быстрая проверка на вирусы (Защитник Windows)", "kind": "ps",
     "payload": "Start-MpScan -ScanType QuickScan; Get-MpThreatDetection | Select-Object -First 10 InitialDetectionTime, ThreatID, Resources | Format-List | Out-String -Width 200; 'проверка завершена'"},

    {"id": "rd_password", "group": "Удалённый доступ", "title": "Сменить пароль удалённого доступа (RustDesk)", "kind": "rd_reset",
     "payload": ""},
]
SCRIPT_BY_ID = {s["id"]: s for s in SCRIPTS}


def ps_quote(v):
    return "'" + str(v).replace("'", "''") + "'"


def build_payload(script, args):
    p = script["payload"]
    for a in script.get("args", []):
        val = args.get(a["name"], a.get("default", ""))
        if not str(val).strip():
            raise ValueError("Не заполнено: " + a["label"])
        p = p.replace("{" + a["name"] + "}", ps_quote(val))
    return p


# ------------------------------------------------------------------ пароль администратора

def hash_pw(pw, salt=None):
    salt = salt or secrets.token_hex(16)
    return salt + "$" + hashlib.pbkdf2_hmac("sha256", pw.encode(), salt.encode(), 200_000).hex()


def check_pw(pw, stored):
    salt, h = stored.split("$", 1)
    return hmac.compare_digest(hash_pw(pw, salt).split("$", 1)[1], h)


# ------------------------------------------------------------------ сервер

def agent_version():
    m = re.search(r"\$AgentVersion\s*=\s*'([^']+)'", open(os.path.join(AGENT_DIR, "agent.ps1"), encoding="utf-8").read())
    return m.group(1) if m else ""


AGENT_VERSION = agent_version()


# ------------------------------------------------------------------ QR-код (без библиотек)
# байтовый режим, коррекция L, версии 1–5 (до 106 байт) — хватает для ссылки otpauth://

_QR_CAP = [(0, 0), (26, 7), (44, 10), (70, 15), (100, 20), (134, 26)]


def _gf_mul(x, y):
    z = 0
    for i in range(7, -1, -1):
        z = (z << 1) ^ ((z >> 7) * 0x11D)
        z ^= ((y >> i) & 1) * x
    return z & 0xFF


def _rs(words, degree):
    gen = [0] * degree
    gen[-1] = 1
    root = 1
    for _ in range(degree):
        for j in range(degree):
            gen[j] = _gf_mul(gen[j], root)
            if j + 1 < degree:
                gen[j] ^= gen[j + 1]
        root = _gf_mul(root, 2)
    res = [0] * degree
    for w in words:
        f = w ^ res[0]
        res = res[1:] + [0]
        for j in range(degree):
            res[j] ^= _gf_mul(gen[j], f)
    return res


def qr_matrix(text):
    data = text.encode("utf-8")
    ver = 1
    while ver <= 5 and (_QR_CAP[ver][0] - _QR_CAP[ver][1]) * 8 < 12 + len(data) * 8:
        ver += 1
    if ver > 5:
        raise ValueError("слишком длинный текст для QR")
    total, ecn = _QR_CAP[ver]
    dw = total - ecn
    bits = []

    def put(v, n):
        bits.extend((v >> i) & 1 for i in range(n - 1, -1, -1))
    put(4, 4)
    put(len(data), 8)
    for b in data:
        put(b, 8)
    put(0, min(4, dw * 8 - len(bits)))
    while len(bits) % 8:
        bits.append(0)
    pad = 0xEC
    while len(bits) < dw * 8:
        put(pad, 8)
        pad ^= 0xEC ^ 0x11
    words = [int("".join(map(str, bits[i:i + 8])), 2) for i in range(0, dw * 8, 8)]
    words += _rs(words, ecn)

    size = ver * 4 + 17
    m = [[False] * size for _ in range(size)]
    fn = [[False] * size for _ in range(size)]

    def st(x, y, v):
        m[y][x] = v
        fn[y][x] = True

    for x0, y0 in ((0, 0), (size - 7, 0), (0, size - 7)):
        for dy in range(-1, 8):
            for dx in range(-1, 8):
                x, y = x0 + dx, y0 + dy
                if 0 <= x < size and 0 <= y < size:
                    d = max(abs(dx - 3), abs(dy - 3))
                    st(x, y, d not in (2, 4))
    for i in range(8, size - 8):
        st(6, i, i % 2 == 0)
        st(i, 6, i % 2 == 0)
    if ver >= 2:
        c = size - 7
        for dy in range(-2, 3):
            for dx in range(-2, 3):
                st(c + dx, c + dy, max(abs(dx), abs(dy)) != 1)
    for i in range(9):
        fn[8][i] = fn[i][8] = True
    for i in range(8):
        fn[8][size - 1 - i] = fn[size - 1 - i][8] = True
    st(8, size - 8, True)

    bit, nbits = 0, len(words) * 8
    right = size - 1
    while right >= 1:
        if right == 6:
            right = 5
        for vert in range(size):
            for j in range(2):
                x = right - j
                up = ((right + 1) & 2) == 0
                y = size - 1 - vert if up else vert
                if fn[y][x]:
                    continue
                v = bit < nbits and ((words[bit >> 3] >> (7 - (bit & 7))) & 1) == 1
                bit += 1
                m[y][x] = v ^ ((x + y) % 2 == 0)
        right -= 2

    rem = 0b01000
    for _ in range(10):
        rem = (rem << 1) ^ ((rem >> 9) * 0x537)
    fb = ((0b01000 << 10) | rem) ^ 0x5412

    def b(i):
        return ((fb >> i) & 1) == 1
    for i in range(6):
        m[i][8] = b(i)
    m[7][8], m[8][8], m[8][7] = b(6), b(7), b(8)
    for i in range(9, 15):
        m[8][14 - i] = b(i)
    for i in range(8):
        m[8][size - 1 - i] = b(i)
    for i in range(8, 15):
        m[size - 15 + i][8] = b(i)
    m[size - 8][8] = True
    return m


def qr_svg(text, px=220):
    m = qr_matrix(text)
    n = len(m) + 8
    rects = "".join(f'<rect x="{x + 4}" y="{y + 4}" width="1" height="1"/>' for y, row in enumerate(m) for x, v in enumerate(row) if v)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {n} {n}" width="{px}" height="{px}" shape-rendering="crispEdges">'
            f'<rect width="{n}" height="{n}" fill="#fff"/><g fill="#000">{rects}</g></svg>')


# ------------------------------------------------------------------ код из приложения (TOTP, RFC 6238)

def totp_code(secret_b32, counter):
    key = base64.b32decode(secret_b32.upper() + "=" * (-len(secret_b32) % 8))
    h = hmac.new(key, struct.pack(">Q", counter), hashlib.sha1).digest()
    o = h[-1] & 15
    return "%06d" % ((struct.unpack(">I", h[o:o + 4])[0] & 0x7FFFFFFF) % 1000000)


def totp_check(secret_b32, code, replay=True):
    code = re.sub(r"\D", "", str(code or ""))
    if len(code) != 6 or not secret_b32:
        return False
    now = int(time.time()) // 30
    for c in (now - 1, now, now + 1):
        if hmac.compare_digest(totp_code(secret_b32, c), code):
            if replay:
                if c <= LAST_TOTP[0]:
                    return False
                LAST_TOTP[0] = c
            return True
    return False


def save_cfg():
    tmp = CFG_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(CFG, f, indent=2, ensure_ascii=False)
    os.chmod(tmp, 0o600)
    os.replace(tmp, CFG_PATH)


class H(BaseHTTPRequestHandler):
    server_version = "nginx"
    sys_version = ""
    protocol_version = "HTTP/1.1"
    timeout = 120   # «висящее» соединение не держит поток вечно

    def log_message(self, fmt, *a):
        pass

    # --- ответы
    def send(self, code, body=b"", ctype="application/json; charset=utf-8", headers=None):
        if isinstance(body, (dict, list)):
            body = json.dumps(body, ensure_ascii=False).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def body(self, limit=8 * 1024 * 1024):
        n = int(self.headers.get("Content-Length") or 0)
        if n > limit:
            raise ValueError("слишком большой запрос")
        return self.rfile.read(n) if n else b""

    def json_body(self):
        b = self.body()
        return json.loads(b.decode("utf-8")) if b else {}

    def client_ip(self):
        return self.client_address[0]

    # --- доступ администратора
    def admin(self):
        ck = http.cookies.SimpleCookie(self.headers.get("Cookie", ""))
        t = ck.get("oc") and ck["oc"].value
        s = SESSIONS.get(t or "")
        if s and s["exp"] > time.time():
            s["exp"] = time.time() + 12 * 3600
            return s
        return None

    def session_token(self):
        ck = http.cookies.SimpleCookie(self.headers.get("Cookie", ""))
        return ck["oc"].value if ck.get("oc") else ""

    # --- доступ агента
    def agent(self):
        a = self.headers.get("X-Agent", "")
        if ":" not in a:
            return None
        pid, sec = a.split(":", 1)
        with db() as c:
            r = c.execute("SELECT * FROM pcs WHERE id=?", (pid,)).fetchone()
        if r and hmac.compare_digest(r["secret"], sec):
            return r
        return None

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        try:
            self.route("GET")
        except Exception as e:  # noqa
            self.send(500, {"error": str(e)})

    def do_POST(self):
        try:
            self.route("POST")
        except ValueError as e:
            self.send(400, {"error": str(e)})
        except Exception as e:  # noqa
            self.send(500, {"error": str(e)})

    def do_DELETE(self):
        try:
            self.route("DELETE")
        except Exception as e:  # noqa
            self.send(500, {"error": str(e)})

    def not_found(self):
        return self.send(404, "Not Found", "text/plain")

    def route(self, method):
        u = urllib.parse.urlparse(self.path)
        path, q = u.path, urllib.parse.parse_qs(u.query)

        # секретный адрес админки: https://сервер:порт/<admin_path>/ — без него админки «нет»
        ap = "/" + CFG["admin_path"] if CFG.get("admin_path") else ""
        in_admin = not ap
        if ap:
            if path == ap:
                return self.send(302, b"", headers={"Location": ap + "/"})
            if path.startswith(ap + "/"):
                path, in_admin = path[len(ap):], True

        # ---------- установка агента (по токену подключения)
        if path in ("/install.ps1", "/agent.ps1"):
            if not hmac.compare_digest((q.get("t") or [""])[0], CFG["enroll_token"]):
                return self.not_found()
            name = "install.ps1" if path == "/install.ps1" else "agent.ps1"
            txt = open(os.path.join(AGENT_DIR, name), encoding="utf-8").read()
            txt = (txt.replace("__PANEL__", CFG["public_url"]).replace("__THUMB__", CFG["thumb"])
                   .replace("__TOKEN__", CFG["enroll_token"]).replace("__RD_HOST__", CFG["rd_host"])
                   .replace("__RD_KEY__", read_rd_key()))
            return self.send(200, txt, "text/plain; charset=utf-8")

        if path == "/dl/rustdesk.exe":
            sess = in_admin and self.admin()
            if not (self.agent() or hmac.compare_digest((q.get("t") or [""])[0], CFG["enroll_token"]) or (sess and sess["full"])):
                return self.not_found()
            return self.send_file(os.path.join(FILES, "rustdesk.exe"), "rustdesk.exe")

        # ---------- агент
        if path == "/a/enroll" and method == "POST":
            return self.a_enroll()
        if path.startswith("/a/"):
            pc = self.agent()
            if not pc:
                return self.send(401, {"error": "агент не зарегистрирован"})
            if path == "/a/report" and method == "POST":
                return self.a_report(pc)
            if path == "/a/result" and method == "POST":
                return self.a_result(pc)
            m = re.match(r"^/a/file/([0-9a-f]{32})$", path)
            if m:
                return self.send_file(os.path.join(UPLOADS, m.group(1)), None)
            return self.send(404, {"error": "нет такого"})

        if not in_admin:
            return self.not_found()

        # ---------- вход
        if path == "/api/login" and method == "POST":
            return self.login()
        if path in ("/", "/index.html"):
            return self.send(200, open(os.path.join(WEB, "index.html"), "rb").read(), "text/html; charset=utf-8",
                             {"Content-Security-Policy": "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; img-src 'self' data:"})

        # ---------- панель (только администратор)
        if path.startswith("/api/"):
            sess = self.admin()
            if not sess:
                return self.send(401, {"error": "нужно войти"})
            if not sess["full"]:   # вошёл по паролю, но код из приложения ещё не настроен
                return self.api_2fa_setup(method, path, sess)
            return self.api(method, path, q)
        return self.not_found()

    # ------------------------------------------------------------------ агент

    def a_enroll(self):
        d = self.json_body()
        if not hmac.compare_digest(str(d.get("token", "")), CFG["enroll_token"]):
            return self.send(403, {"error": "неверный токен"})
        guid = str(d.get("guid", ""))[:80]
        host = str(d.get("hostname", ""))[:80]
        now = int(time.time())
        secret = secrets.token_hex(24)
        with LOCK, db() as c:
            r = c.execute("SELECT id FROM pcs WHERE guid=? AND guid<>''", (guid,)).fetchone()
            if r:   # переустановка на том же ПК — та же запись
                pid = r["id"]
                c.execute("UPDATE pcs SET secret=?, hostname=?, last_seen=? WHERE id=?", (secret, host, now, pid))
            else:
                pid = secrets.token_hex(8)
                c.execute("INSERT INTO pcs(id, secret, guid, hostname, first_seen, last_seen, ip) VALUES(?,?,?,?,?,?,?)",
                          (pid, secret, guid, host, now, now, self.client_ip()))
        log("агент", f"ПК {host} подключён к панели")
        return self.send(200, {"id": pid, "secret": secret})

    def a_report(self, pc):
        d = self.json_body()
        now = int(time.time())
        info = d.get("info") or {}
        sets, vals = ["last_seen=?", "ip=?", "info=?", "hostname=?"], [now, self.client_ip(), json.dumps(info, ensure_ascii=False), str(info.get("hostname", pc["hostname"]))[:80]]
        if d.get("programs") is not None:
            sets += ["programs=?", "programs_at=?"]
            vals += [json.dumps(d["programs"], ensure_ascii=False), now]
        rd_id = str(d.get("rd_id") or "")[:20] or (pc["rd_id"] if pc["rd_id"] else rd_id_from_hbbs(pc["guid"]))
        if rd_id and rd_id != pc["rd_id"]:
            sets.append("rd_id=?"); vals.append(rd_id)
        if d.get("rd_pass"):
            sets.append("rd_pass=?"); vals.append(str(d["rd_pass"])[:40])
        with LOCK, db() as c:
            c.execute(f"UPDATE pcs SET {', '.join(sets)} WHERE id=?", vals + [pc["id"]])
            rows = c.execute("SELECT id, kind, payload, title FROM tasks WHERE pc_id=? AND status='pending' ORDER BY id LIMIT 10", (pc["id"],)).fetchall()
            for r in rows:
                c.execute("UPDATE tasks SET status='sent', sent_at=? WHERE id=?", (now, r["id"]))
        tasks = [{"id": r["id"], "kind": r["kind"], "payload": r["payload"], "title": r["title"]} for r in rows]
        need_programs = d.get("programs") is None and (now - (pc["programs_at"] or 0)) > 6 * 3600
        return self.send(200, {"tasks": tasks, "need_programs": need_programs, "interval": 20, "agent_version": AGENT_VERSION})

    def a_result(self, pc):
        d = self.json_body()
        out = str(d.get("output", ""))[-64000:]
        status = "done" if d.get("ok") else "error"
        with LOCK, db() as c:
            c.execute("UPDATE tasks SET status=?, done_at=?, output=?, code=? WHERE id=? AND pc_id=?",
                      (status, int(time.time()), out, d.get("code"), int(d.get("id", 0)), pc["id"]))
            t = c.execute("SELECT kind, payload FROM tasks WHERE id=? AND pc_id=?", (int(d.get("id", 0)), pc["id"])).fetchone()
            drop_file_if_delivered(c, task_file_id(t))
        return self.send(200, {"ok": True})

    def send_file(self, path, name):
        if not os.path.isfile(path):
            return self.send(404, {"error": "файла нет"})
        size = os.path.getsize(path)
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(size))
        if name:
            self.send_header("Content-Disposition", f'attachment; filename="{name}"')
        self.end_headers()
        with open(path, "rb") as f:
            while True:
                b = f.read(1024 * 1024)
                if not b:
                    break
                self.wfile.write(b)

    # ------------------------------------------------------------------ вход администратора

    def login(self):
        ip = self.client_ip()
        n, t = FAILS.get(ip, (0, 0))
        if n >= 5 and time.time() - t < 600:
            return self.send(429, {"error": "Слишком много попыток. Подожди 10 минут."})
        d = self.json_body()
        has2fa = bool(CFG.get("totp"))
        ok = check_pw(str(d.get("password", "")), CFG["admin_hash"])
        if ok and has2fa:
            ok = totp_check(CFG["totp"], d.get("code"))
        if not ok:
            FAILS[ip] = (n + 1, time.time())
            log(ip, "неудачный вход в панель")
            time.sleep(1)
            return self.send(403, {"error": "Неверный пароль или код" if has2fa else "Неверный пароль"})
        FAILS.pop(ip, None)
        tok = secrets.token_urlsafe(32)
        SESSIONS[tok] = {"exp": time.time() + 12 * 3600, "full": has2fa}
        log(ip, "вход в панель" if has2fa else "вход по паролю — настройка кода из приложения")
        path = ("/" + CFG["admin_path"] + "/") if CFG.get("admin_path") else "/"
        return self.send(200, {"ok": True, "setup2fa": not has2fa},
                         headers={"Set-Cookie": f"oc={tok}; Path={path}; HttpOnly; Secure; SameSite=Strict; Max-Age=43200"})

    def api_2fa_setup(self, method, path, sess):
        """Первый вход: обязательная настройка кода из приложения (Яндекс Ключ / Google Authenticator)."""
        tok = self.session_token()
        if path == "/api/info":
            return self.send(200, {"setup2fa": True})
        if path == "/api/logout":
            SESSIONS.pop(tok, None)
            PENDING_TOTP.pop(tok, None)
            return self.send(200, {"ok": True})
        if path == "/api/2fa/new" and method == "POST":
            sec = base64.b32encode(secrets.token_bytes(20)).decode().rstrip("=")
            PENDING_TOTP[tok] = sec
            host = urllib.parse.quote(CFG.get("rd_host", "office"))
            uri = f"otpauth://totp/Office:{host}?secret={sec}&issuer=Office"
            return self.send(200, {"secret": sec, "svg": qr_svg(uri)})
        if path == "/api/2fa/confirm" and method == "POST":
            sec = PENDING_TOTP.get(tok)
            if not sec:
                raise ValueError("Сначала получи QR-код")
            if CFG.get("totp"):
                raise ValueError("Код уже настроен — войди заново")
            if not totp_check(sec, self.json_body().get("code")):
                raise ValueError("Код не подошёл — проверь время на телефоне и попробуй следующий")
            CFG["totp"] = sec
            save_cfg()
            PENDING_TOTP.pop(tok, None)
            sess["full"] = True
            log(self.client_ip(), "код из приложения настроен")
            return self.send(200, {"ok": True})
        return self.send(403, {"error": "Сначала настрой код из приложения"})

    # ------------------------------------------------------------------ API панели

    def api(self, method, path, q):
        now = int(time.time())
        if path == "/api/logout":
            ck = http.cookies.SimpleCookie(self.headers.get("Cookie", ""))
            if ck.get("oc"):
                SESSIONS.pop(ck["oc"].value, None)
            path = ("/" + CFG["admin_path"] + "/") if CFG.get("admin_path") else "/"
            return self.send(200, {"ok": True}, headers={"Set-Cookie": f"oc=; Path={path}; Max-Age=0"})

        if path == "/api/info":
            return self.send(200, {
                "version": VERSION, "panel": CFG["public_url"], "rd_host": CFG["rd_host"], "rd_key": read_rd_key(),
                "install": install_cmd(), "scripts": SCRIPTS,
            })

        if path == "/api/pcs":
            with db() as c:
                rows = c.execute("SELECT id, hostname, alias, grp, notes, last_seen, first_seen, ip, info, rd_id, rd_pass FROM pcs ORDER BY grp, alias, hostname").fetchall()
                pend = {r["pc_id"]: r["n"] for r in c.execute("SELECT pc_id, COUNT(*) n FROM tasks WHERE status IN ('pending','sent') GROUP BY pc_id")}
            out = []
            for r in rows:
                info = json.loads(r["info"] or "{}")
                out.append({**{k: r[k] for k in r.keys() if k != "info"}, "info": info,
                            "online": now - (r["last_seen"] or 0) < ONLINE_SEC, "pending": pend.get(r["id"], 0)})
            return self.send(200, out)

        m = re.match(r"^/api/pc/([0-9a-f]{16})$", path)
        if m:
            pid = m.group(1)
            with db() as c:
                if method == "DELETE":
                    c.execute("DELETE FROM pcs WHERE id=?", (pid,))
                    c.execute("DELETE FROM tasks WHERE pc_id=?", (pid,))
                    log("админ", f"ПК {pid} удалён из панели")
                    return self.send(200, {"ok": True})
                if method == "POST":
                    d = self.json_body()
                    c.execute("UPDATE pcs SET alias=?, grp=?, notes=? WHERE id=?",
                              (str(d.get("alias", ""))[:60], str(d.get("grp", ""))[:40], str(d.get("notes", ""))[:2000], pid))
                    return self.send(200, {"ok": True})
                r = c.execute("SELECT * FROM pcs WHERE id=?", (pid,)).fetchone()
                if not r:
                    return self.send(404, {"error": "нет такого ПК"})
                tasks = [dict(t) for t in c.execute("SELECT id, created, title, status, done_at, output, code FROM tasks WHERE pc_id=? ORDER BY id DESC LIMIT 60", (pid,))]
            d = {k: r[k] for k in r.keys() if k not in ("secret",)}
            d["info"] = json.loads(d["info"] or "{}")
            d["programs"] = json.loads(d["programs"] or "[]")
            d["online"] = now - (r["last_seen"] or 0) < ONLINE_SEC
            d["tasks"] = tasks
            return self.send(200, d)

        if path == "/api/run" and method == "POST":
            d = self.json_body()
            pcs = [p for p in d.get("pcs", []) if re.fullmatch(r"[0-9a-f]{16}", str(p))]
            if not pcs:
                raise ValueError("Не выбраны компьютеры")
            if d.get("script"):
                s = SCRIPT_BY_ID.get(d["script"])
                if not s:
                    raise ValueError("Нет такого действия")
                kind, title, payload = s["kind"], s["title"], build_payload(s, d.get("args") or {})
                if s.get("args"):
                    title += ": " + ", ".join(str((d.get("args") or {}).get(a["name"], "")) for a in s["args"])[:120]
            elif d.get("ps"):
                kind, title, payload = ("user" if d.get("as_user") else "ps"), "Своя команда: " + str(d["ps"]).strip().splitlines()[0][:80], str(d["ps"])
            elif d.get("file"):
                fid = str(d["file"])
                with db() as c:
                    f = c.execute("SELECT * FROM files WHERE id=?", (fid,)).fetchone()
                if not f:
                    raise ValueError("Файл не найден")
                dest = str(d.get("dest") or "C:\\Users\\Public\\Desktop").strip()
                kind, title = "file", f"Файл {f['name']} → {dest}"
                payload = json.dumps({"id": fid, "name": f["name"], "dest": dest, "run": bool(d.get("run")), "args": str(d.get("run_args") or "")})
            else:
                raise ValueError("Не выбрано действие")
            with LOCK, db() as c:
                for p in pcs:
                    c.execute("INSERT INTO tasks(pc_id, created, title, kind, payload) VALUES(?,?,?,?,?)", (p, now, title, kind, payload))
                names = [r["alias"] or r["hostname"] for r in c.execute(f"SELECT alias, hostname FROM pcs WHERE id IN ({','.join('?' * len(pcs))})", pcs)]
            log("админ", f"{title} → {', '.join(names)}")
            return self.send(200, {"ok": True, "count": len(pcs)})

        m = re.match(r"^/api/task/(\d+)$", path)
        if m:
            with db() as c:
                t = c.execute("SELECT * FROM tasks WHERE id=?", (int(m.group(1)),)).fetchone()
                if method == "DELETE" and t and t["status"] == "pending":
                    c.execute("DELETE FROM tasks WHERE id=?", (t["id"],))
                    drop_file_if_delivered(c, task_file_id(t))
                    return self.send(200, {"ok": True})
            return self.send(200, dict(t) if t else {})

        if path == "/api/upload" and method == "POST":
            n = int(self.headers.get("Content-Length") or 0)
            if n <= 0 or n > MAX_UPLOAD:
                raise ValueError("Файл пустой или больше 2 ГБ")
            name = urllib.parse.unquote(self.headers.get("X-Name", "file"))
            name = re.sub(r'[\\/:*?"<>|]+', "_", name)[:120] or "file"
            fid = secrets.token_hex(16)
            left = n
            with open(os.path.join(UPLOADS, fid), "wb") as f:
                while left:
                    b = self.rfile.read(min(left, 1024 * 1024))
                    if not b:
                        break
                    f.write(b)
                    left -= len(b)
            with db() as c:
                c.execute("INSERT INTO files(id, name, size, created) VALUES(?,?,?,?)", (fid, name, n, now))
            log("админ", f"загружен файл {name} ({n // 1024} КБ)")
            return self.send(200, {"id": fid, "name": name, "size": n})

        if path == "/api/files":
            with db() as c:
                return self.send(200, [dict(r) for r in c.execute("SELECT * FROM files ORDER BY created DESC LIMIT 100")])

        if path == "/api/log":
            with db() as c:
                return self.send(200, [dict(r) for r in c.execute("SELECT * FROM log ORDER BY id DESC LIMIT 300")])

        return self.send(404, {"error": "нет такого"})


def drop_file_if_delivered(c, fid):
    """Файл больше не нужен на сервере: все ПК, куда его отправили, его уже получили (или задания закрыты)."""
    if not re.fullmatch(r"[0-9a-f]{32}", fid or ""):
        return
    rows = c.execute("SELECT status FROM tasks WHERE kind='file' AND payload LIKE ?", (f'%"{fid}"%',)).fetchall()
    if not rows or any(r["status"] in ("pending", "sent") for r in rows):
        return
    f = c.execute("SELECT name FROM files WHERE id=?", (fid,)).fetchone()
    try:
        os.remove(os.path.join(UPLOADS, fid))
    except OSError:
        pass
    if f:
        c.execute("DELETE FROM files WHERE id=?", (fid,))
        # пишем журнал в той же транзакции (отдельное соединение упёрлось бы в блокировку базы)
        c.execute("INSERT INTO log(ts, who, text) VALUES(?,?,?)", (int(time.time()), "панель", f"файл {f['name']} доставлен и удалён с сервера"))


def task_file_id(t):
    try:
        return json.loads(t["payload"]).get("id") if t and t["kind"] == "file" else None
    except (ValueError, TypeError):
        return None


def rd_id_from_hbbs(guid):
    """ID RustDesk этого ПК — из базы нашего сервера RustDesk (hbbs): RustDesk регистрируется под MachineGuid Windows."""
    if not guid:
        return ""
    try:
        h = sqlite3.connect(f"file:{os.path.join(HOME, 'rustdesk', 'db_v2.sqlite3')}?mode=ro", uri=True, timeout=5)
        try:
            r = h.execute("SELECT id FROM peer WHERE uuid=? OR uuid=? ORDER BY created_at DESC LIMIT 1", (guid.encode(), guid)).fetchone()
        finally:
            h.close()
        return str(r[0]) if r and re.fullmatch(r"\d{6,12}", str(r[0])) else ""
    except sqlite3.Error:
        return ""


def read_rd_key():
    try:
        return open(os.path.join(HOME, "rustdesk", "id_ed25519.pub"), encoding="utf-8").read().strip()
    except OSError:
        return ""


def install_cmd():
    """Одна строка для окна PowerShell (от администратора) на ПК офиса. Сертификат панели сверяется по отпечатку."""
    url = f"{CFG['public_url']}/install.ps1?t={CFG['enroll_token']}"
    return ("[Net.ServicePointManager]::SecurityProtocol='Tls12'; "
            f"$t='{CFG['thumb']}'; "
            "[Net.ServicePointManager]::ServerCertificateValidationCallback={param($a,$c) $c.GetCertHashString() -eq $t}; "
            "$w=New-Object Net.WebClient; $w.Encoding=[Text.Encoding]::UTF8; "
            f"iex $w.DownloadString('{url}')")


def cleanup_loop():
    """Сессии, «зависшие» задания (отправлены, но ответа нет 2 часа) и старые журналы."""
    while True:
        time.sleep(600)
        now = time.time()
        for k in [k for k, v in SESSIONS.items() if v["exp"] < now]:
            SESSIONS.pop(k, None)
            PENDING_TOTP.pop(k, None)
        with db() as c:
            c.execute("UPDATE tasks SET status='error', output='нет ответа от ПК (выключен или перезагружен во время выполнения)' WHERE status='sent' AND sent_at < ?", (int(now) - 7200,))
            c.execute("DELETE FROM log WHERE ts < ?", (int(now) - 90 * 86400,))
            for f in c.execute("SELECT id, created FROM files").fetchall():
                if c.execute("SELECT 1 FROM tasks WHERE kind='file' AND payload LIKE ? LIMIT 1", (f'%"{f["id"]}"%',)).fetchone():
                    drop_file_if_delivered(c, f["id"])
                elif (f["created"] or 0) < now - 86400:   # загружен, но так никуда и не отправлен
                    try:
                        os.remove(os.path.join(UPLOADS, f["id"]))
                    except OSError:
                        pass
                    c.execute("DELETE FROM files WHERE id=?", (f["id"],))


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        # обрывы соединений и ошибки TLS от браузера (недоверенный сертификат и т.п.) — не ошибка панели
        e = sys.exc_info()[1]
        if isinstance(e, (ssl.SSLError, ConnectionError, TimeoutError, OSError)):
            return
        super().handle_error(request, client_address)


def main():
    init_db()
    srv = Server(("0.0.0.0", int(CFG["port"])), H)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(os.path.join(HOME, "cert.pem"), os.path.join(HOME, "key.pem"))
    # рукопожатие TLS — в потоке запроса, а не в общем приёме соединений
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True, do_handshake_on_connect=False)
    threading.Thread(target=cleanup_loop, daemon=True).start()
    print(f"Панель офиса {VERSION}: {CFG['public_url']}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
