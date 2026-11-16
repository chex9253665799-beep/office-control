#!/usr/bin/env bash
# Установка / обновление «Панели офиса» на сервер (Ubuntu/Debian). Запуск от root:
#   curl -fsSL https://raw.githubusercontent.com/chex9253665799-beep/office-control/main/server/install.sh | bash
# Ставит всё в /opt/office отдельными службами (office-panel, office-hbbs, office-hbbr) — другие программы на сервере не трогает.
# Повторный запуск = обновление: пароль, ключи и список ПК сохраняются.
set -euo pipefail

REPO="chex9253665799-beep/office-control"
RD_SERVER_VER="1.1.16"
RD_CLIENT_VER="1.5.3"
HOME_DIR="/opt/office"
APP="$HOME_DIR/app"
PANEL_PORT="${OFFICE_PORT:-8443}"

say() { printf '\033[1;36m%s\033[0m\n' "$*"; }
die() { printf '\033[1;31m%s\033[0m\n' "$*"; exit 1; }

[ "$(id -u)" = 0 ] || die "Запусти от root (sudo -i)."

say "1/7  Пакеты"
# ставим только то, чего нет, — уже установленное не обновляем (чтобы не задеть другие программы на сервере)
NEED=""
for p in python3 openssl unzip curl; do command -v "$p" >/dev/null || NEED="$NEED $p"; done
if [ -n "$NEED" ] && command -v apt-get >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null
  apt-get install -y -qq --no-upgrade $NEED ca-certificates >/dev/null
fi
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,7) else 1)' || die "Нужен Python 3.7 или новее."

say "2/7  Программа панели"
id office >/dev/null 2>&1 || useradd --system --home "$HOME_DIR" --shell /usr/sbin/nologin office
mkdir -p "$HOME_DIR/rustdesk" "$HOME_DIR/files/up" "$APP"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -n "$SRC" ] && [ -f "$SRC/panel.py" ]; then
  cp -r "$SRC/panel.py" "$SRC/web" "$SRC/agent" "$APP/"
else
  TMP=$(mktemp -d)
  curl -fsSL "https://github.com/$REPO/archive/refs/heads/main.tar.gz" | tar xz -C "$TMP"
  cp -r "$TMP"/*/server/panel.py "$TMP"/*/server/web "$TMP"/*/server/agent "$APP/"
  cp "$TMP"/*/server/install.sh /usr/local/sbin/office-update && chmod +x /usr/local/sbin/office-update
  rm -rf "$TMP"
fi

# адрес сервера, по которому к нему подключаются ПК офиса
HOST="${OFFICE_HOST:-}"
if [ -z "$HOST" ] && [ -f "$HOME_DIR/config.json" ]; then
  HOST=$(python3 -c "import json;print(json.load(open('$HOME_DIR/config.json'))['rd_host'])")
fi
[ -n "$HOST" ] || HOST=$(curl -fsS4 --max-time 10 https://api.ipify.org || curl -fsS4 --max-time 10 https://ifconfig.me || true)
[ -n "$HOST" ] || die "Не определил внешний IP. Запусти так: OFFICE_HOST=1.2.3.4 bash install.sh"

say "3/7  Сервер RustDesk (свой, без лимитов)"
case "$(uname -m)" in
  x86_64) RDA=amd64 ;; aarch64) RDA=arm64v8 ;; armv7l) RDA=armv7 ;; *) die "Процессор $(uname -m) не поддерживается" ;;
esac
if [ ! -x "$HOME_DIR/rustdesk/hbbs" ] || [ "$(cat "$HOME_DIR/rustdesk/.ver" 2>/dev/null)" != "$RD_SERVER_VER" ]; then
  TMP=$(mktemp -d)
  curl -fsSL -o "$TMP/s.zip" "https://github.com/rustdesk/rustdesk-server/releases/download/$RD_SERVER_VER/rustdesk-server-linux-$RDA.zip"
  unzip -q -o "$TMP/s.zip" -d "$TMP"
  install -m 755 "$(find "$TMP" -name hbbs -type f | head -1)" "$HOME_DIR/rustdesk/hbbs"
  install -m 755 "$(find "$TMP" -name hbbr -type f | head -1)" "$HOME_DIR/rustdesk/hbbr"
  echo "$RD_SERVER_VER" > "$HOME_DIR/rustdesk/.ver"
  rm -rf "$TMP"
fi
if [ ! -s "$HOME_DIR/files/rustdesk.exe" ] || [ "$(cat "$HOME_DIR/files/.client" 2>/dev/null)" != "$RD_CLIENT_VER" ]; then
  say "     клиент RustDesk $RD_CLIENT_VER для ПК офиса"
  curl -fsSL -o "$HOME_DIR/files/rustdesk.exe" "https://github.com/rustdesk/rustdesk/releases/download/$RD_CLIENT_VER/rustdesk-$RD_CLIENT_VER-x86_64.exe"
  echo "$RD_CLIENT_VER" > "$HOME_DIR/files/.client"
fi

say "4/7  Сертификат и настройки"
if [ ! -f "$HOME_DIR/cert.pem" ]; then
  if [[ "$HOST" =~ ^[0-9.]+$ ]]; then SAN="IP:$HOST"; else SAN="DNS:$HOST"; fi
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=office-panel" -addext "subjectAltName=$SAN" \
    -keyout "$HOME_DIR/key.pem" -out "$HOME_DIR/cert.pem" 2>/dev/null
fi
THUMB=$(openssl x509 -in "$HOME_DIR/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')
NEWPASS=""
SHOWPASS=1
if [ -n "${OFFICE_PASS:-}" ]; then
  NEWPASS="$OFFICE_PASS"; SHOWPASS=0          # пароль задан снаружи (секрет) — не печатаем
elif [ ! -f "$HOME_DIR/config.json" ]; then
  NEWPASS=$(tr -dc 'A-HJ-NP-Za-km-z2-9' </dev/urandom | head -c 14)
fi
NEWPASS="$NEWPASS" HOST="$HOST" PORT="$PANEL_PORT" THUMB="$THUMB" CFG="$HOME_DIR/config.json" python3 - <<'PY'
import json, os, secrets, hashlib
p = os.environ["CFG"]
c = json.load(open(p)) if os.path.exists(p) else {}
c.setdefault("port", int(os.environ["PORT"]))
c["rd_host"] = os.environ["HOST"]
c["public_url"] = f"https://{os.environ['HOST']}:{c['port']}"
c["thumb"] = os.environ["THUMB"]
c.setdefault("enroll_token", secrets.token_urlsafe(24))
if os.environ.get("NEWPASS"):
    salt = secrets.token_hex(16)
    c["admin_hash"] = salt + "$" + hashlib.pbkdf2_hmac("sha256", os.environ["NEWPASS"].encode(), salt.encode(), 200_000).hex()
json.dump(c, open(p, "w"), indent=2)
PY
PANEL_PORT=$(python3 -c "import json;print(json.load(open('$HOME_DIR/config.json'))['port'])")
# смена пароля администратора: office-passwd
cat > /usr/local/sbin/office-passwd <<EOF
#!/usr/bin/env bash
read -rsp "Новый пароль панели: " P; echo
P="\$P" python3 - <<'PY'
import json, os, secrets, hashlib
p = "$HOME_DIR/config.json"; c = json.load(open(p)); salt = secrets.token_hex(16)
c["admin_hash"] = salt + "\$" + hashlib.pbkdf2_hmac("sha256", os.environ["P"].encode(), salt.encode(), 200_000).hex()
json.dump(c, open(p, "w"), indent=2)
PY
systemctl restart office-panel && echo "Пароль изменён."
EOF
chmod 700 /usr/local/sbin/office-passwd
chown -R office:office "$HOME_DIR"
chmod 600 "$HOME_DIR/config.json" "$HOME_DIR/key.pem"

say "5/7  Службы"
cat > /etc/systemd/system/office-hbbs.service <<EOF
[Unit]
Description=Office: RustDesk ID server
After=network-online.target
[Service]
User=office
WorkingDirectory=$HOME_DIR/rustdesk
ExecStart=$HOME_DIR/rustdesk/hbbs -r $HOST:21117 -k _
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
cat > /etc/systemd/system/office-hbbr.service <<EOF
[Unit]
Description=Office: RustDesk relay
After=network-online.target
[Service]
User=office
WorkingDirectory=$HOME_DIR/rustdesk
ExecStart=$HOME_DIR/rustdesk/hbbr -k _
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
cat > /etc/systemd/system/office-panel.service <<EOF
[Unit]
Description=Office: control panel
After=network-online.target office-hbbs.service
[Service]
User=office
ExecStart=/usr/bin/env python3 $APP/panel.py $HOME_DIR/config.json
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable -q office-hbbs office-hbbr office-panel
systemctl restart office-hbbs office-hbbr office-panel

say "6/7  Брандмауэр"
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow 21115:21117/tcp >/dev/null; ufw allow 21116/udp >/dev/null; ufw allow "$PANEL_PORT/tcp" >/dev/null
  echo "     ufw: порты открыты"
elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd -q --permanent --add-port=21115-21117/tcp --add-port=21116/udp --add-port="$PANEL_PORT/tcp"; firewall-cmd -q --reload
  echo "     firewalld: порты открыты"
else
  echo "     брандмауэр на сервере не включён — ничего не меняю"
fi

say "7/7  Проверка"
for i in $(seq 1 20); do [ -s "$HOME_DIR/rustdesk/id_ed25519.pub" ] && break; sleep 1; done
sleep 2
for s in office-hbbs office-hbbr office-panel; do
  systemctl is-active -q "$s" && echo "     ✔ $s работает" || { echo "     ✖ $s не запустился:"; journalctl -u "$s" -n 15 --no-pager; }
done

echo
say "═══════════════════════════════════════════════════════════"
say " Панель офиса:  https://$HOST:$PANEL_PORT"
if [ -n "$NEWPASS" ] && [ "$SHOWPASS" = 0 ]; then
  echo " Пароль: тот, что задан в секрете PANEL_PASS"
elif [ -n "$NEWPASS" ]; then
  say " Пароль:        $NEWPASS"
  echo " (сохрани его; сменить: office-passwd)"
else
  echo " Пароль прежний (сменить: office-passwd)"
fi
echo " Браузер предупредит о сертификате — это свой сертификат панели, нажми «Дополнительно → Перейти»."
echo " Если у хостинга есть свой брандмауэр в личном кабинете — открой там порты:"
echo "   TCP 21115-21117, UDP 21116, TCP $PANEL_PORT"
say "═══════════════════════════════════════════════════════════"
