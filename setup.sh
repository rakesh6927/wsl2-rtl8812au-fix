#!/bin/bash
# =============================================================================
# WSL2 WiFi Monitor Mode — Automated Setup Script
# Enables RTL8812AU USB WiFi adapters with monitor mode in WSL2
# Run this INSIDE WSL (Kali/Ubuntu)
# =============================================================================
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

KERNEL_TAG="linux-msft-wsl-6.18.33.1"
KERNEL_DIR="$HOME/WSL2-Linux-Kernel"
REPO_URL="https://github.com/rakesh6927/wsl2-rtl8812au-fix.git"
REPO_DIR="$HOME/wsl2-rtl8812au-fix"
WIN_USER=$(powershell.exe '$env:USERNAME' 2>/dev/null | tr -d '\r' || cmd.exe /c 'echo %USERNAME%' 2>/dev/null | tr -d '\r')

echo -e "${CYAN}================================================================${NC}"
echo -e "${CYAN}   WSL2 WiFi Monitor Mode — RTL8812AU Setup${NC}"
echo -e "${CYAN}================================================================${NC}"
echo ""

# ── Check WSL2 ────────────────────────────────────────────────────────
echo -e "${YELLOW}[1/9] Checking environment...${NC}"

if ! grep -q "microsoft" /proc/version 2>/dev/null; then
    echo -e "${RED}Error: This script must be run inside WSL2.${NC}"
    exit 1
fi

if [ -z "$WIN_USER" ]; then
    echo -e "${YELLOW}Could not detect Windows username.${NC}"
    read -p "Enter your Windows username: " WIN_USER
fi

WIN_USER=$(echo "$WIN_USER" | tr -d ' \r\n')
echo -e "  Windows user: ${GREEN}$WIN_USER${NC}"

# ── Install dependencies ──────────────────────────────────────────────
echo -e "${YELLOW}[2/9] Installing build dependencies...${NC}"
sudo apt-get update -qq
sudo apt-get install -y -qq \
    build-essential flex bison libssl-dev libelf-dev \
    git dwarves bc libncurses-dev wget firmware-realtek 2>&1 | tail -1
echo -e "  Dependencies: ${GREEN}OK${NC}"

# ── Clone/download this repo ──────────────────────────────────────────
echo -e "${YELLOW}[3/9] Fetching patch & config...${NC}"
if [ -d "$REPO_DIR" ]; then
    cd "$REPO_DIR" && git pull -q 2>/dev/null || true
else
    git clone -q "$REPO_URL" "$REPO_DIR"
fi
echo -e "  Repo: ${GREEN}$REPO_DIR${NC}"

# ── Clone WSL2 kernel source ──────────────────────────────────────────
echo -e "${YELLOW}[4/9] Fetching WSL2 kernel source (shallow clone)...${NC}"
if [ -d "$KERNEL_DIR" ]; then
    echo -e "  Kernel source already exists, skipping clone."
else
    git clone --branch "$KERNEL_TAG" --depth 1 \
        https://github.com/microsoft/WSL2-Linux-Kernel.git "$KERNEL_DIR"
    echo -e "  Kernel source: ${GREEN}$KERNEL_DIR${NC}"
fi

# ── Apply patch ───────────────────────────────────────────────────────
echo -e "${YELLOW}[5/9] Applying RTL8812AU driver patch...${NC}"
cd "$KERNEL_DIR"

PATCH_FILE="$REPO_DIR/0001-rtw88-fix-RTL8812AU-8051-firmware-boot-over-USB.patch"
if git apply --check "$PATCH_FILE" 2>/dev/null; then
    if git apply "$PATCH_FILE" 2>/dev/null; then
        echo -e "  Patch: ${GREEN}Applied${NC}"
    else
        echo -e "  Patch: ${YELLOW}Already applied (or failed — continuing)${NC}"
    fi
else
    echo -e "  Patch: ${YELLOW}Already applied${NC}"
fi

# ── Configure ─────────────────────────────────────────────────────────
echo -e "${YELLOW}[6/9] Configuring kernel...${NC}"
cp "$REPO_DIR/wsl2-wifi.config" .config
make olddefconfig 2>&1 | tail -1
echo -e "  Config: ${GREEN}Ready${NC}"

# ── Build ─────────────────────────────────────────────────────────────
echo -e "${YELLOW}[7/9] Building kernel (this takes 15-25 minutes)...${NC}"
echo -e "  Starting at $(date '+%H:%M:%S')"
START_TIME=$(date +%s)

make -j$(nproc) 2>&1 | while IFS= read -r line; do
    # Print a dot every 100 lines to show progress
    if [[ "$line" == *"CC"* ]] || [[ "$line" == *"LD"* ]] || [[ "$line" == *"AR"* ]]; then
        echo -n "."
    fi
done
echo ""

END_TIME=$(date +%s)
ELAPSED=$(( (END_TIME - START_TIME) / 60 ))
echo -e "  Build completed in ${GREEN}${ELAPSED} minutes${NC}"

# ── Install kernel & modules ──────────────────────────────────────────
echo -e "${YELLOW}[8/9] Installing kernel and modules...${NC}"

# Install modules
sudo make INSTALL_MOD_PATH=/ modules_install 2>&1 | tail -1

# Copy kernel to Windows
KERNEL_DEST="/mnt/c/Users/$WIN_USER/wsl-custom-kernel"
cp arch/x86/boot/bzImage "$KERNEL_DEST"
echo -e "  Kernel installed to: ${GREEN}$KERNEL_DEST${NC}"

# ── Update .wslconfig ─────────────────────────────────────────────────
echo -e "${YELLOW}[9/9] Updating .wslconfig...${NC}"

WSL_CONFIG="/mnt/c/Users/$WIN_USER/.wslconfig"
KERNEL_LINE="kernel=C:\\\\\\\\Users\\\\\\\\$WIN_USER\\\\\\\\wsl-custom-kernel"

if [ -f "$WSL_CONFIG" ]; then
    if grep -q "^kernel=" "$WSL_CONFIG" 2>/dev/null; then
        # Update existing kernel line
        sed -i "s|^kernel=.*|kernel=C:\\\\\\\\Users\\\\\\\\$WIN_USER\\\\\\\\wsl-custom-kernel|" "$WSL_CONFIG"
        echo -e "  .wslconfig: ${GREEN}Updated kernel path${NC}"
    else
        # Append under [wsl2]
        sed -i "/^\[wsl2\]/a kernel=C:\\\\Users\\\\$WIN_USER\\\\wsl-custom-kernel" "$WSL_CONFIG"
        echo -e "  .wslconfig: ${GREEN}Added kernel path${NC}"
    fi
else
    # Create new .wslconfig
    cat > "$WSL_CONFIG" << WSLEND
[wsl2]
kernel=C:\\\\Users\\\\$WIN_USER\\\\wsl-custom-kernel
WSLEND
    echo -e "  .wslconfig: ${GREEN}Created${NC}"
fi

# ── Done ──────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN}   Setup Complete!${NC}"
echo -e "${GREEN}================================================================${NC}"
echo ""
echo -e "  ${YELLOW}Next step:${NC} Restart WSL from Windows PowerShell:"
echo -e "    ${CYAN}wsl --shutdown${NC}"
echo ""
echo -e "  After restart, to use the Alfa adapter:"
echo ""
echo -e "  ${YELLOW}Windows PowerShell (Admin):${NC}"
echo -e "    ${CYAN}usbipd bind --busid <BUSID> --force${NC}"
echo -e "    ${CYAN}usbipd attach --wsl --busid <BUSID>${NC}"
echo ""
echo -e "  ${YELLOW}WSL terminal:${NC}"
echo -e "    ${CYAN}sudo modprobe rtw88_8812au${NC}"
echo -e "    ${CYAN}sudo ip link set wlan0 down${NC}"
echo -e "    ${CYAN}sudo iw dev wlan0 set type monitor${NC}"
echo -e "    ${CYAN}sudo ip link set wlan0 up${NC}"
echo -e "    ${CYAN}sudo wifite${NC}"
echo ""
exit 0
