import re, sqlite3, sys
c = sqlite3.connect("/opt/office/office.db"); c.row_factory = sqlite3.Row
r = c.execute("SELECT id, title, status, output FROM tasks WHERE title LIKE 'Диагностика%' ORDER BY id DESC LIMIT 1").fetchone()
print(r["id"], r["status"])
out = re.sub(r"\b\d{7,}\b", "#######", r["output"] or "")
print(re.sub(r"[A-Za-z0-9+/=_-]{14,}", lambda m: m.group(0) if re.search(r"Program|ServiceProfiles|AppData|Roaming|rustdesk|RustDesk", m.group(0)) else "<скрыто>", out))
