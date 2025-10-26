#!/bin/bash
# ==============================================================================
# SNAPSTREAM MANAGER v2025.10.40
# Snapserver + FFmpeg Streams + Snapweb + JSON-RPC clients + Backups + LXC-aware
# Instalación desde .deb oficial (GitHub), fix datadir/configdir, watchdog y utilidades.
# Autor: Josue / GPT-5 — “No bullshit” build.
# ==============================================================================

set -Eeuo pipefail

SNAP_FIFO_DIR="/var/lib/snapserver/fifo"
SYSTEMD_DIR="/etc/systemd/system"
CONF_FILE="/etc/snapserver.conf"
BACKUP_DIR="/etc/snapserver.d/backups"
CACHE_DIR="/var/cache/snapstream"
SNAP_USER="snapserver"
SNAP_GROUP="snapserver"
DEFAULT_GROUP="Default"         # <- Elegiste “Default”
SNAP_RPC="http://127.0.0.1:1780/jsonrpc"

mkdir -p "$BACKUP_DIR" "$CACHE_DIR"

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
# LXC: explicación opcional (no fuerza /dev/snd)
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
  echo "Snapserver puede correr en dos modos:"
  echo " 1) 🟢 Solo orquestación (típico) → NO requiere /dev/snd"
  echo " 2) 🎤 Captura local (ALSA en el CT) → requiere /dev/snd"
  echo "─────────────────────────────────────────────"
  read -rp "¿Vas a capturar audio desde hardware local en este contenedor? (y/N): " use_hw
  echo ""
  if [[ "$use_hw" =~ ^[Yy]$ ]]; then
    echo "⚙️ Habilita /dev/snd en el host Proxmox (reemplaza <ID>):"
    echo "  pct stop <ID>"
    echo "  echo \"lxc.cgroup2.devices.allow = c 116:* rwm\" >> /etc/pve/lxc/<ID>.conf"
    echo "  echo \"lxc.mount.entry = /dev/snd dev/snd none bind,optional,create=dir\" >> /etc/pve/lxc/<ID>.conf"
    echo "  pct start <ID>"
    echo "Si el CT es no privilegiado: pct set <ID> -features nesting=1,mount=1"
    echo "Después dentro del contenedor: systemctl restart snapserver"
  else
    echo "🟢 Queda en modo servidor puro. Sin /dev/snd."
  fi
  echo ""
  pause
}

# ────────────────────────────────────────────────────────────────────────────
# Pre-check de instalación
# ────────────────────────────────────────────────────────────────────────────
needs_install(){
  if ! command -v ffmpeg >/dev/null 2>&1; then return 0; fi
  if ! command -v snapserver >/dev/null 2>&1; then return 0; fi
  if ! id -u "$SNAP_USER" >/dev/null 2>&1; then return 0; fi
  return 1
}

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
  local RELEASE_API="https://api.github.com/repos/badaix/snapcast/releases/latest"
  SNAPVER="$(curl -s --max-time 10 "$RELEASE_API" | jq -r '.tag_name // empty' || true)"
  [ -n "$SNAPVER" ] && echo "  • Última versión Snapcast en GitHub: $SNAPVER"
  echo ""
  echo "Acciones:"
  if ! command -v ffmpeg >/dev/null 2>&1; then echo "  - 📦 Instalar FFmpeg"; else echo "  - ✅ FFmpeg ya instalado"; fi
  if ! command -v snapserver >/dev/null 2>&1; then echo "  - ⬇️ Instalar Snapserver (.deb oficial desde GitHub)"; else echo "  - ✅ Snapserver ya instalado"; fi
  if ! id -u "$SNAP_USER" >/dev/null 2>&1; then echo "  - 👤 Crear usuario '${SNAP_USER}'"; else echo "  - ✅ Usuario '${SNAP_USER}' ya existe"; fi
  echo ""
  echo "════════════════════════════════════════════════════"
  read -rp "¿Deseas continuar? (y/N): " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "❌ Cancelado por el usuario."; exit 0; }
  echo ""
}

# ────────────────────────────────────────────────────────────────────────────
# FIX: datadir + configdir + http-port
# ────────────────────────────────────────────────────────────────────────────
fix_snapserver_unit(){
  local SERVICE_FILE="/usr/lib/systemd/system/snapserver.service"
  [ -f "$SERVICE_FILE" ] || return 0

  echo "🩹 Ajustando unidad de Snapserver (datadir/configdir/http)…"

  # 1) datadir: reemplaza ${HOME} si existe
  sed -i 's|--server.datadir=${HOME}|--server.datadir=/var/lib/snapserver|g' "$SERVICE_FILE"

  # 2) anexar configdir y http-port si no están presentes
  if ! grep -q -- '--server.configdir=' "$SERVICE_FILE"; then
    sed -i 's|ExecStart=.*|& --server.configdir=/var/lib/snapserver/config|' "$SERVICE_FILE"
  fi
  if ! grep -q -- '--http-port' "$SERVICE_FILE"; then
    sed -i 's|ExecStart=.*|& --http-port 1780|' "$SERVICE_FILE"
  fi

  # 3) asegurar docroot si existe snapweb (opcional)
  if [ -d "/usr/share/snapserver/snapweb" ] && ! grep -q -- '--http-doc-root' "$SERVICE_FILE"; then
    sed -i 's|ExecStart=.*|& --http-doc-root=/usr/share/snapserver/snapweb|' "$SERVICE_FILE"
  fi

  mkdir -p /var/lib/snapserver/config "$SNAP_FIFO_DIR"
  chown -R "$SNAP_USER:$SNAP_GROUP" /var/lib/snapserver

  systemctl daemon-reload
  systemctl restart snapserver || true

  echo "✅ Unidad ajustada. datadir=/var/lib/snapserver, configdir=/var/lib/snapserver/config, http-port=1780"
}

# Watchdog/monitor: rescata cuando falla por bug del HOME u otros
monitor_snapserver(){
  echo ""
  echo "🔎 Verificando estado de Snapserver..."
  if ! systemctl list-unit-files | grep -q snapserver.service; then
    echo "❌ snapserver.service no está instalado."
    echo ""
    pause
    return
  fi

  local status
  status="$(systemctl is-active snapserver 2>/dev/null || echo unknown)"

  case "$status" in
    active)
      echo "🟢 Snapserver activo."
      ;;
    activating|reloading|starting)
      echo "🔄 Snapserver iniciando..."
      ;;
    failed|inactive)
      echo "🚨 Snapserver detenido/fallando. Intentando recuperación…"
      # Si la unidad tiene ${HOME}, o los logs muestran /home/snapserver, aplicamos fix completo:
      if grep -q '\--server\.datadir=\${HOME}' /usr/lib/systemd/system/snapserver.service 2>/dev/null \
         || journalctl -u snapserver -n 50 --no-pager 2>/dev/null | grep -q "/home/snapserver"; then
        fix_snapserver_unit
        echo "🔁 Reintentando inicio…"
        systemctl restart snapserver || true
        sleep 1
      fi

      if systemctl is-active snapserver &>/dev/null; then
        echo "✅ Recuperado automáticamente."
      else
        echo "❌ Sigue fallando. Revisa logs:"
        echo "   journalctl -u snapserver -n 80 --no-pager"
      fi
      ;;
    *)
      echo "❓ Estado desconocido: $status"
      ;;
  esac
  echo ""
  pause
}

# ────────────────────────────────────────────────────────────────────────────
# Instalación segura desde release
# ────────────────────────────────────────────────────────────────────────────
install_prereqs(){
  echo "🔍 Verificando/instalando prerequisitos…"
  apt-get update -y
  apt-get install -y ffmpeg curl jq

  id -u "$SNAP_USER" >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin "$SNAP_USER"
  [ -f "$CACHE_DIR/snapserver_current.deb" ] && cp -f "$CACHE_DIR/snapserver_current.deb" "$BACKUP_DIR/snapserver_prev.deb" || true
  [ -f "$CONF_FILE" ] && cp -f "$CONF_FILE" "$BACKUP_DIR/snapserver.conf.prev" || true

  local ARCH CODENAME RELEASE_API SNAPVER PACKAGE_URL FILENAME
  ARCH="$(dpkg --print-architecture)"
  CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-unknown}")"
  RELEASE_API="https://api.github.com/repos/badaix/snapcast/releases/latest"

  echo "⬇️ Buscando última release…"
  SNAPVER="$(curl -s "$RELEASE_API" | jq -r '.tag_name')"
  [ -z "$SNAPVER" ] && { echo "❌ No se pudo obtener versión."; exit 1; }
  echo "📌 Versión: $SNAPVER"

  PACKAGE_URL="$(curl -s "$RELEASE_API" | jq -r '
    .assets[] | select(.name | test("_with-pipewire") | not)
    | select(.name | test("snapserver_.*_'"$ARCH"'_'"$CODENAME"'\\.deb$"))
    | .browser_download_url
  ' | head -n1)"

  if [ -z "$PACKAGE_URL" ] || [ "$PACKAGE_URL" = "null" ]; then
    echo "⚠️ Buscando fallback a bookworm…"
    PACKAGE_URL="$(curl -s "$RELEASE_API" | jq -r '
      .assets[] | select(.name | test("_with-pipewire") | not)
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

  mkdir -p "$SNAP_FIFO_DIR" /var/lib/snapserver/config
  chown -R "$SNAP_USER:$SNAP_GROUP" /var/lib/snapserver
  [ -f "$CONF_FILE" ] || echo "[stream]" > "$CONF_FILE"

  systemctl daemon-reload
  systemctl enable snapserver
  systemctl restart snapserver || true
  echo "✅ Snapserver instalado (o actualizado)."

  # Aplicar fix robusto de unidad, puertos y dirs persistentes
  fix_snapserver_unit
}

ensure_prereqs(){
  if needs_install; then
    confirm_actions
    install_prereqs
  else
    echo "✅ Dependencias ya satisfechas. Saltando instalación."
    sleep 1
  fi
}

# ────────────────────────────────────────────────────────────────────────────
# JSON-RPC helpers (Snapweb/1780)
# ────────────────────────────────────────────────────────────────────────────
rpc(){ curl -s -H 'Content-Type: application/json' -X POST "$SNAP_RPC" -d "$1"; }
rpc_status(){ rpc '{"id":1,"jsonrpc":"2.0","method":"Server.GetStatus"}'; }

list_clients(){
  echo ""
  echo "👥 Clientes conectados:"
  local js
  js="$(rpc_status || true)"
  if [ -z "$js" ] || ! jq -e . >/dev/null 2>&1 <<<"$js"; then
    echo "❌ No se pudo consultar JSON-RPC. ¿Está Snapweb en :1780?"
    echo ""
    pause; return
  fi
  echo "$js" | jq -r '
    .result.server.clients[]
    | [.id, (.name // "unnamed"), (.host.name // .host.address // "unknown"), .group]
    | @tsv
  ' 2>/dev/null | awk -F'\t' 'BEGIN{printf "%-8s | %-24s | %-24s | %-12s\n","ID","Nombre","Host","Grupo"; print gensub(/./,"-","g",72)}{printf "%-8s | %-24s | %-24s | %-12s\n",$1,$2,$3,$4}'
  echo ""
  pause
}

auto_name_clients_from_hostname(){
  echo ""
  echo "✏️ Auto-nombrando clientes usando hostname..."
  local js ids
  js="$(rpc_status || true)"
  [ -z "$js" ] && { echo "❌ JSON-RPC no disponible."; pause; return; }
  ids=($(echo "$js" | jq -r '.result.server.clients[].id'))
  for id in "${ids[@]}"; do
    local host name
    host="$(echo "$js" | jq -r ".result.server.clients[] | select(.id==\"$id\") | (.host.name // .host.address // \"client\")")"
    name="${host%%.*}"
    [ -z "$name" ] && name="client-$id"
    rpc "$(jq -n --arg id "$id" --arg name "$name" '{id:2,"jsonrpc":"2.0","method":"Server.SetClientName","params":{"id":$id,"name":$name}}')" >/dev/null
    echo "  • $id → $name"
  done
  echo "✅ Nombres actualizados."
  echo ""
  pause
}

group_all_clients_default(){
  echo ""
  echo "🧩 Agrupando todos los clientes en \"$DEFAULT_GROUP\"…"
  local js ids
  js="$(rpc_status || true)"
  [ -z "$js" ] && { echo "❌ JSON-RPC no disponible."; pause; return; }
  ids=($(echo "$js" | jq -r '.result.server.clients[].id'))
  for id in "${ids[@]}"; do
    rpc "$(jq -n --arg id "$id" --arg grp "$DEFAULT_GROUP" '{id:3,"jsonrpc":"2.0","method":"Server.SetClientGroup","params":{"id":$id,"group":$grp}}')" >/dev/null
    echo "  • $id → $DEFAULT_GROUP"
  done
  echo "✅ Agrupación aplicada."
  echo ""
  pause
}

clients_menu(){
  while true; do
    clear
    echo "──────────────── CLIENTES (JSON-RPC) ────────────────"
    echo "1) Listar clientes"
    echo "2) Auto-nombrar por hostname"
    echo "3) Agrupar todos → \"$DEFAULT_GROUP\""
    echo "4) Volver"
    read -rp "Elige [1-4]: " c
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
# Streams (sin ALSA en server)
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
       [ -z "$URL" ] && { echo "❌ Sin URL."; pause; return; }
       INPUT_ARGS="-reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 -i \"$URL\"" ;;
    2) read -rp "Archivo local (mp3/wav/flac): " FILE
       [ -f "$FILE" ] || { echo "❌ Archivo no encontrado."; pause; return; }
       INPUT_ARGS="-stream_loop -1 -re -i \"$FILE\"" ;;
    3) read -rp "Args FFmpeg: " CUSTOM
       [ -z "$CUSTOM" ] && { echo "❌ Debes indicar args FFmpeg."; pause; return; }
       INPUT_ARGS="$CUSTOM" ;;
    *) echo "❌ Selección inválida."; pause; return ;;
  esac

  ensure_fifo "$FIFO_PATH"
  local FFMPEG_LINE="$(ffmpeg_cmd_for "$INPUT_ARGS" "$FIFO_PATH")"
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
  [ "${#sources[@]}" -eq 0 ] && { echo "No hay streams."; pause; return; }
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
# Backups (config + datadir + servicios ffmpeg)
# ────────────────────────────────────────────────────────────────────────────
do_backup(){
  local OUT="/var/backups/snapserver_backup_$(ts).tar.gz"
  echo "🧯 Creando backup en $OUT ..."
  mkdir -p /var/backups
  tar -czf "$OUT" \
    /var/lib/snapserver \
    "$CONF_FILE" \
    $SYSTEMD_DIR/ffmpeg-*.service 2>/dev/null || true
  echo "✅ Backup listo: $OUT"
  pause
}

do_restore(){
  echo "🧰 Restaurar backup"
  ls -1 /var/backups/snapserver_backup_*.tar.gz 2>/dev/null || { echo "❌ No hay backups en /var/backups/"; pause; return; }
  read -rp "Ruta del backup a restaurar: " BK
  [ -f "$BK" ] || { echo "❌ No existe $BK"; pause; return; }
  echo "⚠️ Esto sobrescribirá configuración/servicios. Confirmar? (y/N): "
  read -r ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "❌ Cancelado"; pause; return; }
  systemctl stop snapserver || true
  tar -xzf "$BK" -C /
  chown -R "$SNAP_USER:$SNAP_GROUP" /var/lib/snapserver
  systemctl daemon-reload
  systemctl restart snapserver || true
  echo "✅ Restaurado."
  pause
}

backup_menu(){
  while true; do
    clear
    echo "──────────────── BACKUPS ─────────────────"
    echo "1) Crear backup"
    echo "2) Restaurar backup"
    echo "3) Volver"
    read -rp "Elige [1-3]: " b
    case "$b" in
      1) do_backup ;;
      2) do_restore ;;
      3) return ;;
      *) ;;
    esac
  done
}

# ────────────────────────────────────────────────────────────────────────────
# Menú principal
# ────────────────────────────────────────────────────────────────────────────
main_menu(){
  ensure_prereqs
  detect_lxc
  [[ "$LXC_MODE" -eq 1 ]] && lxc_instructions
  monitor_snapserver   # verificación + autorreparación

  while true; do
    clear
    echo "═══════════════════════════════════════════════════"
    echo "           🧩 SNAPSTREAM MANAGER"
    echo "═══════════════════════════════════════════════════"
    echo "1) Agregar nuevo stream"
    echo "2) Listar streams"
    echo "3) Editar un stream"
    echo "4) Eliminar stream(s)"
    echo "5) Ver estado de servicios FFmpeg"
    echo "6) Clientes (listar, auto-nombrar, agrupar)"
    echo "7) Backups (crear/restaurar)"
    echo "8) Salir"
    echo "═══════════════════════════════════════════════════"
    read -rp "Elige [1-8]: " opt
    case "$opt" in
      1) create_stream ;;
      2) get_stream_lines | nl -ba; pause ;;
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
