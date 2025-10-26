#!/bin/bash
# ==============================================================================
# setup-snapclient.sh
# Configura Snapclient en Proxmox/LXC/Debian con ALSA fijo, passthrough,
# asound.conf, control de volumen configurable y verificación automática.
# Autor: Josue / GPT-5 — v2
# ==============================================================================

set -Eeuo pipefail

# === FUNCIONES AUXILIARES ====================================================

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
    *) echo "v0.33.0" ;;
  esac
}

pause(){ read -rp "Presiona Enter para continuar..."; }

# === VERIFICAR PRERREQUISITOS (HOST / CONTENEDOR) ============================

check_prerequisites() {
  local ENVIRONMENT
  ENVIRONMENT=$(detect_environment)

  echo ""
  echo "🔍 Verificando prerrequisitos del entorno ($ENVIRONMENT)…"
  echo ""

  local REQUIRED_PKGS=("alsa-utils" "ffmpeg" "psmisc" "wget" "curl")

  if [ "$ENVIRONMENT" = "proxmox" ]; then
    # Host Proxmox
    local MISSING=()
    for pkg in "${REQUIRED_PKGS[@]}"; do
      dpkg -s "$pkg" &>/dev/null || MISSING+=("$pkg")
    done

    if [ ${#MISSING[@]} -gt 0 ]; then
      echo "⚠️  Faltan paquetes en el host:"
      printf '  - %s\n' "${MISSING[@]}"
      read -rp "¿Instalarlos ahora en el host? (Y/n): " RESP
      if [[ ! "$RESP" =~ ^[Nn]$ ]]; then
        apt update -qq && apt install -y "${MISSING[@]}"
      else
        echo "⏭️  Saltando instalación en el host."
      fi
    else
      echo "✅ Host: prerrequisitos completos."
    fi

    # Verificación y carga de módulos ALSA en host
    check_alsa_modules

  elif [ "$ENVIRONMENT" = "lxc" ] || [ "$ENVIRONMENT" = "debian" ]; then
    # Dentro de un contenedor o Debian suelto
    local MISSING=()
    for pkg in "${REQUIRED_PKGS[@]}"; do
      dpkg -s "$pkg" &>/dev/null || MISSING+=("$pkg")
    done

    if [ ${#MISSING[@]} -gt 0 ]; then
      echo "⚠️  Faltan paquetes en este sistema:"
      printf '  - %s\n' "${MISSING[@]}"
      read -rp "¿Instalarlos ahora? (Y/n): " RESP
      if [[ ! "$RESP" =~ ^[Nn]$ ]]; then
        apt update -qq && apt install -y "${MISSING[@]}"
      else
        echo "⏭️  Saltando instalación local."
      fi
    else
      echo "✅ Sistema: prerrequisitos completos."
    fi
  else
    echo "⚠️  Entorno desconocido; no se verifican prerrequisitos."
  fi

  echo ""
  pause
}

# === VERIFICAR Y CARGAR MÓDULOS ALSA (HOST) ==================================

check_alsa_modules() {
  echo ""
  echo "🎧 Verificando módulos ALSA en el host…"
  echo ""

  local MODULES=("snd_hda_intel" "snd_usb_audio" "snd_soc_core" "snd_pcm" "snd_seq")

  for mod in "${MODULES[@]}"; do
    if ! lsmod | grep -q "^${mod}"; then
      echo "⚠️  Módulo no cargado: $mod"
      if modinfo "$mod" &>/dev/null; then
        read -rp "¿Cargar $mod ahora? (Y/n): " RESP
        if [[ ! "$RESP" =~ ^[Nn]$ ]]; then
          modprobe "$mod" && echo "✅ $mod cargado."
        else
          echo "⏭️  Omitido $mod."
        fi
      else
        echo "❌ $mod no existe en este kernel."
      fi
    else
      echo "✅ $mod ya cargado."
    fi
  done

  echo ""
  echo "🔍 aplay -l:"
  if command -v aplay >/dev/null 2>&1; then
    aplay -l 2>/dev/null || echo "⚠️  Sin dispositivos de reproducción detectados."
  else
    echo "⚠️  'aplay' no está instalado (instala alsa-utils)."
  fi
  echo ""
}

# === GENERAR DIAGNÓSTICO =====================================================

generate_diagnostics() {
  local OUT="/root/snap-audio-check.log"
  echo "🧾 Generando diagnóstico en $OUT …"
  {
    echo "═══════════════════════════════════════════════════════"
    echo " SNAPCLIENT AUDIO DIAGNOSTIC REPORT"
    echo " Fecha: $(date)"
    echo " Hostname: $(hostname)"
    echo "═══════════════════════════════════════════════════════"
    echo
    echo "🧠 Entorno: $(detect_environment)"
    echo "📦 Debian: $(detect_debian_codename)"
    echo
    echo "🔧 Paquetes (alsa-utils, ffmpeg, wget, psmisc, curl):"
    dpkg -l | grep -E 'alsa-utils|ffmpeg|wget|psmisc|curl' || echo "No se detectaron paquetes base"
    echo
    echo "🎛️ Módulos ALSA (lsmod | grep snd):"
    lsmod | grep snd || echo "No hay módulos 'snd' cargados"
    echo
    echo "🎧 /proc/asound/cards:"
    cat /proc/asound/cards 2>/dev/null || echo "No hay tarjetas"
    echo
    echo "🔊 aplay -l:"
    if command -v aplay >/dev/null 2>&1; then
      aplay -l 2>&1 || true
    else
      echo "aplay no instalado."
    fi
    echo
    echo "🎚️ Servicio snapclient (systemctl status):"
    systemctl status snapclient 2>&1 | head -n 30 || echo "Snapclient no instalado"
    echo
    echo "📜 journalctl -u snapclient (últimos 30):"
    journalctl -u snapclient -n 30 --no-pager 2>&1 || true
    echo
  } > "$OUT"
  echo "✅ Diagnóstico listo: $OUT"
  echo ""
  pause
}

# === FIJAR ORDEN DE TARJETAS ALSA (HOST) =====================================

fix_alsa_order() {
  echo "🔍 Detectando tarjetas ALSA en el host…"
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
    echo "❌ No se detectaron tarjetas ALSA. Abortando."
    return
  fi

  echo "🎧 Tarjetas detectadas:"
  for i in "${!CARDS[@]}"; do
    echo "  [${CARDS[$i]}] -> ${IDS[$i]}"
  done
  echo

  read -rp "👉 ¿Cuál tarjeta será la PRINCIPAL (card0)? (ej: Device o PCH): " MAIN
  read -rp "👉 ¿Y la SECUNDARIA (card1)? (dejar en blanco si solo hay una): " SECONDARY

  if ! grep -q "$MAIN" /proc/asound/card*/id; then
    echo "❌ No se encontró ninguna tarjeta con nombre '$MAIN'. Abortando."
    return
  fi

  local CONF_FILE="/etc/modprobe.d/alsa-base.conf"
  local BACKUP_FILE="/etc/modprobe.d/alsa-base.conf.bak_$(date +%Y%m%d%H%M%S)"
  [ -f "$CONF_FILE" ] && cp "$CONF_FILE" "$BACKUP_FILE" && echo "📦 Backup: $BACKUP_FILE"

  echo "🧩 Actualizando $CONF_FILE …"
  {
    echo "# Generated by setup-snapclient.sh on $(date)"
  } > "$CONF_FILE"

  local MOD_USB
  local MOD_HDA
  if lsmod | grep -q snd_usb_audio; then
    MOD_USB="snd_usb_audio"
  else
    MOD_USB="snd-usb-audio"
  fi
  if lsmod | grep -q snd_hda_intel; then
    MOD_HDA="snd_hda_intel"
  else
    MOD_HDA="snd-hda-intel"
  fi

  if [[ "$MAIN" =~ [Uu][Ss][Bb] || "$MAIN" =~ [Dd]evice ]]; then
    echo "options $MOD_USB index=0" >> "$CONF_FILE"
    echo "options $MOD_HDA index=1" >> "$CONF_FILE"
  else
    echo "options $MOD_HDA index=0" >> "$CONF_FILE"
    echo "options $MOD_USB index=1" >> "$CONF_FILE"
  fi

  echo
  echo "✅ Orden ALSA fijado."
  echo "🎯 card0 → $MAIN"
  [[ -n "$SECONDARY" ]] && echo "🎯 card1 → $SECONDARY"
  echo
  echo "⚙️  Reinicia el host para aplicar cambios."
  echo
}

# === CONFIGURAR SNAPCLIENT (HOST/PROXMOX -> CONTENEDOR o LOCAL) ==============

setup_snapclient() {
  local ENVIRONMENT
  ENVIRONMENT=$(detect_environment)

  local CTID=""
  local DEBIAN_VERSION=""
  local INSTALLED_VER=""
  local SUGGESTED_VER=""

  if [ "$ENVIRONMENT" = "proxmox" ]; then
    echo ""
    echo "📦 Contenedores disponibles:"
    pct list | awk 'NR>1 {printf " - %s (%s)\n", $1, $2}'
    echo ""
    read -rp "Ingrese el ID del contenedor LXC destino: " CTID
    if ! pct status "$CTID" >/dev/null 2>&1; then
      echo "❌ El contenedor $CTID no existe."
      exit 1
    fi
    DEBIAN_VERSION=$(pct exec "$CTID" -- bash -c 'grep VERSION_CODENAME= /etc/os-release | cut -d= -f2' 2>/dev/null || echo "bookworm")
    INSTALLED_VER=$(pct exec "$CTID" -- bash -c 'snapclient --version 2>/dev/null | head -n1 | awk "{print \$3}"' || echo "none")
  else
    DEBIAN_VERSION=$(detect_debian_codename)
    INSTALLED_VER=$(detect_snap_version)
  fi

  SUGGESTED_VER=$(get_suggested_snap_ver "$DEBIAN_VERSION")

  echo ""
  echo "📦 Sistema Debian detectado: $DEBIAN_VERSION"
  echo "💡 Versión recomendada de Snapclient: $SUGGESTED_VER"
  echo "🔍 Versión instalada actual: $INSTALLED_VER"
  echo ""

  if [ "$ENVIRONMENT" = "proxmox" ]; then
    echo "🔍 Tarjetas de audio del host:"
    if command -v aplay >/dev/null 2>&1; then
      aplay -l | grep '^card' || echo "⚠️ No se detectaron tarjetas ALSA."
    else
      echo "⚠️ 'aplay' no está instalado en el host."
    fi
  else
    echo "🔍 Tarjetas locales:"
    if command -v aplay >/dev/null 2>&1; then
      aplay -l | grep '^card' || echo "⚠️ No se detectaron tarjetas ALSA."
    else
      echo "⚠️ 'aplay' no está instalado en este sistema."
    fi
  fi

  echo ""
  read -rp "Ingrese el número de tarjeta a usar (ej. 0=Interna, 1=DAC): " CARD_ID

  echo ""
  echo "🎧 Dispositivos disponibles en card $CARD_ID:"
  if command -v aplay >/dev/null 2>&1; then
    aplay -l | awk -v id=$CARD_ID '/^card/ && $2==id":" {print " - device " $6 ": " substr($0, index($0,$8))}' | sed 's/,//g' || true
  fi
  mapfile -t DEVICE_NUMS < <(aplay -l 2>/dev/null | awk -v id=$CARD_ID '/^card/ && $2==id":" {print $6}' | sed 's/,//')
  if [ ${#DEVICE_NUMS[@]} -eq 0 ]; then
    echo "❌ No se detectaron dispositivos ALSA para card $CARD_ID."
    exit 1
  fi

  read -rp "Selecciona el número de dispositivo (ej. ${DEVICE_NUMS[0]}): " DEV_ID
  [[ -z "$DEV_ID" ]] && DEV_ID="${DEVICE_NUMS[0]}"

  local CARD_NAME
  CARD_NAME=$(aplay -l 2>/dev/null | awk -v id=$CARD_ID -F'[][]' '/^card/{if ($2==id) {print $4; exit}}')
  local SAFE_CARD_NAME
  SAFE_CARD_NAME=$(echo "${CARD_NAME:-CARD$CARD_ID}" | tr -d ' ')
  local ALSA_DEVICE="plughw:CARD=$SAFE_CARD_NAME,DEV=$DEV_ID"

  echo "✅ Usando ALSA: $ALSA_DEVICE"
  echo ""

  read -rp "Ingrese la IP del Snapserver: " SNAPSERVER_IP
  read -rp "Ingrese el nombre del cliente Snapcast: " CLIENT_NAME
  read -rp "🎚️ Ingrese el volumen inicial (0–100)%: " VOLUME

  local CARD_DESC
  CARD_DESC=$(aplay -l 2>/dev/null | awk -v id=$CARD_ID -F'[][]' '/^card/{if ($2==id) {print $4; exit}}')

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "🧾 REVISIÓN FINAL DE CONFIGURACIÓN:"
  [[ "$ENVIRONMENT" == "proxmox" ]] && echo " Contenedor LXC:     $CTID"
  echo " Debian:            $DEBIAN_VERSION"
  echo " Snapclient actual: $INSTALLED_VER"
  echo " Snapclient nuevo:  $SUGGESTED_VER"
  echo " Tarjeta:           card $CARD_ID (${CARD_DESC:-Desconocida})"
  echo " Dispositivo ALSA:  $ALSA_DEVICE"
  echo " Snapserver IP:     $SNAPSERVER_IP"
  echo " Nombre cliente:    $CLIENT_NAME"
  echo " Volumen inicial:   ${VOLUME}%"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  read -rp "¿Deseas aplicar esta configuración? (Y/n): " CONFIRM
  [[ "$CONFIRM" =~ ^[Nn]$ ]] && { echo "❌ Cancelado."; return; }

  if [ "$ENVIRONMENT" = "proxmox" ]; then
    local CONF_FILE="/etc/pve/lxc/${CTID}.conf"
    if ! grep -q "/dev/snd" "$CONF_FILE"; then
      echo "⚙️ Agregando passthrough de /dev/snd al contenedor $CTID…"
      cat <<EOF >> "$CONF_FILE"

# === Passthrough ALSA ===
lxc.cgroup2.devices.allow: c 116:* rwm
lxc.mount.entry: /dev/snd dev/snd none bind,optional,create=dir
EOF
    fi

    echo "🔄 Reiniciando contenedor…"
    pct reboot "$CTID"
    sleep 5

    echo "📦 Instalando y configurando Snapclient en el contenedor…"
    pct exec "$CTID" -- bash -c "
      set -Eeuo pipefail
      apt update -qq
      apt install -yq alsa-utils psmisc ffmpeg wget
      cd /root
      wget -q https://github.com/badaix/snapcast/releases/download/$SUGGESTED_VER/snapclient_${SUGGESTED_VER#v}-1_amd64_${DEBIAN_VERSION}.deb -O snapclient.deb
      apt install -y ./snapclient.deb
      usermod -aG audio snapclient || true
      mkdir -p /etc
      echo 'defaults.pcm.card $CARD_ID' > /etc/asound.conf
      echo 'defaults.ctl.card $CARD_ID' >> /etc/asound.conf
      cat > /etc/default/snapclient <<CONF
START_SNAPCLIENT=true
SNAPCLIENT_OPTS=\"--soundcard $ALSA_DEVICE --hostID $CLIENT_NAME tcp://$SNAPSERVER_IP:1704\"
CONF
      amixer -c $CARD_ID sset Master ${VOLUME}% || amixer -c $CARD_ID sset Speaker ${VOLUME}% || amixer -c $CARD_ID sset PCM ${VOLUME}% || true
      alsactl store || true
      systemctl enable snapclient
      systemctl restart snapclient
    "
  else
    echo "📦 Instalando y configurando Snapclient localmente…"
    apt update -qq && apt install -yq alsa-utils psmisc ffmpeg wget
    cd /root
    wget -q https://github.com/badaix/snapcast/releases/download/$SUGGESTED_VER/snapclient_${SUGGESTED_VER#v}-1_amd64_${DEBIAN_VERSION}.deb -O snapclient.deb
    apt install -y ./snapclient.deb
    usermod -aG audio snapclient 2>/dev/null || true
    mkdir -p /etc
    echo "defaults.pcm.card $CARD_ID" > /etc/asound.conf
    echo "defaults.ctl.card $CARD_ID" >> /etc/asound.conf
    cat > /etc/default/snapclient <<CONF
START_SNAPCLIENT=true
SNAPCLIENT_OPTS="--soundcard $ALSA_DEVICE --hostID $CLIENT_NAME tcp://$SNAPSERVER_IP:1704"
CONF
    amixer -c $CARD_ID sset Master ${VOLUME}% || amixer -c $CARD_ID sset Speaker ${VOLUME}% || amixer -c $CARD_ID sset PCM ${VOLUME}% || true
    alsactl store || true
    systemctl enable snapclient
    systemctl restart snapclient
  fi

  verify_snapclient "$ENVIRONMENT" "${CTID:-}"
}

# === VERIFICAR CONEXIÓN SNAPCLIENT ===========================================

verify_snapclient() {
  local ENV="$1"
  local CT="${2:-}"
  echo ""
  echo "🔍 Verificando conexión Snapclient → Snapserver…"
  sleep 5
  if [ "$ENV" = "proxmox" ] && [ -n "$CT" ]; then
    if pct exec "$CT" -- bash -lc 'journalctl -u snapclient -n 50 --no-pager | grep -q Connected'; then
      echo "✅ Snapclient conectado correctamente al Snapserver."
    else
      echo "⚠️  No se detectó conexión. Revisa IP/puerto del Snapserver, firewall o dispositivo ALSA."
      pct exec "$CT" -- journalctl -u snapclient -n 20 --no-pager | tail -n 20
    fi
  else
    if journalctl -u snapclient -n 50 --no-pager | grep -q "Connected"; then
      echo "✅ Snapclient conectado correctamente al Snapserver."
    else
      echo "⚠️  No se detectó conexión. Revisa IP/puerto del Snapserver o el dispositivo ALSA."
      journalctl -u snapclient -n 20 --no-pager | tail -n 20
    fi
  fi
  echo ""
  pause
}

# === VERIFICAR SNAPCLIENT EXISTENTE (MENÚ) ====================================

verify_existing_snapclient() {
  local ENVIRONMENT
  ENVIRONMENT=$(detect_environment)
  echo ""
  echo "🔎 Verificación de Snapclient existente…"
  if [ "$ENVIRONMENT" = "proxmox" ]; then
    echo ""
    echo "📦 Contenedores disponibles:"
    pct list | awk 'NR>1 {printf " - %s (%s)\n", $1, $2}'
    echo ""
    read -rp "Ingrese el ID del contenedor a verificar: " CTID
    verify_snapclient "proxmox" "$CTID"
  else
    verify_snapclient "$ENVIRONMENT" ""
  fi
}

# === MENÚ PRINCIPAL ==========================================================

clear
echo "═══════════════════════════════════════════════════"
echo "      🎧 SNAPCLIENT AUDIO MANAGER v2025.10.26-r3"
echo "═══════════════════════════════════════════════════"
echo "1️⃣  Verificar/instalar prerrequisitos"
echo "2️⃣  Fijar orden ALSA del host"
echo "3️⃣  Configurar Snapclient en LXC/Debian"
echo "4️⃣  Ejecutar ambos pasos (recomendado)"
echo "5️⃣  🔎 Verificar Snapclient existente"
echo "6️⃣  🧾 Generar diagnóstico (snap-audio-check.log)"
echo "7️⃣  🚪 Salir"
echo "═══════════════════════════════════════════════════"
read -rp "Selecciona una opción [1-7]: " opt

case "$opt" in
  1) check_prerequisites ;;
  2) check_prerequisites; fix_alsa_order ;;
  3) check_prerequisites; setup_snapclient ;;
  4) check_prerequisites; fix_alsa_order; setup_snapclient ;;
  5) verify_existing_snapclient ;;
  6) generate_diagnostics ;;
  7) echo "👋 Saliendo…"; exit 0 ;;
  *) echo "❌ Opción inválida."; exit 1 ;;
esac
