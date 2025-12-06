#!/bin/bash

# Snapserver Manager Script
# A simple, clean manager for Snapserver installations
# Supports: Proxmox LXC, TCP Sources, TCP Watchdog, Log Viewing, Service Management

VERSION="1.5.0"

# --- Colors & Styling ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# --- Global Variables ---
CONFIG_FILE="/etc/snapserver.conf"
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
    local dependencies=("curl" "wget" "jq" "systemctl" "grep" "sed" "lsof" "netstat")
    local missing=()

    for cmd in "${dependencies[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Missing dependencies: ${missing[*]}"
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

# --- Core Functions ---

install_snapserver() {
    log_info "Checking for latest Snapserver release..."
    
    # Get latest release tag
    LATEST_RELEASE=$(curl -s https://api.github.com/repos/badaix/snapcast/releases/latest | jq -r .tag_name)
    VERSION=${LATEST_RELEASE#v} # Remove 'v' prefix
    
    if [[ -z "$VERSION" || "$VERSION" == "null" ]]; then
        log_error "Failed to fetch latest version. Check internet connection."
        read -p "Press Enter to continue..."
        return
    fi
    
    log_info "Latest version: ${GREEN}$VERSION${NC}"
    
    # Detect Architecture
    ARCH=$(dpkg --print-architecture)
    DEB_FILE="snapserver_${VERSION}-1_${ARCH}.deb"
    DOWNLOAD_URL="https://github.com/badaix/snapcast/releases/download/${LATEST_RELEASE}/${DEB_FILE}"
    
    log_info "Detected architecture: ${YELLOW}$ARCH${NC}"
    log_info "Downloading $DEB_FILE..."
    
    if wget -q --show-progress "$DOWNLOAD_URL"; then
        log_success "Download complete."
        log_info "Installing Snapserver..."
        dpkg -i "$DEB_FILE"
        
        if [[ $? -ne 0 ]]; then
            log_warn "Dependency issues detected. Fixing..."
            apt-get -f install -y
        fi
        
        rm "$DEB_FILE"
        log_success "Snapserver installed successfully!"
    else
        log_error "Failed to download package."
    fi
    read -p "Press Enter to continue..."
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
        read -p "Select an option: " choice
        
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
kill_zombie_connections() {
    local port="$1"
    local killed_count=0
    
    log_info "Checking for zombie/orphaned connections on port $port (Ingestion Mode)..."
    
    # 1. First Pass: Detect ORPHANED and EXPLICIT DEAD connections
    # -------------------------------------------------------------
    # Orphaned: No process (snapserver) attached (ghosts usually lack process info in ss output)
    # Dead: Timer onack (retransmitting) or Send-Q blocked
    # NOTE: We removed Recv-Q check because audio buffers are naturally large (~90k is normal)
    
    # Use ss -top to show timer information AND process information
    local explicit_zombies=$(ss -top state established "( sport = :${port} )" 2>/dev/null | \
        awk 'NR>1 {
            # Capture full line for regex checks
            line = $0;
            
            # Extract basic fields
            recv_q = $2;
            send_q = $3;
            peer_addr = $5;
            
            # Condition A: ORPHANED SOCKET (The "Ghost" Detector)
            # Valid connections have users:(("snapserver"... associated.
            # Ghosts usually have no process info or different info.
            # We look for absence of "snapserver" in the line.
            is_orphan = (line !~ /users:\(\("snapserver"/);
            
            # Condition B: Stuck Send-Q (any data in purely ingest stream is suspicious)
            is_stuck_send = (send_q > 0);
            
            # Condition C: Retransmission timer active
            is_retrans = (line ~ /timer:\(on[[:space:]]*,/ || line ~ /timer:\(onack/);
            
            if (is_orphan || is_stuck_send || is_retrans) {
                # Add reason for log (optional, just print IP for now)
                print peer_addr, (is_orphan ? "ORPHAN" : "DEAD")
            }
        }')
    
    # Kill explicit zombies first
    if [[ -n "$explicit_zombies" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local remote_addr=$(echo "$line" | awk '{print $1}')
            local reason=$(echo "$line" | awk '{print $2}')
            
            log_warn "Found $reason connection: $remote_addr"
            if ss -K dst "$remote_addr" 2>/dev/null; then
                ((killed_count++))
                log_success "Closed zombie: $remote_addr"
            fi
        done <<< "$explicit_zombies"
    fi

    # 2. Second Pass: Detect Multiple Connections from Same IP (Cleanup)
    # ------------------------------------------------------------------
    # ZERO TOLERANCE POLICY:
    # If a client IP has multiple connections to the same port, the state is inconsistent.
    # It is safer to kill ALL connections from that IP (including "valid" ones) to force
    # a clean, fresh reconnection from the client.
    
    # Get all established connections
    local duplicate_candidates=$(ss -tn state established "( sport = :${port} )" 2>/dev/null | \
        awk 'NR>1 {
            split($5, a, ":");
            ip = a[1];
            port = a[2];
            print ip, port;
        }' | sort)
    
    local multi_conn_ips=$(echo "$duplicate_candidates" | awk '{print $1}' | uniq -d)
    
    if [[ -n "$multi_conn_ips" ]]; then
        while IFS= read -r ip; do
            [[ -z "$ip" ]] && continue
            
            log_warn "Detected multiple connections from IP: $ip (Bad State)"
            log_info "Applying Zero Tolerance: Resetting all connections for $ip..."
            
            local conns=$(echo "$duplicate_candidates" | grep "^$ip ")
            
            # Kill ALL connections for this IP
            while IFS= read -r line; do
                local c_ip=$(echo "$line" | awk '{print $1}')
                local c_port=$(echo "$line" | awk '{print $2}')
                
                log_warn "Force closing: $c_ip:$c_port"
                if ss -K dst "${c_ip}:${c_port}" 2>/dev/null; then
                    ((killed_count++))
                    log_success "Closed: $c_ip:$c_port"
                fi
            done <<< "$conns"
            
        done <<< "$multi_conn_ips"
    fi
    
    if [[ $killed_count -gt 0 ]]; then
        log_success "Total connections closed on port $port: $killed_count"
    else
        log_info "No zombie or duplicate connections found on port $port"
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
    echo -e "${BOLD}Watchdog Behavior:${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  • Monitors the above TCP port(s) for zombie connections"
    echo -e "  • Runs automatically every ${BOLD}2 minutes${NC}"
    echo -e "  • Closes stuck connections (${BOLD}FD only${NC}, not the entire process)"
    echo "  • Logs activity to /var/log/snapcast-tcp-watchdog.log"
    echo ""
    
    # Show current status if installed
    if [[ "$is_installed" == true ]]; then
        echo -e "${BOLD}Current Installation Status:${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        if [[ "$is_running" == true ]]; then
            echo -e "  Status: ${GREEN}Installed and Running${NC}"
            echo "  This will ${BOLD}UPDATE${NC} the existing watchdog configuration."
        else
            echo -e "  Status: ${YELLOW}Installed but Stopped${NC}"
            echo "  This will ${BOLD}UPDATE and START${NC} the watchdog."
        fi
        echo ""
    fi
    
    # Confirm installation/update
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    if [[ "$is_installed" == true ]]; then
        read -p "Do you want to UPDATE the TCP Watchdog? (y/N): " confirm
    else
        read -p "Do you want to INSTALL the TCP Watchdog? (y/N): " confirm
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
    cat > "$watchdog_script" << 'WATCHDOG_EOF'
#!/bin/bash
# Snapcast TCP Watchdog - Monitors and kills zombie TCP connections
# NOTE: Closes only the TCP connection (FD), NOT the entire process

CONFIG_FILE="/etc/snapserver.conf"
LOG_FILE="/var/log/snapcast-tcp-watchdog.log"

log_msg() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

get_tcp_ports() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        return 1
    fi
    grep "source = tcp://" "$CONFIG_FILE" 2>/dev/null | \
        sed -n 's/.*tcp:\/\/[^:]*:\([0-9]*\).*/\1/p' | \
        sort -u
}

kill_zombie_connections() {
    local port="$1"
    local killed_count=0
    
    log_msg "Checking for zombie/orphaned connections on port $port (Ingestion Mode)"
    
    # 1. First Pass: Detect ORPHANED and EXPLICIT DEAD connections
    # -------------------------------------------------------------
    # Use ss -top to show timer information AND process information
    local explicit_zombies=$(ss -top state established "( sport = :${port} )" 2>/dev/null | \
        awk 'NR>1 {
            # Capture full line for regex checks
            line = $0;
            
            # Extract basic fields
            recv_q = $2;
            send_q = $3;
            peer_addr = $5;
            
            # Condition A: ORPHANED SOCKET (The "Ghost" Detector)
            # Valid connections have users:(("snapserver"... associated.
            is_orphan = (line !~ /users:\(\("snapserver"/);
            
            # Condition B: Stuck Send-Q
            is_stuck_send = (send_q > 0);
            
            # Condition C: Retransmission timer active
            is_retrans = (line ~ /timer:\(on[[:space:]]*,/ || line ~ /timer:\(onack/);
            
            if (is_orphan || is_stuck_send || is_retrans) {
                print peer_addr, (is_orphan ? "ORPHAN" : "DEAD")
            }
        }')
    
    # Kill explicit zombies first
    if [[ -n "$explicit_zombies" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local remote_addr=$(echo "$line" | awk '{print $1}')
            local reason=$(echo "$line" | awk '{print $2}')
            
            log_msg "Found $reason connection: $remote_addr"
            if ss -K dst "$remote_addr" 2>/dev/null; then
                ((killed_count++))
                log_msg "Closed zombie: $remote_addr"
            fi

    # 2. Second Pass: Detect Multiple Connections from Same IP (Cleanup)
    # ------------------------------------------------------------------
    # ZERO TOLERANCE POLICY:
    # If a client IP has multiple connections to the same port, the state is inconsistent.
    # It is safer to kill ALL connections from that IP (including "valid" ones) to force
    # a clean, fresh reconnection from the client.
    
    # Get all established connections
    local duplicate_candidates=$(ss -tn state established "( sport = :${port} )" 2>/dev/null | \
        awk 'NR>1 {
            split($5, a, ":");
            ip = a[1];
            port = a[2];
            print ip, port;
        }' | sort)
    
    local multi_conn_ips=$(echo "$duplicate_candidates" | awk '{print $1}' | uniq -d)
    
    if [[ -n "$multi_conn_ips" ]]; then
        while IFS= read -r ip; do
            [[ -z "$ip" ]] && continue
            
            log_msg "Detected multiple connections from IP: $ip (Bad State)"
            log_msg "Applying Zero Tolerance: Resetting all connections for $ip..."
            
            local conns=$(echo "$duplicate_candidates" | grep "^$ip ")
            
            # Kill ALL connections for this IP
            while IFS= read -r line; do
                local c_ip=$(echo "$line" | awk '{print $1}')
                local c_port=$(echo "$line" | awk '{print $2}')
                
                log_msg "Force closing: $c_ip:$c_port"
                if ss -K dst "${c_ip}:${c_port}" 2>/dev/null; then
                    ((killed_count++))
                    log_msg "Closed: $c_ip:$c_port"
                fi
            done <<< "$conns"
            
        done <<< "$multi_conn_ips"
    fi
    
    [[ $killed_count -gt 0 ]] && log_msg "Closed $killed_count connection(s) on port $port"
}

# Main execution
log_msg "TCP Watchdog starting scan"

ports=$(get_tcp_ports)

if [[ -n "$ports" ]]; then
    while IFS= read -r port; do
        [[ -n "$port" ]] && kill_zombie_connections "$port"
    done <<< "$ports"
else
    log_msg "No TCP sources found in configuration"
fi

log_msg "TCP Watchdog scan completed"
WATCHDOG_EOF

    chmod +x "$watchdog_script"
    
    # Create systemd service
    cat > "$service_file" << 'SERVICE_EOF'
[Unit]
Description=Snapcast TCP Watchdog - Monitor and kill zombie TCP connections
After=network.target snapserver.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/snapcast-tcp-watchdog.sh
StandardOutput=journal
StandardError=journal
SERVICE_EOF

    # Create systemd timer (runs every 2 minutes)
    cat > "$timer_file" << 'TIMER_EOF'
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
    log_success "TCP Watchdog installed and started successfully!"
    echo ""
    echo -e "${BOLD}Monitoring:${NC} $port_count TCP port(s)"
    echo -e "${BOLD}Interval:${NC} Every 2 minutes"
    echo -e "${BOLD}Logs:${NC} /var/log/snapcast-tcp-watchdog.log"
    echo ""
    echo -e "${CYAN}Useful commands:${NC}"
    echo "  • View logs: journalctl -u snapcast-tcp-watchdog.service -f"
    echo "  • Check timer: systemctl status snapcast-tcp-watchdog.timer"
    echo "  • Manual run: /usr/local/bin/snapcast-tcp-watchdog.sh"
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
        echo "3. Show Status & Logs"
        echo "4. Uninstall Watchdog"
        echo "5. Back to Main Menu"
        echo -e "${CYAN}-------------------------------${NC}"
        
        read -p "Select an option: " choice
        
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
                show_watchdog_status
                ;;
            4)
                read -p "Are you sure you want to uninstall the watchdog? (y/N): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    uninstall_tcp_watchdog
                fi
                read -p "Press Enter to continue..."
                ;;
            5)
                return
                ;;
            *)
                log_error "Invalid option."
                sleep 1
                ;;
        esac
    done
}

# --- TCP Source Management ---

manage_tcp_sources() {
    while true; do
        clear
        echo -e "${CYAN}--- TCP Source Management ---${NC}"
        echo -e "Current TCP Sources in $CONFIG_FILE:"
        echo -e "${YELLOW}"
        grep "source = tcp://" "$CONFIG_FILE" || echo "No TCP sources found."
        echo -e "${NC}"
        echo -e "${CYAN}-----------------------------${NC}"
        echo "1. Add TCP Source"
        echo "2. Remove TCP Source"
        echo "3. Back to Main Menu"
        echo -e "${CYAN}-----------------------------${NC}"
        read -p "Select an option: " choice
        
        case $choice in
            1)
                read -p "Enter Port (default 4953): " port
                port=${port:-4953}
                read -p "Enter Name (e.g., Spotify): " name
                name=${name:-TCP_Stream}
                
                SOURCE_LINE="source = tcp://0.0.0.0:${port}?name=${name}"
                
                # Check if [stream] section exists
                if ! grep -q "^\[stream\]" "$CONFIG_FILE"; then
                    echo "" >> "$CONFIG_FILE"
                    echo "[stream]" >> "$CONFIG_FILE"
                fi
                
                # Append source to [stream] section
                # Using sed to insert after [stream] is safer but appending is easier for now
                # Ideally we want to append to the end of the file or specifically under [stream]
                # Simple approach: Append to end of file if it doesn't exist, or use sed to append after [stream]
                
                # Better approach: Just append to the file. Snapserver reads all source lines.
                echo "$SOURCE_LINE" >> "$CONFIG_FILE"
                
                log_success "Added: $SOURCE_LINE"
                log_info "Restarting Snapserver to apply changes..."
                systemctl restart "$SERVICE_NAME"
                read -p "Press Enter to continue..."
                ;;
            2)
                echo -e "${YELLOW}Select a line number to delete:${NC}"
                grep -n "source = tcp://" "$CONFIG_FILE"
                read -p "Line number: " line_num
                
                if [[ -n "$line_num" ]]; then
                    sed -i "${line_num}d" "$CONFIG_FILE"
                    log_success "Removed line $line_num"
                    log_info "Restarting Snapserver to apply changes..."
                    systemctl restart "$SERVICE_NAME"
                else
                    log_error "Invalid line number."
                fi
                read -p "Press Enter to continue..."
                ;;
            3) return ;;
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
        echo "4. Manage TCP Sources"
        echo "5. TCP Watchdog (Monitor & Kill Zombies)"
        echo "6. Exit"
        echo -e "${CYAN}--------------------------------------------------${NC}"
        
        read -p "Select an option: " choice
        
        case $choice in
            1) install_snapserver ;;
            2) manage_service ;;
            3) view_logs ;;
            4) manage_tcp_sources ;;
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

main
