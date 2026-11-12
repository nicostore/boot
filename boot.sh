#!/usr/bin/env bash
# =====================================================================
# boot.sh — VPS baru dalam satu perintah (gaya install hermes, tapi RESTORE)
#
#   bash <(curl -fsSL https://gist.githubusercontent.com/nicostore/<ID>/raw/boot.sh)
#
# Alur: pilih mode (hermes+xrouter / root / keduanya) -> pilih sumber archive
#       (login Google sekali = privat tanpa share, atau tempel link Drive)
#       -> sistem disiapkan (apt, rclone, hermes) -> archive diunduh
#       -> restore -> tool + jadwal backup.
#
# Non-interaktif:
#   bash boot.sh --mode both   --source login
#   bash boot.sh --mode hermes --link "https://drive.google.com/file/d/<ID>/view"
#   bash boot.sh --pass 'passku'          # set password root + izinkan ssh password
#   bash boot.sh --selftest               # uji parser, tidak mengubah sistem
# =====================================================================
set -euo pipefail
export TZ=Asia/Jakarta
export HOME="${HOME:-/root}"
export DEBIAN_FRONTEND=noninteractive
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# OAuth app: dipakai untuk login device-flow kalau rclone.conf belum ada.
RCLONE_CONF="${RCLONE_CONF:-/root/.config/rclone/rclone.conf}"
CLIENT_ID="${RCLONE_CLIENT_ID:-134267350051-n9s5vof5287npgq09ou8hq1uo30tsi4e.apps.googleusercontent.com}"
CLIENT_SECRET="${RCLONE_CLIENT_SECRET:-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}"
SCOPE="https://www.googleapis.com/auth/drive.file"
HOURLY_DIR="hermes-backups"

MODE=""; SOURCE=""; LINK=""; LINK2=""; ROOT_PASS=""
DO_UPGRADE=1; DO_APT=1; DO_TOOLS=1; DO_CRON=1; TMP_ARCH="/root"

say()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[X]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- parser link Drive
drive_id() { # cetak ID untuk link Google Drive / ID mentah; gagal -> exit 1
  local s="$1"
  case "$s" in
    *drive.google.com/file/d/*) s="${s#*file/d/}"; printf '%s' "${s%%/*}"; return 0 ;;
    *id=*)                      s="${s#*id=}";      printf '%s' "${s%%&*}";  return 0 ;;
    *drive.usercontent.google.com/download/*) s="${s#*download/}"; printf '%s' "${s%%/*}"; return 0 ;;
  esac
  if printf '%s' "$s" | grep -Eq '^[A-Za-z0-9_-]{20,}$'; then printf '%s' "$s"; return 0; fi
  return 1
}
is_url() { printf '%s' "$1" | grep -Eq '^https?://'; }

selftest() {
  local id
  id="$(drive_id 'https://drive.google.com/file/d/1AbCdEfGhIjKlMnOpQrStUvWxYz1234567/view?usp=drive_link')"
  [ "$id" = "1AbCdEfGhIjKlMnOpQrStUvWxYz1234567" ] || die "selftest: file/d/ gagal"
  id="$(drive_id 'https://drive.google.com/open?id=1AbCdEfGhIjKlMnOpQrStUvWxYz1234567')"
  [ "$id" = "1AbCdEfGhIjKlMnOpQrStUvWxYz1234567" ] || die "selftest: open?id= gagal"
  id="$(drive_id 'https://drive.google.com/uc?export=download&id=1AbCdEfGhIjKlMnOpQrStUvWxYz1234567')"
  [ "$id" = "1AbCdEfGhIjKlMnOpQrStUvWxYz1234567" ] || die "selftest: id= gagal"
  id="$(drive_id '1AbCdEfGhIjKlMnOpQrStUvWxYz1234567')"
  [ "$id" = "1AbCdEfGhIjKlMnOpQrStUvWxYz1234567" ] || die "selftest: ID mentah gagal"
  drive_id 'https://example.com/archive.tar.gz' && die "selftest: URL biasa harus ditolak"
  echo "boot.sh selftest OK (parser link Drive)"
}

# ---------------------------------------------------------------- argumen
while [ $# -gt 0 ]; do
  case "$1" in
    --mode)   MODE="${2:-}";   shift 2 ;;
    --source) SOURCE="${2:-}"; shift 2 ;;
    --link)   LINK="${2:-}"; SOURCE="link"; shift 2 ;;
    --pass)   ROOT_PASS="${2:-}"; shift 2 ;;
    --dest)   TMP_ARCH="${2:-/root}"; shift 2 ;;
    --no-upgrade) DO_UPGRADE=0; shift ;;
    --no-apt)     DO_APT=0; shift ;;
    --no-tools)   DO_TOOLS=0; shift ;;
    --no-cron)    DO_CRON=0; shift ;;
    --selftest) selftest; exit 0 ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "argumen tak dikenal: $1 (pakai --help)" ;;
  esac
done

[ "$(id -u)" = "0" ] || die "jalankan sebagai root"

# `curl ... | bash` memakai stdin untuk script -> menu tak bisa baca input.
if [ ! -t 0 ] && [ -z "$MODE" ] && [ -z "$LINK" ]; then
  exec </dev/tty 2>/dev/null || die "tidak bisa baca input. Pakai: bash <(curl -fsSL <url>)  — atau: --mode … --source login"
fi

# ---------------------------------------------------------------- menu
if [ -z "$MODE" ]; then
  cat <<'BANNER'

  ==============================================
   RESTORE VPS BARU   (hermes + xrouter / root)
  ==============================================
   1) Hermes + xrouter
   2) /root saja
   3) Keduanya   (paling sering dipakai)
   9) Keluar
BANNER
  printf '  Pilih [1/2/3/9]: '; read -r c
  case "$c" in
    1) MODE="hermes" ;; 2) MODE="root" ;; 3) MODE="both" ;; *) echo "batal."; exit 0 ;;
  esac
fi
case "$MODE" in hermes|root|both) ;; *) die "mode tidak valid: $MODE" ;; esac

if [ -z "$SOURCE" ]; then
  cat <<'BANNER'

   Sumber archive:
    1) Login Google sekali   (privat, tanpa share file — disarankan)
    2) Tempel link Drive     (file harus di-share "anyone with the link")
    3) Batalkan
BANNER
  printf '  Pilih [1/2/3]: '; read -r s
  case "$s" in 1) SOURCE="login" ;; 2) SOURCE="link" ;; *) echo "batal."; exit 0 ;; esac
fi

if [ "$SOURCE" = "link" ] && [ -z "$LINK" ]; then
  printf '  Tempel link/ID archive: '; read -r LINK
  [ -n "$LINK" ] || die "link kosong"
fi

if [ -z "$ROOT_PASS" ] && [ -t 0 ]; then
  printf '  Password root baru (kosongkan kalau tidak mau ubah): '; read -r -s ROOT_PASS; echo
fi
say "mode=$MODE  sumber=$SOURCE"

# ---------------------------------------------------------------- 1. sistem
if [ "$DO_APT" = "1" ]; then
  say "apt update + paket dasar"
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates unzip git jq sqlite3 python3 python3-pip \
          openssh-client tmux >/dev/null
  if [ "$DO_UPGRADE" = "1" ]; then say "apt upgrade"; apt-get upgrade -y -qq >/dev/null; fi
fi

if [ -n "$ROOT_PASS" ]; then
  say "set password root + izinkan login ssh pakai password"
  echo "root:${ROOT_PASS}" | chpasswd
  sed -i -E 's/^#?PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config
  sed -i -E 's/^#?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
fi

if ! command -v rclone >/dev/null; then
  say "install rclone"
  curl -fsSL https://rclone.org/install.sh -o /tmp/rclone-install.sh
  bash /tmp/rclone-install.sh >/dev/null    # WAJIB bash, bukan sh (dash: Syntax error)
fi

if [ "$MODE" != "root" ] && ! command -v hermes >/dev/null; then
  say "install Hermes"
  curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
fi

# ---------------------------------------------------------------- 2. sumber archive
login_google() { # device flow: user buka link + masukkan kode, tidak perlu paste apa pun
  local resp dcode ucode vurl interval tok rt at exp err
  say "login Google — buka link di bawah, masukkan kode, setujui"
  mkdir -p "$(dirname "$RCLONE_CONF")"; chmod 700 "$(dirname "$RCLONE_CONF")"
  resp="$(curl -s -X POST https://oauth2.googleapis.com/device/code -d client_id="$CLIENT_ID" -d scope="$SCOPE")"
  dcode="$(printf '%s' "$resp" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("device_code",""))' 2>/dev/null || true)"
  ucode="$(printf '%s' "$resp" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("user_code",""))' 2>/dev/null || true)"
  vurl="$(printf '%s'  "$resp" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("verification_url","https://www.google.com/device"))' 2>/dev/null || true)"
  interval="$(printf '%s' "$resp" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("interval",5))' 2>/dev/null || echo 5)"
  [ -n "$dcode" ] && [ -n "$ucode" ] || die "gagal minta device code ke Google: $resp"
  printf '\n   BUKA : %s\n   KODE : %s\n\n' "${vurl:-https://www.google.com/device}" "$ucode"
  while :; do
    sleep "$((interval + 1))"
    tok="$(curl -s -X POST https://oauth2.googleapis.com/token \
           -d client_id="$CLIENT_ID" -d client_secret="$CLIENT_SECRET" \
           -d device_code="$dcode" -d grant_type=urn:ietf:params:oauth:grant-type:device_code)"
    rt="$(printf '%s' "$tok" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("refresh_token",""))' 2>/dev/null || true)"
    at="$(printf '%s' "$tok" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null || true)"
    if [ -n "$rt" ] && [ -n "$at" ]; then
      exp="$(printf '%s' "$tok" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("expires_in",3600))' 2>/dev/null || echo 3600)"
      python3 - "$RCLONE_CONF" "$CLIENT_ID" "$CLIENT_SECRET" "$rt" "$at" "$exp" <<'PY'
import json, sys, datetime
conf, cid, csec, rt, at, exp = sys.argv[1:7]
token = {"access_token": at, "token_type": "Bearer", "refresh_token": rt,
         "expiry": (datetime.datetime.utcnow() + datetime.timedelta(seconds=int(exp) - 60)).isoformat() + "Z"}
open(conf, "w").write("[gdrive]\ntype = drive\nscope = drive.file\nclient_id = %s\nclient_secret = %s\ntoken = %s\n"
                       % (cid, csec, json.dumps(token)))
PY
      chmod 600 "$RCLONE_CONF"
      echo "   login OK -> $RCLONE_CONF"
      return 0
    fi
    err="$(printf '%s' "$tok" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("error",""))' 2>/dev/null || true)"
    case "$err" in
      authorization_pending|slow_down|"") printf '   menunggu persetujuan...\n' ;;
      access_denied) die "login ditolak di browser" ;;
      expired_token) die "kode kedaluwarsa — jalankan ulang" ;;
      *) die "login gagal ($err). Kalau ini VPS baru, pakai opsi 2 (tempel link) atau login rclone manual." ;;
    esac
  done
}

pull_via_rclone() { # $1 = pola nama archive
  local pat="$1"
  say "unduh archive dari Drive: $pat"
  rclone --config "$RCLONE_CONF" copy "gdrive:$HOURLY_DIR/" "$TMP_ARCH/" \
      --include "$pat" --include "${pat%.tar.gz}.sha256" --stats-one-line 2>&1 | tail -2
}

pull_via_link() { # $1 = link/URL
  local link="$1" id
  if id="$(drive_id "$link")"; then
    command -v gdown >/dev/null || { pip3 install -q --break-system-packages gdown 2>/dev/null || pip3 install -q gdown; }
    ( cd "$TMP_ARCH" && gdown -q "$id" ) || die "gdown gagal — file harus di-share 'anyone with the link'"
  elif is_url "$link"; then
    ( cd "$TMP_ARCH" && curl -fL --retry 3 -O "$link" )
  else
    die "link tidak dikenali: $link"
  fi
}

mkdir -p "$TMP_ARCH"
need_hermes=0; need_root=0
{ [ "$MODE" = "hermes" ] || [ "$MODE" = "both" ]; } && need_hermes=1
{ [ "$MODE" = "root" ]   || [ "$MODE" = "both" ]; } && need_root=1

if [ "$SOURCE" = "login" ]; then
  if [ ! -s "$RCLONE_CONF" ] || ! rclone --config "$RCLONE_CONF" lsf "gdrive:$HOURLY_DIR/" >/dev/null 2>&1; then
    login_google
  fi
  say "isi folder Drive:"; rclone --config "$RCLONE_CONF" lsf "gdrive:$HOURLY_DIR/" | sed 's/^/   /'
  [ "$need_hermes" = "1" ] && pull_via_rclone 'hermes-backup-*.tar.gz'
  [ "$need_root" = "1" ]   && pull_via_rclone 'root-backup-*.tar.gz'
else
  say "unduh via link"
  if [ "$need_hermes" = "1" ]; then pull_via_link "$LINK"; fi
  if [ "$need_root" = "1" ]; then
    if [ "$MODE" = "both" ] && [ -t 0 ]; then printf '  Tempel link archive root: '; read -r LINK2; else LINK2="$LINK"; fi
    [ -n "$LINK2" ] || die "link root kosong"
    pull_via_link "$LINK2"
  fi
fi

H_ARCH="$(ls -1t "$TMP_ARCH"/hermes-backup-*.tar.gz 2>/dev/null | head -1 || true)"
R_ARCH="$(ls -1t "$TMP_ARCH"/root-backup-*.tar.gz   2>/dev/null | head -1 || true)"
if [ "$need_hermes" = "1" ]; then [ -n "$H_ARCH" ] || die "archive hermes tidak ada di $TMP_ARCH"; fi
if [ "$need_root" = "1" ];   then [ -n "$R_ARCH" ] || die "archive root tidak ada di $TMP_ARCH"; fi

# ---------------------------------------------------------------- 3. restore
if [ -n "$H_ARCH" ]; then
  say "restore HERMES + xrouter: $(basename "$H_ARCH") ($(du -h "$H_ARCH" | cut -f1))"
  cd "$TMP_ARCH"; tar -xzf "$H_ARCH" restore.sh
  bash restore.sh "$H_ARCH"
fi
if [ -n "$R_ARCH" ]; then
  say "restore ROOT: $(basename "$R_ARCH") ($(du -h "$R_ARCH" | cut -f1))"
  if [ -f /root/hermes-backup/restore.sh ]; then
    bash /root/hermes-backup/restore.sh "$R_ARCH"
  else
    tar -xzf "$R_ARCH" -C /
    echo "ROOT_RESTORE_OK $(basename "$R_ARCH")"
  fi
fi

# ---------------------------------------------------------------- 4. tool + jadwal
if [ "$DO_TOOLS" = "1" ] && [ -f /root/hermes-backup/setup-tools.sh ]; then
  say "pasang tool pendukung (nvm/node, python, chrome, camoufox, venv, node_modules)"
  bash /root/hermes-backup/setup-tools.sh || warn "ada bagian setup-tools.sh yang gagal — cek /root/hermes-backup/setup-tools.log"
fi

if [ "$DO_CRON" = "1" ] && [ -f /root/hermes-backup/crontab.txt ]; then
  say "hidupkan jadwal backup (hanya baris yang targetnya ada)"
  TMPCRON="$(mktemp)"; echo "TZ=Asia/Jakarta" > "$TMPCRON"
  while IFS= read -r line; do
    case "$line" in ''|'#'*|'TZ='*) continue ;; esac
    target="$(printf '%s' "$line" | sed -E 's/^([^ ]+ +){5}//; s/^(cd [^ ]+ && )?//; s/ .*//')"
    case "$target" in
      /root/*) if [ -e "$target" ]; then echo "$line" >> "$TMPCRON"; else warn "dilewati (target hilang): $target"; fi ;;
      *) echo "$line" >> "$TMPCRON" ;;
    esac
  done < /root/hermes-backup/crontab.txt
  crontab "$TMPCRON" && echo "   crontab dipasang ($(grep -c '' "$TMPCRON") baris)"
  rm -f "$TMPCRON"
fi

cat <<EOF

=====================================================================
 SELESAI
   mode          : $MODE  (sumber: $SOURCE)
   archive hermes: ${H_ARCH:-tidak dipakai}
   archive root  : ${R_ARCH:-tidak dipakai}
   hermes        : $(command -v hermes >/dev/null && echo terpasang || echo 'BELUM: curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash')
   gateway       : systemctl status hermes-gateway   /   systemctl --user status hermes-gateway
   log backup    : tail -f /root/hermes-backup/backup.log
   kurang tool?  : bash /root/hermes-backup/setup-tools.sh
   hapus archive : rm -f /root/{hermes,root}-backup-*.tar.gz
=====================================================================
EOF
