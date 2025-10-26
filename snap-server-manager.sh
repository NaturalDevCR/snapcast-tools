#!/bin/bash
# ==============================================================================
# SNAPSTREAM MANAGER v2025.10.31
# Gestión avanzada de Snapserver + FFmpeg + Streams + LXC-aware
# Instalación segura desde releases .deb oficiales (sin compilar), SHA256 y rollback.
# Autor: Josue / GPT-5 — No bullshit edition.
# ==============================================================================

set -Eeuo pipefail

SNAP_FIFO_DIR="/var/lib/snapserver/fifo"
SYSTEMD_DIR="/etc/systemd/system"
CONF_FILE="/etc/snapserver.conf"
BACKUP_DIR="/etc/snapserver.d/backups"
CACHE_DIR="/var/cache/snapstream"
SNAP_USER="snapserver"
SNAP_GROUP="snapserver"

mkdir -p "$BACKUP_DIR" "$CACHE_DIR"

# ────────────────────────────────────────────────────────────────────────────
# Utilidades base / rollback
# ────────────────────────────────────────────────────────────────────────────
pause(){ read -rp "Presiona Enter para continuar..."; }
ts(){ date +"%Y-%m-%d_%H-%M-%S"; }
escape_sed(){ sed -e 's/[\/&]/\\&/g' <<<"$1"; }

rollback(){
  echo "⚠️  ERROR: ejecutando ROLLBACK…"

  if systemctl list-unit-files | grep -q snapserver.service; then
    systemctl stop snapserver 2>/dev/null || true
  fi

  if [ -f "$BACKUP_DIR/snapserver_prev.deb" ]; then
    echo "↩️  Restaurando paquete previo…"
    dpkg -i "$BACKUP_DIR/snapserver_prev.deb" || true
  else
    echo "ℹ️  No había snapserver previo. Nada que restaurar."
  fi

  if [ -f "$BACKUP_DIR/snapserver.conf.prev" ]; then
    echo "↩️  Restaurando configuración previa…"
    cp -f "$BACKUP_DIR/snapserver.conf.prev" "$CONF_FILE"
  fi

  systemctl daemon-reload || true

  if systemctl list-unit-files | grep -q snapserver.service; then
    systemctl restart snapserver || true
  fi

  echo "✅ Rollback completado."
  exit 1
}

trap rollback ERR

# ────────────────────────────────────────────────────────────────────────────
# LXC detection & guidance
# ────────────────────────────────────────────────────────────────────────────
detect_lxc(){
  if grep -qa container=lxc /proc/1/environ 2>/dev/null; then
    LXC_MODE=1
  else
    LXC_MODE=0
  fi
}

lxc_instructions(){
  echo ""
  echo "─────────────────────────────────────────────"
  echo "   🧠 EJECUCIÓN EN CONTENEDOR LXC DETECTADA"
  echo "─────────────────────────────────────────────"
  echo "Snapserver en LXC puede funcionar de dos maneras:"
  echo ""
  echo " 1) 🟢 Solo orquestación (modo típico)"
  echo "    - No reproduce audio aquí"
  echo "    - No captura audio aquí"
  echo "    - Los clientes reproducen"
  echo "    → NO requiere /dev/snd ni configuraciones adicionales."
  echo ""
  echo " 2) 🎤 Captura de audio local (ej: mixer / mic / tarjeta USB)"
  echo "    - FFmpeg usará ALSA dentro del CT"
  echo "    → Sí requiere /dev/snd y permisos de cgroup."
  echo ""
  echo "─────────────────────────────────────────────"
  read -rp "¿Vas a capturar audio desde hardware local en este contenedor? (y/N): " use_hw
  echo ""
  if [[ "$use_hw" =~ ^[Yy]$ ]]; then
    echo "⚙️ Se requiere habilitar /dev/snd en el host Proxmox."
    echo ""
    echo "Ejecuta en el HOST (Proxmox), reemplazando <ID>:"
    echo ""
    echo "  pct stop <ID>"
    echo "  echo \"lxc.cgroup2.devices.allow = c 116:* rwm\" >> /etc/pve/lxc/<ID>.conf"
    echo "  echo \"lxc.mount.entry = /dev/snd dev/snd none bind,optional,create=dir\" >> /etc/pve/lxc/<ID>.conf"
    echo "  pct start <ID>"
    echo ""
    echo "Si el CT es no privilegiado:"
    echo "  pct set <ID> -features nesting=1,mount=1"
    echo ""
    echo "Después dentro del contenedor:"
    echo "  systemctl restart snapserver"
    echo ""
    pause
  else
    echo "🟢 Perfecto. Modo servidor puro."
    echo "   No se configurará /dev/snd porque no se necesita."
    echo ""
    pause
  fi
}


# ────────────────────────────────────────────────────────────────────────────
# Resumen previo y aprobación del usuario
# ────────────────────────────────────────────────────────────────────────────
confirm_actions(){
  local ARCH CODENAME SNAPVER
  ARCH="$(dpkg --print-architecture)"
  CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-unknown}")"

  echo ""
  echo "════════════════════════════════════════════════════"
  echo "🧩 RESUMEN DE ACCIONES A REALIZAR"
  echo "════════════════════════════════════════════════════"
  echo "🧠 Sistema detectado:"
  echo "  • OS: $CODENAME"
  echo "  • Arquitectura: $ARCH"

  RELEASE_API="https://api.github.com/repos/badaix/snapcast/releases/latest"
  SNAPVER="$(curl -s --max-time 10 "$RELEASE_API" | jq -r '.tag_name // empty' || true)"
  [ -n "$SNAPVER" ] && echo "  • Última versión Snapcast en GitHub: $SNAPVER"

  echo ""
  echo "Acciones:"
  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "  - 📦 Instalar FFmpeg"
  else
    echo "  - ✅ FFmpeg ya instalado"
  fi

  if ! command -v snapserver >/dev/null 2>&1; then
    echo "  - ⬇️ Instalar Snapserver (.deb oficial desde GitHub)"
  else
    echo "  - ✅ Snapserver ya instalado"
  fi

  if ! id -u "$SNAP_USER" >/dev/null 2>&1; then
    echo "  - 👤 Crear usuario '${SNAP_USER}'"
  else
    echo "  - ✅ Usuario '${SNAP_USER}' ya existe"
  fi

  echo ""
  echo "════════════════════════════════════════════════════"
  read -rp "¿Deseas continuar? (y/N): " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "❌ Cancelado por el usuario."; exit 0; }
  echo ""
}

# ────────────────────────────────────────────────────────────────────────────
# Instalación segura Snapserver desde release .deb
# ────────────────────────────────────────────────────────────────────────────
install_prereqs(){
  echo "🔍 Verificando/instalando prerequisitos…"
  apt-get update -y
  apt-get install -y ffmpeg curl jq

  id -u "$SNAP_USER" >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin "$SNAP_USER"

  [ -f "$CACHE_DIR/snapserver_current.deb" ] && cp -f "$CACHE_DIR/snapserver_current.deb" "$BACKUP_DIR/snapserver_prev.deb" || true
  [ -f "$CONF_FILE" ] && cp -f "$CONF_FILE" "$BACKUP_DIR/snapserver.conf.prev" || true

  ARCH="$(dpkg --print-architecture)"
  CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-unknown}")"
  RELEASE_API="https://api.github.com/repos/badaix/snapcast/releases/latest"

  echo "⬇️ Buscando última release…"
  SNAPVER="$(curl -s "$RELEASE_API" | jq -r '.tag_name')"
  [ -z "$SNAPVER" ] && { echo "❌ No se pudo obtener versión."; exit 1; }
  echo "📌 Versión: $SNAPVER"

  PACKAGE_URL="$(curl -s "$RELEASE_API" | jq -r '
    .assets[]
    | select(.name | test("_with-pipewire") | not)
    | select(.name | test("snapserver_.*_'"$ARCH"'_'"$CODENAME"'\\.deb$"))
    | .browser_download_url
  ' | head -n1)"

  if [ -z "$PACKAGE_URL" ] || [ "$PACKAGE_URL" = "null" ]; then
    echo "⚠️ Buscando fallback a bookworm…"
    PACKAGE_URL="$(curl -s "$RELEASE_API" | jq -r '
      .assets[]
      | select(.name | test("_with-pipewire") | not)
      | select(.name | test("snapserver_.*_'"$ARCH"'_bookworm\\.deb$"))
      | .browser_download_url
    ' | head -n1)"
  fi

  [ -z "$PACKAGE_URL" ] && { echo "❌ No hay paquete compatible."; exit 1; }

  echo "📦 Descargando:"
  echo "   $PACKAGE_URL"
  cd /tmp
  FILENAME="$(basename "$PACKAGE_URL")"
  curl -L -o "$FILENAME" "$PACKAGE_URL"

  echo "📦 Instalando..."
  dpkg -i "$FILENAME" || apt-get -f install -y
  cp -f "/tmp/$FILENAME" "$CACHE_DIR/snapserver_current.deb" || true

  mkdir -p "$SNAP_FIFO_DIR"
  chown -R "$SNAP_USER:$SNAP_GROUP" "$SNAP_FIFO_DIR"
  [ -f "$CONF_FILE" ] || echo "[stream]" > "$CONF_FILE"

  systemctl daemon-reload
  systemctl enable snapserver
  systemctl restart snapserver
  echo "✅ Snapserver instalado y activo."
}

ensure_prereqs(){
  confirm_actions
  install_prereqs
}

# ────────────────────────────────────────────────────────────────────────────
# GESTIÓN DE STREAMS (sin ALSA)
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
  echo "📜 Streams:"
  mapfile -t sources < <(get_stream_lines)
  [ "${#sources[@]}" -eq 0 ] && { echo "❌ No hay streams."; return 1; }
  local i=1
  for line in "${sources[@]}"; do
    local entry="${line#*:}"
    local name="$(sed -E 's/.*[?&]name=([^&]+).*/\1/' <<<"$entry")"
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
  local service_name="$1" fifo="$2" ffmpeg_line="$3"
  cat > "${SYSTEMD_DIR}/${service_name}" <<EOF
[Unit]
Description=FFmpeg Stream (${service_name})
After=network-online.target snapserver.service

[Service]
ExecStart=${ffmpeg_line}
User=${SNAP_USER}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

ffmpeg_cmd_for(){
  local INPUT_ARGS="$1" FIFO_PATH="$2"
  echo "/usr/bin/ffmpeg -hide_banner -nostats -loglevel error $INPUT_ARGS -ac 2 -ar 48000 -acodec pcm_s16le -f s16le -y \"$FIFO_PATH\""
}

add_or_replace_stream_line(){
  local fifo="$1" name="$2" sample="48000:16:2" tmp
  tmp="$(mktemp)"

  grep -q "^\[stream\]" "$CONF_FILE" || echo "[stream]" >> "$CONF_FILE"
  sed "/$(escape_sed "$fifo")/d" "$CONF_FILE" > "$tmp" && mv "$tmp" "$CONF_FILE"

  local newline="source = pipe:///${fifo}?name=${name}&codec=pcm&sampleformat=${sample}"
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
  echo "➕ Crear nuevo stream"
  echo "1) URL (HTTP/HTTPS/RTSP/RTMP)"
  echo "2) Archivo local (loop infinito)"
  echo "3) FFmpeg personalizado"
  read -rp "Elige tipo [1-3]: " kind

  read -rp "Nombre del stream: " STREAM_NAME
  [ -z "$STREAM_NAME" ] && { echo "❌ Nombre requerido."; pause; return; }

  STREAM_ID="$(mk_stream_id "$STREAM_NAME")"
  FIFO_PATH="$(fifo_path_for "$STREAM_ID")"
  SERVICE_NAME="$(service_name_for "$STREAM_ID")"

  case "$kind" in
    1) read -rp "URL: " URL
       INPUT_ARGS="-reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 -i \"$URL\"" ;;
    2) read -rp "Archivo local (mp3/wav/flac): " FILE
       INPUT_ARGS="-stream_loop -1 -re -i \"$FILE\"" ;;
    3) read -rp "Args FFmpeg: " CUSTOM
       INPUT_ARGS="$CUSTOM" ;;
    *) echo "❌ Selección inválida."; pause; return ;;
  esac

  ensure_fifo "$FIFO_PATH"
  FFMPEG_LINE="$(ffmpeg_cmd_for "$INPUT_ARGS" "$FIFO_PATH")"
  write_unit "$SERVICE_NAME" "$FIFO_PATH" "$FFMPEG_LINE"

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl restart "$SERVICE_NAME"

  add_or_replace_stream_line "$FIFO_PATH" "$STREAM_NAME"
  systemctl restart snapserver
  echo "✅ Stream creado."
  pause
}

edit_stream(){
  show_streams_numbered || { pause; return; }
  read -rp "Número: " num
  mapfile -t sources < <(get_stream_lines)
  entry="${sources[$((num-1))]#*:}"

  fifo="$(sed -E 's|.*fifo/([^?]+)\?.*|\1|' <<<"$entry")"
  STREAM_ID="${fifo#snapfifo_}"
  SERVICE_NAME="$(service_name_for "$STREAM_ID")"

  ${EDITOR:-nano} "$SYSTEMD_DIR/$SERVICE_NAME"
  systemctl daemon-reload
  systemctl restart "$SERVICE_NAME"
}

delete_streams(){
  show_streams_numbered || { pause; return; }
  read -rp "Número(s) a eliminar (coma): " sel
  IFS=',' read -ra CHOSEN <<<"$sel"
  for n in "${CHOSEN[@]}"; do
    mapfile -t sources < <(get_stream_lines)
    entry="${sources[$((n-1))]#*:}"
    fifo="$(sed -E 's|.*fifo/([^?]+)\?.*|\1|' <<<"$entry")"
    STREAM_ID="${fifo#snapfifo_}"
    SVC="$(service_name_for "$STREAM_ID")"
    systemctl stop "$SVC" 2>/dev/null || true
    systemctl disable "$SVC" 2>/dev/null || true
    rm -f "$SYSTEMD_DIR/$SVC" "$SNAP_FIFO_DIR/$fifo"
    sed -i "/${fifo}/d" "$CONF_FILE"
  done
  systemctl daemon-reload
  systemctl restart snapserver
  echo "✅ Eliminado(s)."
  pause
}

check_activity(){
  echo ""
  echo "🎧 Estado actual:"
  mapfile -t sources < <(get_stream_lines)
  for line in "${sources[@]}"; do
    entry="${line#*:}"
    name="$(sed -E 's/.*[?&]name=([^&]+).*/\1/' <<<"$entry")"
    fifo="$(sed -E 's|.*fifo/([^?]+)\?.*|\1|' <<<"$entry")"
    id="${fifo#snapfifo_}"
    svc="$(service_name_for "$id")"
    st="$(systemctl is-active "$svc" 2>/dev/null || echo unknown)"
    printf "• %-22s : %-10s\n" "$name" "$st"
  done
  echo ""
  pause
}

# ────────────────────────────────────────────────────────────────────────────
# Menú principal
# ────────────────────────────────────────────────────────────────────────────
main_menu(){
  ensure_prereqs
  detect_lxc
  if [[ "$LXC_MODE" -eq 1 ]]; then
    lxc_instructions
  fi

  while true; do
    clear
    echo "═══════════════════════════════════════════════════"
    echo "           🧩 SNAPSTREAM MANAGER"
    echo "═══════════════════════════════════════════════════"
    echo "1) Agregar nuevo stream"
    echo "2) Listar streams"
    echo "3) Editar un stream"
    echo "4) Eliminar stream(s)"
    echo "5) Ver estado"
    echo "6) Salir"
    echo "═══════════════════════════════════════════════════"
    read -rp "Elige [1-6]: " opt
    case "$opt" in
      1) create_stream ;;
      2) get_stream_lines | nl -ba; pause ;;
      3) edit_stream ;;
      4) delete_streams ;;
      5) check_activity ;;
      6) exit 0 ;;
      *) pause ;;
    esac
  done
}

main_menu
