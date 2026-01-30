#!/bin/bash

# Snapserver Manager Script
# A simple, clean manager for Snapserver installations
# Supports: Proxmox LXC, TCP Sources, TCP Watchdog, Log Viewing, Service Management

VERSION="1.5.23"

# Fix for "Invalid option" loop when running via curl | bash
# If running via pipe (stdin is not a TTY), download and run explicitly to allow interactive input
if [ ! -t 0 ]; then
    echo "⚠️  Script detected piped execution (curl | bash)."
    echo "📥 Downloading script to /tmp/snapserver-manager.sh to allow interactive input..."
    
    # URL to this script
    SCRIPT_URL="https://raw.githubusercontent.com/NaturalDevCR/snapcast-tools/main/snapserver-manager.sh"
    
    if curl -s -L "$SCRIPT_URL" -o /tmp/snapserver-manager.sh; then
        chmod +x /tmp/snapserver-manager.sh
        echo "🚀 Re-launching script..."
        exec /bin/bash /tmp/snapserver-manager.sh "$@" < /dev/tty
    else
        echo "❌ Failed to download script. Please run manually."
        exit 1
    fi
fi

# Ensure we have a TTY for input (redundant if relaunched, but good for direct ./ execution without tty)
exec < /dev/tty

# --- Colors & Styling ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# --- Global Variables ---
CONFIG_FILE=${CONFIG_FILE:-"/etc/snapserver.conf"}
SERVICE_NAME="snapserver"
LOG_FILE="/var/log/snapserver-manager.log"

# --- Helper Functions ---

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root."
        exit 1
    fi
}

# Check for required dependencies
check_dependencies() {
    local dependencies=("curl" "wget" "jq" "systemctl" "grep" "sed" "lsof" "netstat" "awk" "ffmpeg" "shairport-sync")
    local missing=()

    for cmd in "${dependencies[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done


    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Missing dependencies: ${missing[*]}"
        
        # Prompt user for installation
        echo -e "${YELLOW}The following packages need to be installed:${NC}"
        for dep in "${missing[@]}"; do
            echo -e "  - $dep"
        done
        echo ""
        read -p "Do you want to proceed with the installation? (y/N): " choice
        
        if [[ ! "$choice" =~ ^[Yy]$ ]]; then
            log_error "Installation aborted by user."
            exit 1
        fi

        log_info "Installing missing dependencies..."
        
        # Map netstat to net-tools package
        local packages=()
        for dep in "${missing[@]}"; do
            if [[ "$dep" == "netstat" ]]; then
                packages+=("net-tools")
            else
                packages+=("$dep")
            fi
        done
        
        apt-get update && apt-get install -y "${packages[@]}"
        log_success "Dependencies installed."
    fi
}

# Detect Proxmox LXC
check_proxmox_lxc() {
    if [[ -f /proc/1/environ ]]; then
        if grep -q "container=lxc" /proc/1/environ; then
            echo -e "${CYAN}--------------------------------------------------${NC}"
            log_info "Proxmox LXC Container detected."
            echo -e "${CYAN}--------------------------------------------------${NC}"
            return 0
        fi
    fi
    return 1
}

detect_debian_codename() {
    # If lsb_release is available, use it
    if command -v lsb_release &> /dev/null; then
        lsb_release -cs
    else
        # Fallback to reading /etc/os-release
        if [[ -f /etc/os-release ]]; then
           grep VERSION_CODENAME= /etc/os-release | cut -d= -f2 2>/dev/null || echo "bookworm" # Default to bookworm if fail
        else
           echo "bookworm"
        fi
    fi
}

# --- Core Functions ---

install_snapserver() {
    log_info "Checking for latest Snapserver release..."
    
    # Get latest release tag with better error handling
    # Use -f to fail on server errors, -L to follow redirects
    # Added User-Agent to avoid some API blocks
    LATEST_RELEASE=$(curl -s -f -L -H "User-Agent: Snapserver-Manager" https://api.github.com/repos/badaix/snapcast/releases/latest | jq -r .tag_name 2>/dev/null)
    
    # Check if curl/jq failed or returned empty/null
    if [[ -z "$LATEST_RELEASE" || "$LATEST_RELEASE" == "null" ]]; then
        log_error "Failed to fetch latest version automatically."
        echo -e "${YELLOW}This could be due to network issues or GitHub API rate limits.${NC}"
        echo ""
        read -p "Would you like to enter the version manually? (y/N): " manual_choice
        
        if [[ "$manual_choice" =~ ^[Yy]$ ]]; then
            read -p "Enter version (e.g., 0.28.0): " MANUAL_VERSION
            # Strip 'v' if user typed it
            VERSION=${MANUAL_VERSION#v}
            LATEST_RELEASE="v$VERSION"
        else
            log_error "Installation aborted."
            read -p "Press Enter to continue..."
            return
        fi
    else
        VERSION=${LATEST_RELEASE#v} # Remove 'v' prefix
    fi
    
    log_info "Version to install: ${GREEN}$VERSION${NC}"
    
    # Detect Architecture
    ARCH=$(dpkg --print-architecture)
    CODENAME=$(detect_debian_codename)
    
    # Try distro-specific filename first (starting from v0.29+, badaix/snapcast uses _codename in filename)
    # e.g. snapserver_0.34.0-1_amd64_bookworm.deb
    DEB_SPECIFIC="snapserver_${VERSION}-1_${ARCH}_${CODENAME}.deb"
    URL_SPECIFIC="https://github.com/badaix/snapcast/releases/download/${LATEST_RELEASE}/${DEB_SPECIFIC}"
    
    # Legacy filename (older versions or generic)
    # e.g. snapserver_0.28.0-1_amd64.deb
    DEB_GENERIC="snapserver_${VERSION}-1_${ARCH}.deb"
    URL_GENERIC="https://github.com/badaix/snapcast/releases/download/${LATEST_RELEASE}/${DEB_GENERIC}"
    
    log_info "Detected architecture: ${YELLOW}$ARCH${NC}"
    log_info "Detected OS codename: ${YELLOW}$CODENAME${NC}"
    
    # Try downloading specific version first
    log_info "Attempting download: $DEB_SPECIFIC"
    if wget -q --show-progress "$URL_SPECIFIC"; then
        DEB_FILE="$DEB_SPECIFIC"
        log_success "Download complete ($DEB_SPECIFIC)."
    else
        log_warn "Specific package not found ($DEB_SPECIFIC)."
        log_info "Attempting fallback to generic/legacy: $DEB_GENERIC"
        
        if wget -q --show-progress "$URL_GENERIC"; then
            DEB_FILE="$DEB_GENERIC"
             log_success "Download complete ($DEB_GENERIC)."
        else
            log_error "Failed to download package."
            echo -e "${YELLOW}Urls attempted:${NC}"
            echo "1. $URL_SPECIFIC"
            echo "2. $URL_GENERIC"
            read -p "Press Enter to continue..."
            return
        fi
    fi

    log_info "Installing Snapserver from $DEB_FILE..."
    dpkg -i "$DEB_FILE"
    
    if [[ $? -ne 0 ]]; then
        log_warn "Dependency issues detected. Fixing..."
        apt-get -f install -y
    fi
    
    rm "$DEB_FILE"
    log_success "Snapserver installed successfully!"
    read -p "Press Enter to continue..." || exit 1
}

manage_service() {
    while true; do
        clear
        echo -e "${CYAN}--- Service Management ---${NC}"
        echo "1. Start Service"
        echo "2. Stop Service"
        echo "3. Restart Service"
        echo "4. Check Status"
        echo "5. Back to Main Menu"
        echo -e "${CYAN}--------------------------${NC}"
        read -p "Select an option: " choice || exit 1
        
        case $choice in
            1) systemctl start "$SERVICE_NAME" && log_success "Service started." ;;
            2) systemctl stop "$SERVICE_NAME" && log_success "Service stopped." ;;
            3) systemctl restart "$SERVICE_NAME" && log_success "Service restarted." ;;
            4) 
                systemctl status "$SERVICE_NAME"
                read -p "Press Enter to continue..." 
                ;;
            5) return ;;
            *) log_error "Invalid option." ;;
        esac
        sleep 1
    done
}

view_logs() {
    clear
    echo -e "${CYAN}--- Snapserver Logs (Press q to exit) ---${NC}"
    journalctl -u "$SERVICE_NAME" -n 50 -f
}

# --- TCP Watchdog Functions ---

# Extract TCP ports from snapserver configuration
get_tcp_ports() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        return 1
    fi
    
    # Extract TCP ports from source lines like: source = tcp://0.0.0.0:4953?name=...
    grep "source = tcp://" "$CONFIG_FILE" 2>/dev/null | \
        sed -n 's/.*tcp:\/\/[^:]*:\([0-9]*\).*/\1/p' | \
        sort -u
}

# Check for zombie TCP connections on a specific port
check_zombie_connections() {
    local port="$1"
    
    # Find ESTABLISHED connections that might be zombies
    # We look for connections in ESTABLISHED state that have been idle
    netstat -tn 2>/dev/null | \
        grep ":${port}.*ESTABLISHED" | \
        awk '{print $5}' | \
        cut -d: -f1
}

# Kill zombie TCP connections for a specific port (INGESTION MODE)
# NOTE: This closes only the specific TCP connection (FD), NOT the entire process
# INGESTION MODE: Laptop sends audio TO Snapserver (server receives, doesn't send)
# STRATEGY: If IP has MULTIPLE connections OR any bad connection, close ALL from that IP
kill_zombie_connections() {
    local port="$1"
    local killed_count=0
    
    log_info "Checking for zombie/orphaned connections on port $port (Ingestion Mode)..."
    
    # Get all connections on this port
    # We only care about ESTABLISHED connections
    local conn_data=$(ss -top state established "( sport = :${port} )" 2>/dev/null | awk 'NR>1 {print $0}')
    
    if [[ -z "$conn_data" ]]; then
        log_info "No connections found on port $port"
        return 0
    fi
    
    # Count total connections
    local total_conns=$(echo "$conn_data" | grep -c .)
    
    if [[ "$total_conns" -gt 1 ]]; then
        log_warn "Multiple connections detected on port $port (Count: $total_conns). Strict limit is 1."
        log_info "Closing ALL connections on port $port to force clean state..."
        
        # Kill all connections found
        while IFS= read -r line; do
             # Extract destination socket info for killing
             # SS output format varies, but usually 4th or 5th column depending on if Recv-Q/Send-Q are present
             # We rely on ss -K dst <peer_addr>
             
             # Extract Peer Address (Dst)
             local peer=$(echo "$line" | awk '{
                 if ($1 ~ /^[0-9]+$/) print $5; # Output with Recv-Q Send-Q columns
                 else print $5;                # Output without queues (unlikely with -t but possible)
             }')
             
             # Fallback if column matching is tricky: just parse for IP:Port pattern
             if [[ ! "$peer" =~ .*:.* ]]; then
                 peer=$(echo "$line" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+' | tail -n1)
             fi

             if [[ -n "$peer" ]]; then
                 log_warn "Force closing: $peer"
                 if ss -K dst "$peer" 2>/dev/null; then
                     ((killed_count++))
                     log_success "Closed: $peer"
                 fi
             fi
        done <<< "$conn_data"
        
        if [[ $killed_count -gt 0 ]]; then
            log_success "Cleaned up $killed_count connection(s) on port $port."
        fi
        
    else
        log_info "Port $port is healthy (1 active connection)."
    fi
}

# Run watchdog for all TCP ports in configuration
run_tcp_watchdog() {
    log_info "Starting TCP Watchdog scan..."
    
    local ports=$(get_tcp_ports)
    
    if [[ -z "$ports" ]]; then
        log_warn "No TCP sources found in $CONFIG_FILE"
        return 0
    fi
    
    log_info "Monitoring TCP ports: $(echo $ports | tr '\n' ' ')"
    
    while IFS= read -r port; do
        [[ -n "$port" ]] && kill_zombie_connections "$port"
    done <<< "$ports"
    
    log_info "TCP Watchdog scan completed"
}

# Install TCP watchdog as systemd service/timer
install_tcp_watchdog() {
    clear
    echo -e "${CYAN}==================================================${NC}"
    echo -e "${BOLD}      TCP Watchdog Installation/Update           ${NC}"
    echo -e "${CYAN}==================================================${NC}"
    echo ""
    
    # Check for existing installation
    local is_installed=false
    local is_running=false
    
    if [[ -f /etc/systemd/system/snapcast-tcp-watchdog.timer ]]; then
        is_installed=true
        if systemctl is-active --quiet snapcast-tcp-watchdog.timer; then
            is_running=true
        fi
    fi
    
    # Get current TCP ports from configuration
    local ports=$(get_tcp_ports)
    local port_count=0
    
    if [[ -n "$ports" ]]; then
        port_count=$(echo "$ports" | wc -l)
    fi
    
    # Show summary
    echo -e "${BOLD}Configuration Summary:${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    if [[ $port_count -eq 0 ]]; then
        log_warn "No TCP sources found in $CONFIG_FILE"
        echo ""
        echo "The watchdog needs at least one TCP source to monitor."
        echo "Please add TCP sources first using option 4 in the main menu."
        echo ""
        read -p "Press Enter to continue..."
        return 1
    fi
    
    echo -e "${GREEN}✓${NC} Found ${BOLD}$port_count${NC} TCP source(s) in configuration:"
    echo ""
    
    # Show each port with its name from config
    while IFS= read -r port; do
        local source_name=$(grep "tcp://.*:${port}" "$CONFIG_FILE" | sed -n 's/.*name=\([^&]*\).*/\1/p')
        if [[ -z "$source_name" ]]; then
            source_name="(unnamed)"
        fi
        echo -e "  • Port ${BOLD}${port}${NC} - ${source_name}"
    done <<< "$ports"
    
    echo ""
    echo -e "${BOLD}Advanced Recovery Settings:${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "The watchdog uses a graduated response to recover deadlocked streams:"
    echo "  1. Kill zombie sockets with ss -K (Strike 1)"
    echo "  2. Retry kill with delay (Strike 2 & 3)"
    echo "  3. Service RESTART (Strike 4 - Nuclear Option, only if enabled)"
    echo ""
    echo -e "${YELLOW}NOTE: The watchdog now uses conservative socket kills instead of SIGUSR1,"
    echo -e "which could kill the entire server for a single port issue.${NC}"
    echo ""
    read -p "Enable AUTO-RESTART of Snapserver if a stream is deadlocked for >6 minutes? (y/N): " enable_restart
    
    local AUTO_RESTART="false"
    if [[ "$enable_restart" =~ ^[Yy]$ ]]; then
        AUTO_RESTART="true"
        echo -e "${YELLOW}>> Auto-Restart ENABLED. The service will restart if deadlocks persist.${NC}"
    else
        echo -e "${GREEN}>> Auto-Restart DISABLED. The watchdog will only log the Critical event.${NC}"
    fi

    echo ""
    echo -e "${BOLD}Watchdog Behavior:${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  • Monitors TCP port(s) for zombie connections every ${BOLD}2 minutes${NC}"
    echo -e "  • Uses a 'Strike System' to track persistent failures"
    echo -e "  • Logs detailed diagnostics to /var/log/snapcast-tcp-watchdog.log"
    echo ""
    
    # Confirm installation/update
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    if [[ "$is_installed" == true ]]; then
        read -p "Do you want to UPDATE the TCP Watchdog with these settings? (y/N): " confirm
    else
        read -p "Do you want to INSTALL the TCP Watchdog with these settings? (y/N): " confirm
    fi
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Installation cancelled by user."
        sleep 1
        return 0
    fi
    
    echo ""
    log_info "Installing TCP Watchdog service..."
    
    local watchdog_script="/usr/local/bin/snapcast-tcp-watchdog.sh"
    local service_file="/etc/systemd/system/snapcast-tcp-watchdog.service"
    local timer_file="/etc/systemd/system/snapcast-tcp-watchdog.timer"
    
    # Create watchdog script
    cat > "$watchdog_script" << WATCHDOG_EOF
#!/bin/bash
# Snapcast TCP Watchdog - Smart Recovery for Zombie Connections & Deadlocks
# Strategy: Graduated Response (Kill -> Soft Reload -> Restart)

CONFIG_FILE="/etc/snapserver.conf"
LOG_FILE="/var/log/snapcast-tcp-watchdog.log"
STRIKE_FILE="/tmp/snapcast_watchdog_strikes.db"
ENABLE_AUTO_RESTART="$AUTO_RESTART"

log_msg() {
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - \$1" >> "\$LOG_FILE"
}

get_strikes() {
    local port=\$1
    if [ -f "\$STRIKE_FILE" ]; then
        grep "^\$port=" "\$STRIKE_FILE" | cut -d= -f2 || echo "0"
    else
        echo "0"
    fi
}

set_strikes() {
    local port=\$1
    local strikes=\$2
    
    # Remove old entry if exists
    if [ -f "\$STRIKE_FILE" ]; then
        grep -v "^\$port=" "\$STRIKE_FILE" > "\$STRIKE_FILE.tmp"
        mv "\$STRIKE_FILE.tmp" "\$STRIKE_FILE"
    fi
    
    if [ "\$strikes" -gt 0 ]; then
        echo "\$port=\$strikes" >> "\$STRIKE_FILE"
    fi
}

get_tcp_ports() {
    if [[ ! -f "\$CONFIG_FILE" ]]; then
        return 1
    fi
    grep "source = tcp://" "\$CONFIG_FILE" 2>/dev/null | \
        sed -n 's/.*tcp:\/\/[^:]*:\([0-9]*\).*/\1/p' | \
        sort -u
}

manage_deadlock() {
    local port="\$1"
    local total_conns="\$2"
    
    local current_strikes=\$(get_strikes "\$port")
    local new_strikes=\$((current_strikes + 1))
    
    log_msg "ALERT: Port \$port has \$total_conns connections (Strike \$current_strikes -> \$new_strikes)."
    
    # Escalation Logic (Conservative approach - never kill the entire server for a single port issue)
    # Strike 1: Kill connections
    # Strike 2: Wait + Kill connections again (aggressive retry)
    # Strike 3: Kill connections again
    # Strike 4+: Service restart IF enabled, otherwise keep trying kills
    
    if [ "\$new_strikes" -ge 4 ]; then
        # STRIKE 4: CRITICAL DEADLOCK (6+ mins)
        log_msg "CRITICAL: Port \$port deadlocked for 6+ minutes. Socket kill attempts ineffective."
        
        if [ "\$ENABLE_AUTO_RESTART" == "true" ]; then
            log_msg "ACTION: NUCLEAR OPTION - Triggering Snapserver Service RESTART."
            systemctl restart snapserver
            log_msg "RESULT: Service restarted. Resetting strikes."
            set_strikes "\$port" "0" 
            return # Exit function, service is restarting anyway
        else
            log_msg "WARNING: AUTO-RESTART is disabled. Cannot restart service."
            log_msg "ACTION: Aggressive socket kill attempt with delay..."
            sleep 3
            kill_connections "\$port"
            # Reset to 2 to continue the kill retry loop
            set_strikes "\$port" "2"
            log_msg "INFO: Strikes reset to 2. Will continue monitoring."
        fi
        
    elif [ "\$new_strikes" -eq 2 ]; then
        # STRIKE 2: AGGRESSIVE RETRY (2 mins)
        # Previous kill didn't immediately resolve. Wait a moment and try again.
        # NOTE: We intentionally do NOT send SIGUSR1 as it kills the entire server
        # instead of just reloading a single stream.
        log_msg "WARNING: Persistent issue on Port \$port. First kill attempt didn't resolve."
        log_msg "ACTION: Waiting 3 seconds, then aggressive socket kill retry..."
        sleep 3
        kill_connections "\$port"
        log_msg "DEBUG: Second kill attempt completed for port \$port."
        set_strikes "\$port" "\$new_strikes"

    else
        # STRIKE 1 & 3: KILL CONNECTIONS (0 mins & 4 mins)
        # Standard cleanup.
        log_msg "ACTION: Killing \$total_conns zombie connection(s) on port \$port."
        kill_connections "\$port"
        set_strikes "\$port" "\$new_strikes"
    fi
}

kill_connections() {
    local port="\$1"
    local conn_data=\$(ss -top state established "( sport = :\$port )" 2>/dev/null | awk 'NR>1 {print \$0}')
    
    while IFS= read -r line; do
         local peer=\$(echo "\$line" | awk '{ if (\$1 ~ /^[0-9]+\$/) print \$5; else print \$5; }')
         if [[ ! "\$peer" =~ .*:.* ]]; then
             peer=\$(echo "\$line" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+' | tail -n1)
         fi

         if [[ -n "\$peer" ]]; then
             if ss -K dst "\$peer" 2>/dev/null; then
                 log_msg "  > Closed socket: \$peer"
             fi
         fi
    done <<< "\$conn_data"
}

# Main execution
log_msg "--- Watchdog Scan Start ---"

ports=\$(get_tcp_ports)

if [[ -n "\$ports" ]]; then
    while IFS= read -r port; do
        [[ -z "\$port" ]] && continue
        
        # Check active connections
        conn_data=\$(ss -top state established "( sport = :\$port )" 2>/dev/null | awk 'NR>1 {print \$0}')
        total_conns=0
        if [[ -n "\$conn_data" ]]; then
            total_conns=\$(echo "\$conn_data" | grep -c .)
        fi
        
        if [[ "\$total_conns" -gt 1 ]]; then
            # Problem Detected
            manage_deadlock "\$port" "\$total_conns"
        else
            # Healthy (0 or 1 connection)
            # If we had strikes before, clear them now.
            if [ "\$(get_strikes "\$port")" -gt 0 ]; then
                log_msg "INFO: Port \$port recovered (Active connections: \$total_conns). Resetting strikes."
                set_strikes "\$port" "0"
            fi
        fi
    done <<< "\$ports"
else
    log_msg "No TCP sources found."
fi
WATCHDOG_EOF

    chmod +x "$watchdog_script"
    
    # Create systemd service
    cat > "$service_file" << SERVICE_EOF
[Unit]
Description=Snapcast TCP Watchdog - Smart Recovery
After=network.target snapserver.service

[Service]
Type=oneshot
ExecStart=$watchdog_script
StandardOutput=journal
StandardError=journal
SERVICE_EOF

    # Create systemd timer (runs every 2 minutes)
    cat > "$timer_file" << TIMER_EOF
[Unit]
Description=Run Snapcast TCP Watchdog every 2 minutes
Requires=snapcast-tcp-watchdog.service

[Timer]
OnBootSec=1min
OnUnitActiveSec=2min
AccuracySec=1s

[Install]
WantedBy=timers.target
TIMER_EOF

    # Reload systemd and enable timer
    systemctl daemon-reload
    systemctl enable snapcast-tcp-watchdog.timer 2>/dev/null
    systemctl restart snapcast-tcp-watchdog.timer
    
    echo ""
    log_success "TCP Watchdog updated successfully!"
    echo "  • Recovery Mode: Conservative (Kill → Kill w/delay → Restart)"
    echo "  • Auto-Restart: $AUTO_RESTART"
    echo "  • Logs: /var/log/snapcast-tcp-watchdog.log"
    echo ""
}

# Uninstall TCP watchdog
uninstall_tcp_watchdog() {
    log_info "Uninstalling TCP Watchdog..."
    
    systemctl stop snapcast-tcp-watchdog.timer 2>/dev/null || true
    systemctl disable snapcast-tcp-watchdog.timer 2>/dev/null || true
    
    rm -f /etc/systemd/system/snapcast-tcp-watchdog.service
    rm -f /etc/systemd/system/snapcast-tcp-watchdog.timer
    rm -f /usr/local/bin/snapcast-tcp-watchdog.sh
    
    systemctl daemon-reload
    
    log_success "TCP Watchdog uninstalled"
}

# Show TCP watchdog status
show_watchdog_status() {
    clear
    echo -e "${CYAN}--- TCP Watchdog Status ---${NC}"
    
    if systemctl is-active --quiet snapcast-tcp-watchdog.timer; then
        echo -e "Status: ${GREEN}Running${NC}"
        echo ""
        echo -e "${BOLD}Monitored TCP Ports:${NC}"
        local ports=$(get_tcp_ports)
        if [[ -n "$ports" ]]; then
            while IFS= read -r port; do
                echo "  • Port $port"
            done <<< "$ports"
        else
            echo "  No TCP sources configured"
        fi
        echo ""
        echo -e "${BOLD}Timer Status:${NC}"
        systemctl status snapcast-tcp-watchdog.timer --no-pager | head -n 10
        echo ""
        echo -e "${BOLD}Recent Logs:${NC}"
        if [[ -f /var/log/snapcast-tcp-watchdog.log ]]; then
            tail -n 10 /var/log/snapcast-tcp-watchdog.log
        else
            journalctl -u snapcast-tcp-watchdog.service -n 10 --no-pager
        fi
    else
        echo -e "Status: ${RED}Not Running${NC}"
    fi
    
    read -p "Press Enter to continue..."
}

# Shared logic for printing status (used by static and live views)
print_watchdog_status_logic() {
    clear
    echo -e "${CYAN}--- Detailed Connection Health ---${NC}"
    echo -e "Snapshot time: $(date '+%H:%M:%S')"
    echo ""

    local ports=$(get_tcp_ports)
    
    if [[ -z "$ports" ]]; then
        log_warn "No TCP sources configured."
        return
    fi
    
    while IFS= read -r port; do
        [[ -z "$port" ]] && continue
        
        # Get source name
        local source_name=$(grep "tcp://.*:${port}" "$CONFIG_FILE" | sed -n 's/.*name=\([^&]*\).*/\1/p')
        [[ -z "$source_name" ]] && source_name="(unnamed)"
        
        echo -e "${BOLD}Port ${port} (${source_name})${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        # Get detailed info using ss
        # -t: tcp, -n: numeric, -p: process, -i: internal info (rtt, etc), -o: timer info
        local details=$(ss -tnpio "sport = :$port" | awk 'NR>1')
        
        if [[ -z "$details" ]]; then
             echo -e "${YELLOW}  No active connections.${NC}"
        else
             # Fix header formatting using printf
             printf "${CYAN}  %-25s %-12s %-10s %-10s${NC}\n" "Remote Address" "State" "Recv-Q" "Send-Q"
             
             while IFS= read -r line; do
                 # Skip empty lines
                 [[ -z "$line" ]] && continue
                 
                 # Check if this is a continuation line (starts with space/tab) representing stats
                 if [[ "$line" =~ ^[[:space:]] ]]; then
                     # This is a stats line (e.g., rtt, cwnd, etc.)
                     # Clean it up and print neatly
                     echo -e "    ${LOW_INTENSITY}↳ $line${NC}"
                     continue
                 fi

                 # It's a connection line
                 # Expected format: State Recv-Q Send-Q Local Peer
                 # But sometimes ss is weird. Let's try to grab the defined columns.
                 
                 local state=$(echo "$line" | awk '{print $1}')
                 local recvq=$(echo "$line" | awk '{print $2}')
                 local sendq=$(echo "$line" | awk '{print $3}')
                 # $4 is Local, $5 is Peer
                 local remote=$(echo "$line" | awk '{print $5}')
                 
                 # Colorize state
                 local state_color="$GREEN"
                 [[ "$state" != "ESTAB" ]] && state_color="$YELLOW"
                 
                 # Highlight high queues based on Snapcast best practices:
                 # < 64KB: Healthy (Normal buffering) -> GREEN
                 # 64KB - 256KB: Caution (Potential buffering/latency) -> YELLOW
                 # > 256KB: Critical (Likely blockage/issues) -> RED
                 if [[ "$recvq" -gt 256000 ]]; then
                     recvq="${RED}${recvq}${NC}"
                 elif [[ "$recvq" -gt 64000 ]]; then
                     recvq="${YELLOW}${recvq}${NC}"
                 else
                     recvq="${GREEN}${recvq}${NC}"
                 fi
                 
                 if [[ "$sendq" -gt 1000 ]]; then sendq="${RED}${sendq}${NC}"; fi
                 
                 # Use %b for columns that might contain color codes (backslashes)
                 printf "  %-25s ${state_color}%-12s${NC} %-10b %-10b\n" "$remote" "$state" "$recvq" "$sendq"
                 
             done <<< "$details"
        fi
        echo ""
        
    done <<< "$ports"
}

# detailed_watchdog_status (Scanning/Snapshot)
detailed_watchdog_status() {
    print_watchdog_status_logic
    
    read -p "Press Enter to refresh (r) or any other key to return: " -n 1 choice
    echo ""
    if [[ "$choice" =~ ^[Rr]$ ]]; then
        detailed_watchdog_status
    fi
}

# live_watchdog_monitor (Real-time)
live_watchdog_monitor() {
    while true; do
        print_watchdog_status_logic
        echo -e "${YELLOW}Press [CTRL+C] to exit live monitor...${NC}"
        sleep 1
    done
}

# TCP Watchdog management menu
manage_tcp_watchdog() {
    while true; do
        clear
        echo -e "${CYAN}--- TCP Watchdog Management ---${NC}"
        
        if systemctl is-active --quiet snapcast-tcp-watchdog.timer; then
            echo -e "Status: ${GREEN}Running${NC}"
        else
            echo -e "Status: ${RED}Stopped${NC}"
        fi
        
        echo -e "${CYAN}-------------------------------${NC}"
        echo "1. Install/Enable Watchdog"
        echo "2. Run Watchdog Now (Manual)"
        echo "3. Show Detailed Connection Health"
        echo "4. Real-time Connection Monitor"
        echo "5. Show Status & Logs"
        echo "6. Uninstall Watchdog"
        echo "7. Back to Main Menu"
        echo -e "${CYAN}-------------------------------${NC}"
        
        read -p "Select an option: " choice || exit 1
        
        case $choice in
            1)
                install_tcp_watchdog
                read -p "Press Enter to continue..."
                ;;
            2)
                run_tcp_watchdog
                read -p "Press Enter to continue..."
                ;;
            3)
                detailed_watchdog_status
                ;;
            4)
                # Trap CTRL+C to return to menu instead of exiting script
                trap 'break' INT
                live_watchdog_monitor
                trap - INT
                ;;
            5)
                show_watchdog_status
                ;;
            6)
                read -p "Are you sure you want to uninstall the watchdog? (y/N): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    uninstall_tcp_watchdog
                fi
                read -p "Press Enter to continue..."
                ;;
            7)
                return
                ;;
            *)
                log_error "Invalid option."
                sleep 1
                ;;
        esac
    done
}

# --- TCP/Process Source Management ---

# Helper to insert source lines into the [stream] block
# Inserts BEFORE the next section ([...]) or at the end of the file if no next section
insert_into_stream_block() {
    local comment="$1"
    local source_line="$2"
    local config="$3"

    # Ensure [stream] section exists
    if ! grep -q "^\[stream\]" "$config"; then
        echo "" >> "$config"
        echo "[stream]" >> "$config"
        echo "codec = pcm" >> "$config"
    fi

    # Create a temporary file with the new content to insert
    local insert_content="${comment}\n${source_line}"

    # Use awk to insert nicely
    awk -v insert="$insert_content" '
        BEGIN { inserted=0; inside_stream=0 }
        /^\[stream\]/ { 
            print; 
            inside_stream=1; 
            next 
        }
        /^\[/ { 
            if (inside_stream && !inserted) {
                print ""
                print insert
                print ""
                inserted=1
                inside_stream=0
            }
        }
        { print }
        END { 
            if (!inserted) {
                print ""
                print insert
            }
        }
    ' "$config" > "${config}.tmp" && mv "${config}.tmp" "$config"
}

# URL Encode helper (simple version for basic URL components)
url_encode() {
    local string="$1"
    local strlen=${#string}
    local encoded=""
    local pos c o

    for (( pos=0 ; pos<strlen ; pos++ )); do
        c=${string:$pos:1}
        case "$c" in
            [-_.~a-zA-Z0-9] ) o="${c}" ;;
            * )               printf -v o '%%%02x' "'$c"
        esac
        encoded+="${o}"
    done
    echo "${encoded}"
}

manage_sources() {
    while true; do
        clear
        echo -e "${CYAN}--- Source Management ---${NC}"
        echo -e "Current Sources in $CONFIG_FILE:"
        echo -e "${YELLOW}"
        # Display sources with their comments (grep context -B1 for comments)
        grep -nE "source = (tcp|process)://" "$CONFIG_FILE" || echo "No custom sources found."
        echo -e "${NC}"
        echo -e "${CYAN}-----------------------------${NC}"
        echo "1. Add TCP Source (Laptop/PC)"
        echo "2. Add Process Source (Azuracast/HLS)"
        echo "3. Remove Source"
        echo "4. Back to Main Menu"
        echo -e "${CYAN}-----------------------------${NC}"
        read -p "Select an option: " choice || exit 1
        
        case $choice in
            1)
                echo -e "${BOLD}Add TCP Source${NC}"
                read -p "Enter Port (default 4953): " port
                port=${port:-4953}
                read -p "Enter Name (e.g., Spotify): " name
                name=${name:-TCP_Stream}
                read -p "Enter Codec (default pcm): " codec
                codec=${codec:-pcm}
                read -p "Enter Sample Format (default 48000:16:2): " sampleformat
                sampleformat=${sampleformat:-48000:16:2}

                # Optional Advanced Configs
                read -p "Idle Threshold (ms, default 2000): " idle_threshold
                idle_threshold=${idle_threshold:-2000}
                
                read -p "Send Silence? (true/false, default true): " send_silence
                send_silence=${send_silence:-true}
                
                read -p "Retry Count (default 3): " retry
                retry=${retry:-3}
                
                read -p "Timeout (sec, default 5): " timeout
                timeout=${timeout:-5}
                
                # Sanitize name
                safe_name=$(echo "$name" | tr -d ' ')

                COMMENT_LINE="# ${name} TCP"
                SOURCE_LINE="source = tcp://0.0.0.0:${port}?name=${safe_name}&codec=${codec}&sampleformat=${sampleformat}&idle_threshold=${idle_threshold}&send_silence=${send_silence}&retry=${retry}&timeout=${timeout}"
                
                insert_into_stream_block "$COMMENT_LINE" "$SOURCE_LINE" "$CONFIG_FILE"
                
                log_success "Added TCP source: $name on port $port"
                
                read -p "Restart Snapserver now? (y/N): " restart_opt
                if [[ "$restart_opt" =~ ^[Yy]$ ]]; then
                    systemctl restart "$SERVICE_NAME"
                    log_success "Service restarted."
                fi
                read -p "Press Enter to continue..."
                ;;
            2)
                echo -e "${BOLD}Add Process Source (Web Stream/HLS)${NC}"
                echo "Example URL: https://cast.symphonycr.com/hls/test/live.m3u8"
                read -p "Enter Stream URL: " stream_url
                
                if [[ -z "$stream_url" ]]; then
                    log_error "URL is required."
                    read -p "Press Enter to continue..."
                    continue
                fi

                read -p "Enter Name (e.g., Radio-Gym): " name
                name=${name:-Web_Stream}
                
                # Sanitize name
                safe_name=$(echo "$name" | tr -d ' ')

                # URL Encode the stream URL for inclusion in params
                # Note: user example uses %20 for spaces, but here we escape the URL itself
                # We simply put the URL as is if it doesn't have spaces, but encoded is safer
                # However, the user example shows explicit params string construction.
                # params=-i https://... -f s16le...
                # We need to ensure spaces in the params are encoded as %20
                
                RAW_PARAMS="-i ${stream_url} -f s16le -ar 48000 -ac 2 -"
                # Helper to encode spaces to %20
                ENCODED_PARAMS=$(echo "$RAW_PARAMS" | sed 's/ /%20/g')

                # Optional Advanced Configs
                read -p "Idle Threshold (ms, default 5000): " idle_threshold
                idle_threshold=${idle_threshold:-5000}
                
                read -p "Send Silence? (true/false, default true): " send_silence
                send_silence=${send_silence:-true}

                COMMENT_LINE="# ${name}"
                SOURCE_LINE="source = process:///usr/bin/ffmpeg?name=${safe_name}&codec=pcm&sampleformat=48000:16:2&idle_threshold=${idle_threshold}&send_silence=${send_silence}&log_stderr=false&params=${ENCODED_PARAMS}"
                
                insert_into_stream_block "$COMMENT_LINE" "$SOURCE_LINE" "$CONFIG_FILE"
                
                log_success "Added Process source: $name"
                
                read -p "Restart Snapserver now? (y/N): " restart_opt
                if [[ "$restart_opt" =~ ^[Yy]$ ]]; then
                    systemctl restart "$SERVICE_NAME"
                    log_success "Service restarted."
                fi
                read -p "Press Enter to continue..."
                ;;
            3)
                echo -e "${YELLOW}Select a source to delete:${NC}"
                # Get lines with line numbers for both tcp and process
                grep -nE "source = (tcp|process)://" "$CONFIG_FILE"
                
                if [[ $? -ne 0 ]]; then
                     echo "No sources to delete."
                     read -p "Press Enter to continue..."
                     continue
                fi

                read -p "Enter the line number of the source to delete: " line_num
                
                if [[ -n "$line_num" && "$line_num" =~ ^[0-9]+$ ]]; then
                    # Check if the previous line is a comment associated with this source
                    prev_line_num=$((line_num - 1))
                    prev_line_content=$(sed "${prev_line_num}q;d" "$CONFIG_FILE")
                    
                    # Delete the source line
                    sed -i.bak "${line_num}d" "$CONFIG_FILE"
                    rm "${CONFIG_FILE}.bak"
                    log_success "Removed source line."

                    # Check if previous line looks like a comment (starts with #)
                    # We are slightly aggressive here, assuming any # above a source we just deleted is ours
                    if [[ "$prev_line_content" =~ ^#.*$ ]]; then
                        sed -i.bak "${prev_line_num}d" "$CONFIG_FILE"
                        rm "${CONFIG_FILE}.bak"
                        log_success "Removed associated comment."
                    fi
                    
                    read -p "Restart Snapserver now? (y/N): " restart_opt
                    if [[ "$restart_opt" =~ ^[Yy]$ ]]; then
                        systemctl restart "$SERVICE_NAME"
                         log_success "Service restarted."
                    fi
                else
                    log_error "Invalid line number."
                fi
                read -p "Press Enter to continue..."
                ;;
            4) return ;;
            *) log_error "Invalid option." ;;
        esac
    done
}

# --- Main Menu ---
show_menu() {
    while true; do
        clear
        echo -e "${CYAN}==================================================${NC}"
        echo -e "${BOLD}         Snapserver Manager v${VERSION}              ${NC}"
        echo -e "${CYAN}==================================================${NC}"
        
        # Status Check
        if systemctl is-active --quiet "$SERVICE_NAME"; then
            echo -e "Status: ${GREEN}Running${NC}"
        else
            echo -e "Status: ${RED}Stopped${NC}"
        fi
        
        echo -e "${CYAN}--------------------------------------------------${NC}"
        echo "1. Install/Update Snapserver"
        echo "2. Service Management"
        echo "3. View Logs"
        echo "4. Manage Sources (TCP/Process)"
        echo "5. TCP Watchdog (Monitor & Kill Zombies)"
        echo "6. Exit"
        echo -e "${CYAN}--------------------------------------------------${NC}"
        
        read -p "Select an option: " choice || exit 1
        
        case $choice in
            1) install_snapserver ;;
            2) manage_service ;;
            3) view_logs ;;
            4) manage_sources ;;
            5) manage_tcp_watchdog ;;
            6) exit 0 ;;
            *) log_error "Invalid option." ; sleep 1 ;;
        esac
    done
}

# --- Entry Point ---
main() {
    check_root
    check_dependencies
    check_proxmox_lxc
    show_menu
}

if ! (return 0 2>/dev/null); then
    main "$@"
fi
