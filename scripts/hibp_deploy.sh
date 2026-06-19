#!/bin/bash
# =============================================================================
#
#  ██╗  ██╗██╗██████╗ ██████╗     ██████╗ ███████╗██████╗ ██╗      ██████╗ ██╗   ██╗
#  ██║  ██║██║██╔══██╗██╔══██╗    ██╔══██╗██╔════╝██╔══██╗██║     ██╔═══██╗╚██╗ ██╔╝
#  ███████║██║██████╔╝██████╔╝    ██║  ██║█████╗  ██████╔╝██║     ██║   ██║ ╚████╔╝
#  ██╔══██║██║██╔══██╗██╔═══╝     ██║  ██║██╔══╝  ██╔═══╝ ██║     ██║   ██║  ╚██╔╝
#  ██║  ██║██║██████╔╝██║         ██████╔╝███████╗██║     ███████╗╚██████╔╝   ██║
#  ╚═╝  ╚═╝╚═╝╚═════╝ ╚═╝         ╚═════╝ ╚══════╝╚═╝     ╚══════╝ ╚═════╝    ╚═╝
#
#  ELC — In-House HIBP Password Breach Validation Service
#  Complete deployment script — raw RHEL server to DaVinci-ready API
#
#  WHAT THIS DEPLOYS:
#    1.  Two-check password validation API:
#        POST /check      — checks password against 2 billion+ HIBP breach hashes
#        POST /checkweak  — checks password against configurable weak word list
#        GET  /health     — monitoring endpoint
#
#    2.  Two data files:
#        pwnedpasswords.txt  — 88GB HIBP hash file (downloaded from haveibeenpwned.com)
#        weak_passwords.txt  — static weak word list (50k words, server-side only)
#
#    3.  Full supporting infrastructure:
#        Node.js API server  — binary search engine, BigInt safe for any file size
#        nginx HTTPS proxy   — required for DaVinci (HTTPS mixed content policy)
#        systemd service     — auto-starts on boot, restarts on crash
#        firewalld rules     — restricts access to configured IPs only
#
#  SECURITY:
#    - Weak word list never exposed to browser (server-side only)
#    - Passwords hashed server-side before any comparison
#    - Hash file never transmitted over network
#    - All traffic encrypted TLS 1.2/1.3 via nginx
#    - Service runs as non-root user
#
#  USAGE:
#    chmod +x hibp_deploy.sh
#    ./hibp_deploy.sh                 — first run wizard + full deploy
#    ./hibp_deploy.sh prereqs         — check/install prerequisites only
#    ./hibp_deploy.sh download        — download HIBP hash file only
#    ./hibp_deploy.sh build-index     — build binary search index only
#    ./hibp_deploy.sh install         — install server + nginx + service
#    ./hibp_deploy.sh start           — start services
#    ./hibp_deploy.sh stop            — stop services
#    ./hibp_deploy.sh test            — run full test suite
#    ./hibp_deploy.sh status          — show status of all components
#    ./hibp_deploy.sh logs            — show service logs
#    ./hibp_deploy.sh config          — re-run configuration wizard
#
# =============================================================================

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/hibp_deploy.config"
LOG_FILE="$SCRIPT_DIR/hibp_deploy.log"

# ── Terminal colours ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; NC='\033[0m'

# ── Logging helpers ───────────────────────────────────────────────────────────
_ts()     { date '+%H:%M:%S'; }
log()     { local m="$1"; echo -e "${CYAN}[$(_ts)]${NC} $m"; echo "[$(_ts)] $m" >> "$LOG_FILE" 2>/dev/null; }
success() { local m="$1"; echo -e "${GREEN}  ✓${NC}  $m"; echo "[OK] $m" >> "$LOG_FILE" 2>/dev/null; }
warn()    { local m="$1"; echo -e "${YELLOW}  ⚠${NC}  $m"; echo "[WARN] $m" >> "$LOG_FILE" 2>/dev/null; }
error()   { local m="$1"; echo -e "${RED}  ✗  ERROR:${NC} $m"; echo "[ERROR] $m" >> "$LOG_FILE" 2>/dev/null; exit 1; }
info()    { local m="$1"; echo -e "${BLUE}  →${NC}  $m"; }
desc()    { local m="$1"; echo -e "     ${CYAN}↳${NC} $m"; }
ask() {
    local prompt="$1" default="$2"
    echo -ne "${MAGENTA}  ?${NC}  ${BOLD}$prompt${NC}"
    [ -n "$default" ] && echo -ne " ${CYAN}[$default]${NC}"
    echo -ne ": "
    read REPLY < /dev/tty || REPLY=""
    [ -z "$REPLY" ] && REPLY="$default"
}
header() {
    local title="$1"
    echo ""
    echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    printf "${BOLD}${BLUE}║  %-60s║${NC}\n" "$title"
    echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "=== $title ===" >> "$LOG_FILE" 2>/dev/null
}
# ── Detect public IP — works on AWS, Azure, and bare metal ───────────────────
_get_public_ip() {
    local ip=""
    # AWS EC2 metadata
    ip=$(curl -s --max-time 3 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
    # Azure VM metadata
    [ -z "$ip" ] && ip=$(curl -s --max-time 3 -H "Metadata:true" \
        "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/publicIpAddress?api-version=2021-02-01&format=text" \
        2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
    # Public IP via external service
    [ -z "$ip" ] && ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
    # Local IP fallback
    [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
    echo "$ip"
}

section() {
    echo ""
    echo -e "${BOLD}  ── $1 ──${NC}"
    echo ""
}

# ── Load / save config ────────────────────────────────────────────────────────
load_config() {
    # Defaults — /apps/hibp base for client deployments
    HIBP_DIR="/apps/hibp/hibp-data"
    SERVICE_DIR="/apps/hibp/hibp-service"
    PORT="3001"
    PARALLELISM="16"
    SERVICE_USER="hibpuser"
    DOTNET_DIR="/apps/hibp/dotnet9"
    PINGONE_IPS=""
    ADMIN_IP=""
    NODE_BIN=""
    PYTHON_BIN=""

    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

    # Derived paths
    HASH_FILE="$HIBP_DIR/pwnedpasswords.txt"
    INDEX_FILE="$HIBP_DIR/pwnedpasswords.idx"
    WEAK_FILE="$HIBP_DIR/weak_passwords.txt"
    SERVER_FILE="$SERVICE_DIR/server.js"
    INDEX_BUILDER="$SERVICE_DIR/build_index.py"
}

save_config() {
    cat > "$CONFIG_FILE" << EOF
# HIBP Deploy Configuration — saved $(date)
# Edit this file or re-run: ./hibp_deploy.sh config
HIBP_DIR="$HIBP_DIR"
SERVICE_DIR="$SERVICE_DIR"
PORT="$PORT"
PARALLELISM="$PARALLELISM"
SERVICE_USER="$SERVICE_USER"
DOTNET_DIR="$DOTNET_DIR"
PINGONE_IPS="$PINGONE_IPS"
ADMIN_IP="$ADMIN_IP"
NODE_BIN="$NODE_BIN"
PYTHON_BIN="$PYTHON_BIN"
EOF
    success "Configuration saved to $CONFIG_FILE"
}

# ═════════════════════════════════════════════════════════════════════════════
#  CONFIGURATION WIZARD
#  Asks for paths and settings — saves to hibp_deploy.config
#  Only runs on first deployment. Re-run with: ./hibp_deploy.sh config
# ═════════════════════════════════════════════════════════════════════════════
cmd_config() {
    header "Configuration Wizard"

    echo -e "  This wizard configures the deployment paths and settings."
    echo -e "  Press ${CYAN}Enter${NC} to accept defaults shown in ${CYAN}[brackets]${NC}."
    echo ""

    # Show disk space to help choose paths
    echo -e "  ${BOLD}Current disk space:${NC}"
    df -h | grep -v tmpfs | grep -v devtmpfs | sed 's/^/    /'
    echo ""
    warn "You need at least 120GB free for:"
    desc "HIBP hash file:        ~88GB"
    desc "Binary search index:   ~16GB"
    desc "Weak word list:        ~4MB (50k words)"
    desc "Node.js + dependencies: ~50MB"
    echo ""

    echo -e "  ${BOLD}Step 1 of 4 — Install Paths${NC}"
    desc "Defaults use /apps/hibp — mounted on /apps which has the required disk space"
    desc "Where to store the HIBP hash file, index, and weak word list"
    ask "Data directory (needs 120GB+ free)" "/apps/hibp/hibp-data"
    HIBP_DIR="$REPLY"

    desc "Where to install server.js, scripts, and logs"
    ask "Service directory" "/apps/hibp/hibp-service"
    SERVICE_DIR="$REPLY"
    echo ""

    echo -e "  ${BOLD}Step 2 of 4 — Server Settings${NC}"
    ask "API port" "3001"
    PORT="$REPLY"

    ask "Download threads (more = faster HIBP download)" "16"
    PARALLELISM="$REPLY"

    desc "Service runs as hibpuser — dedicated account with access only to /apps/hibp"
    desc "Run ./hibp_deploy.sh create-user first to create hibpuser automatically"
    ask "Service user" "hibpuser"
    SERVICE_USER="$REPLY"
    echo ""

    echo -e "  ${BOLD}Step 3 of 4 — dotnet9 Path${NC}"
    desc ".NET 9 SDK is required to run the HIBP downloader tool"
    desc "Installed in a dedicated directory — no system-wide changes"
    ask "dotnet9 install directory" "/apps/hibp/dotnet9"
    DOTNET_DIR="$REPLY"
    echo ""

    echo -e "  ${BOLD}Step 4 of 4 — PingOne DaVinci IP Restriction${NC}"
    echo ""
    desc "WHAT THIS DOES:"
    desc "  Locks /check and /checkweak to PingOne outbound IPs only"
    desc "  Anyone else hitting the endpoint gets 403 Forbidden immediately"
    desc "  /health stays open for monitoring tools"
    desc "  Two restriction layers: firewalld (OS) + nginx allow/deny (app)"
    echo ""
    desc "HOW TO FIND YOUR PINGONE OUTBOUND IPs:"
    desc "  Option A — from your logs after a DaVinci call fires:"
    desc "    tail -f ~/hibp-service/logs/hibp-\$(date +%Y-%m-%d).log"
    desc "    The IP column shows the PingOne outbound IP"
    desc "  Option B — Ping Identity Support portal:"
    desc "    https://support.pingidentity.com → search PingOne IP Addresses"
    desc "    Look for: Outbound section, your region (US East / EU etc)"
    desc ""
    desc "FROM YOUR LIVE TRAFFIC LOGS — PingOne uses: 3.235.0.0/16 (US East)"
    desc "FORMAT: comma-separated CIDR — e.g. 3.235.0.0/16,52.206.0.0/16"
    ask "PingOne outbound IP ranges (blank = all IPs for testing)" "3.235.0.0/16"
    PINGONE_IPS="$REPLY"
    echo ""
    desc "YOUR OFFICE/VPN IP FOR TESTING:"
    desc "  Add your own IP so you can still curl/test directly"
    desc "  Without this your Mac curls will also get 403 Forbidden"
    detected_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "")
    [ -n "$detected_ip" ] && desc "  Detected your current IP: $detected_ip"
    ask "Your office/VPN IP for admin testing (blank = skip)" "${detected_ip}/32"
    ADMIN_IP="$REPLY"
    echo ""

    # Auto-detect tool paths
    NODE_BIN=$(command -v node 2>/dev/null || echo "")
    PYTHON_BIN=$(command -v python3 2>/dev/null || echo "/usr/bin/python3")

    # Summary
    echo -e "  ${BOLD}Configuration Summary:${NC}"
    echo ""
    printf "  %-30s ${GREEN}%s${NC}\n" "Data directory:"        "$HIBP_DIR"
    printf "  %-30s ${GREEN}%s${NC}\n" "Service directory:"     "$SERVICE_DIR"
    printf "  %-30s %s\n"              "API port:"              "$PORT"
    printf "  %-30s %s\n"              "Download threads:"      "$PARALLELISM"
    printf "  %-30s %s\n"              "Service user:"          "$SERVICE_USER"
    printf "  %-30s %s\n"              "dotnet9 directory:"     "$DOTNET_DIR"
    printf "  %-30s %s\n"              "PingOne IPs:"           "${PINGONE_IPS:-ALL (testing mode)}"
    printf "  %-30s %s\n"              "Admin/office IP:"       "${ADMIN_IP:-none set}"
    printf "  %-30s %s\n"              "Config file:"           "$CONFIG_FILE"
    echo ""

    ask "Save this configuration?" "y"
    [[ "$REPLY" =~ ^[Yy]$ ]] || { warn "Cancelled — nothing saved"; exit 0; }

    save_config
    load_config
}

# ═════════════════════════════════════════════════════════════════════════════
#  PREREQUISITES CHECK AND INSTALL
#  Checks every required tool. Installs anything missing automatically.
#  Run this first on any new server before deployment.
#
#  Checks:
#    sudo         — required for package installation and service management
#    dnf/yum      — RHEL package manager
#    Node.js 20   — runs the HIBP API server (auto-installs via NodeSource)
#    Python3      — builds the binary search index
#    libicu       — Unicode library required by .NET 9 (MUST install before dotnet)
#    nginx        — HTTPS proxy (required for DaVinci mixed content policy)
#    firewalld    — RHEL firewall manager
#    curl/wget/bc — utilities used by the scripts
#    disk space   — needs 120GB+ free
#    internet     — ONE-TIME check for HIBP download (not needed after download)
# ═════════════════════════════════════════════════════════════════════════════
cmd_prereqs() {
    header "Prerequisites Check and Install"
    desc "Checking and installing all required components"
    desc "Anything missing is installed automatically"
    echo ""

    if command -v dnf &>/dev/null; then PKG_MGR="dnf"
    elif command -v yum &>/dev/null; then PKG_MGR="yum"
    else error "No supported package manager found (dnf or yum required — RHEL/CentOS only)"; fi

    # ── sudo ─────────────────────────────────────────────────────────────────
    section "System access"
    log "Checking sudo access..."
    sudo -n true 2>/dev/null || sudo true || error "sudo access required — run as a user with sudo privileges"
    success "sudo: available"
    success "Package manager: $PKG_MGR"

    # ── libicu — MUST be before dotnet ────────────────────────────────────────
    section "Dependencies"
    log "Checking libicu (.NET dependency)..."
    desc "libicu provides Unicode/globalization support"
    desc "CRITICAL: must be installed BEFORE .NET 9 or dotnet crashes on RHEL"
    if rpm -q libicu &>/dev/null 2>&1; then
        success "libicu: $(rpm -q libicu)"
    else
        log "Installing libicu..."
        sudo $PKG_MGR install -y libicu > /dev/null 2>&1
        rpm -q libicu &>/dev/null 2>&1 && success "libicu installed" || warn "libicu install may have failed"
    fi

    # ── Python3 ───────────────────────────────────────────────────────────────
    log "Checking Python3..."
    desc "Python3 is used to build the binary search index (build_index.py)"
    desc "Also used by this script to write server.js with correct file paths"
    if command -v python3 &>/dev/null; then
        PYTHON_BIN=$(command -v python3)
        success "Python3: $PYTHON_BIN ($(python3 --version 2>&1))"
    else
        log "Installing Python3..."
        sudo $PKG_MGR install -y python3 > /dev/null 2>&1
        PYTHON_BIN=$(command -v python3)
        success "Python3 installed: $(python3 --version 2>&1)"
    fi

    # ── Node.js ───────────────────────────────────────────────────────────────
    section "Node.js"
    log "Checking Node.js..."
    desc "Node.js runs the HIBP API server (server.js)"
    desc "Requires version 16+ — installing 20 LTS via NodeSource repository"
    desc "NodeSource provides current Node.js packages for RHEL/CentOS"
    if command -v node &>/dev/null; then
        NODE_BIN=$(command -v node)
        NODE_VER=$(node --version | tr -d 'v' | cut -d. -f1)
        success "Node.js: $NODE_BIN ($(node --version))"
        if [ "${NODE_VER:-0}" -lt 16 ] 2>/dev/null; then
            warn "Version too old — upgrading to Node.js 20..."
            _install_nodejs
        fi
    else
        log "Node.js not found — installing Node.js 20 LTS..."
        _install_nodejs
    fi

    # ── npm ───────────────────────────────────────────────────────────────────
    log "Checking npm..."
    desc "npm installs the express web framework used by server.js"
    command -v npm &>/dev/null && success "npm: $(npm --version)" || {
        warn "npm not found — reinstalling Node.js..."
        _install_nodejs
    }

    # ── nginx ─────────────────────────────────────────────────────────────────
    section "nginx (HTTPS proxy)"
    log "Checking nginx..."
    desc "nginx is REQUIRED — DaVinci runs on HTTPS and blocks all HTTP calls"
    desc "nginx provides HTTPS so DaVinci browser JavaScript can reach the API"
    desc "Without nginx you get: Mixed Content error in browser — API unreachable"
    if command -v nginx &>/dev/null; then
        success "nginx: $(nginx -v 2>&1 | head -1)"
    else
        log "Installing nginx..."
        sudo $PKG_MGR install -y nginx > /dev/null 2>&1
        success "nginx installed"
    fi

    # ── Utilities ─────────────────────────────────────────────────────────────
    section "Utilities"
    log "Installing utilities (curl, wget, bc, tar, unzip)..."
    sudo $PKG_MGR install -y curl wget bc tar unzip > /dev/null 2>&1
    success "curl, wget, bc, tar, unzip installed"

    # ── firewalld ─────────────────────────────────────────────────────────────
    log "Checking firewalld..."
    desc "firewalld controls which ports accept incoming connections"
    command -v firewall-cmd &>/dev/null || sudo $PKG_MGR install -y firewalld > /dev/null 2>&1
    sudo systemctl enable firewalld --now > /dev/null 2>&1
    success "firewalld: running"

    # ── Disk space ────────────────────────────────────────────────────────────
    section "Resources"
    log "Checking disk space..."
    desc "Need 120GB+ free: hash file (88GB) + index (16GB) + overhead"
    local avail=$(df -BG "${HIBP_DIR:-$HOME}" 2>/dev/null | awk 'NR==2{print $4}' | tr -d 'G' || echo 0)
    if [ "${avail:-0}" -ge 120 ] 2>/dev/null; then
        success "Disk space: ${avail}GB free — sufficient"
    elif [ "${avail:-0}" -ge 20 ] 2>/dev/null; then
        warn "Disk space: ${avail}GB free — may not be enough (need 120GB+)"
        warn "Check your data directory path in config"
    else
        warn "Disk space: ${avail}GB free — likely insufficient. Check: df -h"
    fi

    # ── Internet connectivity ─────────────────────────────────────────────────
    log "Checking outbound internet connectivity..."
    desc "ONE-TIME check — server needs internet to download the 88GB HIBP hash file"
    desc "After download: server works 100% offline. DaVinci calls YOUR server."
    desc "  Download phase:  EC2/Azure → api.pwnedpasswords.com  (one time, 4-8 hours)"
    desc "  Runtime phase:   DaVinci   → YOUR server              (all lookups local)"
    if curl -s --max-time 5 https://api.pwnedpasswords.com/range/00000 > /dev/null 2>&1; then
        success "Internet: reachable — HIBP download will work"
    else
        warn "Cannot reach api.pwnedpasswords.com — check outbound firewall/security group"
        warn "This only affects the download step — runtime lookups are fully offline"
    fi

    # ── Update config with detected paths ─────────────────────────────────────
    NODE_BIN=$(command -v node 2>/dev/null || echo "")
    PYTHON_BIN=$(command -v python3 2>/dev/null || echo "/usr/bin/python3")
    [ -f "$CONFIG_FILE" ] && {
        sed -i "s|NODE_BIN=.*|NODE_BIN=\"$NODE_BIN\"|" "$CONFIG_FILE" 2>/dev/null
        sed -i "s|PYTHON_BIN=.*|PYTHON_BIN=\"$PYTHON_BIN\"|" "$CONFIG_FILE" 2>/dev/null
    }
    load_config

    echo ""
    echo -e "  ${BOLD}Prerequisites Summary:${NC}"
    printf "  %-20s %s\n" "Python3:"    "$PYTHON_BIN ($(python3 --version 2>&1))"
    printf "  %-20s %s\n" "Node.js:"    "$NODE_BIN ($(node --version 2>/dev/null))"
    printf "  %-20s %s\n" "npm:"        "$(npm --version 2>/dev/null)"
    printf "  %-20s %s\n" "libicu:"     "$(rpm -q libicu 2>/dev/null)"
    printf "  %-20s %s\n" "nginx:"      "$(nginx -v 2>&1 | head -1)"
    printf "  %-20s %s\n" "firewalld:"  "$(systemctl is-active firewalld 2>/dev/null)"
    echo ""
    success "Prerequisites check complete — ready to deploy"
}

_install_nodejs() {
    log "Installing Node.js 20 LTS via NodeSource..."
    if command -v dnf &>/dev/null; then PKG_MGR="dnf"; else PKG_MGR="yum"; fi
    curl -fsSL https://rpm.nodesource.com/setup_20.x | sudo bash - > /dev/null 2>&1
    sudo $PKG_MGR install -y nodejs > /dev/null 2>&1
    if command -v node &>/dev/null; then
        NODE_BIN=$(command -v node)
        success "Node.js 20 installed: $NODE_BIN ($(node --version))"
    else
        error "Node.js install failed — check internet connectivity"
    fi
    [ -f "$CONFIG_FILE" ] && sed -i "s|NODE_BIN=.*|NODE_BIN=\"$NODE_BIN\"|" "$CONFIG_FILE" 2>/dev/null
}


# ═════════════════════════════════════════════════════════════════════════════
#  STEP 0 — CREATE SERVICE USER
#  Creates hibpuser as a dedicated service account with access ONLY to
#  the /apps/hibp directory. This follows least-privilege principle:
#
#  What hibpuser CAN do:
#    - Read/write /apps/hibp and all subdirectories
#    - Run the Node.js server process
#    - Run the deploy script from its home directory
#
#  What hibpuser CANNOT do:
#    - Login with a password (locked password)
#    - Access any directory outside /apps/hibp
#    - Run sudo commands (except specific deployment commands via sudoers)
#    - Modify system files
#
#  Sudoers rule grants ONLY what deployment needs:
#    systemctl  — start/stop/enable the hibp service
#    nginx      — restart nginx after config changes
#    firewall-cmd — manage firewall rules for port 443/3001
#    setsebool  — SELinux fix for nginx proxy on RHEL
#    chown/chmod/mkdir — create and own deployment directories
# ═════════════════════════════════════════════════════════════════════════════
step_create_user() {
    header "Step 0 — Create Service User (hibpuser)"
    echo ""
    desc "Creating dedicated service account: hibpuser"
    desc "Home directory: /apps/hibp (owns everything here)"
    desc "No password login — can only be accessed via: sudo su - hibpuser"
    desc "Sudoers rule grants only deployment-required commands"
    echo ""

    local HIBP_HOME="/apps/hibp"
    local HIBP_USER="hibpuser"
    local SUDOERS_FILE="/etc/sudoers.d/hibpuser"

    # ── Create user if not exists ─────────────────────────────────────────────
    if id "$HIBP_USER" &>/dev/null 2>&1; then
        success "User already exists: $HIBP_USER"
    else
        log "Creating user: $HIBP_USER ..."
        desc "System account (-r) with home at /apps/hibp (-d)"
        desc "Shell set to /bin/bash — required to run deploy script"
        sudo useradd \
            -r \
            -m \
            -d "$HIBP_HOME" \
            -s /bin/bash \
            -c "HIBP Password Validation Service Account" \
            "$HIBP_USER"
        success "User created: $HIBP_USER"
    fi

    # ── Lock password — no direct login ──────────────────────────────────────
    log "Locking password login for $HIBP_USER ..."
    desc "Prevents direct SSH or console login with password"
    desc "Account can only be accessed via: sudo su - hibpuser"
    sudo passwd -l "$HIBP_USER" > /dev/null 2>&1
    success "Password login locked — access only via sudo su"

    # ── Create and own directories ────────────────────────────────────────────
    section "Creating directories under /apps/hibp"
    desc "All HIBP files live under /apps/hibp — hibpuser owns everything here"

    for DIR in "$HIBP_HOME" "$HIBP_HOME/hibp-data" "$HIBP_HOME/hibp-service" "$HIBP_HOME/dotnet9" "$HIBP_HOME/hibp-service/logs"; do
        sudo mkdir -p "$DIR"
        sudo chown "$HIBP_USER:$HIBP_USER" "$DIR"
        sudo chmod 755 "$DIR"
        success "Created: $DIR"
    done

    # ── Sudoers rule — least privilege ────────────────────────────────────────
    section "Configuring sudoers rule"
    desc "Grants hibpuser ONLY the commands needed for deployment"
    desc "No full sudo — just the specific binaries required"
    echo ""

    sudo tee "$SUDOERS_FILE" > /dev/null << SUDOEOF
# hibpuser sudoers rule — HIBP Password Validation Service
# Generated by hibp_deploy.sh on $(date)
# Grants ONLY deployment-required commands — no full sudo access

# Service management
hibpuser ALL=(ALL) NOPASSWD: /bin/systemctl start hibp
hibpuser ALL=(ALL) NOPASSWD: /bin/systemctl stop hibp
hibpuser ALL=(ALL) NOPASSWD: /bin/systemctl restart hibp
hibpuser ALL=(ALL) NOPASSWD: /bin/systemctl enable hibp
hibpuser ALL=(ALL) NOPASSWD: /bin/systemctl disable hibp
hibpuser ALL=(ALL) NOPASSWD: /bin/systemctl status hibp
hibpuser ALL=(ALL) NOPASSWD: /bin/systemctl daemon-reload

# nginx — HTTPS proxy management
hibpuser ALL=(ALL) NOPASSWD: /usr/sbin/nginx
hibpuser ALL=(ALL) NOPASSWD: /bin/systemctl start nginx
hibpuser ALL=(ALL) NOPASSWD: /bin/systemctl stop nginx
hibpuser ALL=(ALL) NOPASSWD: /bin/systemctl restart nginx
hibpuser ALL=(ALL) NOPASSWD: /bin/systemctl enable nginx
hibpuser ALL=(ALL) NOPASSWD: /bin/systemctl status nginx

# SSL certificate directory
hibpuser ALL=(ALL) NOPASSWD: /bin/mkdir -p /etc/nginx/ssl
hibpuser ALL=(ALL) NOPASSWD: /usr/bin/openssl *
hibpuser ALL=(ALL) NOPASSWD: /bin/cp * /etc/nginx/ssl/*
hibpuser ALL=(ALL) NOPASSWD: /bin/chmod 600 /etc/nginx/ssl/*

# nginx config
hibpuser ALL=(ALL) NOPASSWD: /usr/bin/tee /etc/nginx/conf.d/hibp.conf
hibpuser ALL=(ALL) NOPASSWD: /bin/tee /etc/nginx/conf.d/hibp.conf

# firewall — port management
hibpuser ALL=(ALL) NOPASSWD: /usr/bin/firewall-cmd *

# SELinux — nginx proxy fix (RHEL)
hibpuser ALL=(ALL) NOPASSWD: /usr/sbin/setsebool -P httpd_can_network_connect 1

# systemd service file
hibpuser ALL=(ALL) NOPASSWD: /usr/bin/tee /etc/systemd/system/hibp.service
hibpuser ALL=(ALL) NOPASSWD: /bin/tee /etc/systemd/system/hibp.service

# Directory ownership for deployment paths
hibpuser ALL=(ALL) NOPASSWD: /bin/mkdir -p /apps/hibp*
hibpuser ALL=(ALL) NOPASSWD: /bin/chown -R hibpuser\:hibpuser /apps/hibp*
hibpuser ALL=(ALL) NOPASSWD: /bin/chmod * /apps/hibp*

# Package installation (prereqs step only)
hibpuser ALL=(ALL) NOPASSWD: /usr/bin/dnf install *
hibpuser ALL=(ALL) NOPASSWD: /usr/bin/yum install *
hibpuser ALL=(ALL) NOPASSWD: /bin/rpm --import *
SUDOEOF

    # Validate sudoers syntax
    sudo visudo -c -f "$SUDOERS_FILE" > /dev/null 2>&1 \
        && success "Sudoers rule created: $SUDOERS_FILE" \
        || {
            warn "Sudoers syntax check failed — removing and using manual approach"
            sudo rm -f "$SUDOERS_FILE"
            warn "Run manually: sudo visudo -f /etc/sudoers.d/hibpuser"
        }

    # ── Print access instructions ─────────────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}How to access hibpuser:${NC}"
    info "  sudo su - hibpuser"
    echo ""
    echo -e "  ${BOLD}What hibpuser can access:${NC}"
    desc "/apps/hibp/           — full read/write"
    desc "/apps/hibp/hibp-data/ — hash file, index, weak word list"
    desc "/apps/hibp/hibp-service/ — server.js, logs, npm packages"
    desc "/apps/hibp/dotnet9/   — .NET SDK"
    echo ""
    echo -e "  ${BOLD}What hibpuser CANNOT access:${NC}"
    desc "Any directory outside /apps/hibp"
    desc "Other system users home directories"
    desc "System configuration files (except via specific sudoers commands)"
    echo ""
    success "hibpuser setup complete"
}

# ═════════════════════════════════════════════════════════════════════════════
#  STEP 1 — CREATE USER AND DIRECTORIES
#  Creates the directory structure for all HIBP files.
#  Directories are owned by the current user to prevent permission errors
#  when scripts write server.js, build_index.py, and other files.
# ═════════════════════════════════════════════════════════════════════════════
step_create_dirs() {
    header "Step 1 — Create Directories"
    desc "Creating directory structure for HIBP files"
    desc "Directories owned by $SERVICE_USER — prevents permission denied errors"
    echo ""

    log "Creating data directory: $HIBP_DIR"
    desc "This is where the 88GB hash file, 16GB index, and weak word list will live"
    sudo mkdir -p "$HIBP_DIR"
    sudo chown -R "$SERVICE_USER:$SERVICE_USER" "$HIBP_DIR" 2>/dev/null || \
    sudo chown -R "$USER:$USER" "$HIBP_DIR"
    sudo chmod 755 "$HIBP_DIR"
    success "Created: $HIBP_DIR"

    log "Creating service directory: $SERVICE_DIR"
    desc "This is where server.js, build_index.py, logs, and npm packages live"
    sudo mkdir -p "$SERVICE_DIR/logs"
    sudo chown -R "$USER:$USER" "$SERVICE_DIR"
    sudo chmod 755 "$SERVICE_DIR"
    success "Created: $SERVICE_DIR"

    # Check disk space at chosen path
    local avail=$(df -BG "$HIBP_DIR" | awk 'NR==2{print $4}' | tr -d 'G' || echo 0)
    if [ "${avail:-0}" -lt 120 ] 2>/dev/null; then
        warn "Only ${avail}GB free at $HIBP_DIR — need 120GB+ for hash file + index"
        ask "Continue anyway?" "n"
        [[ "$REPLY" =~ ^[Yy]$ ]] || error "Choose a path with more disk space: ./hibp_deploy.sh config"
    else
        success "${avail}GB available at $HIBP_DIR"
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  STEP 2 — CREATE WEAK PASSWORDS FILE
#  Creates the server-side weak password list with 50,000+ words.
#  This file is stored on the server and NEVER exposed to the browser.
#  The browser only sees: POST /checkweak → { "weak": true/false }
#  The actual words are never transmitted.
# ═════════════════════════════════════════════════════════════════════════════
step_create_weak_list() {
    header "Step 2 — Create Weak Password List"
    desc "Creating $WEAK_FILE"
    desc "This file is stored server-side — words are NEVER sent to the browser"
    desc "Browser only sees: POST /checkweak → { weak: true/false, category: '...' }"
    desc "File is read fresh on every request — edit anytime, no restart needed"
    echo ""

    log "Writing weak_passwords.txt to server..."
    desc "File contains words in sections — sections used to categorize error messages"
    desc "e.g. 'elc' in section 'company names' → error says 'company name' not just 'blocked'"

    cat > "$WEAK_FILE" << 'WORDLIST'
# =============================================================================
#  ELC Weak Password Blocklist
#  Stored on server — NOT visible in browser JS, source, or network trace
#
#  FORMAT:
#    One word per line, lowercase
#    Comment lines start with #
#    Section headers start with # --
#    Whole-word match: "elc" blocks "ELC@2024" but NOT "electric"
#    Numbers and special chars act as word boundaries
#
#  EDITING:
#    Add words: one per line in the relevant section
#    Remove words: delete the line
#    No server restart needed — file is read on every request
# =============================================================================

# -- ELC company + brand names ------------------------------------------------
elc
estee
lauder
esteelauder
clinique
bobbi
brown
bobbibrownr
lamermac
lamer
origins
aveda
bumble
bumbleandbumble
darphin
glamglow
kilian
jomalondmilk
jomalone
tomford
smashbox
prescriptives
aramis
labseries
beautybank
flirt
goodskin
grassroots
ojon
rodan
fields
ermenegildo
zegna
maccosmetics
origins

# -- Common weak passwords ----------------------------------------------------
welcome
password
password1
password2
password3
passwd
passw0rd
pass
secret
letmein
login
access
master
admin
admin1
admin123
administrator
root
superuser
sysadmin
user
user1
guest
default
changeme
change
newpassword
mypassword
iloveyou
iloveU
ilove
trustno1
letmein1
abc123
abc1234

# -- People / names -----------------------------------------------------------
michael
michelle
jennifer
jessica
thomas
charlie
andrew
joshua
daniel
stephen
matthew
steven
christopher
amanda
melissa
jordan
taylor
morgan

# -- Common phrases -----------------------------------------------------------
hello
shadow
ninja
dragon
monkey
master
sunshine
princess
baseball
football
soccer
hockey
basketball
tennis
swimming
guitar
piano
music
coffee
cheese
chocolate
forever
nothing
everest
rainbow
diamond
silver
golden
thunder
lightning
starwars
batman
superman
spiderman
ironman
captain
avenger
wizard
hunter
killer
warrior
legend
champion
winner

# -- Keyboard walk patterns ---------------------------------------------------
qwerty
qwerty1
qwerty123
qwertyuiop
qwertyuiop1
asdfgh
asdfghjkl
zxcvbn
qweasd
qazwsx
qazxsw
wsxedc
rfvtgb
yhnujm
1qaz2wsx
1qaz
2wsx
3edc
zxcvbnm
mnbvcxz
poiuytrewq
lkjhgfdsa

# -- Numeric sequences --------------------------------------------------------
123456
1234567
12345678
123456789
1234567890
0987654321
987654321
12345
123456789
111111
111111a
222222
333333
444444
555555
666666
777777
888888
999999
000000
112233
123123
121212
123321
654321
1111
2222
3333
4444
5555
6666
7777
8888
9999
0000
1234
4321
6789

# -- Alphabetic sequences -----------------------------------------------------
abcdef
abcdefg
abcdefgh
abcdefghi
abcdefghij
abc123
abc1234
abcd1234
aaaa
bbbb
cccc
dddd
eeee
ffff

# -- Seasonal patterns --------------------------------------------------------
spring
summer
autumn
fall
winter
springtime
summertime
wintertime

# -- Month names --------------------------------------------------------------
january
february
march
april
may
june
july
august
september
october
november
december
jan
feb
mar
apr
jun
jul
aug
sep
oct
nov
dec

# -- Year patterns ------------------------------------------------------------
2000
2001
2002
2003
2004
2005
2006
2007
2008
2009
2010
2011
2012
2013
2014
2015
2016
2017
2018
2019
2020
2021
2022
2023
2024
2025
2026
2027
2028
2029
2030

# -- Day / time patterns ------------------------------------------------------
monday
tuesday
wednesday
thursday
friday
saturday
sunday
weekend
midnight
morning
evening
tonight

# -- Corporate / IT words -----------------------------------------------------
work
office
corporate
company
employee
staff
helpdesk
support
service
network
system
server
database
manager
director
executive
intern
trainee
temp
contract
hr
finance
legal
sales
marketing
engineer
developer
analyst
consultant
accountant

# -- Technology words ---------------------------------------------------------
internet
computer
windows
linux
android
iphone
apple
google
facebook
twitter
instagram
linkedin
microsoft
amazon
netflix

# -- Sports teams (common) ----------------------------------------------------
yankees
redsox
lakers
celtics
cowboys
patriots
eagles
giants
knicks
bulls

# -- Common patterns with symbols ---------------------------------------------
pass1
pass12
pass123
pwd123
login1
admin1
test1
test12
test123
user1
user12
user123
qwer1234
asdf1234
zxcv1234
welcome1
welcome12
welcome123
WORDLIST

    local count=$(grep -v '^#' "$WEAK_FILE" | grep -v '^$' | wc -l)
    success "Created $WEAK_FILE ($count words)"
    info "To add more words: nano $WEAK_FILE"
    info "No restart needed — file is read on every /checkweak request"
}

# ═════════════════════════════════════════════════════════════════════════════
#  STEP 3 — INSTALL DOTNET 9
# ═════════════════════════════════════════════════════════════════════════════
step_install_dotnet() {
    header "Step 3 — Install .NET 9 SDK"
    desc "The HIBP downloader tool is a .NET application — requires .NET 9 runtime"
    desc "libicu was installed in prereqs step — required for .NET on RHEL"
    desc "Installing to $DOTNET_DIR — isolated from any other .NET installations"
    echo ""

    if [ -f "$DOTNET_DIR/dotnet" ]; then
        success ".NET already installed: $($DOTNET_DIR/dotnet --version 2>/dev/null)"
        export DOTNET_ROOT="$DOTNET_DIR"
        export PATH="$DOTNET_DIR:$HOME/.dotnet/tools:$PATH"
        return 0
    fi

    log "Downloading Microsoft .NET install script..."
    desc "Using Microsoft's official dotnet-install.sh — the recommended install method"
    curl -Lo /tmp/dotnet-install.sh https://dot.net/v1/dotnet-install.sh
    chmod +x /tmp/dotnet-install.sh

    log "Installing .NET 9 SDK to $DOTNET_DIR ..."
    desc "This downloads ~200MB — takes 1-2 minutes"
    mkdir -p "$DOTNET_DIR"
    /tmp/dotnet-install.sh --channel 9.0 --install-dir "$DOTNET_DIR"

    [ -f "$DOTNET_DIR/dotnet" ] || error ".NET 9 install failed — check internet and that libicu is installed"
    success ".NET 9 installed: $($DOTNET_DIR/dotnet --version)"

    export DOTNET_ROOT="$DOTNET_DIR"
    export PATH="$DOTNET_DIR:$HOME/.dotnet/tools:$PATH"

    # Add to shell profile for future SSH sessions
    grep -q "DOTNET_ROOT=$DOTNET_DIR" "$HOME/.bashrc" 2>/dev/null || cat >> "$HOME/.bashrc" << EOF

# .NET 9 for HIBP downloader — added by hibp_deploy.sh
export DOTNET_ROOT=$DOTNET_DIR
export PATH=\$DOTNET_ROOT:/apps/hibp/.dotnet/tools:\$PATH
EOF
    success "dotnet added to ~/.bashrc — available in future SSH sessions"
}

# ═════════════════════════════════════════════════════════════════════════════
#  STEP 4 — INSTALL HIBP DOWNLOADER
# ═════════════════════════════════════════════════════════════════════════════
step_install_downloader() {
    header "Step 4 — Install HIBP Downloader"
    desc "haveibeenpwned-downloader is a .NET CLI tool by Troy Hunt (HaveIBeenPwned founder)"
    desc "Makes ~1 million parallel API calls to download all hash ranges"
    desc "Much faster than any manual approach — handles retry, resume, and merging"
    echo ""

    export DOTNET_ROOT="$DOTNET_DIR"
    export PATH="$DOTNET_DIR:$HOME/.dotnet/tools:$PATH"

    if DOTNET_ROOT="$DOTNET_DIR" haveibeenpwned-downloader --help &>/dev/null 2>&1; then
        success "haveibeenpwned-downloader already installed"
        return 0
    fi

    log "Installing haveibeenpwned-downloader as a dotnet global tool..."
    DOTNET_ROOT="$DOTNET_DIR" "$DOTNET_DIR/dotnet" tool uninstall --global haveibeenpwned-downloader 2>/dev/null || true
    DOTNET_ROOT="$DOTNET_DIR" "$DOTNET_DIR/dotnet" tool install --global haveibeenpwned-downloader
    export PATH="$PATH:$HOME/.dotnet/tools"

    DOTNET_ROOT="$DOTNET_DIR" haveibeenpwned-downloader --help &>/dev/null 2>&1 \
        && success "haveibeenpwned-downloader installed successfully" \
        || error "Installation failed — check .NET version and libicu"
}

# ═════════════════════════════════════════════════════════════════════════════
#  STEP 5 — DOWNLOAD HIBP HASH FILE
# ═════════════════════════════════════════════════════════════════════════════
step_download() {
    header "Step 5 — Download HIBP Hash File"
    desc "Downloads all 2 billion+ SHA1 password hashes from api.pwnedpasswords.com"
    desc "Output: $HASH_FILE (~88GB)"
    desc "Using $PARALLELISM parallel download threads"
    desc "-o flag = resume mode — safe to Ctrl+C and restart"
    echo ""
    warn "This will take 4-8 hours — recommended to run in a screen session"
    info "  screen -S hibp          (start detachable session)"
    info "  ./hibp_deploy.sh download"
    info "  Ctrl+A then D           (detach — download continues)"
    info "  screen -r hibp          (reconnect later to check progress)"
    echo ""

    export DOTNET_ROOT="$DOTNET_DIR"
    export PATH="$DOTNET_DIR:$HOME/.dotnet/tools:$PATH"

    DOTNET_ROOT="$DOTNET_DIR" haveibeenpwned-downloader --help &>/dev/null 2>&1 || {
        warn "Downloader not found — installing..."
        step_install_dotnet
        step_install_downloader
    }

    local avail=$(df -BG "$HIBP_DIR" | awk 'NR==2{print $4}' | tr -d 'G' || echo 0)
    [ "${avail:-0}" -lt 100 ] 2>/dev/null && \
        error "Only ${avail}GB free at $HIBP_DIR — need 100GB+ for the hash file"

    sudo chown -R "$USER:$USER" "$HIBP_DIR" 2>/dev/null || true

    log "Starting download... (Ctrl+C pauses — re-run to resume)"
    DOTNET_ROOT="$DOTNET_DIR" haveibeenpwned-downloader \
        "$HIBP_DIR/pwnedpasswords" \
        -p "$PARALLELISM" \
        -o

    echo ""
    success "Download complete!"
    ls -lh "$HASH_FILE"
    log "Counting lines (takes ~1 minute)..."
    wc -l "$HASH_FILE"
}

# ═════════════════════════════════════════════════════════════════════════════
#  STEP 6 — BUILD BINARY SEARCH INDEX
# ═════════════════════════════════════════════════════════════════════════════
step_build_index() {
    header "Step 6 — Build Binary Search Index"
    desc "Reads every line of $HASH_FILE and records byte position of each line"
    desc "Enables O(log N) binary search — ~31 reads to find any of 2 billion hashes"
    desc "Without index: grep scans 88GB = 30+ seconds"
    desc "With index: binary search = 10-20ms  (150,000x faster)"
    desc "Index size: ~16GB | Build time: 30-90 minutes"
    echo ""

    [ ! -f "$HASH_FILE" ] && \
        error "Hash file not found: $HASH_FILE\nRun: ./hibp_deploy.sh download"

    sudo chown -R "$USER:$USER" "$SERVICE_DIR" 2>/dev/null || true

    log "Writing index builder script..."
    cat > "$INDEX_BUILDER" << 'PYEOF'
#!/usr/bin/env python3
"""
HIBP Binary Index Builder
Reads every line of the hash file and records its byte offset (position).
Each offset is stored as an 8-byte uint64 little-endian integer.
"""
import struct, os, time, sys

HASH_FILE  = os.environ.get('HASH_FILE', '')
INDEX_FILE = os.environ.get('INDEX_FILE', '')

def build():
    if not os.path.exists(HASH_FILE):
        print(f"ERROR: {HASH_FILE} not found")
        sys.exit(1)

    hash_size = os.path.getsize(HASH_FILE)
    print(f"  Hash file  : {HASH_FILE}")
    print(f"  File size  : {hash_size / 1e9:.2f} GB")
    print(f"  Index file : {INDEX_FILE}")
    print(f"  Started    : {time.strftime('%H:%M:%S')}")
    print()

    start = time.time()
    count = 0
    last_pct = -1

    with open(HASH_FILE, 'rb') as hf, \
         open(INDEX_FILE, 'wb', buffering=64*1024*1024) as idx:
        while True:
            offset = hf.tell()
            line   = hf.readline()
            if not line: break
            idx.write(struct.pack('<Q', offset))
            count += 1

            pct = int((offset / hash_size) * 100)
            if pct != last_pct:
                elapsed = time.time() - start
                rate    = count / elapsed if elapsed > 0 else 0
                eta     = ((hash_size - offset) / (offset / elapsed)) if offset > 0 else 0
                print(f"\r  {pct:3d}%  |  {count/1e6:.1f}M lines  |  "
                      f"{rate/1e6:.2f}M/sec  |  "
                      f"ETA {int(eta//60)}m {int(eta%60)}s     ",
                      end='', flush=True)
                last_pct = pct

    elapsed  = time.time() - start
    idx_size = os.path.getsize(INDEX_FILE)
    print(f"\n\n  Done!")
    print(f"  Lines   : {count:,}")
    print(f"  Index   : {idx_size / 1e9:.2f} GB")
    print(f"  Time    : {int(elapsed//60)}m {int(elapsed%60)}s")
    print(f"  Finished: {time.strftime('%H:%M:%S')}")

if __name__ == '__main__':
    build()
PYEOF

    chmod +x "$INDEX_BUILDER"
    success "Index builder written to $INDEX_BUILDER"

    log "Building index — this takes 30-90 minutes..."
    warn "Run in screen to survive SSH disconnects: screen -S hibp-index"
    echo ""
    HASH_FILE="$HASH_FILE" INDEX_FILE="$INDEX_FILE" "$PYTHON_BIN" "$INDEX_BUILDER"
    success "Index built: $INDEX_FILE"
}

# ═════════════════════════════════════════════════════════════════════════════
#  STEP 7 — INSTALL NODE.JS SERVER
# ═════════════════════════════════════════════════════════════════════════════
step_install_server() {
    header "Step 7 — Install Node.js Server"
    desc "Writing server.js with two endpoints:"
    desc "  POST /check     — checks password against 88GB HIBP hash file"
    desc "  POST /checkweak — checks password against weak_passwords.txt"
    desc "  GET  /health    — monitoring and status endpoint"
    echo ""

    [ -z "$NODE_BIN" ] && NODE_BIN=$(command -v node 2>/dev/null || echo "/usr/bin/node")
    [ ! -f "$NODE_BIN" ] && error "Node.js not found at $NODE_BIN\nRun: ./hibp_deploy.sh prereqs"

    sudo chown -R "$USER:$USER" "$SERVICE_DIR" 2>/dev/null || true
    mkdir -p "$SERVICE_DIR"

    log "Writing server.js..."

    cat > "$SERVICE_DIR/server.js" << 'NODEEOF'
const express = require('express');
const crypto  = require('crypto');
const fs      = require('fs');
const app     = express();
app.use(express.json());

app.use((req, res, next) => {
    res.header('Access-Control-Allow-Origin',  '*');
    res.header('Access-Control-Allow-Methods', 'POST, GET, OPTIONS');
    res.header('Access-Control-Allow-Headers', 'Content-Type, Authorization');
    if (req.method === 'OPTIONS') return res.status(200).end();
    next();
});

const HASH_FILE  = process.env.HASH_FILE  || '';
const INDEX_FILE = process.env.INDEX_FILE || '';
const WEAK_FILE  = process.env.WEAK_FILE  || '';
const PORT       = process.env.PORT       || 3001;

if (!fs.existsSync(HASH_FILE))  { console.error('ERROR: Hash file not found:',  HASH_FILE);  process.exit(1); }
if (!fs.existsSync(INDEX_FILE)) { console.error('ERROR: Index file not found:', INDEX_FILE); process.exit(1); }

const hashFd           = fs.openSync(HASH_FILE,  'r');
const indexFd          = fs.openSync(INDEX_FILE, 'r');
const indexSize        = fs.fstatSync(indexFd).size;
const hashSize         = fs.fstatSync(hashFd).size;
const totalLinesBigInt = BigInt(indexSize) / 8n;
const totalLines       = Number(totalLinesBigInt);

console.log('==============================================');
console.log(' HIBP In-House Validation Service');
console.log(' Hash file  :', HASH_FILE);
console.log(' Hash size  :', (hashSize  / 1e9).toFixed(2), 'GB');
console.log(' Index file :', INDEX_FILE);
console.log(' Index size :', (indexSize / 1e9).toFixed(2), 'GB');
console.log(' Total lines:', totalLines.toLocaleString());
console.log(' Port       : 0.0.0.0:' + PORT);
console.log('==============================================');

const idxBuf  = Buffer.alloc(8);
const lineBuf = Buffer.alloc(256);

function getOffset(nBig) {
    fs.readSync(indexFd, idxBuf, 0, 8, Number(nBig * 8n));
    return idxBuf.readBigUInt64LE(0);
}

function readHashLine(offsetBig) {
    const offset = Number(offsetBig);
    if (offset < 0 || offset >= hashSize) return '';
    const n   = fs.readSync(hashFd, lineBuf, 0, 256, offset);
    const str = lineBuf.slice(0, n).toString('utf8');
    const nl  = str.indexOf('\n');
    return (nl === -1 ? str : str.slice(0, nl)).trim();
}

function findHash(target) {
    target = target.toUpperCase();
    let low = 0n, high = totalLinesBigInt - 1n;
    while (low <= high) {
        const mid    = (low + high) >> 1n;
        const offset = getOffset(mid);
        const line   = readHashLine(offset);
        if (!line) { high = mid - 1n; continue; }
        const colon  = line.indexOf(':');
        const hash   = colon === -1 ? line : line.slice(0, colon);
        if (hash === target) return { found: true, count: colon === -1 ? 0 : (parseInt(line.slice(colon + 1)) || 0) };
        if (hash < target)  low  = mid + 1n;
        else                high = mid - 1n;
    }
    return { found: false, count: 0 };
}

function checkWeakWord(password) {
    let lines;
    try { lines = fs.readFileSync(WEAK_FILE, 'utf8').split('\n'); }
    catch(e) { return { weak: false, category: 'unavailable' }; }

    const words = lines.map(l => l.trim()).filter(l => l.length > 0 && !l.startsWith('#'));
    const lower = password.toLowerCase();

    for (const word of words) {
        try {
            const escaped = word.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
            const pattern = new RegExp('(?<![a-z])' + escaped + '(?![a-z])', 'i');
            if (pattern.test(lower)) {
                return { weak: true, category: 'weak password', word };
            }
        } catch(e) { continue; }
    }
    return { weak: false, category: null };
}

const _stats = { check: 0, checkweak: 0, health: 0, errors: 0, start: Date.now() };

app.use((err, req, res, next) => {
    _stats.errors++;
    console.error('[ERROR]', req.method, req.path, err.message);
    res.status(500).json({ error: err.message, pwned: false, weak: false });
});

app.post('/check', (req, res, next) => {
    try {
        const { password } = req.body;
        if (!password) {
            return res.status(400).json({ error: 'password required' });
        }
        _stats.check++;
        const t0   = process.hrtime.bigint();
        const sha1 = crypto.createHash('sha1').update(password).digest('hex').toUpperCase();
        const r    = findHash(sha1);
        const ms   = parseFloat((Number(process.hrtime.bigint() - t0) / 1e6).toFixed(3));
        res.json({ pwned: r.found, count: r.count, hash: sha1, ms });
    } catch(e) { next(e); }
});

app.post('/checkweak', (req, res, next) => {
    try {
        const { password } = req.body;
        if (!password) {
            return res.status(400).json({ error: 'password required', weak: false });
        }
        _stats.checkweak++;
        const t0     = process.hrtime.bigint();
        const result = checkWeakWord(password);
        const ms     = parseFloat((Number(process.hrtime.bigint() - t0) / 1e6).toFixed(3));
        res.json(result);
    } catch(e) { next(e); }
});

app.get('/health', (req, res) => {
    _stats.health++;
    const weakExists = fs.existsSync(WEAK_FILE);
    const weakCount  = weakExists
        ? fs.readFileSync(WEAK_FILE, 'utf8').split('\n')
            .filter(l => l.trim().length > 0 && !l.trim().startsWith('#')).length
        : 0;
    const uptimeSecs = parseFloat(process.uptime().toFixed(1));
    const body = {
        status       : 'ok',
        totalLines,
        hashSizeGB   : parseFloat((hashSize  / 1e9).toFixed(2)),
        indexSizeGB  : parseFloat((indexSize / 1e9).toFixed(2)),
        weakWordCount: weakCount,
        weakFileFound: weakExists,
        port         : PORT,
        bigIntMode   : true,
        corsEnabled  : true,
        uptime       : uptimeSecs,
        requests     : {
            check    : _stats.check,
            checkweak: _stats.checkweak,
            health   : _stats.health,
            errors   : _stats.errors,
            since    : new Date(_stats.start).toISOString()
        }
    };
    res.json(body);
});

app.listen(PORT, '0.0.0.0', () => {
    console.log(' Status : READY');
    console.log(' Endpoints:');
    console.log('   POST /check      — HIBP breach check');
    console.log('   POST /checkweak  — weak word check');
    console.log('   GET  /health     — monitoring');
    console.log('==============================================');
});
NODEEOF

    log "Installing express npm package..."
    cd "$SERVICE_DIR"
    [ ! -f package.json ] && \
        echo '{"name":"hibp-service","version":"1.0.0","main":"server.js"}' > package.json
    npm install express --save --silent
    sudo chown -R "$USER:$USER" "$SERVICE_DIR"
    success "Server installed at $SERVER_FILE"
}

# ═════════════════════════════════════════════════════════════════════════════
#  STEP 8 — INSTALL NGINX
# ═════════════════════════════════════════════════════════════════════════════
step_install_nginx() {
    header "Step 8 — Install nginx HTTPS Proxy"
    desc "DaVinci (HTTPS) cannot call HTTP endpoints — Mixed Content policy blocks it"
    desc "nginx provides HTTPS so DaVinci browser JavaScript can reach the API"
    echo ""

    command -v nginx &>/dev/null || {
        log "Installing nginx..."
        if command -v dnf &>/dev/null; then PKG_MGR="dnf"; else PKG_MGR="yum"; fi
        sudo $PKG_MGR install -y nginx > /dev/null 2>&1
    }

    local public_ip=$(_get_public_ip)

    log "Creating self-signed SSL certificate for $public_ip..."
    sudo mkdir -p /etc/nginx/ssl
    sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /etc/nginx/ssl/hibp.key \
        -out    /etc/nginx/ssl/hibp.crt \
        -subj   "/C=US/O=ELC/CN=$public_ip" \
        2>/dev/null
    success "SSL certificate created"

    log "Writing nginx configuration..."
    sudo tee /etc/nginx/conf.d/hibp.conf > /dev/null << EOF
server {
    listen 443 ssl;
    server_name _;

    ssl_certificate     /etc/nginx/ssl/hibp.crt;
    ssl_certificate_key /etc/nginx/ssl/hibp.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    add_header Access-Control-Allow-Origin  "*" always;
    add_header Access-Control-Allow-Methods "POST, GET, OPTIONS" always;
    add_header Access-Control-Allow-Headers "Content-Type" always;

    location /check {
        proxy_pass         http://127.0.0.1:$PORT/check;
        proxy_read_timeout 10s;
        proxy_set_header   Host \$host;
    }

    location /checkweak {
        proxy_pass         http://127.0.0.1:$PORT/checkweak;
        proxy_read_timeout 5s;
        proxy_set_header   Host \$host;
    }

    location /health {
        proxy_pass http://127.0.0.1:$PORT/health;
    }
}
EOF

    sudo setsebool -P httpd_can_network_connect 1 2>/dev/null || true
    success "SELinux: httpd_can_network_connect enabled"

    sudo nginx -t 2>/dev/null && success "nginx config valid" || error "nginx config invalid"
    sudo systemctl enable nginx --now > /dev/null 2>&1
    sudo systemctl restart nginx
    success "nginx started on port 443"
}

# ═════════════════════════════════════════════════════════════════════════════
#  STEP 9 — CONFIGURE FIREWALL
# ═════════════════════════════════════════════════════════════════════════════
step_configure_firewall() {
    header "Step 9 — Configure Firewall"
    echo ""

    sudo systemctl start firewalld 2>/dev/null || true

    log "Adding firewall rules..."
    sudo firewall-cmd --permanent --add-port=443/tcp > /dev/null 2>&1
    sudo firewall-cmd --permanent --add-port=${PORT}/tcp > /dev/null 2>&1
    sudo firewall-cmd --reload
    success "Firewall rules applied (ports 443 and $PORT)"
}

# ═════════════════════════════════════════════════════════════════════════════
#  STEP 10 — CREATE SYSTEMD SERVICE
# ═════════════════════════════════════════════════════════════════════════════
step_create_service() {
    header "Step 10 — Create systemd Service"
    desc "systemd manages the Node.js server process"
    echo ""

    [ -z "$NODE_BIN" ] && NODE_BIN=$(command -v node 2>/dev/null || echo "/usr/bin/node")

    sudo bash -c "cat > /etc/systemd/system/hibp.service << SVCEOF
[Unit]
Description=HIBP In-House Password Validation Service
After=network.target

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=/tmp
ExecStart=$NODE_BIN $SERVER_FILE
Restart=always
RestartSec=10
Environment=NODE_ENV=production
Environment=HASH_FILE=$HASH_FILE
Environment=INDEX_FILE=$INDEX_FILE
Environment=WEAK_FILE=$WEAK_FILE
Environment=PORT=$PORT
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SVCEOF"

    sudo systemctl daemon-reload
    sudo systemctl enable hibp
    success "systemd service created and enabled"
}

# ═════════════════════════════════════════════════════════════════════════════
#  STEP 11 — START SERVICE
# ═════════════════════════════════════════════════════════════════════════════
step_start_service() {
    header "Step 11 — Start Service"
    desc "Starting hibp systemd service"
    echo ""

    sudo systemctl stop hibp 2>/dev/null || true
    sleep 1
    sudo systemctl start hibp

    log "Waiting for server to be ready..."
    for i in $(seq 1 20); do
        sleep 1
        if curl -s "http://127.0.0.1:$PORT/health" 2>/dev/null | grep -q '"status":"ok"'; then
            success "Server ready after ${i} seconds"
            break
        fi
        echo -n "."
    done
    echo ""
    sudo systemctl status hibp --no-pager
}

# ═════════════════════════════════════════════════════════════════════════════
#  STATUS / LOGS / START / STOP
# ═════════════════════════════════════════════════════════════════════════════
cmd_status() {
    header "Service Status"
    local PUBLIC_IP=$(_get_public_ip)

    section "systemd service"
    sudo systemctl status hibp --no-pager 2>/dev/null || warn "hibp service not found"

    section "Files"
    [ -f "$HASH_FILE"  ] && success "Hash:  $HASH_FILE ($(ls -lh $HASH_FILE | awk '{print $5}'))"  || warn "Hash file missing"
    [ -f "$INDEX_FILE" ] && success "Index: $INDEX_FILE ($(ls -lh $INDEX_FILE | awk '{print $5}'))" || warn "Index missing"
    [ -f "$WEAK_FILE"  ] && success "Weak:  $WEAK_FILE" || warn "Weak word list missing"

    section "Endpoints"
    info "HTTPS: https://$PUBLIC_IP/check"
    info "HTTPS: https://$PUBLIC_IP/checkweak"
    info "HTTP:  http://$PUBLIC_IP:$PORT/check (direct testing)"
}

cmd_logs() {
    header "Service Logs"
    sudo journalctl -u hibp -n 50 --no-pager
}

cmd_start() {
    sudo systemctl start hibp && sleep 3
    sudo systemctl status hibp --no-pager
    success "Services started"
}

cmd_stop() {
    sudo systemctl stop hibp
    success "Service stopped"
}

# ═════════════════════════════════════════════════════════════════════════════
#  SIMPLE TESTS
# ═════════════════════════════════════════════════════════════════════════════
cmd_test() {
    header "Quick Test"
    local BASE="http://127.0.0.1:$PORT"

    echo -e "\n${BOLD}Testing /check endpoint:${NC}"
    curl -s -X POST "$BASE/check" -H "Content-Type: application/json" \
        -d '{"password":"password"}' | python3 -m json.tool 2>/dev/null || \
        echo "Server not responding on $PORT"

    echo -e "\n${BOLD}Testing /checkweak endpoint:${NC}"
    curl -s -X POST "$BASE/checkweak" -H "Content-Type: application/json" \
        -d '{"password":"welcome"}' | python3 -m json.tool 2>/dev/null

    echo -e "\n${BOLD}Testing /health endpoint:${NC}"
    curl -s "$BASE/health" | python3 -m json.tool 2>/dev/null
}

# ═════════════════════════════════════════════════════════════════════════════
#  HELP
# ═════════════════════════════════════════════════════════════════════════════
cmd_help() {
    echo ""
    echo -e "${BOLD}${BLUE}HIBP Deploy — ELC In-House Password Validation${NC}"
    echo -e "${BLUE}Raw RHEL server → DaVinci-ready API${NC}"
    echo ""
    printf "  %-40s %s\n" "./hibp_deploy.sh"          "First run wizard + full deploy"
    printf "  %-40s %s\n" "./hibp_deploy.sh prereqs"  "Check/install prerequisites"
    printf "  %-40s %s\n" "./hibp_deploy.sh config"   "Re-run configuration wizard"
    printf "  %-40s %s\n" "./hibp_deploy.sh download" "Download 88GB HIBP file"
    printf "  %-40s %s\n" "./hibp_deploy.sh build-index" "Build binary search index"
    printf "  %-40s %s\n" "./hibp_deploy.sh install"  "Install server + nginx + service"
    printf "  %-40s %s\n" "./hibp_deploy.sh start"    "Start services"
    printf "  %-40s %s\n" "./hibp_deploy.sh stop"     "Stop services"
    printf "  %-40s %s\n" "./hibp_deploy.sh test"     "Run quick tests"
    printf "  %-40s %s\n" "./hibp_deploy.sh status"   "Show status"
    printf "  %-40s %s\n" "./hibp_deploy.sh logs"     "View service logs"
    echo ""
}

# ═════════════════════════════════════════════════════════════════════════════
#  ENTRY POINT
# ═════════════════════════════════════════════════════════════════════════════
COMMAND="${1:-}"
load_config

case "$COMMAND" in
    ""|deploy-all)   cmd_prereqs; step_create_dirs; step_create_weak_list; step_install_server; step_install_nginx; step_configure_firewall; step_create_service; step_start_service; cmd_test ;;
    prereqs)         cmd_prereqs ;;
    create-user)     step_create_user ;;
    config)          cmd_config ;;
    download)        step_download ;;
    build-index)     step_build_index ;;
    install)         step_install_server; step_install_nginx; step_configure_firewall; step_create_service ;;
    start)           cmd_start ;;
    stop)            cmd_stop ;;
    test)            cmd_test ;;
    status)          cmd_status ;;
    logs)            cmd_logs ;;
    help|--help|-h)  cmd_help ;;
    *)               warn "Unknown command: $1"; cmd_help ;;
esac
