#!/bin/bash
# ==============================================================================
# setup-snapclient.sh - v3.5 (Functions Restored)
# Restores accidentally deleted functions `fix_alsa_order` and
# `generate_diagnostics` for full menu functionality.
#
# Author: Josue / GPT-5 — v3.5
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
    bookworm) echo "v0.33.0" ;;
    trixie) echo "v0.34.0" ;;
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
  local OUT="/root/snap-audio-check.log"
  echo "🧾 Generating diagnostics report at $OUT …"
  {
    echo "═══════════════════════════════════════════════════════"
    echo " SNAPCLIENT AUDIO DIAGNOSTIC REPORT"
    echo " Date: $(date)"
    echo " Hostname: $(hostname)"
    echo "═══════════════════════════════════════════════════════"
    echo
    echo "🧠 Environment: $(detect_environment)"
    echo "📦 Debian Codename: $(detect_debian_codename)"
    echo
    echo "🔧 Packages (alsa-utils, ffmpeg, wget, psmisc, curl):"
    dpkg -l | grep -E 'alsa-utils|ffmpeg|wget|psmisc|curl' || echo "No base packages detected"
    echo
    echo "🎛️ ALSA Modules (lsmod | grep snd):"
    lsmod | grep snd || echo "No 'snd' modules loaded"
    echo
    echo "🎧 /proc/asound/cards:"
    cat /proc/asound/cards 2>/dev/null || echo "No cards found"
    echo
    echo "🔊 aplay -l:"
    if command -v aplay >/dev/null 2>&1; then
      aplay -l 2>&1 || true
    else
      echo "aplay not installed."
    fi
    echo
    echo "🎚️ Snapclient Service (systemctl status):"
    systemctl status snapclient 2>&1 | head -n 30 || echo "Snapclient not installed"
    echo
    echo "📜 journalctl -u snapclient (last 30 lines):"
    journalctl -u snapclient -n 30 --no-pager 2>&1 || true
    echo
  } > "$OUT"
  echo "✅ Diagnostics report ready: $OUT"
  echo ""
  pause
}

# === FIX ALSA CARD ORDER (HOST) =============================================

fix_alsa_order() {
  echo "🔍 Detecting ALSA cards on the host…"
  echo

  CARDS=()
  IDS=()

  for card in /proc/asound/card*/id; do
    cid=$(basename "$(dirname "$card")")
    name=$(cat "$card")
    CARDS+=("$cid")
    IDS+=("$name")
  done

  if [ ${#CARDS[@]} -eq 0 ]; then
    echo "❌ No ALSA cards detected. Aborting."
    return
  fi

  echo "🎧 Detected cards:"
  for i in "${!CARDS[@]}"; do
    echo "  [${CARDS[$i]}] -> ${IDS[$i]}"
  done
  echo

  read -rp "👉 Which card will be PRIMARY (card0)? (e.g., Audio or PCH): " MAIN
  read -rp "👉 And the SECONDARY (card1)? (leave blank if only one): " SECONDARY

  if ! grep -q "$MAIN" /proc/asound/card*/id; then
    echo "❌ No card found with name '$MAIN'. Aborting."
    return
  fi

  local CONF_FILE="/etc/modprobe.d/alsa-base.conf"
  local BACKUP_FILE="/etc/modprobe.d/alsa-base.conf.bak_$(date +%Y%m%d%H%M%S)"
  [ -f "$CONF_FILE" ] && cp "$CONF_FILE" "$BACKUP_FILE" && echo "📦 Backup: $BACKUP_FILE"

  echo "🧩 Updating $CONF_FILE …"
  {
    echo "# Generated by setup-snapclient.sh on $(date)"
  } > "$CONF_FILE"

  local MOD_USB="snd-usb-audio"
  local MOD_HDA="snd-hda-intel"

  if [[ "$MAIN" =~ [Uu][Ss][Bb] || "$MAIN" =~ [Aa]udio ]]; then
    echo "options $MOD_USB index=0" >> "$CONF_FILE"
    echo "options $MOD_HDA index=1" >> "$CONF_FILE"
  else
    echo "options $MOD_HDA index=0" >> "$CONF_FILE"
    echo "options $MOD_USB index=1" >> "$CONF_FILE"
  fi

  echo
  echo "✅ ALSA order fixed."
  echo "🎯 card0 → $MAIN"
  [[ -n "$SECONDARY" ]] && echo "🎯 card1 → $SECONDARY"
  echo
  echo "⚙️  Reboot the host to apply changes."
  echo
}

# === INSTALLATION LOGIC =====================================================

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
      echo "❌ FATAL: Download failed for main package. Please check network or URL. Aborting." >&2
      return 1
  fi
  
  local CHECKSUM_FILE="${DEB_FILE}.sha256"
  
  if wget --show-progress -O "$CHECKSUM_FILE" "${BASE_URL}/${CHECKSUM_FILE}"; then
      echo "🛡️  Verifying package integrity..."
      if sha256sum -c --strict --status "$CHECKSUM_FILE"; then
          echo "✅ Checksum verified."
      else
          echo "❌ FATAL: Checksum verification failed! The package may be corrupt. Aborting." >&2
          return 1
      fi
  else
      echo "⚠️  Could not download the checksum file (it may not exist for this version). Skipping verification."
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

  echo "Setting initial volume to ${VOLUME}% and ensuring it persists..."
  
  if amixer -c "$CARD_ID" sset Master "${VOLUME}%" >/dev/null 2>&1; then
      echo "✅ Volume set on 'Master' control."
  elif amixer -c "$CARD_ID" sset Speaker "${VOLUME}%" >/dev/null 2>&1; then
      echo "✅ Volume set on 'Speaker' control."
  elif amixer -c "$CARD_ID" sset PCM "${VOLUME}%" >/dev/null 2>&1; then
      echo "✅ Volume set on 'PCM' control."
  else
      echo "⚠️ Could not find a common mixer control (Master, Speaker, PCM) to set the volume."
  fi

  if alsactl store; then
      echo "✅ ALSA settings saved to /var/lib/alsa/asound.state."
  else
      echo "⚠️ Could not save ALSA settings."
  fi

  if systemctl enable alsa-restore.service >/dev/null 2>&1; then
      echo "✅ ALSA restore service enabled to persist volume across reboots."
  else
      echo "⚠️ Could not enable alsa-restore service."
  fi
  
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
    if grep -qE '^unprivileged:\s*1' "$CONF_FILE"; then
      echo "❌ FATAL ERROR: Container $CTID is UNPRIVILEGED ('unprivileged: 1')."
      echo "Audio passthrough requires a PRIVILEGED container to function correctly."
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
      echo "⚙️ Adding /dev/snd passthrough to container $CTID…"
      cat <<EOF >> "$CONF_FILE"

# === ALSA Passthrough (added by setup-snapclient.sh) ===
lxc.cgroup2.devices.allow: c 116:* rwm
lxc.mount.entry: /dev/snd dev/snd none bind,optional,create=dir
EOF
      echo "🔄 Rebooting container to apply passthrough..."
      pct reboot "$CTID"
      sleep 8
    fi
    echo "📦 Installing and configuring Snapclient in container $CTID..."
    pct exec "$CTID" -- bash -c "$(declare -f _install_and_configure_snapclient); _install_and_configure_snapclient '$SUGGESTED_VER' '$DEBIAN_VERSION' '$CARD_ID' '$ALSA_DEVICE' '$CLIENT_NAME' '$SNAPSERVER_IP' '$VOLUME'"
  else
    echo "📦 Installing and configuring Snapclient locally…"
    _install_and_configure_snapclient "$SUGGESTED_VER" "$DEBIAN_VERSION" "$CARD_ID" "$ALSA_DEVICE" "$CLIENT_NAME" "$SNAPSERVER_IP" "$VOLUME"
  fi
  verify_snapclient "$ENVIRONMENT" "${CTID:-}"
}

# === VERIFICATION AND MENU ===================================================
verify_snapclient() {
  local ENV="$1"
  local CT="${2:-}"
  echo ""
  echo "🔍 Verifying Snapclient → Snapserver connection (waiting 5s)..."
  sleep 5
  if [ "$ENV" = "proxmox" ] && [ -n "$CT" ]; then
    if pct exec "$CT" -- bash -lc 'journalctl -u snapclient -n 50 --no-pager | grep -q -E "Connected to|Stream established"'; then
      echo "✅ Snapclient connected successfully to the Snapserver."
    else
      echo "⚠️  Connection not detected. Check Snapserver IP/port, firewall, or ALSA device."
      pct exec "$CT" -- journalctl -u snapclient -n 20 --no-pager | tail -n 20
    fi
  else
    if journalctl -u snapclient -n 50 --no-pager | grep -q -E "Connected to|Stream established"; then
      echo "✅ Snapclient connected successfully to the Snapserver."
    else
      echo "⚠️  Connection not detected. Check Snapserver IP/port or ALSA device."
      journalctl -u snapclient -n 20 --no-pager | tail -n 20
    fi
  fi
  echo ""
  pause
}
verify_existing_snapclient() {
  local ENVIRONMENT
  ENVIRONMENT=$(detect_environment)
  echo ""
  echo "🔎 Verifying existing Snapclient…"
  if [ "$ENVIRONMENT" = "proxmox" ]; then
    echo ""
    echo "📦 Available containers:"
    pct list | awk 'NR>1 {printf " - %s (%s)\n", $1, $2}'
    echo ""
    read -rp "Enter the container ID to verify: " CTID
    verify_snapclient "proxmox" "$CTID"
  else
    verify_snapclient "$ENVIRONMENT" ""
  fi
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
