#!/bin/bash
# ==============================================================================
# SNAPSTREAM MANAGER v2025.10.28
# Gestión avanzada de Snapserver y FFmpeg basada en snapserver.conf
# Autor: Josue / GPT-5
# ==============================================================================

set -Eeuo pipefail
SNAP_FIFO_DIR="/var/lib/snapserver/fifo"
SYSTEMD_DIR="/etc/systemd/system"
CONF_FILE="/etc/snapserver.conf"
BACKUP_DIR="/etc/snapserver.d/backups"
SNAP_USER="snapserver"
SNAP_GROUP="snapserver"

# ────────────────────────────────────────────────────────────────────────────
# Utilidades
# ────────────────────────────────────────────────────────────────────────────
pause(){ read -rp "Presiona Enter para continuar..."; }
ts(){ date +"%Y-%m-%d_%H-%M-%S"; }
ensure_cmd(){ command -v "$1" >/dev/null 2>&1 || { echo "❌ Requiere '$1'."; exit 1; }; }
escape_sed(){ sed -e 's/[\/&]/\\&/g' <<<"$1"; }

confirm_actions(){
  echo ""
  echo "════════════════════════════════════════════════════"
  echo "🧩 RESUMEN DE ACCIONES A REALIZAR"
  echo "════════════════════════════════════════════════════"
  echo ""

  local todo=()

  # ffmpeg
  if ! command -v ffmpeg >/dev/null 2>&1; then
    todo+=("📦 Instalar FFmpeg")
  else
    todo+=("✅ FFmpeg ya instalado")
  fi

  # alsa-utils
  if ! dpkg -l | grep -q '^ii.*alsa-utils'; then
    todo+=("📦 Instalar ALSA (alsa-utils)")
  else
    todo+=("✅ ALSA ya instalado")
  fi

  # snapserver
  if ! command -v snapserver >/dev/null 2>&1; then
    todo+=("⬇️ Descargar e instalar Snapserver (.deb oficial desde GitHub)")
  else
    todo+=("✅ Snapserver ya instalado (no se reinstala)")
  fi

  # usuario snapserver
  if ! id -u snapserver >/dev/null 2>&1; then
    todo+=("👤 Crear usuario 'snapserver'")
  else
    todo+=("✅ Usuario snapserver ya existe")
  fi

  echo "Acciones:"
  printf '  - %s\n' "${todo[@]}"
  echo ""

  echo "════════════════════════════════════════════════════"
  read -rp "¿Deseas continuar? (y/N): " ans
  case "$ans" in
    [Yy]*) echo "✅ Continuando...";;
    *) echo "❌ Cancelado por el usuario."; exit 0;;
  esac
  echo ""
}


install_prereqs(){
  echo "🔍 Verificando dependencias..."

  apt-get update -y
  apt-get install -y alsa-utils ffmpeg curl jq

  # Crear usuario snapserver si no existe
  if ! id -u snapserver >/dev/null 2>&1; then
    echo "👤 Creando usuario snapserver..."
    useradd -r -s /usr/sbin/nologin snapserver
  fi

  # Detectar arquitectura
  ARCH="$(dpkg --print-architecture)"
  echo "🏗 Arquitectura detectada: $ARCH"

  # Detectar OS codename
  CODENAME="$(grep VERSION_CODENAME= /etc/os-release | cut -d= -f2)"
  echo "🧭 OS: $CODENAME"

  # Obtener última release desde GitHub
  echo "⬇️ Buscando última versión de Snapcast..."
  RELEASE_API="https://api.github.com/repos/badaix/snapcast/releases/latest"
  SNAPVER=$(curl -s "$RELEASE_API" | jq -r .tag_name)

  if [ -z "$SNAPVER" ] || [ "$SNAPVER" = "null" ]; then
    echo "❌ No se pudo obtener la versión desde GitHub."
    exit 1
  fi

  echo "📌 Última versión: $SNAPVER"

  # Buscar el .deb correcto
  PACKAGE_URL=$(curl -s "$RELEASE_API" | jq -r ".assets[] | select(.name | test(\"snapserver_.*_${ARCH}.*deb\")) | .browser_download_url")

  if [ -z "$PACKAGE_URL" ] || [ "$PACKAGE_URL" = "null" ]; then
    echo "❌ No hay .deb para arquitectura $ARCH en $SNAPVER"
    exit 1
  fi

  echo "📦 Paquete encontrado:"
  echo "   $PACKAGE_URL"

  cd /tmp
  curl -LO "$PACKAGE_URL"

  echo "📦 Instalando paquete .deb..."
  dpkg -i snapserver_*_"$ARCH".deb || apt-get -f install -y

  # Crear directorios si no existen
  mkdir -p /var/lib/snapserver /etc/snapserver.d/backups /var/lib/snapserver/fifo
  chown -R snapserver:snapserver /var/lib/snapserver

  # Crear servicio systemd si viene faltante (según release)
  if ! systemctl list-unit-files | grep -q snapserver.service; then
    cat > /etc/systemd/system/snapserver.service <<EOF
[Unit]
Description=Snapcast Server
After=network.target

[Service]
ExecStart=/usr/bin/snapserver --config /etc/snapserver.conf
User=snapserver
Restart=always

[Install]
WantedBy=multi-user.target
EOF
  fi

  systemctl daemon-reload
  systemctl enable snapserver
  systemctl restart snapserver

  echo "✅ Snapserver instalado y en ejecución."
}


ensure_prereqs(){
  confirm_actions
  install_prereqs
  mkdir -p "$SNAP_FIFO_DIR" "$BACKUP_DIR"
  chown -R "$SNAP_USER:$SNAP_GROUP" "$SNAP_FIFO_DIR"
  [ -f "$CONF_FILE" ] || echo "[stream]" > "$CONF_FILE"
  cp -a "$CONF_FILE" "${BACKUP_DIR}/snapserver.conf.$(ts).bak" || true
}

# ────────────────────────────────────────────────────────────────────────────
# Lectura y helpers
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
  echo "📜 Streams en snapserver.conf:"
  mapfile -t sources < <(get_stream_lines)
  if [ "${#sources[@]}" -eq 0 ]; then
    echo "❌ No hay fuentes definidas."
    return 1
  fi
  local i=1
  for line in "${sources[@]}"; do
    local entry="${line#*:}"
    local name="$(sed -E 's/.*[?&]name=([^&]+).*/\1/' <<<"$entry")"
    local fifo="$(sed -E 's|.*fifo/([^?]+)\?.*|\1|' <<<"$entry")"
    echo "  $i) ${name} (${fifo})"
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
Description=FFmpeg Stream Bridge (${service_name})
After=network-online.target snapserver.service
Requires=snapserver.service
PartOf=snapserver.service

[Service]
Type=simple
ExecStartPre=/bin/bash -c 'test -p "${fifo}" || (mkfifo "${fifo}" && chown ${SNAP_USER}:${SNAP_GROUP} "${fifo}" && chmod 666 "${fifo}")'
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

# ────────────────────────────────────────────────────────────────────────────
# Configuración segura de snapserver.conf
# ────────────────────────────────────────────────────────────────────────────
add_or_replace_stream_line(){
  local fifo="$1" name="$2" sample="48000:16:2" tmpfile
  tmpfile="$(mktemp)"

  grep -q "^\[stream\]" "$CONF_FILE" || echo "[stream]" >> "$CONF_FILE"
  sed "/$(escape_sed "$fifo")/d" "$CONF_FILE" > "$tmpfile" && mv "$tmpfile" "$CONF_FILE"

  local newline="source = pipe:///${fifo}?name=${name}&codec=pcm&sampleformat=${sample}&sendIdle=1&timeout=0"
  awk -v newline="$newline" '
    BEGIN{inserted=0}
    /^\[stream\]/{print; in_stream=1; next}
    /^\[/{if(in_stream&&!inserted){print newline;inserted=1} in_stream=0}
    {print}
    END{if(in_stream&&!inserted){print newline}}
  ' "$CONF_FILE" > "$tmpfile"
  mv "$tmpfile" "$CONF_FILE"
}

verify_stream_insertion(){
  local fifo="$1" service="$2"
  if grep -A10 "^\[stream\]" "$CONF_FILE" | grep -q "$fifo"; then
    echo "✅ Stream correctamente insertado en [stream]."
  else
    echo "⚠️ Stream no parece estar dentro de [stream]. Verifica $CONF_FILE"
  fi
  local status
  status="$(systemctl is-active "$service" 2>/dev/null || true)"
  if [[ "$status" == "active" ]]; then
    echo "✅ Servicio $service en ejecución."
  else
    echo "⚠️ Servicio $service con estado: $status"
    echo "📜 Últimos logs:"
    journalctl -u "$service" -n 10 --no-pager --output=short-monotonic 2>/dev/null || true
  fi
}

# ────────────────────────────────────────────────────────────────────────────
# Crear nuevo stream
# ────────────────────────────────────────────────────────────────────────────
create_stream(){
  echo ""
  echo "➕ Crear nuevo stream"
  echo "1) URL (HTTP/HTTPS/RTSP/RTMP)"
  echo "2) ALSA (micrófono/dispositivo hw:0,0)"
  echo "3) Archivo local (loop infinito)"
  echo "4) FFmpeg personalizado (avanzado)"
  read -rp "Elige tipo [1-4]: " kind

  read -rp "Nombre del stream: " STREAM_NAME
  [ -z "$STREAM_NAME" ] && { echo "❌ Debes indicar un nombre."; pause; return; }

  local STREAM_ID="$(mk_stream_id "$STREAM_NAME")"
  local FIFO_PATH="$(fifo_path_for "$STREAM_ID")"
  local SERVICE_NAME="$(service_name_for "$STREAM_ID")"
  local INPUT_ARGS=""

  case "$kind" in
    1) read -rp "URL: " URL
       [ -z "$URL" ] && { echo "❌ Sin URL."; pause; return; }
       local EXTRA="-reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5"
       [[ "$URL" == https* ]] && EXTRA="$EXTRA -tls_verify 0"
       INPUT_ARGS="$EXTRA -i \"$URL\"" ;;
    2) read -rp "Dispositivo ALSA (ej hw:0,0): " DEV
       INPUT_ARGS="-f alsa -thread_queue_size 4096 -i \"$DEV\"" ;;
    3) read -rp "Archivo local (mp3/wav): " FILE
       [ -f "$FILE" ] || { echo "❌ Archivo no encontrado."; pause; return; }
       INPUT_ARGS="-stream_loop -1 -re -i \"$FILE\"" ;;
    4) read -rp "Argumentos FFmpeg personalizados: " CUSTOM
       INPUT_ARGS="$CUSTOM" ;;
    *) echo "❌ Tipo inválido."; pause; return ;;
  esac

  ensure_prereqs
  ensure_fifo "$FIFO_PATH"
  local FFMPEG_LINE="$(ffmpeg_cmd_for "$INPUT_ARGS" "$FIFO_PATH")"
  write_unit "$SERVICE_NAME" "$FIFO_PATH" "$FFMPEG_LINE"

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl restart "$SERVICE_NAME"
  add_or_replace_stream_line "$FIFO_PATH" "$STREAM_NAME"
  verify_stream_insertion "$FIFO_PATH" "$SERVICE_NAME"
  systemctl restart snapserver
  echo "✅ Stream '${STREAM_NAME}' creado correctamente."
  pause
}

# ────────────────────────────────────────────────────────────────────────────
# Edición / gestión de streams
# ────────────────────────────────────────────────────────────────────────────
edit_stream(){
  echo ""
  show_streams_numbered || { pause; return; }
  read -rp "Número de stream: " num
  [ -z "$num" ] && { echo "❌ Sin selección."; pause; return; }
  mapfile -t sources < <(get_stream_lines)
  [ "$num" -ge 1 ] && [ "$num" -le "${#sources[@]}" ] || { echo "❌ Inválido."; pause; return; }
  local entry="${sources[$((num-1))]#*:}"
  local fifo_name="$(sed -E 's|.*fifo/([^?]+)\?.*|\1|' <<<"$entry")"
  local STREAM_ID="${fifo_name#snapfifo_}"
  local SERVICE_NAME="$(service_name_for "$STREAM_ID")"
  local FILE="${SYSTEMD_DIR}/${SERVICE_NAME}"
  while true; do
    echo ""
    echo "🧩 Gestión de '${STREAM_ID}'"
    echo "1) Editar servicio (.service)"
    echo "2) Editar snapserver.conf"
    echo "3) Reiniciar servicio"
    echo "4) Detener servicio"
    echo "5) Iniciar servicio"
    echo "6) Ver logs recientes"
    echo "7) Regresar"
    read -rp "Opción [1-7]: " act
    case "$act" in
      1) [ -f "$FILE" ] && ${EDITOR:-nano} "$FILE"; systemctl daemon-reload ;;
      2) ${EDITOR:-nano} "$CONF_FILE"; systemctl restart snapserver ;;
      3) systemctl restart "$SERVICE_NAME"; systemctl status "$SERVICE_NAME" --no-pager -l | grep Active ;;
      4) systemctl stop "$SERVICE_NAME"; systemctl status "$SERVICE_NAME" --no-pager -l | grep Active ;;
      5) systemctl start "$SERVICE_NAME"; systemctl status "$SERVICE_NAME" --no-pager -l | grep Active ;;
      6) journalctl -u "$SERVICE_NAME" -n 20 --no-pager --output=short-monotonic ;;
      7) return ;;
      *) echo "❌ Inválido." ;;
    esac
  done
}

# ────────────────────────────────────────────────────────────────────────────
# Limpieza segura de huérfanos / fallidos
# ────────────────────────────────────────────────────────────────────────────
cleanup_orphaned(){
  echo ""
  echo "🧹 Escaneando posibles huérfanos..."
  local orphans=()

  while IFS= read -r svc; do
    local id="${svc#ffmpeg-}"; id="${id%.service}"
    local fifo="${SNAP_FIFO_DIR}/snapfifo_${id}"
    local state
    state="$(systemctl is-active "$svc" 2>/dev/null || echo unknown)"
    if { [ ! -p "$fifo" ] || ! grep -Eq "pipe://.*/snapfifo_${id}(\?|&|$)" "$CONF_FILE"; } && [[ "$state" != "active" ]]; then
      orphans+=("$svc")
    fi
  done < <(systemctl list-unit-files | awk '/^ffmpeg-.*\.service/ {print $1}')

  if [ "${#orphans[@]}" -eq 0 ]; then
    echo "✅ No se detectaron servicios huérfanos ni fallidos."
    pause; return
  fi

  echo ""
  echo "⚠️ Servicios sospechosos (${#orphans[@]}):"
  printf '  - %s\n' "${orphans[@]}"
  echo ""
  read -rp "¿Eliminar estos servicios? (y = uno por uno, a = todos, n = cancelar): " choice

  local total=0
  case "$choice" in
    [Aa])
      for svc in "${orphans[@]}"; do
        echo "🧯 Eliminando ${svc}..."
        local id="${svc#ffmpeg-}"; id="${id%.service}"
        local fifo="${SNAP_FIFO_DIR}/snapfifo_${id}"
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
        rm -f "${SYSTEMD_DIR}/${svc}" "$fifo" 2>/dev/null || true
        ((total++))
      done ;;
    [Yy])
      for svc in "${orphans[@]}"; do
        read -rp "Eliminar ${svc}? [y/N]: " ans
        [[ "$ans" =~ ^[Yy]$ ]] || continue
        echo "🧯 Eliminando ${svc}..."
        local id="${svc#ffmpeg-}"; id="${id%.service}"
        local fifo="${SNAP_FIFO_DIR}/snapfifo_${id}"
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
        rm -f "${SYSTEMD_DIR}/${svc}" "$fifo" 2>/dev/null || true
        ((total++))
      done ;;
    *) echo "❌ Cancelado."; pause; return ;;
  esac

  systemctl daemon-reload
  systemctl restart snapserver || true
  echo "✅ Limpieza completada. Se eliminaron ${total} servicios."
  pause
}

# ────────────────────────────────────────────────────────────────────────────
# Eliminación manual y estado
# ────────────────────────────────────────────────────────────────────────────
delete_streams(){
  echo ""
  show_streams_numbered || { pause; return; }
  read -rp "Selecciona números (coma): " sel
  [ -z "$sel" ] && { echo "❌ Sin selección."; pause; return; }
  IFS=',' read -ra CHOSEN <<< "$sel"
  mapfile -t sources < <(get_stream_lines)
  for idx in "${CHOSEN[@]}"; do
    idx="$(tr -d ' ' <<<"$idx")"
    [[ "$idx" =~ ^[0-9]+$ ]] || continue
    [ "$idx" -ge 1 ] && [ "$idx" -le "${#sources[@]}" ] || continue
    local entry="${sources[$((idx-1))]#*:}"
    local fifo="$(sed -E 's|.*fifo/([^?]+)\?.*|\1|' <<<"$entry")"
    local STREAM_ID="${fifo#snapfifo_}"
    local SVC="$(service_name_for "$STREAM_ID")"
    echo "🧹 Eliminando $STREAM_ID..."
    systemctl stop "$SVC" 2>/dev/null || true
    systemctl disable "$SVC" 2>/dev/null || true
    rm -f "${SYSTEMD_DIR}/${SVC}" "${SNAP_FIFO_DIR}/${fifo}" 2>/dev/null || true
    sed -i "/${fifo}/d" "$CONF_FILE"
  done
  systemctl daemon-reload
  systemctl restart snapserver
  echo "✅ Eliminación completada."
  pause
}

check_activity(){
  echo ""
  echo "🎧 Estado actual:"
  mapfile -t sources < <(get_stream_lines)
  [ "${#sources[@]}" -eq 0 ] && { echo "No hay streams."; pause; return; }
  for line in "${sources[@]}"; do
    local entry="${line#*:}"
    local name="$(sed -E 's/.*[?&]name=([^&]+).*/\1/' <<<"$entry")"
    local fifo="$(sed -E 's|.*fifo/([^?]+)\?.*|\1|' <<<"$entry")"
    local id="${fifo#snapfifo_}"
    local svc="$(service_name_for "$id")"
    local st="$(systemctl is-active "$svc" 2>/dev/null || echo unknown)"
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
  while true; do
    clear
    echo "═══════════════════════════════════════════════════"
    echo "           🧩 SNAPSTREAM MANAGER v2025.10.28"
    echo "═══════════════════════════════════════════════════"
    echo "1) Agregar nuevo stream"
    echo "2) Listar streams actuales"
    echo "3) Editar o gestionar un stream"
    echo "4) Eliminar streams"
    echo "5) Ver estado"
    echo "6) 🧹 Limpiar huérfanos o fallidos"
    echo "7) Salir"
    echo "═══════════════════════════════════════════════════"
    read -rp "Elige una opción [1-7]: " opt
    case "$opt" in
      1) create_stream ;;
      2) get_stream_lines | nl -ba; pause ;;
      3) edit_stream ;;
      4) delete_streams ;;
      5) check_activity ;;
      6) cleanup_orphaned ;;
      7) echo "👋 Saliendo..."; exit 0 ;;
      *) echo "❌ Opción inválida."; pause ;;
    esac
  done
}

main_menu
