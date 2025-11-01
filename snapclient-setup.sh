#!/bin/bash
# ==============================================================================
# setup-snapclient.sh - v4 (Enhanced by collaborative debugging)
# Configures Snapclient on Proxmox/LXC/Debian with robust error handling,
# intelligent passthrough, and versatile execution environments.
#
# Author: Josue / GPT-5 — v4
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

generate_diagnostics() {
  # ... (Esta función no se ha modificado)
}

# === FIX ALSA CARD ORDER (HOST) =============================================

fix_alsa_order() {
  # ... (Esta función no se ha modificado)
}

# === INSTALLATION LOGIC (REFACTORED AND ROBUST) =============================

_install_and_configure_snapclient() {
  set -Eeuo pipefail
  
  # Parameters
  local SUGGESTED_VER="$1"
  local DEBIAN_VERSION="$2"
  local CARD_ID="$3"
  local ALSA_DEVICE="$4"
  local CLIENT_NAME="$5"
  local SNAPSERVER_IP="$6"
  local VOLUME="$7"

  echo "📦 Installing prerequisites..."
  apt-get update -qq
  apt-get install -yq alsa-utils psmisc ffmpeg wget

  cd /tmp

  local DEB_FILE="snapclient_${SUGGESTED_VER#v}-1_amd64_${DEBIAN_VERSION}.deb"
  local BASE_URL="https://github.com/badaix/snapcast/releases/download/${SUGGESTED_VER}"

  echo "Downloading Snapclient ${SUGGESTED_VER} for ${DEBIAN_VERSION}..."
  
  # --- ROBUST DOWNLOAD LOGIC ---
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
  # Download checksum, ignore failure as it's not always present for fallback packages
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
    if ! pct status "$CTID" >/dev/null 2>&1; then
      echo "❌ Container $CTID does not exist."
      exit 1
    fi
    
    local CONF_FILE="/etc/pve/lxc/${CTID}.conf"
    
    # --- CRITICAL CHECK: Ensure container is privileged ---
    if grep -qE '^unprivileged:\s*1' "$CONF_FILE"; then
      echo "❌ FATAL ERROR: Container $CTID is UNPRIVILEGED ('unprivileged: 1')."
      echo "Audio passthrough requires a PRIVILEGED container to function correctly."
      echo ""
      echo "👉 TO FIX THIS:"
      echo "   1. Stop the container: pct stop $CTID"
      echo "   2. Edit the config: nano $CONF_FILE"
      echo "   3. DELETE the line 'unprivileged: 1'"
      echo "   4. Start the container: pct start $CTID"
      echo "   5. Run this script again."
      exit 1
    else
      echo "✅ Container $CTID is privileged. Proceeding..."
    fi

    DEBIAN_VERSION=$(pct exec "$CTID" -- bash -c 'grep VERSION_CODENAME= /etc/os-release | cut -d= -f2' 2>/dev/null || echo "bookworm")
    INSTALLED_VER=$(pct exec "$CTID" -- bash -c 'snapclient --version 2>/dev/null | head -n1 | awk "{print \$3}"' || echo "none")
  else
    DEBIAN_VERSION=$(detect_debian_codename)
    INSTALLED_VER=$(detect_snap_version)
  fi

  SUGGESTED_VER=$(get_suggested_snap_ver "$DEBIAN_VERSION")

  # ... [Recopilación de datos del usuario, igual que en el original] ...
  echo ""
  echo "📦 Detected Debian system: $DEBIAN_VERSION"
  echo "💡 Recommended Snapclient version: $SUGGESTED_VER"
  echo "🔍 Currently installed version: $INSTALLED_VER"
  echo ""
  aplay -l | grep '^card' || { echo "❌ No ALSA cards detected on this system."; exit 1; }
  echo ""
  read -rp "Enter the card number to use (e.g., 0=Internal, 1=DAC): " CARD_ID
  mapfile -t DEVICE_NUMS < <(aplay -l 2>/dev/null | awk -v id=$CARD_ID '/^card/ && $2==id":" {print $6}' | sed 's/,//')
  if [ ${#DEVICE_NUMS[@]} -eq 0 ]; then
    echo "❌ No ALSA devices detected for card $CARD_ID."
    exit 1
  fi
  read -rp "Select the device number [default: ${DEVICE_NUMS[0]}]: " DEV_ID
  [[ -z "$DEV_ID" ]] && DEV_ID="${DEVICE_NUMS[0]}"
  if [ -f "/proc/asound/card${CARD_ID}/id" ]; then
    CARD_NAME=$(cat "/proc/asound/card${CARD_ID}/id")
  else
    CARD_NAME=$(aplay -l 2>/dev/null | awk -v id="$CARD_ID" -F'[][]' '/^card/{if ($2==id) {print $4; exit}}')
  fi
  SAFE_CARD_NAME=$(echo "$CARD_NAME" | tr -d ' ')
  ALSA_DEVICE="plughw:CARD=$SAFE_CARD_NAME,DEV=$DEV_ID"
  echo ""
  echo "✅ Card detected successfully:"
  echo "   CARD_NAME = $CARD_NAME"
  echo "   ALSA_DEVICE = $ALSA_DEVICE"
  echo ""
  read -rp "Enter the Snapserver IP: " SNAPSERVER_IP
  local DEFAULT_CLIENT_NAME
  if [ "$ENVIRONMENT" = "proxmox" ]; then
    DEFAULT_CLIENT_NAME=$(pct exec "$CTID" -- hostname)
  else
    DEFAULT_CLIENT_NAME=$(hostname)
  fi
  read -rp "Enter the Snapcast client name [default: $DEFAULT_CLIENT_NAME]: " CLIENT_NAME
  [[ -z "$CLIENT_NAME" ]] && CLIENT_NAME="$DEFAULT_CLIENT_NAME"
  read -rp "🎚️ Enter the initial volume (0–100)% [default: 70]: " VOLUME
  [[ -z "$VOLUME" ]] && VOLUME="70"
  local CARD_DESC
  CARD_DESC=$(aplay -l 2>/dev/null | awk -v id="$CARD_ID" -F'[][]' '/^card/{if ($2==id) {print $4; exit}}')

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "🧾 FINAL CONFIGURATION REVIEW:"
  [[ "$ENVIRONMENT" == "proxmox" ]] && echo " LXC Container:     $CTID"
  echo " Debian Codename:   $DEBIAN_VERSION"
  echo " Snapclient Version: $SUGGESTED_VER"
  echo " Card:              card $CARD_ID (${CARD_DESC:-Unknown})"
  echo " ALSA Device:       $ALSA_DEVICE"
  echo " Snapserver IP:     $SNAPSERVER_IP"
  echo " Client Name:       $CLIENT_NAME"
  echo " Initial Volume:    ${VOLUME}%"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  read -rp "Do you want to apply this configuration? (Y/n): " CONFIRM
  [[ "$CONFIRM" =~ ^[Nn]$ ]] && { echo "❌ Canceled."; return; }

  if [ "$ENVIRONMENT" = "proxmox" ]; then
    local CONF_FILE="/etc/pve/lxc/${CTID}.conf"
    if ! grep -q "/dev/snd" "$CONF_FILE"; then
      echo "⚙️  Adding /dev/snd passthrough to container $CTID…"
      cat <<EOF >> "$CONF_FILE"

# === ALSA Passthrough (added by setup-snapclient.sh) ===
lxc.cgroup2.devices.allow: c 116:* rwm
lxc.mount.entry: /dev/snd dev/snd none bind,optional,create=dir
EOF
      echo "🔄 Applying passthrough by stopping and starting the container..."
      pct stop "$CTID" || true
      sleep 3
      pct start "$CTID"
      echo "⏳ Waiting for container to boot (10 seconds)..."
      sleep 10
    fi

    echo "🔍 Verifying passthrough inside the container..."
    if pct exec "$CTID" -- bash -c 'test -d /dev/snd && ls -A /dev/snd | grep -q .'; then
      echo "✅ Success! Audio devices are visible inside the container."
    else
      echo "❌ FAILED: Audio devices are NOT visible. Check host logs or device usage."
      exit 1
    fi
    
    echo "📦 Preparing the script of installation for the container $CTID..."
    local SCRIPT_PATH="/tmp/install_snapclient_temp.sh"
    local SCRIPT_TARGET_PATH="/tmp/install_snapclient_temp.sh"
    cat > "$SCRIPT_PATH" <<EOF
#!/bin/bash
$(declare -f _install_and_configure_snapclient)
_install_and_configure_snapclient "$SUGGESTED_VER" "$DEBIAN_VERSION" "$CARD_ID" "$ALSA_DEVICE" "$CLIENT_NAME" "$SNAPSERVER_IP" "$VOLUME"
EOF
    echo "⇥ Sending the script of installation to the container..."
    pct push "$CTID" "$SCRIPT_PATH" "$SCRIPT_TARGET_PATH"
    echo "🚀 Executing installation inside the container..."
    pct exec "$CTID" -- bash "$SCRIPT_TARGET_PATH"
    echo "🧹 Cleaning up temporary files..."
    pct exec "$CTID" -- rm "$SCRIPT_TARGET_PATH"
    rm "$SCRIPT_PATH"

  else # Standalone Debian/LXC
    echo "📦 Installing and configuring Snapclient locally…"
    _install_and_configure_snapclient "$SUGGESTED_VER" "$DEBIAN_VERSION" "$CARD_ID" "$ALSA_DEVICE" "$CLIENT_NAME" "$SNAPSERVER_IP" "$VOLUME"
  fi

  verify_snapclient "$ENVIRONMENT" "${CTID:-}"
}

# === VERIFICATION AND MENU =================================================

verify_snapclient() {
  # ... (Esta función no se ha modificado)
}

verify_existing_snapclient() {
  # ... (Esta función no se ha modificado)
}

# === MAIN MENU =============================================================

main() {
    clear
    echo "═══════════════════════════════════════════════════"
    echo "      🎧 SNAPCLIENT AUDIO MANAGER v2025.10.29-r1"
    echo "═══════════════════════════════════════════════════"
    echo "1️⃣  Check prerequisites & ALSA modules (Host)"
    echo "2️⃣  Fix host ALSA card order"
    echo "3️⃣  Configure new Snapclient (LXC/Debian)"
    echo "4️⃣  Run all steps (1, 2, 3)"
    echo "---"
    echo "5️⃣  🔎 Verify existing Snapclient"
    echo "6️⃣  🧾 Generate diagnostics report"
    echo "7️⃣  🚪 Exit"
    echo "═══════════════════════════════════════════════════"
    read -rp "Select an option [1-7]: " opt

    case "$opt" in
      1) check_prerequisites ;;
      2) check_prerequisites; fix_alsa_order ;;
      3) check_prerequisites; setup_snapclient ;;
      4) check_prerequisites; fix_alsa_order; setup_snapclient ;;
      5) verify_existing_snapclient ;;
      6) generate_diagnostics ;;
      7) echo "👋 Exiting…"; exit 0 ;;
      *) echo "❌ Invalid option."; exit 1 ;;
    esac
}

main "$@"
