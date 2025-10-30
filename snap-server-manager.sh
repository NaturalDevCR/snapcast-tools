#!/bin/bash
# ==============================================================================
# SNAPSTREAM MANAGER v2025.10.52 (Merged and Improved Build)
# Snapserver + FFmpeg Streams + Snapweb + JSON-RPC + Backups + LXC-aware
# Installation from .deb, datadir/configdir fix, watchdog, and silent fallback.
# Author: Josue / GPT-5 / Gemini — “No bullshit” build.
# Status: ALPHA state, be careful when using this script, something might just not work!
# ==============================================================================

set -Eeuo pipefail

# --- Privilege Check ---
if [[ $EUID -ne 0 ]]; then
   echo "❌ This script must be run as root."
   exit 1
fi

# --- Global Variables ---
SNAP_FIFO_DIR="/var/lib/snapserver/fifo"
SYSTEMD_DIR="/etc/systemd/system"
CONF_FILE="/etc/snapserver.conf"
BACKUP_DIR="/etc/snapserver.d/backups"
CACHE_DIR="/var/cache/snapstream"
SNAP_USER="snapserver"
SNAP_GROUP="snapserver"
DEFAULT_GROUP="Default"
SNAP_RPC="http://127.0.0.1:1780/jsonrpc"

# --- Variables for Silent Fallback (integrated) ---
SILENCE_FIFO="$SNAP_FIFO_DIR/silence.fifo"
SILENCE_SERVICE="$SYSTEMD_DIR/snap-silence.service"

mkdir -p "$BACKUP_DIR" "$CACHE_DIR"

# --- Utility Functions ---
pause(){ read -rp "Press Enter to continue..."; }
ts(){ date +"%Y-%m-%d_%H-%M-%S"; }
escape_sed(){ sed -e 's/[\/&]/\\&/g' <<<"$1"; }

# --- Rollback in case of error ---
rollback(){
  echo "⚠️  ERROR: executing ROLLBACK…"
  if systemctl list-unit-files | grep -q snapserver.service; then
    systemctl stop snapserver 2>/dev/null || true
  fi
  if [ -f "$BACKUP_DIR/snapserver_prev.deb" ]; then
    echo "↩️  Restoring previous package…"
    dpkg -i "$BACKUP_DIR/snapserver_prev.deb" || true
  else
    echo "ℹ️  No previous snapserver package found. Nothing to restore."
  fi
  if [ -f "$BACKUP_DIR/snapserver.conf.prev" ]; then
    echo "↩️  Restoring previous configuration…"
    cp -f "$BACKUP_DIR/snapserver.conf.prev" "$CONF_FILE"
  fi
  systemctl daemon-reload || true
  if systemctl list-unit-files | grep -q snapserver.service; then
    systemctl restart snapserver || true
  fi
  echo "✅ Rollback complete."
  exit 1
}
trap rollback ERR

# ────────────────────────────────────────────────────────────────────────────
# LXC Detection and Help
# ────────────────────────────────────────────────────────────────────────────
detect_lxc(){
  if grep -qa container=lxc /proc/1/environ 2>/dev/null; then
    LXC_MODE=1
  else
    LXC_MODE=0
  fi
}
lxc_instructions(){
  local use_hw
  echo ""
  echo "─────────────────────────────────────────────"
  echo "   🧠 RUNNING IN LXC CONTAINER DETECTED"
  echo "─────────────────────────────────────────────"
  echo "Snapserver can run in two modes:"
  echo " 1) 🟢 Orchestration only (typical) → Does NOT require /dev/snd"
  echo " 2) 🎤 Local capture (ALSA in the CT) → Requires /dev/snd"
  echo "─────────────────────────────────────────────"
  read -rp "Are you going to capture audio from local hardware in this container? (y/N): " use_hw
  echo ""
  if [[ "$use_hw" =~ ^[Yy]$ ]]; then
    echo "⚙️ Enable /dev/snd on the Proxmox host (replace <ID>):"
    echo "  pct stop <ID>"
    echo "  echo \"lxc.cgroup2.devices.allow = c 116:* rwm\" >> /etc/pve/lxc/<ID>.conf"
    echo "  echo \"lxc.mount.entry = /dev/snd dev/snd none bind,optional,create=dir\" >> /etc/pve/lxc/<ID>.conf"
    echo "  pct start <ID>"
    echo "If the CT is unprivileged: pct set <ID> -features nesting=1,mount=1"
    echo "Then, inside the container: systemctl restart snapserver"
  else
    echo "🟢 Staying in pure server mode. No /dev/snd."
  fi
  echo ""
  pause
}

# ────────────────────────────────────────────────────────────────────────────
# Secure installation, pre-checks, and configuration
# ────────────────────────────────────────────────────────────────────────────
needs_install(){
  if ! command -v ffmpeg >/dev/null 2>&1; then return 0; fi
  if ! command -v snapserver >/dev/null 2>&1; then return 0; fi
  if ! id -u "$SNAP_USER" >/dev/null 2>&1; then return 0; fi
  return 1
}

confirm_actions(){
  local ARCH CODENAME SNAPVER RELEASE_API ans
  ARCH="$(dpkg --print-architecture)"
  CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-unknown}")"

  echo ""
  echo "════════════════════════════════════════════════════"
  echo "🧩 SUMMARY OF ACTIONS TO BE PERFORMED"
  echo "════════════════════════════════════════════════════"
  echo "🧠 System detected:"
  echo "  • OS: $CODENAME"
  echo "  • Architecture: $ARCH"
  RELEASE_API="https://api.github.com/repos/badaix/snapcast/releases/latest"
  SNAPVER="$(curl -s --max-time 10 "$RELEASE_API" | jq -r '.tag_name // empty' || true)"
  [ -n "$SNAPVER" ] && echo "  • Latest Snapcast version on GitHub: $SNAPVER"
  echo ""
  echo "Actions:"
  if ! command -v ffmpeg >/dev/null 2>&1; then echo "  - 📦 Install FFmpeg"; else echo "  - ✅ FFmpeg already installed"; fi
  if ! command -v snapserver >/dev/null 2>&1; then echo "  - ⬇️ Install Snapserver (official .deb from GitHub)"; else echo "  - ✅ Snapserver already installed"; fi
  if ! id -u "$SNAP_USER" >/dev/null 2>&1; then echo "  - 👤 Create user '${SNAP_USER}'"; else echo "  - ✅ User '${SNAP_USER}' already exists"; fi
  echo ""
  echo "════════════════════════════════════════════════════"
  read -rp "Do you wish to continue? (y/N): " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "❌ Canceled by user."; exit 0; }
  echo ""
}

fix_snapserver_unit(){
  local SERVICE_FILE="/usr/lib/systemd/system/snapserver.service"
  [ -f "$SERVICE_FILE" ] || return 0

  echo "🩹 Adjusting Snapserver unit (datadir/configdir/http)…"
  sed -i 's|--server.datadir=${HOME}|--server.datadir=/var/lib/snapserver|g' "$SERVICE_FILE"
  if ! grep -q -- '--server.configdir=' "$SERVICE_FILE"; then
    sed -i 's|ExecStart=.*|& --server.configdir=/var/lib/snapserver/config|' "$SERVICE_FILE"
  fi
  if ! grep -q -- '--http-port' "$SERVICE_FILE"; then
    sed -i 's|ExecStart=.*|& --http-port 1780|' "$SERVICE_FILE"
  fi
  if [ -d "/usr/share/snapserver/snapweb" ] && ! grep -q -- '--http-doc-root' "$SERVICE_FILE"; then
    sed -i 's|ExecStart=.*|& --http-doc-root=/usr/share/snapserver/snapweb|' "$SERVICE_FILE"
  fi

  mkdir -p /var/lib/snapserver/config "$SNAP_FIFO_DIR"
  chown -R "$SNAP_USER:$SNAP_GROUP" /var/lib/snapserver

  systemctl daemon-reload
  systemctl reset-failed snapserver.service 2>/dev/null || true
  systemctl restart snapserver.service || true
  
  echo "✅ Unit adjusted. datadir=/var/lib/snapserver, configdir=/var/lib/snapserver/config, http-port=1780"
}

monitor_snapserver(){
  echo ""
  echo "🔎 Checking Snapserver status..."
  # Detect service existence more reliably
  if ! systemctl status snapserver &>/dev/null; then
    echo "❌ snapserver.service not found or not recognized by systemd."
    echo ""
    pause
    return
  fi

  local status
  status="$(systemctl is-active snapserver 2>/dev/null || echo unknown)"

  case "$status" in
    active)
      echo "🟢 Snapserver is active."
      ;;
    activating|reloading|starting)
      echo "🔄 Snapserver is starting..."
      ;;
    failed|inactive)
      echo "🚨 Snapserver is stopped/failing. Attempting recovery…"
      if grep -q '\--server\.datadir=\${HOME}' /usr/lib/systemd/system/snapserver.service 2>/dev/null \
         || journalctl -u snapserver -n 50 --no-pager 2>/dev/null | grep -q "/home/snapserver"; then
        fix_snapserver_unit
        echo "🔁 Retrying start…"
        systemctl restart snapserver || true
        sleep 1
      fi

      if systemctl is-active snapserver &>/dev/null; then
        echo "✅ Automatically recovered."
      else
        echo "❌ Still failing. Check logs:"
        echo "   journalctl -u snapserver -n 80 --no-pager"
      fi
      ;;
    *)
      echo "❓ Unknown status: $status"
      ;;
  esac
  echo ""
  pause
}

install_prereqs(){
  echo "🔍 Checking/installing prerequisites…"
  apt-get update -y
  apt-get install -y ffmpeg curl jq

  id -u "$SNAP_USER" >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin "$SNAP_USER"
  [ -f "$CACHE_DIR/snapserver_current.deb" ] && cp -f "$CACHE_DIR/snapserver_current.deb" "$BACKUP_DIR/snapserver_prev.deb" || true
  [ -f "$CONF_FILE" ] && cp -f "$CONF_FILE" "$BACKUP_DIR/snapserver.conf.prev" || true

  local ARCH CODENAME RELEASE_API SNAPVER PACKAGE_URL FILENAME
  ARCH="$(dpkg --print-architecture)"
  CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-unknown}")"
  RELEASE_API="https://api.github.com/repos/badaix/snapcast/releases/latest"

  echo "⬇️ Searching for the latest release…"
  SNAPVER="$(curl -s "$RELEASE_API" | jq -r '.tag_name')"
  [ -z "$SNAPVER" ] && { echo "❌ Could not get version."; exit 1; }
  echo "📌 Version: $SNAPVER"

  PACKAGE_URL="$(curl -s "$RELEASE_API" | jq -r '
    .assets[] | select(.name | test("_with-pipewire") | not)
    | select(.name | test("snapserver_.*_'"$ARCH"'_'"$CODENAME"'\\.deb$"))
    | .browser_download_url
  ' | head -n1)"

  if [ -z "$PACKAGE_URL" ] || [ "$PACKAGE_URL" = "null" ]; then
    echo "⚠️ Searching for fallback to bookworm…"
    PACKAGE_URL="$(curl -s "$RELEASE_API" | jq -r '
      .assets[] | select(.name | test("_with-pipewire") | not)
      | select(.name | test("snapserver_.*_'"$ARCH"'_bookworm\\.deb$"))
      | .browser_download_url
    ' | head -n1)"
  fi

  [ -z "$PACKAGE_URL" ] && { echo "❌ No compatible package found."; exit 1; }

  FILENAME="/tmp/$(basename "$PACKAGE_URL")"
  echo "📦 Downloading:"
  echo "   $PACKAGE_URL"
  echo "   to $FILENAME"
  curl -L -o "$FILENAME" "$PACKAGE_URL"

  echo "📦 Installing..."
  dpkg -i "$FILENAME" || apt-get -f install -y
  cp -f "$FILENAME" "$CACHE_DIR/snapserver_current.deb" || true

  mkdir -p "$SNAP_FIFO_DIR" /var/lib/snapserver/config
  chown -R "$SNAP_USER:$SNAP_GROUP" /var/lib/snapserver
  [ -f "$CONF_FILE" ] || echo "[stream]" > "$CONF_FILE"

  systemctl daemon-reload
  systemctl enable snapserver
  systemctl restart snapserver || true
  echo "✅ Snapserver installed (or updated)."
  fix_snapserver_unit
}

ensure_prereqs(){
  if needs_install; then
    confirm_actions
    install_prereqs
  else
    echo "✅ Dependencies already satisfied. Skipping installation."
    sleep 1
  fi
}

# ────────────────────────────────────────────────────────────────────────────
# Automatic Silent Fallback
# ────────────────────────────────────────────────────────────────────────────
ensure_silence_fallback(){
  echo ""
  echo "🔈 Verifying silent fallback (snap-silence.service)..."

  # ────────────────────────────────────────────────
  # 🩹 Fix user home if misconfigured (common LXC bug)
  # ────────────────────────────────────────────────
  local snap_home
  snap_home="$(getent passwd "$SNAP_USER" | cut -d: -f6)"
  if [ "$snap_home" != "/var/lib/snapserver" ]; then
    echo "🩹 Fixing home directory for user '$SNAP_USER' → /var/lib/snapserver"
    usermod -d /var/lib/snapserver "$SNAP_USER" 2>/dev/null || true
    mkdir -p /var/lib/snapserver
    chown -R "$SNAP_USER:$SNAP_GROUP" /var/lib/snapserver
  fi

  # ────────────────────────────────────────────────
  # 🧱 Ensure FIFO exists and permissions are correct
  # ────────────────────────────────────────────────
  mkdir -p "$SNAP_FIFO_DIR"
  if [ ! -p "$SILENCE_FIFO" ]; then
    echo "🪄 Creating FIFO at $SILENCE_FIFO..."
    mkfifo "$SILENCE_FIFO"
  fi
  chown "$SNAP_USER:$SNAP_GROUP" "$SILENCE_FIFO"
  chmod 666 "$SILENCE_FIFO"

  # ────────────────────────────────────────────────
  # 🪄 Create or repair service
  # ────────────────────────────────────────────────
  if [ ! -f "$SILENCE_SERVICE" ]; then
    echo "🪄 Creating snap-silence.service..."
  else
    echo "🩹 Rewriting snap-silence.service (ensuring compatibility)..."
  fi

  cat > "$SILENCE_SERVICE" <<EOF
[Unit]
Description=Snapcast Persistent Silence (anullsrc)
After=snapserver.service
Requires=snapserver.service

[Service]
ExecStart=/bin/bash -c '/usr/bin/ffmpeg -hide_banner -nostats -loglevel error -f lavfi -i anullsrc=r=48000:cl=stereo -f wav pipe:1 > $SILENCE_FIFO'
Restart=always
RestartSec=3
User=$SNAP_USER
Group=$SNAP_GROUP

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now snap-silence.service

  # ────────────────────────────────────────────────
  # 🔍 Autotest: verify if it started correctly
  # ────────────────────────────────────────────────
  sleep 1
  if ! systemctl is-active --quiet snap-silence.service; then
    echo "⚠️ snap-silence.service failed to start, retrying permissions..."
    chown "$SNAP_USER:$SNAP_GROUP" "$SILENCE_FIFO"
    chmod 666 "$SILENCE_FIFO"
    systemctl restart snap-silence.service
    sleep 1
  fi

  if systemctl is-active --quiet snap-silence.service; then
    echo "✅ snap-silence.service is active and running."
  else
    echo "❌ snap-silence.service is still failing. Check logs with:"
    echo "   journalctl -u snap-silence -n 50 --no-pager"
  fi
  echo ""
}


# ────────────────────────────────────────────────────────────────────────────
# JSON-RPC: Client Management
# ────────────────────────────────────────────────────────────────────────────
rpc(){ curl -s -H 'Content-Type: application/json' -X POST "$SNAP_RPC" -d "$1"; }
rpc_status(){ rpc '{"id":1,"jsonrpc":"2.0","method":"Server.GetStatus"}'; }

list_clients(){
  echo ""
  echo "👥 Connected clients:"
  rpc_status | jq -r '.result.server.clients[]? | "  • \(.id) | \(.host.name) | \(.config.name)"' || echo "❌ No clients or server is not responding."
  echo ""
  pause
}

auto_name_clients_from_hostname(){
  echo ""
  echo "✏️ Auto-naming clients using their hostname..."
  local js ids id host name
  js="$(rpc_status || true)"
  [ -z "$js" ] && { echo "❌ JSON-RPC not available."; pause; return; }
  ids=($(echo "$js" | jq -r '.result.server.clients[].id'))
  for id in "${ids[@]}"; do
    host="$(echo "$js" | jq -r ".result.server.clients[] | select(.id==\"$id\") | (.host.name // .host.address // \"client\")")"
    name="${host%%.*}"
    [ -z "$name" ] && name="client-$id"
    rpc "$(jq -n --arg id "$id" --arg name "$name" '{id:2,"jsonrpc":"2.0","method":"Client.SetName","params":{"id":$id,"name":$name}}')" >/dev/null
    echo "  • Client $id → renamed to '$name'"
  done
  echo "✅ Names updated."
  echo ""
  pause
}

group_all_clients_default(){
  echo ""
  echo "🧩 Grouping all clients into \"$DEFAULT_GROUP\"…"
  local js ids client_ids_json
  js="$(rpc_status || true)"
  [ -z "$js" ] && { echo "❌ JSON-RPC not available."; pause; return; }
  ids=($(echo "$js" | jq -r '.result.server.clients[].id'))
  client_ids_json=$(printf '%s\n' "${ids[@]}" | jq -R . | jq -s .)
  rpc "$(jq -n --argjson ids "$client_ids_json" --arg grp "$DEFAULT_GROUP" '{id:3,"jsonrpc":"2.0","method":"Group.SetClients","params":{"id":$grp,"clients":$ids}}')" > /dev/null
  echo "✅ Grouping applied. All clients are in '$DEFAULT_GROUP'."
  echo ""
  pause
}

clients_menu(){
  local c
  while true; do
    clear
    echo "──────────────── CLIENTS (JSON-RPC) ────────────────"
    echo "1) List clients"
    echo "2) Auto-name by hostname"
    echo "3) Group all into → \"$DEFAULT_GROUP\""
    echo "4) Back"
    read -rp "Choose [1-4]: " c
    case "$c" in
      1) list_clients ;;
      2) auto_name_clients_from_hostname ;;
      3) group_all_clients_default ;;
      4) return ;;
      *) ;;
    esac
  done
}

# ────────────────────────────────────────────────────────────────────────────
# Stream Management with FFmpeg
# ────────────────────────────────────────────────────────────────────────────
get_stream_lines(){
  awk '
    /^\[stream\]/{instream=1; next}
    /^\[/{instream=0}
    instream && /^source[[:space:]]*=/ { print NR ":" $0 }
  ' "$CONF_FILE" 2>/dev/null || true
}

show_streams_numbered(){
  echo ""
  echo "📜 Configured Streams:"
  local sources i line entry name
  mapfile -t sources < <(get_stream_lines)
  [ "${#sources[@]}" -eq 0 ] && { echo "❌ No streams defined in $CONF_FILE"; return 1; }
  i=1
  for line in "${sources[@]}"; do
    entry="${line#*:}"
    name="$(sed -E 's/.*[?&]name=([^&]+).*/\1/' <<<"$entry")"
    echo "  $i) $name"
    ((i++))
  done
  echo ""
}

mk_stream_id(){ tr '[:upper:]' '[:lower:]' <<<"$1" | tr -cd '[:alnum:]'; }
fifo_path_for(){ echo "${SNAP_FIFO_DIR}/snapfifo_$1"; }
service_name_for(){ echo "ffmpeg-$1.service"; }

ensure_fifo(){
  local fp="$1"
  [ -p "$fp" ] || mkfifo "$fp"
  chown "$SNAP_USER:$SNAP_GROUP" "$fp"
  chmod 666 "$fp"
}

write_unit(){
  local service_name="$1" ffmpeg_line="$2"
  cat > "${SYSTEMD_DIR}/${service_name}" <<EOF
[Unit]
Description=FFmpeg Stream (${service_name})
After=network-online.target snapserver.service

[Service]
ExecStart=${ffmpeg_line}
User=${SNAP_USER}
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
}

ffmpeg_cmd_for(){
  local INPUT_ARGS="$1" FIFO_PATH="$2"
  echo "/usr/bin/ffmpeg -hide_banner -nostats -loglevel error $INPUT_ARGS -ac 2 -ar 48000 -acodec pcm_s16le -f s16le -y \"$FIFO_PATH\""
}

add_or_replace_stream_line(){
  local fifo="$1" name="$2" sample="48000:16:2" tmp newline
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN # Clean up temp file on function exit

  grep -q "^\[stream\]" "$CONF_FILE" || echo "[stream]" >> "$CONF_FILE"
  # Remove the previous source line for this FIFO, if it exists
  sed "/$(escape_sed "$fifo")/d" "$CONF_FILE" > "$tmp" && mv "$tmp" "$CONF_FILE"
  
  newline="source = pipe:///${fifo}?name=${name}&codec=pcm&sampleformat=${sample}"
  
  # Insert the new source line under the [stream] section
  awk -v newline="$newline" '
    BEGIN{inserted=0}
    /^\[stream\]/{print; in_stream=1; next}
    /^\[/{if(in_stream&&!inserted){print newline;inserted=1} in_stream=0}
    {print}
    END{if(in_stream&&!inserted){print newline}}
  ' "$CONF_FILE" > "$tmp"
  mv "$tmp" "$CONF_FILE"
}

create_stream(){
  echo ""
  echo "➕ Create new stream"
  echo "1) URL (HTTP/HTTPS/RTSP/RTMP)"
  echo "2) Local file (infinite loop)"
  echo "3) Custom FFmpeg (input arguments only)"
  
  local kind STREAM_NAME STREAM_ID FIFO_PATH SERVICE_NAME INPUT_ARGS URL FILE CUSTOM FFMPEG_LINE
  read -rp "Choose type [1-3]: " kind
  read -rp "Stream name: " STREAM_NAME
  [ -z "$STREAM_NAME" ] && { echo "❌ Name is required."; pause; return; }

  STREAM_ID="$(mk_stream_id "$STREAM_NAME")"
  FIFO_PATH="$(fifo_path_for "$STREAM_ID")"
  SERVICE_NAME="$(service_name_for "$STREAM_ID")"

  case "$kind" in
    1) read -rp "URL: " URL
       [ -z "$URL" ] && { echo "❌ No URL provided."; pause; return; }
       INPUT_ARGS="-reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 -i \"$URL\"" ;;
    2) read -rp "Path to file (mp3/wav/flac): " FILE
       [ -f "$FILE" ] || { echo "❌ File not found."; pause; return; }
       INPUT_ARGS="-stream_loop -1 -re -i \"$FILE\"" ;;
    3) echo "Example: -f alsa -i hw:0"
       echo "⚠️  WARNING: The arguments will be used directly in the service. Use with caution."
       read -rp "FFmpeg input arguments: " CUSTOM
       [ -z "$CUSTOM" ] && { echo "❌ You must provide arguments."; pause; return; }
       INPUT_ARGS="$CUSTOM" ;;
    *) echo "❌ Invalid selection."; pause; return ;;
  esac

  ensure_fifo "$FIFO_PATH"
  FFMPEG_LINE="$(ffmpeg_cmd_for "$INPUT_ARGS" "$FIFO_PATH")"
  write_unit "$SERVICE_NAME" "$FFMPEG_LINE"

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl restart "$SERVICE_NAME"

  add_or_replace_stream_line "$FIFO_PATH" "$STREAM_NAME"
  systemctl restart snapserver
  echo "✅ Stream '$STREAM_NAME' created and service '$SERVICE_NAME' started."
  pause
}

edit_stream(){
  show_streams_numbered || { pause; return; }
  local num sources entry fifo STREAM_ID SERVICE_NAME
  read -rp "Number of the stream to edit: " num
  mapfile -t sources < <(get_stream_lines)
  entry="${sources[$((num-1))]#*:}"
  fifo="$(sed -E 's|.*fifo/([^?]+)\?.*|\1|' <<<"$entry")"
  STREAM_ID="${fifo#snapfifo_}"
  SERVICE_NAME="$(service_name_for "$STREAM_ID")"
  echo "✍️  Editing service: $SYSTEMD_DIR/$SERVICE_NAME"
  pause
  ${EDITOR:-nano} "$SYSTEMD_DIR/$SERVICE_NAME"
  systemctl daemon-reload
  systemctl restart "$SERVICE_NAME"
  echo "✅ Service reloaded."
  pause
}

delete_streams(){
  show_streams_numbered || { pause; return; }
  local sel CHOSEN n sources entry fifo STREAM_ID SVC
  read -rp "Number(s) to delete (comma-separated, e.g., 1,3): " sel
  IFS=',' read -ra CHOSEN <<<"$sel"
  for n in "${CHOSEN[@]}"; do
    mapfile -t sources < <(get_stream_lines)
    entry="${sources[$((n-1))]#*:}"
    fifo="$(sed -E 's|.*fifo/([^?]+)\?.*|\1|' <<<"$entry")"
    STREAM_ID="${fifo#snapfifo_}"
    SVC="$(service_name_for "$STREAM_ID")"
    echo "🗑️  Deleting stream $n and its associated service..."
    systemctl stop "$SVC" 2>/dev/null || true
    systemctl disable "$SVC" 2>/dev/null || true
    rm -f "$SYSTEMD_DIR/$SVC" "$SNAP_FIFO_DIR/$fifo"
    sed -i "/${fifo}/d" "$CONF_FILE"
  done
  systemctl daemon-reload
  systemctl restart snapserver
  echo "✅ Stream(s) deleted."
  pause
}

check_activity(){
  echo ""
  echo "🎧 Current status of FFmpeg services:"
  local sources line entry name fifo id svc st
  mapfile -t sources < <(get_stream_lines)
  [ "${#sources[@]}" -eq 0 ] && { echo "No streams configured."; pause; return; }
  for line in "${sources[@]}"; do
    entry="${line#*:}"
    name="$(sed -E 's/.*[?&]name=([^&]+).*/\1/' <<<"$entry")"
    fifo="$(sed -E 's|.*fifo/([^?]+)\?.*|\1|' <<<"$entry")"
    id="${fifo#snapfifo_}"
    svc="$(service_name_for "$id")"
    st="$(systemctl is-active "$svc" 2>/dev/null || echo unknown)"
    printf "  • %-22s : %-10s (%s)\n" "'$name'" "$st" "$svc"
  done
  echo ""
  pause
}

# ────────────────────────────────────────────────────────────────────────────
# Backups (config + datadir + ffmpeg services)
# ────────────────────────────────────────────────────────────────────────────
do_backup(){
  local OUT="/var/backups/snapserver_backup_$(ts).tar.gz"
  echo "🧯 Creating backup at $OUT ..."
  mkdir -p /var/backups
  tar -czf "$OUT" \
    /var/lib/snapserver \
    "$CONF_FILE" \
    $SYSTEMD_DIR/ffmpeg-*.service \
    $SYSTEMD_DIR/snap-silence.service 2>/dev/null || true
  echo "✅ Backup ready: $OUT"
  pause
}

do_restore(){
  local BK ans
  echo "🧰 Restore backup"
  ls -1 /var/backups/snapserver_backup_*.tar.gz 2>/dev/null || { echo "❌ No backups found in /var/backups/"; pause; return; }
  read -rp "Path of the backup to restore: " BK
  [ -f "$BK" ] || { echo "❌ $BK does not exist"; pause; return; }
  read -rp "⚠️  This will overwrite the current configuration. Confirm? (y/N): " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "❌ Canceled"; pause; return; }
  
  echo "⛔ Stopping services..."
  systemctl stop snapserver snap-silence.service ffmpeg-*.service 2>/dev/null || true
  
  echo "📦 Extracting files..."
  tar -xzf "$BK" -C /
  
  echo "🔧 Applying permissions and reloading..."
  chown -R "$SNAP_USER:$SNAP_GROUP" /var/lib/snapserver
  systemctl daemon-reload
  
  echo "🟢 Restarting restored services..."
  systemctl restart snapserver || true
  # Restart only the ffmpeg services that exist after the restore
  if compgen -G "$SYSTEMD_DIR/ffmpeg-*.service" > /dev/null; then
    systemctl restart ffmpeg-*.service
  fi
  if [ -f "$SYSTEMD_DIR/snap-silence.service" ]; then
    systemctl restart snap-silence.service
  fi
  
  echo "✅ Restored."
  pause
}

backup_menu(){
  local b
  while true; do
    clear
    echo "──────────────── BACKUPS ─────────────────"
    echo "1) Create backup"
    echo "2) Restore backup"
    echo "3) Back"
    read -rp "Choose [1-3]: " b
    case "$b" in
      1) do_backup ;;
      2) do_restore ;;
      3) return ;;
      *) ;;
    esac
  done
}

# ────────────────────────────────────────────────────────────────────────────
# Main Menu
# ────────────────────────────────────────────────────────────────────────────
main_menu(){
  ensure_prereqs
  detect_lxc
  [[ "$LXC_MODE" -eq 1 ]] && lxc_instructions
  ensure_silence_fallback
  monitor_snapserver

  local opt
  while true; do
    clear
    echo "═══════════════════════════════════════════════════"
    echo "        🧩 SNAPSTREAM MANAGER v2025.10.45"
    echo "═══════════════════════════════════════════════════"
    echo "1) Add new stream"
    echo "2) List streams"
    echo "3) Edit a stream (FFmpeg service)"
    echo "4) Delete stream(s)"
    echo "5) Check status of FFmpeg services"
    echo "6) Clients (list, name, group)"
    echo "7) Backups (create/restore)"
    echo "8) Exit"
    echo "═══════════════════════════════════════════════════"
    read -rp "Choose [1-8]: " opt
    case "$opt" in
      1) create_stream ;;
      2) show_streams_numbered; pause ;;
      3) edit_stream ;;
      4) delete_streams ;;
      5) check_activity ;;
      6) clients_menu ;;
      7) backup_menu ;;
      8) exit 0 ;;
      *) ;;
    esac
  done
}

main_menu
