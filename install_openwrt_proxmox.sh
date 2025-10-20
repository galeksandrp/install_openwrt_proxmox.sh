#!/bin/bash

# Script to create an OpenWrt LXC container in Proxmox
# Downloads from openwrt.org with latest stable or snapshot version, detects bridges/devices, IDs, configures network, sets optional password
# Pre-configures WAN/LAN in UCI, includes summary and confirmation, optional LuCI install for snapshots with apk

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

# Check required tools (NO BC!)
for cmd in wget pct pvesm ip curl whiptail pvesh bridge stat; do
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

# Whiptail inputbox function
whiptail_input() {
    local title="$1" prompt="$2" default="$3" var="$4"
    local input
    input=$(whiptail --title "$title" --inputbox "$prompt\n\nDefault: $default" 10 50 "$default" 3>&1 1>&2 2>&3) || \
        eval "$var=\"$default\""
    eval "$var=\"${input:-$default}\""
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

# Main execution
echo -e "${GREEN}Fetching latest stable OpenWrt version...${NC}"
STABLE_VER=$(detect_latest_version)
echo -e "${GREEN}Detected latest stable version: $STABLE_VER${NC}"

# Select OpenWrt release type
RELEASE_TYPE=$(whiptail --title "OpenWrt Release Type" --radiolist \
    "Choose the OpenWrt release type (Stable allows manual version input):\nUse Spacebar to select." 10 60 2 \
    "Stable" "Stable version (e.g., $STABLE_VER)" "ON" \
    "Snapshot" "Latest daily snapshot" "OFF" 3>&1 1>&2 2>&3) || exit_script 1 "Error: Release type selection aborted"

if [ "$RELEASE_TYPE" = "Stable" ]; then
    whiptail_input "OpenWrt Version" "Enter OpenWrt stable version" "$STABLE_VER" VER
    DOWNLOAD_URL="https://downloads.openwrt.org/releases/$VER/targets/x86/64/openwrt-$VER-x86-64-rootfs.tar.gz"
    TEMPLATE_FILE="openwrt-$VER-$ARCH.tar.gz"
else
    VER="snapshot"
    DOWNLOAD_URL="https://downloads.openwrt.org/snapshots/targets/x86/64/openwrt-x86-64-rootfs.tar.gz"
    TEMPLATE_FILE="openwrt-snapshot-$ARCH.tar.gz"
    # Prompt for LuCI installation
    if whiptail --title "Install LuCI" --yesno "Would you like to automatically install LuCI (graphical web interface) for the snapshot?" 10 60 3>&1 1>&2 2>&3; then
        INSTALL_LUCI=1
    else
        INSTALL_LUCI=0
    fi
fi

NEXT_CTID=$(detect_next_ctid)
whiptail_input "Container ID" "Enter Container ID" "$NEXT_CTID" CTID
whiptail_input "Container Name" "Enter Container Name" "openwrt-$CTID" CTNAME

# Password prompt using whiptail passwordbox
while true; do
    PASSWORD=$(whiptail --title "Root Password" --passwordbox "Enter root password (leave blank to skip)" 10 50 3>&1 1>&2 2>&3)
    [ $? -ne 0 ] && PASSWORD=""  # Cancel = blank password
    PASSWORD_CONFIRM=$(whiptail --title "Confirm Password" --passwordbox "Confirm root password" 10 50 3>&1 1>&2 2>&3)
    [ $? -ne 0 ] && continue  # Cancel = retry
    
    if [ -z "$PASSWORD" ] && [ -z "$PASSWORD_CONFIRM" ]; then
        echo -e "${GREEN}Root password skipped.${NC}"
        break
    elif [ "$PASSWORD" = "$PASSWORD_CONFIRM" ]; then
        break
    else
        whiptail --title "Error" --msgbox "Passwords do not match. Please try again." 8 50
    fi
done

# sysntpd prompt (DEFAULT: DISABLED)
DISABLE_SYNTPD=$(whiptail --title "Disable sysntpd Service" --radiolist \
    "Disable sysntpd (NTP time sync service)?\n\nThis removes sysntpd from startup (recommended for containers).\nUse Spacebar to select." 12 60 2 \
    "Yes" "Disable sysntpd (DEFAULT)" "ON" \
    "No" "Keep sysntpd enabled" "OFF" 3>&1 1>&2 2>&3) || exit_script 1 "Error: sysntpd selection aborted"

whiptail_input "Memory Size" "Enter memory size in MB" "$DEFAULT_MEMORY" MEMORY
whiptail_input "CPU Cores" "Enter number of CPU cores" "$DEFAULT_CORES" CORES
whiptail_input "Storage Size" "Enter storage limit in GB" "$DEFAULT_STORAGE" STORAGE_SIZE
whiptail_input "LAN Subnet" "Enter LAN subnet" "$DEFAULT_SUBNET" SUBNET

# YOUR ORIGINAL STORAGE LOGIC - FIXED WITH AWK
[[ "$CTID" =~ ^[0-9]+$ && "$CTID" -ge 100 ]] || exit_script 1 "Error: Container ID must be a number >= 100"
pct list | awk '{print $1}' | grep -q "^$CTID$" && exit_script 1 "Error: Container ID $CTID is already in use"
[[ "$MEMORY" =~ ^[0-9]+$ && "$MEMORY" -ge 64 ]] || exit_script 1 "Error: Memory size must be a number >= 64 MB"
[[ "$CORES" =~ ^[0-9]+$ && "$CORES" -ge 1 ]] || exit_script 1 "Core count must be a number >= 1"
[[ "$STORAGE_SIZE" =~ ^[0-9]*\.?[0-9]+$ && $(echo "$STORAGE_SIZE > 0" | awk '{if ($1 > 0) print 1; else print 0}') -eq 1 ]] || exit_script 1 "Error: Storage limit must be a positive number"

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

WAN_BRIDGE=""; WAN_DEVICE=""
if [ "${WAN_OPTION#bridge:}" != "$WAN_OPTION" ]; then
    WAN_BRIDGE="${WAN_OPTION#bridge:}"
elif [ "${WAN_OPTION#device:}" != "$WAN_OPTION" ]; then
    WAN_DEVICE="${WAN_OPTION#device:}"
fi

LAN_BRIDGE=""; LAN_DEVICE=""
if [ "${LAN_OPTION#bridge:}" != "$LAN_OPTION" ]; then
    LAN_BRIDGE="${LAN_OPTION#bridge:}"
elif [ "${LAN_OPTION#device:}" != "$LAN_OPTION" ]; then
    LAN_DEVICE="${LAN_OPTION#device:}"
fi

# Summary and confirmation
SUMMARY="Container Configuration Summary:\n"
SUMMARY+="  OpenWrt Version: $VER\n"
SUMMARY+="  Container ID: $CTID\n"
SUMMARY+="  Container Name: $CTNAME\n"
SUMMARY+="  Root Password: $( [ -n "$PASSWORD" ] && echo "Set" || echo "Not set" )\n"
SUMMARY+="  sysntpd Service: $( [ "$DISABLE_SYNTPD" = "Yes" ] && echo "DISABLED" || echo "Enabled" )\n"
SUMMARY+="  Memory: $MEMORY MB\n"
SUMMARY+="  CPU Cores: $CORES\n"
SUMMARY+="  Storage: $STORAGE_SIZE GB on $STORAGE\n"
SUMMARY+="  LAN Subnet: $SUBNET\n"
SUMMARY+="  WAN Interface: ${WAN_BRIDGE:-${WAN_DEVICE:-None}} (eth0, DHCP/DHCPv6)\n"
SUMMARY+="  LAN Interface: ${LAN_BRIDGE:-${LAN_DEVICE:-None}} (eth1, static)\n"
[ "$RELEASE_TYPE" = "Snapshot" ] && [ "$INSTALL_LUCI" -eq 1 ] && SUMMARY+="  LuCI: Will be installed automatically\n"

whiptail --title "Confirm Container Creation" --yesno "$SUMMARY\nProceed with container creation?" 22 60 || exit_script 0 "Container creation aborted by user"

# Download template with snapshot age check
if [ ! -f "$TEMPLATE_DIR/$TEMPLATE_FILE" ]; then
    echo -e "${GREEN}Downloading OpenWrt $VER rootfs...${NC}"
    wget -q "$DOWNLOAD_URL" -O "$TEMPLATE_DIR/$TEMPLATE_FILE" || exit_script 1 "Error: Failed to download OpenWrt $VER image"
else
    if [ "$RELEASE_TYPE" = "Snapshot" ]; then
        # Check if snapshot file is older than 1 day (86400 seconds)
        FILE_AGE=$(($(date +%s) - $(stat -c %Y "$TEMPLATE_DIR/$TEMPLATE_FILE")))
        if [ "$FILE_AGE" -gt 86400 ]; then
            echo -e "${GREEN}Snapshot is older than 1 day, refreshing...${NC}"
            rm -f "$TEMPLATE_DIR/$TEMPLATE_FILE"
            wget -q "$DOWNLOAD_URL" -O "$TEMPLATE_DIR/$TEMPLATE_FILE" || exit_script 1 "Error: Failed to download OpenWrt snapshot"
        else
            echo -e "${GREEN}Using existing OpenWrt snapshot: $TEMPLATE_FILE${NC}"
        fi
    else
        echo -e "${GREEN}Using existing OpenWrt image: $TEMPLATE_FILE${NC}"
    fi
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

# Disable sysntpd if selected
if [ "$DISABLE_SYNTPD" = "Yes" ]; then
    echo -e "${GREEN}Disabling sysntpd service...${NC}"
    pct exec "$CTID" -- sh -c "rm -f /etc/rc.d/*sysntpd" || echo -e "${RED}Warning: Failed to disable sysntpd${NC}"
fi

echo -e "${GREEN}Configuring network...${NC}"
pct exec "$CTID" -- sh -c "
    # Configure WAN (eth0) with DHCP and DHCPv6
    uci set network.wan=interface
    uci set network.wan.proto='dhcp'
    uci set network.wan.device='eth0'
    uci set network.wan6=interface
    uci set network.wan6.proto='dhcpv6'
    uci set network.wan6.device='eth0'

    # Configure LAN (eth1) with static IP
    uci set network.lan=interface
    uci set network.lan.proto='static'
    uci set network.@device[0].ports='eth1'
    uci set network.lan.ipaddr='$LAN_IP'
    uci set network.lan.netmask='$LAN_NETMASK'

    # Commit changes and restart network
    uci commit network
    /etc/init.d/network restart" || echo -e "${RED}Warning: Network configuration failed${NC}"

if [ "$RELEASE_TYPE" = "Snapshot" ] && [ "$INSTALL_LUCI" -eq 1 ]; then
    echo -e "${GREEN}Waiting 15 seconds for internet connectivity...${NC}"
    sleep 15
    echo -e "${GREEN}Installing LuCI...${NC}"
    pct exec "$CTID" -- sh -c "apk update; apk add luci" || echo -e "${RED}Warning: LuCI installation failed${NC}"
fi

[ -n "$PASSWORD" ] && {
    echo -e "${GREEN}Setting root password...${NC}"
    echo -e "$PASSWORD\n$PASSWORD" | pct exec "$CTID" -- passwd || echo -e "${RED}Warning: Failed to set root password${NC}"
} || echo -e "${GREEN}Root password not set (left blank).${NC}"

echo -e "${GREEN}Container $CTID ($CTNAME) created and started!${NC}"
echo "Next steps:"
echo "1. Access: pct exec $CTID /bin/sh"
echo "2. Verify network: uci show network"
if [ "$DISABLE_SYNTPD" = "Yes" ]; then
    echo "3. sysntpd: Disabled (removed from startup)"
    NEXT_NUM=4
else
    NEXT_NUM=3
fi

if [ "$RELEASE_TYPE" = "Stable" ]; then
    echo "$NEXT_NUM. LuCI: http://$LAN_IP (if LAN configured)"
    [ -z "$PASSWORD" ] && echo "$((NEXT_NUM + 1)). Set password if needed: pct exec $CTID passwd"
else
    # Snapshot
    if [ "$INSTALL_LUCI" -eq 1 ]; then
        echo "$NEXT_NUM. LuCI installed: Access at http://$LAN_IP (if LAN configured)"
        [ -z "$PASSWORD" ] && echo "$((NEXT_NUM + 1)). Set password if needed: pct exec $CTID passwd"
    else
        echo "$NEXT_NUM. Update: apk update"
        echo "$((NEXT_NUM + 1)). Install LuCI: apk add luci"
        [ -n "$LAN_BRIDGE" ] || [ -n "$LAN_DEVICE" ] && echo "$((NEXT_NUM + 2)). LuCI: http://$LAN_IP" || echo "$((NEXT_NUM + 2)). Add eth1 to activate LAN: http://$LAN_IP"
        [ -z "$PASSWORD" ] && echo "$((NEXT_NUM + 3)). Set password if needed: pct exec $CTID passwd"
    fi
fi