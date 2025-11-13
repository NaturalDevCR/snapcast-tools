#!/bin/bash
# ==============================================================================
# SNAPSTREAM MANAGER v1.0.13
# Snapserver + FFmpeg Streams + Snapweb + JSON-RPC + Backups + LXC-aware
# Fixed loop bug, added timeout enforcement, and improved overall stability.
# Author: Josue / GPT-5 / Gemini — “The Definitive Build.”
# Status: STABLE - Production ready.
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
LOG_DIR="/var/log/ffmpeg"
SNAP_USER="snapserver"
SNAP_GROUP="snapserver"
DEFAULT_GROUP="Default"
SNAP_RPC="http://127.0.0.1:1780/jsonrpc"
WATCHDOG_CONF="/etc/snapserver.d/snapstream-watchdog.conf"

# --- Variables for Silent Fallback (integrated) ---
SILENCE_FIFO="$SNAP_FIFO_DIR/silence.fifo"
SILENCE_SERVICE="$SYSTEMD_DIR/snap-silence.service"

mkdir -p "$BACKUP_DIR" "$CACHE_DIR" "$LOG_DIR"
chown "$SNAP_USER:$SNAP_GROUP" "$LOG_DIR" 2>/dev/null || true

# --- Utility Functions ---
pause(){ read -rp "Press Enter to continue..." < /dev/tty; }
ts(){ date +"%Y-%m-%d_%H-%M-%S"; }
escape_sed(){ sed -e 's/[\/&]/\\&/g' <<<"$1"; }

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
  if [[ "${LXC_MODE:-0}" -eq 1 ]]; then
    echo "   🧠 RUNNING IN LXC CONTAINER DETECTED"
  else
    echo "   🧠 Host/VM environment detected"
  fi
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
    sed -i 's|ExecStart=.*|& --server.conf=/etc/snapserver.conf|' "$SERVICE_FILE"
  fi
  if ! grep -q -- '--http-port' "$SERVICE_FILE"; then
    sed -i 's|ExecStart=.*|& --http-port 1780|' "$SERVICE_FILE"
  fi
  if [ -d "/usr/share/snapserver/snapweb" ] && ! grep -q -- '--http-doc-root' "$SERVICE_FILE"; then
    sed -i 's|ExecStart=.*|& --http-doc-root=/usr/share/snapserver/snapweb|' "$SERVICE_FILE"
  fi
  if ! grep -q -- '--http-doc-root' "$SERVICE_FILE"; then
     sed -i 's|ExecStart=.*|& --http-doc-root=/usr/share/snapserver/snapweb|' "$SERVICE_FILE"
  fi

  mkdir -p /var/lib/snapserver/config "$SNAP_FIFO_DIR"
  chown -R "$SNAP_USER:$SNAP_GROUP" /var/lib/snapserver

  systemctl daemon-reload
  systemctl reset-failed snapserver.service 2>/dev/null || true
  systemctl restart snapserver.service || true

  echo "✅ Unit adjusted. datadir=/var/lib/snapserver, configdir=/var/lib/snapserver/config, http-port=1780"

  if [ -f /etc/snapserver.conf ]; then
    cp -f /etc/snapserver.conf /var/lib/snapserver/config/snapserver.conf 2>/dev/null || true
    chown "$SNAP_USER:$SNAP_GROUP" /var/lib/snapserver/config/snapserver.conf
  fi
}

monitor_snapserver(){
  echo ""
  echo "🔎 Checking Snapserver status..."
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

      if ! systemctl list-unit-files | grep -q '^snapserver\.service'; then
          echo "❌ snapserver.service is not installed."
          pause
          return
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
  if [ -z "$SNAPVER" ]; then
    echo "❌ Could not get Snapcast version from GitHub."
    if [ -f "$BACKUP_DIR/snapserver_prev.deb" ]; then dpkg -i "$BACKUP_DIR/snapserver_prev.deb"; fi
    return 1
  fi
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

  [ -z "$PACKAGE_URL" ] && { echo "❌ No compatible package found for your OS/Arch."; return 1; }

  FILENAME="/tmp/$(basename "$PACKAGE_URL")"
  echo "📦 Downloading: $PACKAGE_URL"
  if ! curl -L -o "$FILENAME" "$PACKAGE_URL"; then
    echo "❌ Download failed."
    return 1
  fi

  echo "📦 Installing..."
  if ! dpkg -i "$FILENAME"; then
    echo "dpkg failed, trying to fix dependencies..."
    if ! apt-get -f install -y; then
        echo "❌ Failed to install package and fix dependencies."
        if [ -f "$BACKUP_DIR/snapserver_prev.deb" ]; then dpkg -i "$BACKUP_DIR/snapserver_prev.deb"; fi
        return 1
    fi
  fi
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
    (
      confirm_actions && install_prereqs
    )
    if [ $? -ne 0 ]; then
      echo "🚨 Installation failed. Please check the errors above."
      exit 1
    fi
  else
    echo "✅ Dependencies already satisfied. Skipping installation."
    sleep 1
  fi
}

# ────────────────────────────────────────────────────────────────────────────
# Automatic Silent Fallback (MetaStreams-friendly)
# ────────────────────────────────────────────────────────────────────────────
##
# ensure_silence_fallback
# Adds/updates a global Silence source using a process URI (ffmpeg) inside
# the `[stream]` section of `/etc/snapserver.conf`. This Silence has
# `codec=null` so it remains invisible to users, and is intended to be used
# as the fallback target by MetaStreams.
#
# Why: Using a global Silence source and MetaStreams is the recommended
# structure to ensure stable fallback behavior across all user-facing streams.
##
ensure_silence_fallback(){
  echo ""
  echo "🔈 Verificando y generando silence global (process:///ffmpeg)…"
  local snap_home
  snap_home="$(getent passwd "$SNAP_USER" | cut -d: -f6)"
  if [ "$snap_home" != "/var/lib/snapserver" ]; then
    echo "🩹 Fixing home directory for user '$SNAP_USER' → /var/lib/snapserver"
    usermod -d /var/lib/snapserver "$SNAP_USER" 2>/dev/null || true
    mkdir -p /var/lib/snapserver
    chown -R "$SNAP_USER:$SNAP_GROUP" /var/lib/snapserver
  fi

  # If an old FIFO-based silence service exists, disable and remove it
  if systemctl list-unit-files | grep -q '^snap-silence\.service'; then
    echo "🧹 Disabling legacy snap-silence.service (FIFO-based)…"
    systemctl stop snap-silence.service 2>/dev/null || true
    systemctl disable snap-silence.service 2>/dev/null || true
  fi
  [ -f "$SILENCE_SERVICE" ] && rm -f "$SILENCE_SERVICE"
  [ -p "$SILENCE_FIFO" ] && rm -f "$SILENCE_FIFO"

  # Ensure [stream] section exists
  grep -q "^\[stream\]" "$CONF_FILE" || echo "[stream]" >> "$CONF_FILE"

  # Add or replace the global silence process source inside [stream]
  local tmp_conf; tmp_conf="$(mktemp)"
  local silence_line="source = process:///usr/bin/ffmpeg?name=Silence&codec=null&sampleformat=48000:16:2&params=-f lavfi -i anullsrc=r=48000:cl=stereo -f s16le -ar 48000 -ac 2 -"

  awk -v new_line="$silence_line" '
    BEGIN { in_stream=0; replaced=0; inserted=0; }
    /^\[stream\]/ { print; in_stream=1; next }
    /^\[/ {
      if (in_stream && !inserted && !replaced) { print new_line; inserted=1 }
      in_stream=0
    }
    {
      # Match any existing Silence process line regardless of slash count or param order
      if (in_stream && $0 ~ /^\s*source\s*=\s*process:\/\/+usr\/bin\/ffmpeg/ && $0 ~ /([?&])name=Silence/) {
        if (!replaced) { print new_line; replaced=1 }
        next
      }
      print
    }
    END { if (in_stream && !inserted && !replaced) print new_line }
  ' "$CONF_FILE" > "$tmp_conf"

  mv "$tmp_conf" "$CONF_FILE"
  rm -f "$tmp_conf"
  chown "$SNAP_USER:$SNAP_GROUP" "$CONF_FILE"
  echo "✅ Silence global agregado/actualizado en la sección [stream]."
  echo ""
}

# ────────────────────────────────────────────────────────────────────────────
# JSON-RPC: Client Management
# ────────────────────────────────────────────────────────────────────────────
rpc(){
    local response
    response=$(curl --fail -s --connect-timeout 5 -H 'Content-Type: application/json' -X POST "$SNAP_RPC" -d "$1" 2>&1)
    if [ $? -ne 0 ]; then
        echo "RPC_ERROR: Failed to communicate with Snapserver on ${SNAP_RPC}." >&2
        echo "curl error: ${response}" >&2
        return 1
    fi
    echo "$response"
}
rpc_status(){ rpc '{"id":1,"jsonrpc":"2.0","method":"Server.GetStatus"}'; }

list_clients(){
  echo ""
  echo "👥 Connected clients:"
  local response
  if ! response=$(rpc_status); then
      echo "❌ Error communicating with Snapserver. Is the service running and is port 1780 open?"
      pause
      return
  fi
  
  local count
  count=$(echo "$response" | jq '.result.server.clients | length')
  if [ "$count" -eq 0 ]; then
    echo "ℹ️ No clients are currently connected."
  else
    echo "$response" | jq -r '.result.server.clients[] | "  • ID: \(.id)\n    Host: \(.host.name)\n    Name: \(.config.name)\n"'
  fi
  echo ""
  pause
}

auto_name_clients_from_hostname(){
  echo ""
  echo "✏️ Auto-naming clients using their hostname..."
  local response js
  if ! response=$(rpc_status); then
      echo "❌ Error communicating with Snapserver."
      pause
      return
  fi
  js="$response"
  
  local ids id host name
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
  local response js
  if ! response=$(rpc_status); then
      echo "❌ Error communicating with Snapserver."
      pause
      return
  fi
  js="$response"
  
  local ids client_ids_json
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
    read -rp "Choose [1-4]: " c < /dev/tty
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
# Stream Management with FFmpeg & Advanced Watchdog
# ────────────────────────────────────────────────────────────────────────────
##
# get_stream_lines
# Returns only pipe source lines from the `[stream]` section. This ensures
# operations (edit/delete/watchdog/restart) target actual FFmpeg-backed
# sources, excluding MetaStreams and the Silence process.
##
get_stream_lines(){
  # Use awk to reliably return all pipe sources inside the [stream] section,
  # allowing optional leading whitespace before section headers.
  awk '
    BEGIN { in_stream = 0 }
    /^[[:space:]]*\[stream\]/ { in_stream = 1; next }
    /^[[:space:]]*\[/ { if (in_stream) in_stream = 0 }
    in_stream && /^[[:space:]]*source[[:space:]]*=[[:space:]]*pipe:/ { print }
  ' "$CONF_FILE"
}

show_streams_numbered(){
  echo ""
  echo "📜 Configured Streams:"
  local i=1
  while IFS= read -r line; do
    local name
    name=$(echo "$line" | sed -nE 's/.*[?&]name=([^&]+).*/\1/p')
    echo "  $i) $name"
    ((i++))
  done < <(get_stream_lines)

  if [ "$i" -eq 1 ]; then
    echo "❌ No streams defined in $CONF_FILE"
    return 1
  fi
  echo ""
}

mk_stream_id(){ tr '[:upper:]' '[:lower:]' <<<"$1" | tr -cd '[:alnum:]'; }
fifo_path_for(){ echo "${SNAP_FIFO_DIR}/snapfifo_$1"; }
service_name_for(){ echo "ffmpeg-$1.service"; }
log_file_for(){ echo "${LOG_DIR}/ffmpeg-$1.log"; }

ensure_fifo(){
  local fp="$1"
  [ -p "$fp" ] || mkfifo "$fp"
  chown "$SNAP_USER:$SNAP_GROUP" "$fp"
  chmod 666 "$fp"
}

write_unit(){
  local service_name="$1" ffmpeg_line="$2" stream_name="$3" stream_id="$4" fifo_path="$5"
  cat > "${SYSTEMD_DIR}/${service_name}" <<EOF
[Unit]
Description=FFmpeg Stream for ${stream_name}
After=network-online.target snapserver.service
PartOf=snapserver.service
Requires=snapserver.service

[Service]
ExecStart=${ffmpeg_line}
ExecStopPost=/bin/bash -c 'rm -f "${fifo_path}" && mkfifo "${fifo_path}" && chown ${SNAP_USER}:${SNAP_GROUP} "${fifo_path}" && chmod 666 "${fifo_path}"'
User=${SNAP_USER}
Restart=always
RestartSec=5
StartLimitIntervalSec=30
StartLimitBurst=10
StandardOutput=append:$(log_file_for "$stream_id")
StandardError=append:$(log_file_for "$stream_id")

[Install]
WantedBy=multi-user.target
EOF
}

ensure_watchdog_templates(){
  local w_service="${SYSTEMD_DIR}/ffmpeg-watchdog@.service"
  local w_timer="${SYSTEMD_DIR}/ffmpeg-watchdog@.timer"
  local w_exec="/usr/local/bin/snap_ffmpeg_watchdog.sh"

  if [ ! -f "$w_exec" ]; then
    echo "⚙️ Creating watchdog executor script..."
    cat > "$w_exec" <<'EOF'
#!/bin/bash
set -e
INSTANCE="$1"
UNIT="ffmpeg-${INSTANCE}.service"
LOG="/var/log/ffmpeg/ffmpeg-${INSTANCE}.log"
FIFO="/var/lib/snapserver/fifo/snapfifo_${INSTANCE}"
REASON=""
LOG_STALE_SECONDS="${LOG_STALE_SECONDS:-90}"
MIN_UPTIME_SECONDS="${MIN_UPTIME_SECONDS:-120}"
ERROR_PATTERN_REGEX="${ERROR_PATTERN_REGEX:-"(Connection timed out|Protocol not found|No route to host|End of file|Connection refused|HTTP error|Invalid data found when processing input)"}"

# sanitize pattern from EnvironmentFile (strip optional surrounding quotes)
PATTERN="${ERROR_PATTERN_REGEX}"
PATTERN=${PATTERN#\"}
PATTERN=${PATTERN%\"}

if ! systemctl is-active --quiet "${UNIT}"; then
  REASON="service was not active"
elif [ ! -p "${FIFO}" ]; then
  REASON="FIFO pipe was missing"
elif [ -f "${LOG}" ]; then
  if grep -E -q -- "${PATTERN}" <<<"" 2>/dev/null; then
    if tail -n 200 "${LOG}" 2>/dev/null | grep -E -q -- "${PATTERN}"; then
      REASON="detected critical error pattern in logs"
    fi
  else
    echo "[WATCHDOG] WARNING: invalid ERROR_PATTERN_REGEX='${PATTERN}', skipping regex check." >> "${LOG}"
  fi
  if [ -z "${REASON}" ]; then
    if [ -s "${LOG}" ] && [ "${LOG_STALE_SECONDS}" -gt 0 ] 2>/dev/null; then
      LAST_UPDATE=$(( $(date +%s) - $(stat -c %Y "${LOG}" 2>/dev/null || echo $(date +%s)) ))
      if [[ "${LAST_UPDATE}" -gt "${LOG_STALE_SECONDS}" ]]; then
         ACTIVE_SINCE_BOOT=$(systemctl show "${UNIT}" -p ActiveEnterTimestampMonotonic --value 2>/dev/null || echo 0)
         UPTIME=$(awk '{print int($1)}' /proc/uptime)
         if [[ "${ACTIVE_SINCE_BOOT}" -gt 0 ]] && [[ $(( UPTIME - (ACTIVE_SINCE_BOOT / 1000000) )) -gt "${MIN_UPTIME_SECONDS}" ]]; then
            REASON="process appears frozen (log not updated in ${LAST_UPDATE}s, non-empty log)"
         fi
      fi
    fi
  fi
fi

if [ -n "${REASON}" ]; then
  if [ -f "${LOG}" ]; then mv "${LOG}" "${LOG}.prev.$(date +%s)" 2>/dev/null || true; fi
  systemctl restart "${UNIT}"
  sleep 1
  : > "${LOG}"
  chown snapserver:snapserver "${LOG}" 2>/dev/null || true
  echo "[WATCHDOG] Restarting ${UNIT}. Reason: ${REASON}." >> "${LOG}"
fi
EOF
    chmod 0755 "$w_exec"
  fi

  if [ ! -f "$w_service" ]; then
    echo "⚙️ Creating advanced FFmpeg watchdog service template..."
    cat > "$w_service" <<'EOF'
[Unit]
Description=FFmpeg Watchdog for %i (Advanced Logic)
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/snap_ffmpeg_watchdog.sh %i
EnvironmentFile=/etc/snapserver.d/snapstream-watchdog.conf
EOF
  fi

  if [ ! -f "$w_timer" ]; then
    echo "⚙️ Creating FFmpeg watchdog timer template..."
    cat > "$w_timer" <<'EOF'
[Unit]
Description=Run FFmpeg Watchdog for %i every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1m

[Install]
WantedBy=timers.target
EOF
  fi

  # Ensure watchdog config file exists with defaults
  if [ ! -f "$WATCHDOG_CONF" ]; then
    mkdir -p "$(dirname "$WATCHDOG_CONF")"
    cat > "$WATCHDOG_CONF" <<'EOF'
# Snapstream Watchdog configuration (defaults)
LOG_STALE_SECONDS=90
MIN_UPTIME_SECONDS=120
ERROR_PATTERN_REGEX="(Connection timed out|Protocol not found|No route to host|End of file|Connection refused|HTTP error|Invalid data found when processing input)"
EOF
  fi
}

ensure_logrotate(){
  local LOGROTATE_CONF="/etc/logrotate.d/ffmpeg-snapstream"
  if [ ! -f "$LOGROTATE_CONF" ]; then
    echo "⚙️ Creating logrotate config for FFmpeg streams..."
    cat > "$LOGROTATE_CONF" <<EOF
/var/log/ffmpeg/ffmpeg-*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 0640 ${SNAP_USER} ${SNAP_GROUP}
    su ${SNAP_USER} ${SNAP_GROUP}
}
EOF
  fi
}

ffmpeg_cmd_for(){
  local INPUT_ARGS="$1" FIFO_PATH="$2"
  echo "/usr/bin/ffmpeg -hide_banner -nostats -loglevel error $INPUT_ARGS -acodec pcm_s16le -ac 2 -ar 48000 -f s16le -y \"$FIFO_PATH\""
}

##
# add_or_replace_stream_line
# Ensures a single pipe source line (codec=null) exists in the `[stream]`
# section for the given FIFO path and display name. If found, it replaces it;
# otherwise it inserts it once.
#
# Why: All user streams should be declared with `codec=null` so they are not
# directly visible to users; they will be wrapped by MetaStreams instead.
##
add_or_replace_stream_line(){
  local fifo="$1" name="$2" sample="48000:16:2"
  local tmp_conf; tmp_conf="$(mktemp)"

  local new_line="source = pipe:///${fifo}?name=${name}&codec=null&sampleformat=${sample}"

  awk -v fifo_path="${fifo}" \
      -v new_line="${new_line}" '
      BEGIN {
          in_stream_section = 0;
          inserted = 0;
      }
      /^\[stream\]/ {
          print;
          in_stream_section = 1;
          next;
      }
      /^\[/ {
          if (in_stream_section && !inserted) {
              print new_line;
              inserted = 1;
          }
          in_stream_section = 0;
      }
      in_stream_section && $0 ~ fifo_path {
          next;
      }
      { print; }
      END {
          if (in_stream_section && !inserted) {
              print new_line;
          }
      }
  ' "$CONF_FILE" > "$tmp_conf"

  mv "$tmp_conf" "$CONF_FILE"
  rm -f "$tmp_conf"
  chown "$SNAP_USER:$SNAP_GROUP" "$CONF_FILE"
}

# Add or replace a metastream line referencing a source and the global Silence
##
# add_or_replace_metastream_line
# Ensures a single MetaStream line exists that references
# `meta:///<source_name>/Silence` with the given `meta_name` and `codec=pcm`.
# If found, it replaces it; else it inserts it once.
#
# Why: MetaStreams present the user-facing stream and include the global
# Silence as the fallback, providing correct behavior when the source is down.
##
add_or_replace_metastream_line(){
  local source_name="$1" meta_name="$2" sample="48000:16:2"
  local tmp_conf; tmp_conf="$(mktemp)"

  local new_line="source = meta:///${source_name}/Silence?name=${meta_name}&codec=pcm&sampleformat=${sample}"

  awk -v src_name="${source_name}" \
      -v new_line="${new_line}" '
      BEGIN { in_stream_section = 0; inserted = 0; replaced = 0; }
      /^\[stream\]/ { print; in_stream_section = 1; next; }
      /^\[/ {
          if (in_stream_section && !inserted && !replaced) {
              print new_line;
              inserted = 1;
          }
          in_stream_section = 0;
      }
      in_stream_section {
          if (!replaced && index($0, "source = meta:///" src_name "/Silence") > 0) {
              print new_line; replaced = 1; next;
          }
      }
      { print; }
      END {
          if (in_stream_section && !inserted && !replaced) {
              print new_line;
          }
      }
  ' "$CONF_FILE" > "$tmp_conf"

  mv "$tmp_conf" "$CONF_FILE"
  rm -f "$tmp_conf"
  chown "$SNAP_USER:$SNAP_GROUP" "$CONF_FILE"
}

# Ensure default pipe sources with codec=null for known FIFOs and names
##
# ensure_default_pipe_sources
# Declares the fixed set of known FIFO-based sources with `codec=null`.
# These are the non-visible raw sources that MetaStreams will wrap.
#
# Why: Keeps config consistent and eliminates duplicate/incorrect entries.
##
ensure_default_pipe_sources(){
  echo "🧩 Ensuring default pipe sources (codec=null)…"
  add_or_replace_stream_line \
    "/var/lib/snapserver/fifo/snapfifo_frontdesk" "PC-FrontDesk"
  add_or_replace_stream_line \
    "/var/lib/snapserver/fifo/snapfifo_aracari" "PC-Aracari"
  add_or_replace_stream_line \
    "/var/lib/snapserver/fifo/snapfifo_azuracastrestaurants" "Azuracast-Restaurants"
  add_or_replace_stream_line \
    "/var/lib/snapserver/fifo/snapfifo_azuracastfrontdesk" "Azuracast-FrontDesk"
  add_or_replace_stream_line \
    "/var/lib/snapserver/fifo/snapfifo_azuracastoutdoors" "Azuracast-Outdoors"
  add_or_replace_stream_line \
    "/var/lib/snapserver/fifo/snapfifo_pcpool" "PC-Pool"
}

# Ensure default metastreams referencing Silence fallback
##
#
# ensure_default_metastreams
# Creates/updates the user-facing MetaStreams for each raw pipe source, pointing to
# `meta:///<SourceName>/Silence` with `codec=pcm` and `sampleformat=48000:16:2`.
#
# Why: Presents meaningful names to users and guarantees Silence fallback.
#
ensure_default_metastreams(){
  # Guard: require global Silence to exist in [stream] before creating MetaStreams
  if ! grep -qE '^\s*source\s*=\s*process:///usr/bin/ffmpeg.*name=Silence' "$CONF_FILE"; then
    echo "⚠️  Global 'Silence' source not found in [stream]."
    echo "    Run 'Configuration → Ensure global Silence source' first."
    pause
    return
  fi
  echo "🧩 Ensuring default metastreams (codec=pcm, Silence fallback)…"
  add_or_replace_metastream_line "PC-FrontDesk" "FrontDesk"
  add_or_replace_metastream_line "PC-Aracari" "Aracari"
  add_or_replace_metastream_line "Azuracast-Restaurants" "Restaurants"
  add_or_replace_metastream_line "Azuracast-FrontDesk" "AzuraFrontDesk"
  add_or_replace_metastream_line "Azuracast-Outdoors" "Outdoors"
  add_or_replace_metastream_line "PC-Pool" "Pool"
}

create_stream(){
  echo ""
  echo "➕ Create new stream"
  echo "1) URL (HTTP/HTTPS/RTSP/RTMP)"
  echo "2) Local file (infinite loop)"
  echo "3) Custom FFmpeg (input arguments only)"

  local kind STREAM_NAME STREAM_ID FIFO_PATH SERVICE_NAME INPUT_ARGS URL FILE CUSTOM FFMPEG_LINE
  read -rp "Choose type [1-3]: " kind < /dev/tty
  read -rp "Stream name: " STREAM_NAME < /dev/tty
  [ -z "$STREAM_NAME" ] && { echo "❌ Name is required."; pause; return; }

  STREAM_ID="$(mk_stream_id "$STREAM_NAME")"
  FIFO_PATH="$(fifo_path_for "$STREAM_ID")"
  SERVICE_NAME="$(service_name_for "$STREAM_ID")"

  case "$kind" in
    1)
      read -rp "URL: " URL < /dev/tty
      [ -z "$URL" ] && { echo "❌ No URL provided."; pause; return; }
      INPUT_ARGS="-reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 -i \"$URL\""
      ;;
    2)
      read -rp "Path to file (mp3/wav/flac): " FILE < /dev/tty
      [ -f "$FILE" ] || { echo "❌ File not found."; pause; return; }
      INPUT_ARGS="-stream_loop -1 -re -i \"$FILE\""
      ;;
    3)
      echo "Example: -f alsa -i hw:0"
      echo "⚠️  WARNING: The arguments will be used directly in the service. Use with caution."
      read -rp "FFmpeg input arguments: " CUSTOM < /dev/tty
      [ -z "$CUSTOM" ] && { echo "❌ You must provide arguments."; pause; return; }
      INPUT_ARGS="$CUSTOM"
      ;;
    *)
      echo "❌ Invalid selection."
      pause
      return
      ;;
  esac

  ensure_fifo "$FIFO_PATH"
  FFMPEG_LINE="$(ffmpeg_cmd_for "$INPUT_ARGS" "$FIFO_PATH")"
  write_unit "$SERVICE_NAME" "$FFMPEG_LINE" "$STREAM_NAME" "$STREAM_ID" "$FIFO_PATH"

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl restart "$SERVICE_NAME"

  echo "🛡️ Activating advanced watchdog for '$STREAM_NAME'..."
  systemctl enable --now "ffmpeg-watchdog@${STREAM_ID}.timer" >/dev/null 2>&1 || true

  add_or_replace_stream_line "$FIFO_PATH" "$STREAM_NAME"
  systemctl restart snapserver
  echo "✅ Stream '$STREAM_NAME' created and started with advanced watchdog."
  pause
}

edit_stream(){
  show_streams_numbered || { pause; return; }
  local num entry fifo STREAM_ID SERVICE_NAME
  read -rp "Number of the stream to edit: " num < /dev/tty
  
  local i=1
  while IFS= read -r line; do
    if [ "$i" -eq "$num" ]; then
      entry="$line"
      break
    fi
    ((i++))
  done < <(get_stream_lines)

  STREAM_ID="$(echo "$entry" | sed -nE 's|.*snapfifo_([^?]+)\?.*|\1|p')"
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
  local sel CHOSEN n entry STREAM_ID SVC LOG_FILE
  
  local -a sources
  mapfile -t sources < <(get_stream_lines)

  read -rp "Number(s) to delete (comma-separated, e.g., 1,3): " sel < /dev/tty
  IFS=',' read -ra CHOSEN <<<"$sel"
  for n in "${CHOSEN[@]}"; do
    entry="${sources[$((n-1))]}"
    STREAM_ID="$(echo "$entry" | sed -nE 's|.*snapfifo_([^?]+)\?.*|\1|p')"
    SVC="$(service_name_for "$STREAM_ID")"
    LOG_FILE="$(log_file_for "$STREAM_ID")"

    echo "🗑️  Deleting stream $n ('${STREAM_ID}') and its associated service..."
    systemctl stop "$SVC" 2>/dev/null || true
    systemctl disable "$SVC" 2>/dev/null || true
    systemctl stop "ffmpeg-watchdog@${STREAM_ID}.timer" 2>/dev/null || true
    systemctl disable "ffmpeg-watchdog@${STREAM_ID}.timer" 2>/dev/null || true

    rm -f "$SYSTEMD_DIR/$SVC" "${SNAP_FIFO_DIR}/snapfifo_${STREAM_ID}" "$LOG_FILE"
    sed -i "/snapfifo_${STREAM_ID}/d" "$CONF_FILE"
  done
  systemctl daemon-reload
  systemctl restart snapserver
  echo "✅ Stream(s) deleted."
  pause
}

check_activity(){
  echo ""
  echo "🎧 Current status of FFmpeg services:"
  local server_status
  if ! server_status=$(rpc_status); then
      echo "⚠️  Could not connect to Snapserver to check stream sources. Displaying service status only."
      server_status=""
  fi
  
  local i=1
  while IFS= read -r line; do
    local name id svc st source_status
    name=$(echo "$line" | sed -nE 's/.*[?&]name=([^&]+).*/\1/p')
    id=$(echo "$line" | sed -nE 's|.*snapfifo_([^?]+)\?.*|\1|p')
    svc=$(service_name_for "$id")
    st=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
    
    source_status="-"
    if [ -n "$server_status" ]; then
      local current_uri
      current_uri=$(echo "$server_status" | jq -r --arg n "$name" '.result.server.streams[] | select(.id==$n) | .uri.path')
      
      if [[ "$current_uri" == *"/silence.fifo" ]]; then
          source_status="FALLBACK"
      elif [[ "$st" != "active" ]]; then
          source_status="OFFLINE"
      elif [ -n "$current_uri" ]; then
          source_status="MAIN"
      fi
    fi

    printf "  • %-22s | Service: %-10s | Source: %-8s\n" "'$name'" "$st" "$source_status"
    ((i++))
  done < <(get_stream_lines)

  if [ "$i" -eq 1 ]; then echo "No streams configured."; fi
  
  echo ""
  echo "🔎 To see logs, run: tail -f /var/log/ffmpeg/ffmpeg-<stream_id>.log"
  echo ""
  pause
}

##
# restart_snapserver_with_confirm
# Asks for confirmation and restarts the Snapserver service. Shows a short
# status summary after the restart.
##
restart_snapserver_with_confirm(){
  echo ""
  read -rp "⚠️  Restart Snapserver now? (y/N): " ans < /dev/tty
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    echo "🔁 Restarting Snapserver…"
    if systemctl restart snapserver; then
      sleep 1
      local st
      st=$(systemctl is-active snapserver 2>/dev/null || echo "unknown")
      echo "✅ Snapserver status: $st"
    else
      echo "❌ Failed to restart Snapserver. Check: journalctl -u snapserver -n 50 --no-pager"
    fi
  else
    echo "🟡 Skipped Snapserver restart."
  fi
  echo ""
  pause
}

##
# restart_selected_ffmpeg_services
# Lets the user pick specific FFmpeg services (by stream number) to restart,
# asks for confirmation, and restarts each selected service.
##
restart_selected_ffmpeg_services(){
  show_streams_numbered || { pause; return; }
  local sel CHOSEN entry id svc st
  mapfile -t sources < <(get_stream_lines)

  read -rp "Number(s) to restart (comma-separated, e.g., 1,3): " sel < /dev/tty
  IFS=',' read -ra CHOSEN <<<"$sel"

  if [ "${#CHOSEN[@]}" -eq 0 ]; then
    echo "❌ No selection."
    pause
    return
  fi

  read -rp "⚠️  Confirm restarting the selected FFmpeg service(s)? (y/N): " ans < /dev/tty
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "🟡 Skipped restart."; pause; return; }

  for n in "${CHOSEN[@]}"; do
    entry="${sources[$((n-1))]}"
    id="$(echo "$entry" | sed -nE 's|.*snapfifo_([^?]+)\?.*|\1|p')"
    if [ -z "$id" ]; then
      echo "⚠️  Could not parse a valid Stream ID for item '$n'. Skipping."
      continue
    fi
    svc="$(service_name_for "$id")"
    echo "🔁 Restarting $svc …"
    if systemctl restart "$svc"; then
      st=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
      echo "✅ $svc status: $st"
    else
      echo "❌ Failed to restart $svc. Check: journalctl -u $svc -n 50 --no-pager"
    fi
  done
  echo ""
  pause
}

##
# services_menu
# Submenu that centralizes service management tasks: view statuses and
# optionally restart Snapserver or FFmpeg services (all or selected).
##
services_menu(){
  local opt
  while true; do
    clear
    echo "──────────────── SERVICES ─────────────────"
    echo "1) View Snapserver status"
    echo "2) View status of FFmpeg services"
    echo "3) Restart Snapserver (optional)"
    echo "4) Restart specific FFmpeg services (optional)"
    echo "5) Restart ALL FFmpeg services (optional)"
    echo "6) Back"
    read -rp "Choose [1-6]: " opt < /dev/tty
    case "$opt" in
      1) monitor_snapserver ;;
      2) check_activity ;;
      3) restart_snapserver_with_confirm ;;
      4) restart_selected_ffmpeg_services ;;
      5) restart_all_ffmpeg_services ;;
      6) return ;;
      *) ;;
    esac
  done
}

enable_watchdog_for_existing(){
  enable_watchdog_for_all_safe
}

##
# enable_watchdog_for_all_with_report
# Enables the watchdog timer for all FFmpeg stream services and prints
# a compact per-stream report showing enable result and current active state.
#
# Why: Quickly verify coverage across all streams without checking each unit.
##

enable_watchdog_for_selected(){
  show_streams_numbered || { pause; return; }
  local sel entry id output st
  mapfile -t sources < <(get_stream_lines)
  read -rp "Number to enable watchdog: " sel < /dev/tty
  entry="${sources[$((sel-1))]}"
  id="$(echo "$entry" | sed -nE 's|.*snapfifo_([^?]+)\?.*|\1|p')"
  [ -z "$id" ] && { echo "❌ Invalid selection"; pause; return; }
  systemctl daemon-reload
  if ! output=$(systemctl enable --now "ffmpeg-watchdog@${id}.timer" 2>&1); then
    echo "❌ Failed to enable watchdog for '${id}':"
    echo "$output"
  else
    st=$(systemctl is-active "ffmpeg-watchdog@${id}.timer" 2>/dev/null || echo "inactive")
    echo "✅ Watchdog enabled for '${id}' (status: ${st})."
  fi
  echo ""
  pause
}
 
disable_watchdog_for_selected(){
  show_streams_numbered || { pause; return; }
  local sel entry id
  mapfile -t sources < <(get_stream_lines)
  read -rp "Number to disable watchdog: " sel < /dev/tty
  entry="${sources[$((sel-1))]}"
  id="$(echo "$entry" | sed -nE 's|.*snapfifo_([^?]+)\?.*|\1|p')"
  [ -z "$id" ] && { echo "❌ Invalid selection"; pause; return; }
  systemctl stop "ffmpeg-watchdog@${id}.timer" 2>/dev/null || true
  systemctl disable "ffmpeg-watchdog@${id}.timer" 2>/dev/null || true
  systemctl stop "ffmpeg-watchdog@${id}.service" 2>/dev/null || true
  systemctl reset-failed "ffmpeg-watchdog@${id}.service" 2>/dev/null || true
  echo "✅ Watchdog disabled for '${id}'."
  echo ""
  pause
}

remove_watchdog_for_selected(){
  show_streams_numbered || { pause; return; }
  local sel entry id
  mapfile -t sources < <(get_stream_lines)
  read -rp "Number to delete watchdog: " sel < /dev/tty
  entry="${sources[$((sel-1))]}"
  id="$(echo "$entry" | sed -nE 's|.*snapfifo_([^?]+)\?.*|\1|p')"
  [ -z "$id" ] && { echo "❌ Invalid selection"; pause; return; }
  systemctl stop "ffmpeg-watchdog@${id}.timer" 2>/dev/null || true
  systemctl disable "ffmpeg-watchdog@${id}.timer" 2>/dev/null || true
  rm -f "${SYSTEMD_DIR}/timers.target.wants/ffmpeg-watchdog@${id}.timer" 2>/dev/null || true
  systemctl stop "ffmpeg-watchdog@${id}.service" 2>/dev/null || true
  systemctl reset-failed "ffmpeg-watchdog@${id}.service" 2>/dev/null || true
  systemctl daemon-reload
  echo "✅ Watchdog deleted for '${id}'."
  echo ""
  pause
}

check_watchdog_status_all(){
  echo ""
  printf "%-24s | %-8s | %-8s\n" "Stream" "Enabled" "Active"
  printf -- "-------------------------+----------+----------\n"
  local name id timer_service enabled st
  while IFS= read -r line; do
    name=$(echo "$line" | sed -nE 's/.*[?&]name=([^&]+).*/\1/p')
    id=$(echo "$line" | sed -nE 's|.*snapfifo_([^?]+)\?.*|\1|p')
    timer_service="ffmpeg-watchdog@${id}.timer"
    enabled=$(systemctl is-enabled "$timer_service" 2>/dev/null || echo "disabled")
    st=$(systemctl is-active "$timer_service" 2>/dev/null || echo "inactive")
    printf "%-24s | %-8s | %-8s\n" "$name" "$enabled" "$st"
  done < <(get_stream_lines)
  echo ""
  pause
}

enable_watchdog_for_all_safe(){
  echo ""
  echo "🛡️  Enabling Watchdog timers for all streams..."
  systemctl daemon-reload
  local -a ids
  ids=()
  local seen
  seen=""
  while IFS= read -r line; do
    local sid
    sid=$(echo "$line" | sed -nE 's|.*snapfifo_([^?]+)\?.*|\1|p')
    [ -z "$sid" ] && continue
    if [[ " $seen " != *" $sid "* ]]; then
      ids+=("$sid")
      seen+=" $sid"
    fi
  done < <(get_stream_lines)
  if [ ${#ids[@]} -eq 0 ]; then echo "❌ No streams found."; pause; return; fi
  local id
  for id in "${ids[@]}"; do
    systemctl enable --now "ffmpeg-watchdog@${id}.timer" >/dev/null 2>&1 || echo "⚠️  Failed to enable for ${id}"
  done
  echo "✅ Completed."
  echo ""
  pause
}

check_watchdog_status(){
  echo ""
  echo "🛡️  Current status of Watchdog timers (enabled only):"
  local count=0
  while IFS= read -r line; do
    local name id timer_service st enabled
    name=$(echo "$line" | sed -nE 's/.*[?&]name=([^&]+).*/\1/p')
    id=$(echo "$line" | sed -nE 's|.*snapfifo_([^?]+)\?.*|\1|p')
    timer_service="ffmpeg-watchdog@${id}.timer"
    enabled=$(systemctl is-enabled "$timer_service" 2>/dev/null || echo "absent")
    [ "$enabled" != "enabled" ] && continue
    st=$(systemctl is-active "$timer_service" 2>/dev/null || echo "inactive")
    printf "  • %-22s : %-10s (%s)\n" "'$name'" "$st" "$timer_service"
    ((count++))
  done < <(get_stream_lines)
  if [ "$count" -eq 0 ]; then echo "No enabled watchdog timers found."; fi
  echo ""
  pause
}

##
# (Removed) add_timeout_to_streams
# This function was deprecated per user request and removed to avoid
# modifying the stream URIs with a timeout parameter.
##


restart_all_ffmpeg_services(){
  echo ""
  echo "🔁 Restarting all FFmpeg services..."
  if ! systemctl restart ffmpeg-*.service; then
      echo "⚠️  Some services may have failed to restart. Use option 2 to check status."
  else
      echo "✅ Restart command sent successfully to all ffmpeg services."
  fi
  echo ""
  pause
}

# ────────────────────────────────────────────────────────────────────────────
# Backups
# ────────────────────────────────────────────────────────────────────────────
# Omitted for brevity, identical to previous version
do_backup(){
  local OUT="/var/backups/snapserver_backup_$(ts).tar.gz"
  echo "🧯 Creating backup at $OUT ..."
  mkdir -p /var/backups
  tar -czf "$OUT" \
    /var/lib/snapserver \
    "$CONF_FILE" \
    "$LOG_DIR" \
    "$SYSTEMD_DIR/ffmpeg-*.service" \
    "$SYSTEMD_DIR/snap-silence.service" \
    "$SYSTEMD_DIR/ffmpeg-watchdog@.service" \
    "$SYSTEMD_DIR/ffmpeg-watchdog@.timer" \
    /etc/logrotate.d/ffmpeg-snapstream 2>/dev/null || true
  echo "✅ Backup ready: $OUT"
  pause
}
do_restore(){
  local BK ans
  echo "🧰 Restore backup"
  ls -1 /var/backups/snapserver_backup_*.tar.gz 2>/dev/null || { echo "❌ No backups found in /var/backups/"; pause; return; }
  read -rp "Path of the backup to restore: " BK < /dev/tty
  [ -f "$BK" ] || { echo "❌ $BK does not exist"; pause; return; }
  read -rp "⚠️  This will overwrite the current configuration. Confirm? (y/N): " ans < /dev/tty
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "❌ Canceled"; pause; return; }
  echo "⛔ Stopping services..."; systemctl stop snapserver snap-silence.service ffmpeg-*.service ffmpeg-watchdog@*.timer 2>/dev/null || true
  echo "📦 Extracting files..."; tar -xzf "$BK" -C /
  echo "🔧 Applying permissions and reloading..."; chown -R "$SNAP_USER:$SNAP_GROUP" /var/lib/snapserver; [ -d "$LOG_DIR" ] && chown -R "$SNAP_USER:$SNAP_GROUP" "$LOG_DIR"; systemctl daemon-reload
  echo "🟢 Restarting restored services..."; systemctl restart snapserver || true
  if compgen -G "$SYSTEMD_DIR/ffmpeg-*.service" > /dev/null; then systemctl restart ffmpeg-*.service; fi
  if compgen -G "$SYSTEMD_DIR/ffmpeg-watchdog@*.timer" > /dev/null; then systemctl start ffmpeg-watchdog@*.timer; fi
  if [ -f "$SYSTEMD_DIR/snap-silence.service" ]; then systemctl restart snap-silence.service; fi
  echo "✅ Restored."; pause
}
backup_menu(){
  local b
  while true; do
    clear
    echo "──────────────── BACKUPS ─────────────────"
    echo "1) Create backup"
    echo "2) Restore backup"
    echo "3) Back"
    read -rp "Choose [1-3]: " b < /dev/tty
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
  trap - ERR

  ensure_prereqs
  detect_lxc
  # Initial configuration previously auto-run is now optional via Configuration menu
  # ensure_silence_fallback
  # ensure_default_pipe_sources
  # ensure_default_metastreams
  ensure_watchdog_templates
  systemctl daemon-reload
  ensure_logrotate

  local opt
  while true; do
    local active_count
    active_count=$(systemctl list-units --type=service --state=running "ffmpeg-*.service" | grep -c . || echo "0")
    
    clear
    echo "═══════════════════════════════════════════════════"
    echo "  🧩 SNAPSTREAM MANAGER v1.0.13 "
    echo "═══════════════════════════════════════════════════"
    echo "     🎚️  ${active_count} FFmpeg stream(s) currently running"
    echo "═══════════════════════════════════════════════════"
    echo "         ─── Stream Management ───"
    echo "1) Add new stream"
    echo "2) List / Check Status of streams"
    echo "3) Edit a stream's FFmpeg service"
    echo "4) Delete stream(s)"
    echo "         ─── System & Clients ───"
    echo "5) Client Management"
    echo "6) Backups (Create/Restore)"
    echo "S) Services (Status/Restart)"
    echo "C) Configuration (Silence & Defaults, LXC help)"
    echo "         ─── Maintenance ───"
    echo "L) Logs & Watchdog"
    echo "0) Exit"
    echo "═══════════════════════════════════════════════════"
    read -rp "Choose an option: " opt < /dev/tty
    case "$opt" in
      1) create_stream;;
      2) check_activity;;
      3) edit_stream;;
      4) delete_streams;;
      5) clients_menu;;
      6) backup_menu;;
      L|l) logs_and_watchdog_menu;;
      S|s) services_menu;;
      C|c) configuration_menu;;
      0) exit 0;;
      *) ;;
    esac
  done
}

# Defer main menu start until all functions are defined
##
# view_logs_snapserver
# Lets the user choose how many lines to show (default 50) and tails the
# Snapserver journal logs.
##
view_logs_snapserver(){
  local lines
  read -rp "Lines to show (default 50): " lines < /dev/tty
  lines=${lines:-50}
  echo ""
  echo "📜 Snapserver logs (last ${lines} lines):"
  journalctl -u snapserver -n "$lines" --no-pager || echo "❌ Could not read snapserver logs"
  echo ""
  pause
}

##
# view_logs_ffmpeg_service
# Shows the journal logs for a specific FFmpeg service selected by the user.
##
view_logs_ffmpeg_service(){
  show_streams_numbered || { pause; return; }
  local sel entry id svc lines
  mapfile -t sources < <(get_stream_lines)
  read -rp "Number to view logs: " sel < /dev/tty
  entry="${sources[$((sel-1))]}"
  id="$(echo "$entry" | sed -nE 's|.*snapfifo_([^?]+)\?.*|\1|p')"
  [ -z "$id" ] && { echo "❌ Invalid selection"; pause; return; }
  svc="ffmpeg-${id}.service"
  read -rp "Lines to show (default 50): " lines < /dev/tty
  lines=${lines:-50}
  echo ""
  echo "📜 Logs for ${svc} (last ${lines} lines):"
  journalctl -u "$svc" -n "$lines" --no-pager || echo "❌ Could not read logs for $svc"
  echo ""
  pause
}

##
# view_logs_watchdog
# Shows the journal logs for the watchdog timer/service for a selected stream.
##
view_logs_watchdog(){
  show_streams_numbered || { pause; return; }
  local sel entry id timer svc lines
  mapfile -t sources < <(get_stream_lines)
  read -rp "Number to view watchdog logs: " sel < /dev/tty
  entry="${sources[$((sel-1))]}"
  id="$(echo "$entry" | sed -nE 's|.*snapfifo_([^?]+)\?.*|\1|p')"
  [ -z "$id" ] && { echo "❌ Invalid selection"; pause; return; }
  timer="ffmpeg-watchdog@${id}.timer"
  svc="ffmpeg-watchdog@${id}.service"
  read -rp "Lines to show (default 50): " lines < /dev/tty
  lines=${lines:-50}
  echo ""
  echo "📜 Watchdog timer logs (${timer}) (last ${lines} lines):"
  journalctl -u "$timer" -n "$lines" --no-pager || echo "⚠️  No timer logs for ${timer}"
  echo ""
  echo "📜 Watchdog service logs (${svc}) (last ${lines} lines):"
  journalctl -u "$svc" -n "$lines" --no-pager || echo "⚠️  No service logs for ${svc}"
  echo ""
  pause
}

clear_watchdog_logs_selected(){
  show_streams_numbered || { pause; return; }
  local sel entry id log
  mapfile -t sources < <(get_stream_lines)
  read -rp "Number to clear watchdog log: " sel < /dev/tty
  entry="${sources[$((sel-1))]}"
  id="$(echo "$entry" | sed -nE 's|.*snapfifo_([^?]+)\?.*|\1|p')"
  [ -z "$id" ] && { echo "❌ Invalid selection"; pause; return; }
  log="$(log_file_for "$id")"
  mkdir -p "$(dirname "$log")"
  : > "$log"
  echo "✅ Watchdog log cleared for '${id}': $log"
  echo ""
  pause
}

##
# configure_watchdog_thresholds
# Allows the user to configure and persist watchdog thresholds. Writes to
# /etc/snapserver.d/snapstream-watchdog.conf and reloads systemd.
##
configure_watchdog_thresholds(){
  echo ""
  echo "⚙️  Configure Watchdog thresholds"
  local stale uptime pattern
  read -rp "Seconds without log update to consider frozen (default 90, 0 disables): " stale < /dev/tty
  read -rp "Minimum uptime before considering freeze (default 120): " uptime < /dev/tty
  read -rp "Error pattern regex (leave empty for default): " pattern < /dev/tty
  stale=${stale:-90}
  uptime=${uptime:-120}
  pattern=${pattern:-"(Connection timed out|Protocol not found|No route to host|End of file|Connection refused|HTTP error|Invalid data found when processing input)"}
  pattern_escaped=${pattern//\"/\\\"}
  mkdir -p "$(dirname "$WATCHDOG_CONF")"
  cat > "$WATCHDOG_CONF" <<EOF
# Snapstream Watchdog configuration (user-defined)
LOG_STALE_SECONDS=${stale}
MIN_UPTIME_SECONDS=${uptime}
ERROR_PATTERN_REGEX="${pattern_escaped}"
EOF
  echo "✅ Watchdog configuration saved to ${WATCHDOG_CONF}"
  systemctl daemon-reload
  echo ""
  pause
}

##
# logs_and_watchdog_menu
# Submenu to view logs and configure watchdog detection times.
##
logs_and_watchdog_menu(){
  local opt
  while true; do
    clear
    echo "──────────── Logs & Watchdog ────────────"
    echo "1) View Snapserver logs"
    echo "2) View FFmpeg service logs (select one)"
    echo "3) View Watchdog logs (select one)"
    echo "4) Enable Watchdog for selected stream"
    echo "5) Disable Watchdog for selected stream"
    echo "6) Delete Watchdog for selected stream"
    echo "7) Check Watchdog status"
    echo "8) Check Watchdog status (all streams)"
    echo "9) Enable Watchdog for all streams"
    echo "10) Configure Watchdog detection thresholds"
    echo "11) Clear Watchdog logs (select one)"
    echo "12) Back"
    echo "13) Force refresh Watchdog templates"
    read -rp "Choose [1-13]: " opt < /dev/tty
    case "$opt" in
      1) view_logs_snapserver ;;
      2) view_logs_ffmpeg_service ;;
      3) view_logs_watchdog ;;
      4) enable_watchdog_for_selected ;;
      5) disable_watchdog_for_selected ;;
      6) remove_watchdog_for_selected ;;
      7) check_watchdog_status ;;
      8) check_watchdog_status_all ;;
      9) enable_watchdog_for_all_safe ;;
      10) configure_watchdog_thresholds ;;
      11) clear_watchdog_logs_selected ;;
      12) return ;;
      13) force_refresh_watchdog_templates ;;
      *) ;;
    esac
  done
}

force_refresh_watchdog_templates(){
  local w_service="${SYSTEMD_DIR}/ffmpeg-watchdog@.service"
  local w_timer="${SYSTEMD_DIR}/ffmpeg-watchdog@.timer"
  local w_exec="/usr/local/bin/snap_ffmpeg_watchdog.sh"
  rm -f "$w_service" "$w_timer" "$w_exec" 2>/dev/null || true
  ensure_watchdog_templates
  systemctl daemon-reload
  echo "✅ Watchdog templates refreshed."
  pause
}

# ────────────────────────────────────────────────────────────────────────────
# Configuration Menu (manual actions)
# ────────────────────────────────────────────────────────────────────────────
#
# configuration_menu
# Provides manual configuration actions: LXC/local capture help, ensuring global Silence,
# declaring default pipe sources, and creating default MetaStreams.
#
configuration_menu(){
  local opt
  while true; do
    clear
    echo "═══════════════════════════════════════════════════"
    echo "  ⚙️  Configuration"
    echo "═══════════════════════════════════════════════════"
    echo "1) LXC / Local capture instructions"
    echo "2) Ensure global Silence source"
    echo "3) Ensure default pipe sources"
    echo "4) Ensure default MetaStreams (Silence fallback)"
    echo "5) Back"
    echo "═══════════════════════════════════════════════════"
    read -rp "Choose an option: " opt < /dev/tty
    case "$opt" in
      1) detect_lxc; lxc_instructions ;;
      2) ensure_silence_fallback ;;
      3) ensure_default_pipe_sources ;;
      4) ensure_default_metastreams ;;
      5) return ;;
      *) ;;
    esac
  done
}

# Start the main menu loop now that all functions are defined
main_menu
