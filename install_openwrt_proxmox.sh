#!/bin/bash

# Script to create an OpenWrt LXC container in Proxmox
# Supports stable, release candidates (with prompt if newer), and snapshots
# Robust template handling (reuse / redownload / corruption check)
# Aborts cleanly on Esc/Cancel in dialogs

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

# Exit handler
exit_script() {
    local code=$1
    local msg=$2
    [ -n "$msg" ] && echo -e "${RED}$msg${NC}"
    exit "$code"
}

# Must run as root
[ "$EUID" -ne 0 ] && exit_script 1 "This script must be run as root"

# Check required commands
for cmd in wget pct pvesm ip curl whiptail pvesh bridge stat tar numfmt; do
    command -v "$cmd" &>/dev/null || exit_script 1 "Required command not found: $cmd"
done

# ────────────────────────────────────────────────
# Helper functions
# ────────────────────────────────────────────────

whiptail_radiolist() {
    local title="$1" prompt="$2" height="$3" width="$4" items=("${@:5}")
    local selection
    selection=$(whiptail --title "$title" --radiolist "$prompt" "$height" "$width" "$((${#items[@]} / 3))" "${items[@]}" 3>&1 1>&2 2>&3) \
        || exit_script 1 "Aborted by user"
    echo "$selection"
}

whiptail_input() {
    local title="$1" prompt="$2" default="$3" var="$4"
    local input
    input=$(whiptail --title "$title" --inputbox "$prompt\n\nDefault: $default" 10 60 "$default" 3>&1 1>&2 2>&3) \
        || exit_script 1 "Aborted by user"
    eval "$var=\"${input:-$default}\""
}

detect_latest_stable() {
    local ver
    ver=$(curl -sSf "https://downloads.openwrt.org/" |
          grep -oP '(?<=OpenWrt )\d+\.\d+\.\d+(?=\s|</strong>|Released)' |
          head -1)
    if [ -z "$ver" ]; then
        ver=$(curl -sSf "https://downloads.openwrt.org/releases/" |
              grep -oE '[0-9]+\.[0-9]+\.[0-9]+' |
              grep -vE '-(rc|beta|alpha|test)' |
              sort -V | tail -1)
    fi
    [ -z "$ver" ] && ver="24.10.5"
    echo "$ver"
}

detect_newest_available() {
    local ver
    ver=$(curl -sSf "https://downloads.openwrt.org/releases/" |
          grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?' |
          sort -V | tail -1)
    [ -z "$ver" ] && ver="$(detect_latest_stable)"
    echo "$ver"
}

select_storage() {
    local -a menu
    while read -r line || [ -n "$line" ]; do
        local tag=$(echo "$line" | awk '{print $1}')
        local type=$(echo "$line" | awk '{printf "%-10s", $2}')
        local free=$(echo "$line" | numfmt --field 4-6 --from-unit=K --to=iec --format %.2f | awk '{printf "%9sB", $6}')
        menu+=("$tag" "Type: $type Free: $free" "OFF")
    done < <(pvesm status -content rootdir | awk 'NR>1')

    [ ${#menu[@]} -eq 0 ] && exit_script 1 "No storage pools found"
    [ $((${#menu[@]} / 3)) -eq 1 ] && echo "${menu[0]}" && return
    whiptail_radiolist "Storage Pools" "Select storage for container:" 16 80 "${menu[@]}"
}

detect_network_options() {
    BRIDGE_LIST=($(ip link | grep -o 'vmbr[0-9]\+' | sort -u))
    BRIDGE_COUNT=${#BRIDGE_LIST[@]}

    local all_devs=$(ip link show | grep -oE '^[0-9]+: ([^:]+):' | awk '{print $2}' | cut -d':' -f1 | grep -vE '^(lo|vmbr|veth|tap|fwbr|fwpr|fwln)')
    readarray -t ALL_DEVICES <<<"$all_devs"

    local bridged_devs=$(bridge link show | cut -d ":" -f2 | cut -d " " -f2)
    readarray -t BRIDGED_DEVICES <<<"$bridged_devs"

    UNBRIDGED_DEVICES=()
    for dev in "${ALL_DEVICES[@]}"; do
        local bridged=false
        for bdev in "${BRIDGED_DEVICES[@]}"; do [ "$dev" = "$bdev" ] && bridged=true && break; done
        [ "$bridged" = false ] && UNBRIDGED_DEVICES+=("$dev")
    done
    UNBRIDGED_COUNT=${#UNBRIDGED_DEVICES[@]}
}

select_network_option() {
    local type="$1" eth="$2"
    local -a menu=("None" "No network assigned" "OFF")
    for b in "${BRIDGE_LIST[@]}"; do menu+=("bridge:$b" "Bridge $b" "OFF"); done
    for d in "${UNBRIDGED_DEVICES[@]}"; do menu+=("device:$d" "Device $d" "OFF"); done
    whiptail_radiolist "$type Network" "Select for $type ($eth) or None:" 16 60 "${menu[@]}"
}

detect_next_ctid() {
    local id=$(pvesh get /cluster/nextid 2>/dev/null)
    echo "${id:-100}"
}

# ────────────────────────────────────────────────
# Main logic
# ────────────────────────────────────────────────

echo -e "${GREEN}Fetching OpenWrt version info...${NC}"
STABLE_VER=$(detect_latest_stable)
echo -e "${GREEN}Latest stable: $STABLE_VER${NC}"

NEWEST_VER=$(detect_newest_available)

if [ "$NEWEST_VER" != "$STABLE_VER" ] && [[ "$NEWEST_VER" == *"-rc"* ]]; then
    if whiptail --title "Newer RC Available" --yesno \
        "Newer release candidate found:\n  $NEWEST_VER\nStable: $STABLE_VER\n\nUse RC?" \
        12 70 3>&1 1>&2 2>&3; then
        VER="$NEWEST_VER"
        echo -e "${GREEN}Using RC: $VER${NC}"
    else
        VER="$STABLE_VER"
        echo -e "${GREEN}Using stable: $VER${NC}"
    fi
else
    VER="$STABLE_VER"
    echo -e "${GREEN}Using: $VER (no newer RC)${NC}"
fi

RELEASE_TYPE=$(whiptail --title "Release Type" --radiolist \
    "Choose type (Stable allows manual/RC override):" 10 65 2 \
    "Stable"   "Stable or RC (current: $VER)" "ON" \
    "Snapshot" "Latest snapshot"              "OFF" 3>&1 1>&2 2>&3) \
    || exit_script 1 "Aborted by user"

if [ "$RELEASE_TYPE" = "Stable" ]; then
    whiptail_input "OpenWrt Version" "Enter version (stable or RC)" "$VER" VER \
        || exit_script 1 "Aborted by user"
    DOWNLOAD_URL="https://downloads.openwrt.org/releases/$VER/targets/x86/64/openwrt-${VER}-x86-64-rootfs.tar.gz"
    TEMPLATE_FILE="openwrt-${VER}-${ARCH}.tar.gz"
else
    VER="snapshot"
    DOWNLOAD_URL="https://downloads.openwrt.org/snapshots/targets/x86/64/openwrt-x86-64-rootfs.tar.gz"
    TEMPLATE_FILE="openwrt-snapshot-${ARCH}.tar.gz"
    if whiptail --title "LuCI" --yesno "Install LuCI automatically (snapshot)?" 10 60; then
        INSTALL_LUCI=1
    else
        INSTALL_LUCI=0
    fi || exit_script 1 "Aborted by user"
fi

NEXT_CTID=$(detect_next_ctid)
whiptail_input "Container ID" "Enter ID" "$NEXT_CTID" CTID || exit_script 1 "Aborted"
whiptail_input "Container Name" "Enter name" "openwrt-$CTID" CTNAME || exit_script 1 "Aborted"

# Password
while true; do
    PASSWORD=$(whiptail --title "Root Password" --passwordbox "Enter password (blank = skip)" 10 50 3>&1 1>&2 2>&3)
    ret=$?
    [ $ret -ne 0 ] && { PASSWORD=""; break; }
    PASSWORD_CONFIRM=$(whiptail --title "Confirm" --passwordbox "Confirm password" 10 50 3>&1 1>&2 2>&3) \
        || exit_script 1 "Aborted by user"
    if [ -z "$PASSWORD" ] && [ -z "$PASSWORD_CONFIRM" ]; then
        echo -e "${GREEN}Password skipped.${NC}"
        break
    elif [ "$PASSWORD" = "$PASSWORD_CONFIRM" ]; then
        break
    else
        whiptail --title "Error" --msgbox "Passwords do not match." 8 50
    fi
done

DISABLE_SYNTPD=$(whiptail --title "sysntpd" --radiolist \
    "Disable sysntpd (recommended for containers)?" 12 60 2 \
    "Yes" "Disable (default)" "ON" \
    "No"  "Keep enabled"      "OFF" 3>&1 1>&2 2>&3) \
    || exit_script 1 "Aborted by user"

whiptail_input "Memory (MB)"   "Memory size" "$DEFAULT_MEMORY"   MEMORY   || exit_script 1 "Aborted"
whiptail_input "CPU Cores"     "Number of cores" "$DEFAULT_CORES" CORES   || exit_script 1 "Aborted"
whiptail_input "Storage (GB)"  "Storage limit" "$DEFAULT_STORAGE" STORAGE_SIZE || exit_script 1 "Aborted"
whiptail_input "LAN Subnet"    "e.g. 10.23.45.1/24" "$DEFAULT_SUBNET" SUBNET || exit_script 1 "Aborted"

# Basic validation
[[ "$CTID" =~ ^[0-9]+$ && "$CTID" -ge 100 ]] || exit_script 1 "ID must be >= 100"
pct list | awk '{print $1}' | grep -q "^$CTID$" && exit_script 1 "ID $CTID in use"
[[ "$MEMORY" =~ ^[0-9]+$ && "$MEMORY" -ge 64 ]] || exit_script 1 "Memory >= 64"
[[ "$CORES" =~ ^[0-9]+$ && "$CORES" -ge 1 ]] || exit_script 1 "Cores >= 1"
[[ "$STORAGE_SIZE" =~ ^[0-9]*\.?[0-9]+$ && $(echo "$STORAGE_SIZE > 0" | bc) -eq 1 ]] || exit_script 1 "Storage > 0 required"

LAN_IP=$(echo "$SUBNET" | cut -d'/' -f1)
LAN_PREFIX=$(echo "$SUBNET" | cut -d'/' -f2)
case "$LAN_PREFIX" in
    24) LAN_NETMASK="255.255.255.0" ;;
    23) LAN_NETMASK="255.255.254.0" ;;
    22) LAN_NETMASK="255.255.252.0" ;;
    16) LAN_NETMASK="255.255.0.0" ;;
    *) exit_script 1 "Unsupported prefix /$LAN_PREFIX" ;;
esac

STORAGE=$(select_storage)
detect_network_options
[ "$BRIDGE_COUNT" -eq 0 ] && [ "$UNBRIDGED_COUNT" -eq 0 ] && echo -e "${RED}Warning: No network devices found${NC}"

WAN_OPTION=$(select_network_option "WAN" "eth0") || exit_script 1 "Aborted"
LAN_OPTION=$(select_network_option "LAN" "eth1") || exit_script 1 "Aborted"

WAN_BRIDGE=""; WAN_DEVICE=""
[[ "$WAN_OPTION" == bridge:* ]] && WAN_BRIDGE="${WAN_OPTION#bridge:}"
[[ "$WAN_OPTION" == device:* ]] && WAN_DEVICE="${WAN_OPTION#device:}"

LAN_BRIDGE=""; LAN_DEVICE=""
[[ "$LAN_OPTION" == bridge:* ]] && LAN_BRIDGE="${LAN_OPTION#bridge:}"
[[ "$LAN_OPTION" == device:* ]] && LAN_DEVICE="${LAN_OPTION#device:}"

# Summary
SUMMARY="Summary:\n"
SUMMARY+="  Version: $VER\n"
SUMMARY+="  ID/Name: $CTID / $CTNAME\n"
SUMMARY+="  Password: $( [ -n "$PASSWORD" ] && echo Set || echo Skipped )\n"
SUMMARY+="  sysntpd:  $( [ "$DISABLE_SYNTPD" = "Yes" ] && echo DISABLED || echo Enabled )\n"
SUMMARY+="  Memory/Cores/Storage: $MEMORY MB / $CORES / $STORAGE_SIZE GB on $STORAGE\n"
SUMMARY+="  LAN: $SUBNET\n"
SUMMARY+="  WAN: ${WAN_BRIDGE:-${WAN_DEVICE:-None}} (eth0)\n"
SUMMARY+="  LAN: ${LAN_BRIDGE:-${LAN_DEVICE:-None}} (eth1)\n"
[ "$RELEASE_TYPE" = "Snapshot" ] && [ "${INSTALL_LUCI:-0}" -eq 1 ] && SUMMARY+="  LuCI: auto-install\n"

whiptail --title "Confirm" --yesno "$SUMMARY\n\nCreate container?" 22 75 \
    || exit_script 0 "Aborted by user"

# ────────────────────────────────────────────────
# Template handling
# ────────────────────────────────────────────────

TEMPLATE_PATH="$TEMPLATE_DIR/$TEMPLATE_FILE"
download_needed=1

if [ -f "$TEMPLATE_PATH" ]; then
    FILE_SIZE=$(stat -c %s "$TEMPLATE_PATH" 2>/dev/null || echo 0)
    if [ "$FILE_SIZE" -eq 0 ]; then
        echo -e "${RED}Existing file empty → redownload${NC}"
        rm -f "$TEMPLATE_PATH"
    elif ! tar tzf "$TEMPLATE_PATH" >/dev/null 2>&1; then
        echo -e "${RED}Corrupt template detected${NC}"
        if whiptail --title "Corrupt File" --yesno "Redownload?" 10 60; then
            rm -f "$TEMPLATE_PATH"
        else
            exit_script 1 "Aborted - corrupt file kept"
        fi
    else
        SIZE_H=$(numfmt --to=iec --format %.2f "$FILE_SIZE")
        if whiptail --title "Reuse Template?" --yesno \
            "Found:\n  $TEMPLATE_FILE\n  Size: $SIZE_H\n\nReuse? (No = redownload)" 12 70; then
            echo -e "${GREEN}Reusing existing template${NC}"
            download_needed=0
        else
            rm -f "$TEMPLATE_PATH"
        fi
    fi
fi

if [ "$RELEASE_TYPE" = "Snapshot" ] && [ "$download_needed" -eq 0 ]; then
    FILE_AGE=$(($(date +%s) - $(stat -c %Y "$TEMPLATE_PATH" 2>/dev/null || echo 0)))
    if [ "$FILE_AGE" -gt 86400 ]; then
        echo -e "${GREEN}Snapshot >1 day old → refreshing${NC}"
        rm -f "$TEMPLATE_PATH"
        download_needed=1
    fi
fi

if [ "$download_needed" -eq 1 ]; then
    echo -e "${GREEN}Downloading $VER rootfs...${NC}"
    wget --show-progress "$DOWNLOAD_URL" -O "$TEMPLATE_PATH.part" || {
        rm -f "$TEMPLATE_PATH.part"
        exit_script 1 "Download failed"
    }
    mv "$TEMPLATE_PATH.part" "$TEMPLATE_PATH"
    if ! tar tzf "$TEMPLATE_PATH" >/dev/null 2>&1; then
        rm -f "$TEMPLATE_PATH"
        exit_script 1 "Downloaded file corrupt"
    fi
    echo -e "${GREEN}Download verified${NC}"
fi

# ────────────────────────────────────────────────
# Container creation
# ────────────────────────────────────────────────

echo -e "${GREEN}Creating container $CTID...${NC}"
NET_OPTS=()
[ -n "$WAN_BRIDGE" ] && NET_OPTS+=("--net0" "name=eth0,bridge=$WAN_BRIDGE")
[ -n "$WAN_DEVICE" ] && NET_OPTS+=("--net0" "name=eth0,hwaddr=$(ip link show "$WAN_DEVICE" | grep -o 'ether [0-9a-f:]\+' | cut -d' ' -f2)")
[ -n "$LAN_BRIDGE" ] && NET_OPTS+=("--net1" "name=eth1,bridge=$LAN_BRIDGE")
[ -n "$LAN_DEVICE" ] && NET_OPTS+=("--net1" "name=eth1,hwaddr=$(ip link show "$LAN_DEVICE" | grep -o 'ether [0-9a-f:]\+' | cut -d' ' -f2)")

pct create "$CTID" "$TEMPLATE_PATH" \
    --arch amd64 \
    --hostname "$CTNAME" \
    --rootfs "$STORAGE:$STORAGE_SIZE" \
    --memory "$MEMORY" \
    --cores "$CORES" \
    --unprivileged 1 \
    --features nesting=1 \
    --ostype unmanaged \
    "${NET_OPTS[@]}" || exit_script 1 "pct create failed"

pct start "$CTID" || exit_script 1 "pct start failed"

sleep 5

pct exec "$CTID" -- sh -c "sed -i 's!procd_add_jail!: procd_add_jail!g' /etc/init.d/dnsmasq" 2>/dev/null

[ "$DISABLE_SYNTPD" = "Yes" ] && {
    echo -e "${GREEN}Disabling sysntpd...${NC}"
    pct exec "$CTID" -- sh -c "rm -f /etc/rc.d/*sysntpd" 2>/dev/null
}

echo -e "${GREEN}Configuring network...${NC}"
pct exec "$CTID" -- sh -c "
    uci set network.wan=interface;    uci set network.wan.proto='dhcp';     uci set network.wan.device='eth0'
    uci set network.wan6=interface;   uci set network.wan6.proto='dhcpv6';  uci set network.wan6.device='eth0'
    uci set network.lan=interface;    uci set network.lan.proto='static';   uci set network.@device[0].ports='eth1'
    uci set network.lan.ipaddr='$LAN_IP'; uci set network.lan.netmask='$LAN_NETMASK'
    uci commit network; /etc/init.d/network restart
" || echo -e "${RED}Network config warning${NC}"

[ "$RELEASE_TYPE" = "Snapshot" ] && [ "${INSTALL_LUCI:-0}" -eq 1 ] && {
    echo -e "${GREEN}Installing LuCI...${NC}"
    sleep 15
    pct exec "$CTID" -- sh -c "apk update && apk add luci" || echo -e "${RED}LuCI install failed${NC}"
}

[ -n "$PASSWORD" ] && {
    echo -e "${GREEN}Setting password...${NC}"
    echo -e "$PASSWORD\n$PASSWORD" | pct exec "$CTID" -- passwd || echo -e "${RED}Password set failed${NC}"
}

echo -e "${GREEN}Done! Container $CTID ($CTNAME) ready.${NC}"
echo "Next:"
echo "  pct exec $CTID /bin/sh"
echo "  uci show network"
[ "$DISABLE_SYNTPD" = "Yes" ] && { echo "  sysntpd disabled"; NEXT=4; } || NEXT=3
if [ "$RELEASE_TYPE" = "Stable" ]; then
    echo "  $NEXT. LuCI: http://$LAN_IP (if LAN up)"
    [ -z "$PASSWORD" ] && echo "  $((NEXT+1)). Set password: pct exec $CTID passwd"
else
    if [ "${INSTALL_LUCI:-0}" -eq 1 ]; then
        echo "  $NEXT. LuCI → http://$LAN_IP"
        [ -z "$PASSWORD" ] && echo "  $((NEXT+1)). Set password: pct exec $CTID passwd"
    else
        echo "  $NEXT.   apk update"
        echo "  $((NEXT+1)). apk add luci"
        echo "  $((NEXT+2)). http://$LAN_IP (after LAN config)"
        [ -z "$PASSWORD" ] && echo "  $((NEXT+3)). Set password: pct exec $CTID passwd"
    fi
fi

exit 0