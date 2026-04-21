#!/usr/bin/env bash
# netinfo.sh — Network & NIC information for Ubuntu 24.04
# Usage: sudo bash netinfo.sh

# ── Colours ────────────────────────────────────────────────────────────────────
B='\033[1m'          # bold
C='\033[1;36m'       # cyan  (section headers)
Y='\033[1;33m'       # yellow (field labels)
G='\033[0;32m'       # green
R='\033[0;31m'       # red
N='\033[0m'          # reset

sep()  { printf "${C}%s${N}\n" "──────────────────────────────────────────────────────────"; }
hdr()  { echo; sep; printf "${C}  %s${N}\n" "$1"; sep; }
lbl()  { printf "  ${Y}%-28s${N} %s\n" "$1" "$2"; }
warn() { printf "  ${R}%-28s${N} %s\n" "⚠  $1" "$2"; }
cmd_ok() { command -v "$1" &>/dev/null; }

# ── Root check ─────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo -e "${R}Run as root for full hardware details:${N}  sudo bash $0"
    echo "(Continuing — some fields may be blank)"
    echo
fi

# ── Auto-install missing packages ───────────────────────────────────────────────
#    Map: binary → apt package name
declare -A PKGS=(
    [ethtool]="ethtool"
    [iw]="iw"
    [iwconfig]="wireless-tools"
    [lspci]="pciutils"
    [lsusb]="usbutils"
    [ss]="iproute2"
    [resolvectl]="systemd"
    [ufw]="ufw"
    [iptables]="iptables"
    [numfmt]="coreutils"
    [lshw]="lshw"
    [dmidecode]="dmidecode"
)

missing=()
for bin in "${!PKGS[@]}"; do
    cmd_ok "$bin" || missing+=("${PKGS[$bin]}")
done

# De-duplicate the list
mapfile -t missing < <(printf '%s\n' "${missing[@]}" | sort -u)

if [[ ${#missing[@]} -gt 0 ]]; then
    echo -e "${Y}The following packages are missing and will be installed:${N}"
    printf "  • %s\n" "${missing[@]}"
    echo

    if [[ $EUID -ne 0 ]]; then
        echo -e "${R}Cannot install packages without root.${N} Re-run with sudo, or install manually:"
        echo "  sudo apt install ${missing[*]}"
        echo
    else
        echo -e "${C}Updating package list…${N}"
        apt-get update -qq

        echo -e "${C}Installing: ${missing[*]}${N}"
        apt-get install -y -qq "${missing[@]}" \
            && echo -e "${G}All packages installed successfully.${N}\n" \
            || echo -e "${R}Some packages failed to install — output above may be incomplete.${N}\n"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
hdr "SYSTEM"
lbl "Hostname"      "$(hostname -f 2>/dev/null || hostname)"
lbl "Kernel"        "$(uname -r)"
lbl "OS"            "$(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '\"')"
lbl "Date / Time"   "$(date '+%F %T %Z')"

# ══════════════════════════════════════════════════════════════════════════════
hdr "NETWORK INTERFACES"

hr() { numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || echo "${1} B"; }

for iface in $(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$'); do

    echo
    sep
    printf "  ${B}${G}%-20s${N}\n" "INTERFACE: $iface"
    sep

    # ════════════════════════════════════════════════════════
    # ①  HARDWARE IDENTITY  — physical NIC name & chip details
    # ════════════════════════════════════════════════════════
    printf "\n  ${B}${C}▸ Hardware Identity${N}\n"

    # Collect ethtool driver info early — bus slot is needed below
    drv_out=""; driver=""; drv_ver=""; fw=""; bus=""
    if cmd_ok ethtool; then
        drv_out=$(ethtool -i "$iface" 2>/dev/null)
        driver=$(echo  "$drv_out" | awk '/^driver:/{print $2}')
        drv_ver=$(echo "$drv_out" | awk '/^version:/{print $2}')
        fw=$(echo      "$drv_out" | awk '/^firmware-version:/{$1=""; print $0}' | xargs)
        bus=$(echo     "$drv_out" | awk '/^bus-info:/{print $2}')
    fi

    # ── Kernel interface name ────────────────────────────────
    lbl "Interface name (kernel)" "$iface"

    # ── Physical / permanent name via udevadm ───────────────
    phys_name=$(udevadm info /sys/class/net/"$iface" 2>/dev/null \
        | awk -F= '/ID_NET_NAME_PATH=|ID_NET_NAME_ONBOARD=|ID_NET_NAME_SLOT=/{print $2; exit}')
    [[ -n "$phys_name" ]] && lbl "Physical name (udev)" "$phys_name"

    # Permanent MAC (differs from active MAC on bonded/renamed NICs)
    perm_mac=$(ethtool -P "$iface" 2>/dev/null | awk '{print $NF}')
    [[ -n "$perm_mac" && "$perm_mac" != "00:00:00:00:00:00" ]] \
        && lbl "Permanent MAC" "$perm_mac"

    # ── PCI / USB hardware identification ───────────────────
    uevent=/sys/class/net/"$iface"/device/uevent
    pci_id=""; vendor_id=""; device_id=""; subsys=""

    if [[ -f "$uevent" ]]; then
        pci_id=$(   grep -i '^PCI_ID='      "$uevent" 2>/dev/null | cut -d= -f2)
        subsys=$(   grep -i '^PCI_SUBSYS_ID' "$uevent" 2>/dev/null | cut -d= -f2)
        vendor_id=$(echo "$pci_id" | cut -d: -f1)
        device_id=$( echo "$pci_id" | cut -d: -f2)
    fi

    # Try sysfs vendor/device files as fallback
    [[ -z "$vendor_id" ]] && vendor_id=$(cat /sys/class/net/"$iface"/device/vendor  2>/dev/null)
    [[ -z "$device_id" ]] && device_id=$(cat /sys/class/net/"$iface"/device/device  2>/dev/null)
    [[ -z "$subsys"    ]] && subsys=$(cat    /sys/class/net/"$iface"/device/subsystem_device 2>/dev/null)

    # ── Full model name ──────────────────────────────────────
    # Priority: lspci verbose > lshw > sysfs
    model=""
    if cmd_ok lspci && [[ -n "$bus" ]]; then
        # -vmm gives structured output; grep the Device field
        model=$(lspci -vmm -s "$bus" 2>/dev/null | awk -F'\t' '/^Device:/{print $2; exit}')
        # Also grab vendor name from lspci
        hw_vendor=$(lspci -vmm -s "$bus" 2>/dev/null | awk -F'\t' '/^Vendor:/{print $2; exit}')
        hw_class=$( lspci -vmm -s "$bus" 2>/dev/null | awk -F'\t' '/^Class:/{print $2; exit}')
        hw_svendor=$(lspci -vmm -s "$bus" 2>/dev/null | awk -F'\t' '/^SVendor:/{print $2; exit}')
        hw_sdevice=$(lspci -vmm -s "$bus" 2>/dev/null | awk -F'\t' '/^SDevice:/{print $2; exit}')
    fi

    if [[ -z "$model" ]] && cmd_ok lshw; then
        model=$(lshw -class network -businfo 2>/dev/null \
            | awk -v bus="$bus" '$1 ~ bus {$1=$2=""; sub(/^[ \t]+/,"",$0); print}')
    fi

    [[ -n "$model"      ]] && printf "  ${Y}%-28s${N} ${B}%s${N}\n" "Model" "$model"
    [[ -n "$hw_vendor"  ]] && lbl "Vendor"          "$hw_vendor"
    [[ -n "$hw_class"   ]] && lbl "Class"           "$hw_class"
    [[ -n "$hw_svendor" ]] && lbl "Subsystem vendor" "$hw_svendor"
    [[ -n "$hw_sdevice" ]] && lbl "Subsystem model"  "$hw_sdevice"

    # Formatted PCI IDs  (like: 8086:7E40)
    if [[ -n "$pci_id" ]]; then
        lbl "PCI ID (vendor:device)" "$pci_id"
        [[ -n "$subsys" ]] && lbl "PCI Subsystem ID" "$subsys"
    fi

    # USB NICs
    if ls -l /sys/class/net/"$iface"/device 2>/dev/null | grep -q usb; then
        lbl "Bus type" "USB"
        usb_id=$(cat /sys/class/net/"$iface"/device/../idVendor 2>/dev/null):$(cat /sys/class/net/"$iface"/device/../idProduct 2>/dev/null)
        usb_mfr=$(cat /sys/class/net/"$iface"/device/../manufacturer 2>/dev/null)
        usb_prod=$(cat /sys/class/net/"$iface"/device/../product 2>/dev/null)
        [[ -n "$usb_mfr"  ]] && lbl "USB Manufacturer" "$usb_mfr"
        [[ -n "$usb_prod" ]] && lbl "USB Product"      "$usb_prod"
        [[ "$usb_id" != ":" ]] && lbl "USB ID (vid:pid)" "$usb_id"
    fi

    lbl "Bus / PCI slot"    "${bus:-n/a}"

    # ── Driver & firmware ────────────────────────────────────
    printf "\n  ${B}${C}▸ Driver & Firmware${N}\n"
    lbl "Driver"            "${driver:-n/a}"
    lbl "Driver version"    "${drv_ver:-n/a}"
    lbl "Firmware version"  "${fw:-n/a}"

    # Kernel module path
    if [[ -n "$driver" ]]; then
        mod_path=$(modinfo "$driver" 2>/dev/null | awk '/^filename:/{print $2}')
        mod_ver=$(modinfo  "$driver" 2>/dev/null | awk '/^version:/{print $2}')
        mod_desc=$(modinfo "$driver" 2>/dev/null | awk '/^description:/{$1=""; print $0}' | xargs)
        [[ -n "$mod_path" ]] && lbl "Kernel module path"   "$mod_path"
        [[ -n "$mod_ver"  ]] && lbl "Kernel module version" "$mod_ver"
        [[ -n "$mod_desc" ]] && lbl "Module description"   "$mod_desc"
    fi

    # ethtool extra capabilities
    if cmd_ok ethtool && [[ -n "$bus" ]]; then
        ee_out=$(ethtool "$iface" 2>/dev/null)
        auto=$(echo "$ee_out" | awk '/Auto-negotiation:/{print $2}')
        sup=$(echo  "$ee_out" | awk '/Supported ports:/{gsub(/[\[\]]/,""); $1=$2=""; print $0}' | xargs)
        [[ -n "$auto" ]] && lbl "Auto-negotiation"   "$auto"
        [[ -n "$sup"  ]] && lbl "Supported ports"    "$sup"
    fi

    # ════════════════════════════════════════════════════════
    # ②  LINK & IP INFO
    # ════════════════════════════════════════════════════════
    printf "\n  ${B}${C}▸ Link & IP${N}\n"

    state=$(ip -o link show "$iface" | grep -oP '(?<=state )\S+')
    flags=$(ip -o link show "$iface" | grep -oP '(?<=<)[^>]+')
    mac=$(cat /sys/class/net/"$iface"/address 2>/dev/null)
    mtu=$(cat /sys/class/net/"$iface"/mtu 2>/dev/null)
    txq=$(cat /sys/class/net/"$iface"/tx_queue_len 2>/dev/null)
    ipv4=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet /{print $2}' | paste -sd ', ')
    ipv6=$(ip -6 addr show "$iface" 2>/dev/null | awk '/inet6/{print $2}' | paste -sd ', ')

    lbl "State"             "$state"
    lbl "Flags"             "$flags"
    lbl "MAC address"       "${mac:-n/a}"
    lbl "IPv4"              "${ipv4:-none}"
    lbl "IPv6"              "${ipv6:-none}"
    lbl "MTU"               "${mtu:-n/a}"
    lbl "TX queue length"   "${txq:-n/a}"

    # Speed / duplex
    if cmd_ok ethtool; then
        eth_out=$(ethtool "$iface" 2>/dev/null)
        speed=$(echo  "$eth_out" | awk '/Speed:/{print $2}')
        duplex=$(echo "$eth_out" | awk '/Duplex:/{print $2}')
        link=$(echo   "$eth_out" | awk '/Link detected:/{print $3}')
        lbl "Speed"             "${speed:-n/a}"
        lbl "Duplex"            "${duplex:-n/a}"
        lbl "Link detected"     "${link:-n/a}"
    fi

    # ════════════════════════════════════════════════════════
    # ③  RX / TX STATISTICS & ERRORS
    # ════════════════════════════════════════════════════════
    printf "\n  ${B}${C}▸ Statistics${N}\n"

    stats=$(ip -s link show "$iface" 2>/dev/null)
    rx_bytes=$(echo "$stats" | awk '/RX:/{getline; print $1}')
    rx_pkts=$( echo "$stats" | awk '/RX:/{getline; print $2}')
    rx_err=$(  echo "$stats" | awk '/RX:/{getline; print $3}')
    rx_drop=$( echo "$stats" | awk '/RX:/{getline; print $4}')
    tx_bytes=$(echo "$stats" | awk '/TX:/{getline; print $1}')
    tx_pkts=$( echo "$stats" | awk '/TX:/{getline; print $2}')
    tx_err=$(  echo "$stats" | awk '/TX:/{getline; print $3}')
    tx_drop=$( echo "$stats" | awk '/TX:/{getline; print $4}')

    lbl "RX"  "$(hr "${rx_bytes:-0}")  packets: $rx_pkts"
    lbl "TX"  "$(hr "${tx_bytes:-0}")  packets: $tx_pkts"

    [[ "${rx_err:-0}"  -gt 0 ]] && warn "RX errors"    "$rx_err"
    [[ "${rx_drop:-0}" -gt 0 ]] && warn "RX dropped"   "$rx_drop"
    [[ "${tx_err:-0}"  -gt 0 ]] && warn "TX errors"    "$tx_err"
    [[ "${tx_drop:-0}" -gt 0 ]] && warn "TX dropped"   "$tx_drop"

    proc_line=$(awk -v i="$iface" '$1 ~ i":" {print}' /proc/net/dev 2>/dev/null)
    if [[ -n "$proc_line" ]]; then
        overrun=$(echo "$proc_line" | awk '{print $6}')
        collis=$( echo "$proc_line" | awk '{print $15}')
        carrier=$(echo "$proc_line" | awk '{print $16}')
        fifo_rx=$(echo "$proc_line" | awk '{print $5}')
        fifo_tx=$(echo "$proc_line" | awk '{print $13}')
        [[ "${overrun:-0}"  -gt 0 ]] && warn "Overruns"     "$overrun"
        [[ "${collis:-0}"   -gt 0 ]] && warn "Collisions"   "$collis"
        [[ "${carrier:-0}"  -gt 0 ]] && warn "Carrier loss" "$carrier"
        [[ "${fifo_rx:-0}"  -gt 0 ]] && warn "FIFO RX"      "$fifo_rx"
        [[ "${fifo_tx:-0}"  -gt 0 ]] && warn "FIFO TX"      "$fifo_tx"
    fi

    # ethtool detailed stats (driver-specific counters)
    if cmd_ok ethtool; then
        printf "\n  ${B}  ethtool -S (driver counters):${N}\n"
        ethtool -S "$iface" 2>/dev/null \
            | grep -v '^NIC statistics:' \
            | awk '{printf "    %-36s %s\n", $1, $2}' \
            | head -30
    fi

    # ════════════════════════════════════════════════════════
    # ④  WI-FI DETAILS  (wireless interfaces only)
    # ════════════════════════════════════════════════════════
    if [[ -d /sys/class/net/"$iface"/wireless ]]; then
        printf "\n  ${B}${C}▸ Wi-Fi Details${N}\n"

        if cmd_ok iw; then
            iw_out=$(iw dev "$iface" info 2>/dev/null)
            ssid=$(echo  "$iw_out" | awk '/ssid/{print $2}')
            ch=$(echo    "$iw_out" | awk '/channel/{print $2, $3, $4, $5}')
            type=$(echo  "$iw_out" | awk '/type/{print $2}')
            wdev=$(echo  "$iw_out" | awk '/wdev/{print $2}')
            addr=$(echo  "$iw_out" | awk '/addr/{print $2}')
            lbl "SSID"              "${ssid:-not associated}"
            lbl "Mode"              "${type:-n/a}"
            lbl "Channel"           "${ch:-n/a}"
            lbl "wdev"              "${wdev:-n/a}"
            lbl "Interface address" "${addr:-n/a}"

            iw_link=$(iw dev "$iface" link 2>/dev/null)
            bssid=$(  echo "$iw_link" | awk '/Connected to/{print $3}')
            signal=$( echo "$iw_link" | awk '/signal:/{print $2, $3}')
            rx_bit=$( echo "$iw_link" | awk '/rx bitrate:/{print $3, $4, $5}')
            tx_bit=$( echo "$iw_link" | awk '/tx bitrate:/{print $3, $4, $5}')
            beacon=$( echo "$iw_link" | awk '/beacon int:/{print $3}')
            dtim=$(   echo "$iw_link" | awk '/DTIM period:/{print $3}')
            lbl "BSSID (AP MAC)"    "${bssid:-n/a}"
            lbl "Signal strength"   "${signal:-n/a}"
            lbl "RX bitrate"        "${rx_bit:-n/a}"
            lbl "TX bitrate"        "${tx_bit:-n/a}"
            [[ -n "$beacon" ]] && lbl "Beacon interval"  "$beacon TU"
            [[ -n "$dtim"   ]] && lbl "DTIM period"      "$dtim"

            # Supported bands / frequencies
            printf "\n  ${B}  Supported bands (iw phy):${N}\n"
            phy=$(iw dev "$iface" info 2>/dev/null | awk '/wiphy/{print "phy"$2}')
            iw phy "$phy" info 2>/dev/null \
                | awk '/Band [0-9]|MHz.*dBm/{printf "    %s\n", $0}' \
                | head -20
        fi

        if cmd_ok iwconfig; then
            iwconfig_out=$(iwconfig "$iface" 2>/dev/null)
            freq=$(echo "$iwconfig_out" | awk '/Frequency:/{match($0,/Frequency:[^ ]+/); print substr($0,RSTART,RLENGTH)}')
            qual=$(echo "$iwconfig_out" | awk '/Link Quality/{match($0,/Link Quality=[^ ]+/); print substr($0,RSTART,RLENGTH)}')
            noise=$(echo "$iwconfig_out"| awk '/Noise level/{match($0,/Noise level=[^ ]+/); print substr($0,RSTART,RLENGTH)}')
            pwr=$(echo  "$iwconfig_out" | awk '/Tx-Power/{match($0,/Tx-Power=[^ ]+/); print substr($0,RSTART,RLENGTH)}')
            lbl "Frequency"         "${freq:-n/a}"
            lbl "Link quality"      "${qual:-n/a}"
            lbl "Noise level"       "${noise:-n/a}"
            lbl "TX power"          "${pwr:-n/a}"
        fi
    fi

done

# ══════════════════════════════════════════════════════════════════════════════
hdr "ROUTING TABLE"
ip route show 2>/dev/null | while read -r line; do
    printf "  %s\n" "$line"
done

# ── Default gateway ──────────────────────────────────────────────────────────
gw=$(ip route show default 2>/dev/null | awk '/default via/{print $3, "dev", $5}')
echo
lbl "Default gateway" "${gw:-none}"

# ══════════════════════════════════════════════════════════════════════════════
hdr "DNS CONFIGURATION"
if [[ -f /etc/resolv.conf ]]; then
    while read -r line; do
        [[ "$line" =~ ^#  ]] && continue
        [[ -z "$line"     ]] && continue
        printf "  %s\n" "$line"
    done < /etc/resolv.conf
fi

# systemd-resolved (Ubuntu 24.04 default)
if cmd_ok resolvectl; then
    echo
    printf "  ${B}systemd-resolved status:${N}\n"
    resolvectl status 2>/dev/null \
        | grep -E '(DNS Servers|DNS Domain|DNSSEC|Current Scopes|Protocols)' \
        | while read -r line; do printf "    %s\n" "$line"; done
fi

# ══════════════════════════════════════════════════════════════════════════════
hdr "ACTIVE CONNECTIONS  (ss)"
if cmd_ok ss; then
    ss -tunaep 2>/dev/null \
        | awk 'NR==1{printf "  %-8s %-7s %-26s %-26s %s\n","Proto","State","Local","Peer","Process"; next}
               {printf "  %-8s %-7s %-26s %-26s %s\n",$1,$2,$5,$6,$7}' \
        | head -40
fi

# ══════════════════════════════════════════════════════════════════════════════
hdr "ARP / NEIGHBOUR CACHE"
ip neigh show 2>/dev/null | while read -r line; do
    printf "  %s\n" "$line"
done

# ══════════════════════════════════════════════════════════════════════════════
hdr "PCI NETWORK DEVICES  (lspci)"
if cmd_ok lspci; then
    lspci | grep -iE '(ethernet|network|wireless|wi-fi|wifi|802\.11|wlan)' \
          | while read -r line; do printf "  %s\n" "$line"; done
fi

# ══════════════════════════════════════════════════════════════════════════════
hdr "USB NETWORK DEVICES  (lsusb)"
if cmd_ok lsusb; then
    # Show any USB device that could be a NIC/dongle
    lsusb | grep -iE '(ethernet|network|wireless|wi-fi|802\.11|rndis|cdc|asix|rtl|ax88)' \
          | while read -r line; do printf "  %s\n" "$line"; done \
          || echo "  (none detected)"
fi

# ══════════════════════════════════════════════════════════════════════════════
hdr "FIREWALL  (ufw)"
if cmd_ok ufw; then
    ufw status verbose 2>/dev/null | while read -r line; do
        printf "  %s\n" "$line"
    done
else
    echo "  ufw not installed"
fi

# ══════════════════════════════════════════════════════════════════════════════
hdr "IPTABLES SUMMARY  (iptables)"
if cmd_ok iptables; then
    for chain in INPUT OUTPUT FORWARD; do
        count=$(iptables -L "$chain" --line-numbers 2>/dev/null | grep -c '^[0-9]')
        lbl "Chain $chain rules" "$count"
    done
else
    echo "  iptables not available"
fi

# ══════════════════════════════════════════════════════════════════════════════
hdr "NETWORK NAMESPACES"
ip netns list 2>/dev/null | while read -r line; do
    printf "  %s\n" "$line"
done || echo "  (none)"

sep
echo
echo -e "  ${G}Done.${N}  Run with ${B}sudo${N} for full hardware details."
echo
