# WSL2 WiFi Monitor Mode — RTL8812AU Kernel Fix

Enables **RTL8812AU USB WiFi adapters** (Alfa AWUS036ACH and similar) in **WSL2** with full **monitor mode** and packet injection support.

## The Problem

WSL2's default kernel ships without wireless drivers. Even with a custom kernel build enabling the in-tree `rtw88_8812au` driver, the RTL8812AU chip fails to boot its firmware — the 8051 microcontroller inside the chip never asserts the `WINTINI_RDY` flag.

## The Fix

The in-tree `rtw88` driver uses `BIT(0)` for the 8051 MCU IO interface on all chips, but the RTL8812AU (and RTL8814AU) requires `BIT(3)` in `REG_RSV_CTRL+1`. This repository provides:

1. **Patch**: `rtw88` driver fix for RTL8812AU 8051 firmware boot
2. **Config**: Working kernel `.config` with all necessary options enabled

## Changes (`0001-rtw88-fix-*.patch`)

| Function | Change |
|----------|--------|
| `get_wlmcu_ioif_bit()` | New — returns `BIT(3)` for 8812A/8814A, `BIT(0)` for others |
| `wlan_cpu_enable()` | Uses per-chip IO interface bit |
| `en_download_firmware_legacy()` | 8051 reset if firmware loaded, clear `REG_MCUFW_CTRL=0x00`, clear `BIT(1)` in `REG_RSV_CTRL` for 8812A |
| `download_firmware_validate_legacy()` | Increased timeout: 200ms → 2.5s, added register debug output |

## Build Instructions

### 1. Clone WSL2 kernel

```bash
git clone --branch linux-msft-wsl-6.18.33.1 --depth 1 \
  https://github.com/microsoft/WSL2-Linux-Kernel.git
cd WSL2-Linux-Kernel
```

### 2. Apply the patch

```bash
patch -p1 < /path/to/0001-rtw88-fix-RTL8812AU-8051-firmware-boot-over-USB.patch
```

### 3. Configure

```bash
cp /path/to/wsl2-wifi.config .config
make olddefconfig
```

### 4. Build

```bash
make -j$(nproc)
```

### 5. Install

```bash
sudo make INSTALL_MOD_PATH=/ modules_install
cp arch/x86/boot/bzImage /mnt/c/Users/<YourUser>/wsl-custom-kernel
```

### 6. Update `.wslconfig`

In `C:\Users\<YourUser>\.wslconfig`:
```ini
[wsl2]
kernel=C:\\Users\\<YourUser>\\wsl-custom-kernel
```

### 7. Restart WSL

From PowerShell:
```powershell
wsl --shutdown
```

### 8. Install firmware (in WSL)

```bash
sudo apt install firmware-realtek
```

## USB Passthrough

Use `usbipd-win` to attach the WiFi adapter from Windows to WSL:

```powershell
# Admin PowerShell
usbipd list                         # Find BUSID (e.g., 1-1)
usbipd bind --busid <BUSID> --force
usbipd attach --wsl --busid <BUSID>
```

In WSL:
```bash
sudo modprobe vhci_hcd
sudo modprobe rtw88_8812au
```

The interface should appear as `wlan0`.

## Enable Monitor Mode

```bash
sudo ip link set wlan0 down
sudo iw dev wlan0 set type monitor
sudo ip link set wlan0 up
```

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
