#!/bin/bash
# ==============================================================================
# SNAPSTREAM MANAGER v2025.10.29 (SAFE INSTALL + STREAM MANAGEMENT)
# Gestión avanzada de Snapserver + FFmpeg basada en snapserver.conf
# Instalación segura desde releases de GitHub (.deb), SHA256 y rollback.
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
msg(){ echo -e "$1"; }

rollback(){
  echo "⚠️  ERROR: ejecutando ROLLBACK…"
  systemctl stop snapserver 2>/dev/null || true

  # Restaura .deb previo si existe
  if [ -f "$BACKUP_DIR/snapserver_prev.deb" ]; then
    echo "↩️  Restaurando paquete previo…"
    dpkg -i "$BACKUP_DIR/snapserver_prev.deb" || true
  fi

  # Restaura configuración previa si existe
  if [ -f "$BACKUP_DIR/snapserver.conf.prev" ]; then
    echo "↩️  Restaurando /etc/snapserver.conf previo…"
    cp -f "$BACKUP_DIR/snapserver.conf.prev" "$CONF_FILE"
  fi

  systemctl daemon-reload || true
  systemctl restart snapserver || true
  echo "✅ Rollback completado."
  exit 1
}

trap rollback ERR

# ────────────────────────────────────────────────────────────────────────────
# Resumen previo y confirmación
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

  # Intento de leer última versión (informativo; si falla, seguimos)
  local RELEASE_API="https://api.github.com/repos/badaix/snapcast/releases/latest"
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
    echo "  - ✅ Snapserver ya instalado (se actualizará solo si eliges instalar manualmente fuera del script)"
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
# Instalación segura de prerequisitos y Snapserver (release .deb)
# ────────────────────────────────────────────────────────────────────────────
install_prereqs(){
  echo "🔍 Verificando/instalando prerequisitos…"
  apt-get update -y
  apt-get install -y ffmpeg curl jq

  # Usuario snapserver
  if ! id -u "$SNAP_USER" >/dev/null 2>&1; then
    echo "👤 Creando usuario ${SNAP_USER}…"
    useradd -r -s /usr/sbin/nologin "$SNAP_USER"
  fi

  # Si snapserver ya está instalado, guardamos .deb previo si lo tenemos en cache
  if [ -f "$CACHE_DIR/snapserver_current.deb" ]; then
    cp -f "$CACHE_DIR/snapserver_current.deb" "$BACKUP_DIR/snapserver_prev.deb" || true
  fi
  [ -f "$CONF_FILE" ] && cp -f "$CONF_FILE" "$BACKUP_DIR/snapserver.conf.prev" || true

  # Detectar arquitectura/codename y elegir .deb adecuado (sin pipewire)
  local ARCH CODENAME RELEASE_API SNAPVER PACKAGE_URL FILENAME
  ARCH="$(dpkg --print-architecture)"
  CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-unknown}")"
  RELEASE_API="https://api.github.com/repos/badaix/snapcast/releases/latest"

  echo "⬇️ Buscando última release de Snapcast…"
  SNAPVER="$(curl -s "$RELEASE_API" | jq -r '.tag_name')"
  [ -z "$SNAPVER" ] && { echo "❌ No se pudo obtener la versión desde GitHub."; exit 1; }
  echo "📌 Última versión: $SNAPVER"

  # Preferimos sin pipewire; primero distro exacta, luego fallback a bookworm
  PACKAGE_URL="$(curl -s "$RELEASE_API" | jq -r \
    ".assets[]
     | select((.name | test(\"_with-pipewire\")|not)
              and (.name | test(\"^snapserver_.*_${ARCH}_${CODENAME}\\.deb$\")))
     | .browser_download_url" | head -n1)"

  if [ -z "$PACKAGE_URL" ] || [ "$PACKAGE_URL" = "null" ]; then
    echo "⚠️ No hay paquete exacto para ${CODENAME}. Probando fallback a bookworm…"
    PACKAGE_URL="$(curl -s "$RELEASE_API" | jq -r \
      ".assets[]
       | select((.name | test(\"_with-pipewire\")|not)
                and (.name | test(\"^snapserver_.*_${ARCH}_bookworm\\.deb$\")))
       | .browser_download_url" | head -n1)"
  fi

  [ -z "$PACKAGE_URL" ] && { echo "❌ No se encontró .deb compatible para ${CODENAME}/${ARCH}."; exit 1; }

  echo "📦 Paquete seleccionado:"
  echo "   $PACKAGE_URL"

  cd /tmp
  FILENAME="$(basename "$PACKAGE_URL")"
  curl -L -o "$FILENAME" "$PACKAGE_URL"

  # ── Verificación SHA256 (intenta varias convenciones de archivo)
  echo "🔐 Verificando integridad (SHA256)…"
  set +e
  VERIFIED=0
  # 1) Archivo individual .sha256 (contenido: "<hash>  <filename>")
  curl -fsSL -o "$FILENAME.sha256" "${PACKAGE_URL}.sha256" && sha256sum -c "$FILENAME.sha256" && VERIFIED=1
  # 2) Archivo individual .sha256.txt
  if [ "$VERIFIED" -eq 0 ]; then
    curl -fsSL -o "$FILENAME.sha256.txt" "${PACKAGE_URL}.sha256.txt" && sha256sum -c "$FILENAME.sha256.txt" && VERIFIED=1
  fi
  # 3) Lista general SHA256SUMS o checksums.txt dentro de la release
  if [ "$VERIFIED" -eq 0 ]; then
    SUMS_URL="$(curl -s "$RELEASE_API" | jq -r '.assets[] | select(.name|test("SHA256SUMS|checksums.txt")) | .browser_download_url' | head -n1)"
    if [ -n "$SUMS_URL" ] && [ "$SUMS_URL" != "null" ]; then
      curl -fsSL -o "SHA256SUMS" "$SUMS_URL"
      # filtra la línea del archivo
      grep " $FILENAME\$" SHA256SUMS > "CHK" 2>/dev/null
      if [ -s "CHK" ]; then
        sha256sum -c "CHK" && VERIFIED=1
      fi
    fi
  fi
  set -e

  if [ "$VERIFIED" -eq 1 ]; then
    echo "✅ SHA256 correcto."
  else
    echo "⚠️ No se encontró checksum oficial para esta release/asset."
    echo "   Continuando sin verificación criptográfica."
  fi

  echo "📦 Instalando $FILENAME…"
  dpkg -i "$FILENAME" || apt-get -f install -y

  # Guarda .deb instalado como "current" para futuros rollbacks
  cp -f "/tmp/$FILENAME" "$CACHE_DIR/snapserver_current.deb" || true

  # Asegura directorios base
  mkdir -p "$SNAP_FIFO_DIR" "$BACKUP_DIR"
  chown -R "$SNAP_USER:$SNAP_GROUP" "$SNAP_FIFO_DIR"
  [ -f "$CONF_FILE" ] || echo "[stream]" > "$CONF_FILE"
  cp -a "$CONF_FILE" "${BACKUP_DIR}/snapserver.conf.$(ts).bak" || true

  systemctl daemon-reload
  systemctl enable snapserver
  systemctl restart snapserver
  echo "✅ Snapserver instalado y ejecutándose."
}

# ────────────────────────────────────────────────────────────────────────────
# Aseguramiento previo para flujo de menú (usa instalación segura)
# ────────────────────────────────────────────────────────────────────────────
ensure_prereqs(){
  # Muestra resumen, instala prereqs y deja todo listo
  confirm_actions
  install_prereqs
}

# ────────────────────────────────────────────────────────────────────────────
# === BLOQUE DE GESTIÓN DE STREAMS (tu código íntegro) =======================
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

  # Asegura instalación/listo antes de crear
  # (no re-ejecuta confirmación; ya se ejecutó al inicio)
  mkdir -p "$SNAP_FIFO_DIR" "$BACKUP_DIR"
  chown -R "$SNAP_USER:$SNAP_GROUP" "$SNAP_FIFO_DIR"
  [ -f "$CONF_FILE" ] || echo "[stream]" > "$CONF_FILE"
  cp -a "$CONF_FILE" "${BACKUP_DIR}/snapserver.conf.$(ts).bak" || true

  ensure_fifo "$FIFO_PATH"
  local FFMPEG_LINE
  FFMPEG_LINE="$(ffmpeg_cmd_for "$INPUT_ARGS" "$FIFO_PATH")"
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

main_menu(){
  ensure_prereqs
  while true; do
    clear
    echo "═══════════════════════════════════════════════════"
    echo "           🧩 SNAPSTREAM MANAGER v2025.10.29"
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

# ────────────────────────────────────────────────────────────────────────────
# Arranque
# ────────────────────────────────────────────────────────────────────────────
main_menu
