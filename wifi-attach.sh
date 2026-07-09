#!/bin/bash
# =============================================================================
# WiFi Adapter Attach — Robustly attach USB WiFi adapters from Windows to WSL
# Handles: bind, attach, vhci drops, retries, verification
# =============================================================================
set -eo pipefail

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok() { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  WiFi Adapter Attach${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

# ── 1. Find Realtek USB WiFi adapters ──
echo -e "${YELLOW}Scanning for USB WiFi adapters...${NC}"

mapfile -t ADAPTERS < <(powershell.exe "usbipd list" 2>/dev/null | grep -i "Realtek\|RTL\|8812\|8814\|8821\|802.11ac\|802.11n.*NIC\|Wireless LAN" | awk '{print $1}')

if [ ${#ADAPTERS[@]} -eq 0 ]; then
    echo ""
    echo -e "  ${RED}No USB WiFi adapters found${NC}"
    echo ""
    echo -e "  Troubleshooting:"
    echo -e "  1. Is the adapter plugged in? Try a different USB port."
    echo -e "  2. Alfa cards need ~500mA — use a powered USB hub if multiple."
    echo -e "  3. Check Windows Device Manager for driver issues."
    echo -e "  4. Run: ${CYAN}usbipd list${NC} in Windows PowerShell."
    echo ""
    exit 1
fi

echo -e "  Found ${#ADAPTERS[@]} adapter(s): ${ADAPTERS[*]}"
echo ""

# ── 2. Load kernel modules ──
echo -e "${YELLOW}Loading kernel modules...${NC}"

if ! lsmod | grep -q "^rtw88_8812au"; then
    if sudo modprobe rtw88_8812au 2>/dev/null; then
        ok "rtw88_8812au driver loaded"
    else
        fail "rtw88_8812au driver not found"
        echo -e "  Run the setup script first: ${CYAN}bash setup.sh${NC}"
        exit 1
    fi
else
    ok "rtw88_8812au driver already loaded"
fi

if ! lsmod | grep -q "^vhci_hcd"; then
    sudo modprobe vhci_hcd 2>/dev/null || true
    ok "vhci_hcd loaded"
else
    ok "vhci_hcd already loaded"
fi

echo ""

# ── 3. Attach each adapter ──
SUCCESS=0
FAILED=0

for BUSID in "${ADAPTERS[@]}"; do
    echo -e "${YELLOW}Attaching ${BUSID}...${NC}"

    # Get current state
    STATE=$(powershell.exe "usbipd list" 2>/dev/null | grep "^${BUSID}" | awk '{print $NF}' | tr -d '\r')

    case "$STATE" in
        "Attached")
            ok "${BUSID} already attached"
            ;;
        *)
            # Bind if needed
            if [ "$STATE" = "Not shared" ] || [ -z "$STATE" ]; then
                echo -n "  Binding... "
                if powershell.exe -Command "Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile -Command usbipd bind --busid ${BUSID} --force'" 2>/dev/null; then
                    ok "Bound"
                else
                    fail "Bind failed — run manually: usbipd bind --busid ${BUSID} --force"
                    ((FAILED++))
                    continue
                fi
            fi

            # Attach with retries (vhci can drop on first attempt)
            ATTACHED=0
            for TRY in 1 2 3; do
                if [ "$TRY" -gt 1 ]; then
                    warn "Retry ${TRY}/3..."
                    sleep 2
                fi

                # Detach first (clean slate)
                powershell.exe -Command "Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile -Command usbipd detach --busid ${BUSID}'" 2>/dev/null || true
                sleep 1

                if powershell.exe -Command "Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile -Command usbipd attach --wsl --busid ${BUSID}'" 2>/dev/null; then
                    sleep 3
                    # Verify device appeared in WSL
                    if lsusb 2>/dev/null | grep -q "0bda:8812"; then
                        ok "USB device attached (attempt ${TRY})"
                        ATTACHED=1
                        break
                    fi
                fi
            done

            if [ "$ATTACHED" -eq 0 ]; then
                fail "Attach failed after 3 attempts for ${BUSID}"
                warn "Try: unplug the adapter, wait 5s, plug it back in, then re-run this script"
                ((FAILED++))
                continue
            fi
            ;;
    esac

    # ── Wait for wlan interface ──
    echo -n "  Waiting for wlan interface... "
    for i in $(seq 1 10); do
        WLAN=$(iw dev 2>/dev/null | grep "Interface" | awk '{print $2}' | head -1)
        if [ -n "$WLAN" ]; then
            echo ""
            ok "Interface: ${WLAN}"
            MAC=$(iw dev "$WLAN" info 2>/dev/null | grep "addr" | awk '{print $2}')
            DRIVER=$(ethtool -i "$WLAN" 2>/dev/null | grep "driver" | awk '{print $2}')
            echo -e "    MAC: ${MAC:-unknown}  Driver: ${DRIVER:-unknown}"
            ((SUCCESS++))
            break
        fi
        sleep 1
        echo -n "."
    done

    if [ -z "$WLAN" ]; then
        echo ""
        fail "wlan interface did not appear for ${BUSID}"
        warn "Check: sudo dmesg | tail -20"
        ((FAILED++))
    fi
    echo ""
done

# ── 4. Summary ──
echo -e "${CYAN}========================================${NC}"
echo -e "${GREEN}  Attached: ${SUCCESS}${NC}  ${RED}Failed: ${FAILED}${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

if [ "$SUCCESS" -gt 0 ]; then
    echo -e "  ${GREEN}Ready to use:${NC}"
    WLAN_COUNT=$(iw dev 2>/dev/null | grep -c "Interface" || true)
    iw dev 2>/dev/null | grep -E "Interface|type|addr" | sed 's/^/    /'
    echo ""
    echo -e "  Enable monitor mode:"
    for IFACE in $(iw dev 2>/dev/null | grep "Interface" | awk '{print $2}'); do
        echo -e "    ${CYAN}sudo ip link set ${IFACE} down${NC}"
        echo -e "    ${CYAN}sudo iw dev ${IFACE} set type monitor${NC}"
        echo -e "    ${CYAN}sudo ip link set ${IFACE} up${NC}"
    done
else
    echo -e "  ${RED}No adapters attached.${NC}"
    echo -e "  Try manual attach from Windows PowerShell (Admin):"
    for BUSID in "${ADAPTERS[@]}"; do
        echo -e "    ${CYAN}usbipd bind --busid ${BUSID} --force${NC}"
        echo -e "    ${CYAN}usbipd attach --wsl --busid ${BUSID}${NC}"
    done
fi

echo ""
exit $FAILED
