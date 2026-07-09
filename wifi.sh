#!/bin/bash
# =============================================================================
# WiFi Manager — Show status & attach USB adapters to WSL
# Run without args: show status + auto-attach if needed
# Run with --status : show status only
# Run with --attach : force attach all available adapters
# =============================================================================
set -eo pipefail

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }

MODE="${1:-auto}"  # auto, status, attach

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  WiFi Manager${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

# ============================================================
# STATUS  Show Windows adapters + WSL interfaces
# ============================================================
show_status() {
    echo -e "${YELLOW}USB WiFi adapters:${NC}"
    echo ""

    local found=0
    while IFS= read -r line; do
        if echo "$line" | grep -qiE "Realtek|RTL|8812|8814|8821|802.11ac|802.11n.*NIC|Wireless LAN"; then
            BUSID=$(echo "$line" | awk '{print $1}')
            DEVICE=$(echo "$line" | cut -c8- | sed 's/[[:space:]]*$//')
            RAW_STATE=$(echo "$line" | awk '{print $NF}' | tr -d '\r')

            case "$RAW_STATE" in
                "Attached")      COLOR="$GREEN"; STATUS="→ WSL (wlan)" ;;
                "Shared"*)       COLOR="$YELLOW"; STATUS="→ ready to attach" ;;
                "Not shared")    COLOR="$CYAN"; STATUS="→ Windows only" ;;
                *)               COLOR="$NC"; STATUS="$RAW_STATE" ;;
            esac
            echo -e "  ${COLOR}[${BUSID}]  ${DEVICE}  ${STATUS}${NC}"
            found=1
        fi
    done < <(powershell.exe "usbipd list" 2>/dev/null | grep -E '^[0-9]')

    [ "$found" -eq 0 ] && echo -e "  ${RED}No USB WiFi adapters detected${NC}"
    echo ""

    echo -e "${YELLOW}WSL wireless interfaces:${NC}"
    echo ""

    local wlan=0
    while IFS= read -r line; do
        IFACE=$(echo "$line" | awk '{print $2}')
        MODE=$(iw dev "$IFACE" info 2>/dev/null | grep "type" | awk '{print $2}')
        CHAN=$(iw dev "$IFACE" info 2>/dev/null | grep "channel" | awk '{print $2}' | head -1)
        MAC=$(iw dev "$IFACE" info 2>/dev/null | grep "addr" | awk '{print $2}')
        echo -e "  ${GREEN}${IFACE}  Mode: ${MODE:-unknown}  Ch: ${CHAN:-n/a}  ${MAC}${NC}"
        wlan=1
    done < <(iw dev 2>/dev/null | grep "Interface")

    [ "$wlan" -eq 0 ] && echo -e "  ${YELLOW}None — run with --attach${NC}"
    echo ""
}

# ============================================================
# ATTACH  Load drivers, bind, attach, verify
# ============================================================
do_attach() {
    echo -e "${YELLOW}Loading kernel modules...${NC}"

    if ! lsmod | grep -q "^rtw88_8812au"; then
        if sudo modprobe rtw88_8812au 2>/dev/null; then
            ok "rtw88_8812au loaded"
        else
            fail "rtw88_8812au driver missing — run setup.sh first"
            exit 1
        fi
    else
        ok "rtw88_8812au already loaded"
    fi

    sudo modprobe vhci_hcd 2>/dev/null || true
    ok "vhci_hcd loaded"
    echo ""

    # Find adapters not yet attached
    local adapters=()
    while IFS= read -r line; do
        if echo "$line" | grep -qiE "Realtek|RTL|8812|8814|8821|802.11ac|Wireless LAN"; then
            BUSID=$(echo "$line" | awk '{print $1}')
            STATE=$(echo "$line" | awk '{print $NF}' | tr -d '\r')
            if [ "$STATE" != "Attached" ]; then
                adapters+=("$BUSID")
            fi
        fi
    done < <(powershell.exe "usbipd list" 2>/dev/null | grep -E '^[0-9]')

    if [ ${#adapters[@]} -eq 0 ]; then
        ok "All adapters already attached"
        echo ""
        return 0
    fi

    local success=0
    local failed=0

    for BUSID in "${adapters[@]}"; do
        echo -e "${YELLOW}Attaching ${BUSID}...${NC}"

        # Bind
        echo -n "  Binding... "
        if powershell.exe -Command "Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile -Command usbipd bind --busid ${BUSID} --force'" 2>/dev/null; then
            ok "Bound"
        else
            fail "Bind failed"
            ((failed++)); continue
        fi

        # Attach with retries
        local attached=0
        for TRY in 1 2 3; do
            if [ "$TRY" -gt 1 ]; then
                warn "Retry ${TRY}/3..."
                powershell.exe -Command "Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile -Command usbipd detach --busid ${BUSID}'" 2>/dev/null || true
                sleep 2
            fi

            if powershell.exe -Command "Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile -Command usbipd attach --wsl --busid ${BUSID}'" 2>/dev/null; then
                sleep 3
                if lsusb 2>/dev/null | grep -q "0bda:8812"; then
                    ok "Attached (attempt ${TRY})"
                    attached=1
                    break
                fi
            fi
        done

        if [ "$attached" -eq 0 ]; then
            fail "Attach failed after 3 attempts"
            warn "Try: unplug adapter, wait 5s, plug back in, re-run"
            ((failed++)); continue
        fi

        # Wait for wlan
        echo -n "  Waiting for wlan... "
        local wlan=""
        for i in $(seq 1 10); do
            wlan=$(iw dev 2>/dev/null | grep "Interface" | awk '{print $2}' | head -1)
            [ -n "$wlan" ] && break
            sleep 1
            echo -n "."
        done

        if [ -n "$wlan" ]; then
            echo ""
            local mode=$(iw dev "$wlan" info 2>/dev/null | grep "type" | awk '{print $2}')
            local mac=$(iw dev "$wlan" info 2>/dev/null | grep "addr" | awk '{print $2}')
            ok "${wlan}  Mode: ${mode}  MAC: ${mac}"
            ((success++))
        else
            echo ""
            fail "wlan interface did not appear"
            warn "Check: sudo dmesg | tail -20"
            ((failed++))
        fi
        echo ""
    done

    echo -e "${CYAN}Result:${NC} ${GREEN}${success} attached${NC}  ${RED}${failed} failed${NC}"
    echo ""
}

# ============================================================
# MAIN
# ============================================================
case "$MODE" in
    status)
        show_status
        ;;
    attach)
        show_status
        do_attach
        echo -e "${GREEN}All done. Run 'bash wifi.sh --status' to verify.${NC}"
        ;;
    auto|*)
        show_status

        # Check if any adapters need attaching
        NEED_ATTACH=0
        while IFS= read -r line; do
            STATE=$(echo "$line" | awk '{print $NF}' | tr -d '\r')
            if [ "$STATE" != "Attached" ] && echo "$line" | grep -qiE "Realtek|RTL|8812|Wireless LAN"; then
                NEED_ATTACH=1
                break
            fi
        done < <(powershell.exe "usbipd list" 2>/dev/null | grep -E '^[0-9]')

        if [ "$NEED_ATTACH" -eq 1 ]; then
            echo -e "${YELLOW}Adapters need attaching. Attaching now...${NC}"
            echo ""
            do_attach
        fi

        # Show ready-to-use commands if we have wlan
        if iw dev 2>/dev/null | grep -q "Interface"; then
            echo -e "${GREEN}Monitor mode commands:${NC}"
            for IFACE in $(iw dev 2>/dev/null | grep "Interface" | awk '{print $2}'); do
                echo -e "  ${CYAN}sudo ip link set ${IFACE} down${NC}"
                echo -e "  ${CYAN}sudo iw dev ${IFACE} set type monitor${NC}"
                echo -e "  ${CYAN}sudo ip link set ${IFACE} up${NC}"
            done
            echo ""
            echo -e "  Then: ${CYAN}sudo wifite${NC}  or  ${CYAN}sudo airgeddon${NC}"
        fi
        ;;
esac

echo ""
