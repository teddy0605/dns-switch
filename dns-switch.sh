#!/bin/bash

# DNS Management Script - auto-detects home/office and VPN state, applies the right DNS config
set -euo pipefail

# Re-execute with sudo if not root. "check" is read-only, so the menu bar
# watchdog can run it every few seconds without sudo.
if [ "$EUID" -ne 0 ] && [ "${1:-}" != "check" ]; then
  exec sudo "$0" "$@"
fi

# Constants
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BREW_PREFIX="$(brew --prefix)"
DNSMASQ_LOG="${BREW_PREFIX}/var/log/dnsmasq.log"
DNSMASQ_CONF="${BREW_PREFIX}/etc/dnsmasq.conf"
DNSMASQ_PID="/tmp/dns-switch-dnsmasq.pid"
RESOLVER_DIR="/etc/resolver"
VPN_LOG="${BREW_PREFIX}/var/log/dns-switch-vpn.log"
VPN_DISCONNECT_TIMEOUT=30

CONFIG_FILE="${SCRIPT_DIR}/local/.env"
EXAMPLE_CONFIG_FILE="${SCRIPT_DIR}/dns-switch.env.example"

# Load Configuration
if [ -f "$CONFIG_FILE" ]; then
  source "$CONFIG_FILE"
else
  echo "❌ Configuration file not found at $CONFIG_FILE"
  echo "Create one from $EXAMPLE_CONFIG_FILE or run 'install'."
  # Default values to prevent crash if just checking help
  PIHOLE_IP=""
  VPN_DNS_1=""
  VPN_DNS_2=""
  CACHE_SIZE="2000"
  MIN_CACHE_TTL="1800"
  WORK_DOMAINS=()
  BLOCKED_DOMAINS=()
  TEST_HOSTS=("example.com")
fi

if [ -z "${BLOCKED_DOMAINS+x}" ]
then
  BLOCKED_DOMAINS=()
fi

TEST_HOSTS=("${TEST_HOSTS[@]:-google.com}")

config_append_to_array() {
  local array_name=$1 value=$2
  sed -i.bak "/^${array_name}=(/,/^)/{
/^)/i\\
  \"${value}\"
}" "$CONFIG_FILE" && rm -f "${CONFIG_FILE}.bak"
}

config_remove_from_array() {
  local array_name=$1 value=$2
  sed -i.bak "/^${array_name}=(/,/^)/{
/\"${value}\"/d
}" "$CONFIG_FILE" && rm -f "${CONFIG_FILE}.bak"
}

# Utility functions
get_network_services() {
  networksetup -listallnetworkservices | sed '1{/An asterisk/d;}' | sed '/^\*/d'
}

ensure_dirs() {
  local log_dir
  log_dir="$(dirname "$DNSMASQ_LOG")"

  # Prefer user-owned files for user-scoped Homebrew services.
  mkdir -p "$log_dir" 2>/dev/null || sudo mkdir -p "$log_dir"
  touch "$DNSMASQ_LOG" 2>/dev/null || sudo touch "$DNSMASQ_LOG"
  chmod 664 "$DNSMASQ_LOG" 2>/dev/null || sudo chmod 664 "$DNSMASQ_LOG"
  chown "$(id -un)":staff "$DNSMASQ_LOG" 2>/dev/null || sudo chown "$(id -un)":staff "$DNSMASQ_LOG" 2>/dev/null || true
}

restart_dnsmasq() {
  ensure_dirs
  if ! "${BREW_PREFIX}/sbin/dnsmasq" --test -C "$DNSMASQ_CONF" >/dev/null 2>&1; then
    echo "❌ dnsmasq config test failed: $DNSMASQ_CONF"
    return 1
  fi

  # Stop existing dnsmasq process if running.
  if [ -f "$DNSMASQ_PID" ]; then
    sudo kill "$(cat "$DNSMASQ_PID")" >/dev/null 2>&1 || true
    sudo rm -f "$DNSMASQ_PID" >/dev/null 2>&1 || true
  fi
  sudo pkill -x dnsmasq >/dev/null 2>&1 || true

  # Start dnsmasq directly as root (required for port 53 on macOS).
  if ! sudo "${BREW_PREFIX}/sbin/dnsmasq" --conf-file="$DNSMASQ_CONF" --pid-file="$DNSMASQ_PID"; then
    echo "❌ dnsmasq start command failed"
    return 1
  fi

  # Wait for process and local DNS socket to become ready.
  for _ in 1 2 3 4 5; do
    if pgrep -x dnsmasq >/dev/null 2>&1 && dig +time=1 +tries=1 +short localhost @127.0.0.1 >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  echo "❌ dnsmasq did not become ready on 127.0.0.1:53"
  return 1
}

flush_dns_cache() {
  sudo dscacheutil -flushcache || true
  sudo killall -HUP mDNSResponder 2>/dev/null || true
  sudo pkill -HUP -x dnsmasq 2>/dev/null || true
}

get_upstream_dns() {
  [ -f "$DNSMASQ_CONF" ] && grep "^server=" "$DNSMASQ_CONF" | grep -v "/" | head -1 | cut -d'=' -f2 || echo "Not configured"
}

# Reads the DNS server the active interface actually got from DHCP, independent
# of any networksetup override already in place (needed for office mode, where
# we point system DNS at 127.0.0.1 but still want dnsmasq to forward upstream
# to whatever the office network handed out).
get_dhcp_dns() {
  local iface dns
  iface=$(route -n get default 2>/dev/null | awk '/interface: /{print $2}')
  [ -z "$iface" ] && return 1
  dns=$(ipconfig getoption "$iface" domain_name_server 2>/dev/null | awk -F'[, ]+' '{print $1}')
  [ -z "$dns" ] && return 1
  echo "$dns"
}

# Quick check for whether the home Pi-hole is actually reachable on the
# current network (it won't be from the office, even with VPN connected).
is_pihole_reachable() {
  [ -n "$PIHOLE_IP" ] && dig +time=1 +tries=1 +short localhost @"$PIHOLE_IP" >/dev/null 2>&1
}

# Whether openconnect is currently holding a VPN tunnel. vpn-hook.sh sets
# DNS_SWITCH_VPN=no on disconnect, while openconnect is still running.
is_vpn_connected() {
  [ "${DNS_SWITCH_VPN:-}" = "no" ] && return 1
  pgrep -a -x openconnect >/dev/null 2>&1
}

# home if the home Pi-hole is reachable, office otherwise.
detect_location() {
  if is_pihole_reachable; then
    echo "home"
  else
    echo "office"
  fi
}

# Sets: TARGET_MODE (home|office), TARGET_DEFAULT_DNS, VPN_ACTIVE (yes|no)
compute_dns_targets() {
  local location
  location=$(detect_location)

  if [ "$location" = "home" ]; then
    TARGET_MODE="home"
    TARGET_DEFAULT_DNS="$PIHOLE_IP"
  else
    TARGET_MODE="office"
    TARGET_DEFAULT_DNS=$(get_dhcp_dns || echo "")
  fi

  VPN_ACTIVE=$(is_vpn_connected && echo yes || echo no)
}

# Reads back mode/VPN state from the live dnsmasq.conf, for status reporting.
# Sets: LIVE_MODE (home|office|unknown), LIVE_VPN_ACTIVE (yes|no)
detect_live_config() {
  LIVE_MODE="unknown"
  LIVE_VPN_ACTIVE="no"
  [ -f "$DNSMASQ_CONF" ] || return
  if grep -q "^# dnsmasq: home mode" "$DNSMASQ_CONF"; then
    LIVE_MODE="home"
  elif grep -q "^# dnsmasq: office mode" "$DNSMASQ_CONF"; then
    LIVE_MODE="office"
  fi
  grep -q "server=/.*/$VPN_DNS_1\|server=/.*/$VPN_DNS_2" "$DNSMASQ_CONF" 2>/dev/null && LIVE_VPN_ACTIVE="yes"
  true
}

validate_config() {
  local mode=$1
  local vpn_active=${2:-no}

  if [ -z "$PIHOLE_IP" ]; then
    echo "❌ PIHOLE_IP is required in $CONFIG_FILE"
    return 1
  fi

  if [ "$vpn_active" = "yes" ] && { [ -z "$VPN_DNS_1" ] || [ -z "$VPN_DNS_2" ]; }; then
    echo "❌ VPN_DNS_1 and VPN_DNS_2 are required when VPN is active in $CONFIG_FILE"
    return 1
  fi
}

# DNS management functions
write_dnsmasq_config() {
  local mode=$1
  local default_dns=${2:-$PIHOLE_IP}
  local vpn_active=${3:-no}
  validate_config "$mode" "$vpn_active"

  local work_servers=""
  local vpn_bootstrap_servers=""
  local blocked_servers=""
  if [ "$vpn_active" = "yes" ]
  then
    work_servers=$(for d in "${WORK_DOMAINS[@]}"; do echo "server=/$d/$VPN_DNS_1"; echo "server=/$d/$VPN_DNS_2"; done)
    vpn_bootstrap_servers=$(for d in "${VPN_BOOTSTRAP_HOSTS[@]}"; do echo "server=/$d/$default_dns"; done)
  fi
  if [ ${#BLOCKED_DOMAINS[@]} -gt 0 ]
  then
    blocked_servers=$(for d in "${BLOCKED_DOMAINS[@]}"; do echo "address=/$d/0.0.0.0"; done)
  fi
  
  local tmp_conf
  tmp_conf="$(mktemp)"
  cat >"$tmp_conf" <<EOF
# dnsmasq: $mode mode
listen-address=127.0.0.1
port=53
no-hosts
no-resolv
cache-size=$CACHE_SIZE
min-cache-ttl=$MIN_CACHE_TTL
bogus-priv
log-queries
log-facility=$DNSMASQ_LOG

# Tailscale
server=/ts.net/100.100.100.100

$work_servers

# GlobalProtect portal/gateway bootstrap: force public DNS, overriding the
# broader WORK_DOMAINS rules above (dnsmasq matches longest domain)
$vpn_bootstrap_servers

# Blocked domains: blackholed to 0.0.0.0 for all resolvers, in every mode
$blocked_servers

# Default upstream
server=$default_dns
EOF
  mv "$tmp_conf" "$DNSMASQ_CONF" 2>/dev/null || sudo mv "$tmp_conf" "$DNSMASQ_CONF"
  chmod 644 "$DNSMASQ_CONF" 2>/dev/null || sudo chmod 644 "$DNSMASQ_CONF" 2>/dev/null || true
}

manage_resolvers() {
  local action=$1
  for d in "${WORK_DOMAINS[@]}"; do
    if [ "$action" = "install" ]; then
      tmp=$(mktemp)
      cat >"$tmp" <<EOF
# managed-by: dns-switch.sh
nameserver 127.0.0.1
port 53
timeout 2
EOF
      sudo mv "$tmp" "$RESOLVER_DIR/$d"
      sudo chmod 644 "$RESOLVER_DIR/$d"
      echo "  Installed resolver for $d"
    elif [ -f "$RESOLVER_DIR/$d" ] && head -1 "$RESOLVER_DIR/$d" 2>/dev/null | grep -q "managed-by: dns-switch.sh"; then
      echo "  Removing resolver for $d"
      sudo rm -f "$RESOLVER_DIR/$d"
    fi
  done
}

set_system_dns() {
  local mode=$1
  local local_dns="127.0.0.1"
  
  get_network_services | while read -r service; do
    [ -z "$service" ] && continue
    if [ "$mode" = "local" ]; then
      echo "  Setting $service → $local_dns"
      sudo networksetup -setdnsservers "$service" "$local_dns" 2>/dev/null || true
    else
      echo "  Clearing $service DNS → DHCP"
      sudo networksetup -setdnsservers "$service" Empty
    fi
  done
}

# Mode functions
cmd_activate() {
  compute_dns_targets

  if [ "$TARGET_MODE" = "office" ] && [ -z "$TARGET_DEFAULT_DNS" ]; then
    echo "❌ At the office but could not read DHCP DNS; aborting"
    exit 1
  fi

  if [ "$TARGET_MODE" = "home" ]; then
    echo "🏠 Home (upstream: Pi-hole $PIHOLE_IP)"
  else
    echo "🏢 Office (upstream from DHCP: $TARGET_DEFAULT_DNS)"
  fi
  if [ "$VPN_ACTIVE" = "yes" ]; then
    echo "🔒 VPN connected - work domains via VPN DNS"
  fi

  write_dnsmasq_config "$TARGET_MODE" "$TARGET_DEFAULT_DNS" "$VPN_ACTIVE"

  if [ "$VPN_ACTIVE" = "yes" ]; then
    sudo mkdir -p "$RESOLVER_DIR"
    manage_resolvers "install"
  else
    manage_resolvers "remove"
  fi

  if restart_dnsmasq; then
    set_system_dns "local"
  else
    echo "❌ Failed to start/restart dnsmasq. Leaving system DNS unchanged."
    set_system_dns "dhcp"
    exit 1
  fi
  flush_dns_cache
}

cmd_deactivate() {
  echo "🛑 Stopping dnsmasq..."
  if [ -f "$DNSMASQ_PID" ]; then
    sudo kill "$(cat "$DNSMASQ_PID")" >/dev/null 2>&1 || true
    sudo rm -f "$DNSMASQ_PID" >/dev/null 2>&1 || true
  fi
  sudo pkill -x dnsmasq >/dev/null 2>&1 || true
  manage_resolvers "remove"
  set_system_dns "dhcp"
  flush_dns_cache
}

cmd_flush() {
  echo "🧼 Flushing DNS caches..."
  flush_dns_cache
}

cmd_status() {
  echo "📊 DNS Status:"
  if pgrep -x "dnsmasq" > /dev/null; then
    detect_live_config
    upstream=$(get_upstream_dns)
    echo "✅ dnsmasq active - Location: $LIVE_MODE - VPN: $LIVE_VPN_ACTIVE - Upstream: $upstream"

  if [ "$LIVE_VPN_ACTIVE" = "yes" ]; then
    echo "📁 Per-domain resolvers:"
    for d in "${WORK_DOMAINS[@]}"; do
      [ -f "$RESOLVER_DIR/$d" ] && echo "  ✅ $d" || echo "  ❌ $d (missing)"
    done
    echo ""
  fi
  else
    echo "❌ dnsmasq inactive - Direct system DNS"
  fi
  
  echo ""
  echo "🖥️ System DNS:"
  get_network_services | while read -r service; do
    dns=$(networksetup -getdnsservers "$service" 2>/dev/null || echo "Error")
    echo "  $service: $dns"
  done
  
  echo ""
  echo "🧪 DNS Resolution Tests:"
  for h in "${TEST_HOSTS[@]}"; do
    result=$(dig +short "$h" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g')
    if [ -z "$result" ]; then
      result=$(dig +short AAAA "$h" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g' || echo 'No records')
    fi
    printf "  %-25s: %s\n" "$h" "${result:-'No response'}"
  done
  
  echo ""
  echo "📋 Recent DNS queries:"
  if [ -f "$DNSMASQ_LOG" ]; then
    tail -10 "$DNSMASQ_LOG"
  else
    echo "  No log file found"
  fi
}

cmd_logs() {
  local follow=0
  [ "${1:-}" = "-f" ] || [ "${1:-}" = "--follow" ] && follow=1
  [ -f "$DNSMASQ_LOG" ] || { echo "No log file"; return; }
  if [ "$follow" -eq 1 ]; then
    tail -f "$DNSMASQ_LOG"
  else
    echo "📋 DNS queries:"
    tail -20 "$DNSMASQ_LOG"
  fi
}

cmd_cache() {
  local size=$1
  if ! [[ "$size" =~ ^[0-9]+$ ]] || [ "$size" -le 0 ]; then
    echo "Usage: $0 cache <positive-integer>"
    exit 1
  fi
  
  echo "🧠 Cache size: $size"
  
  # Update config file
  if [ -f "$CONFIG_FILE" ]; then
    sed -i.bak 's/^CACHE_SIZE="[0-9]*"/CACHE_SIZE="'"$size"'"/' "$CONFIG_FILE" && rm -f "${CONFIG_FILE}.bak"
    echo "✅ Updated config file"
  else
    echo "❌ Config file not found"
    exit 1
  fi
  
  # Reload config
  source "$CONFIG_FILE"
  
  if pgrep -x "dnsmasq" > /dev/null; then
    compute_dns_targets
    write_dnsmasq_config "$TARGET_MODE" "$TARGET_DEFAULT_DNS" "$VPN_ACTIVE"
    restart_dnsmasq
    flush_dns_cache
    echo "✅ Applied and restarted"
  else
    [ -f "$DNSMASQ_CONF" ] && sudo sed -i 's/^cache-size=.*/cache-size='"$CACHE_SIZE"'/' "$DNSMASQ_CONF"
    echo "✅ Updated dnsmasq config"
  fi
}

cmd_install() {
  echo "📦 Installing DNS Split Setup..."
  
  if ! command -v brew &> /dev/null; then
    echo "❌ Homebrew required"
    exit 1
  fi
  
  if ! brew list dnsmasq &> /dev/null; then
    brew install dnsmasq
  fi
  
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "Creating default configuration at $CONFIG_FILE..."
    cat > "$CONFIG_FILE" <<EOF
# Configuration for dns-switch.sh
PIHOLE_IP="192.168.1.1"
VPN_DNS_1="10.0.0.53"
VPN_DNS_2="10.0.0.54"
CACHE_SIZE="2000"
MIN_CACHE_TTL="1800"

WORK_DOMAINS=(
  "corp.example.com"
)

BLOCKED_DOMAINS=(
)

TEST_HOSTS=(
  "corp.example.com"
  "google.com"
)
EOF
    echo "✅ Created config file"
  fi
  
  source "$CONFIG_FILE"
  
  [ -f "$DNSMASQ_CONF" ] && ! [ -f "${DNSMASQ_CONF}.backup" ] && sudo cp "$DNSMASQ_CONF" "${DNSMASQ_CONF}.backup"
  
  write_dnsmasq_config "home" "$PIHOLE_IP" "no"
  ensure_dirs

  if sudo "${BREW_PREFIX}/sbin/dnsmasq" --test -C "$DNSMASQ_CONF"; then
    echo "✅ Installation complete"
    echo "Usage: $0 {activate|deactivate|flush|status|cache <size>|add-domain <domain>}"
  else
    echo "❌ Configuration error"
    exit 1
  fi
}

cmd_add_domain() {
  local domain=$1
  [ -z "$domain" ] && { echo "Usage: $0 add-domain <domain>"; exit 1; }
  
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ Config file not found at $CONFIG_FILE"
    exit 1
  fi
  
  for d in "${WORK_DOMAINS[@]}"; do
    if [ "$d" = "$domain" ]; then
      echo "ℹ️ Domain already exists in WORK_DOMAINS"
      return
    fi
  done

  if grep -q "WORK_DOMAINS=(" "$CONFIG_FILE"; then
    config_append_to_array "WORK_DOMAINS" "$domain"
    echo "✅ Added '$domain' to WORK_DOMAINS - run 'activate' to apply"
  else
    echo "❌ Could not parse WORK_DOMAINS in config file"
    exit 1
  fi
}

cmd_remove_domain() {
  local domain=$1
  [ -z "$domain" ] && { echo "Usage: $0 remove-domain <domain>"; exit 1; }
  
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ Config file not found at $CONFIG_FILE"
    exit 1
  fi
  
  # Check if domain exists in loaded config
  local found=0
  for d in "${WORK_DOMAINS[@]}"; do
    if [ "$d" = "$domain" ]; then
      found=1
      break
    fi
  done
  
  if [ $found -eq 0 ]; then
    echo "ℹ️ Domain '$domain' not found in configuration"
    return
  fi
  
  config_remove_from_array "WORK_DOMAINS" "$domain"
  echo "✅ Removed '$domain' from WORK_DOMAINS - run 'activate' to apply"
}

cmd_list_domains() {
  echo "📋 Work Domains (VPN forwarded):"
  if [ ${#WORK_DOMAINS[@]} -eq 0 ]; then
    echo "  (No domains configured)"
  else
    for d in "${WORK_DOMAINS[@]}"; do
      echo "  • $d"
    done
  fi
  echo ""
  echo "Total: ${#WORK_DOMAINS[@]} domains"
}

cmd_block_domain() {
  local domain=$1
  [ -z "$domain" ] && { echo "Usage: $0 block-domain <domain>"; exit 1; }

  if [ ! -f "$CONFIG_FILE" ]
  then
    echo "❌ Config file not found at $CONFIG_FILE"
    exit 1
  fi

  if [ ${#BLOCKED_DOMAINS[@]} -gt 0 ]
  then
    for d in "${BLOCKED_DOMAINS[@]}"; do
      if [ "$d" = "$domain" ]
      then
        echo "ℹ️ Domain already exists in BLOCKED_DOMAINS"
        return
      fi
    done
  fi

  if grep -q "BLOCKED_DOMAINS=(" "$CONFIG_FILE"
  then
    config_append_to_array "BLOCKED_DOMAINS" "$domain"
  else
    printf '\nBLOCKED_DOMAINS=(\n)\n' >> "$CONFIG_FILE"
    config_append_to_array "BLOCKED_DOMAINS" "$domain"
  fi
  echo "✅ Added '$domain' to BLOCKED_DOMAINS - run 'activate' to apply"
}

cmd_unblock_domain() {
  local domain=$1
  [ -z "$domain" ] && { echo "Usage: $0 unblock-domain <domain>"; exit 1; }

  if [ ! -f "$CONFIG_FILE" ]
  then
    echo "❌ Config file not found at $CONFIG_FILE"
    exit 1
  fi

  local found=0
  if [ ${#BLOCKED_DOMAINS[@]} -gt 0 ]
  then
    for d in "${BLOCKED_DOMAINS[@]}"; do
      if [ "$d" = "$domain" ]
      then
        found=1
        break
      fi
    done
  fi

  if [ $found -eq 0 ]
  then
    echo "ℹ️ Domain '$domain' not found in BLOCKED_DOMAINS"
    return
  fi

  config_remove_from_array "BLOCKED_DOMAINS" "$domain"
  echo "✅ Removed '$domain' from BLOCKED_DOMAINS - run 'activate' to apply"
}

cmd_list_blocked_domains() {
  echo "🚫 Blocked Domains (blackholed to 0.0.0.0):"
  if [ ${#BLOCKED_DOMAINS[@]} -eq 0 ]
  then
    echo "  (No domains configured)"
  else
    for d in "${BLOCKED_DOMAINS[@]}"; do
      echo "  • $d"
    done
  fi
  echo ""
  echo "Total: ${#BLOCKED_DOMAINS[@]} domains"
}

cmd_cleanup_routes() {
  echo "🧹 Cleaning up stale VPN state..."
  local vpn_running=0
  pgrep -x openconnect >/dev/null 2>&1 && vpn_running=1

  # --- Step 1: destroy orphaned utun interfaces holding VPN IPs ---
  # These cause "Can't assign requested address" on TCP even when routes look clean,
  # because macOS selects the dead VPN IP as the source address for new connections.
  local iface_removed=0
  while IFS= read -r line; do
    local iface ip
    iface=$(echo "$line" | awk '{print $1}')
    ip=$(echo "$line" | awk '{print $2}')
    [[ "$ip" =~ ^10\. ]] || continue

    if [ "$vpn_running" -eq 1 ]; then
      # Don't touch interfaces that belong to a live openconnect session
      local iface_flags
      iface_flags=$(ifconfig "$iface" 2>/dev/null | head -1)
      [[ "$iface_flags" =~ UP ]] && echo "  Skipping active tunnel $iface ($ip)" && continue
    fi

    echo "  Destroying orphaned VPN interface $iface (had IP $ip)"
    sudo ifconfig "$iface" down 2>/dev/null || true
    sudo ifconfig "$iface" delete "$ip" 2>/dev/null || true
    iface_removed=$((iface_removed + 1))
  done < <(ifconfig -a 2>/dev/null | awk '
    /^utun[0-9]+:/ { iface=$1; sub(/:$/,"",iface) }
    iface && /inet [0-9]/ { print iface, $2; iface="" }
  ')

  # --- Step 2: remove stale routes with 10.x.x.x gateways ---
  local active_gateways
  active_gateways=$(ifconfig 2>/dev/null | awk '
    /^utun[0-9]+:/ { iface=1; next }
    iface && /inet / { print $2; iface=0 }
    /^[a-z]/ { iface=0 }
  ')

  local removed=0
  while IFS= read -r line; do
    local dest gateway
    dest=$(echo "$line" | awk '{print $1}')
    gateway=$(echo "$line" | awk '{print $2}')
    [[ "$gateway" =~ ^10\. ]] || continue
    echo "$active_gateways" | grep -qx "$gateway" && continue
    echo "  Removing stale route: $dest via $gateway"
    sudo route -q delete "$dest" "$gateway" 2>/dev/null && removed=$((removed + 1)) || true
  done < <(netstat -rn -f inet 2>/dev/null | awk 'NR>4 && /^[0-9]/{print}')

  echo "  Done — destroyed $iface_removed interface(s), removed $removed stale route(s)"
  [ $((iface_removed + removed)) -gt 0 ] && flush_dns_cache || true
}

# Reads the password and the 2FA code from stdin, one per line, so the menu bar
# app can connect without a Terminal. openconnect continues in the background
# once the tunnel is up, and vpn-hook.sh re-runs activate.
# Exit 2 with "UNTRUSTED_CERT <host> <pin>" when a host's cert pin is unknown.
cmd_vpn_connect() {
  local gateway=$1
  [ -z "$gateway" ] && { echo "Usage: $0 vpn-connect <gateway>"; exit 1; }
  is_vpn_connected && { echo "ℹ️ VPN already connected"; return; }

  local pins=() pin host
  for pin in "${VPN_SERVERCERTS[@]}"; do pins+=(--servercert "$pin"); done

  ensure_dirs
  if openconnect --protocol=gp "$VPN_PORTAL" --user "$VPN_USER" --authgroup "$gateway" \
    --passwd-on-stdin "${pins[@]}" \
    --csd-wrapper "$SCRIPT_DIR/local/hipreport.sh" --script "$SCRIPT_DIR/vpn-hook.sh" \
    --background >"$VPN_LOG" 2>&1
  then
    echo "🔒 VPN connected via $gateway"
    return
  fi

  pin=$(grep -o "match server's certificate: pin-sha256:[^ ]*" "$VPN_LOG" | tail -1 | sed 's/.*: //')
  if [ -n "$pin" ]; then
    host=$(grep -o 'SSL negotiation with [^ ]*' "$VPN_LOG" | tail -1 | awk '{print $NF}')
    echo "UNTRUSTED_CERT $host $pin"
    exit 2
  fi
  echo "❌ VPN connect failed:"
  tail -15 "$VPN_LOG"
  exit 1
}

# Same as Ctrl+C in the openconnect terminal: clean exit, routes removed,
# and vpn-hook.sh re-runs activate for the non-VPN state.
cmd_vpn_disconnect() {
  is_vpn_connected || { echo "ℹ️ VPN not connected"; return; }
  pkill -INT -x openconnect
  for _ in $(seq "$VPN_DISCONNECT_TIMEOUT"); do
    is_vpn_connected || { echo "🔓 VPN disconnected"; return; }
    sleep 1
  done
  echo "❌ openconnect still running after ${VPN_DISCONNECT_TIMEOUT}s"
  exit 1
}

cmd_vpn_trust() {
  local pin=$1
  [[ "$pin" =~ ^pin-sha256:[A-Za-z0-9+/=]+$ ]] || { echo "Usage: $0 vpn-trust pin-sha256:<base64>"; exit 1; }
  config_append_to_array "VPN_SERVERCERTS" "$pin"
  echo "✅ Added $pin to VPN_SERVERCERTS"
}

# Exit 1 with a reason when the live DNS setup no longer matches reality.
cmd_check() {
  if ! dig +time=1 +tries=1 +short localhost @127.0.0.1 >/dev/null 2>&1; then
    echo "dnsmasq not answering"
    exit 1
  fi
  detect_live_config
  local vpn location
  vpn=$(is_vpn_connected && echo yes || echo no)
  if [ "$vpn" != "$LIVE_VPN_ACTIVE" ]; then
    echo "VPN is $vpn, DNS config has VPN $LIVE_VPN_ACTIVE"
    exit 1
  fi
  location=$(detect_location)
  if [ "$location" != "$LIVE_MODE" ]; then
    echo "location is $location, DNS config has $LIVE_MODE"
    exit 1
  fi
  echo "ok"
}

# Main execution
case "${1:-}" in
  activate)   cmd_activate ;;
  deactivate) cmd_deactivate ;;
  flush)      cmd_flush ;;
  status)   cmd_status ;;
  logs)     cmd_logs "${2:-}" ;;
  cache)    cmd_cache "${2:-}" ;;
  install)  cmd_install ;;
  add-domain) cmd_add_domain "${2:-}" ;;
  remove-domain) cmd_remove_domain "${2:-}" ;;
  list-domains) cmd_list_domains ;;
  block-domain) cmd_block_domain "${2:-}" ;;
  unblock-domain) cmd_unblock_domain "${2:-}" ;;
  list-blocked-domains) cmd_list_blocked_domains ;;
  cleanup-routes) cmd_cleanup_routes ;;
  vpn-connect) cmd_vpn_connect "${2:-}" ;;
  vpn-disconnect) cmd_vpn_disconnect ;;
  vpn-trust) cmd_vpn_trust "${2:-}" ;;
  check) cmd_check ;;
  *)
    echo "🧭 DNS Management Script"
    echo "Usage: $0 {activate|deactivate|flush|status|logs|install|cache <size>|add-domain <domain>|remove-domain <domain>|list-domains|block-domain <domain>|unblock-domain <domain>|list-blocked-domains}"
    echo ""
    echo "Core:"
    echo "  activate   - Auto-detect location (home/office) and VPN state, apply DNS config"
    echo "  deactivate - Stop and restore DHCP"
    echo "  flush      - Flush macOS + dnsmasq DNS caches only"
    echo ""
    echo "Management:"
    echo "  status     - Comprehensive status and diagnostics"
    echo "  add-domain - Add work domain"
    echo "  remove-domain - Remove work domain"
    echo "  list-domains  - List all work domains"
    echo "  block-domain - Blackhole a domain for all resolvers"
    echo "  unblock-domain - Remove a domain from the blackhole"
    echo "  list-blocked-domains - List all blocked domains"
    echo "  cleanup-routes - Remove stale routes from killed VPN sessions"
    echo "  vpn-connect <gateway> - Connect VPN (password + 2FA code on stdin)"
    echo "  vpn-disconnect - Disconnect VPN (like Ctrl+C)"
    echo "  vpn-trust <pin> - Trust a VPN portal/gateway cert pin"
    echo "  check      - Exit 1 if the live DNS setup is stale"
    echo "  cache <n>  - Set cache size"
    echo "  install    - Initial setup"
    echo ""
    if pgrep -x "dnsmasq" > /dev/null; then
      detect_live_config
      upstream=$(get_upstream_dns)
      echo "Current: ✅ $LIVE_MODE, VPN: $LIVE_VPN_ACTIVE (upstream: $upstream)"
    else
      echo "Current: 🔸 Direct system DNS"
    fi
    ;;
esac
