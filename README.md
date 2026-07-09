# WSL2 WiFi Monitor Mode — RTL8812AU Kernel Fix

Enables **RTL8812AU USB WiFi adapters** (Alfa AWUS036ACH and similar) in **WSL2** with full **monitor mode** and packet injection support.

Tested on **Kali Linux WSL2** with kernel **6.18.33.1**.

## The Problem

WSL2's default kernel ships without wireless drivers. Even with a custom kernel build enabling the in-tree `rtw88_8812au` driver, the RTL8812AU chip fails to boot its firmware — the 8051 microcontroller inside the chip never asserts the `WINTINI_RDY` flag.

## The Fix

The in-tree `rtw88` driver uses `BIT(0)` for the 8051 MCU IO interface on all chips, but the RTL8812AU (and RTL8814AU) requires `BIT(3)` in `REG_RSV_CTRL+1`. This repository provides the patch, kernel config, and step-by-step instructions.

---

## Instructions

### Step 1 — Clone this repo (in WSL)

```bash
# Run INSIDE WSL (Kali/Ubuntu):
git clone https://github.com/rakesh6927/wsl2-rtl8812au-fix.git
cd wsl2-rtl8812au-fix
```

### Step 2 — Clone WSL2 kernel source (in WSL)

```bash
# Still inside WSL:
cd ~
git clone --branch linux-msft-wsl-6.18.33.1 --depth 1 \
  https://github.com/microsoft/WSL2-Linux-Kernel.git
cd WSL2-Linux-Kernel
```

### Step 3 — Apply the patch (in WSL)

```bash
# From ~/WSL2-Linux-Kernel:
patch -p1 < ~/wsl2-rtl8812au-fix/0001-rtw88-fix-RTL8812AU-8051-firmware-boot-over-USB.patch
```

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

### Step 8 — Configure WSL to use custom kernel (in Windows)

Open **File Explorer**, navigate to `C:\Users\<YourUsername>\`, and edit `.wslconfig` (create it if it doesn't exist):

```ini
[wsl2]
kernel=C:\\Users\\<YourUsername>\\wsl-custom-kernel
```

> Replace `<YourUsername>` with your actual Windows username. Double backslashes are required.

### Step 9 — Restart WSL (in Windows PowerShell or CMD)

```powershell
wsl --shutdown
```

Then reopen your WSL terminal.

### Step 10 — Install firmware (in WSL, after restart)

```bash
sudo apt install firmware-realtek -y
```

### Step 11 — Verify the new kernel (in WSL)

```bash
uname -r
# Should show: 6.18.33.1-microsoft-standard-WSL2

zcat /proc/config.gz | grep CONFIG_RTW88_8812AU
# Should show: CONFIG_RTW88_8812AU=m
```

---

## USB Passthrough (each time you plug in the adapter)

### Attach from Windows (PowerShell as Administrator)

```powershell
# Find the Alfa's BUSID:
usbipd list

# Bind and attach (replace <BUSID> with actual ID, usually 1-1):
usbipd bind --busid <BUSID> --force
usbipd attach --wsl --busid <BUSID>
```

### Load the driver (in WSL)

```bash
sudo modprobe vhci_hcd
sudo modprobe rtw88_8812au
```

Check that `wlan0` appears:
```bash
iwconfig
```

---

## Enable Monitor Mode (in WSL)

```bash
sudo ip link set wlan0 down
sudo iw dev wlan0 set type monitor
sudo ip link set wlan0 up

# Verify:
iwconfig wlan0
# Should show: Mode:Monitor
```

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
- WSL2 kernel 6.18.33.1 (Microsoft)
- Kali Linux WSL2

## License

The patch applies to the Linux kernel source, licensed under GPL-2.0.
