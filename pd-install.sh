#!/usr/bin/env bash
# PublicDROP installer v3 (login + admin users + installable app)
#   * uses the publicdrop.in.zip that sits NEXT TO this file (or PD_ZIP=/path/to.zip, or downloads it from $PD_RAW)
#   * checks the new files BEFORE touching anything
#   * backs up the current site to /root/pd-backups
#   * swaps the new site in, tests it, and AUTOMATICALLY ROLLS BACK if the test fails
#   * installs / upgrades the backend (admin panel, users, maintenance, popup, push, stats)
# Run:   sudo bash pd-install.sh
# Optional (shows EVERY registered user in the admin panel, even before they revisit):
#        sudo PD_SUPABASE_SERVICE_KEY='your-secret-service-role-key' bash pd-install.sh
set -euo pipefail

RAW="${PD_RAW:-https://raw.githubusercontent.com/IndiTech13/PublicFLIX/main}"
SB_URL="https://zmfiavshwwgayrymnjia.supabase.co"
SELF="${BASH_SOURCE[0]:-$0}"
SELF_DIR="$(cd "$(dirname "$SELF")" 2>/dev/null && pwd || pwd)"
WEBUSER="nginx"; id nginx >/dev/null 2>&1 || WEBUSER="www-data"
WEB=/usr/share/nginx/html
APP=/opt/publicdrop-pd
DATA=/var/lib/publicdrop-pd
ENVF=/etc/publicdrop-pd.env
BK=/root/pd-backups
DOMAIN="publicdrop.in"
DEFAULT_HASH='pbkdf2_sha256:200000:79a762634356fee37019955927191dec:18c18497d8ae656ad7246010a7621457b20fc57b9ef5b8f4e7ef33a87d2c32ec'

[ "$(id -u)" -eq 0 ] || { echo "Please run with sudo (see the command in the instructions)."; exit 1; }

say() { echo; echo "==> $*"; }

# Fetch a URL on this server (follows http->https redirects, ignores cert name) and print the status code.
code() { curl -ksSL --max-time 12 -o /dev/null -w '%{http_code}' \
  --resolve "$DOMAIN:80:127.0.0.1" --resolve "$DOMAIN:443:127.0.0.1" "http://$DOMAIN$1" 2>/dev/null || echo 000; }

site_ok() { [ "$(code /)" = 200 ] && [ "$(code /js/app.js)" = 200 ] && [ "$(code /admin/)" = 200 ] && [ "$(code /js/pd-track.js)" = 200 ] && [ "$(code /manifest.json)" = 200 ] && [ "$(code /sw.js)" = 200 ] && [ "$(code /js/pwa.js)" = 200 ]; }

say "[1/6] Finding and checking the new website files"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
ZIP=""
for cand in "${PD_ZIP:-}" "$SELF_DIR/publicdrop.in.zip" "$PWD/publicdrop.in.zip" "$SELF_DIR/publicdrop_in.zip" "$PWD/publicdrop_in.zip"; do
  if [ -n "$cand" ] && [ -s "$cand" ]; then ZIP="$cand"; break; fi
done
if [ -z "$ZIP" ]; then
  for cand in "$SELF_DIR"/publicdrop*.zip "$PWD"/publicdrop*.zip "$SELF_DIR"/PublicDROP*.zip; do
    if [ -s "$cand" ]; then ZIP="$cand"; break; fi
  done
fi
if [ -z "$ZIP" ]; then
  echo "No local zip found next to this script, trying to download it from $RAW ..."
  curl -fsSL "$RAW/publicdrop.in.zip" -o "$TMP/pd.zip" || { echo "ERROR: put publicdrop.in.zip in the same folder as pd-install.sh and run again. Nothing was changed."; exit 1; }
  ZIP="$TMP/pd.zip"
fi
echo "Using: $ZIP"
if command -v dnf >/dev/null 2>&1; then dnf install -y unzip python3 python3-pip >/dev/null 2>&1 || true
elif command -v apt-get >/dev/null 2>&1; then apt-get install -y unzip python3 python3-pip >/dev/null 2>&1 || true; fi
command -v unzip >/dev/null 2>&1 || { echo "ERROR: 'unzip' is not installed and could not be installed. Nothing was changed."; exit 1; }
unzip -oq "$ZIP" -d "$TMP/pd" || { echo "ERROR: the zip could not be opened. Nothing was changed."; exit 1; }
SRC="$TMP/pd/publicdrop.in"
[ -d "$SRC" ] || { echo "ERROR: the zip must contain a folder called publicdrop.in. Nothing was changed."; exit 1; }
for f in index.html js/app.js js/config.js js/auth.js js/player.js js/pd-track.js js/pwa.js js/account.js assets/avatars/a1.svg assets/avatars/a8.svg sw.js manifest.json manifest.webmanifest offline.html admin/index.html assets/publicdrop-favicon.png assets/icon-192.png assets/icon-512.png assets/icon-maskable-192.png assets/icon-maskable-512.png assets/apple-touch-icon.png; do
  [ -s "$SRC/$f" ] || { echo "ERROR: the zip is missing $f. Nothing was changed."; exit 1; }
done
grep -q 'pd-track.js' "$SRC/index.html" || { echo "ERROR: index.html does not load pd-track.js. Nothing was changed."; exit 1; }
grep -q 'G-PLCGW0JZWK' "$SRC/index.html" || { echo "ERROR: index.html has no Google Analytics tag (wrong zip?). Nothing was changed."; exit 1; }
grep -q 'admin/health' "$SRC/admin/index.html" || { echo "ERROR: admin/index.html is the OLD one. Nothing was changed."; exit 1; }
grep -q 'account.js' "$SRC/index.html" || { echo "ERROR: index.html does not load account.js. Nothing was changed."; exit 1; }
grep -q 'zmfiavshwwgayrymnjia' "$SRC/js/config.js" || { echo "ERROR: config.js does not point at the new Supabase project. Nothing was changed."; exit 1; }
if grep -q 'coming-soon-script' "$SRC/index.html"; then echo "ERROR: index.html still contains the login blocker. Nothing was changed."; exit 1; fi

say "[2/6] Backing up the current site"
mkdir -p "$BK"
if [ -d "$WEB" ] && [ -n "$(ls -A "$WEB" 2>/dev/null)" ]; then
  tar czf "$BK/site-$(date +%Y%m%d-%H%M%S).tar.gz" -C "$(dirname "$WEB")" "$(basename "$WEB")"
  ls -1t "$BK"/site-*.tar.gz 2>/dev/null | tail -n +6 | xargs -r rm -f
  echo "Backup saved in $BK (last 5 are kept)."
fi

say "[3/6] Replacing old files with the new site"
systemctl enable --now nginx >/dev/null 2>&1 || true
rm -rf "$WEB.new" "$WEB.old"
mkdir -p "$WEB.new"
cp -r "$SRC/." "$WEB.new/"
chown -R "$WEBUSER:$WEBUSER" "$WEB.new" 2>/dev/null || chown -R "$WEBUSER" "$WEB.new" 2>/dev/null || true
chmod -R a+rX "$WEB.new"
restorecon -R "$WEB.new" 2>/dev/null || true
[ -d "$WEB" ] && mv "$WEB" "$WEB.old"
mv "$WEB.new" "$WEB"
sleep 1
if site_ok; then
  echo "New site is live and passed the check."
  rm -rf "$WEB.old"
else
  echo "!! The new site failed the check. Rolling back to the old files..."
  rm -rf "$WEB"
  [ -d "$WEB.old" ] && mv "$WEB.old" "$WEB"
  systemctl reload nginx 2>/dev/null || true
  echo "Rolled back. Your old site is back exactly as it was. Send me this output."
  echo "Codes: / =$(code /)  app.js=$(code /js/app.js)  admin=$(code /admin/)  pd-track=$(code /js/pd-track.js)"
  exit 1
fi

say "[4/6] Installing the push library"
mkdir -p "$APP/lib" "$DATA"
python3 -m pip install --quiet --upgrade --target "$APP/lib" pywebpush || echo "WARNING: push-notification library could not be installed. Everything else will still work."

say "[5/6] Installing the backend (admin panel, maintenance, popup, stats, push)"
cat > "$APP/server.py" <<'PYEOF'
#!/usr/bin/env python3
"""PublicDROP backend: visitor stats, admin panel API, maintenance + popup settings, web push.

Standard library only, plus `pywebpush` for sending push notifications.
Listens on 127.0.0.1 and is reached through nginx at /pd-api/. No IP addresses are stored.
Everything the website does with this server is fail-open: if it is down, the site works normally.
"""
import base64
import hashlib
import hmac
import json
import os
import re
import shutil
import socket
import sqlite3
import ssl
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PD_PORT", "8787"))
DATA = os.environ.get("PD_DATA", "/var/lib/publicdrop-pd")
INIT_HASH = os.environ.get("PD_ADMIN_INIT_HASH", "")
VAPID_SUB = os.environ.get("PD_VAPID_SUB", "mailto:admin@publicdrop.in")
SITE_DOMAIN = os.environ.get("PD_DOMAIN", "publicdrop.in")
STARTED = time.time()
LIVE_WINDOW = 90          # seconds without a heartbeat before a visitor is "gone"
TZ_OFFSET = 19800         # IST (UTC+5:30) for "today"
KEEP_SESSIONS_DAYS = 45   # raw sessions are pruned; daily totals are kept forever
SESSION_DAYS = 30         # admin login lifetime
PBKDF2_ITERS = 200000

BOT_RE = re.compile(r"bot|crawl|spider|slurp|headless|lighthouse|preview|monitor|curl|wget", re.I)
ID_RE = re.compile(r"^[A-Za-z0-9_-]{8,40}$")
EMAIL_RE = re.compile(r"^[^@\s]{1,64}@[^@\s]{1,120}$")
WATCH_RE = re.compile(r"^#/watch/([a-z]{2,10})/([A-Za-z0-9_-]{1,40})")
CTRL_RE = re.compile(r"[\x00-\x1f\x7f]")
CTRL_ML_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")

DEFAULT_MAINT = {
    "on": False,
    "title": "We'll be right back",
    "message": "PublicDROP is under maintenance right now. Please check back in a little while.",
    "eta": "",
}
DEFAULT_POPUP = {
    "on": False, "id": 0, "title": "", "body": "", "image": "",
    "btn": "", "url": "", "show": "once", "delay": 3,
}

os.makedirs(DATA, exist_ok=True)
LOCK = threading.Lock()
DB = sqlite3.connect(os.path.join(DATA, "pd.db"), check_same_thread=False)
DB.execute("PRAGMA journal_mode=WAL")
DB.execute("PRAGMA synchronous=NORMAL")
DB.executescript(
    """
    CREATE TABLE IF NOT EXISTS sessions(
      sid TEXT PRIMARY KEY, vid TEXT, first_seen INTEGER, last_seen INTEGER,
      path TEXT, email TEXT DEFAULT '', name TEXT DEFAULT '', device TEXT DEFAULT 'desktop');
    CREATE INDEX IF NOT EXISTS ix_sessions_last ON sessions(last_seen);
    CREATE INDEX IF NOT EXISTS ix_sessions_first ON sessions(first_seen);
    CREATE TABLE IF NOT EXISTS visitors(vid TEXT PRIMARY KEY, first_seen INTEGER);
    CREATE TABLE IF NOT EXISTS daily(day INTEGER PRIMARY KEY, visits INTEGER DEFAULT 0, pv INTEGER DEFAULT 0);
    CREATE TABLE IF NOT EXISTS users(
      email TEXT PRIMARY KEY, name TEXT DEFAULT '', first_seen INTEGER, last_seen INTEGER, visits INTEGER DEFAULT 0);
    CREATE TABLE IF NOT EXISTS subs(
      endpoint TEXT PRIMARY KEY, data TEXT, email TEXT DEFAULT '', created INTEGER);
    CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT);
    CREATE TABLE IF NOT EXISTS titles(key TEXT PRIMARY KEY, kind TEXT, id TEXT, views INTEGER DEFAULT 0, last_seen INTEGER);
    CREATE TABLE IF NOT EXISTS viewed(sid TEXT, key TEXT, PRIMARY KEY(sid,key));
    CREATE TABLE IF NOT EXISTS notifs(
      id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT, body TEXT, url TEXT, ts INTEGER,
      total INTEGER DEFAULT 0, sent INTEGER DEFAULT 0, failed INTEGER DEFAULT 0, done INTEGER DEFAULT 0, test INTEGER DEFAULT 0);
    """
)
DB.commit()


class Bad(Exception):
    """A validation problem whose message is safe to show to the admin."""


# ---------------------------------------------------------------- settings + passwords
def sget(key, default=None):
    row = DB.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
    return json.loads(row[0]) if row else default


def sset(key, value):
    DB.execute(
        "INSERT INTO settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        (key, json.dumps(value)),
    )


def pw_hash(password, salt=None):
    salt = salt or os.urandom(16).hex()
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(salt), PBKDF2_ITERS).hex()
    return "pbkdf2_sha256:%d:%s:%s" % (PBKDF2_ITERS, salt, digest)


def pw_check(password, stored):
    try:
        _, iters, salt, digest = stored.split(":")
        calc = hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(salt), int(iters)).hex()
        return hmac.compare_digest(calc, digest)
    except Exception:
        return False


def make_token(secret):
    exp = int(time.time()) + SESSION_DAYS * 86400
    sig = hmac.new(bytes.fromhex(secret), str(exp).encode(), hashlib.sha256).hexdigest()
    return "%d.%s" % (exp, sig), exp


def token_ok(token, secret):
    try:
        exp_s, sig = token.split(".", 1)
        if int(exp_s) < time.time():
            return False
        good = hmac.new(bytes.fromhex(secret), exp_s.encode(), hashlib.sha256).hexdigest()
        return hmac.compare_digest(sig, good)
    except Exception:
        return False


CFG = {}  # public config served at /pd-api/config (rebuilt on every save)


def rebuild_cfg():
    m, p = sget("maintenance", DEFAULT_MAINT), sget("popup", DEFAULT_POPUP)
    CFG.clear()
    CFG.update({
        "m": {"on": bool(m["on"]), "title": m["title"], "message": m["message"], "eta": m["eta"]},
        "p": {k: p[k] for k in ("on", "id", "title", "body", "image", "btn", "url", "show", "delay")},
    })


with LOCK:
    if sget("secret") is None:
        sset("secret", os.urandom(32).hex())
    if sget("admin_hash") is None and INIT_HASH:
        sset("admin_hash", INIT_HASH)
    if sget("maintenance") is None:
        sset("maintenance", DEFAULT_MAINT)
    if sget("popup") is None:
        sset("popup", DEFAULT_POPUP)
    DB.commit()
    rebuild_cfg()

if len(sys.argv) >= 3 and sys.argv[1] == "reset-password":
    if len(sys.argv[2]) < 8:
        sys.exit("Password must be at least 8 characters.")
    with LOCK:
        sset("admin_hash", pw_hash(sys.argv[2]))
        sset("secret", os.urandom(32).hex())
        DB.commit()
    print("Admin password changed. All admin sessions were logged out.")
    sys.exit(0)


# ---------------------------------------------------------------- VAPID keys
def load_vapid():
    pem = os.path.join(DATA, "vapid_private.pem")
    from cryptography.hazmat.primitives import serialization as ser
    from cryptography.hazmat.primitives.asymmetric import ec

    if not os.path.exists(pem):
        key = ec.generate_private_key(ec.SECP256R1())
        data = key.private_bytes(ser.Encoding.PEM, ser.PrivateFormat.PKCS8, ser.NoEncryption())
        fd = os.open(pem, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
    with open(pem, "rb") as fh:
        key = ser.load_pem_private_key(fh.read(), None)
    raw = key.public_key().public_bytes(ser.Encoding.X962, ser.PublicFormat.UncompressedPoint)
    return pem, base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


VAPID_PEM, VAPID_PUBLIC = load_vapid()
try:
    import pywebpush  # noqa: F401

    PUSH_READY = True
except Exception:  # pragma: no cover
    PUSH_READY = False


# ---------------------------------------------------------------- helpers
_rate = {}
_fails = {}
_rate_lock = threading.Lock()


def rate_ok(ip, bucket, limit, window):
    now = time.time()
    key = (ip, bucket)
    with _rate_lock:
        start, count = _rate.get(key, (now, 0))
        if now - start > window:
            start, count = now, 0
        count += 1
        _rate[key] = (start, count)
        if len(_rate) > 20000:
            for k in [k for k, v in _rate.items() if now - v[0] > 600]:
                _rate.pop(k, None)
        return count <= limit


def blocked(ip):
    now = time.time()
    with _rate_lock:
        recent = [t for t in _fails.get(ip, []) if now - t < 600]
        _fails[ip] = recent
        return len(recent) >= 8


def record_fail(ip):
    with _rate_lock:
        _fails.setdefault(ip, []).append(time.time())
        if len(_fails) > 5000:
            _fails.clear()


def clean(value, n):
    return CTRL_RE.sub("", str(value or ""))[:n].strip()


def clean_ml(value, n):
    return CTRL_ML_RE.sub("", str(value or "").replace("\r\n", "\n"))[:n].strip()


def day_of(ts):
    return (ts + TZ_OFFSET) // 86400


def bump_daily(day, visits=0, pv=0):
    DB.execute("INSERT OR IGNORE INTO daily(day,visits,pv) VALUES(?,0,0)", (day,))
    DB.execute("UPDATE daily SET visits=visits+?, pv=pv+? WHERE day=?", (visits, pv, day))


def prune_loop():
    while True:
        time.sleep(3600)
        try:
            with LOCK:
                DB.execute("DELETE FROM sessions WHERE first_seen < ?", (int(time.time()) - KEEP_SESSIONS_DAYS * 86400,))
                DB.execute("DELETE FROM viewed WHERE sid NOT IN (SELECT sid FROM sessions)")
                DB.commit()
        except Exception as exc:  # pragma: no cover
            print("prune error", exc, file=sys.stderr)


def ok_link(url, allow_relative=True):
    if not url:
        return True
    if CTRL_RE.search(url) or len(url) > 300:
        return False
    if allow_relative and ((url.startswith("/") and not url.startswith("//")) or url.startswith("#")):
        return True
    return bool(re.match(r"^https?://[^\s]+$", url))


def norm_maint(d):
    title = clean(d.get("title"), 80) or DEFAULT_MAINT["title"]
    message = clean_ml(d.get("message"), 600) or DEFAULT_MAINT["message"]
    return {"on": bool(d.get("on")), "title": title, "message": message, "eta": clean(d.get("eta"), 60)}


def norm_popup(d, old):
    show = d.get("show") if d.get("show") in ("once", "daily", "visit") else "once"
    try:
        delay = max(0, min(30, int(d.get("delay", 3))))
    except (TypeError, ValueError):
        delay = 3
    p = {
        "on": bool(d.get("on")),
        "title": clean(d.get("title"), 80),
        "body": clean_ml(d.get("body"), 600),
        "image": clean(d.get("image"), 400),
        "btn": clean(d.get("btn"), 30),
        "url": clean(d.get("url"), 300),
        "show": show,
        "delay": delay,
    }
    if p["on"] and not (p["title"] or p["body"]):
        raise Bad("The popup needs a title or a message.")
    if p["image"] and not p["image"].startswith("https://"):
        raise Bad("Image link must start with https://")
    if not ok_link(p["url"]):
        raise Bad("Button link must start with /, #, http:// or https://")
    if p["btn"] and not p["url"]:
        raise Bad("Add a button link, or clear the button text.")
    content = lambda x: (x["title"], x["body"], x["image"], x["btn"], x["url"], x["show"])  # noqa: E731
    changed = content(p) != content(old)
    p["id"] = int(time.time()) if (p["on"] and (not old["on"] or changed)) else old.get("id", 0)
    return p


# ---------------------------------------------------------------- push sending
def push_one(args):
    from pywebpush import WebPushException, webpush

    sub, payload = args
    try:
        webpush(subscription_info=sub, data=payload, vapid_private_key=VAPID_PEM,
                vapid_claims={"sub": VAPID_SUB}, ttl=86400, timeout=10)
        return "ok"
    except WebPushException as exc:
        code = getattr(getattr(exc, "response", None), "status_code", 0)
        return "gone" if code in (404, 410) else "fail"
    except Exception:
        return "fail"


def run_broadcast(nid, rows, payload):
    sent = failed = 0
    gone = []
    try:
        with ThreadPoolExecutor(max_workers=12) as pool:
            results = list(pool.map(push_one, [(json.loads(r[1]), payload) for r in rows]))
        for (endpoint, _), res in zip(rows, results):
            if res == "ok":
                sent += 1
            else:
                failed += 1
                if res == "gone":
                    gone.append(endpoint)
    finally:
        with LOCK:
            for endpoint in gone:
                DB.execute("DELETE FROM subs WHERE endpoint=?", (endpoint,))
            DB.execute("UPDATE notifs SET sent=?, failed=?, done=1 WHERE id=?", (sent, failed, nid))
            DB.commit()


# ---------------------------------------------------------------- server health (admin only, on demand)
# Nothing here runs by itself. It only runs when a logged-in admin panel asks for it.
_health_lock = threading.Lock()
_cpu_prev = [None]
_deps = {"ts": 0.0, "busy": False, "items": []}
DEPS = [
    ("TMDB catalog", "https://api.themoviedb.org/3/"),
    ("Vumeto player", "https://vumeto.xyz/"),
    ("Vidstuck player", "https://vidstuck.cc/"),
    ("Supabase login", "https://gdpfxkobhyhwbhpaiuqr.supabase.co/auth/v1/health"),
]


def _read(path):
    with open(path) as fh:
        return fh.read()


def _cpu_sample():
    vals = [int(x) for x in _read("/proc/stat").splitlines()[0].split()[1:]]
    return vals[3] + (vals[4] if len(vals) > 4 else 0), sum(vals)


def cpu_percent():
    with _health_lock:
        prev = _cpu_prev[0]
        if prev is None:
            prev = _cpu_sample()
            time.sleep(0.25)
        cur = _cpu_sample()
        _cpu_prev[0] = cur
    total = cur[1] - prev[1]
    if total <= 0:
        return None
    return round(max(0.0, min(100.0, 100.0 * (1 - (cur[0] - prev[0]) / total))), 1)


def mem_info():
    m = {}
    for line in _read("/proc/meminfo").splitlines():
        k, _, v = line.partition(":")
        m[k] = int(v.split()[0]) * 1024
    total, avail = m.get("MemTotal", 0), m.get("MemAvailable", 0)
    return {"total": total, "used": max(0, total - avail),
            "swap_total": m.get("SwapTotal", 0), "swap_used": max(0, m.get("SwapTotal", 0) - m.get("SwapFree", 0))}


def proc_rss():
    for line in _read("/proc/self/status").splitlines():
        if line.startswith("VmRSS:"):
            return int(line.split()[1]) * 1024
    return 0


def local_get(path):
    """GET a page from nginx on this same machine (HTTPS first, then HTTP) and time the first reply."""
    tried = []
    for scheme, port in (("https", 443), ("http", 80)):
        t0 = time.perf_counter()
        try:
            sock = socket.create_connection(("127.0.0.1", port), timeout=3)
            if scheme == "https":
                ctx = ssl.create_default_context()
                ctx.check_hostname = False
                ctx.verify_mode = ssl.CERT_NONE
                sock = ctx.wrap_socket(sock, server_hostname=SITE_DOMAIN)
            sock.settimeout(3)
            sock.sendall(("GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: pd-health\r\nAccept-Encoding: identity\r\n"
                          "Connection: close\r\n\r\n" % (path, SITE_DOMAIN)).encode())
            head = sock.recv(64).decode("latin-1", "replace")
            ms = round((time.perf_counter() - t0) * 1000)
            sock.close()
            code = int(head.split(" ")[1]) if head.startswith("HTTP/") else 0
        except Exception:
            continue
        # A redirect from plain HTTP only means "go to HTTPS", it is not proof the site is up.
        ok = code == 200 or (scheme == "https" and 200 <= code < 400)
        res = {"path": path, "ok": ok, "code": code, "ms": ms, "via": scheme}
        if ok:
            return res
        tried.append(res)
    if tried:
        return tried[0]
    return {"path": path, "ok": False, "code": 0, "ms": None, "via": ""}


def _dep_check(item):
    name, url = item
    t0 = time.perf_counter()
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (pd-health)"})
        try:
            code = urllib.request.urlopen(req, timeout=5).status
        except urllib.error.HTTPError as exc:  # any HTTP answer means the service is reachable
            code = exc.code
        return {"name": name, "ok": code < 500, "code": code, "ms": round((time.perf_counter() - t0) * 1000)}
    except Exception:
        return {"name": name, "ok": False, "code": 0, "ms": None}


def _deps_worker():
    try:
        with ThreadPoolExecutor(max_workers=len(DEPS)) as pool:
            items = list(pool.map(_dep_check, DEPS))
        _deps.update(items=items, ts=time.time())
    finally:
        _deps["busy"] = False


def deps_cached():
    """Outside services are re-checked at most every 25 seconds, in the background, so polling stays light."""
    if not _deps["busy"] and time.time() - _deps["ts"] > 25:
        _deps["busy"] = True
        threading.Thread(target=_deps_worker, daemon=True).start()
    return {"items": _deps["items"], "age": int(time.time() - _deps["ts"]) if _deps["ts"] else None}


def health_snapshot():
    out = {"now": int(time.time())}
    try:
        la = _read("/proc/loadavg").split()[:3]
        du = shutil.disk_usage("/")
        out["server"] = {
            "cpu": cpu_percent(), "cores": os.cpu_count() or 1, "load": [float(x) for x in la],
            "mem": mem_info(), "disk": {"total": du.total, "used": du.used},
            "uptime": int(float(_read("/proc/uptime").split()[0])),
        }
    except Exception:
        out["server"] = None
    db_size = 0
    for suffix in ("", "-wal", "-shm"):
        try:
            db_size += os.path.getsize(os.path.join(DATA, "pd.db" + suffix))
        except OSError:
            pass
    try:
        rss = proc_rss()
    except Exception:
        rss = 0
    out["backend"] = {"uptime": int(time.time() - STARTED), "rss": rss, "db": db_size,
                      "threads": threading.active_count(), "push": PUSH_READY}
    out["site"] = [local_get("/"), local_get("/js/app.js")]
    out["deps"] = deps_cached()
    return out


# ---------------------------------------------------------------- HTTP
class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "pd"

    def log_message(self, *args):
        pass

    def ip(self):
        return (self.headers.get("X-Real-IP") or self.client_address[0])[:64]

    def reply(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def body(self, limit):
        n = int(self.headers.get("Content-Length") or 0)
        if n > limit:
            raise Bad("Request too large")
        raw = self.rfile.read(n) if n else b"{}"
        data = json.loads(raw or b"{}")
        if not isinstance(data, dict):
            raise Bad("Bad request")
        return data

    def admin(self):
        """True when the request carries a valid admin session token."""
        ip = self.ip()
        if not rate_ok(ip, "admin", 240, 60):
            self.reply(429, {"error": "slow down"})
            return False
        if blocked(ip):
            self.reply(429, {"error": "Too many wrong attempts. Wait 10 minutes."})
            return False
        auth = self.headers.get("Authorization", "")
        token = auth[7:] if auth.startswith("Bearer ") else ""
        with LOCK:
            secret = sget("secret")
        if token and token_ok(token, secret):
            return True
        record_fail(ip)
        self.reply(401, {"error": "Please log in again."})
        return False

    def do_GET(self):
        try:
            path = self.path.split("?", 1)[0].rstrip("/")
            if path == "/pd-api/health":
                return self.reply(200, {"ok": 1, "push": PUSH_READY})
            if path == "/pd-api/config":
                return self.reply(200, CFG)
            if path == "/pd-api/vapid":
                return self.reply(200, {"key": VAPID_PUBLIC})
            if path == "/pd-api/admin/stats":
                if self.admin():
                    self.reply(200, stats())
                return
            if path == "/pd-api/admin/health":
                if self.admin():
                    self.reply(200, health_snapshot())
                return
            if path == "/pd-api/admin/settings":
                if self.admin():
                    with LOCK:
                        self.reply(200, {"maintenance": sget("maintenance"), "popup": sget("popup")})
                return
            self.reply(404, {"error": "not found"})
        except Exception as exc:
            print("GET error", repr(exc), file=sys.stderr)
            self.reply(500, {"error": "server error"})

    def do_POST(self):
        try:
            path = self.path.split("?", 1)[0].rstrip("/")
            if path == "/pd-api/hit":
                return self.api_hit()
            if path == "/pd-api/subscribe":
                return self.api_subscribe()
            if path == "/pd-api/admin/login":
                return self.api_login()
            if path.startswith("/pd-api/admin/"):
                if not self.admin():
                    return
                if path == "/pd-api/admin/notify":
                    return self.api_notify()
                if path == "/pd-api/admin/settings":
                    return self.api_settings()
                if path == "/pd-api/admin/password":
                    return self.api_password()
                if path == "/pd-api/admin/logout-all":
                    with LOCK:
                        sset("secret", os.urandom(32).hex())
                        DB.commit()
                    return self.reply(200, {"ok": 1})
            self.reply(404, {"error": "not found"})
        except Bad as exc:
            self.reply(400, {"error": str(exc)})
        except (ValueError, KeyError):
            self.reply(400, {"error": "Bad request"})
        except Exception as exc:
            print("POST error", repr(exc), file=sys.stderr)
            self.reply(500, {"error": "server error"})

    # --- public endpoints
    def api_hit(self):
        if not rate_ok(self.ip(), "hit", 120, 60):
            return self.reply(429, {"ok": 0})
        d = self.body(4096)
        ua = self.headers.get("User-Agent", "")[:200]
        if BOT_RE.search(ua):
            return self.reply(200, {"ok": 1})
        sid, vid = clean(d.get("sid"), 40), clean(d.get("vid"), 40)
        if not (ID_RE.match(sid) and ID_RE.match(vid)):
            return self.reply(400, {"ok": 0})
        path = clean(d.get("path"), 120) or "#/"
        email = clean(d.get("email"), 190).lower()
        email = email if EMAIL_RE.match(email) else ""
        name = clean(d.get("name"), 60)
        kind = clean(d.get("t"), 8)
        now = int(time.time())
        day = day_of(now)
        with LOCK:
            row = DB.execute("SELECT email FROM sessions WHERE sid=?", (sid,)).fetchone()
            if row is None:
                device = "mobile" if re.search(r"Mobi|Android|iPhone|iPad", ua) else "desktop"
                DB.execute(
                    "INSERT INTO sessions(sid,vid,first_seen,last_seen,path,email,name,device) VALUES(?,?,?,?,?,?,?,?)",
                    (sid, vid, now, now, path, email, name, device),
                )
                DB.execute("INSERT OR IGNORE INTO visitors(vid,first_seen) VALUES(?,?)", (vid, now))
                bump_daily(day, visits=1, pv=1)
                new_login = bool(email)
            else:
                old_email = row[0] or ""
                DB.execute(
                    "UPDATE sessions SET last_seen=?, path=?, email=CASE WHEN ?!='' THEN ? ELSE email END, "
                    "name=CASE WHEN ?!='' THEN ? ELSE name END WHERE sid=?",
                    (now, path, email, email, name, name, sid),
                )
                if kind == "pv":
                    bump_daily(day, pv=1)
                new_login = bool(email) and email != old_email
            m = WATCH_RE.match(path)
            if m:
                key = m.group(1) + "/" + m.group(2)
                cur = DB.execute("INSERT OR IGNORE INTO viewed(sid,key) VALUES(?,?)", (sid, key))
                if cur.rowcount == 1:
                    DB.execute("INSERT OR IGNORE INTO titles(key,kind,id,views,last_seen) VALUES(?,?,?,0,?)",
                               (key, m.group(1), m.group(2), now))
                    DB.execute("UPDATE titles SET views=views+1, last_seen=? WHERE key=?", (now, key))
            if email:
                DB.execute("INSERT OR IGNORE INTO users(email,name,first_seen,last_seen,visits) VALUES(?,?,?,?,0)",
                           (email, name, now, now))
                DB.execute(
                    "UPDATE users SET last_seen=?, name=CASE WHEN ?!='' THEN ? ELSE name END, visits=visits+? WHERE email=?",
                    (now, name, name, 1 if new_login else 0, email),
                )
            DB.commit()
        self.reply(200, {"ok": 1})

    def api_subscribe(self):
        if not rate_ok(self.ip(), "sub", 20, 60):
            return self.reply(429, {"ok": 0})
        d = self.body(4096)
        sub = d.get("subscription") or {}
        endpoint = str(sub.get("endpoint") or "")
        keys = sub.get("keys") or {}
        if not (endpoint.startswith("https://") and len(endpoint) < 700 and keys.get("p256dh") and keys.get("auth")):
            return self.reply(400, {"ok": 0})
        clean_sub = {"endpoint": endpoint, "keys": {"p256dh": str(keys["p256dh"])[:200], "auth": str(keys["auth"])[:100]}}
        email = clean(d.get("email"), 190).lower()
        email = email if EMAIL_RE.match(email) else ""
        with LOCK:
            if DB.execute("SELECT COUNT(*) FROM subs").fetchone()[0] >= 500000:
                return self.reply(503, {"ok": 0})
            DB.execute(
                "INSERT INTO subs(endpoint,data,email,created) VALUES(?,?,?,?) "
                "ON CONFLICT(endpoint) DO UPDATE SET data=excluded.data, email=excluded.email",
                (endpoint, json.dumps(clean_sub), email, int(time.time())),
            )
            DB.commit()
        self.reply(200, {"ok": 1})

    # --- admin endpoints
    def api_login(self):
        ip = self.ip()
        if blocked(ip):
            return self.reply(429, {"error": "Too many wrong attempts. Wait 10 minutes."})
        d = self.body(2048)
        password = str(d.get("password") or "")[:200]
        with LOCK:
            stored, secret = sget("admin_hash"), sget("secret")
        if stored and pw_check(password, stored):
            token, exp = make_token(secret)
            return self.reply(200, {"token": token, "exp": exp, "default_pw": bool(INIT_HASH) and stored == INIT_HASH})
        record_fail(ip)
        time.sleep(0.7)
        self.reply(401, {"error": "Wrong password."})

    def api_password(self):
        d = self.body(2048)
        old, new = str(d.get("old") or ""), str(d.get("new") or "")
        if len(new) < 8:
            raise Bad("New password must be at least 8 characters.")
        if len(new) > 200:
            raise Bad("New password is too long.")
        with LOCK:
            stored = sget("admin_hash")
        if not (stored and pw_check(old, stored)):
            record_fail(self.ip())
            raise Bad("Current password is wrong.")
        with LOCK:
            sset("admin_hash", pw_hash(new))
            secret = os.urandom(32).hex()
            sset("secret", secret)
            DB.commit()
        token, exp = make_token(secret)
        self.reply(200, {"ok": 1, "token": token, "exp": exp})

    def api_settings(self):
        d = self.body(8192)
        with LOCK:
            if isinstance(d.get("maintenance"), dict):
                sset("maintenance", norm_maint(d["maintenance"]))
            if isinstance(d.get("popup"), dict):
                sset("popup", norm_popup(d["popup"], sget("popup", DEFAULT_POPUP)))
            DB.commit()
            rebuild_cfg()
            out = {"maintenance": sget("maintenance"), "popup": sget("popup")}
        self.reply(200, out)

    def api_notify(self):
        if not PUSH_READY:
            raise Bad("pywebpush is not installed on the server.")
        d = self.body(4096)
        title = clean(d.get("title"), 80)
        text = clean(d.get("body"), 200)
        url = clean(d.get("url"), 300) or "/"
        if not title or not text:
            raise Bad("Title and message are required.")
        if not ok_link(url):
            raise Bad("Link must start with /, # or https://")
        only = str(d.get("only_endpoint") or "")
        with LOCK:
            if only:
                rows = DB.execute("SELECT endpoint,data FROM subs WHERE endpoint=?", (only,)).fetchall()
            else:
                rows = DB.execute("SELECT endpoint,data FROM subs").fetchall()
            if not rows:
                raise Bad("There are no subscribers to send to.")
            cur = DB.execute(
                "INSERT INTO notifs(title,body,url,ts,total,test) VALUES(?,?,?,?,?,?)",
                (title, text, url, int(time.time()), len(rows), 1 if only else 0),
            )
            nid = cur.lastrowid
            DB.commit()
        payload = json.dumps({"title": title, "body": text, "url": url})
        threading.Thread(target=run_broadcast, args=(nid, rows, payload), daemon=True).start()
        self.reply(200, {"ok": 1, "id": nid, "total": len(rows)})


def stats():
    now = int(time.time())
    day = day_of(now)
    start_today = day * 86400 - TZ_OFFSET
    live_from = now - LIVE_WINDOW
    with LOCK:
        q = lambda sql, args=(): DB.execute(sql, args).fetchone()[0]  # noqa: E731
        live = q("SELECT COUNT(*) FROM sessions WHERE last_seen>=?", (live_from,))
        watching = q("SELECT COUNT(*) FROM sessions WHERE last_seen>=? AND path LIKE '%/watch/%'", (live_from,))
        live_users = q("SELECT COUNT(*) FROM sessions WHERE last_seen>=? AND email!=''", (live_from,))
        live_mobile = q("SELECT COUNT(*) FROM sessions WHERE last_seen>=? AND device='mobile'", (live_from,))
        today = DB.execute("SELECT visits,pv FROM daily WHERE day=?", (day,)).fetchone() or (0, 0)
        today_unique = q("SELECT COUNT(DISTINCT vid) FROM sessions WHERE first_seen>=?", (start_today,))
        totals = DB.execute("SELECT COALESCE(SUM(visits),0), COALESCE(SUM(pv),0) FROM daily").fetchone()
        unique_total = q("SELECT COUNT(*) FROM visitors")
        subs = q("SELECT COUNT(*) FROM subs")
        series = []
        for i in range(13, -1, -1):
            d = day - i
            row = DB.execute("SELECT visits,pv FROM daily WHERE day=?", (d,)).fetchone() or (0, 0)
            series.append({"date": time.strftime("%d %b", time.gmtime(d * 86400)), "visits": row[0], "pv": row[1]})
        users_total = q("SELECT COUNT(*) FROM users")
        users = [
            {"email": r[0], "name": r[1], "first_seen": r[2], "last_seen": r[3], "visits": r[4], "online": r[3] >= live_from}
            for r in DB.execute("SELECT email,name,first_seen,last_seen,visits FROM users ORDER BY last_seen DESC LIMIT 300")
        ]
        notifs = [
            {"id": r[0], "title": r[1], "body": r[2], "url": r[3], "ts": r[4], "total": r[5], "sent": r[6], "failed": r[7], "done": bool(r[8]), "test": bool(r[9])}
            for r in DB.execute("SELECT id,title,body,url,ts,total,sent,failed,done,test FROM notifs ORDER BY id DESC LIMIT 10")
        ]
        counts = {}
        for (p,) in DB.execute("SELECT path FROM sessions WHERE last_seen>=? AND path LIKE '%/watch/%'", (live_from,)):
            m = WATCH_RE.match(p or "")
            if m:
                counts[(m.group(1), m.group(2))] = counts.get((m.group(1), m.group(2)), 0) + 1
        live_titles = [{"kind": k[0], "id": k[1], "count": c} for k, c in sorted(counts.items(), key=lambda x: -x[1])[:8]]
        top_titles = [{"kind": r[0], "id": r[1], "count": r[2]}
                      for r in DB.execute("SELECT kind,id,views FROM titles ORDER BY views DESC LIMIT 10")]
        stored = sget("admin_hash")
    return {
        "now": now, "live": live, "watching": watching, "live_users": live_users, "live_mobile": live_mobile,
        "today_visits": today[0], "today_pv": today[1], "today_unique": today_unique,
        "total_visits": totals[0], "total_pv": totals[1], "unique_total": unique_total, "subs": subs,
        "series": series, "users_total": users_total, "users": users, "notifs": notifs,
        "live_titles": live_titles, "top_titles": top_titles,
        "maint_on": bool(CFG.get("m", {}).get("on")), "popup_on": bool(CFG.get("p", {}).get("on")),
        "default_pw": bool(INIT_HASH) and stored == INIT_HASH,
        "push_ready": PUSH_READY, "sb_sync": bool(SB_URL and SB_KEY),
    }


# ---------------------------------------------------------------- Supabase user sync (optional)
SB_URL = os.environ.get("PD_SUPABASE_URL", "").rstrip("/")
SB_KEY = os.environ.get("PD_SUPABASE_SERVICE_KEY", "").strip()


def _iso_to_ts(value):
    """'2026-11-02T10:20:30.123Z' -> unix seconds (0 when missing/invalid)."""
    m = re.match(r"(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})", str(value or ""))
    if not m:
        return 0
    try:
        import calendar
        return calendar.timegm(tuple(int(x) for x in m.groups()) + (0, 0, 0))
    except Exception:
        return 0


def sb_sync_users():
    """Copy every registered Supabase user into the admin Users list (needs the service key; read-only)."""
    if not (SB_URL and SB_KEY):
        return 0
    added, page = 0, 1
    while page <= 50:
        req = urllib.request.Request(
            "%s/auth/v1/admin/users?page=%d&per_page=200" % (SB_URL, page),
            headers={"apikey": SB_KEY, "Authorization": "Bearer " + SB_KEY},
        )
        with urllib.request.urlopen(req, timeout=20) as resp:
            data = json.loads(resp.read().decode("utf-8", "replace"))
        rows = data.get("users", []) if isinstance(data, dict) else []
        with LOCK:
            for u in rows:
                email = clean(u.get("email"), 190).lower()
                if not EMAIL_RE.match(email):
                    continue
                meta = u.get("user_metadata") or {}
                name = clean(meta.get("display_name") or meta.get("full_name") or meta.get("name") or meta.get("user_name") or "", 60)
                created = _iso_to_ts(u.get("created_at")) or int(time.time())
                last = _iso_to_ts(u.get("last_sign_in_at")) or created
                cur = DB.execute("INSERT OR IGNORE INTO users(email,name,first_seen,last_seen,visits) VALUES(?,?,?,?,0)",
                                 (email, name, created, last))
                added += cur.rowcount
                DB.execute(
                    "UPDATE users SET first_seen=MIN(first_seen,?), last_seen=MAX(last_seen,?), "
                    "name=CASE WHEN name='' THEN ? ELSE name END WHERE email=?",
                    (created, last, name, email),
                )
            DB.commit()
        if len(rows) < 200:
            break
        page += 1
    return added


def sb_sync_loop():
    time.sleep(5)
    while True:
        try:
            n = sb_sync_users()
            if n:
                print("supabase sync: %d new user(s)" % n, flush=True)
        except Exception as exc:  # never let this affect the site
            print("supabase sync error:", repr(exc)[:200], file=sys.stderr, flush=True)
        time.sleep(600)


if __name__ == "__main__":
    threading.Thread(target=prune_loop, daemon=True).start()
    if SB_URL and SB_KEY:
        threading.Thread(target=sb_sync_loop, daemon=True).start()
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    srv.daemon_threads = True
    print("publicdrop-pd listening on 127.0.0.1:%d (push=%s)" % (PORT, PUSH_READY), flush=True)
    srv.serve_forever()
PYEOF
id publicdrop-pd >/dev/null 2>&1 || useradd -r -s /sbin/nologin -d "$DATA" publicdrop-pd
chown -R publicdrop-pd:publicdrop-pd "$DATA"
chmod 755 "$APP"; chmod 644 "$APP/server.py"

if [ ! -f "$ENVF" ]; then
  cat > "$ENVF" <<ENVEOF
PD_ADMIN_INIT_HASH=$DEFAULT_HASH
PD_PORT=8787
PD_DATA=$DATA
PD_VAPID_SUB=mailto:admin@$DOMAIN
PD_DOMAIN=$DOMAIN
PYTHONPATH=$APP/lib
ENVEOF
else
  sed -i '/^PD_ADMIN_TOKEN=/d' "$ENVF"
  grep -q '^PD_ADMIN_INIT_HASH=' "$ENVF" || echo "PD_ADMIN_INIT_HASH=$DEFAULT_HASH" >> "$ENVF"
  grep -q '^PD_DOMAIN=' "$ENVF" || echo "PD_DOMAIN=$DOMAIN" >> "$ENVF"
fi
sed -i '/^PD_SUPABASE_URL=/d' "$ENVF"; echo "PD_SUPABASE_URL=$SB_URL" >> "$ENVF"
if [ -n "${PD_SUPABASE_SERVICE_KEY:-}" ]; then
  sed -i '/^PD_SUPABASE_SERVICE_KEY=/d' "$ENVF"; echo "PD_SUPABASE_SERVICE_KEY=$PD_SUPABASE_SERVICE_KEY" >> "$ENVF"
fi
chmod 600 "$ENVF"

cat > /usr/local/bin/pd-reset-password <<'HEOF'
#!/usr/bin/env bash
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo"; exit 1; }
[ -n "${1:-}" ] || { echo "Usage: sudo pd-reset-password 'NewPassword'"; exit 1; }
set -a; . /etc/publicdrop-pd.env; set +a
exec runuser -u publicdrop-pd -- /usr/bin/python3 /opt/publicdrop-pd/server.py reset-password "$1"
HEOF
chmod 755 /usr/local/bin/pd-reset-password

cat > /usr/local/bin/pd-set-supabase-key <<'HEOF'
#!/usr/bin/env bash
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo"; exit 1; }
[ -n "${1:-}" ] || { echo "Usage: sudo pd-set-supabase-key 'SERVICE_ROLE_SECRET_KEY'"; exit 1; }
sed -i '/^PD_SUPABASE_SERVICE_KEY=/d' /etc/publicdrop-pd.env
echo "PD_SUPABASE_SERVICE_KEY=$1" >> /etc/publicdrop-pd.env
chmod 600 /etc/publicdrop-pd.env
systemctl restart publicdrop-pd && echo "Done. Registered users will appear in the admin Users tab within a minute."
HEOF
chmod 755 /usr/local/bin/pd-set-supabase-key

cat > /etc/systemd/system/publicdrop-pd.service <<UNITEOF
[Unit]
Description=PublicDROP admin, stats and push backend
After=network.target

[Service]
User=publicdrop-pd
Group=publicdrop-pd
EnvironmentFile=$ENVF
ExecStart=/usr/bin/python3 $APP/server.py
Restart=always
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=$DATA
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNITEOF

systemctl daemon-reload
systemctl enable publicdrop-pd >/dev/null 2>&1
systemctl restart publicdrop-pd

say "[6/6] Connecting nginx and checking everything"
mkdir -p /etc/nginx/default.d
cat > /etc/nginx/default.d/publicdrop-pd.conf <<'NGEOF'
location ^~ /pd-api/ {
    proxy_pass http://127.0.0.1:8787;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    client_max_body_size 16k;
}
NGEOF
cat > "$APP/nginx_fix.py" <<'NGFIX'
#!/usr/bin/env python3
"""Make sure the nginx server block(s) that serve the site include the /pd-api/ snippet.

Usage: nginx_fix.py DOMAIN BACKUP_DIR
Safe by design: it only ADDS one `include` line, backs up every file it touches, runs `nginx -t`
and restores the originals if nginx does not accept the result.
"""
import glob
import os
import re
import shutil
import subprocess
import sys
import time

DOMAIN, BK = sys.argv[1], sys.argv[2]
ROOT = os.environ.get("PD_NGINX_ROOT", "/etc/nginx")
SNIP = "/etc/nginx/default.d/publicdrop-pd.conf"
INC = "include " + SNIP + ";"


def conf_files():
    files = []
    if ROOT == "/etc/nginx" and shutil.which("nginx"):
        try:
            out = subprocess.run(["nginx", "-T"], capture_output=True, text=True, timeout=20)
            files = re.findall(r"^# configuration file (.+?):$", out.stdout + out.stderr, re.M)
        except Exception:
            files = []
    if not files:
        files = [os.path.join(ROOT, "nginx.conf")] + sorted(glob.glob(os.path.join(ROOT, "conf.d", "*.conf"))) \
            + sorted(glob.glob(os.path.join(ROOT, "sites-enabled", "*")))
    seen = []
    for f in files:
        if f not in seen and f != SNIP and os.path.isfile(f):
            seen.append(f)
    return seen


def mask(t):
    """Blank out comments and quoted strings, keeping every character offset the same."""
    out, i, n = [], 0, len(t)
    while i < n:
        c = t[i]
        if c == "#":
            j = t.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
        elif c in "\"'":
            j = i + 1
            while j < n and t[j] != c:
                j += 2 if t[j] == "\\" else 1
            j = min(j + 1, n)
            out.append(c + " " * (j - i - 2) + c if j - i >= 2 else c)
            i = j
        else:
            out.append(c)
            i += 1
    return "".join(out)


def blocks(m):
    """Return [(header, open_idx, close_idx, parent_headers)] for every {...} block."""
    stack, res, last = [], [], 0
    for i, ch in enumerate(m):
        if ch in ";":
            last = i + 1
        elif ch == "{":
            stack.append((m[last:i].strip(), i))
            last = i + 1
        elif ch == "}":
            if stack:
                head, o = stack.pop()
                res.append((head, o, i, [h for h, _ in stack]))
            last = i + 1
    return res


def statements(m, o, c):
    """Direct (depth 0) statements inside a block: [(text, start, end_of_semicolon)]."""
    res, depth, start = [], 0, o + 1
    for i in range(o + 1, c):
        ch = m[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                start = i + 1
        elif ch == ";" and depth == 0:
            res.append((m[start:i].strip(), start, i + 1))
            start = i + 1
    return res


def plan(path):
    text = open(path, encoding="utf-8", errors="surrogateescape").read()
    m = mask(text)
    found = []
    for head, o, c, parents in blocks(m):
        if head != "server" or "stream" in parents:
            continue
        st = statements(m, o, c)
        names = []
        for s, _, _ in st:
            if s.startswith("server_name"):
                names += s.split()[1:]
        listens = " ".join(s for s, _, _ in st if s.startswith("listen"))
        body = text[o:c]
        covered = INC in body or "default.d" in body or "/pd-api/" in body
        redirect_only = any(re.match(r"return\s+30\d", s) for s, _, _ in st)
        at = next((e for s, _, e in st if s.startswith("server_name")), o + 1)
        eol = m.find("\n", at)
        eol = len(m) if eol < 0 else eol
        if not m[at:eol].strip():  # only a comment (or nothing) follows: insert after it, on its own line
            at = eol
        found.append({"names": names, "default": "default_server" in listens, "covered": covered,
                      "redirect": redirect_only, "at": at, "o": o})
    return text, found


def main():
    plans = {f: plan(f) for f in conf_files()}
    named = [(f, b) for f, (_, bl) in plans.items() for b in bl if DOMAIN in b["names"] or "www." + DOMAIN in b["names"]]
    if named:
        targets = named
    else:  # no block names the domain: the site must be served by the default server
        targets = [(f, b) for f, (_, bl) in plans.items() for b in bl if b["default"] or not b["names"] or "_" in b["names"]]
    todo = [(f, b) for f, b in targets if not b["covered"] and not b["redirect"]]
    if not targets:
        print("NGINX-FIX: could not find a server block for " + DOMAIN + " (nothing changed).")
        return
    if not todo:
        print("NGINX-FIX: nginx already routes /pd-api/ for " + DOMAIN + " (nothing to change).")
        return

    os.makedirs(BK, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    saved = {}
    by_file = {}
    for f, b in todo:
        by_file.setdefault(f, []).append(b)
    for f, bl in by_file.items():
        text = plans[f][0]
        bak = os.path.join(BK, "nginx-%s-%s.bak" % (os.path.basename(f), stamp))
        shutil.copy2(f, bak)
        saved[f] = bak
        for b in sorted(bl, key=lambda x: -x["at"]):
            line_start = text.rfind("\n", 0, b["at"]) + 1
            indent = re.match(r"[ \t]*", text[line_start:]).group(0) or "    "
            text = text[:b["at"]] + "\n" + indent + INC + text[b["at"]:]
        with open(f, "w", encoding="utf-8", errors="surrogateescape") as fh:
            fh.write(text)
        print("NGINX-FIX: added the /pd-api/ include to " + f)

    if ROOT == "/etc/nginx" and shutil.which("nginx"):
        ok = subprocess.run(["nginx", "-t"], capture_output=True, text=True)
        if ok.returncode != 0:
            for f, bak in saved.items():
                shutil.copy2(bak, f)
            print("NGINX-FIX: nginx rejected the change, so I restored your original config. Details:")
            print(ok.stderr.strip())


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # never let this helper stop the installer
        print("NGINX-FIX: skipped (" + repr(exc) + ")")
NGFIX
say "Making sure nginx forwards /pd-api/ to the backend"
python3 "$APP/nginx_fix.py" "$DOMAIN" "$BK" || echo "NGINX-FIX: skipped"
setsebool -P httpd_can_network_connect 1 2>/dev/null || true
if nginx -t >/dev/null 2>&1; then
  systemctl reload nginx
else
  echo "nginx config test failed. Removing the new nginx snippet so your site keeps working."
  rm -f /etc/nginx/default.d/publicdrop-pd.conf
  nginx -t || true
  systemctl reload nginx 2>/dev/null || true
fi

sleep 2
if ! systemctl is-active --quiet publicdrop-pd; then
  echo "Backend did not start. Last log lines:"; journalctl -u publicdrop-pd -n 15 --no-pager
  echo "Your website itself is fine and unchanged by this problem."; exit 1
fi
HEALTH=$(curl -ksSL --max-time 8 --resolve "$DOMAIN:80:127.0.0.1" --resolve "$DOMAIN:443:127.0.0.1" "http://$DOMAIN/pd-api/health" 2>/dev/null || true)
echo "Backend check: ${HEALTH:-no reply}"
site_ok && echo "Website check: OK" || echo "Website check: FAILED (open the site and tell me what you see)"

echo
echo "=============================================="
case "$HEALTH" in
  *'"ok": 1'*)
    echo " DONE.  Admin panel:  https://$DOMAIN/admin/"
    echo " Log in with your admin password, then change it in the Account tab."
    echo " New: Server tab = live server health + website ping (only while you are logged in)." ;;
  *)
    echo " Website updated. The backend runs, but nginx is still not forwarding /pd-api/."
    echo " Direct backend check : $(curl -s --max-time 5 http://127.0.0.1:8787/pd-api/health || echo failed)"
    echo " Through nginx check  : ${HEALTH:-no reply}"
    echo " nginx server blocks  :"; grep -rn "server_name" /etc/nginx --include=*.conf 2>/dev/null | grep -v '^\S*:[0-9]*:\s*#' | head -8
    echo " Send me a screenshot of this box." ;;
esac
echo " Login: set up the database once (supabase-setup.sql) and add https://$DOMAIN in Supabase > Authentication > URL Configuration."
echo " Admin Users tab: shows people as they sign in. To also list everyone already registered:"
echo "     sudo pd-set-supabase-key 'YOUR_SERVICE_ROLE_SECRET'"
echo " Install as app: open https://$DOMAIN on a phone or in Chrome, then tap Install."
echo " Forgot the password?  sudo pd-reset-password 'NewPassword123'"
echo " Backups of the old site: $BK"
echo "=============================================="
