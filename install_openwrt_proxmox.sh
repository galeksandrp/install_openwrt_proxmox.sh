#!/bin/bash

# Script to create an OpenWrt LXC container in Proxmox
# Downloads from openwrt.org with latest stable version, detects bridges/devices, IDs, configures network, sets optional password
# Pre-configures WAN/LAN in UCI, includes summary and confirmation

# Default resource values
DEFAULT_MEMORY="256"                      # MB
DEFAULT_CORES="2"                         # CPU cores
DEFAULT_STORAGE="0.5"                     # GB
DEFAULT_SUBNET="10.23.45.1/24"            # LAN subnet
ARCH="x86_64"                             # Architecture
TEMPLATE_DIR="/var/lib/vz/template/cache" # Default template location

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Exit handler for cleanup and messages
exit_script() {
    local code=$1
    local msg=$2
    [ -n "$msg" ] && echo -e "${RED}$msg${NC}"
    exit "$code"
}

# Check if running as root
[ "$EUID" -ne 0 ] && exit_script 1 "Error: This script must be run as root"

# Check required tools
for cmd in wget pct pvesm ip curl whiptail pvesh bridge; do
    command -v "$cmd" &>/dev/null || exit_script 1 "Error: $cmd is not installed. Please install it first."
done

# Generic whiptail radiolist function
whiptail_radiolist() {
    local title="$1" prompt="$2" height="$3" width="$4" items=("${@:5}")
    local selection
    selection=$(whiptail --title "$title" --radiolist "$prompt" "$height" "$width" "$((${#items[@]} / 3))" "${items[@]}" 3>&1 1>&2 2>&3) || \
        exit_script 1 "Error: $title selection aborted"
    echo "$selection"
}

# Detect latest stable OpenWrt version (silent)
detect_latest_version() {
    local ver
    ver=$(curl -sSf "https://downloads.openwrt.org/releases/" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1)
    [ -z "$ver" ] && ver="24.10.0"  # Default to 24.10.0 if detection fails
    echo "$ver"
}

# Select storage
select_storage() {
    local content='rootdir' label='Container'
    local -a menu
    while read -r line || [ -n "$line" ]; do
        local tag=$(echo "$line" | awk '{print $1}')
        local type=$(echo "$line" | awk '{printf "%-10s", $2}')
        local free=$(echo "$line" | numfmt --field 4-6 --from-unit=K --to=iec --format %.2f | awk '{printf "%9sB", $6}')
        menu+=("$tag" "Type: $type Free: $free" "OFF")
    done < <(pvesm status -content "$content" | awk 'NR>1')

    [ ${#menu[@]} -eq 0 ] && exit_script 1 "Error: No storage pools found for $label"
    [ $((${#menu[@]} / 3)) -eq 1 ] && echo "${menu[0]}" && return
    whiptail_radiolist "Storage Pools" "Which storage pool for the ${label,,}?\nUse Spacebar to select." 16 $(( $(echo "${menu[*]}" | wc -L) + 23 )) "${menu[@]}"
}

# Detect network options (bridges and unbridged devices)
detect_network_options() {
    BRIDGE_LIST=($(ip link | grep -o 'vmbr[0-9]\+' | sort -u))
    BRIDGE_COUNT=${#BRIDGE_LIST[@]}

    local all_devs
    all_devs=$(ip link show | grep -oE '^[0-9]+: ([^:]+):' | awk '{print $2}' | cut -d':' -f1 | grep -vE '^(lo|vmbr|veth|tap|fwbr|fwpr|fwln)')
    readarray -t ALL_DEVICES <<<"$all_devs"

    local bridged_devs
    bridged_devs=$(bridge link show | cut -d ":" -f2 | cut -d " " -f2)
    readarray -t BRIDGED_DEVICES <<<"$bridged_devs"

    UNBRIDGED_DEVICES=()
    for dev in "${ALL_DEVICES[@]}"; do
        bridged=false
        for bridged_dev in "${BRIDGED_DEVICES[@]}"; do
            [ "$dev" = "$bridged_dev" ] && bridged=true && break
        done
        [ "$bridged" = false ] && UNBRIDGED_DEVICES+=("$dev")
    done
    UNBRIDGED_COUNT=${#UNBRIDGED_DEVICES[@]}
}

# Select network option
select_network_option() {
    local type="$1" eth="$2"
    local -a menu=("None" "No network assigned" "OFF")
    for bridge in "${BRIDGE_LIST[@]}"; do
        menu+=("bridge:$bridge" "Bridge $bridge" "OFF")
    done
    for device in "${UNBRIDGED_DEVICES[@]}"; do
        menu+=("device:$device" "Device $device" "OFF")
    done
    whiptail_radiolist "$type Network Selection" "Select a bridge or device for $type ($eth) or 'None':\nUse Spacebar to select." 16 60 "${menu[@]}"
}

# Detect next available Container ID
detect_next_ctid() {
    local id
    id=$(pvesh get /cluster/nextid)
    echo "${id:-100}"
}

# Prompt with default value
prompt_with_default() {
    local prompt="$1" default="$2" var="$3"
    read -e -p "$prompt (default: $default): " -i "$default" input
    eval "$var=\"${input:-$default}\""
}

# Main execution
echo -e "${GREEN}Fetching latest stable OpenWrt version...${NC}"
VER=$(detect_latest_version)
echo -e "${GREEN}Detected latest stable version: $VER${NC}"
prompt_with_default "Enter OpenWrt version" "$VER" VER
DOWNLOAD_URL="https://downloads.openwrt.org/releases/$VER/targets/x86/64/openwrt-$VER-x86-64-rootfs.tar.gz"
TEMPLATE_FILE="openwrt-$VER-$ARCH.tar.gz"

NEXT_CTID=$(detect_next_ctid)
prompt_with_default "Enter Container ID" "$NEXT_CTID" CTID
prompt_with_default "Enter Container Name" "openwrt-$CTID" CTNAME

while true; do
    read -s -p "Enter root password (leave blank to skip): " PASSWORD; echo
    read -s -p "Confirm root password: " PASSWORD_CONFIRM; echo
    if [ -z "$PASSWORD" ] && [ -z "$PASSWORD_CONFIRM" ]; then
        echo -e "${GREEN}Root password skipped.${NC}"
        break
    elif [ "$PASSWORD" = "$PASSWORD_CONFIRM" ]; then
        break
    else
        echo -e "${RED}Passwords do not match. Please try again.${NC}"
    fi
done

prompt_with_default "Enter memory size in MB" "$DEFAULT_MEMORY" MEMORY
prompt_with_default "Enter number of CPU cores" "$DEFAULT_CORES" CORES
prompt_with_default "Enter storage limit in GB" "$DEFAULT_STORAGE" STORAGE_SIZE
prompt_with_default "Enter LAN subnet" "$DEFAULT_SUBNET" SUBNET

# Validate inputs
[[ "$CTID" =~ ^[0-9]+$ && "$CTID" -ge 100 ]] || exit_script 1 "Error: Container ID must be a number >= 100"
pct list | awk '{print $1}' | grep -q "^$CTID$" && exit_script 1 "Error: Container ID $CTID is already in use"
[[ "$MEMORY" =~ ^[0-9]+$ && "$MEMORY" -ge 64 ]] || exit_script 1 "Error: Memory size must be a number >= 64 MB"
[[ "$CORES" =~ ^[0-9]+$ && "$CORES" -ge 1 ]] || exit_script 1 "Error: Core count must be a number >= 1"
[[ "$STORAGE_SIZE" =~ ^[0-9]*\.?[0-9]+$ && "$(echo "$STORAGE_SIZE > 0" | bc)" -eq 1 ]] || exit_script 1 "Error: Storage limit must be a positive number"

# Parse subnet
LAN_IP=$(echo "$SUBNET" | cut -d'/' -f1)
LAN_PREFIX=$(echo "$SUBNET" | cut -d'/' -f2)
case "$LAN_PREFIX" in
    24) LAN_NETMASK="255.255.255.0" ;;
    23) LAN_NETMASK="255.255.254.0" ;;
    22) LAN_NETMASK="255.255.252.0" ;;
    16) LAN_NETMASK="255.255.0.0" ;;
    *) exit_script 1 "Error: Unsupported subnet prefix /$LAN_PREFIX. Use /16, /22, /23, or /24" ;;
esac

STORAGE=$(select_storage container)
detect_network_options
[ "$BRIDGE_COUNT" -eq 0 ] && [ "$UNBRIDGED_COUNT" -eq 0 ] && echo -e "${RED}Warning: No network options found. Selecting 'None' for WAN/LAN.${NC}"

WAN_OPTION=$(select_network_option "WAN" "eth0")
LAN_OPTION=$(select_network_option "LAN" "eth1")

echo -e "${RED}Note: Wan Option: $WAN_OPTION, Lan Option: $LAN_OPTION${NC}"

WAN_BRIDGE=""; WAN_DEVICE=""
if [[ "$WAN_OPTION" == bridge:* ]]; then
    WAN_BRIDGE="${WAN_OPTION#bridge:}"
elif [[ "$WAN_OPTION" == device:* ]]; then
    WAN_DEVICE="${WAN_OPTION#device:}"
fi

LAN_BRIDGE=""; LAN_DEVICE=""
if [[ "$LAN_OPTION" == bridge:* ]]; then
    LAN_BRIDGE="${LAN_OPTION#bridge:}"
elif [[ "$LAN_OPTION" == device:* ]]; then
    LAN_DEVICE="${LAN_OPTION#device:}"
fi

# Summary and confirmation
SUMMARY="Container Configuration Summary:\n"
SUMMARY+="  OpenWrt Version: $VER\n"
SUMMARY+="  Container ID: $CTID\n"
SUMMARY+="  Container Name: $CTNAME\n"
SUMMARY+="  Root Password: $( [ -n "$PASSWORD" ] && echo "Set" || echo "Not set" )\n"
SUMMARY+="  Memory: $MEMORY MB\n"
SUMMARY+="  CPU Cores: $CORES\n"
SUMMARY+="  Storage: $STORAGE_SIZE GB on $STORAGE\n"
SUMMARY+="  LAN Subnet: $SUBNET\n"
SUMMARY+="  WAN Interface: ${WAN_BRIDGE:-${WAN_DEVICE:-None}} (eth0, DHCP/DHCPv6)\n"
SUMMARY+="  LAN Interface: ${LAN_BRIDGE:-${LAN_DEVICE:-None}} (eth1, static)\n"

whiptail --title "Confirm Container Creation" --yesno "$SUMMARY\nProceed with container creation?" 30 60 || exit_script 0 "Container creation aborted by user"

# Download template
if [ ! -f "$TEMPLATE_DIR/$TEMPLATE_FILE" ]; then
    echo -e "${GREEN}Downloading OpenWrt $VER rootfs...${NC}"
    wget -q "$DOWNLOAD_URL" -O "$TEMPLATE_DIR/$TEMPLATE_FILE" || exit_script 1 "Error: Failed to download OpenWrt $VER image"
else
    echo -e "${GREEN}Using existing OpenWrt image: $TEMPLATE_FILE${NC}"
fi

# Build pct create command with corrected network options
echo -e "${GREEN}Creating LXC container $CTID...${NC}"
NET_OPTS=()
[ -n "$WAN_BRIDGE" ] && NET_OPTS+=("--net0" "name=eth0,bridge=$WAN_BRIDGE")
[ -n "$WAN_DEVICE" ] && NET_OPTS+=("--net0" "name=eth0,hwaddr=$(ip link show "$WAN_DEVICE" | grep -o 'ether [0-9a-f:]\+' | cut -d' ' -f2)")
[ -n "$LAN_BRIDGE" ] && NET_OPTS+=("--net1" "name=eth1,bridge=$LAN_BRIDGE")
[ -n "$LAN_DEVICE" ] && NET_OPTS+=("--net1" "name=eth1,hwaddr=$(ip link show "$LAN_DEVICE" | grep -o 'ether [0-9a-f:]\+' | cut -d' ' -f2)")

pct create "$CTID" "$TEMPLATE_DIR/$TEMPLATE_FILE" \
    --arch amd64 \
    --hostname "$CTNAME" \
    --rootfs "$STORAGE:$STORAGE_SIZE" \
    --memory "$MEMORY" \
    --cores "$CORES" \
    --unprivileged 1 \
    --features nesting=1 \
    --ostype unmanaged \
    "${NET_OPTS[@]}" || exit_script 1 "Error: Failed to create container"


echo -e "${GREEN}Starting container $CTID...${NC}"
pct start "$CTID" || exit_script 1 "Error: Failed to start container"

pct exec "$CTID" -- sh -c "sed -i 's!procd_add_jail!: procd_add_jail!g' /etc/init.d/dnsmasq"
sleep 10

echo -e "${GREEN}Configuring network...${NC}"
pct exec "$CTID" -- sh -c "
    # Always configure WAN (eth0) with DHCP and DHCPv6
    uci set network.wan=interface
    uci set network.wan.proto='dhcp'
    uci set network.wan.device='eth0'
    uci set network.wan6=interface
    uci set network.wan6.proto='dhcpv6'
    uci set network.wan6.device='eth0'

    # Always configure LAN (eth1) with static IP
    uci set network.lan=interface
    uci set network.lan.proto='static'
    uci set network.@device[0].ports='eth1'
    uci set network.lan.ipaddr='$LAN_IP'
    uci set network.lan.netmask='$LAN_NETMASK'

    # Commit changes and restart network
    uci commit network
    /etc/init.d/network restart" || echo -e "${RED}Warning: Network configuration failed${NC}"

[ -n "$PASSWORD" ] && {
    echo -e "${GREEN}Setting root password...${NC}"
    echo -e "$PASSWORD\n$PASSWORD" | pct exec "$CTID" -- passwd || echo -e "${RED}Warning: Failed to set root password${NC}"
} || echo -e "${GREEN}Root password not set (left blank).${NC}"

echo -e "${GREEN}Container $CTID ($CTNAME) created and started!${NC}"
echo "Next steps:"
echo "1. Access: pct exec $CTID /bin/sh"
echo "2. Verify network: uci show network"
echo "3. Update: opkg update"
echo "4. Install LuCI: opkg install luci"
[ -n "$LAN_BRIDGE" ] || [ -n "$LAN_DEVICE" ] && echo "5. LuCI: http://$LAN_IP" || echo "5. Add eth1 to activate LAN: http://$LAN_IP"
[ -z "$PASSWORD" ] && echo "6. Set password if needed: pct exec $CTID passwd"