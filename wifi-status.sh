#!/bin/bash
# =============================================================================
# WiFi Adapter Status — Show where your adapters are (Windows vs WSL)
# =============================================================================

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  WiFi Adapter Status${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

# ── Windows: USB WiFi adapters via usbipd ──
echo -e "${YELLOW}USB WiFi adapters (Windows):${NC}"
echo ""

HAS_ADAPTERS=0
while IFS= read -r line; do
    if echo "$line" | grep -q "Realtek\|RTL\|8812\|8814\|8821\|802.11ac\|802.11n.*NIC\|Wireless LAN"; then
        BUSID=$(echo "$line" | awk '{print $1}')
        DEVICE=$(echo "$line" | cut -c8-)
        STATE=$(echo "$line" | awk '{print $NF}')

        case "$STATE" in
            "Attached")    COLOR="$GREEN"; STATUS="→ In WSL (as wlan)" ;;
            "Shared"*)     COLOR="$YELLOW"; STATUS="→ Ready to attach" ;;
            "Not shared")  COLOR="$RED"; STATUS="→ In Windows only" ;;
            *)             COLOR="$NC"; STATUS="$STATE" ;;
        esac

        echo -e "  ${COLOR}${BUSID}  ${DEVICE}  ${STATUS}${NC}"
        HAS_ADAPTERS=1
    fi
done < <(powershell.exe "usbipd list" 2>/dev/null | grep -E '^[0-9]')

if [ "$HAS_ADAPTERS" -eq 0 ]; then
    echo -e "  ${RED}No USB WiFi adapters detected${NC}"
    echo -e "  Make sure the adapter is plugged in and drivers are installed."
fi

echo ""

# ── WSL: Wireless interfaces ──
echo -e "${YELLOW}Wireless interfaces (WSL):${NC}"
echo ""

WLAN_COUNT=$(iw dev 2>/dev/null | grep -c "Interface" || true)
if [ "$WLAN_COUNT" -gt 0 ]; then
    while IFS= read -r line; do
        IFACE=$(echo "$line" | awk '{print $2}')
        MODE=$(iw dev "$IFACE" info 2>/dev/null | grep "type" | awk '{print $2}')
        CHAN=$(iw dev "$IFACE" info 2>/dev/null | grep "channel" | awk '{print $2}' | head -1)
        MAC=$(iw dev "$IFACE" info 2>/dev/null | grep "addr" | awk '{print $2}')
        echo -e "  ${GREEN}${IFACE}  Mode: ${MODE}  Channel: ${CHAN:-n/a}  MAC: ${MAC}${NC}"
    done < <(iw dev 2>/dev/null | grep "Interface")
else
    echo -e "  ${RED}No wireless interfaces in WSL${NC}"
    echo -e "  Run: ${CYAN}sudo modprobe rtw88_8812au${NC}"
fi

echo ""

# ── Quick actions ──
echo -e "${CYAN}Quick actions:${NC}"
echo ""
echo -e "  ${YELLOW}Attach adapter to WSL:${NC}"
echo -e "    ${CYAN}sudo modprobe rtw88_8812au${NC}              # Load driver"
echo -e "    ${CYAN}sudo modprobe vhci_hcd${NC}                  # Enable USB/IP"
echo -e "   (Run in Windows Admin PowerShell):"
echo -e "    ${CYAN}usbipd bind --busid <ID> --force${NC}"
echo -e "    ${CYAN}usbipd attach --wsl --busid <ID>${NC}"
echo ""
echo -e "  ${YELLOW}Return adapter to Windows:${NC}"
echo -e "   (Run in Windows Admin PowerShell):"
echo -e "    ${CYAN}usbipd detach --busid <ID>${NC}"
echo ""
echo -e "  ${YELLOW}Set monitor mode:${NC}"
echo -e "    ${CYAN}sudo ip link set wlan0 down${NC}"
echo -e "    ${CYAN}sudo iw dev wlan0 set type monitor${NC}"
echo -e "    ${CYAN}sudo ip link set wlan0 up${NC}"
echo ""
