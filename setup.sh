#!/bin/bash
# =============================================================================
# WSL2 WiFi Monitor Mode — Automated Setup Script
# Enables RTL8812AU USB WiFi adapters with monitor mode in WSL2
# Run this INSIDE WSL (Kali/Ubuntu/Debian)
# =============================================================================
set -eo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
KERNEL_TAG="linux-msft-wsl-6.18.33.1"
KERNEL_DIR="$HOME/WSL2-Linux-Kernel"
REPO_DIR="$HOME/wsl2-rtl8812au-fix"
BUILD_LOG="$HOME/wsl2-kernel-build.log"

die() { echo -e "${RED}Error: $*${NC}" >&2; exit 1; }
step() { echo -e "${YELLOW}[$1/$TOTAL] $2${NC}"; }
ok() { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
TOTAL=10

# ============================================================
# 0. Pre-flight checks
# ============================================================
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  WSL2 WiFi Monitor Mode — Automated Setup${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

# ── Must be WSL2 ──
grep -q "microsoft" /proc/version 2>/dev/null || die "This script must be run inside WSL2"
ok "Running inside WSL2"

# ── Must have sudo ──
sudo -v 2>/dev/null || die "sudo access required. Run: sudo -v first"
ok "sudo access confirmed"

# ── Detect Windows username ──
WIN_USER=$(powershell.exe '$env:USERNAME' 2>/dev/null | tr -d '\r\n' || true)
if [ -z "$WIN_USER" ]; then
    WIN_USER=$(cmd.exe /c 'echo %USERNAME%' 2>/dev/null | tr -d '\r\n' || true)
fi
if [ -z "$WIN_USER" ]; then
    read -rp "  Enter your Windows username: " WIN_USER
fi
WIN_USER=$(echo "$WIN_USER" | tr -d ' \r\n')
[ -z "$WIN_USER" ] && die "Could not determine Windows username"
ok "Windows user: $WIN_USER"

# ── Check /mnt/c access ──
[ -d "/mnt/c/Users/$WIN_USER" ] || die "/mnt/c/Users/$WIN_USER not found. Is WSL mounted?"
ok "/mnt/c/Users/$WIN_USER accessible"

# ── Disk space (need ~5GB for kernel build) ──
AVAIL_GB=$(df -BG "$HOME" 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G')
if [ -n "$AVAIL_GB" ] && [ "$AVAIL_GB" -lt 5 ]; then
    die "Less than 5GB free in $HOME (have ${AVAIL_GB}GB). Free up space first."
fi
ok "Sufficient disk space"

echo ""

# ============================================================
# 1/9  Check & install dependencies
# ============================================================
step 1 "Checking dependencies..."

DEPS="build-essential flex bison libssl-dev libelf-dev git dwarves bc libncurses-dev wget"
MISSING=""

for pkg in $DEPS; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        MISSING="$MISSING $pkg"
    fi
done

if [ -n "$MISSING" ]; then
    echo -e "  Installing:$MISSING"
    sudo apt-get update -qq 2>/dev/null
    sudo apt-get install -y -qq $MISSING 2>&1 | tail -1
fi
ok "Build dependencies installed"

# Install firmware package (needed after reboot, but install now for convenience)
if ! dpkg -s firmware-realtek >/dev/null 2>&1; then
    sudo apt-get install -y -qq firmware-realtek 2>&1 | tail -1
fi
ok "Realtek firmware package installed"

# ============================================================
# 2/9  Clone this repo (patch + config)
# ============================================================
step 2 "Fetching patch & kernel config..."
REPO_URL="https://github.com/rakesh6927/wsl2-rtl8812au-fix.git"
if [ -d "$REPO_DIR/.git" ]; then
    cd "$REPO_DIR" && git pull -q --ff-only 2>/dev/null && ok "Repo updated" || ok "Repo already current"
else
    rm -rf "$REPO_DIR"
    git clone -q "$REPO_URL" "$REPO_DIR"
    ok "Repo cloned to $REPO_DIR"
fi

# ============================================================
# 3/9  Clone WSL2 kernel source
# ============================================================
step 3 "Fetching WSL2 kernel source..."
KERNEL_URL="https://github.com/microsoft/WSL2-Linux-Kernel.git"
if [ -d "$KERNEL_DIR/.git" ]; then
    cd "$KERNEL_DIR"
    CURRENT_TAG=$(git describe --tags 2>/dev/null || echo "unknown")
    if [ "$CURRENT_TAG" = "$KERNEL_TAG" ]; then
        ok "Kernel source already at $KERNEL_TAG"
    else
        warn "Kernel source exists but wrong tag ($CURRENT_TAG). Re-cloning..."
        cd "$HOME"
        rm -rf "$KERNEL_DIR"
        git clone --branch "$KERNEL_TAG" --depth 1 "$KERNEL_URL" "$KERNEL_DIR"
        ok "Kernel source cloned"
    fi
else
    rm -rf "$KERNEL_DIR"
    git clone --branch "$KERNEL_TAG" --depth 1 "$KERNEL_URL" "$KERNEL_DIR"
    ok "Kernel source cloned to $KERNEL_DIR"
fi

# ============================================================
# 4/9  Clean previous build artifacts
# ============================================================
step 4 "Cleaning previous build artifacts..."
cd "$KERNEL_DIR"
if [ -f "vmlinux.o" ] || [ -f ".config" ]; then
    make mrproper 2>/dev/null || make clean 2>/dev/null || true
    ok "Build directory cleaned"
else
    ok "Build directory already clean"
fi

# ============================================================
# 5/9  Apply patch
# ============================================================
step 5 "Applying RTL8812AU driver patch..."
PATCH_FILE="$REPO_DIR/0001-rtw88-fix-RTL8812AU-8051-firmware-boot-over-USB.patch"
if [ ! -f "$PATCH_FILE" ]; then
    die "Patch file not found: $PATCH_FILE"
fi

if git apply --check "$PATCH_FILE" 2>/dev/null; then
    git apply "$PATCH_FILE" 2>/dev/null
    ok "Patch applied"
elif git log --oneline -1 2>/dev/null | grep -q "rtw88.*RTL8812AU"; then
    ok "Patch already applied (found in git log)"
else
    # Check if the changes are already in the source
    if grep -q "get_wlmcu_ioif_bit" drivers/net/wireless/realtek/rtw88/mac.c 2>/dev/null; then
        ok "Patch already applied (found in source)"
    else
        warn "Patch may already be applied (check failed but continuing)"
    fi
fi

# ============================================================
# 6/9  Configure kernel
# ============================================================
step 6 "Configuring kernel..."
CONFIG_FILE="$REPO_DIR/wsl2-wifi.config"
if [ ! -f "$CONFIG_FILE" ]; then
    die "Config file not found: $CONFIG_FILE"
fi
cp "$CONFIG_FILE" .config
make olddefconfig 2>&1 | tail -1

# Verify key options
if grep -q "CONFIG_RTW88_8812AU=m" .config; then
    ok "Kernel configured (RTW88_8812AU enabled)"
else
    die "Config verification failed: RTW88_8812AU not enabled"
fi

# ============================================================
# 7/9  Build kernel
# ============================================================
step 7 "Building kernel (15-25 minutes)..."
JOBS=$(nproc)
echo -e "  Using $JOBS parallel jobs"
echo -e "  Build log: $BUILD_LOG"
echo -e "  Started at $(date '+%H:%M:%S')"

START_TIME=$(date +%s)

# Run build, log output, show progress
if make -j"$JOBS" > "$BUILD_LOG" 2>&1; then
    END_TIME=$(date +%s)
    ELAPSED=$(( (END_TIME - START_TIME) / 60 ))
    ok "Build completed in ${ELAPSED} minutes"
else
    echo ""
    echo -e "${RED}Build failed! Last 20 lines of build log:${NC}"
    tail -20 "$BUILD_LOG"
    die "Kernel build failed. See full log: $BUILD_LOG"
fi

# Verify bzImage exists
[ -f "arch/x86/boot/bzImage" ] || die "bzImage not found after build"
BZ_SIZE=$(du -h arch/x86/boot/bzImage | cut -f1)
ok "Kernel image built: ${BZ_SIZE}"

# ============================================================
# 8/9  Install kernel and modules
# ============================================================
step 8 "Installing kernel and modules..."

# Install kernel modules
sudo make INSTALL_MOD_PATH=/ modules_install >> "$BUILD_LOG" 2>&1
ok "Modules installed"

# Copy kernel to Windows
KERNEL_DEST="/mnt/c/Users/$WIN_USER/wsl-custom-kernel"
cp arch/x86/boot/bzImage "$KERNEL_DEST"
ok "Kernel copied to $KERNEL_DEST"

# ============================================================
# 9/10  Patch airgeddon (if installed)
# ============================================================
step 9 "Patching airgeddon WSL2 compatibility..."
AIRGEDDON_SCRIPT="/usr/share/airgeddon/airgeddon.sh"
AIRGEDDON_PATCH="$REPO_DIR/airgeddon-wsl2.patch"

if [ -f "$AIRGEDDON_SCRIPT" ]; then
    if grep -q "WSL2 with custom kernel detected" "$AIRGEDDON_SCRIPT" 2>/dev/null; then
        ok "airgeddon already patched"
    elif [ -f "$AIRGEDDON_PATCH" ]; then
        sudo patch "$AIRGEDDON_SCRIPT" < "$AIRGEDDON_PATCH" 2>/dev/null
        ok "airgeddon patched for WSL2"
    else
        warn "airgeddon patch not found, skipping"
    fi
else
    ok "airgeddon not installed, skipping"
fi

# ============================================================
# 10/10 Update .wslconfig
# ============================================================
step 10 "Updating .wslconfig..."
WSL_CONFIG="/mnt/c/Users/$WIN_USER/.wslconfig"

# Remove BOM if present
if [ -f "$WSL_CONFIG" ]; then
    sed -i '1s/^\xEF\xBB\xBF//' "$WSL_CONFIG" 2>/dev/null || true
fi

if [ -f "$WSL_CONFIG" ]; then
    if grep -q "^kernel=" "$WSL_CONFIG" 2>/dev/null; then
        sed -i "s|^kernel=.*|kernel=C:\\\\\\\\Users\\\\\\\\$WIN_USER\\\\\\\\wsl-custom-kernel|" "$WSL_CONFIG"
        ok ".wslconfig updated"
    else
        # Check if [wsl2] section exists
        if grep -q "^\[wsl2\]" "$WSL_CONFIG" 2>/dev/null; then
            sed -i "/^\[wsl2\]/a kernel=C:\\\\Users\\\\$WIN_USER\\\\wsl-custom-kernel" "$WSL_CONFIG"
        else
            # Prepend [wsl2] section
            sed -i "1i [wsl2]\nkernel=C:\\\\Users\\\\$WIN_USER\\\\wsl-custom-kernel" "$WSL_CONFIG"
        fi
        ok ".wslconfig updated"
    fi
else
    printf '[wsl2]\nkernel=C:\\\\Users\\\\%s\\\\wsl-custom-kernel\n' "$WIN_USER" > "$WSL_CONFIG"
    ok ".wslconfig created"
fi

# Verify .wslconfig content
if grep -q "wsl-custom-kernel" "$WSL_CONFIG" 2>/dev/null; then
    ok "Verified: .wslconfig points to custom kernel"
else
    warn ".wslconfig verification failed — please check manually"
fi

# ============================================================
# Done
# ============================================================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Setup Complete!                      ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "  Kernel: ${CYAN}$KERNEL_DEST${NC}"
echo -e "  Config: ${CYAN}$WSL_CONFIG${NC}"
echo -e "  Log:    ${CYAN}$BUILD_LOG${NC}"
echo ""
echo -e "  ${YELLOW}► Next: Restart WSL from Windows PowerShell:${NC}"
echo -e "    ${CYAN}wsl --shutdown${NC}"
echo ""
echo -e "  ${YELLOW}► After restart, attach the Alfa adapter:${NC}"
echo ""
echo -e "    ${YELLOW}Windows PowerShell (Admin):${NC}"
echo -e "    ${CYAN}usbipd bind --busid <BUSID> --force${NC}"
echo -e "    ${CYAN}usbipd attach --wsl --busid <BUSID>${NC}"
echo ""
echo -e "    ${YELLOW}WSL terminal:${NC}"
echo -e "    ${CYAN}sudo modprobe rtw88_8812au${NC}"
echo -e "    ${CYAN}sudo ip link set wlan0 down${NC}"
echo -e "    ${CYAN}sudo iw dev wlan0 set type monitor${NC}"
echo -e "    ${CYAN}sudo ip link set wlan0 up${NC}"
echo ""
exit 0
