#!/usr/bin/env bash
# PublicDROP installer v12 (v10 + browser error log, site settings, cache and TMDB tools, VM health history, traffic sources) · (v9 + NontonGo and VidFast servers, no auto-switch, sandbox-free ad shield, own screen modes; v9 = v8 + Admin > Servers: separate movie/series and anime/cartoon server lists, ping test, auto-switch;
#                         v8 = v7 + team roles, activity log, backups, insights, user controls, scheduled push/maintenance/popup,
#                         announcement bar, login-to-watch switch, TMDB key health)
#                         v7 = v6 + Admin > API keys (extra TMDB key with automatic fail-over)
#                         + v6 =  v5 + Admin > Database (Supabase keys) + Admin > Inbox (movie requests & messages)
#                         + Help & Support page, Request a Movie, max 4 profiles, WhatsApp channel in the footer)
#   * uses the publicdrop.in.zip that sits NEXT TO this file (or PD_ZIP=/path/to.zip, or downloads it from $PD_RAW)
#   * checks the new files BEFORE touching anything
#   * backs up the current site to /root/pd-backups
#   * swaps the new site in, tests it, and AUTOMATICALLY ROLLS BACK if the test fails
#   * installs / upgrades the backend (admin panel, users, maintenance, popup, push, stats)
# Run:   sudo bash pd-install.sh
# Optional (shows EVERY registered user in the admin panel, even before they revisit):
#        sudo PD_SUPABASE_SERVICE_KEY='your-secret-service-role-key' bash pd-install.sh
# Optional (switches OFF "Confirm email" in Supabase, adds the site to the allowed redirect URLs and,
#           if you also give the Google keys, turns on Google sign-in - all in one go):
#        sudo PD_SB_TOKEN='sbp_your_personal_access_token' \
#             PD_GOOGLE_CLIENT_ID='xxxx.apps.googleusercontent.com' PD_GOOGLE_CLIENT_SECRET='GOCSPX-xxxx' bash pd-install.sh
#        (create the token at https://supabase.com/dashboard/account/tokens ; it is used once and never stored)
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
  # any publicdrop*.zip (e.g. "publicdrop.in-4.zip"): take the NEWEST one so an old download is never installed by mistake
  ZIP="$(ls -1t "$SELF_DIR"/publicdrop*.zip "$PWD"/publicdrop*.zip "$SELF_DIR"/PublicDROP*.zip 2>/dev/null | head -n 1 || true)"
  [ -n "$ZIP" ] && [ -s "$ZIP" ] || ZIP=""
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
for f in js/site-theme.js index.html js/app.js js/config.js js/auth.js js/player.js js/pd-track.js js/pwa.js js/account.js js/profiles.js css/profiles.css assets/avatars/a1.svg assets/avatars/a8.svg assets/avatars/a9.svg assets/avatars/a20.svg assets/avatars/a21.svg assets/avatars/a32.svg css/profiles.css sw.js manifest.json manifest.webmanifest offline.html admin/index.html assets/publicdrop-favicon.png assets/icon-192.png assets/icon-512.png assets/icon-maskable-192.png assets/icon-maskable-512.png assets/apple-touch-icon.png; do
  [ -s "$SRC/$f" ] || { echo "ERROR: the zip is missing $f. Nothing was changed."; exit 1; }
done
grep -q 'pd-track.js' "$SRC/index.html" || { echo "ERROR: index.html does not load pd-track.js. Nothing was changed."; exit 1; }
grep -q 'G-PLCGW0JZWK' "$SRC/index.html" || { echo "ERROR: index.html has no Google Analytics tag (wrong zip?). Nothing was changed."; exit 1; }
grep -q 'admin/health' "$SRC/admin/index.html" || { echo "ERROR: admin/index.html is the OLD one. Nothing was changed."; exit 1; }
grep -q 'account.js' "$SRC/index.html" || { echo "ERROR: index.html does not load account.js. Nothing was changed."; exit 1; }
grep -q 'profiles.js' "$SRC/index.html" || { echo "ERROR: index.html does not load profiles.js (profiles / My Space). Nothing was changed."; exit 1; }
grep -q 'zmfiavshwwgayrymnjia' "$SRC/js/config.js" || { echo "ERROR: config.js does not point at the new Supabase project. Nothing was changed."; exit 1; }
grep -q 'pd-pop' "$SRC/js/profiles.js" || { echo "ERROR: js/profiles.js is the OLD one (no profile menu). Nothing was changed."; exit 1; }
grep -q 'signInWithOAuth' "$SRC/js/auth.js" || { echo "ERROR: js/auth.js has no Google sign-in. Nothing was changed."; exit 1; }
grep -q 'pd-sb-config' "$SRC/js/config.js" || { echo "ERROR: js/config.js is the OLD one (no Supabase settings). Nothing was changed."; exit 1; }
grep -q 'supabase-test' "$SRC/admin/index.html" || { echo "ERROR: admin/index.html is the OLD one (no Database tab). Nothing was changed."; exit 1; }
grep -q 'servers-test' "$SRC/admin/index.html" || { echo "ERROR: admin/index.html is the OLD one (no Servers tab). Nothing was changed."; exit 1; }
grep -q 'SUPEREMBED_BASE_URL' "$SRC/js/config.js" || { echo "ERROR: js/config.js is the OLD one (no server lists). Nothing was changed."; exit 1; }
grep -q 'tmdb-test' "$SRC/admin/index.html" || { echo "ERROR: admin/index.html is the OLD one (no API keys tab). Nothing was changed."; exit 1; }
grep -q 'tab-activity' "$SRC/admin/index.html" || { echo "ERROR: admin/index.html is the OLD one (no team / activity / backups). Nothing was changed."; exit 1; }
grep -q 'PDGate' "$SRC/js/pd-track.js" || { echo "ERROR: js/pd-track.js is the OLD one (no announcement bar / login-to-watch). Nothing was changed."; exit 1; }
grep -q 'pd-tmdb-config' "$SRC/js/config.js" || { echo "ERROR: js/config.js is the OLD one (no extra TMDB key support). Nothing was changed."; exit 1; }
grep -q 'send-request' "$SRC/js/profiles.js" || { echo "ERROR: js/profiles.js is the OLD one (no Request a Movie). Nothing was changed."; exit 1; }
grep -q 'whatsapp.com/channel' "$SRC/js/app.js" || { echo "ERROR: js/app.js is the OLD one (no WhatsApp channel). Nothing was changed."; exit 1; }
if grep -q 'needsVerification' "$SRC/js/auth.js"; then echo "ERROR: js/auth.js still asks for e-mail confirmation (OLD file). Nothing was changed."; exit 1; fi
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
"""PublicDROP backend: visitor stats, admin panel API (roles, activity log, backups), maintenance + popup + announcement
settings (with schedules), login-to-watch switch, user controls, scheduled web push.

Standard library only, plus `pywebpush` for sending push notifications.
Listens on 127.0.0.1 and is reached through nginx at /pd-api/. Visitor IP addresses are never stored
(only admin sign-in attempts keep an address, for the activity log).
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
import tempfile
import threading
import time
import urllib.error
import urllib.parse
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
DEFAULT_THEME = {"accent": "#e50914", "mode": "dark", "force": False}
DEFAULT_TMDB = {"key": "", "mode": "auto"}
DEFAULT_ANN = {"on": False, "id": 0, "text": "", "link": "", "linkText": "", "style": "info", "dismissible": True, "start": 0, "end": 0}
DEFAULT_ACCESS = {"login_required": False}
ANN_STYLES = ("info", "success", "warn", "danger")
ADMIN_USER_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{2,29}$")
ROLES = ("owner", "admin", "moderator")
ROLE_LABEL = {"owner": "Owner", "admin": "Admin", "moderator": "Moderator"}
# What each role may do. "*" = everything (owner only: team, backups, Supabase keys, deleting accounts).
PERMS = {
    "owner": {"*"},
    "admin": {"view", "controls", "notify", "inbox", "users", "usermanage", "tmdb", "activity"},
    "moderator": {"view", "inbox", "users", "usermanage"},
}
BACKUP_DIR = os.path.join(DATA, "backups")
BACKUP_KEEP = 7
UID_RE = re.compile(r"^[0-9a-fA-F-]{36}$")
SB_BAN_FOREVER = "876000h"
TMDB_KEY_RE = re.compile(r"^[A-Fa-f0-9]{32}$")
TMDB_MODES = ("auto", "main", "extra")
# ---- playback servers: two separate lists (movies + web series | anime + cartoons), editable in Admin > Servers
SRV_GROUPS = {"video": ("vidlink", "vidstuck", "vumeto", "superembed", "nontongo", "vidfast"), "anime": ("vidlink", "vumeto", "smashy", "twoembed", "nontongo", "vidfast")}
SRV_IDS = ("vidlink", "vidstuck", "superembed", "vumeto", "smashy", "twoembed", "nontongo", "vidfast")
SRV_NAMES = {"vidlink": "VidLink", "vidstuck": "Vidstuck", "superembed": "SuperEmbed VIP", "vumeto": "Vumeto", "smashy": "Smashy", "twoembed": "2Embed Anime", "nontongo": "NontonGo", "vidfast": "VidFast"}
SRV_PING = {"vidlink": "https://vidlink.pro/", "vidstuck": "https://vidstuck.cc/", "superembed": "https://multiembed.mov/directstream.php?video_id=tt6791350&check=1",
            "vumeto": "https://vumeto.xyz/", "smashy": "https://player.smashy.stream/", "twoembed": "https://www.2embed.skin/",
            "nontongo": "https://www.nontongo.win/", "vidfast": "https://vidfast.vc/"}
DEFAULT_SERVERS = {"video": {"order": ["vidstuck", "vidlink", "vumeto", "nontongo", "vidfast", "superembed"], "off": []},
                   "anime": {"order": ["vumeto", "vidlink", "nontongo", "vidfast", "smashy", "twoembed"], "off": []},
                   "tpl": {}, "auto": True, "health": {}}


SITE_LANGS = ("hi", "en", "ta", "te", "ml", "kn", "bn", "mr", "pa")
DEFAULT_SITE = {"telegram_url": "", "telegram_username": "", "whatsapp_url": "", "audio_server": {}, "shield_clicks": 1, "ad_shield": True}


def site_view():
    """Site settings with every missing piece filled in (an empty link means: use the built-in one)."""
    sv = sget("site", DEFAULT_SITE) or {}
    out = dict(DEFAULT_SITE)
    for k in ("telegram_url", "telegram_username", "whatsapp_url"):
        out[k] = str(sv.get(k) or "")
    aus = sv.get("audio_server") if isinstance(sv.get("audio_server"), dict) else {}
    out["audio_server"] = {l: int(n) for l, n in aus.items() if l in SITE_LANGS and isinstance(n, int) and 1 <= n <= 8}
    try:
        out["shield_clicks"] = max(0, min(3, int(sv.get("shield_clicks", 1))))
    except (TypeError, ValueError):
        out["shield_clicks"] = 1
    out["ad_shield"] = sv.get("ad_shield", True) is not False
    return out


def servers_view():
    """The saved server lists with every missing piece filled in (safe to hand to the browser)."""
    sv = sget("servers", DEFAULT_SERVERS) or {}
    out = {"tpl": dict(sv.get("tpl") or {}), "auto": sv.get("auto", True) is not False, "health": dict(sv.get("health") or {})}
    for g, allowed in SRV_GROUPS.items():
        x = sv.get(g) or {}
        order = [i for i in (x.get("order") or []) if i in allowed]
        order += [i for i in DEFAULT_SERVERS[g]["order"] if i not in order]
        out[g] = {"order": order, "off": [i for i in (x.get("off") or []) if i in allowed]}
    return out

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
    CREATE TABLE IF NOT EXISTS inbox(
      id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT, uid TEXT DEFAULT '', email TEXT DEFAULT '', name TEXT DEFAULT '',
      subject TEXT DEFAULT '', body TEXT DEFAULT '', meta TEXT DEFAULT '{}', ts INTEGER, status TEXT DEFAULT 'new');
    CREATE INDEX IF NOT EXISTS ix_inbox_ts ON inbox(ts);
    CREATE INDEX IF NOT EXISTS ix_inbox_uid ON inbox(uid, ts);
    CREATE TABLE IF NOT EXISTS notifs(
      id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT, body TEXT, url TEXT, ts INTEGER,
      total INTEGER DEFAULT 0, sent INTEGER DEFAULT 0, failed INTEGER DEFAULT 0, done INTEGER DEFAULT 0, test INTEGER DEFAULT 0);
    CREATE TABLE IF NOT EXISTS admins(
      username TEXT PRIMARY KEY, hash TEXT NOT NULL, role TEXT NOT NULL DEFAULT 'admin', created INTEGER,
      last_login INTEGER DEFAULT 0, disabled INTEGER DEFAULT 0, tokver INTEGER DEFAULT 1);
    CREATE TABLE IF NOT EXISTS audit(
      id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER, admin TEXT, role TEXT, action TEXT, detail TEXT DEFAULT '', ip TEXT DEFAULT '');
    CREATE INDEX IF NOT EXISTS ix_audit_ts ON audit(ts);
    CREATE TABLE IF NOT EXISTS user_flags(
      email TEXT PRIMARY KEY, uid TEXT DEFAULT '', status TEXT DEFAULT '', reason TEXT DEFAULT '',
      signout_after INTEGER DEFAULT 0, updated INTEGER DEFAULT 0, by TEXT DEFAULT '');
    CREATE TABLE IF NOT EXISTS sched(
      id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT, body TEXT, url TEXT, run_at INTEGER, repeat TEXT DEFAULT '',
      status TEXT DEFAULT 'pending', created INTEGER, by TEXT DEFAULT '', last_sent INTEGER DEFAULT 0,
      sent_count INTEGER DEFAULT 0, note TEXT DEFAULT '');
    CREATE TABLE IF NOT EXISTS wh(
      uid TEXT NOT NULL, email TEXT DEFAULT '', k TEXT NOT NULL, title TEXT DEFAULT '', type TEXT DEFAULT '',
      season INTEGER DEFAULT 0, episode INTEGER DEFAULT 0, ct REAL DEFAULT 0, du REAL DEFAULT 0, fin INTEGER DEFAULT 0,
      at INTEGER DEFAULT 0, PRIMARY KEY(uid, k));
    CREATE INDEX IF NOT EXISTS ix_wh_email ON wh(email, at);
    CREATE TABLE IF NOT EXISTS srvuse(
      day INTEGER, srv TEXT, grp TEXT, opens INTEGER DEFAULT 0, picks INTEGER DEFAULT 0, quick INTEGER DEFAULT 0, PRIMARY KEY(day, srv, grp));
    CREATE TABLE IF NOT EXISTS errlog(
      sig TEXT PRIMARY KEY, msg TEXT, src TEXT DEFAULT '', page TEXT DEFAULT '', devs TEXT DEFAULT '', n INTEGER DEFAULT 0, first INTEGER DEFAULT 0, last INTEGER DEFAULT 0);
    CREATE INDEX IF NOT EXISTS ix_errlog_last ON errlog(last);
    CREATE TABLE IF NOT EXISTS vmh(ts INTEGER PRIMARY KEY, cpu REAL DEFAULT 0, load REAL DEFAULT 0, mem REAL DEFAULT 0, disk REAL DEFAULT 0, swap REAL DEFAULT 0, rss INTEGER DEFAULT 0);
    CREATE TABLE IF NOT EXISTS wtday(day INTEGER PRIMARY KEY, sec REAL DEFAULT 0);
    CREATE TABLE IF NOT EXISTS wtitle(k TEXT PRIMARY KEY, title TEXT DEFAULT '', type TEXT DEFAULT '', sec REAL DEFAULT 0, last INTEGER DEFAULT 0);
    CREATE TABLE IF NOT EXISTS keystats(
      hour INTEGER, k TEXT, ok INTEGER DEFAULT 0, fail INTEGER DEFAULT 0, slow INTEGER DEFAULT 0,
      ms_sum INTEGER DEFAULT 0, ms_n INTEGER DEFAULT 0, switches INTEGER DEFAULT 0, PRIMARY KEY(hour, k));
    """
)
try:
    DB.execute("ALTER TABLE users ADD COLUMN uid TEXT DEFAULT ''")
except sqlite3.OperationalError:
    pass  # column already there
try:
    DB.execute("ALTER TABLE sessions ADD COLUMN src TEXT DEFAULT ''")  # where the visit came from (telegram, google, direct ...)
except sqlite3.OperationalError:
    pass
try:
    DB.execute("ALTER TABLE wh ADD COLUMN ws REAL DEFAULT 0")  # seconds REALLY played (older rows only knew how far the viewer got, so they count 0)
except sqlite3.OperationalError:
    pass
DB.commit()


class Bad(Exception):
    """A validation problem whose message is safe to show to the admin."""


class Denied(Exception):
    """The signed-in admin's role does not allow this."""


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


def make_token(secret, user, ver):
    """Admin login token = base64(expiry|username|version) + signature. Bumping `version` logs that admin out everywhere."""
    exp = int(time.time()) + SESSION_DAYS * 86400
    raw = base64.urlsafe_b64encode(("%d|%s|%d" % (exp, user, ver)).encode()).decode().rstrip("=")
    sig = hmac.new(bytes.fromhex(secret), raw.encode(), hashlib.sha256).hexdigest()
    return "%s.%s" % (raw, sig), exp


def token_parse(token, secret):
    """-> (username, version) when the token is genuine and not expired, else None."""
    try:
        raw, sig = token.split(".", 1)
        good = hmac.new(bytes.fromhex(secret), raw.encode(), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(sig, good):
            return None
        exp_s, user, ver = base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4)).decode().split("|")
        if int(exp_s) < time.time():
            return None
        return user, int(ver)
    except Exception:
        return None


def can(role, perm):
    p = PERMS.get(role, set())
    return "*" in p or perm in p


def perm_list(role):
    allp = ["view", "controls", "notify", "inbox", "users", "usermanage", "tmdb", "activity", "userdelete", "supabase", "backup", "admins"]
    return [x for x in allp if can(role, x)]


def audit(who, action, detail="", ip=""):
    """Write one line to the admin activity log. Never raises, never holds the lock for long. Call it OUTSIDE `with LOCK`."""
    try:
        with LOCK:
            DB.execute("INSERT INTO audit(ts,admin,role,action,detail,ip) VALUES(?,?,?,?,?,?)",
                       (int(time.time()), str(who[0])[:40], str(who[1])[:20], str(action)[:40], CTRL_RE.sub("", str(detail))[:400], str(ip)[:64]))
            DB.commit()
    except Exception as exc:  # pragma: no cover
        print("audit error", repr(exc)[:200], file=sys.stderr)


DEFAULT_HASH_DUMMY = "pbkdf2_sha256:200000:00000000000000000000000000000000:" + "0" * 64
CFG = {}  # public config served at /pd-api/config (rebuilt on every save)
SBCONF = {}  # saved Supabase settings, cached in memory (rebuilt on every save)
TMDBPUB = {}  # extra TMDB key + mode served inside /pd-api/public-config (TMDB keys are public in the browser anyway)
SRVPUB = {}  # server lists + last ping test, served inside /pd-api/public-config
SITEPUB = {}  # site settings edited in Admin > Control (footer links, default server per language, shield), served inside /pd-api/public-config
BUST = [0]  # "clear visitors' saved pages" token: browsers that see a new number drop their saved home rows
SBPUB = {}  # public Supabase URL + publishable key served at /pd-api/public-config (never the secret key)


def in_window(o, now=None):
    """True when the item is switched on AND we are inside its optional start/end time."""
    now = now or int(time.time())
    return bool(o.get("on")) and (not o.get("start") or now >= o["start"]) and (not o.get("end") or now < o["end"])


def cfg_now():
    """The public config with schedules applied right now (computed on every request, so start/end times just work)."""
    now = int(time.time())
    out = dict(CFG)
    for k in ("m", "p", "a"):
        if k in out:
            out[k] = dict(out[k], on=in_window(out[k], now))
    return out


def rebuild_cfg():
    m, p = sget("maintenance", DEFAULT_MAINT), sget("popup", DEFAULT_POPUP)
    t = sget("theme", DEFAULT_THEME)
    a = dict(DEFAULT_ANN, **(sget("announce", DEFAULT_ANN) or {}))
    g = dict(DEFAULT_ACCESS, **(sget("access", DEFAULT_ACCESS) or {}))
    CFG.clear()
    CFG.update({
        "t": {"accent": t.get("accent", "#e50914"), "mode": t.get("mode", "dark"), "force": bool(t.get("force"))},
        "m": {"on": bool(m["on"]), "title": m["title"], "message": m["message"], "eta": m["eta"],
              "start": int(m.get("start") or 0), "end": int(m.get("end") or 0)},
        "p": dict({k: p[k] for k in ("on", "id", "title", "body", "image", "btn", "url", "show", "delay")},
                  start=int(p.get("start") or 0), end=int(p.get("end") or 0)),
        "a": {k: a[k] for k in ("on", "id", "text", "link", "linkText", "style", "dismissible", "start", "end")},
        "g": {"login": bool(g.get("login_required"))},
    })
    sb = sget("supabase", {}) or {}
    SBCONF.clear()
    SBCONF.update(sb)
    SBPUB.clear()
    SBPUB.update({"url": sb.get("url", ""), "key": sb.get("publishable_key", "")})
    tm = sget("tmdb", DEFAULT_TMDB) or {}
    TMDBPUB.clear()
    TMDBPUB.update({"key": tm.get("key", ""), "mode": tm.get("mode", "auto") if tm.get("mode") in TMDB_MODES else "auto"})
    SRVPUB.clear()
    SRVPUB.update(servers_view())
    SITEPUB.clear()
    SITEPUB.update(site_view())
    try:
        BUST[0] = int(sget("bust", 0) or 0)
    except (TypeError, ValueError):
        BUST[0] = 0


with LOCK:
    if sget("secret") is None:
        sset("secret", os.urandom(32).hex())
    if sget("admin_hash") is None and INIT_HASH:
        sset("admin_hash", INIT_HASH)
    if sget("maintenance") is None:
        sset("maintenance", DEFAULT_MAINT)
    if sget("popup") is None:
        sset("popup", DEFAULT_POPUP)
    if sget("theme") is None:
        sset("theme", DEFAULT_THEME)
    if sget("tmdb") is None:
        sset("tmdb", DEFAULT_TMDB)
    if sget("servers") is None:
        sset("servers", DEFAULT_SERVERS)
    if sget("srv_mig4") is None:  # one-time: best servers first; SuperEmbed (dead: "File not found") switched off
        cur = sget("servers", DEFAULT_SERVERS) or {}
        for g in ("video", "anime"):
            x = dict(cur.get(g) or {})
            x["order"] = list(DEFAULT_SERVERS[g]["order"])
            x["off"] = list(x.get("off") or [])
            if g == "video" and "superembed" not in x["off"]:
                x["off"].append("superembed")
            cur[g] = x
        sset("servers", cur)
        sset("srv_mig4", 1)
    if sget("announce") is None:
        sset("announce", DEFAULT_ANN)
    if sget("access") is None:
        sset("access", DEFAULT_ACCESS)
    # the single admin password of older versions becomes the first account: user "admin", role owner
    if DB.execute("SELECT COUNT(*) FROM admins").fetchone()[0] == 0 and sget("admin_hash"):
        DB.execute("INSERT INTO admins(username,hash,role,created) VALUES('admin',?,'owner',?)", (sget("admin_hash"), int(time.time())))
    DB.commit()
    rebuild_cfg()

if len(sys.argv) >= 3 and sys.argv[1] == "reset-password":
    if len(sys.argv[2]) < 8:
        sys.exit("Password must be at least 8 characters.")
    with LOCK:
        newhash = pw_hash(sys.argv[2])
        sset("admin_hash", newhash)
        sset("secret", os.urandom(32).hex())
        # also (re)create the owner account "admin", so this command always gets you back in
        DB.execute("INSERT INTO admins(username,hash,role,created) VALUES('admin',?,'owner',?) "
                   "ON CONFLICT(username) DO UPDATE SET hash=excluded.hash, role='owner', disabled=0, tokver=tokver+1",
                   (newhash, int(time.time())))
        DB.commit()
    print("Password of the owner account 'admin' changed. All admin sessions were logged out.")
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
                DB.execute("DELETE FROM audit WHERE id <= (SELECT COALESCE(MAX(id),0) FROM audit) - 5000")
                DB.execute("DELETE FROM keystats WHERE hour < ?", (int(time.time()) // 3600 - 24 * 14,))
                DB.execute("DELETE FROM srvuse WHERE day < ?", (day_of(int(time.time())) - 120,))
                DB.execute("DELETE FROM wtitle WHERE last < ?", (int(time.time()) - 365 * 86400,))
                DB.execute("DELETE FROM sched WHERE status!='pending' AND created < ?", (int(time.time()) - 60 * 86400,))
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


def norm_window(d):
    """Optional schedule: unix seconds. 0 = no limit."""
    def ts(v):
        try:
            v = int(v or 0)
        except (TypeError, ValueError):
            raise Bad("That date is not valid.")
        if v < 0 or v > 4102444800:
            raise Bad("That date is out of range.")
        return v
    start, end = ts(d.get("start")), ts(d.get("end"))
    if start and end and end <= start:
        raise Bad("The end time must be after the start time.")
    return start, end


def norm_maint(d):
    title = clean(d.get("title"), 80) or DEFAULT_MAINT["title"]
    message = clean_ml(d.get("message"), 600) or DEFAULT_MAINT["message"]
    start, end = norm_window(d)
    return {"on": bool(d.get("on")), "title": title, "message": message, "eta": clean(d.get("eta"), 60), "start": start, "end": end}


def norm_announce(d, old):
    old = dict(DEFAULT_ANN, **(old or {}))
    style = d.get("style") if d.get("style") in ANN_STYLES else "info"
    start, end = norm_window(d)
    a = {
        "on": bool(d.get("on")), "text": clean(d.get("text"), 220), "link": clean(d.get("link"), 300),
        "linkText": clean(d.get("linkText"), 30), "style": style, "dismissible": bool(d.get("dismissible", True)),
        "start": start, "end": end,
    }
    if a["on"] and not a["text"]:
        raise Bad("Type the announcement text first.")
    if not ok_link(a["link"]):
        raise Bad("Link must start with /, #, http:// or https://")
    if a["linkText"] and not a["link"]:
        raise Bad("Add a link, or clear the link text.")
    content = lambda x: (x["text"], x["link"], x["linkText"], x["style"])  # noqa: E731
    changed = content(a) != content(old)
    a["id"] = int(time.time()) if (a["on"] and (not old["on"] or changed)) else old.get("id", 0)
    return a


def norm_access(d):
    return {"login_required": bool(d.get("login_required"))}


def norm_theme(d):
    accent = clean(d.get("accent"), 7).lower()
    if not re.match(r"^#[0-9a-f]{6}$", accent):
        raise Bad("Colour must look like #1f80e0")
    mode = "light" if d.get("mode") == "light" else "dark"
    return {"accent": accent, "mode": mode, "force": bool(d.get("force"))}


def norm_popup(d, old):
    show = d.get("show") if d.get("show") in ("once", "daily", "visit") else "once"
    try:
        delay = max(0, min(30, int(d.get("delay", 3))))
    except (TypeError, ValueError):
        delay = 3
    start, end = norm_window(d)
    p = {
        "start": start, "end": end,
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


# ---------------------------------------------------------------- Supabase settings (set from the admin panel)
# Stored in the database (/var/lib/publicdrop-pd), so they survive re-installs and never need a file edit.
SB_ENV_URL = os.environ.get("PD_SUPABASE_URL", "").rstrip("/")
SB_ENV_SERVICE = os.environ.get("PD_SUPABASE_SERVICE_KEY", "").strip()
SB_ENV_PUB = os.environ.get("PD_SUPABASE_PUB_KEY", "").strip()
SB_REF_RE = re.compile(r"^[a-z0-9]{12,40}$")
SB_HOST_RE = re.compile(r"^https://([a-z0-9][a-z0-9.-]{2,120})$")
SB_PUB_RE = re.compile(r"^sb_publishable_[A-Za-z0-9_-]{16,200}$")
SB_SECRET_RE = re.compile(r"^sb_secret_[A-Za-z0-9_-]{16,200}$")
JWT_RE = re.compile(r"^eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}$")
SYNC_NOW = threading.Event()


def jwt_role(token):
    try:
        part = token.split(".")[1]
        part += "=" * (-len(part) % 4)
        return str(json.loads(base64.urlsafe_b64decode(part)).get("role") or "")
    except Exception:
        return ""


def sb_conf():
    return SBCONF


def sb_url():
    return (sb_conf().get("url") or SB_ENV_URL or "").rstrip("/")


def sb_service_key():
    return (sb_conf().get("service_key") or SB_ENV_SERVICE or "").strip()


def sb_public_key():
    """Key used to ask Supabase "who is this signed-in visitor?" (falls back to the service key, which also works)."""
    return (sb_conf().get("publishable_key") or SB_ENV_PUB or sb_service_key() or "").strip()


def norm_supabase(d, old):
    """Validate what the admin typed. Secret fields: absent = keep, "" = remove, text = replace."""
    ref = clean(d.get("project_id"), 40).lower()
    url = clean(d.get("url"), 200).rstrip("/").lower()
    pub = clean(d.get("publishable_key"), 400)
    if ref and not SB_REF_RE.match(ref):
        raise Bad("Project ID must be the short code from your Supabase URL (letters and numbers only), e.g. zmfiavshwwgayrymnjia.")
    if url:
        if not SB_HOST_RE.match(url):
            raise Bad("Project URL must look like https://yourprojectid.supabase.co (no path, no spaces).")
        host = url[8:]
        if not ref and host.endswith(".supabase.co"):
            ref = host[: -len(".supabase.co")]
    elif ref:
        url = "https://%s.supabase.co" % ref
    if url and ref and url.endswith(".supabase.co") and url[8:-len(".supabase.co")] != ref:
        raise Bad("Project ID and Project URL point at different projects. Fix one of them (the URL is https://<project id>.supabase.co).")
    if pub:
        if SB_SECRET_RE.match(pub) or (JWT_RE.match(pub) and jwt_role(pub) == "service_role"):
            raise Bad("That is a SECRET key. Never put it in the public key field: every visitor can see this one. Use the sb_publishable_... key here, and put the secret key in the Secret key box below.")
        if not (SB_PUB_RE.match(pub) or (JWT_RE.match(pub) and jwt_role(pub) in ("anon", ""))):
            raise Bad("Public key must start with sb_publishable_ (or be the older anon key that starts with eyJ).")
    svc = old.get("service_key", "")
    if "service_key" in d:
        raw = clean(d.get("service_key"), 400)
        if raw == "":
            svc = ""
        else:
            if SB_PUB_RE.match(raw) or (JWT_RE.match(raw) and jwt_role(raw) == "anon"):
                raise Bad("That is the PUBLIC key. The secret box needs the sb_secret_... key (Supabase > Project Settings > API Keys).")
            if not (SB_SECRET_RE.match(raw) or (JWT_RE.match(raw) and jwt_role(raw) == "service_role")):
                raise Bad("Secret key must start with sb_secret_ (or be the older service_role key that starts with eyJ).")
            svc = raw
    if (url or pub or svc) and not url:
        raise Bad("Enter the Project ID (or the Project URL) too.")
    return {"project_id": ref, "url": url, "publishable_key": pub, "service_key": svc}


def sb_public_view():
    c = sb_conf()
    svc = c.get("service_key") or ""
    env_only = bool(not svc and SB_ENV_SERVICE)
    hint = ""
    if svc or env_only:
        k = svc or SB_ENV_SERVICE
        hint = k[:10] + "..." + k[-4:] if len(k) > 18 else "saved"
    return {
        "project_id": c.get("project_id", ""), "url": c.get("url", ""), "publishable_key": c.get("publishable_key", ""),
        "service_key_set": bool(svc or env_only), "service_key_hint": hint, "service_key_from_server_file": env_only,
        "effective_url": sb_url(), "sync_on": bool(sb_url() and sb_service_key()),
    }


def norm_tmdb(d, old):
    """Validate the extra TMDB key + mode the admin typed. Empty key = no extra key."""
    key = clean(d.get("key", old.get("key", "")), 200)
    mode = clean(d.get("mode", old.get("mode", "auto")), 10).lower() or "auto"
    if mode not in TMDB_MODES:
        raise Bad("Pick one of: automatic, main key first, extra key first.")
    if key and not TMDB_KEY_RE.match(key):
        if key.startswith("eyJ"):
            raise Bad("That is the long Read Access Token. Use the short API Key (32 letters and numbers) from themoviedb.org > Settings > API.")
        raise Bad("A TMDB API key is exactly 32 letters and numbers (themoviedb.org > Settings > API > API Key).")
    return {"key": key, "mode": mode}


def tmdb_public_view():
    t = sget("tmdb", DEFAULT_TMDB) or {}
    return {"key": t.get("key", ""), "mode": t.get("mode", "auto"), "key_set": bool(t.get("key"))}


def norm_servers(d, old):
    """Validate the server lists the admin saved: known servers only, at least one ON per list, https templates only."""
    old = old or {}
    out = {"tpl": {}, "health": dict(old.get("health") or {}), "auto": bool(d.get("auto", old.get("auto", True)))}
    for g, allowed in SRV_GROUPS.items():
        x = d.get(g) if isinstance(d.get(g), dict) else (old.get(g) or {})
        order = list(dict.fromkeys(i for i in (x.get("order") or []) if i in allowed))
        order += [i for i in DEFAULT_SERVERS[g]["order"] if i not in order]
        off = list(dict.fromkeys(i for i in (x.get("off") or []) if i in allowed))
        if all(i in off for i in allowed):
            raise Bad("Keep at least one server switched on for %s." % ("movies and web series" if g == "video" else "anime and cartoons"))
        out[g] = {"order": order, "off": off}
    tpl = d.get("tpl") if isinstance(d.get("tpl"), dict) else (old.get("tpl") or {})
    for i in SRV_IDS:
        v = clean(tpl.get(i, ""), 500)
        if v:
            if not re.match(r"^https://[^\s\"'<>]{4,490}$", v):
                raise Bad("The custom address for %s must start with https:// and have no spaces." % SRV_NAMES[i])
            out["tpl"][i] = v
    return out


def servers_ping_one(sid, url):
    started = time.time()
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (PublicDROP server check)", "Accept": "*/*"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            code = resp.status
    except urllib.error.HTTPError as exc:
        code = exc.code  # the host answered (a 403/404 from a protected embed host still means it is up)
    except Exception as exc:
        return {"id": sid, "ok": False, "ms": 0, "code": 0, "text": "No answer from this server (%s)." % type(exc).__name__}
    ms = int((time.time() - started) * 1000)
    ok = code < 500
    return {"id": sid, "ok": ok, "ms": ms, "code": code, "text": ("Answered in %d ms." % ms) if ok else ("The server is up but broken (error %s)." % code)}


def servers_test():
    """Ping every playback server from THIS server, save the result (the site then skips servers that are down) and report it."""
    sv = sget("servers", DEFAULT_SERVERS) or {}
    tpl = sv.get("tpl") or {}
    targets = {}
    off_all = set()
    for g in SRV_GROUPS:
        off_all |= set((sv.get(g) or {}).get("off") or [])
    for i in SRV_IDS:
        if i in off_all and all(i in ((sv.get(g) or {}).get("off") or []) for g, al in SRV_GROUPS.items() if i in al):
            continue  # switched off everywhere: nothing to test
        t = tpl.get(i)
        if t:
            pu = urllib.parse.urlsplit(t)
            targets[i] = "%s://%s/" % (pu.scheme, pu.netloc)
        else:
            targets[i] = SRV_PING[i]
    with ThreadPoolExecutor(max_workers=6) as ex:
        res = list(ex.map(lambda kv: servers_ping_one(kv[0], kv[1]), targets.items()))
    now = int(time.time())
    health = {r["id"]: {"ok": r["ok"], "ms": r["ms"], "at": now} for r in res}
    with LOCK:
        cur = sget("servers", DEFAULT_SERVERS) or {}
        cur["health"] = health
        sset("servers", cur)
        DB.commit()
        rebuild_cfg()
    checks = []
    for r in res:
        groups = [g for g, allowed in SRV_GROUPS.items() if r["id"] in allowed]
        checks.append({"id": r["id"], "name": SRV_NAMES[r["id"]], "groups": groups, "ok": r["ok"], "ms": r["ms"], "text": r["text"]})
    return {"checks": checks, "ok": any(c["ok"] for c in checks), "at": now}


def tmdb_test():
    """Ask TMDB, with the SAVED extra key, for its configuration and say in plain words what happened."""
    out = {"checks": []}
    key = (sget("tmdb", DEFAULT_TMDB) or {}).get("key", "")
    if not key:
        out["checks"].append({"name": "Extra key", "ok": False, "text": "No extra key is saved yet. Paste it above and press Save and test."})
        out["ok"] = False
        return out
    for name, base in (("TMDB (api.themoviedb.org)", "https://api.themoviedb.org/3"), ("TMDB alias (api.tmdb.org)", "https://api.tmdb.org/3")):
        started = time.time()
        try:
            req = urllib.request.Request("%s/configuration?api_key=%s" % (base, key), headers={"Accept": "application/json"})
            with urllib.request.urlopen(req, timeout=12) as resp:
                ms = int((time.time() - started) * 1000)
                ok = resp.status == 200
                text = "Accepted, answered in %d ms." % ms if ok else "TMDB answered with code %s." % resp.status
        except urllib.error.HTTPError as exc:
            ok = False
            text = "TMDB refused the key (code 401). Copy the API Key again." if exc.code == 401 else "TMDB answered with error %s." % exc.code
        except Exception as exc:
            ok = False
            text = "Could not reach it from the server (%s)." % type(exc).__name__
        out["checks"].append({"name": name, "ok": ok, "text": text})
    # the key is fine if at least one address accepted it
    out["ok"] = any(c["ok"] for c in out["checks"])
    if out["ok"]:
        for c in out["checks"]:
            if not c["ok"] and c["text"].startswith("Could not reach"):
                c["ok"] = True
                c["text"] += " Not a problem: the other address works."
    return out


def sb_call(path, key, bearer=None, timeout=15, method="GET", payload=None):
    hdr = {"apikey": key, "Authorization": "Bearer " + (bearer or key), "Content-Type": "application/json"}
    req = urllib.request.Request(sb_url() + path, headers=hdr, method=method,
                                 data=json.dumps(payload).encode() if payload is not None else None)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8", "replace") or "{}")
    except urllib.error.HTTPError as exc:
        try:
            body = json.loads(exc.read().decode("utf-8", "replace") or "{}")
        except Exception:
            body = {}
        return exc.code, body


def sb_test():
    """Check the SAVED settings against Supabase and say, in plain words, what works."""
    url, pub, svc = sb_url(), (sb_conf().get("publishable_key") or SB_ENV_PUB), sb_service_key()
    out = {"url": url, "checks": []}

    def add(name, ok, text):
        out["checks"].append({"name": name, "ok": bool(ok), "text": text})

    if not url:
        add("Project", False, "No project is set yet. Fill in the Project ID and save.")
        return out
    try:
        code, _ = sb_call("/auth/v1/health", pub or svc or "x")
        add("Project reachable", code in (200, 401, 404), "Supabase answered (code %s)." % code if code in (200, 401, 404) else "Supabase answered with error %s. Check the Project ID." % code)
    except Exception as exc:
        add("Project reachable", False, "Could not reach %s (%s). Check the Project ID." % (url, type(exc).__name__))
        return out
    if pub:
        try:
            code, _ = sb_call("/auth/v1/settings", pub)
            add("Public key", code == 200, "Accepted by Supabase." if code == 200 else "Supabase refused it (code %s). Copy the Publishable key again." % code)
        except Exception as exc:
            add("Public key", False, "Could not test it (%s)." % type(exc).__name__)
    else:
        add("Public key", True, "Not set here, so the website keeps the key built into its files.")
    if svc:
        try:
            code, _ = sb_call("/auth/v1/admin/users?page=1&per_page=1", svc)
            add("Secret key", code == 200, "Accepted. All registered users can be listed in the Users tab." if code == 200 else "Supabase refused it (code %s). Copy the Secret key again." % code)
        except Exception as exc:
            add("Secret key", False, "Could not test it (%s)." % type(exc).__name__)
    else:
        add("Secret key", True, "Not set. Optional: add it to list every registered user in the Users tab.")
    out["ok"] = all(c["ok"] for c in out["checks"])
    return out


def sb_verify_user(token):
    """Ask Supabase who owns this sign-in token. Returns {} when it is invalid or Supabase is not configured."""
    key = sb_public_key()
    if not (sb_url() and key and token and len(token) < 4000):
        return None
    try:
        code, body = sb_call("/auth/v1/user", key, bearer=token, timeout=10)
    except Exception:
        return None
    if code != 200 or not body.get("id"):
        return {}
    meta = body.get("user_metadata") or {}
    return {
        "id": clean(body.get("id"), 60), "email": clean(body.get("email"), 190).lower(),
        "name": clean(meta.get("display_name") or meta.get("full_name") or meta.get("name") or "", 60),
        "last_sign_in": _iso_to_ts(body.get("last_sign_in_at")),
    }


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
    ("VidLink player", "https://vidlink.pro/"),
    ("SuperEmbed player", "https://multiembed.mov/"),
    ("Smashy player", "https://player.smashy.stream/"),
    ("2Embed anime", "https://www.2embed.skin/"),
    ("Vumeto player", "https://vumeto.xyz/"),
    ("Vidstuck player", "https://vidstuck.cc/"),
    ("NontonGo player", "https://www.nontongo.win/"),
    ("VidFast player", "https://vidfast.vc/"),
    ("Supabase login", "https://zmfiavshwwgayrymnjia.supabase.co/auth/v1/health"),
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

# ---------------------------------------------------------------- broadcast + scheduled push
def start_broadcast(title, text, url, only=""):
    """Queue a push notification. Call WITHOUT holding LOCK. Returns (notification id, number of devices)."""
    with LOCK:
        if only:
            rows = DB.execute("SELECT endpoint,data FROM subs WHERE endpoint=?", (only,)).fetchall()
        else:
            rows = DB.execute("SELECT endpoint,data FROM subs").fetchall()
        if not rows:
            raise Bad("There are no subscribers to send to.")
        cur = DB.execute("INSERT INTO notifs(title,body,url,ts,total,test) VALUES(?,?,?,?,?,?)",
                         (title, text, url, int(time.time()), len(rows), 1 if only else 0))
        nid = cur.lastrowid
        DB.commit()
    payload = json.dumps({"title": title, "body": text, "url": url})
    threading.Thread(target=run_broadcast, args=(nid, rows, payload), daemon=True).start()
    return nid, len(rows)


REPEAT_STEP = {"daily": 86400, "weekly": 7 * 86400}


def sched_list():
    with LOCK:
        pend = DB.execute("SELECT id,title,body,url,run_at,repeat,status,by,last_sent,sent_count,note FROM sched "
                          "WHERE status='pending' ORDER BY run_at LIMIT 100").fetchall()
        done = DB.execute("SELECT id,title,body,url,run_at,repeat,status,by,last_sent,sent_count,note FROM sched "
                          "WHERE status!='pending' ORDER BY id DESC LIMIT 10").fetchall()
    keys = ("id", "title", "body", "url", "run_at", "repeat", "status", "by", "last_sent", "sent_count", "note")
    return {"items": [dict(zip(keys, r)) for r in pend + done], "now": int(time.time())}


def sched_fire_due():
    now = int(time.time())
    with LOCK:
        due = DB.execute("SELECT id,title,body,url,run_at,repeat FROM sched WHERE status='pending' AND run_at<=?", (now,)).fetchall()
    for sid, title, body, url, run_at, repeat in due:
        status, note = "sent", ""
        if now - run_at > 3600 and not repeat:
            status, note = "missed", "The server was off or busy at the planned time."
        else:
            try:
                if not PUSH_READY:
                    raise Bad("pywebpush is not installed on the server.")
                start_broadcast(title, body, url)
            except Bad as exc:
                status, note = "failed", str(exc)
            except Exception as exc:  # never let one bad job stop the loop
                status, note = "failed", type(exc).__name__
        with LOCK:
            if repeat and status != "missed":
                step = REPEAT_STEP.get(repeat, 86400)
                nxt = run_at + step * (((now - run_at) // step) + 1)
                DB.execute("UPDATE sched SET run_at=?, last_sent=?, sent_count=sent_count+?, note=? WHERE id=?",
                           (nxt, now, 1 if status == "sent" else 0, note, sid))
            elif repeat:
                step = REPEAT_STEP.get(repeat, 86400)
                DB.execute("UPDATE sched SET run_at=?, note=? WHERE id=?", (run_at + step * (((now - run_at) // step) + 1), note, sid))
            else:
                DB.execute("UPDATE sched SET status=?, note=?, last_sent=?, sent_count=sent_count+? WHERE id=?",
                           (status, note, now if status == "sent" else 0, 1 if status == "sent" else 0, sid))
            DB.commit()
        audit(("scheduler", "system"), "push-" + status, "%s%s" % (title, (": " + note) if note else ""))


def sched_loop():
    time.sleep(10)
    while True:
        try:
            sched_fire_due()
        except Exception as exc:  # pragma: no cover
            print("scheduler error", repr(exc)[:200], file=sys.stderr, flush=True)
        time.sleep(20)


# ---------------------------------------------------------------- user controls (disable / ban / sign out / delete)
def sb_find_uid(email):
    """The Supabase id of a registered e-mail (needs the Secret key). '' when unknown."""
    with LOCK:
        row = DB.execute("SELECT uid FROM users WHERE email=?", (email,)).fetchone()
        flag = DB.execute("SELECT uid FROM user_flags WHERE email=?", (email,)).fetchone()
    for r in (row, flag):
        if r and UID_RE.match(r[0] or ""):
            return r[0]
    url, key = sb_url(), sb_service_key()
    if not (url and key):
        return ""
    for page in range(1, 51):
        code, body = sb_call("/auth/v1/admin/users?page=%d&per_page=200" % page, key, timeout=20)
        users = body.get("users", []) if isinstance(body, dict) else []
        for u in users:
            if str(u.get("email") or "").lower() == email and UID_RE.match(str(u.get("id") or "")):
                return u["id"]
        if code != 200 or len(users) < 200:
            break
    return ""


WH_CACHE = {}  # tiny TTL cache so opening the same history again (or refreshing the totals) never hits Supabase twice


def wh_cached(key, ttl, fn, force=False):
    now = time.time()
    hit = WH_CACHE.get(key)
    if hit and not force and now - hit[0] < ttl:
        return hit[1]
    val = fn()
    if not (isinstance(val, dict) and val.get("error")):
        WH_CACHE[key] = (now, val)
        if len(WH_CACHE) > 200:
            for k in sorted(WH_CACHE, key=lambda x: WH_CACHE[x][0])[:50]:
                WH_CACHE.pop(k, None)
    return val


def wh_seconds(ws, du):
    """Seconds of a title that were really played (the player counts playback only: opening a movie at 89% or skipping ahead adds nothing),
    never more than the title's length. History keeps the last 150 titles per person."""
    try:
        ws, du = float(ws or 0), float(du or 0)
    except (TypeError, ValueError):
        return 0.0
    return max(0.0, min(ws, du) if du > 0 else ws)


def wh_user(email):
    """Watch history of one person, read from THIS server (saved by the website through /pd-api/wh)."""
    with LOCK:
        rows = DB.execute("SELECT title,type,season,episode,ws,du,fin,at FROM wh WHERE email=? ORDER BY at DESC LIMIT 150", (email,)).fetchall()
    items, total = [], 0.0
    for title, typ, season, episode, ws, du, fin, at in rows:
        sec = wh_seconds(ws, du)
        total += sec
        items.append({"title": clean(title or "Untitled", 160), "type": clean(typ or "", 12), "season": int(season or 0),
                      "episode": int(episode or 0), "sec": int(sec), "dur": int(du or 0), "fin": bool(fin),
                      "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(at or 0))})
    return {"email": email, "count": len(items), "total_sec": int(total), "items": items, "as_of": int(time.time())}


def wh_total():
    with LOCK:
        rows = DB.execute("SELECT uid,ws,du FROM wh").fetchall()
    users, total = set(), 0.0
    for uid, ws, du in rows:
        users.add(uid)
        total += wh_seconds(ws, du)
    return {"total_sec": int(total), "users": len(users), "titles": len(rows), "as_of": int(time.time())}


# ---------------------------------------------------------------- site settings, visit sources, browser errors, VM history, TMDB lookup
def norm_site(d, old):
    old = old or {}
    out = {}
    for k, label in (("telegram_url", "Telegram link"), ("whatsapp_url", "WhatsApp link")):
        v = clean(d.get(k, old.get(k, "")), 300)
        if v and not re.match(r"^https://[^\s\"'<>]{4,290}$", v):
            raise Bad("The %s must start with https:// and have no spaces." % label)
        out[k] = v
    un = clean(d.get("telegram_username", old.get("telegram_username", "")), 40)
    if un and not re.match(r"^@[A-Za-z0-9_]{3,32}$", un):
        raise Bad("The Telegram name must look like @PublicDROPflix.")
    out["telegram_username"] = un
    aus = d.get("audio_server") if isinstance(d.get("audio_server"), dict) else (old.get("audio_server") or {})
    out["audio_server"] = {}
    for lang in SITE_LANGS:
        try:
            n = int(aus.get(lang) or 0)
        except (TypeError, ValueError):
            n = 0
        if 1 <= n <= 8:
            out["audio_server"][lang] = n
    try:
        out["shield_clicks"] = max(0, min(3, int(d.get("shield_clicks", old.get("shield_clicks", 1)))))
    except (TypeError, ValueError):
        raise Bad("The shield tap count must be a number from 0 to 3.")
    out["ad_shield"] = bool(d.get("ad_shield", old.get("ad_shield", True)))
    return out


SRC_RULES = (("telegram", ("t.me", "telegram", "org.telegram")), ("whatsapp", ("whatsapp", "wa.me", "l.wl.co")),
             ("google", ("google.", "com.google", "gsa")), ("bing", ("bing.",)), ("duckduckgo", ("duckduckgo",)), ("yahoo", ("yahoo.",)),
             ("facebook", ("facebook", "fb.com", "fb.me", "m.me")), ("instagram", ("instagram",)),
             ("x / twitter", ("twitter.", "t.co", "x.com", "com.twitter")), ("youtube", ("youtube", "youtu.be")),
             ("reddit", ("reddit",)), ("discord", ("discord",)), ("pinterest", ("pinterest",)))


def _src_match(text):
    for name, needles in SRC_RULES:
        if any(n in text for n in needles):
            return name
    return ""


def classify_src(ref, utm):
    """Where a visit came from: ?utm_source= / ?src= first, otherwise the referring site. Only a short label is stored, never the full address."""
    u = re.sub(r"[^a-z0-9 ._-]", "", (utm or "").lower())[:30]
    if u:
        return _src_match(u) or u
    r = (ref or "").lower().strip()
    if not r:
        return "direct"
    m = re.match(r"^(?:[a-z0-9+.-]+://)?([^/:?#]+)", r)
    host = m.group(1) if m else ""
    if not host or SITE_DOMAIN.lower() in host:
        return "direct"
    return _src_match(host) or ("other: " + host[:40])


def traffic_sources(days):
    since = int(time.time()) - days * 86400
    with LOCK:
        rows = DB.execute("SELECT src,COUNT(*),COUNT(DISTINCT vid) FROM sessions WHERE first_seen>=? GROUP BY src ORDER BY 2 DESC", (since,)).fetchall()
    items, unknown, total = [], 0, 0
    for src, n, v in rows:
        if not src:
            unknown += n
            continue
        total += n
        items.append({"src": src, "visits": n, "people": v})
    return {"days": days, "total": total, "unknown": unknown, "items": items[:25], "as_of": int(time.time())}


ERR_NOISE = re.compile(r"ResizeObserver|^Script error|chrome-extension|moz-extension|safari-extension|Non-Error promise rejection|Loading chunk|AbortError|NetworkError when attempting|Failed to fetch|Load failed", re.I)


def dev_label(ua):
    ua = ua or ""
    osn = "TV" if re.search(r"SmartTV|Tizen|Web0S|WebOS|AndroidTV|BRAVIA|HbbTV", ua, re.I) else "Android" if "Android" in ua else "iOS" if re.search(r"iPhone|iPad|iPod", ua) else "Windows" if "Windows" in ua else "Mac" if "Macintosh" in ua else "Linux" if "Linux" in ua else "Other"
    br = "Edge" if "Edg/" in ua else "Samsung" if "SamsungBrowser" in ua else "Opera" if re.search(r"OPR/|Opera", ua) else "Firefox" if "Firefox" in ua else "Chrome" if re.search(r"Chrome|CriOS", ua) else "Safari" if "Safari" in ua else "Other"
    return "%s %s" % (osn, br)


def err_save(ip_ua, d):
    msg = clean(d.get("msg"), 220)
    src = clean(d.get("src"), 120)
    page = re.sub(r"[^a-z]", "", clean(d.get("page"), 20).lower())[:12]
    if not msg or ERR_NOISE.search(msg):
        return
    sig = hashlib.sha1((msg + "|" + src).encode("utf-8", "ignore")).hexdigest()[:16]
    dev = dev_label(ip_ua)
    now = int(time.time())
    with LOCK:
        row = DB.execute("SELECT devs FROM errlog WHERE sig=?", (sig,)).fetchone()
        if row is None:
            if DB.execute("SELECT COUNT(*) FROM errlog").fetchone()[0] >= 400:
                DB.execute("DELETE FROM errlog WHERE sig IN (SELECT sig FROM errlog ORDER BY last ASC LIMIT 50)")
            DB.execute("INSERT INTO errlog(sig,msg,src,page,devs,n,first,last) VALUES(?,?,?,?,?,1,?,?)", (sig, msg, src, page, dev, now, now))
        else:
            devs = [x for x in (row[0] or "").split(",") if x]
            if dev not in devs:
                devs = (devs + [dev])[-5:]
            DB.execute("UPDATE errlog SET n=n+1, last=?, page=?, devs=? WHERE sig=?", (now, page, ",".join(devs), sig))
        DB.commit()


def err_list():
    with LOCK:
        rows = DB.execute("SELECT msg,src,page,devs,n,first,last FROM errlog ORDER BY last DESC LIMIT 60").fetchall()
    return {"items": [{"msg": m, "src": s_, "page": p_, "devs": [x for x in (dv or "").split(",") if x], "n": n, "first": f, "last": l} for m, s_, p_, dv, n, f, l in rows],
            "now": int(time.time())}


def vm_sample():
    cpu = cpu_percent()
    mi = mem_info()
    du = shutil.disk_usage("/")
    la = float(_read("/proc/loadavg").split()[0])
    mem = 100.0 * mi["used"] / mi["total"] if mi["total"] else 0.0
    swap = 100.0 * mi["swap_used"] / mi["swap_total"] if mi["swap_total"] else 0.0
    disk = 100.0 * du.used / du.total if du.total else 0.0
    with LOCK:
        DB.execute("INSERT OR REPLACE INTO vmh(ts,cpu,load,mem,disk,swap,rss) VALUES(?,?,?,?,?,?,?)",
                   (int(time.time()), cpu or 0.0, la, mem, disk, swap, proc_rss()))
        DB.execute("DELETE FROM vmh WHERE ts < ?", (int(time.time()) - 14 * 86400,))
        DB.commit()


def vm_loop():
    time.sleep(20)
    while True:
        try:
            vm_sample()
        except Exception as exc:  # pragma: no cover
            print("vm sample error", exc, file=sys.stderr)
        time.sleep(300)


def vm_history(rng):
    hours = 168 if rng == "7d" else 24
    since = int(time.time()) - hours * 3600
    with LOCK:
        rows = DB.execute("SELECT ts,cpu,load,mem,disk,swap,rss FROM vmh WHERE ts>=? ORDER BY ts", (since,)).fetchall()
    step = max(1, len(rows) // 160 + (1 if len(rows) % 160 else 0)) if len(rows) > 160 else 1
    pts = []
    for i in range(0, len(rows), step):
        chunk = rows[i:i + step]
        n = len(chunk)
        pts.append({"ts": chunk[-1][0], "cpu": round(sum(r[1] for r in chunk) / n, 1), "load": round(sum(r[2] for r in chunk) / n, 2),
                    "mem": round(sum(r[3] for r in chunk) / n, 1), "disk": round(chunk[-1][4], 1), "swap": round(sum(r[5] for r in chunk) / n, 1),
                    "cpu_max": round(max(r[1] for r in chunk), 1), "mem_max": round(max(r[3] for r in chunk), 1)})
    try:
        total_mem, total_disk, cores = mem_info()["total"], shutil.disk_usage("/").total, os.cpu_count() or 1
    except Exception:
        total_mem, total_disk, cores = 0, 0, 1
    return {"range": "7d" if hours == 168 else "24h", "points": pts, "mem_total": total_mem, "disk_total": total_disk, "cores": cores, "now": int(time.time())}


def main_tmdb_key():
    """The key built into the website files (it is public in every visitor's browser anyway)."""
    try:
        with open(os.path.join(os.environ.get("PD_WEB", "/usr/share/nginx/html"), "js", "config.js"), encoding="utf-8") as fh:
            m = re.search(r'TMDB_API_KEY:\s*"([A-Fa-f0-9]{32})"', fh.read())
        return m.group(1) if m else ""
    except OSError:
        return ""


def tmdb_lookup(kind, tid):
    """What TMDB itself says about one title, so you can tell 'TMDB is wrong' from 'the site shows an old copy'."""
    if kind not in ("movie", "tv") or not re.match(r"^[0-9]{1,9}$", str(tid)):
        raise Bad("Enter a TMDB number and choose Movie or Series.")
    key = (sget("tmdb", DEFAULT_TMDB) or {}).get("key", "") or main_tmdb_key()
    if not key:
        raise Bad("No TMDB key is available on this server. Save an extra key in API keys first.")
    last = "No answer from TMDB."
    for base in ("https://api.themoviedb.org/3", "https://api.tmdb.org/3"):
        try:
            req = urllib.request.Request("%s/%s/%s?api_key=%s&language=en-US" % (base, kind, tid, key), headers={"Accept": "application/json"})
            with urllib.request.urlopen(req, timeout=12) as resp:
                j = json.loads(resp.read().decode("utf-8", "replace"))
            title = j.get("title") or j.get("name") or ""
            date = j.get("release_date") or j.get("first_air_date") or ""
            return {"ok": True, "title": clean(title, 200), "year": date[:4], "rating": round(float(j.get("vote_average") or 0), 1), "status": clean(j.get("status"), 40),
                    "overview": clean(j.get("overview"), 500), "runtime": int(j.get("runtime") or 0), "seasons": int(j.get("number_of_seasons") or 0),
                    "poster": ("https://image.tmdb.org/t/p/w185" + j["poster_path"]) if j.get("poster_path") and re.match(r"^/[A-Za-z0-9._-]+$", j["poster_path"]) else "",
                    "id": int(tid), "kind": kind}
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return {"ok": False, "text": "TMDB has no %s with number %s." % ("movie" if kind == "movie" else "series", tid)}
            last = "TMDB answered with error %s." % exc.code
        except Exception as exc:
            last = "Could not reach TMDB from the server (%s)." % type(exc).__name__
    return {"ok": False, "text": last}


def day_label(day):
    return time.strftime("%Y-%m-%d", time.gmtime(int(day) * 86400))


def srv_stats(days=14):
    """Which playback servers viewers really use (counted anonymously by the website): plays, chosen by hand, and left within a minute."""
    today = day_of(int(time.time()))
    first = today - days + 1
    with LOCK:
        rows = DB.execute("SELECT day,srv,opens,picks,quick FROM srvuse WHERE day>=?", (first,)).fetchall()
    tot, daily = {}, {}
    for day, srv, o, p, qk in rows:
        t = tot.setdefault(srv, [0, 0, 0])
        t[0] += o or 0
        t[1] += p or 0
        t[2] += qk or 0
        daily.setdefault(srv, {})
        daily[srv][day] = daily[srv].get(day, 0) + (o or 0)
    items = []
    for sid in SRV_IDS:
        t = tot.get(sid, [0, 0, 0])
        items.append({"id": sid, "name": SRV_NAMES[sid], "opens": t[0], "picks": t[1], "quick": t[2],
                      "daily": [daily.get(sid, {}).get(d, 0) for d in range(first, today + 1)]})
    items.sort(key=lambda x: -x["opens"])
    return {"days": days, "labels": [day_label(d) for d in range(first, today + 1)], "items": items, "total": sum(v[0] for v in tot.values()), "as_of": int(time.time())}


def watch_charts(days=30):
    """Hours really watched per day (all users) and the most watched titles. Counted from the seconds the player reports as played."""
    today = day_of(int(time.time()))
    first = today - days + 1
    with LOCK:
        got = dict(DB.execute("SELECT day,sec FROM wtday WHERE day>=?", (first,)).fetchall())
        top = DB.execute("SELECT title,type,sec FROM wtitle WHERE sec>0 ORDER BY sec DESC LIMIT 10").fetchall()
    return {"labels": [day_label(d) for d in range(first, today + 1)], "sec": [int(got.get(d, 0) or 0) for d in range(first, today + 1)],
            "top": [{"title": clean(t or "Untitled", 160), "type": clean(ty or "", 12), "sec": int(s or 0)} for t, ty, s in top], "as_of": int(time.time())}


WH_TOK = {}  # sign-in token -> (expires, who): avoids asking Supabase on every save


def wh_who(token):
    now = time.time()
    hit = WH_TOK.get(token)
    if hit and hit[0] > now:
        return hit[1]
    who = sb_verify_user(token)
    if who and who.get("id"):
        if len(WH_TOK) > 500:
            WH_TOK.clear()
        WH_TOK[token] = (now + 300, who)
    return who


def wh_num(v, hi):
    try:
        return max(0.0, min(float(v or 0), hi))
    except (TypeError, ValueError):
        return 0.0


def wh_save(who, d):
    """Store (or clear) one signed-in person's watch progress on this server."""
    uid, email = who["id"], who.get("email", "")
    with LOCK:
        if d.get("clear"):
            DB.execute("DELETE FROM wh WHERE uid=?", (uid,))
        for it in (d.get("items") or [])[:100]:
            if not isinstance(it, dict):
                continue
            k = clean(it.get("key"), 80)
            if not k:
                continue
            at = int(wh_num(it.get("watchedAt"), 4e12) / 1000) or int(time.time())
            du_new = wh_num(it.get("duration"), 1e6)
            ws_new = wh_num(it.get("watchedSec"), 1e6)
            if du_new > 0:
                ws_new = min(ws_new, du_new)
            row = DB.execute("SELECT ws FROM wh WHERE uid=? AND k=?", (uid, k)).fetchone()
            ws_old = float((row[0] if row else 0) or 0)
            ws_final = max(ws_old, ws_new)  # never goes down (another device may know less)
            gained = ws_final - ws_old
            if gained > 0:
                now = int(time.time())
                DB.execute("INSERT INTO wtday(day,sec) VALUES(?,?) ON CONFLICT(day) DO UPDATE SET sec=sec+excluded.sec", (day_of(now), gained))
                DB.execute("INSERT INTO wtitle(k,title,type,sec,last) VALUES(?,?,?,?,?) ON CONFLICT(k) DO UPDATE SET sec=sec+excluded.sec, title=excluded.title, last=excluded.last",
                           (k, clean(it.get("title") or "Untitled", 160), clean(it.get("type"), 12), gained, now))
            DB.execute("INSERT OR REPLACE INTO wh(uid,email,k,title,type,season,episode,ct,du,fin,at,ws) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
                       (uid, email, k, clean(it.get("title") or "Untitled", 160), clean(it.get("type"), 12),
                        int(wh_num(it.get("season"), 9999)), int(wh_num(it.get("episode"), 99999)),
                        wh_num(it.get("currentTime"), 1e6), wh_num(it.get("duration"), 1e6), 1 if it.get("finished") else 0, at,
                        ws_final))
        DB.execute("DELETE FROM wh WHERE uid=? AND k NOT IN (SELECT k FROM wh WHERE uid=? ORDER BY at DESC LIMIT 150)", (uid, uid))
        DB.commit()
    WH_CACHE.clear()


def sb_user_call(email, method, payload=None):
    """Run an admin call on one user at Supabase. -> (status text, ok). Falls back gracefully when no Secret key is saved."""
    if not (sb_url() and sb_service_key()):
        return "no-key", False
    try:
        uid = sb_find_uid(email)
        if not uid:
            return "not-found", False
        code, _ = sb_call("/auth/v1/admin/users/" + uid, sb_service_key(), method=method, payload=payload, timeout=20)
        return ("ok" if code in (200, 204) else "error %s" % code), code in (200, 204)
    except Exception as exc:
        return type(exc).__name__, False


def flag_upsert(email, **fields):
    with LOCK:
        DB.execute("INSERT OR IGNORE INTO user_flags(email) VALUES(?)", (email,))
        for k, v in fields.items():
            if k in ("status", "reason", "signout_after", "updated", "by", "uid"):
                DB.execute("UPDATE user_flags SET %s=? WHERE email=?" % k, (v, email))
        DB.commit()


# ---------------------------------------------------------------- insights: retention + devices (computed only when the tab is open)
_ana = {"ts": 0, "data": None}


def analytics():
    now = int(time.time())
    if _ana["data"] and now - _ana["ts"] < 60:
        return _ana["data"]
    today = day_of(now)
    with LOCK:
        rows = DB.execute("SELECT vid,first_seen,device FROM sessions WHERE first_seen>=?", (now - KEEP_SESSIONS_DAYS * 86400,)).fetchall()
        first_day = {vid: day_of(ts) for vid, ts in DB.execute(
            "SELECT vid,first_seen FROM visitors WHERE first_seen>=?", (now - KEEP_SESSIONS_DAYS * 86400,))}
        first_any = dict(DB.execute("SELECT vid,first_seen FROM visitors WHERE vid IN (SELECT DISTINCT vid FROM sessions WHERE first_seen>=?)",
                                    (now - 15 * 86400,)))
    per_day, days_seen, dev_total = {}, {}, {"mobile": set(), "desktop": set()}
    for vid, ts, device in rows:
        d = day_of(ts)
        per_day.setdefault(d, {}).setdefault(vid, device)
        days_seen.setdefault(vid, set()).add(d)
        if d >= today - 13:
            dev_total.setdefault(device if device in ("mobile", "desktop") else "desktop", set()).add(vid)
    series = []
    for i in range(13, -1, -1):
        d = today - i
        vids = per_day.get(d, {})
        new = sum(1 for v in vids if day_of(first_any.get(v, 0) or 0) == d)
        series.append({
            "date": time.strftime("%d %b", time.gmtime(d * 86400)), "new": new, "returning": len(vids) - new,
            "mobile": sum(1 for x in vids.values() if x == "mobile"), "desktop": sum(1 for x in vids.values() if x != "mobile"),
        })
    retention = {}
    for label, n in (("d1", 1), ("d7", 7), ("d30", 30)):
        eligible = retained = 0
        for vid, fd in first_day.items():
            if fd + n > today:
                continue
            eligible += 1
            if any(fd < d <= fd + n for d in days_seen.get(vid, ())):
                retained += 1
        retention[label] = {"days": n, "of": eligible, "back": retained, "rate": round(100.0 * retained / eligible, 1) if eligible else None}
    data = {
        "series": series, "retention": retention,
        "devices": {"mobile": len(dev_total.get("mobile", ())), "desktop": len(dev_total.get("desktop", ()))},
        "now": now,
    }
    _ana["ts"], _ana["data"] = now, data
    return data


# ---------------------------------------------------------------- TMDB key health (reported by visitors' browsers; labels only, never keys)
def keyhealth():
    hour = int(time.time()) // 3600
    since = hour - 23
    with LOCK:
        rows = DB.execute("SELECT hour,k,ok,fail,slow,ms_sum,ms_n,switches FROM keystats WHERE hour>=?", (since,)).fetchall()
        tm = sget("tmdb", DEFAULT_TMDB) or {}
    keys = {}
    for k in ("main", "extra"):
        mine = [r for r in rows if r[1] == k]
        ok, fail, slow = sum(r[2] for r in mine), sum(r[3] for r in mine), sum(r[4] for r in mine)
        ms_n = sum(r[6] for r in mine)
        bad = [r[0] for r in mine if r[3] > 0 or r[4] > 0]
        keys[k] = {
            "ok": ok, "fail": fail, "slow": slow, "requests": ok + fail,
            "success_pct": round(100.0 * ok / (ok + fail), 1) if (ok + fail) else None,
            "avg_ms": int(sum(r[5] for r in mine) / ms_n) if ms_n else None,
            "last_problem": (max(bad) + 1) * 3600 if bad else 0,
            "hours": [{"ok": sum(r[2] for r in mine if r[0] == h), "fail": sum(r[3] for r in mine if r[0] == h)} for h in range(since, hour + 1)],
        }
    return {"keys": keys, "switches": sum(r[7] for r in rows), "extra_set": bool(tm.get("key")), "mode": tm.get("mode", "auto"), "now": int(time.time())}


# ---------------------------------------------------------------- backups
def make_backup(path):
    """Consistent copy of the whole database (settings, admins, stats, inbox ...)."""
    os.makedirs(BACKUP_DIR, exist_ok=True)
    dst = sqlite3.connect(path)
    try:
        with LOCK:
            DB.backup(dst)
    finally:
        dst.close()
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


def backup_list():
    out = []
    try:
        for name in sorted(os.listdir(BACKUP_DIR), reverse=True):
            if re.match(r"^pd-\d{8}\.db$", name):
                st = os.stat(os.path.join(BACKUP_DIR, name))
                out.append({"name": name, "size": st.st_size, "ts": int(st.st_mtime)})
    except OSError:
        pass
    return out


def backup_loop():
    """One automatic copy per day, the last BACKUP_KEEP days are kept."""
    time.sleep(90)
    while True:
        try:
            name = "pd-%s.db" % time.strftime("%Y%m%d", time.gmtime(time.time() + TZ_OFFSET))
            path = os.path.join(BACKUP_DIR, name)
            if not os.path.exists(path):
                make_backup(path)
                print("backup written:", name, flush=True)
            for old in [b["name"] for b in backup_list()][BACKUP_KEEP:]:
                os.remove(os.path.join(BACKUP_DIR, old))
        except Exception as exc:  # pragma: no cover
            print("backup error", repr(exc)[:200], file=sys.stderr, flush=True)
        time.sleep(3600)


def export_json():
    """A readable export (not meant for restoring): settings without secrets, team without passwords, inbox, users, totals."""
    with LOCK:
        settings = {}
        for k, v in DB.execute("SELECT key,value FROM settings"):
            if k in ("secret", "admin_hash"):
                continue
            val = json.loads(v)
            if k == "supabase" and isinstance(val, dict):
                val = dict(val, service_key="(hidden)" if val.get("service_key") else "")
            settings[k] = val
        q = lambda sql: [list(r) for r in DB.execute(sql)]  # noqa: E731
        return {
            "exported_at": int(time.time()), "settings": settings,
            "team": q("SELECT username,role,created,last_login,disabled FROM admins"),
            "users": q("SELECT email,name,first_seen,last_seen,visits FROM users"),
            "user_flags": q("SELECT email,status,reason,signout_after,updated FROM user_flags"),
            "inbox": q("SELECT id,kind,email,name,subject,body,ts,status FROM inbox"),
            "daily": q("SELECT day,visits,pv FROM daily ORDER BY day"),
            "scheduled_push": q("SELECT id,title,body,url,run_at,repeat,status FROM sched"),
            "notifications": q("SELECT id,title,body,url,ts,total,sent,failed FROM notifs"),
            "top_titles": q("SELECT key,views FROM titles ORDER BY views DESC LIMIT 200"),
        }


def settings_out(role):
    """Settings the panel shows. Caller holds LOCK. Secrets are never included, and each role only gets what it may edit."""
    out = {
        "maintenance": sget("maintenance"), "popup": sget("popup"), "theme": sget("theme", DEFAULT_THEME),
        "announce": dict(DEFAULT_ANN, **(sget("announce", DEFAULT_ANN) or {})),
        "access": dict(DEFAULT_ACCESS, **(sget("access", DEFAULT_ACCESS) or {})),
    }
    if can(role, "controls"):
        out["site"] = site_view()
    if can(role, "supabase"):
        out["supabase"] = sb_public_view()
    if can(role, "tmdb"):
        out["tmdb"] = tmdb_public_view()
        out["servers"] = servers_view()
    return out


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

    def reply_file(self, path, filename, ctype="application/octet-stream", delete=False):
        size = os.path.getsize(path)
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(size))
        self.send_header("Content-Disposition", 'attachment; filename="%s"' % filename)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            with open(path, "rb") as fh:
                while True:
                    chunk = fh.read(65536)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
        finally:
            if delete:
                try:
                    os.remove(path)
                except OSError:
                    pass

    def admin(self, perm="view"):
        """True when the request carries a valid admin session token AND that admin's role allows `perm`."""
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
        parsed = token_parse(token, secret) if token else None
        if parsed:
            with LOCK:
                row = DB.execute("SELECT role,disabled,tokver FROM admins WHERE username=?", (parsed[0],)).fetchone()
            if row and not row[1] and row[2] == parsed[1]:
                self.who = (parsed[0], row[0])
                if not can(row[0], perm):
                    self.reply(403, {"error": "Your role (%s) cannot do this." % ROLE_LABEL.get(row[0], row[0])})
                    return False
                return True
        record_fail(ip)
        self.reply(401, {"error": "Please log in again."})
        return False

    def note(self, action, detail=""):
        audit(self.who, action, detail)

    GET_PERMS = {"inbox": "inbox", "stats": "view", "health": "view", "settings": "view", "me": "view", "analytics": "view",
                 "keyhealth": "tmdb", "watchtime": "users", "watchcharts": "users", "srvstats": "tmdb", "errors": "view", "vmhealth": "view", "traffic": "view", "audit": "activity", "admins": "admins", "schedule": "notify", "backups": "backup", "backup": "backup"}
    POST_PERMS = {"notify": "notify", "settings": "view", "password": "view", "logout-all": "view", "supabase-test": "supabase",
                  "tmdb-test": "tmdb", "servers-test": "tmdb", "errors-clear": "controls", "cache-bust": "tmdb", "tmdb-lookup": "tmdb", "inbox": "inbox", "history": "users", "user": "usermanage", "schedule": "notify", "admins": "admins"}

    def do_GET(self):
        try:
            parsed = urllib.parse.urlsplit(self.path)
            path = parsed.path.rstrip("/")
            q = urllib.parse.parse_qs(parsed.query)
            if path == "/pd-api/health":
                return self.reply(200, {"ok": 1, "push": PUSH_READY})
            if path == "/pd-api/config":
                return self.reply(200, cfg_now())
            if path == "/pd-api/vapid":
                return self.reply(200, {"key": VAPID_PUBLIC})
            if path == "/pd-api/public-config":
                return self.reply(200, dict(SBPUB, tmdb=dict(TMDBPUB), servers=dict(SRVPUB), site=dict(SITEPUB), bust=BUST[0]))
            if path.startswith("/pd-api/admin/"):
                route = path[len("/pd-api/admin/"):]
                need = self.GET_PERMS.get(route)
                if need is None:
                    return self.reply(404, {"error": "not found"})
                if not self.admin(need):
                    return
                if route == "inbox":
                    return self.reply(200, inbox_list(self.path))
                if route == "stats":
                    return self.reply(200, stats())
                if route == "health":
                    return self.reply(200, health_snapshot())
                if route == "settings":
                    with LOCK:
                        return self.reply(200, settings_out(self.who[1]))
                if route == "me":
                    return self.reply(200, {"user": self.who[0], "role": self.who[1], "label": ROLE_LABEL.get(self.who[1]), "perms": perm_list(self.who[1])})
                if route == "analytics":
                    return self.reply(200, analytics())
                if route == "watchtime":
                    return self.reply(200, wh_cached("total", 600, wh_total, force=bool(q.get("refresh"))))
                if route == "errors":
                    return self.reply(200, err_list())
                if route == "vmhealth":
                    return self.reply(200, vm_history((q.get("range") or [""])[0] if isinstance(q.get("range"), list) else q.get("range")))
                if route == "traffic":
                    try:
                        dd = int((q.get("days") or ["7"])[0] if isinstance(q.get("days"), list) else (q.get("days") or 7))
                    except (TypeError, ValueError):
                        dd = 7
                    return self.reply(200, traffic_sources(30 if dd >= 30 else 7))
                if route == "watchcharts":
                    return self.reply(200, wh_cached("charts", 300, watch_charts, force=bool(q.get("refresh"))))
                if route == "srvstats":
                    return self.reply(200, srv_stats())
                if route == "keyhealth":
                    return self.reply(200, keyhealth())
                if route == "audit":
                    return self.api_audit(q)
                if route == "admins":
                    return self.reply(200, admins_list())
                if route == "schedule":
                    return self.reply(200, sched_list())
                if route == "backups":
                    return self.reply(200, {"items": backup_list(), "keep": BACKUP_KEEP})
                if route == "backup":
                    return self.api_backup(q)
            self.reply(404, {"error": "not found"})
        except Exception as exc:
            print("GET error", repr(exc), file=sys.stderr)
            self.reply(500, {"error": "server error"})

    def do_POST(self):
        try:
            path = self.path.split("?", 1)[0].rstrip("/")
            if path == "/pd-api/hit":
                return self.api_hit()
            if path == "/pd-api/wh":
                return self.api_wh()
            if path == "/pd-api/srv":
                return self.api_srv()
            if path == "/pd-api/err":
                return self.api_err()
            if path == "/pd-api/subscribe":
                return self.api_subscribe()
            if path == "/pd-api/admin/login":
                return self.api_login()
            if path == "/pd-api/activate":
                return self.api_activate()
            if path == "/pd-api/inbox":
                return self.api_inbox()
            if path == "/pd-api/me-status":
                return self.api_me_status()
            if path == "/pd-api/tmdb-report":
                return self.api_tmdb_report()
            if path.startswith("/pd-api/admin/"):
                route = path[len("/pd-api/admin/"):]
                need = self.POST_PERMS.get(route)
                if need is None:
                    return self.reply(404, {"error": "not found"})
                if not self.admin(need):
                    return
                if route == "notify":
                    return self.api_notify()
                if route == "settings":
                    return self.api_settings()
                if route == "password":
                    return self.api_password()
                if route == "supabase-test":
                    return self.reply(200, sb_test())
                if route == "tmdb-test":
                    return self.reply(200, tmdb_test())
                if route == "servers-test":
                    return self.reply(200, servers_test())
                if route == "errors-clear":
                    with LOCK:
                        DB.execute("DELETE FROM errlog")
                        DB.commit()
                    self.note("errors-clear", "browser error log cleared")
                    return self.reply(200, {"ok": 1})
                if route == "cache-bust":
                    with LOCK:
                        sset("bust", int(time.time()))
                        rebuild_cfg()
                    self.note("cache-bust", "visitors' saved home rows will be reloaded")
                    return self.reply(200, {"ok": 1, "bust": BUST[0]})
                if route == "tmdb-lookup":
                    dl = self.body(512)
                    try:
                        res = tmdb_lookup(clean(dl.get("kind"), 6), clean(dl.get("id"), 12))
                    except Bad as exc:
                        res = {"ok": False, "text": str(exc)}
                    return self.reply(200, res)
                if route == "inbox":
                    return self.api_inbox_admin()
                if route == "history":
                    em = clean((self.body(512) or {}).get("email"), 190).lower()
                    if not EMAIL_RE.match(em):
                        raise Bad("Bad request")
                    self.note("user-history", em)
                    return self.reply(200, wh_cached("u:" + em, 120, lambda: wh_user(em)))
                if route == "user":
                    return self.api_user()
                if route == "schedule":
                    return self.api_schedule()
                if route == "admins":
                    return self.api_admins()
                if route == "logout-all":
                    with LOCK:
                        DB.execute("UPDATE admins SET tokver=tokver+1 WHERE username=?", (self.who[0],))
                        DB.commit()
                    self.note("logout-everywhere", "signed out all own devices")
                    return self.reply(200, {"ok": 1})
            self.reply(404, {"error": "not found"})
        except Bad as exc:
            self.reply(400, {"error": str(exc)})
        except Denied:
            self.reply(403, {"error": "Your role cannot do this."})
        except (ValueError, KeyError):
            self.reply(400, {"error": "Bad request"})
        except Exception as exc:
            print("POST error", repr(exc), file=sys.stderr)
            self.reply(500, {"error": "server error"})

    def api_activate(self):
        """Fallback when the SQL helper is not installed: confirm one unconfirmed Supabase account (needs the service key)."""
        if not rate_ok(self.ip(), "activate", 10, 600):
            return self.reply(429, {"ok": 0})
        email = clean(self.body(1024).get("email"), 190).lower()
        SB_URL, SB_KEY = sb_url(), sb_service_key()
        if not (SB_URL and SB_KEY and EMAIL_RE.match(email)):
            return self.reply(200, {"ok": 0})
        hdr = {"apikey": SB_KEY, "Authorization": "Bearer " + SB_KEY, "Content-Type": "application/json"}
        uid = ""
        for page in range(1, 51):
            req = urllib.request.Request("%s/auth/v1/admin/users?page=%d&per_page=200" % (SB_URL, page), headers=hdr)
            with urllib.request.urlopen(req, timeout=20) as resp:
                rows = (json.loads(resp.read().decode("utf-8", "replace")) or {}).get("users", [])
            for u in rows:
                if str(u.get("email") or "").lower() == email and not u.get("email_confirmed_at"):
                    uid = u.get("id") or ""
                    break
            if uid or len(rows) < 200:
                break
        if uid and re.match(r"^[0-9a-fA-F-]{36}$", uid):
            req = urllib.request.Request("%s/auth/v1/admin/users/%s" % (SB_URL, uid), data=json.dumps({"email_confirm": True}).encode(), headers=hdr, method="PUT")
            urllib.request.urlopen(req, timeout=20).read()
        self.reply(200, {"ok": 1})

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
                source = classify_src(clean(d.get("ref"), 200), clean(d.get("src"), 40))
                DB.execute(
                    "INSERT INTO sessions(sid,vid,first_seen,last_seen,path,email,name,device,src) VALUES(?,?,?,?,?,?,?,?,?)",
                    (sid, vid, now, now, path, email, name, device, source),
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
        username = clean(d.get("username"), 40).lower() or "admin"
        password = str(d.get("password") or "")[:200]
        with LOCK:
            row = DB.execute("SELECT hash,role,disabled,tokver FROM admins WHERE username=?", (username,)).fetchone()
            secret = sget("secret")
        good = bool(row) and pw_check(password, row[0]) if row else (pw_check(password, DEFAULT_HASH_DUMMY) and False)
        if good and not row[2]:
            with LOCK:
                DB.execute("UPDATE admins SET last_login=? WHERE username=?", (int(time.time()), username))
                DB.commit()
            token, exp = make_token(secret, username, row[3])
            audit((username, row[1]), "login", "signed in", ip)
            return self.reply(200, {"token": token, "exp": exp, "user": username, "role": row[1], "label": ROLE_LABEL.get(row[1]),
                                    "perms": perm_list(row[1]), "default_pw": bool(INIT_HASH) and row[0] == INIT_HASH})
        record_fail(ip)
        audit((username[:40], "?"), "login-failed", "wrong password" if row and not row[2] else ("account disabled" if row else "unknown user"), ip)
        time.sleep(0.7)
        self.reply(401, {"error": "Wrong username or password."})

    def api_password(self):
        d = self.body(2048)
        old, new = str(d.get("old") or ""), str(d.get("new") or "")
        if len(new) < 8:
            raise Bad("New password must be at least 8 characters.")
        if len(new) > 200:
            raise Bad("New password is too long.")
        with LOCK:
            row = DB.execute("SELECT hash FROM admins WHERE username=?", (self.who[0],)).fetchone()
        if not (row and pw_check(old, row[0])):
            record_fail(self.ip())
            raise Bad("Current password is wrong.")
        with LOCK:
            DB.execute("UPDATE admins SET hash=?, tokver=tokver+1 WHERE username=?", (pw_hash(new), self.who[0]))
            ver = DB.execute("SELECT tokver FROM admins WHERE username=?", (self.who[0],)).fetchone()[0]
            secret = sget("secret")
            DB.commit()
        self.note("password-changed", "own password")
        token, exp = make_token(secret, self.who[0], ver)
        self.reply(200, {"ok": 1, "token": token, "exp": exp})

    SETTINGS_PERM = {"maintenance": "controls", "popup": "controls", "theme": "controls", "announce": "controls",
                     "access": "controls", "supabase": "supabase", "tmdb": "tmdb", "servers": "tmdb", "site": "controls"}

    def api_settings(self):
        d = self.body(8192)
        role = self.who[1]
        for key, need in self.SETTINGS_PERM.items():
            if isinstance(d.get(key), dict) and not can(role, need):
                raise Denied()
        said = []
        with LOCK:
            if isinstance(d.get("maintenance"), dict):
                m = norm_maint(d["maintenance"])
                sset("maintenance", m)
                said.append(("maintenance", ("ON" if m["on"] else "off") + (" (scheduled)" if m["start"] or m["end"] else "")))
            if isinstance(d.get("popup"), dict):
                pp = norm_popup(d["popup"], sget("popup", DEFAULT_POPUP))
                sset("popup", pp)
                said.append(("popup", ("ON" if pp["on"] else "off") + (" (scheduled)" if pp["start"] or pp["end"] else "")))
            if isinstance(d.get("theme"), dict):
                sset("theme", norm_theme(d["theme"]))
                said.append(("theme", "changed"))
            if isinstance(d.get("announce"), dict):
                an = norm_announce(d["announce"], sget("announce", DEFAULT_ANN))
                sset("announce", an)
                said.append(("announcement", ("ON" if an["on"] else "off") + (" (scheduled)" if an["start"] or an["end"] else "")))
            if isinstance(d.get("access"), dict):
                ac = norm_access(d["access"])
                sset("access", ac)
                said.append(("login-to-watch", "ON" if ac["login_required"] else "off"))
            if isinstance(d.get("supabase"), dict):
                sset("supabase", norm_supabase(d["supabase"], sget("supabase", {}) or {}))
                SYNC_NOW.set()
                said.append(("supabase", "connection settings changed"))
            if isinstance(d.get("tmdb"), dict):
                tm = norm_tmdb(d["tmdb"], sget("tmdb", DEFAULT_TMDB) or {})
                sset("tmdb", tm)
                said.append(("tmdb-keys", "extra key %s, mode %s" % ("set" if tm["key"] else "not set", tm["mode"])))
            if isinstance(d.get("site"), dict):
                sset("site", norm_site(d["site"], sget("site", DEFAULT_SITE) or {}))
                said.append(("site-settings", "changed"))
            if isinstance(d.get("servers"), dict):
                sv = norm_servers(d["servers"], sget("servers", DEFAULT_SERVERS) or {})
                sset("servers", sv)
                said.append(("servers", "lists changed, auto-switch %s" % ("on" if sv["auto"] else "off")))
            DB.commit()
            rebuild_cfg()
            out = settings_out(role)
        for what, detail in said:
            self.note("settings-" + what, detail)
        self.reply(200, out)

    def api_audit(self, q):
        try:
            limit = max(1, min(500, int((q.get("limit") or ["200"])[0])))
        except ValueError:
            limit = 200
        who = clean((q.get("admin") or [""])[0], 40)
        with LOCK:
            if who:
                rows = DB.execute("SELECT id,ts,admin,role,action,detail,ip FROM audit WHERE admin=? ORDER BY id DESC LIMIT ?", (who, limit)).fetchall()
            else:
                rows = DB.execute("SELECT id,ts,admin,role,action,detail,ip FROM audit ORDER BY id DESC LIMIT ?", (limit,)).fetchall()
        keys = ("id", "ts", "admin", "role", "action", "detail", "ip")
        self.reply(200, {"items": [dict(zip(keys, r)) for r in rows], "now": int(time.time())})

    def api_backup(self, q):
        name = (q.get("file") or [""])[0]
        kind = (q.get("kind") or [""])[0]
        stamp = time.strftime("%Y%m%d-%H%M", time.gmtime(time.time() + TZ_OFFSET))
        if kind == "json":
            data = json.dumps(export_json(), indent=1).encode()
            self.note("backup-download", "readable export (.json)")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Content-Disposition", 'attachment; filename="publicdrop-export-%s.json"' % stamp)
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)
            return
        if name:
            if not re.match(r"^pd-\d{8}\.db$", name) or not os.path.exists(os.path.join(BACKUP_DIR, name)):
                return self.reply(404, {"error": "That backup does not exist."})
            self.note("backup-download", name)
            return self.reply_file(os.path.join(BACKUP_DIR, name), name)
        os.makedirs(BACKUP_DIR, exist_ok=True)
        tmp = os.path.join(BACKUP_DIR, "manual-%d.tmp" % int(time.time() * 1000))
        make_backup(tmp)
        self.note("backup-download", "full backup made now (.db)")
        self.reply_file(tmp, "publicdrop-backup-%s.db" % stamp, delete=True)

    # --- admin team (owner only)
    def api_admins(self):
        d = self.body(2048)
        action = d.get("action")
        user = clean(d.get("username"), 40).lower()
        me = self.who[0]
        if action == "add":
            pw = str(d.get("password") or "")
            role = d.get("role")
            if not ADMIN_USER_RE.match(user):
                raise Bad("Username: 3 to 30 characters, lower-case letters, numbers, dot, dash or underscore.")
            if role not in ROLES:
                raise Bad("Pick a role.")
            if len(pw) < 8 or len(pw) > 200:
                raise Bad("Password must be 8 to 200 characters.")
            with LOCK:
                if DB.execute("SELECT 1 FROM admins WHERE username=?", (user,)).fetchone():
                    raise Bad("That username is already taken.")
                if DB.execute("SELECT COUNT(*) FROM admins").fetchone()[0] >= 50:
                    raise Bad("Team limit reached (50).")
                DB.execute("INSERT INTO admins(username,hash,role,created) VALUES(?,?,?,?)", (user, pw_hash(pw), role, int(time.time())))
                DB.commit()
            self.note("team-add", "%s as %s" % (user, role))
            return self.reply(200, admins_list())
        with LOCK:
            row = DB.execute("SELECT role,disabled FROM admins WHERE username=?", (user,)).fetchone()
            owners = DB.execute("SELECT COUNT(*) FROM admins WHERE role='owner' AND disabled=0").fetchone()[0]
        if not row:
            raise Bad("That team member does not exist.")
        losing_owner = row[0] == "owner" and not row[1] and owners <= 1
        if action == "role":
            role = d.get("role")
            if role not in ROLES:
                raise Bad("Pick a role.")
            if user == me:
                raise Bad("You cannot change your own role. Ask another owner.")
            if losing_owner and role != "owner":
                raise Bad("There must always be at least one active owner.")
            with LOCK:
                DB.execute("UPDATE admins SET role=?, tokver=tokver+1 WHERE username=?", (role, user))
                DB.commit()
            self.note("team-role", "%s is now %s" % (user, role))
        elif action == "password":
            pw = str(d.get("password") or "")
            if len(pw) < 8 or len(pw) > 200:
                raise Bad("Password must be 8 to 200 characters.")
            with LOCK:
                DB.execute("UPDATE admins SET hash=?, tokver=tokver+1 WHERE username=?", (pw_hash(pw), user))
                DB.commit()
            self.note("team-password", "reset password of " + user)
        elif action in ("disable", "enable"):
            if user == me and action == "disable":
                raise Bad("You cannot disable your own account.")
            if action == "disable" and losing_owner:
                raise Bad("There must always be at least one active owner.")
            with LOCK:
                DB.execute("UPDATE admins SET disabled=?, tokver=tokver+1 WHERE username=?", (1 if action == "disable" else 0, user))
                DB.commit()
            self.note("team-" + action, user)
        elif action == "signout":
            with LOCK:
                DB.execute("UPDATE admins SET tokver=tokver+1 WHERE username=?", (user,))
                DB.commit()
            self.note("team-signout", user)
        elif action == "delete":
            if user == me:
                raise Bad("You cannot delete your own account.")
            if losing_owner:
                raise Bad("There must always be at least one active owner.")
            with LOCK:
                DB.execute("DELETE FROM admins WHERE username=?", (user,))
                DB.commit()
            self.note("team-delete", user)
        else:
            raise Bad("Bad request")
        self.reply(200, admins_list())

    # --- visitor accounts (disable / ban / sign out / delete)
    def api_user(self):
        d = self.body(2048)
        action = d.get("action")
        email = clean(d.get("email"), 190).lower()
        reason = clean(d.get("reason"), 200)
        if not EMAIL_RE.match(email):
            raise Bad("Bad request")
        now = int(time.time())
        who = self.who[0]
        note = ""
        if action in ("disable", "ban"):
            flag_upsert(email, status="disabled" if action == "disable" else "banned", reason=reason, updated=now, by=who)
            res, ok = sb_user_call(email, "PUT", {"ban_duration": SB_BAN_FOREVER})
            note = "Also blocked at Supabase." if ok else "Blocked on the website. (Supabase: %s. Add the Secret key in Database to block there too.)" % res
        elif action == "enable":
            flag_upsert(email, status="", reason="", updated=now, by=who)
            res, ok = sb_user_call(email, "PUT", {"ban_duration": "none"})
            note = "Allowed again." if ok or res == "no-key" else "Allowed again on the website. (Supabase: %s.)" % res
        elif action == "signout":
            flag_upsert(email, signout_after=now, updated=now, by=who)
            note = "They are signed out on their next visit (within a few minutes if they are online now)."
        elif action == "delete":
            if not can(self.who[1], "userdelete"):
                raise Denied()
            res, ok = sb_user_call(email, "DELETE")
            with LOCK:
                DB.execute("DELETE FROM users WHERE email=?", (email,))
                keep = DB.execute("SELECT status FROM user_flags WHERE email=?", (email,)).fetchone()
                if not (keep and keep[0] == "banned"):  # a banned address stays blocked even after its account is gone
                    DB.execute("DELETE FROM user_flags WHERE email=?", (email,))
                DB.commit()
            note = "Account deleted." if ok else "Removed from this list. (Supabase: %s.)" % ("no Secret key saved" if res == "no-key" else res)
        else:
            raise Bad("Bad request")
        self.note("user-" + action, email + (" (%s)" % reason if reason else ""))
        self.reply(200, {"ok": 1, "note": note})

    # --- scheduled push notifications
    def api_schedule(self):
        d = self.body(4096)
        action = d.get("action")
        if action == "cancel":
            try:
                sid = int(d.get("id") or 0)
            except (TypeError, ValueError):
                raise Bad("Bad request")
            with LOCK:
                row = DB.execute("SELECT title FROM sched WHERE id=? AND status='pending'", (sid,)).fetchone()
                DB.execute("UPDATE sched SET status='cancelled' WHERE id=? AND status='pending'", (sid,))
                DB.commit()
            if row:
                self.note("push-schedule-cancel", row[0])
            return self.reply(200, sched_list())
        if action != "add":
            raise Bad("Bad request")
        if not PUSH_READY:
            raise Bad("pywebpush is not installed on the server.")
        title, text = clean(d.get("title"), 80), clean(d.get("body"), 200)
        url = clean(d.get("url"), 300) or "/"
        repeat = d.get("repeat") if d.get("repeat") in ("daily", "weekly") else ""
        try:
            run_at = int(d.get("run_at") or 0)
        except (TypeError, ValueError):
            raise Bad("Pick a date and time.")
        if not title or not text:
            raise Bad("Title and message are required.")
        if not ok_link(url):
            raise Bad("Link must start with /, # or https://")
        if run_at < int(time.time()) + 30:
            raise Bad("Pick a time in the future.")
        if run_at > int(time.time()) + 366 * 86400:
            raise Bad("That is more than a year away.")
        with LOCK:
            if DB.execute("SELECT COUNT(*) FROM sched WHERE status='pending'").fetchone()[0] >= 50:
                raise Bad("You already have 50 scheduled notifications. Cancel some first.")
            DB.execute("INSERT INTO sched(title,body,url,run_at,repeat,created,by) VALUES(?,?,?,?,?,?,?)",
                       (title, text, url, run_at, repeat, int(time.time()), self.who[0]))
            DB.commit()
        self.note("push-schedule", "%s at %s%s" % (title, time.strftime("%d %b %Y %H:%M", time.gmtime(run_at + TZ_OFFSET)) + " IST", (", " + repeat) if repeat else ""))
        self.reply(200, sched_list())

    # --- public: is this signed-in visitor allowed? (disabled / banned / signed out by admin)
    def api_me_status(self):
        if not rate_ok(self.ip(), "me", 60, 60):
            return self.reply(429, {"ok": 0})
        auth = self.headers.get("Authorization", "")
        token = auth[7:].strip() if auth.startswith("Bearer ") else ""
        self.body(512)
        who = sb_verify_user(token) if token else None
        if not who or not who.get("email"):
            return self.reply(200, {"ok": 0})  # unknown: the site keeps working
        with LOCK:
            row = DB.execute("SELECT status,reason,signout_after FROM user_flags WHERE email=?", (who["email"],)).fetchone()
        out = {"ok": 1, "blocked": False, "signout": False}
        if row and row[0] in ("disabled", "banned"):
            out.update(blocked=True, status=row[0], reason=row[1] or "")
        elif row and row[2] and who.get("last_sign_in") and who["last_sign_in"] <= row[2]:
            out["signout"] = True
        self.reply(200, out)

    # --- public: anonymous TMDB key health counters from visitors' browsers
    def api_tmdb_report(self):
        if not rate_ok(self.ip(), "kh", 30, 60):
            return self.reply(429, {"ok": 0})
        d = self.body(2048)
        hour = int(time.time()) // 3600

        def num(v, cap):
            try:
                return max(0, min(cap, int(v)))
            except (TypeError, ValueError):
                return 0
        with LOCK:
            for k in ("main", "extra"):
                r = d.get(k)
                if not isinstance(r, dict):
                    continue
                ok, fail, slow = num(r.get("ok"), 500), num(r.get("fail"), 500), num(r.get("slow"), 500)
                n = num(r.get("n"), 500)
                ms = num(r.get("ms"), 500 * 60000)
                if not (ok or fail):
                    continue
                DB.execute("INSERT OR IGNORE INTO keystats(hour,k) VALUES(?,?)", (hour, k))
                DB.execute("UPDATE keystats SET ok=ok+?, fail=fail+?, slow=slow+?, ms_sum=ms_sum+?, ms_n=ms_n+? WHERE hour=? AND k=?",
                           (ok, fail, slow, ms, n, hour, k))
            sw = num(d.get("sw"), 500)
            if sw:
                DB.execute("INSERT OR IGNORE INTO keystats(hour,k) VALUES(?,?)", (hour, "all"))
                DB.execute("UPDATE keystats SET switches=switches+? WHERE hour=? AND k='all'", (sw, hour))
            DB.commit()
        self.reply(200, {"ok": 1})

    # --- requests + messages from signed-in visitors
    def api_err(self):
        """Anonymous: a browser reports a script error (short text only: no address bar, no person)."""
        if not rate_ok(self.ip(), "err", 20, 600):
            return self.reply(429, {"ok": 0})
        ua = self.headers.get("User-Agent", "")[:200]
        if not BOT_RE.search(ua):
            err_save(ua, self.body(2048))
        self.reply(200, {"ok": 1})

    def api_srv(self):
        """Anonymous, tiny: the website says a playback server was opened / picked by the viewer / left within a minute. Counts only, no identity."""
        if not rate_ok(self.ip(), "srv", 90, 600):
            return self.reply(429, {"ok": 0})
        d = self.body(512)
        srv, grp, ev = clean(d.get("srv"), 20), clean(d.get("grp"), 8), clean(d.get("ev"), 8)
        col = {"open": "opens", "pick": "picks", "quick": "quick"}.get(ev)
        if srv in SRV_IDS and grp in ("video", "anime") and col:
            with LOCK:
                day = day_of(int(time.time()))
                DB.execute("INSERT OR IGNORE INTO srvuse(day,srv,grp) VALUES(?,?,?)", (day, srv, grp))
                DB.execute("UPDATE srvuse SET %s=%s+1 WHERE day=? AND srv=? AND grp=?" % (col, col), (day, srv, grp))
                DB.commit()
        self.reply(200, {"ok": 1})

    def api_wh(self):
        ip = self.ip()
        if not rate_ok(ip, "wh", 120, 600):
            return self.reply(429, {"error": "Too many requests."})
        auth = self.headers.get("Authorization", "")
        token = auth[7:].strip() if auth.startswith("Bearer ") else ""
        d = self.body(60000)
        if not token:
            return self.reply(401, {"error": "Please sign in first."})
        who = wh_who(token)
        if not who:
            return self.reply(401, {"error": "Please sign in again."})
        wh_save(who, d)
        self.reply(200, {"ok": 1})

    def api_inbox(self):
        ip = self.ip()
        if not rate_ok(ip, "inbox", 20, 600):
            return self.reply(429, {"error": "Too many messages. Please try again in a few minutes."})
        auth = self.headers.get("Authorization", "")
        token = auth[7:].strip() if auth.startswith("Bearer ") else ""
        d = self.body(6000)
        kind = d.get("kind")
        if kind not in ("request", "message"):
            raise Bad("Bad request")
        if not token:
            return self.reply(401, {"error": "Please sign in first."})
        who = sb_verify_user(token)
        if who is None:
            return self.reply(503, {"error": "Messaging is not switched on yet. Please try again later."})
        if not who or not who.get("id"):
            return self.reply(401, {"error": "Please sign in again, then retry."})
        subject = clean(d.get("subject"), 120)
        body = clean_ml(d.get("body"), 1500)
        meta = {}
        if kind == "request":
            if len(subject) < 2:
                raise Bad("Please type the movie or series name.")
            typ = d.get("type") if d.get("type") in ("movie", "series", "anime", "cartoon") else "movie"
            meta = {"type": typ, "year": clean(d.get("year"), 4)}
        else:
            if len(body) < 5:
                raise Bad("Please write your message (at least a few words).")
            subject = subject or "Message from website"
        now = int(time.time())
        with LOCK:
            limit, window = (10, 86400) if kind == "request" else (5, 3600)
            n = DB.execute("SELECT COUNT(*) FROM inbox WHERE uid=? AND kind=? AND ts>?", (who["id"], kind, now - window)).fetchone()[0]
            if n >= limit:
                raise Bad("You have sent a lot already. Please wait a while before sending more.")
            dup = DB.execute("SELECT 1 FROM inbox WHERE uid=? AND kind=? AND subject=? AND body=? AND ts>?",
                             (who["id"], kind, subject, body, now - 600)).fetchone()
            if not dup:
                if DB.execute("SELECT COUNT(*) FROM inbox").fetchone()[0] >= 20000:
                    raise Bad("The inbox is full right now. Please try again later.")
                DB.execute("INSERT INTO inbox(kind,uid,email,name,subject,body,meta,ts,status) VALUES(?,?,?,?,?,?,?,?, 'new')",
                           (kind, who["id"], who["email"], who["name"], subject, body, json.dumps(meta), now))
                DB.commit()
        self.reply(200, {"ok": 1})

    def api_inbox_admin(self):
        d = self.body(2048)
        action = d.get("action")
        try:
            iid = int(d.get("id") or 0)
        except (TypeError, ValueError):
            raise Bad("Bad request")
        with LOCK:
            if action == "status" and d.get("status") in ("new", "read", "done"):
                DB.execute("UPDATE inbox SET status=? WHERE id=?", (d["status"], iid))
            elif action == "delete":
                DB.execute("DELETE FROM inbox WHERE id=?", (iid,))
            elif action == "mark-all-read":
                DB.execute("UPDATE inbox SET status='read' WHERE status='new'")
            else:
                raise Bad("Bad request")
            DB.commit()
        if action in ("delete", "mark-all-read"):
            self.note("inbox-" + action, "#%d" % iid if action == "delete" else "all")
        self.reply(200, {"ok": 1})

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
        nid, total = start_broadcast(title, text, url, only)
        self.note("push-send", "%s%s" % (title, " (test: one device)" if only else " to %d devices" % total))
        self.reply(200, {"ok": 1, "id": nid, "total": total})


def admins_list():
    with LOCK:
        rows = DB.execute("SELECT username,role,created,last_login,disabled FROM admins ORDER BY (role!='owner'), username").fetchall()
    return {"items": [{"username": r[0], "role": r[1], "created": r[2], "last_login": r[3], "disabled": bool(r[4])} for r in rows],
            "roles": [{"id": r, "label": ROLE_LABEL[r]} for r in ROLES]}


def inbox_list(raw_path):
    q = raw_path.split("?", 1)[1] if "?" in raw_path else ""
    kind = "request" if "kind=request" in q else "message" if "kind=message" in q else ""
    with LOCK:
        sql, args = "SELECT id,kind,email,name,subject,body,meta,ts,status FROM inbox", ()
        if kind:
            sql, args = sql + " WHERE kind=?", (kind,)
        rows = DB.execute(sql + " ORDER BY (status='done'), id DESC LIMIT 300", args).fetchall()
        counts = {k: DB.execute("SELECT COUNT(*) FROM inbox WHERE kind=? AND status='new'", (k,)).fetchone()[0] for k in ("request", "message")}
    items = []
    for r in rows:
        try:
            meta = json.loads(r[6] or "{}")
        except Exception:
            meta = {}
        items.append({"id": r[0], "kind": r[1], "email": r[2], "name": r[3], "subject": r[4], "body": r[5], "meta": meta, "ts": r[7], "status": r[8]})
    return {"items": items, "new_requests": counts["request"], "new_messages": counts["message"], "now": int(time.time())}


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
        inbox_new = q("SELECT COUNT(*) FROM inbox WHERE status='new'")
        series = []
        for i in range(13, -1, -1):
            d = day - i
            row = DB.execute("SELECT visits,pv FROM daily WHERE day=?", (d,)).fetchone() or (0, 0)
            series.append({"date": time.strftime("%d %b", time.gmtime(d * 86400)), "visits": row[0], "pv": row[1]})
        users_total = q("SELECT COUNT(*) FROM users")
        users = [
            {"email": r[0], "name": r[1], "first_seen": r[2], "last_seen": r[3], "visits": r[4], "online": r[3] >= live_from,
             "status": r[5] or "", "reason": r[6] or "", "signed_out_at": r[7] or 0}
            for r in DB.execute(
                "SELECT u.email,u.name,u.first_seen,u.last_seen,u.visits,f.status,f.reason,f.signout_after "
                "FROM users u LEFT JOIN user_flags f ON f.email=u.email ORDER BY u.last_seen DESC LIMIT 300")
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
        owner = DB.execute("SELECT hash FROM admins WHERE username='admin'").fetchone()
        stored = owner[0] if owner else sget("admin_hash")
        up = {k: sget(k, {}) or {} for k in ("maintenance", "popup", "announce", "access")}
    return {
        "now": now, "live": live, "watching": watching, "live_users": live_users, "live_mobile": live_mobile,
        "today_visits": today[0], "today_pv": today[1], "today_unique": today_unique,
        "total_visits": totals[0], "total_pv": totals[1], "unique_total": unique_total, "subs": subs,
        "series": series, "users_total": users_total, "users": users, "notifs": notifs,
        "live_titles": live_titles, "top_titles": top_titles,
        "maint_on": in_window(CFG.get("m", {})), "popup_on": in_window(CFG.get("p", {})),
        "maint_armed": bool(up["maintenance"].get("on")), "popup_armed": bool(up["popup"].get("on")),
        "ann_on": in_window(CFG.get("a", {})), "ann_armed": bool(up["announce"].get("on")),
        "login_required": bool(up["access"].get("login_required")),
        "default_pw": bool(INIT_HASH) and stored == INIT_HASH,
        "push_ready": PUSH_READY, "sb_sync": bool(sb_url() and sb_service_key()), "inbox_new": inbox_new,
    }


# ---------------------------------------------------------------- Supabase user sync (optional)


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
    SB_URL, SB_KEY = sb_url(), sb_service_key()
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
                uid = clean(u.get("id"), 60)
                if UID_RE.match(uid):
                    DB.execute("UPDATE users SET uid=? WHERE email=?", (uid, email))
            DB.commit()
        if len(rows) < 200:
            break
        page += 1
    return added


def sb_sync_loop():
    """Runs forever; picks up a new key/project the moment the admin saves it (no restart needed)."""
    time.sleep(5)
    while True:
        wait = 600
        try:
            if sb_url() and sb_service_key():
                n = sb_sync_users()
                if n:
                    print("supabase sync: %d new user(s)" % n, flush=True)
            else:
                wait = 120
        except Exception as exc:  # never let this affect the site
            print("supabase sync error:", repr(exc)[:200], file=sys.stderr, flush=True)
        SYNC_NOW.wait(wait)
        SYNC_NOW.clear()


if __name__ == "__main__":
    threading.Thread(target=prune_loop, daemon=True).start()
    threading.Thread(target=vm_loop, daemon=True).start()
    threading.Thread(target=sb_sync_loop, daemon=True).start()
    threading.Thread(target=sched_loop, daemon=True).start()
    threading.Thread(target=backup_loop, daemon=True).start()
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
# the public (publishable) key that ships inside the website files is the fallback until you set one in Admin > Supabase
PUBK="$(grep -o 'sb_publishable_[A-Za-z0-9_-]*' "$SRC/js/config.js" 2>/dev/null | head -n 1 || true)"
sed -i '/^PD_SUPABASE_PUB_KEY=/d' "$ENVF"; [ -n "$PUBK" ] && echo "PD_SUPABASE_PUB_KEY=$PUBK" >> "$ENVF"
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
    client_max_body_size 128k;
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
# Speed-up: gzip text files and let browsers cache images/fonts. Own file; removed again if nginx dislikes it.
cat > /etc/nginx/conf.d/publicdrop-speed.conf <<'SPEOF'
gzip on;
gzip_comp_level 5;
gzip_min_length 600;
gzip_vary on;
gzip_types text/css application/javascript text/javascript application/json image/svg+xml text/plain application/manifest+json;
SPEOF
if ! nginx -t >/dev/null 2>&1; then rm -f /etc/nginx/conf.d/publicdrop-speed.conf; echo "SPEED: nginx already compresses or rejected the extra file, so it was left out."; fi
setsebool -P httpd_can_network_connect 1 2>/dev/null || true
if nginx -t >/dev/null 2>&1; then
  systemctl reload nginx
else
  echo "nginx config test failed. Removing the new nginx snippet so your site keeps working."
  rm -f /etc/nginx/default.d/publicdrop-pd.conf
  nginx -t || true
  systemctl reload nginx 2>/dev/null || true
fi

if [ -n "${PD_SB_TOKEN:-}" ]; then
  say "Updating Supabase sign-in settings (no confirmation e-mail, redirect URLs, Google)"
  PD_SB_REF="${SB_URL#https://}"; PD_SB_REF="${PD_SB_REF%%.*}"
  PD_SQL_FILE=""; for c in "$SELF_DIR/supabase-setup.sql" "$PWD/supabase-setup.sql"; do [ -s "$c" ] && PD_SQL_FILE="$c" && break; done
  PD_SQL_FILE="$PD_SQL_FILE" PD_SB_REF="$PD_SB_REF" PD_SITE="https://$DOMAIN" python3 - <<'PYSB' || echo "SUPABASE: skipped (the site itself is fine). Do it by hand: Authentication > Sign In / Providers > Email > turn OFF Confirm email."
import json, os, sys, urllib.request, urllib.error

ref, tok, site = os.environ["PD_SB_REF"], os.environ["PD_SB_TOKEN"], os.environ["PD_SITE"]
url = "https://api.supabase.com/v1/projects/%s/config/auth" % ref
hdr = {"Authorization": "Bearer " + tok, "Content-Type": "application/json", "User-Agent": "publicdrop-installer"}

def call(method, body=None):
    req = urllib.request.Request(url, data=json.dumps(body).encode() if body is not None else None, headers=hdr, method=method)
    with urllib.request.urlopen(req, timeout=25) as r:
        return json.loads(r.read().decode() or "{}")

try:
    cur = call("GET")
except urllib.error.HTTPError as e:
    sys.exit("SUPABASE: token was refused (HTTP %s). Check the access token." % e.code)
patch = {"mailer_autoconfirm": True}
allow = [x.strip() for x in str(cur.get("uri_allow_list") or "").split(",") if x.strip()]
for u in (site, site + "/**", site.replace("https://", "https://www.") , site.replace("https://", "https://www.") + "/**"):
    if u not in allow:
        allow.append(u)
patch["uri_allow_list"] = ",".join(allow)
if not cur.get("site_url") or "localhost" in str(cur.get("site_url")):
    patch["site_url"] = site
gid, gsec = os.environ.get("PD_GOOGLE_CLIENT_ID", "").strip(), os.environ.get("PD_GOOGLE_CLIENT_SECRET", "").strip()
if gid and gsec:
    patch.update({"external_google_enabled": True, "external_google_client_id": gid, "external_google_secret": gsec})
call("PATCH", patch)
sql_path = os.environ.get("PD_SQL_FILE", "")
if sql_path and os.path.isfile(sql_path):
    try:
        q = urllib.request.Request("https://api.supabase.com/v1/projects/%s/database/query" % ref,
                                   data=json.dumps({"query": open(sql_path, encoding="utf-8").read()}).encode(), headers=hdr, method="POST")
        urllib.request.urlopen(q, timeout=60).read()
        print("SUPABASE: supabase-setup.sql was run (accounts activate instantly, cloud tables ready).")
    except Exception as exc:
        print("SUPABASE: could not run supabase-setup.sql automatically (%s). Paste it into the SQL Editor by hand." % exc)
print("SUPABASE: confirmation e-mail is now OFF; redirect URLs saved" + ("; Google sign-in is ON." if gid and gsec else "."))
if not (gid and gsec):
    print("SUPABASE: Google keys not given, so Google sign-in was left as it is (see the note at the end).")
PYSB
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
echo " Login (do these once in Supabase, unless you gave PD_SB_TOKEN above):"
echo "   1. SQL Editor: run supabase-setup.sql        (activates accounts instantly + cloud sync tables)"
echo "   2. Authentication > Sign In / Providers > Email: turn OFF 'Confirm email'   (= no confirmation mail)"
echo "   3. Authentication > URL Configuration: Site URL https://$DOMAIN and add https://$DOMAIN/** to Redirect URLs"
echo "   4. Google: Authentication > Sign In / Providers > Google: ON + paste Client ID & Secret"
echo "      (Google Cloud > OAuth client > Authorized redirect URI: $SB_URL/auth/v1/callback)"
echo " Admin > Team   : add moderators / admins. Your existing password is the owner account: username admin."
echo " Admin > Controls : announcement bar, login-required-to-watch, and start/end times for popup + maintenance."
echo " Admin > Database : download backups (the server also keeps 7 daily copies in its data folder)."
echo " Admin > API keys : add a second TMDB key. The site then switches between the two by itself when one is slow or down."
echo " Admin > Database : set the Supabase Project ID, Publishable key and Secret key right in the admin panel."
echo "                    (stored on the server, so a key change never needs a file edit or re-install)"
echo " Admin > Inbox    : movie requests and messages sent by signed-in visitors."
echo " Admin Users tab: shows people as they sign in. To list everyone already registered, paste the Secret key in"
echo "     Admin > Database   (or, the old way:  sudo pd-set-supabase-key 'YOUR_SECRET_KEY')"
echo " Install as app: open https://$DOMAIN on a phone or in Chrome, then tap Install."
echo " Forgot the password?  sudo pd-reset-password 'NewPassword123'"
echo " Backups of the old site: $BK"
echo "=============================================="
