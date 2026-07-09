# WSL2 WiFi Monitor Mode — RTL8812AU Kernel Fix

Enables **RTL8812AU USB WiFi adapters** (Alfa AWUS036ACH and similar) in **WSL2** with full **monitor mode** and packet injection support.

Tested on **Kali Linux WSL2** with kernel **6.18.35.2**.

## The Problem

WSL2's default kernel ships without wireless drivers. Even with a custom kernel build enabling the in-tree `rtw88_8812au` driver, the RTL8812AU chip fails to boot its firmware — the 8051 microcontroller inside the chip never asserts the `WINTINI_RDY` flag.

## The Fix

The in-tree `rtw88` driver uses `BIT(0)` for the 8051 MCU IO interface on all chips, but the RTL8812AU (and RTL8814AU) requires `BIT(3)` in `REG_RSV_CTRL+1`. This repository provides the patch, kernel config, scripts, and step-by-step instructions.

## Files

| File | Purpose |
|------|---------|
| `setup.sh` | **One-time:** build custom kernel, install modules, update .wslconfig, patch airgeddon |
| `wifi.sh` | **Daily use:** show adapter status, auto-attach from Windows, retry on failure, verify wlan0 |
| `0001-rtw88-fix-*.patch` | Driver fix (clean git format — use `git apply`) |
| `wsl2-wifi.config` | Working kernel `.config` with RTW88_8812AU + embedded firmware |
| `airgeddon-wsl2.patch` | Bypasses airgeddon's WSL2 block |

---

## Quick Start (Automated)

**Prerequisites:** Install WiFi auditing tools first so setup.sh can patch them:

```bash
sudo apt install wifite airgeddon -y
```

Then two scripts handle everything:

### One-time setup (build custom kernel)

```bash
# Inside WSL:
git clone https://github.com/rakesh6927/wsl2-rtl8812au-fix.git
cd wsl2-rtl8812au-fix
bash setup.sh
```

This auto-installs dependencies, clones the WSL2 kernel source, applies the patch, builds the kernel (~20 min), installs it, and updates `.wslconfig`. If wifite/airgeddon are installed, it auto-patches airgeddon for WSL2 compatibility. If they're missing, it warns you to install them and shows the patch command.

When it finishes, **restart WSL** from Windows PowerShell:

```powershell
wsl --shutdown
```

### Daily use (attach Alfa adapter)

```bash
cd ~/wsl2-rtl8812au-fix
bash wifi.sh
```

Detects your Alfa, loads drivers, attaches it from Windows via usbipd, and verifies `wlan0` is ready. Handles bind/attach failures, vhci drops, and retries automatically.

```
bash wifi.sh              # Auto: show status + attach if needed
bash wifi.sh --status     # Just show where adapters are (Windows vs WSL)
bash wifi.sh --attach     # Force re-attach all available adapters
```

After that, enable monitor mode and launch your tool:

```bash
sudo ip link set wlan0 down
sudo iw dev wlan0 set type monitor
sudo ip link set wlan0 up
sudo wifite      # or sudo airgeddon
```

---

## Updating to a Newer WSL2 Kernel

When Microsoft releases a new kernel, re-run setup.sh to rebase:

```bash
cd ~/wsl2-rtl8812au-fix
git pull
bash setup.sh
```

The script auto-detects the latest kernel tag, re-clones if needed, re-applies the patch, rebuilds, and reinstalls.

---

## Manual Setup (step-by-step reference)

### Step 1 — Clone this repo (in WSL)

```bash
git clone https://github.com/rakesh6927/wsl2-rtl8812au-fix.git
cd wsl2-rtl8812au-fix
```

### Step 2 — Clone WSL2 kernel source (in WSL)

```bash
cd ~
git clone --branch linux-msft-wsl-6.18.35.2 --depth 1 \
  https://github.com/microsoft/WSL2-Linux-Kernel.git
cd WSL2-Linux-Kernel
```

### Step 3 — Apply the patch (in WSL)

```bash
git apply ~/wsl2-rtl8812au-fix/0001-rtw88-fix-RTL8812AU-8051-firmware-boot-over-USB.patch
```

> The patch is in clean `git diff` format — use `git apply`, not `patch -p1`.

### Step 4 — Configure kernel (in WSL)

```bash
cp ~/wsl2-rtl8812au-fix/wsl2-wifi.config .config
make olddefconfig
```

### Step 5 — Build (in WSL, takes ~15-25 min)

```bash
make -j$(nproc)
```

### Step 6 — Install kernel modules (in WSL)

```bash
sudo make INSTALL_MOD_PATH=/ modules_install
```

### Step 7 — Copy kernel to Windows (in WSL)

```bash
# Replace IOTlab with your Windows username:
cp arch/x86/boot/bzImage /mnt/c/Users/IOTlab/wsl-custom-kernel
```

### Step 8 — Configure .wslconfig (in Windows)

Edit `C:\Users\<YourUsername>\.wslconfig`:

```ini
[wsl2]
kernel=C:\\Users\\<YourUsername>\\wsl-custom-kernel
```

### Step 9 — Restart WSL (in Windows PowerShell)

```powershell
wsl --shutdown
```

### Step 10 — Install firmware (in WSL, after restart)

```bash
sudo apt install firmware-realtek -y
```

### Step 11 — Patch airgeddon (in WSL, if installed)

```bash
sudo patch /usr/share/airgeddon/airgeddon.sh < ~/wsl2-rtl8812au-fix/airgeddon-wsl2.patch
```

### Step 12 — Attach adapter and use

From Windows PowerShell (Admin):
```powershell
usbipd list
usbipd bind --busid <BUSID> --force
usbipd attach --wsl --busid <BUSID>
```

In WSL:
```bash
sudo modprobe rtw88_8812au
sudo ip link set wlan0 down
sudo iw dev wlan0 set type monitor
sudo ip link set wlan0 up
sudo wifite
```

> Tip: Use `bash wifi.sh` instead of the manual attach steps.

---

## Changes in the Patch

| Function | Change |
|----------|--------|
| `get_wlmcu_ioif_bit()` | New — returns `BIT(3)` for 8812A/8814A, `BIT(0)` for others |
| `wlan_cpu_enable()` | Uses per-chip IO interface bit |
| `en_download_firmware_legacy()` | 8051 reset if firmware loaded, clear `REG_MCUFW_CTRL=0x00`, clear `BIT(1)` in `REG_RSV_CTRL` for 8812A |
| `download_firmware_validate_legacy()` | Increased timeout: 200ms → 2.5s, added register debug output |

## Kernel Config Summary

| Option | Value | Purpose |
|--------|-------|---------|
| `CONFIG_RTW88_8812AU` | m | RTL8812AU USB driver |
| `CONFIG_CFG80211` | y | Wireless config API (built-in) |
| `CONFIG_MAC80211` | y | Wireless stack (built-in) |
| `CONFIG_EXTRA_FIRMWARE` | rtw88/rtw8812a_fw.bin | Embedded firmware |
| `CONFIG_DRM` | n | Disabled GPU drivers for faster build |

## Tested Hardware

- Alfa AWUS036ACH (Realtek RTL8812AU, USB ID: 0bda:8812)
- WSL2 kernel 6.18.33.1 → 6.18.35.2 (Microsoft)
- Kali Linux WSL2

## License

The patch applies to the Linux kernel source, licensed under GPL-2.0.
