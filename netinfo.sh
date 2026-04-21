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

for iface in $(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$'); do

    echo
    printf "  ${B}${G}Interface: %s${N}\n" "$iface"

    # ── Link status & flags ─────────────────────────────────────────────────
    state=$(ip -o link show "$iface" | grep -oP '(?<=state )\S+')
    flags=$(ip -o link show "$iface" | grep -oP '(?<=<)[^>]+')
    lbl "State"         "$state"
    lbl "Flags"         "$flags"

    # ── MAC address ─────────────────────────────────────────────────────────
    mac=$(cat /sys/class/net/"$iface"/address 2>/dev/null)
    lbl "MAC address"   "${mac:-n/a}"

    # ── IP addresses ────────────────────────────────────────────────────────
    ipv4=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet /{print $2}' | paste -sd ', ')
    ipv6=$(ip -6 addr show "$iface" 2>/dev/null | awk '/inet6/{print $2}' | paste -sd ', ')
    lbl "IPv4"          "${ipv4:-none}"
    lbl "IPv6"          "${ipv6:-none}"

    # ── Speed / duplex (ethtool) ─────────────────────────────────────────────
    if cmd_ok ethtool; then
        eth_out=$(ethtool "$iface" 2>/dev/null)
        speed=$(echo "$eth_out" | awk '/Speed:/{print $2}')
        duplex=$(echo "$eth_out" | awk '/Duplex:/{print $2}')
        link=$(echo "$eth_out"  | awk '/Link detected:/{print $3}')
        lbl "Speed"         "${speed:-n/a}"
        lbl "Duplex"        "${duplex:-n/a}"
        lbl "Link detected" "${link:-n/a}"
    fi

    # ── Driver & firmware ────────────────────────────────────────────────────
    if cmd_ok ethtool; then
        drv_out=$(ethtool -i "$iface" 2>/dev/null)
        driver=$(echo  "$drv_out" | awk '/^driver:/{print $2}')
        version=$(echo "$drv_out" | awk '/^version:/{print $2}')
        fw=$(echo      "$drv_out" | awk '/^firmware-version:/{$1=""; print $0}' | xargs)
        bus=$(echo     "$drv_out" | awk '/^bus-info:/{print $2}')
        lbl "Driver"        "${driver:-n/a}"
        lbl "Driver version" "${version:-n/a}"
        lbl "Firmware"      "${fw:-n/a}"
        lbl "Bus / PCI slot" "${bus:-n/a}"
    fi

    # ── Vendor / model from PCI ──────────────────────────────────────────────
    # Try sysfs modalias first (works for both PCI and USB NICs)
    uevent=/sys/class/net/"$iface"/device/uevent
    if [[ -f "$uevent" ]]; then
        pci_id=$(grep -i 'PCI_ID' "$uevent" 2>/dev/null | cut -d= -f2)
        [[ -n "$pci_id" ]] && lbl "PCI ID (vendor:device)" "$pci_id"
    fi
    if cmd_ok lspci && [[ -n "${bus:-}" ]]; then
        model=$(lspci -s "$bus" 2>/dev/null | sed 's/^[^ ]* //')
        [[ -n "$model" ]] && lbl "PCI device"    "$model"
    fi
    # USB NICs (common for docking stations / dongles)
    usb_info=$(ls -l /sys/class/net/"$iface"/device 2>/dev/null | grep usb)
    [[ -n "$usb_info" ]] && lbl "Bus type" "USB"

    # ── MTU ─────────────────────────────────────────────────────────────────
    mtu=$(cat /sys/class/net/"$iface"/mtu 2>/dev/null)
    lbl "MTU"           "${mtu:-n/a}"

    # ── TX queue length ──────────────────────────────────────────────────────
    txq=$(cat /sys/class/net/"$iface"/tx_queue_len 2>/dev/null)
    lbl "TX queue length" "${txq:-n/a}"

    # ── RX / TX statistics ───────────────────────────────────────────────────
    stats=$(ip -s link show "$iface" 2>/dev/null)
    rx_bytes=$(echo "$stats" | awk '/RX:/{getline; print $1}')
    rx_pkts=$( echo "$stats" | awk '/RX:/{getline; print $2}')
    rx_err=$(  echo "$stats" | awk '/RX:/{getline; print $3}')
    rx_drop=$( echo "$stats" | awk '/RX:/{getline; print $4}')
    tx_bytes=$(echo "$stats" | awk '/TX:/{getline; print $1}')
    tx_pkts=$( echo "$stats" | awk '/TX:/{getline; print $2}')
    tx_err=$(  echo "$stats" | awk '/TX:/{getline; print $3}')
    tx_drop=$( echo "$stats" | awk '/TX:/{getline; print $4}')

    # Convert bytes to human-readable
    hr() { numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || echo "${1} B"; }

    lbl "RX bytes"      "$(hr "$rx_bytes")  ($rx_pkts packets)"
    lbl "TX bytes"      "$(hr "$tx_bytes")  ($tx_pkts packets)"

    # Warn if there are errors / drops
    [[ "${rx_err:-0}"  -gt 0 ]] && warn "RX errors"   "$rx_err"
    [[ "${rx_drop:-0}" -gt 0 ]] && warn "RX dropped"  "$rx_drop"
    [[ "${tx_err:-0}"  -gt 0 ]] && warn "TX errors"   "$tx_err"
    [[ "${tx_drop:-0}" -gt 0 ]] && warn "TX dropped"  "$tx_drop"

    # Overruns & collisions from /proc/net/dev
    proc_line=$(awk -v iface="$iface" '$1 ~ iface":" {print}' /proc/net/dev 2>/dev/null)
    if [[ -n "$proc_line" ]]; then
        overrun=$( echo "$proc_line" | awk '{print $6}')
        collis=$(  echo "$proc_line" | awk '{print $15}')
        carrier=$( echo "$proc_line" | awk '{print $16}')
        [[ "${overrun:-0}"  -gt 0 ]] && warn "Overruns"    "$overrun"
        [[ "${collis:-0}"   -gt 0 ]] && warn "Collisions"  "$collis"
        [[ "${carrier:-0}"  -gt 0 ]] && warn "Carrier loss" "$carrier"
    fi

    # ── Wi-Fi specific ───────────────────────────────────────────────────────
    if [[ -d /sys/class/net/"$iface"/wireless ]]; then
        echo
        printf "  ${B}  ↳ Wi-Fi details${N}\n"
        if cmd_ok iw; then
            iw_out=$(iw dev "$iface" info 2>/dev/null)
            ssid=$(echo "$iw_out" | awk '/ssid/{print $2}')
            ch=$(echo   "$iw_out" | awk '/channel/{print $2, $3, $4, $5}')
            type=$(echo "$iw_out" | awk '/type/{print $2}')
            lbl "SSID"          "${ssid:-not associated}"
            lbl "Channel"       "${ch:-n/a}"
            lbl "Mode"          "${type:-n/a}"
            # Station / link quality
            iw_link=$(iw dev "$iface" link 2>/dev/null)
            bssid=$( echo "$iw_link" | awk '/Connected to/{print $3}')
            signal=$(echo "$iw_link" | awk '/signal:/{print $2, $3}')
            rx_bit=$(echo "$iw_link" | awk '/rx bitrate:/{print $3, $4}')
            tx_bit=$(echo "$iw_link" | awk '/tx bitrate:/{print $3, $4}')
            lbl "BSSID (AP MAC)" "${bssid:-n/a}"
            lbl "Signal"        "${signal:-n/a}"
            lbl "RX bitrate"    "${rx_bit:-n/a}"
            lbl "TX bitrate"    "${tx_bit:-n/a}"
        fi
        if cmd_ok iwconfig; then
            iwconfig_out=$(iwconfig "$iface" 2>/dev/null)
            freq=$(echo "$iwconfig_out"  | awk '/Frequency:/{match($0,/Frequency:[^ ]+/); print substr($0,RSTART,RLENGTH)}')
            qual=$(echo "$iwconfig_out"  | awk '/Link Quality/{match($0,/Link Quality=[^ ]+/); print substr($0,RSTART,RLENGTH)}')
            lbl "Frequency"     "${freq:-n/a}"
            lbl "Link quality"  "${qual:-n/a}"
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
