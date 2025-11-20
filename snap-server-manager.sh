#!/bin/bash
# ==============================================================================
# SNAPSTREAM MANAGER v1.0.34
# Snapserver + FFmpeg Streams + Snapweb + JSON-RPC + Backups + LXC-aware
# Fixed loop bug, added timeout enforcement, and improved overall stability.
# Author: NaturalDevCR”
# Status: STABLE - Production ready.
# ==============================================================================

set -Eeuo pipefail

# --- Privilege Check ---
if [[ $EUID -ne 0 ]]; then
   echo "❌ This script must be run as root."
   exit 1
fi

# --- Global Variables (Readonly for Security) ---
readonly SNAP_FIFO_DIR="/var/lib/snapserver/fifo"
readonly SYSTEMD_DIR="/etc/systemd/system"
readonly CONF_FILE="/etc/snapserver.conf"
readonly BACKUP_DIR="/etc/snapserver.d/backups"
readonly CACHE_DIR="/var/cache/snapstream"
readonly LOG_DIR="/var/log/ffmpeg"
readonly SNAP_USER="snapserver"
readonly SNAP_GROUP="snapserver"
readonly DEFAULT_GROUP="Default"
readonly SNAP_RPC="http://127.0.0.1:1780/jsonrpc"
readonly WATCHDOG_CONF="/etc/snapserver.d/snapstream-watchdog.conf"

# --- Variables for Silent Fallback (integrated) ---
SILENCE_FIFO="$SNAP_FIFO_DIR/silence.fifo"
SILENCE_SERVICE="$SYSTEMD_DIR/snap-silence.service"

mkdir -p "$BACKUP_DIR" "$CACHE_DIR" "$LOG_DIR"
chown "$SNAP_USER:$SNAP_GROUP" "$LOG_DIR" 2>/dev/null || true

# --- Utility Functions ---
pause(){ read -rp "Press Enter to continue..." < /dev/tty; }
ts(){ date +"%Y-%m-%d_%H-%M-%S"; }
escape_sed(){ sed -e 's/[\/\&]/\\&/g' <<<"$1"; }

# --- Logging Function ---
SCRIPT_LOG="/var/log/snap-manager/operations.log"
log(){
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    mkdir -p "$(dirname "$SCRIPT_LOG")" 2>/dev/null
    echo "[${timestamp}] [${level}] ${message}" | tee -a "$SCRIPT_LOG" >&2
}

# --- Input Validation Functions ---
##
# validate_url
# Validates URL format and rejects dangerous characters to prevent command injection.
# Returns the URL if valid, returns 1 if invalid.
##
validate_url(){
    local url="$1"
    
    # Check for valid URL scheme
    if [[ ! "$url" =~ ^(https?|rtsp|rtmp|rtp):// ]]; then
        echo "❌ Invalid URL format. Must start with http://, https://, rtsp://, rtmp://, or rtp://" >&2
        return 1
    fi
    
    # Reject URLs with dangerous shell characters
    if [[ "$url" =~ [\$\(\)\;\|\&\<\>\`] ]]; then
        echo "❌ URL contains dangerous characters: \$, (, ), ;, |, &, <, >, or \`" >&2
        return 1
    fi
    
    # Check for reasonable length (max 2048 chars)
    if [ ${#url} -gt 2048 ]; then
        echo "❌ URL too long (max 2048 characters)" >&2
        return 1
    fi
    
    echo "$url"
}

##
# validate_number
# Validates that input is a positive integer within an optional range.
# Usage: validate_number VALUE [MIN] [MAX]
##
validate_number(){
    local value="$1"
    local min="${2:-1}"
    local max="${3:-999999}"
    
    # Check if it's a valid positive integer
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        echo "❌ Invalid input. Please enter a positive number." >&2
        return 1
    fi
    
    # Check range
    if [ "$value" -lt "$min" ] || [ "$value" -gt "$max" ]; then
        echo "❌ Number out of range. Valid range: ${min}-${max}" >&2
        return 1
    fi
    
    echo "$value"
}

##
# validate_path
# Validates file path to prevent directory traversal attacks.
# Usage: validate_path PATH BASE_DIR
##
validate_path(){
    local path="$1"
    local base_dir="${2:-/}"
    
    # Check if path exists
    if [ ! -e "$path" ]; then
        echo "❌ Path does not exist: $path" >&2
        return 1
    fi
    
    # Resolve to absolute path
    local real_path
    real_path=$(realpath "$path" 2>/dev/null) || {
        echo "❌ Cannot resolve path: $path" >&2
        return 1
    }
    
    # If base_dir specified, verify path is within it
    if [ "$base_dir" != "/" ]; then
        local real_base
        real_base=$(realpath "$base_dir" 2>/dev/null) || real_base="$base_dir"
        
        if [[ "$real_path" != "$real_base"* ]]; then
            echo "❌ Path outside allowed directory: $base_dir" >&2
            return 1
        fi
    fi
    
    echo "$real_path"
}

##
# wait_for_service
# Waits for a systemd service to become active with timeout.
# Usage: wait_for_service SERVICE_NAME [TIMEOUT_SECONDS]
##
wait_for_service(){
    local service="$1"
    local timeout="${2:-10}"
    local elapsed=0
    
    while [ $elapsed -lt $timeout ]; do
        if systemctl is-active "$service" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        ((elapsed++))
    done
    
    return 1
}

##
# check_disk_space
# Checks if sufficient disk space is available.
# Usage: check_disk_space REQUIRED_MB [PATH]
##
check_disk_space(){
    local required_mb="$1"
    local path="${2:-.}"
    
    local available_mb
    available_mb=$(df -BM "$path" 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'M')
    
    if ! [[ "$available_mb" =~ ^[0-9]+$ ]]; then
        log "WARN" "Cannot determine disk space for $path"
        return 0  # Proceed with caution
    fi
    
    if [ "$available_mb" -lt "$required_mb" ]; then
        echo "❌ Insufficient disk space. Required: ${required_mb}MB, Available: ${available_mb}MB" >&2
        return 1
    fi
    
    return 0
}

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

pretty_name_from_id(){
  local id="$1"

  # 1. Convertir separadores (- y _) a espacio
  id="${id//_/ }"
  id="${id//-/ }"

  # 2. Insertar espacios entre cambios de mayúscula/minúscula
  id=$(echo "$id" | sed -E 's/([a-z])([A-Z])/\1 \2/g')

  # 3. Dividir palabras en secuencias lógicas
  local out=""
  for w in $id; do
    # Casos especiales (siglas)
    case "$w" in
      pc) w="PC" ;;
      swyh) w="SWYH" ;;
      ffmpeg) w="FFmpeg" ;;
    esac

    # Si después de eso todavía es minúscula → capitalizar
    if [[ "$w" =~ ^[a-z] ]]; then
      w="$(tr '[:lower:]' '[:upper:]' <<< "${w:0:1}")${w:1}"
    fi

    out+="$w "
  done

  echo "${out%" "}"
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
  log "INFO" "Starting prerequisites installation"
  
  # Update package lists
  if ! apt-get update -y; then
    echo "❌ Failed to update package lists" >&2
    log "ERROR" "apt-get update failed"
    return 1
  fi
  
  # Install each package individually with validation
  local pkg
  for pkg in ffmpeg curl jq; do
    if ! command -v "$pkg" >/dev/null 2>&1; then
      echo "📦 Installing $pkg..."
      if ! apt-get install -y "$pkg"; then
        echo "❌ Failed to install $pkg" >&2
        log "ERROR" "Failed to install package: $pkg"
        return 1
      fi
      log "INFO" "Installed package: $pkg"
    else
      echo "✅ $pkg already installed"
    fi
  done

  # Create snapserver user if needed
  if ! id -u "$SNAP_USER" >/dev/null 2>&1; then
    useradd -r -s /usr/sbin/nologin "$SNAP_USER"
    log "INFO" "Created user: $SNAP_USER"
  fi
  
  # Backup existing configurations
  [ -f "$CACHE_DIR/snapserver_current.deb" ] && cp -f "$CACHE_DIR/snapserver_current.deb" "$BACKUP_DIR/snapserver_prev.deb" || true
  [ -f "$CONF_FILE" ] && cp -f "$CONF_FILE" "$BACKUP_DIR/snapserver.conf.prev" || true

  local ARCH CODENAME RELEASE_API SNAPVER PACKAGE_URL FILENAME
  ARCH="$(dpkg --print-architecture)"
  CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-unknown}")"
  RELEASE_API="https://api.github.com/repos/badaix/snapcast/releases/latest"

  echo "⬇️ Searching for the latest release…"
  SNAPVER="$(curl -s "$RELEASE_API" | jq -r '.tag_name')"
  if [ -z "$SNAPVER" ] || [ "$SNAPVER" = "null" ]; then
    echo "❌ Could not get Snapcast version from GitHub."
    log "ERROR" "Failed to fetch Snapcast version from GitHub"
    if [ -f "$BACKUP_DIR/snapserver_prev.deb" ]; then dpkg -i "$BACKUP_DIR/snapserver_prev.deb"; fi
    return 1
  fi
  log "INFO" "Found Snapcast version: $SNAPVER"
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

  if [ -z "$PACKAGE_URL" ] || [ "$PACKAGE_URL" = "null" ]; then
    echo "❌ No compatible package found for your OS/Arch."
    log "ERROR" "No compatible Snapcast package found for $CODENAME/$ARCH"
    return 1
  fi

  FILENAME="/tmp/$(basename "$PACKAGE_URL")"
  echo "📦 Downloading: $PACKAGE_URL"
  log "INFO" "Downloading Snapserver package"
  
  if ! curl -L -o "$FILENAME" "$PACKAGE_URL"; then
    echo "❌ Download failed."
    log "ERROR" "Failed to download Snapserver package"
    return 1
  fi

  echo "📦 Installing..."
  if ! dpkg -i "$FILENAME"; then
    echo "dpkg failed, trying to fix dependencies..."
    if ! apt-get -f install -y; then
        echo "❌ Failed to install package and fix dependencies."
        log "ERROR" "Failed to install Snapserver package"
        if [ -f "$BACKUP_DIR/snapserver_prev.deb" ]; then 
          echo "🔄 Attempting to restore previous version..."
          dpkg -i "$BACKUP_DIR/snapserver_prev.deb"
        fi
        return 1
    fi
  fi
  
  cp -f "$FILENAME" "$CACHE_DIR/snapserver_current.deb" || true
  log "INFO" "Snapserver package installed successfully"

  mkdir -p "$SNAP_FIFO_DIR" /var/lib/snapserver/config
  chown -R "$SNAP_USER:$SNAP_GROUP" /var/lib/snapserver
  [ -f "$CONF_FILE" ] || echo "[stream]" > "$CONF_FILE"

  systemctl daemon-reload
  systemctl enable snapserver
  systemctl restart snapserver || true
  
  log "INFO" "Snapserver installed and enabled"
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
  log "INFO" "Ensuring global Silence fallback source"
  
  local snap_home
  snap_home="$(getent passwd "$SNAP_USER" | cut -d: -f6)"
  if [ "$snap_home" != "/var/lib/snapserver" ]; then
    echo "🩹 Fixing home directory for user '$SNAP_USER' → /var/lib/snapserver"
    log "INFO" "Fixing home directory for $SNAP_USER"
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
  local tmp_conf
  tmp_conf="$(mktemp /tmp/snapserver.XXXXXXXXXX)" || {
    log "ERROR" "Failed to create temporary file"
    return 1
  }
  trap 'rm -f "$tmp_conf" 2>/dev/null' RETURN ERR
  
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
  chown "$SNAP_USER:$SNAP_GROUP" "$CONF_FILE"
  
  log "INFO" "Global Silence source configured"
  echo "✅ Silence global agregado/actualizado en la sección [stream]."
  echo ""
}

# ────────────────────────────────────────────────────────────────────────────
# JSON-RPC: Client Management
# ────────────────────────────────────────────────────────────────────────────
##
# rpc
# Makes JSON-RPC calls to Snapserver with retry logic for resilience.
# Retries up to 3 times with exponential backoff on failure.
##
rpc(){
    local payload="$1"
    local max_retries=3
    local retry_delay=2
    local response
    local attempt
    
    for attempt in $(seq 1 $max_retries); do
        if response=$(curl --fail -s \
            --connect-timeout 5 \
            --max-time 10 \
            -H 'Content-Type: application/json' \
            -X POST "$SNAP_RPC" \
            -d "$payload" 2>&1); then
            echo "$response"
            return 0
        fi
        
        if [ "$attempt" -lt "$max_retries" ]; then
            log "WARN" "RPC attempt $attempt failed, retrying in ${retry_delay}s..."
            echo "⚠️  RPC attempt $attempt failed, retrying in ${retry_delay}s..." >&2
            sleep "$retry_delay"
            # Exponential backoff
            retry_delay=$((retry_delay * 2))
        fi
    done
    
    log "ERROR" "RPC failed after $max_retries attempts"
    echo "RPC_ERROR: Failed to communicate with Snapserver on ${SNAP_RPC} after $max_retries attempts." >&2
    echo "Last error: ${response}" >&2
    return 1
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
  
  # Validate JSON response
  local count
  if ! count=$(echo "$response" | jq -e '.result.server.clients | length' 2>/dev/null); then
      echo "❌ Failed to parse JSON response from Snapserver."
      log "ERROR" "Invalid JSON response from Snapserver"
      pause
      return
  fi
  
  # Validate count is a number
  if ! [[ "$count" =~ ^[0-9]+$ ]]; then
      echo "❌ Invalid client count in server response."
      pause
      return
  fi
  
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
  
  local -a ids
  local id host name
  
  # Use mapfile for safer array handling
  mapfile -t ids < <(echo "$js" | jq -r '.result.server.clients[].id')
  
  for id in "${ids[@]}"; do
    host="$(echo "$js" | jq -r ".result.server.clients[] | select(.id==\"$id\") | (.host.name // .host.address // \"client\")")"
    name="${host%%.*}"
    [ -z "$name" ] && name="client-$id"
    rpc "$(jq -n --arg id "$id" --arg name "$name" '{id:2,"jsonrpc":"2.0","method":"Client.SetName","params":{"id":$id,"name":$name}}')" >/dev/null
    echo "  • Client $id → renamed to '$name'"
  done
  
  log "INFO" "Auto-named ${#ids[@]} clients"
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
  
  local -a ids
  local client_ids_json
  
  # Use mapfile for safer array handling
  mapfile -t ids < <(echo "$js" | jq -r '.result.server.clients[].id')
  
  client_ids_json=$(printf '%s\n' "${ids[@]}" | jq -R . | jq -s .)
  rpc "$(jq -n --argjson ids "$client_ids_json" --arg grp "$DEFAULT_GROUP" '{id:3,"jsonrpc":"2.0","method":"Group.SetClients","params":{"id":$grp,"clients":$ids}}')" >/dev/null
  
  log "INFO" "Grouped ${#ids[@]} clients into $DEFAULT_GROUP"
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
    in_stream && (/^[[:space:]]*source[[:space:]]*=[[:space:]]*pipe:/ || /^[[:space:]]*source[[:space:]]*=[[:space:]]*tcp:/) { print }
  ' "$CONF_FILE"
}

rebuild_all_units(){
  echo ""
  echo "🔧 Rebuilding ALL FFmpeg units using the latest template…"
  echo ""

  for svc in /etc/systemd/system/ffmpeg-*.service; do
    [ -e "$svc" ] || continue

    local service_name stream_id fifo stream_name
    service_name=$(basename "$svc")
    stream_id=$(echo "$service_name" | sed -E 's/^ffmpeg-(.+)\.service$/\1/')
    fifo=$(fifo_path_for "$stream_id")
    stream_name=$(pretty_name_from_id "$stream_id")

    echo "• Migrating: ${service_name}  (ID=${stream_id}, FIFO=${fifo})"

    # Extraer la línea antigua manejando continuaciones de línea (backslashes)
    local old_line
    old_line=$(awk '/^ExecStart=/ {
        sub(/^ExecStart=/, "")
        line = $0
        while (line ~ /\\$/) {
            sub(/\\$/, "", line)
            if (getline > 0) {
                sub(/^[[:space:]]+/, "", $0)
                line = line " " $0
            } else {
                break
            }
        }
        print line
        exit
    }' "$svc")

    if [ -z "$old_line" ]; then
      echo "  ⚠️  Cannot extract ExecStart from $service_name — skipped."
      continue
    fi

    # Extraer solo los INPUT_ARGS del FFmpeg
    # Esto elimina:
    # 1. Todo desde /usr/bin/ffmpeg hasta (e incluyendo) -rw_timeout y su valor
    # 2. Todo desde -acodec hasta el final (opciones de output)
    # Lo que queda debe ser solo los argumentos de input (típicamente -i <url> y opciones de input)
    local input_args
    input_args=$(echo "$old_line" \
      | sed -E 's|^.*/usr/bin/ffmpeg[[:space:]]+||' \
      | sed -E 's/(-hide_banner|-nostats|-loglevel[[:space:]]+[^[:space:]]+|-nostdin)[[:space:]]*//g' \
      | sed -E 's/(-reconnect[_a-z]*[[:space:]]+[0-9]+)[[:space:]]*//g' \
      | sed -E 's/(-rw_timeout[[:space:]]+[0-9]+)[[:space:]]*//g' \
      | sed -E 's/[[:space:]]*-acodec.*$//' \
      | sed -E 's/[[:space:]]*-f[[:space:]]+s16le.*$//' \
      | sed -E 's/\\[[:space:]]*//g' \
      | sed -E 's/[[:space:]]+/ /g' \
      | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//'
    )

    if [ -z "$input_args" ]; then
       echo "  ⚠️  Could not reconstruct INPUT_ARGS (empty?) — skipping to avoid data loss."
       continue
    fi

    # Construye FFmpeg desde tu nueva función
    local new_ffmpeg_line
    new_ffmpeg_line=$(ffmpeg_cmd_for "$input_args" "$fifo")

    # Reescribe el unit con tu plantilla unificada
    write_unit "$service_name" "$new_ffmpeg_line" "$stream_name" "$stream_id" "$fifo"

    echo "  ✅ Rebuilt."
  done

  echo ""
  echo "🔁 Reloading Systemd and restarting all ffmpeg services…"
  systemctl daemon-reload

  for svc in /etc/systemd/system/ffmpeg-*.service; do
    [ -e "$svc" ] || continue
    systemctl restart "$(basename "$svc")" 2>/dev/null || true
  done

  echo "🔁 Restarting Snapserver…"
  systemctl restart snapserver

  echo ""
  echo "🎉 All units successfully migrated to the new standard."
  pause
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

##
# ensure_fifo
# Creates or repairs a FIFO pipe with atomic operations to prevent race conditions.
# Uses temporary file creation and atomic rename for safer concurrent access.
##
ensure_fifo(){
  local fp="$1"
  local temp_fifo="${fp}.tmp.$$"
  
  # Cleanup trap for temporary FIFO
  trap 'rm -f "$temp_fifo" 2>/dev/null' RETURN ERR
  
  # Si existe pero NO ES un FIFO → eliminar (alguien creó un archivo en su lugar)
  if [ -e "$fp" ] && [ ! -p "$fp" ]; then
    log "WARN" "Removing non-FIFO file at $fp"
    rm -f "$fp"
  fi

  # Si el FIFO no existe → crearlo de forma más segura
  if [ ! -p "$fp" ]; then
    log "INFO" "Creating FIFO: $fp"
    
    # Crear FIFO temporal primero con permisos correctos
    if ! mkfifo -m 666 "$temp_fifo" 2>/dev/null; then
      log "ERROR" "Failed to create temporary FIFO: $temp_fifo"
      return 1
    fi
    
    if ! chown "$SNAP_USER:$SNAP_GROUP" "$temp_fifo" 2>/dev/null; then
      log "WARN" "Failed to set ownership on temporary FIFO"
      rm -f "$temp_fifo"
      return 1
    fi
    
    # Mover atómicamente (más seguro contra race conditions)
    if ! mv "$temp_fifo" "$fp" 2>/dev/null; then
      # Si falla, probablemente el FIFO ya existe (lo creó otro proceso)
      rm -f "$temp_fifo"
      if [ -p "$fp" ]; then
        log "INFO" "FIFO already exists (created by another process): $fp"
      else
        log "ERROR" "Failed to create FIFO: $fp"
        return 1
      fi
    fi
    
    return 0
  fi

  # Si existe, verificar si está siendo usado por FFmpeg
  local pid
  pid=$(fuser "$fp" 2>/dev/null | tr -d ' ' || true)

  # Si no hay writers activos → regenerarlo (sanitizar pipes corruptos)
  if [ -z "$pid" ]; then
    log "INFO" "Regenerating unused FIFO: $fp"
    rm -f "$fp"
    mkfifo -m 666 "$fp"
    chown "$SNAP_USER:$SNAP_GROUP" "$fp" 2>/dev/null || true
  else
    # FIFO en uso, solo corregir permisos si es necesario
    chown "$SNAP_USER:$SNAP_GROUP" "$fp" 2>/dev/null || true
    chmod 666 "$fp" 2>/dev/null || true
  fi
}

write_unit(){
  local service_name="$1"
  local ffmpeg_line="$2"
  local stream_name="$3"
  local stream_id="$4"
  local fifo_path="$5"
  local log_file
  log_file="$(log_file_for "$stream_id")"

  cat > "${SYSTEMD_DIR}/${service_name}" <<EOF
[Unit]
Description=FFmpeg Stream for ${stream_name}
After=network-online.target snapserver.service
Requires=snapserver.service
PartOf=snapserver.service
StartLimitIntervalSec=30
StartLimitBurst=10

[Service]
# --- AJUSTES DE SEGURIDAD Y WATCHDOG ---
TimeoutStopSec=10
KillMode=mixed

# Nota el signo '+' al inicio. Esto permite que mkdir/chown corran como ROOT
ExecStartPre=+/bin/bash -c 'for i in {1..10}; do [ -p "${fifo_path}" ] && exit 0 || sleep 1; done; exit 1'
ExecStartPre=+/bin/bash -c 'if [ ! -p "${fifo_path}" ]; then echo "[FFMPEG] FIFO missing, creating: ${fifo_path}"; rm -f "${fifo_path}"; mkfifo "${fifo_path}"; chown ${SNAP_USER}:${SNAP_GROUP} "${fifo_path}"; chmod 666 "${fifo_path}"; fi'

ExecStart=${ffmpeg_line}

# Nota el signo '+' aquí también para limpiar
ExecStopPost=+/bin/bash -c 'echo "[FFMPEG] Regenerating FIFO after stop: ${fifo_path}"; rm -f "${fifo_path}"; mkfifo "${fifo_path}"; chown ${SNAP_USER}:${SNAP_GROUP} "${fifo_path}"; chmod 666 "${fifo_path}";'

User=${SNAP_USER}
Restart=always
RestartSec=5
LimitNOFILE=65536

StandardOutput=append:${log_file}
StandardError=append:${log_file}

[Install]
WantedBy=multi-user.target
EOF
}


ensure_watchdog_templates(){
  local w_service="${SYSTEMD_DIR}/ffmpeg-watchdog@.service"
  local w_timer="${SYSTEMD_DIR}/ffmpeg-watchdog@.timer"
  local w_exec="/usr/local/bin/snap_ffmpeg_watchdog.sh"
  local watchdog_conf="/etc/snapserver.d/snapstream-watchdog.conf"

  # Asegurar directorio de logs global
  mkdir -p /var/log/ffmpeg

  # ================================================================
  # Siempre refrescar el script del watchdog (evitar versiones viejas)
  # ================================================================
  echo "⚙️ Updating watchdog executor script..."
  cat > "$w_exec" <<'EOF'
#!/bin/bash
set -e

INSTANCE="$1"
UNIT="ffmpeg-${INSTANCE}.service"
LOG="/var/log/ffmpeg/ffmpeg-${INSTANCE}.log"
FIFO="/var/lib/snapserver/fifo/snapfifo_${INSTANCE}"
WLOG="/var/log/ffmpeg/watchdog-${INSTANCE}.log"

REASON=""

# Asegurar directorios de logs
LOG_DIR="$(dirname "$LOG")"
mkdir -p "$LOG_DIR"
mkdir -p "$(dirname "$WLOG")"
touch "$WLOG"
chown snapserver:snapserver "$WLOG" 2>/dev/null || true

# --- Load defaults or EnvironmentFile overrides ---
LOG_STALE_SECONDS="${LOG_STALE_SECONDS:-0}"
MIN_UPTIME_SECONDS="${MIN_UPTIME_SECONDS:-45}"
ERROR_PATTERN_REGEX="${ERROR_PATTERN_REGEX:-"(Connection timed out|Protocol not found|No route to host|End of file|Connection refused|HTTP error|Invalid data found when processing input)"}"

# --- Sanitize regex (remove accidental surrounding quotes) ---
PATTERN="${ERROR_PATTERN_REGEX}"
PATTERN="${PATTERN#\"}"
PATTERN="${PATTERN%\"}"

# ================================================================
# Pre-lectura de estado de systemd (para CrashLoop detection)
# ================================================================
UNIT_STATE="$(systemctl show "$UNIT" -p ActiveState --value 2>/dev/null || echo "unknown")"
NRESTARTS="$(systemctl show "$UNIT" -p NRestarts --value 2>/dev/null || echo 0)"

# ================================================================
# 1) BASIC HEALTH CHECKS + CrashLoop básico
# ================================================================
if [ "$UNIT_STATE" != "active" ]; then
    # Servicio no está activo ahora; revisar si viene de un storm de reinicios
    if [[ "$NRESTARTS" =~ ^[0-9]+$ ]] && [ "$NRESTARTS" -gt 5 ]; then
        REASON="service not active (CrashLoop detected, NRestarts=${NRESTARTS})"
    else
        REASON="service was not active"
    fi

elif [ -z "$FIFO" ] || [ ! -p "$FIFO" ]; then
    REASON="FIFO pipe was missing"

elif [ -f "${LOG}" ]; then

    # ================================================================
    # 2) CRITICAL ERROR PATTERN CHECK
    # ================================================================
    if [ -n "${PATTERN}" ]; then
        if ! printf '' | grep -E -q "${PATTERN}" 2>/dev/null; then
            PATTERN=""
            echo "[WATCHDOG] Invalid ERROR_PATTERN_REGEX, disabling pattern check." >> "${LOG}"
        fi
    fi

    if [ -n "${PATTERN}" ]; then
        if tail -n 200 "${LOG}" 2>/dev/null | grep -E -q "${PATTERN}"; then
            REASON="detected critical FFmpeg error pattern"
        fi
    fi

    # ================================================================
    # 3) FFmpeg write_bytes delta (detect frozen encoder)
    # ================================================================
    if [ -z "$REASON" ]; then
        PID=$(systemctl show "$UNIT" -p MainPID --value 2>/dev/null || echo "")

        if [[ "$PID" =~ ^[0-9]+$ ]] && [ "$PID" -gt 1 ]; then
            W1=$(awk '/write_bytes/ {print $2}' "/proc/$PID/io" 2>/dev/null || echo "")
            sleep 0.5
            W2=$(awk '/write_bytes/ {print $2}' "/proc/$PID/io" 2>/dev/null || echo "")

            if [[ "$W1" =~ ^[0-9]+$ ]] && [[ "$W2" =~ ^[0-9]+$ ]] && [ "$W1" -eq "$W2" ]; then
                REASON="ffmpeg appears frozen (no write_bytes delta)"
            fi
        fi
    fi

    # ================================================================
    # 4) LOG STALE CHECK (detect silent hangs)
    # ================================================================
    if [ -z "$REASON" ] && [[ "$LOG_STALE_SECONDS" =~ ^[0-9]+$ ]] && [ "$LOG_STALE_SECONDS" -gt 0 ]; then
        NOW=$(date +%s)
        LOG_MTIME=$(stat -c %Y "$LOG" 2>/dev/null || echo "$NOW")
        LAST_UPDATE=$(( NOW - LOG_MTIME ))

        if [ "$LAST_UPDATE" -gt "$LOG_STALE_SECONDS" ]; then
            ACTIVE_SINCE_BOOT=$(systemctl show "$UNIT" -p ActiveEnterTimestampMonotonic --value 2>/dev/null || echo 0)
            UPTIME=$(awk '{print int($1)}' /proc/uptime)

            if [[ "$ACTIVE_SINCE_BOOT" =~ ^[0-9]+$ ]]; then
                ACTIVE_SEC=$(( ACTIVE_SINCE_BOOT / 1000000 ))
                RUNTIME=$(( UPTIME - ACTIVE_SEC ))

                if [ "$RUNTIME" -gt "$MIN_UPTIME_SECONDS" ]; then
                    REASON="process frozen (log not updated for ${LAST_UPDATE}s)"
                fi
            fi
        fi
    fi
fi

# ================================================================
# 5) EXECUTE RECOVERY IF NEEDED
# ================================================================
if [ -n "$REASON" ]; then

    # Backup previous log
    if [ -f "$LOG" ]; then
        mv "$LOG" "$LOG.prev.$(date +%s)" 2>/dev/null || true
    fi

    echo "[$(date -Iseconds)] ACTION: $UNIT — $REASON (systemctl restart)" >> "$WLOG"

    # Restart FFmpeg service
    systemctl restart "$UNIT"

    # Recreate fresh log
    sleep 1
    : > "$LOG"
    chown snapserver:snapserver "$LOG" 2>/dev/null || true

    # Asegurar que el FIFO exista después del restart (por si ExecStopPost no corrió)
    if [ -n "$FIFO" ]; then
        if [ ! -p "$FIFO" ]; then
            rm -f "$FIFO" 2>/dev/null || true
            mkdir -p "$(dirname "$FIFO")"
            mkfifo "$FIFO"
            chown snapserver:snapserver "$FIFO" 2>/dev/null || true
            chmod 666 "$FIFO" 2>/dev/null || true
            echo "[WATCHDOG] FIFO recreated at $FIFO" >> "$LOG"
        fi
    fi

    echo "[WATCHDOG] Restarted $UNIT — Reason: $REASON" >> "$LOG"

else
    # Estado saludable, loguear OK del watchdog
    echo "[$(date -Iseconds)] OK: $UNIT healthy (state=${UNIT_STATE}, NRestarts=${NRESTARTS})" >> "$WLOG"
fi

EOF
  chmod 0755 "$w_exec"

  # ================================================================
  # Create systemd service template (if missing)
  # ================================================================
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

  # ================================================================
  # Create timer template (if missing)
  # ================================================================
  if [ ! -f "$w_timer" ]; then
    echo "⚙️ Creating FFmpeg watchdog timer template..."
    cat > "$w_timer" <<'EOF'
[Unit]
Description=Run FFmpeg Watchdog for %i every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
EOF
  fi

  # ================================================================
  # Create watchdog default config if missing
  # ================================================================
  if [ ! -f "$watchdog_conf" ]; then
    mkdir -p "$(dirname "$watchdog_conf")"
    cat > "$watchdog_conf" <<'EOF'
# Snapstream Watchdog configuration (defaults)
LOG_STALE_SECONDS=0
MIN_UPTIME_SECONDS=45
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
  local INPUT_ARGS="$1"
  local FIFO_PATH="$2"

  echo "/usr/bin/ffmpeg \
    -hide_banner -nostats -loglevel error -nostdin \
    -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 \
    -rw_timeout 15000000 \
    ${INPUT_ARGS} \
    -acodec pcm_s16le -ac 2 -ar 48000 \
    -f s16le -flush_packets 1 -y \"${FIFO_PATH}\""
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
  local tmp_conf
  tmp_conf="$(mktemp /tmp/snapserver.XXXXXXXXXX)" || {
    log "ERROR" "Failed to create temporary file"
    return 1
  }
  trap 'rm -f "$tmp_conf" 2>/dev/null' RETURN ERR

  local new_line="source = pipe:///${fifo}?name=${name}&codec=null&sampleformat=${sample}"

  awk -v fifo_path="${fifo}" \
      -v new_line="${new_line}" '
      BEGIN { in_stream=0; found=0 }
      /^\[stream\]/ { print; in_stream=1; next }
      /^\[/ {
          if (in_stream && !found) print new_line
          in_stream=0
      }
      in_stream && index($0,fifo_path)>0 { found=1; next }
      { print }
      END {
          if (in_stream && !found) print new_line
      }
  ' "$CONF_FILE" > "$tmp_conf"

  mv "$tmp_conf" "$CONF_FILE"
  chown "$SNAP_USER:$SNAP_GROUP" "$CONF_FILE"
}

##
# add_or_replace_tcp_stream_line
# Adds or updates a TCP source line in the `[stream]` section.
# Format: source = tcp://0.0.0.0:<PORT>?name=<NAME>&codec=null&sampleformat=48000:16:2
##
add_or_replace_tcp_stream_line(){
  local port="$1" name="$2" sample="48000:16:2"
  local tmp_conf
  tmp_conf="$(mktemp /tmp/snapserver.XXXXXXXXXX)" || {
    log "ERROR" "Failed to create temporary file"
    return 1
  }
  trap 'rm -f "$tmp_conf" 2>/dev/null' RETURN ERR

  local new_line="source = tcp://0.0.0.0:${port}?name=${name}&codec=null&sampleformat=${sample}"

  awk -v port="${port}" \
      -v new_line="${new_line}" '
      BEGIN { in_stream=0; found=0 }
      /^\[stream\]/ { print; in_stream=1; next }
      /^\[/ {
          if (in_stream && !found) print new_line
          in_stream=0
      }
      # Match existing TCP line with same port
      in_stream && $0 ~ "tcp://0.0.0.0:" port { found=1; print new_line; next }
      { print }
      END {
          if (in_stream && !found) print new_line
      }
  ' "$CONF_FILE" > "$tmp_conf"

  mv "$tmp_conf" "$CONF_FILE"
  chown "$SNAP_USER:$SNAP_GROUP" "$CONF_FILE"
}


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
  local source_name="$1"
  local meta_name="$2"
  local sample="48000:16:2"
  local tmp_conf
  tmp_conf="$(mktemp /tmp/snapserver.XXXXXXXXXX)" || {
    log "ERROR" "Failed to create temporary file"
    return 1
  }
  trap 'rm -f "$tmp_conf" 2>/dev/null' RETURN ERR

  local new_line="source = meta:///${source_name}/Silence?name=${meta_name}&codec=pcm&sampleformat=${sample}"

  awk -v src="${source_name}" \
      -v new_line="${new_line}" '
      BEGIN { in_stream=0; found=0 }
      /^\[stream\]/ { print; in_stream=1; next }
      /^\[/ {
          if (in_stream && !found) print new_line
          in_stream=0
      }
      in_stream && index($0, "meta:///" src "/Silence")>0 { found=1; next }
      { print }
      END {
          if (in_stream && !found) print new_line
      }
  ' "$CONF_FILE" > "$tmp_conf"

  mv "$tmp_conf" "$CONF_FILE"
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

  local svc stream_id fifo stream_name

  # Recorre todos los ffmpeg-*.service existentes
  for svc in /etc/systemd/system/ffmpeg-*.service; do
    [ -e "$svc" ] || continue

    stream_id=$(basename "$svc" | sed -E 's/^ffmpeg-(.+)\.service$/\1/')
    [ -z "$stream_id" ] && continue

    fifo="$(fifo_path_for "$stream_id")"
    stream_name="$(pretty_name_from_id "$stream_id")"

    add_or_replace_stream_line "$fifo" "$stream_name"
  done

  echo "✅ Default pipe sources updated based on existing FFmpeg services."
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
  echo "🧩 Ensuring default MetaStreams (pretty names + Silence fallback)…"

  # Confirmar que Silence existe primero
  if ! grep -qE '^\s*source\s*=\s*process:///usr/bin/ffmpeg.*name=Silence' "$CONF_FILE"; then
    echo "⚠️  Global 'Silence' source missing in config."
    echo "    Run 'Ensure global Silence stream' first."
    pause
    return
  fi

  local svc stream_id source_name meta_name

  # Recorrer todos los services ffmpeg-*.service existentes
  for svc in /etc/systemd/system/ffmpeg-*.service; do
    [ -e "$svc" ] || continue

    # Obtener ID del archivo
    stream_id=$(basename "$svc" | sed -E 's/^ffmpeg-(.+)\.service$/\1/')
    [ -z "$stream_id" ] && continue

    # Generar nombres bonitos
    source_name=$(pretty_name_from_id "$stream_id")
    meta_name="$source_name"

    # Agregar MetaStream
    add_or_replace_metastream_line "$source_name" "$meta_name"
  done

  echo "✅ Default MetaStreams refreshed."
}



create_stream(){
  echo ""
  echo "➕ Create new stream"
  echo "1) URL (HTTP/HTTPS/RTSP/RTMP)"
  echo "2) Local file (infinite loop)"
  echo "3) Custom FFmpeg (input arguments only)"
  echo "4) TCP Source (e.g. Windows PC)"

  local kind STREAM_NAME STREAM_ID FIFO_PATH SERVICE_NAME INPUT_ARGS URL FILE CUSTOM FFMPEG_LINE META_NAME RAW_NAME TCP_PORT

  read -rp "Choose type [1-4]: " kind < /dev/tty
  
  # Validate numeric input
  if ! kind=$(validate_number "$kind" 1 4 2>/dev/null); then
    echo "❌ Invalid selection. Please enter 1, 2, 3, or 4."
    pause
    return
  fi
  
  read -rp "Stream name: " STREAM_NAME < /dev/tty
  [ -z "$STREAM_NAME" ] && { echo "❌ Name is required."; pause; return; }

  STREAM_ID="$(mk_stream_id "$STREAM_NAME")"
  META_NAME="$STREAM_NAME"
  RAW_NAME="$STREAM_ID"

  # Common variables for FFmpeg-based streams (1-3)
  FIFO_PATH="$(fifo_path_for "$STREAM_ID")"
  SERVICE_NAME="$(service_name_for "$STREAM_ID")"

  case "$kind" in
    1)
      read -rp "URL: " URL < /dev/tty
      [ -z "$URL" ] && { echo "❌ No URL provided."; pause; return; }
      
      # Validate URL to prevent command injection
      if ! URL=$(validate_url "$URL"); then
        pause
        return
      fi
      
      log "INFO" "Creating URL stream: $STREAM_NAME -> $URL"
      INPUT_ARGS="-i \"${URL}\""
      ;;
    2)
      read -rp "Path to file (mp3/wav/flac): " FILE < /dev/tty
      
      # Validate file path
      if ! FILE=$(validate_path "$FILE" 2>/dev/null); then
        echo "❌ File not found or invalid path."
        pause
        return
      fi
      
      log "INFO" "Creating file loop stream: $STREAM_NAME -> $FILE"
      INPUT_ARGS="-stream_loop -1 -re -i \"${FILE}\""
      ;;
    3)
      echo "Example: -f alsa -i hw:0"
      echo "⚠️  WARNING: These arguments will be inserted directly in the unit."
      echo "⚠️  Only use trusted input. Dangerous characters will be rejected."
      read -rp "FFmpeg input arguments: " CUSTOM < /dev/tty
      [ -z "$CUSTOM" ] && { echo "❌ You must provide arguments."; pause; return; }
      
      # Basic sanitization - reject obviously dangerous patterns
      if [[ "$CUSTOM" =~ [\$\(\)\;\`\|\&\<\>] ]]; then
        echo "❌ Custom arguments contain dangerous shell characters."
        echo "   Rejected characters: \$, (, ), ;, \`, |, &, <, >"
        pause
        return
      fi
      
      log "INFO" "Creating custom FFmpeg stream: $STREAM_NAME"
      INPUT_ARGS="$CUSTOM"
      ;;
    4)
      read -rp "TCP Port (e.g. 4953): " TCP_PORT < /dev/tty
      if ! TCP_PORT=$(validate_number "$TCP_PORT" 1024 65535 2>/dev/null); then
        echo "❌ Invalid port. Must be between 1024 and 65535."
        pause
        return
      fi

      log "INFO" "Creating TCP stream: $STREAM_NAME on port $TCP_PORT"
      
      # Add TCP source
      add_or_replace_tcp_stream_line "$TCP_PORT" "$RAW_NAME"
      
      # Add MetaStream
      add_or_replace_metastream_line "$RAW_NAME" "$META_NAME"
      
      systemctl restart snapserver
      
      echo "✅ TCP Stream '$STREAM_NAME' created on port $TCP_PORT."
      pause
      return
      ;;
    *)
      echo "❌ Invalid selection."
      pause
      return
      ;;
  esac

  log "INFO" "Creating FIFO for stream: $FIFO_PATH"
  ensure_fifo "$FIFO_PATH" || {
    log "ERROR" "Failed to create FIFO: $FIFO_PATH"
    echo "❌ Failed to create FIFO"
    pause
    return
  }
  
  FFMPEG_LINE="$(ffmpeg_cmd_for "$INPUT_ARGS" "$FIFO_PATH")"
  write_unit "$SERVICE_NAME" "$FFMPEG_LINE" "$STREAM_NAME" "$STREAM_ID" "$FIFO_PATH"

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl restart "$SERVICE_NAME"

  echo "🛡️ Activating advanced watchdog for '$STREAM_NAME'..."
  systemctl enable --now "ffmpeg-watchdog@${STREAM_ID}.timer" >/dev/null 2>&1 || true

  # PIPE (codec=null)
  add_or_replace_stream_line "$FIFO_PATH" "$RAW_NAME"

  # METASTREAM
  add_or_replace_metastream_line "$RAW_NAME" "$META_NAME"

  systemctl restart snapserver

  log "INFO" "Stream created successfully: $STREAM_NAME (ID: $STREAM_ID)"
  echo "✅ Stream '$STREAM_NAME' created and fully initialized with codec=null pipe, MetaStream, and watchdog."
  pause
}

sync_all_streams(){
  echo ""
  echo "🔄 Syncing Snapserver stream configuration…"

  ensure_silence_fallback         # Crea/actualiza Silence (process:///ffmpeg)
  ensure_default_pipe_sources     # Genera pipe sources con codec=null
  ensure_default_metastreams      # Genera MetaStreams visibles con Silence fallback
  
  echo "🔁 Reloading Systemd…"
  systemctl daemon-reload

  echo "🔁 Restarting all FFmpeg services…"
  for svc in /etc/systemd/system/ffmpeg-*.service; do
    [ -e "$svc" ] || continue
    local name
    name=$(basename "$svc")
    systemctl restart "$name" 2>/dev/null || true
  done

  echo "🔁 Restarting Snapserver…"
  systemctl restart snapserver

  echo "✅ All streams synchronized successfully."
  pause
}

edit_stream(){
  show_streams_numbered || { pause; return; }
  local num entry fifo STREAM_ID SERVICE_NAME total_streams
  
  # Count total streams for validation
  total_streams=$(get_stream_lines | wc -l)
  
  read -rp "Number of the stream to edit: " num < /dev/tty
  
  # Validate numeric input
  if ! num=$(validate_number "$num" 1 "$total_streams" 2>/dev/null); then
    pause
    return
  fi
  
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
  
  log "INFO" "Editing stream service: $SERVICE_NAME"
  echo "✍️  Editing service: $SYSTEMD_DIR/$SERVICE_NAME"
  pause
  ${EDITOR:-nano} "$SYSTEMD_DIR/$SERVICE_NAME"
  
  systemctl daemon-reload
  systemctl restart "$SERVICE_NAME"
  
  log "INFO" "Stream service reloaded: $SERVICE_NAME"
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
    
    # Extract ID: works for pipe://...snapfifo_ID?... OR tcp://...?name=ID...
    if [[ "$entry" =~ snapfifo_ ]]; then
        STREAM_ID="$(echo "$entry" | sed -nE 's|.*snapfifo_([^?]+)\?.*|\1|p')"
    else
        STREAM_ID="$(echo "$entry" | sed -nE 's|.*name=([^&]+).*|\1|p')"
    fi
    
    # Clean up ID (lowercase, alphanum) just in case
    STREAM_ID="$(mk_stream_id "$STREAM_ID")"

    echo "🗑️  Deleting stream $n ('${STREAM_ID}')..."

    # Check if it's a pipe stream (has associated service)
    SVC="$(service_name_for "$STREAM_ID")"
    if [ -f "$SYSTEMD_DIR/$SVC" ]; then
        echo "   • Stopping and removing service $SVC..."
        systemctl stop "$SVC" 2>/dev/null || true
        systemctl disable "$SVC" 2>/dev/null || true
        systemctl stop "ffmpeg-watchdog@${STREAM_ID}.timer" 2>/dev/null || true
        systemctl disable "ffmpeg-watchdog@${STREAM_ID}.timer" 2>/dev/null || true

        rm -f "$SYSTEMD_DIR/$SVC" "${SNAP_FIFO_DIR}/snapfifo_${STREAM_ID}" "$(log_file_for "$STREAM_ID")"
    fi

    # Remove from config (matches both pipe and tcp lines by name/fifo)
    # We use a broader sed pattern to catch the line defining this source
    # Pattern matches: source = ... name=STREAM_ID ... OR ... snapfifo_STREAM_ID ...
    sed -i "/name=${STREAM_ID}/d" "$CONF_FILE"
    sed -i "/snapfifo_${STREAM_ID}/d" "$CONF_FILE"
    
    # Also remove the MetaStream associated with it
    sed -i "/meta:\/\/\/${STREAM_ID}\/Silence/d" "$CONF_FILE"
    
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
# status summary after the restart with timeout-based validation.
##
restart_snapserver_with_confirm(){
  echo ""
  read -rp "⚠️  Restart Snapserver now? (y/N): " ans < /dev/tty
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    echo "🔁 Restarting Snapserver…"
    log "INFO" "User requested Snapserver restart"
    
    if systemctl restart snapserver; then
      # Wait for service to become active
      if wait_for_service snapserver 10; then
        local st
        st=$(systemctl is-active snapserver 2>/dev/null || echo "unknown")
        log "INFO" "Snapserver restarted successfully: $st"
        echo "✅ Snapserver status: $st"
      else
        log "WARN" "Snapserver failed to start within timeout"
        echo "⚠️ Snapserver did not start within 10 seconds. Check: journalctl -u snapserver -n 50 --no-pager"
      fi
    else
      log "ERROR" "Failed to restart Snapserver"
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
    echo "──────────────── SERVICES & RESTARTS ─────────────────"
    echo "1) View Snapserver status"
    echo "2) View all stream services"
    echo "3) Restart Snapserver"
    echo "4) Restart selected streams"
    echo "5) Restart ALL streams"
    echo "6) Rebuild stream units (maintenance)"
    echo "7) Back"
    read -rp "Choose [1-7]: " opt < /dev/tty
    case "$opt" in
      1) monitor_snapserver ;;
      2) check_activity ;;
      3) restart_snapserver_with_confirm ;;
      4) restart_selected_ffmpeg_services ;;
      5) restart_all_ffmpeg_services ;;
      6) rebuild_all_units ;;
      7) return ;;
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
  if ! compgen -G "${SYSTEMD_DIR}/ffmpeg-*.service" > /dev/null; then
    echo "ℹ️  No FFmpeg services found."
  else
    if ! systemctl restart ffmpeg-*.service; then
        echo "⚠️  Some services may have failed to restart. Use option 2 to check status."
    else
        echo "✅ Restart command sent successfully to all ffmpeg services."
    fi
  fi
  echo ""
  pause
}

# ────────────────────────────────────────────────────────────────────────────
# Backups
# ────────────────────────────────────────────────────────────────────────────
do_backup(){
  local OUT="/var/backups/snapserver_backup_$(ts).tar.gz"
  
  echo "🧯 Creating backup at $OUT ..."
  log "INFO" "Starting backup creation"
  
  # Check disk space (require 500MB free)
  if ! check_disk_space 500 /var/backups; then
    log "ERROR" "Insufficient disk space for backup"
    pause
    return 1
  fi
  
  mkdir -p /var/backups
  
  if tar -czf "$OUT" \
    /var/lib/snapserver \
    "$CONF_FILE" \
    "$LOG_DIR" \
    "$SYSTEMD_DIR/ffmpeg-*.service" \
    "$SYSTEMD_DIR/snap-silence.service" \
    "$SYSTEMD_DIR/ffmpeg-watchdog@.service" \
    "$SYSTEMD_DIR/ffmpeg-watchdog@.timer" \
    /etc/logrotate.d/ffmpeg-snapstream 2>/dev/null; then
    
    log "INFO" "Backup created successfully: $OUT"
    echo "✅ Backup ready: $OUT"
  else
    log "ERROR" "Backup creation failed"
    echo "❌ Backup creation failed"
  fi
  
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
    echo "  🧩 SNAPSTREAM MANAGER v1.0.33"
    echo "═══════════════════════════════════════════════════"
    echo "     🎚️  ${active_count} FFmpeg stream(s) currently running"
    echo "═══════════════════════════════════════════════════"
    echo ""
    echo "         ─── Stream Operations ───"
    echo "1) Add new stream"
    echo "2) Edit stream"
    echo "3) Delete stream(s)"
    echo "4) View stream status"
    echo "5) Sync streams (Silence/MetaStreams)"
    echo ""
    echo "         ─── System Management ───"
    echo "6) Services & Restarts"
    echo "7) Clients"
    echo "8) Logs"
    echo ""
    echo "         ─── Advanced ───"
    echo "W) Watchdog Management"
    echo "C) Configuration & Setup"
    echo "B) Backups"
    echo ""
    echo "0) Exit"
    echo "═══════════════════════════════════════════════════"
    read -rp "Choose an option: " opt < /dev/tty
    case "$opt" in
      1) create_stream;;
      2) edit_stream;;
      3) delete_streams;;
      4) check_activity;;
      5) sync_all_streams;;
      6) services_menu;;
      7) clients_menu;;
      8) logs_menu;;
      W|w) watchdog_management_menu;;
      C|c) configuration_menu;;
      B|b) backup_menu;;
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
# logs_menu
# Simplified menu for viewing logs only (split from logs_and_watchdog_menu)
##
logs_menu(){
  local opt
  while true; do
    clear
    echo "──────────────── LOGS ─────────────────"
    echo "1) View Snapserver logs"
    echo "2) View stream service logs (select one)"
    echo "3) View watchdog logs (select one)"
    echo "4) Clear stream logs (select one)"
    echo "5) Back"
    read -rp "Choose [1-5]: " opt < /dev/tty
    case "$opt" in
      1) view_logs_snapserver ;;
      2) view_logs_ffmpeg_service ;;
      3) view_logs_watchdog ;;
      4) clear_watchdog_logs_selected ;;
      5) return ;;
      *) ;;
    esac
  done
}

##
# watchdog_management_menu
# Consolidated watchdog operations (split from logs_and_watchdog_menu)
##
watchdog_management_menu(){
  local opt
  while true; do
    clear
    echo "──────────────── WATCHDOG MANAGEMENT ─────────────────"
    echo "1) View watchdog status (all streams)"
    echo "2) Enable for selected stream"
    echo "3) Enable for ALL streams"
    echo "4) Disable for selected stream"
    echo "5) Configure detection thresholds"
    echo "6) Refresh templates (advanced)"
    echo "7) Back"
    read -rp "Choose [1-7]: " opt < /dev/tty
    case "$opt" in
      1) check_watchdog_status_all ;;
      2) enable_watchdog_for_selected ;;
      3) enable_watchdog_for_all_safe ;;
      4) disable_watchdog_for_selected ;;
      5) configure_watchdog_thresholds ;;
      6) force_refresh_watchdog_templates ;;
      7) return ;;
      *) ;;
    esac
  done
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
    echo "1) View Logs"
    echo "2) Manage Watchdog"
    echo "3) Back"
    read -rp "Choose [1-3]: " opt < /dev/tty
    case "$opt" in
      1) logs_menu ;;
      2) watchdog_management_menu ;;
      3) return ;;
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

##
# configuration_menu
# Provides manual configuration actions: LXC/local capture help, ensuring global Silence,
# declaring default pipe sources, and creating default MetaStreams.
##
configuration_menu(){
  local opt
  while true; do
    clear
    echo "═══════════════════════════════════════════════════"
    echo "  ⚙️  Configuration & Setup"
    echo "═══════════════════════════════════════════════════"
    echo "1) LXC / Local capture help"
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
