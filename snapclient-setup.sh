#!/bin/bash
# ==============================================================================
# setup-snapclient.sh - v5 (Corrected heredoc expansion)
# Configures Snapclient on Proxmox/LXC/Debian with robust error handling,
# intelligent passthrough, and versatile execution environments.
#
# Author: Josue / GPT-5 — v5
# ==============================================================================

set -Eeuo pipefail

# === HELPER FUNCTIONS =======================================================

detect_environment() {
  if command -v pct >/dev/null 2>&1; then
    echo "proxmox"
  elif grep -qa container=lxc /proc/1/environ 2>/dev/null; then
    echo "lxc"
  elif [[ -f /etc/debian_version ]]; then
    echo "debian"
  else
    echo "unknown"
  fi
}

detect_debian_codename() {
  grep VERSION_CODENAME= /etc/os-release | cut -d= -f2 2>/dev/null || echo "unknown"
}

detect_snap_version() {
  snapclient --version 2>/dev/null | head -n1 | awk '{print $3}' || echo "none"
}

get_suggested_snap_ver() {
  local codename="$1"
  case "$codename" in
    bullseye) echo "v0.29.0" ;;
    bookworm | trixie | forky) echo "v0.34.0" ;; # Trixie and future versions will use the latest stable
    *) echo "v0.34.0" ;;
  esac
}

pause(){ read -rp "Press Enter to continue..."; }

# === PREREQUISITES, MODULES, AND DIAGNOSTICS ================================

check_prerequisites() {
  local ENVIRONMENT
  ENVIRONMENT=$(detect_environment)

  echo ""
  echo "🔍 Checking environment prerequisites ($ENVIRONMENT)…"
  echo ""

  local REQUIRED_PKGS=("alsa-utils" "ffmpeg" "psmisc" "wget" "curl")

  if [ "$ENVIRONMENT" = "proxmox" ]; then
    local MISSING=()
    for pkg in "${REQUIRED_PKGS[@]}"; do
      dpkg -s "$pkg" &>/dev/null || MISSING+=("$pkg")
    done

    if [ ${#MISSING[@]} -gt 0 ]; then
      echo "⚠️  Missing packages on the host:"
      printf '  - %s\n' "${MISSING[@]}"
      read -rp "Install them now on the host? (Y/n): " RESP
      if [[ ! "$RESP" =~ ^[Nn]$ ]]; then
        apt update -qq && apt install -y "${MISSING[@]}"
      else
        echo "⏭️  Skipping installation on the host."
      fi
    else
      echo "✅ Host: prerequisites met."
    fi
    check_alsa_modules
  elif [ "$ENVIRONMENT" = "lxc" ] || [ "$ENVIRONMENT" = "debian" ]; then
    local MISSING=()
    for pkg in "${REQUIRED_PKGS[@]}"; do
      dpkg -s "$pkg" &>/dev/null || MISSING+=("$pkg")
    done

    if [ ${#MISSING[@]} -gt 0 ]; then
      echo "⚠️  Missing packages on this system:"
      printf '  - %s\n' "${MISSING[@]}"
      read -rp "Install them now? (Y/n): " RESP
      if [[ ! "$RESP" =~ ^[Nn]$ ]]; then
        apt update -qq && apt install -y "${MISSING[@]}"
      else
        echo "⏭️  Skipping local installation."
      fi
    else
      echo "✅ System: prerequisites met."
    fi
  else
    echo "⚠️  Unknown environment; skipping prerequisite check."
  fi

  echo ""
  pause
}

check_alsa_modules() {
  echo ""
  echo "🎧 Checking ALSA modules on the host…"
  echo ""
  local MODULES=("snd_hda_intel" "snd_usb_audio" "snd_soc_core" "snd_pcm" "snd_seq")
  for mod in "${MODULES[@]}"; do
    if ! lsmod | grep -q "^${mod}"; then
      echo "⚠️  Module not loaded: $mod"
      if modinfo "$mod" &>/dev/null; then
        read -rp "Load $mod now? (Y/n): " RESP
        if [[ ! "$RESP" =~ ^[Nn]$ ]]; then
          modprobe "$mod" && echo "✅ $mod loaded."
        else
          echo "⏭️  Skipped $mod."
        fi
      else
        echo "❌ $mod does not exist in this kernel."
      fi
    else
      echo "✅ $mod already loaded."
    fi
  done
  echo ""
  echo "🔍 aplay -l:"
  if command -v aplay >/dev/null 2>&1; then
    aplay -l 2>/dev/null || echo "⚠️  No playback devices detected."
  else
    echo "⚠️  'aplay' is not installed (install alsa-utils)."
  fi
  echo ""
}

# === INSTALLATION LOGIC (REFACTORED AND ROBUST) =============================

_install_and_configure_snapclient() {
  set -Eeuo pipefail
  
  local SUGGESTED_VER="$1"
  local DEBIAN_VERSION="$2"
  local CARD_ID="$3"
  local ALSA_DEVICE="$4"
  local CLIENT_NAME="$5"
  local SNAPSERVER_IP="$6"
  local VOLUME="$7"

  echo "📦 Installing prerequisites..."
  apt-get update -qq && apt-get install -yq alsa-utils psmisc ffmpeg wget

  cd /tmp

  local DEB_FILE="snapclient_${SUGGESTED_VER#v}-1_amd64_${DEBIAN_VERSION}.deb"
  local BASE_URL="https://github.com/badaix/snapcast/releases/download/${SUGGESTED_VER}"

  echo "Downloading Snapclient ${SUGGESTED_VER} for ${DEBIAN_VERSION}..."
  
  if ! wget --show-progress -O "$DEB_FILE" "${BASE_URL}/${DEB_FILE}"; then
    echo "❌ WARNING: Failed to download Snapclient package for '${DEBIAN_VERSION}'." >&2
    if [[ "$DEBIAN_VERSION" == "trixie" ]]; then
        echo "ℹ️  Attempting to download 'bookworm' package as a fallback..."
        DEB_FILE="snapclient_${SUGGESTED_VER#v}-1_amd64_bookworm.deb"
        if ! wget --show-progress -O "$DEB_FILE" "${BASE_URL}/${DEB_FILE}"; then
            echo "❌ FATAL: Fallback download for 'bookworm' also failed. Aborting." >&2
            return 1
        fi
    else
        echo "❌ FATAL: Download failed. Please check network or URL. Aborting." >&2
        return 1
    fi
  fi
  
  local CHECKSUM_FILE="${DEB_FILE}.sha256"
  wget --show-progress -O "$CHECKSUM_FILE" "${BASE_URL}/${CHECKSUM_FILE}" || echo "⚠️  Could not download checksum file."

  if [ -f "$CHECKSUM_FILE" ]; then
    echo "🛡️  Verifying package integrity..."
    if sha256sum -c --strict --status "$CHECKSUM_FILE"; then
      echo "✅ Checksum verified."
    else
      echo "❌ FATAL: Checksum verification failed! Aborting installation." >&2
      return 1
    fi
  else
    echo "⚠️  Skipping checksum verification (file not found)."
  fi
  
  echo "Installing Snapclient package..."
  apt-get install -y "./${DEB_FILE}"
  
  echo "Configuring system..."
  usermod -aG audio snapclient 2>/dev/null || true
  
  mkdir -p /etc
  cat > /etc/asound.conf <<EOF
defaults.pcm.card ${CARD_ID}
defaults.ctl.card ${CARD_ID}
EOF

  cat > /etc/default/snapclient <<CONF
START_SNAPCLIENT=true
SNAPCLIENT_OPTS="--soundcard ${ALSA_DEVICE} --hostID ${CLIENT_NAME} --host ${SNAPSERVER_IP}"
CONF

  echo "Setting initial volume to ${VOLUME}%..."
  amixer -c "$CARD_ID" sset Master "${VOLUME}%" || \
  amixer -c "$CARD_ID" sset Speaker "${VOLUME}%" || \
  amixer -c "$CARD_ID" sset PCM "${VOLUME}%" || \
  echo "⚠️ Could not set volume. You may need to set it manually."

  alsactl store || true
  
  echo "🚀 Starting Snapclient service..."
  systemctl enable --now snapclient
  systemctl restart snapclient
}

# === CONFIGURE SNAPCLIENT (MAIN FUNCTION) ===================================

setup_snapclient() {
  local ENVIRONMENT
  ENVIRONMENT=$(detect_environment)
  local CTID=""
  local DEBIAN_VERSION=""
  local INSTALLED_VER=""
  local SUGGESTED_VER=""

  if [ "$ENVIRONMENT" = "proxmox" ]; then
    echo ""
    echo "📦 Available containers:"
    pct list | awk 'NR>1 {printf " - %s (%s)\n", $1, $2}'
    echo ""
    read -rp "Enter the target LXC container ID: " CTID
    if ! pct status "$CTID" >/dev/null 2>&1; then echo "❌ Container $CTID does not exist."; exit 1; fi
    local CONF_FILE="/etc/pve/lxc/${CTID}.conf"
    if grep -qE '^unprivileged:\s*1' "$CONF_FILE"; then
      echo "❌ FATAL ERROR: Container $CTID is UNPRIVILEGED ('unprivileged: 1')."; echo "Audio passthrough requires a PRIVILEGED container."; exit 1
    fi
    echo "✅ Container $CTID is privileged. Proceeding..."
    DEBIAN_VERSION=$(pct exec "$CTID" -- bash -c 'grep VERSION_CODENAME= /etc/os-release | cut -d= -f2' 2>/dev/null || echo "bookworm")
    INSTALLED_VER=$(pct exec "$CTID" -- bash -c 'snapclient --version 2>/dev/null | head -n1 | awk "{print \$3}"' || echo "none")
  else
    DEBIAN_VERSION=$(detect_debian_codename)
    INSTALLED_VER=$(detect_snap_version)
  fi

  SUGGESTED_VER=$(get_suggested_snap_ver "$DEBIAN_VERSION")
  
  echo "📦 Detected Debian system: $DEBIAN_VERSION"; echo "💡 Recommended Snapclient version: $SUGGESTED_VER"; echo "🔍 Currently installed version: $INSTALLED_VER"; echo ""
  aplay -l | grep '^card' || { echo "❌ No ALSA cards detected."; exit 1; }
  echo ""
  read -rp "Enter the card number to use (e.g., 0): " CARD_ID
  read -rp "Enter the device number to use (e.g., 0): " DEV_ID
  CARD_NAME=$(aplay -l | awk -v id="$CARD_ID" -F'[][]' '/^card/{if ($2==id) {print $4; exit}}')
  ALSA_DEVICE="plughw:CARD=${CARD_NAME// /},DEV=$DEV_ID"
  echo "✅ Card selected: $CARD_NAME, ALSA device: $ALSA_DEVICE"
  read -rp "Enter the Snapserver IP: " SNAPSERVER_IP
  DEFAULT_CLIENT_NAME=$( [ "$ENVIRONMENT" = "proxmox" ] && pct exec "$CTID" -- hostname || hostname )
  read -rp "Enter Snapcast client name [default: $DEFAULT_CLIENT_NAME]: " CLIENT_NAME; [[ -z "$CLIENT_NAME" ]] && CLIENT_NAME="$DEFAULT_CLIENT_NAME"
  read -rp "🎚️ Initial volume (0–100)% [default: 70]: " VOLUME; [[ -z "$VOLUME" ]] && VOLUME="70"

  if [ "$ENVIRONMENT" = "proxmox" ]; then
    if ! grep -q "/dev/snd" "$CONF_FILE"; then
      echo "⚙️ Adding /dev/snd passthrough to container $CTID…"
      cat <<EOF >> "$CONF_FILE"

# === ALSA Passthrough (added by setup-snapclient.sh) ===
lxc.cgroup2.devices.allow: c 116:* rwm
lxc.mount.entry: /dev/snd dev/snd none bind,optional,create=dir
EOF
      echo "🔄 Applying passthrough by stopping/starting the container..."
      pct stop "$CTID" || true && sleep 3 && pct start "$CTID" && sleep 10
    fi
    if ! pct exec "$CTID" -- bash -c 'test -d /dev/snd && ls -A /dev/snd | grep -q .'; then
      echo "❌ FAILED: Audio devices not visible inside container."; exit 1
    fi
    echo "✅ Success! Audio devices are visible inside the container."
    
    local SCRIPT_PATH="/tmp/install_snapclient_temp.sh"
    local SCRIPT_TARGET_PATH="/tmp/install_snapclient_temp.sh"
    # --- CRITICAL FIX: Use 'EOF' to prevent variable expansion in the heredoc ---
    cat > "$SCRIPT_PATH" <<'EOF'
#!/bin/bash
set -Eeuo pipefail

# The entire function is embedded here literally
_install_and_configure_snapclient() {
  set -Eeuo pipefail
  
  local SUGGESTED_VER="$1"
  local DEBIAN_VERSION="$2"
  local CARD_ID="$3"
  local ALSA_DEVICE="$4"
  local CLIENT_NAME="$5"
  local SNAPSERVER_IP="$6"
  local VOLUME="$7"

  echo "📦 Installing prerequisites..."
  apt-get update -qq && apt-get install -yq alsa-utils psmisc ffmpeg wget

  cd /tmp

  local DEB_FILE="snapclient_${SUGGESTED_VER#v}-1_amd64_${DEBIAN_VERSION}.deb"
  local BASE_URL="https://github.com/badaix/snapcast/releases/download/${SUGGESTED_VER}"

  echo "Downloading Snapclient ${SUGGESTED_VER} for ${DEBIAN_VERSION}..."
  
  if ! wget --show-progress -O "$DEB_FILE" "${BASE_URL}/${DEB_FILE}"; then
    echo "❌ WARNING: Failed to download Snapclient package for '${DEBIAN_VERSION}'." >&2
    if [[ "$DEBIAN_VERSION" == "trixie" ]]; then
        echo "ℹ️  Attempting to download 'bookworm' package as a fallback..."
        DEB_FILE="snapclient_${SUGGESTED_VER#v}-1_amd64_bookworm.deb"
        if ! wget --show-progress -O "$DEB_FILE" "${BASE_URL}/${DEB_FILE}"; then
            echo "❌ FATAL: Fallback download for 'bookworm' also failed. Aborting." >&2
            return 1
        fi
    else
        echo "❌ FATAL: Download failed. Please check network or URL. Aborting." >&2
        return 1
    fi
  fi
  
  local CHECKSUM_FILE="${DEB_FILE}.sha256"
  wget --show-progress -O "$CHECKSUM_FILE" "${BASE_URL}/${CHECKSUM_FILE}" || echo "⚠️  Could not download checksum file."

  if [ -f "$CHECKSUM_FILE" ]; then
    echo "🛡️  Verifying package integrity..."
    if sha256sum -c --strict --status "$CHECKSUM_FILE"; then
      echo "✅ Checksum verified."
    else
      echo "❌ FATAL: Checksum verification failed! Aborting installation." >&2
      return 1
    fi
  else
    echo "⚠️  Skipping checksum verification (file not found)."
  fi
  
  echo "Installing Snapclient package..."
  apt-get install -y "./${DEB_FILE}"
  
  echo "Configuring system..."
  usermod -aG audio snapclient 2>/dev/null || true
  
  mkdir -p /etc
  cat > /etc/asound.conf <<ASOUNDEOF
defaults.pcm.card ${CARD_ID}
defaults.ctl.card ${CARD_ID}
ASOUNDEOF

  cat > /etc/default/snapclient <<SNAPCONF
START_SNAPCLIENT=true
SNAPCLIENT_OPTS="--soundcard ${ALSA_DEVICE} --hostID ${CLIENT_NAME} --host ${SNAPSERVER_IP}"
SNAPCONF

  echo "Setting initial volume to ${VOLUME}%..."
  amixer -c "$CARD_ID" sset Master "${VOLUME}%" || \
  amixer -c "$CARD_ID" sset Speaker "${VOLUME}%" || \
  amixer -c "$CARD_ID" sset PCM "${VOLUME}%" || \
  echo "⚠️ Could not set volume. You may need to set it manually."

  alsactl store || true
  
  echo "🚀 Starting Snapclient service..."
  systemctl enable --now snapclient
  systemctl restart snapclient
}
# Now, call the function with the arguments passed from the host
_install_and_configure_snapclient "$1" "$2" "$3" "$4" "$5" "$6" "$7"
EOF
    pct push "$CTID" "$SCRIPT_PATH" "$SCRIPT_TARGET_PATH"
    echo "🚀 Executing installation inside the container..."
    pct exec "$CTID" -- bash "$SCRIPT_TARGET_PATH" "$SUGGESTED_VER" "$DEBIAN_VERSION" "$CARD_ID" "$ALSA_DEVICE" "$CLIENT_NAME" "$SNAPSERVER_IP" "$VOLUME"
    echo "🧹 Cleaning up..."
    pct exec "$CTID" -- rm "$SCRIPT_TARGET_PATH"
    rm "$SCRIPT_PATH"
  else
    echo "📦 Installing and configuring Snapclient locally…"
    _install_and_configure_snapclient "$SUGGESTED_VER" "$DEBIAN_VERSION" "$CARD_ID" "$ALSA_DEVICE" "$CLIENT_NAME" "$SNAPSERVER_IP" "$VOLUME"
  fi
  verify_snapclient "$ENVIRONMENT" "${CTID:-}"
}

verify_snapclient() {
  # ... (unchanged)
}
verify_existing_snapclient() {
  # ... (unchanged)
}

main() {
    # ... (unchanged)
}

main "$@"
