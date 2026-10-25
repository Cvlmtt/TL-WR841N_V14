# TP-Link TL-WR841N (V14) — Firmware Reverse Engineering & Custom Firmware

Security-research project on the **TP-Link TL-WR841N, hardware revision V14.1**
(MediaTek MT7628, MIPS32R2 little-endian). The work covers the full path from
firmware acquisition and static audit, through a reproducible cross-compilation
toolchain, to rebuilding a **working custom firmware** — including the reverse
engineering of an undocumented firmware-layout constraint that is required for
the device to keep its configuration after a flash.

Academic + personal project by **Carlo Alberto Giordano** and **Mattia
([@Cvlmtt](https://github.com/Cvlmtt))**. Everything here was performed on
hardware we own, for study and defensive research.

---

## Highlights

- Firmware acquisition and static audit (binwalk, Firmware-Mod-Kit, firmwalker)
  of the official EU image.
- A reproducible **MIPS32R2 / uClibc-ng cross-compilation toolchain** built with
  Buildroot (the vendor GPL toolchain only builds on Ubuntu 12.04).
- Reverse engineering of the **firmware layout constraints** that govern
  configuration persistence — the core finding of the project.
- QEMU emulation of the image using an injected **fake `libnvram`** to work
  around flash-backed NVRAM.
- Two validated flashing paths: **web UI update** and **TFTP recovery**.

## Target device

| | |
|---|---|
| Model | TP-Link TL-WR841N |
| Hardware revision | V14.1 |
| SoC / Wi-Fi | MediaTek MT7628 |
| CPU | MIPS32 Release 2, little-endian (mipsel) |
| Bootloader | U-Boot 1.1.3 |
| Root filesystem | SquashFS 4.0 (XZ), mounted read-only |
| Firmware integrity | **No secure boot / no cryptographic signature** |

## Scope & ethics

This repository documents firmware analysis and **custom-firmware engineering**
on a device we physically own. The vulnerabilities referenced in the static
audit are already public and widely documented; none are disclosed here as
novel. The repository intentionally **does not** publish any weaponized
artifact (no implant, no command-and-control, no network control tooling): those
proof-of-concept components were kept private, as they would provide real-world
offensive capability against devices still in circulation and serve no purpose
in a methodology write-up. The device line is discontinued by the vendor.

---

## Methodology

### 1. Firmware acquisition & static analysis
The official EU firmware was downloaded from the TP-Link support page and
unpacked with `binwalk3` / Firmware-Mod-Kit, revealing an **LZMA-compressed
kernel** and an **XZ SquashFS root filesystem**. A `firmwalker` pass over the
extracted rootfs mapped the attack surface: the web management stack
(`httpd`, login/management pages, the `tpEncrypt.js` client-side obfuscation),
legacy tunneling daemons (PPPoE/PPTP/L2TP, UPnP), BusyBox and Dropbear, a
`passwd.bak` backup account file, no `/etc/shadow`, no bundled TLS keys, and no
HTTPS on the admin interface. The full audit is in
[`docs/Static-analysis.md`](docs/Static-analysis.md).

### 2. Cross-compilation toolchain
Because the vendor GPL toolchain targets an obsolete build host (Ubuntu 12.04),
a modern toolchain was rebuilt from scratch with **Buildroot**: MIPS little-
endian, Generic MIPS32R2, **uClibc-ng** with C++ support, and SquashFS images
padded to a 4K boundary. An `env.sh` helper exposes `mipsel-linux-gcc` for
building target binaries, with a documented tiered approach to size/stability
optimization (`-Os`/`-O2`, section GC, LTO, and the micro-architecture-specific
flags that must stay in sync with the uClibc ABI). See
[`docs/Firmware-mod.md`](docs/Firmware-mod.md).

### 3. Firmware repacking & the layout-constraint discovery
Rebuilding an image that the router accepts **and** that preserves its
configuration turned out to be the hardest part. Stock FMK rebuilds flashed
successfully but **wiped persistent configuration**: the `config` partition
(`mtd3`) failed to mount at boot, bricking the device for practical use.

The breakthrough came from a **"blessed" firmware** — an image FMK produced by
accident that *did* preserve configuration. Diffing its rootfs against the
original showed the filesystems were identical, so the difference was purely
structural. Analysis isolated the conditions for persistence:

- the SquashFS rootfs must be compressed with a **1 MiB block size**, and
- the final image must be padded with `0xFF` to an **exact total size of
  4,063,744 bytes** (matching the factory image byte-for-byte).

These constraints were automated into
[`scripts/build-firmware.sh`](scripts/build-firmware.sh), which rebuilds a valid,
persistence-preserving image from a modified rootfs and can also emit the
header-stripped variant used for TFTP recovery.

### 4. Emulation
Full QEMU emulation is non-trivial (NVRAM, proprietary ioctls, peripherals), so
`FirmwareModUtils/repackFirmware.py` injects a **fake `libnvram`**
([nvram-faker](https://github.com/zcutlip/nvram-faker)) to emulate the shared-
memory NVRAM behavior the firmware expects. Emulation was used selectively;
final validation was done on the physical router.

### 5. Flashing
Two paths were validated and documented in
[`docs/Firmware-flashing.md`](docs/Firmware-flashing.md):
- **Web UI update** — upload the rebuilt `.bin` through the stock firmware-update
  page.
- **TFTP recovery** — serve a header-stripped `tp_recovery.bin` from
  `192.168.0.66` and trigger the WPS/RESET recovery sequence; `scripts/tftp_server.sh`
  automates the server/interface setup and restores the environment on exit.

---

## Key takeaway

On a device with **no secure boot**, firmware integrity is still enforced
*implicitly* — through hard assumptions about image size, compression block size
and alignment. Violating those assumptions does not reject the image; it silently
breaks configuration persistence and bricks the device. Understanding and
reproducing these constraints is what makes reliable, non-destructive custom
firmware possible.

## Repository layout

```
docs/                  Write-ups: static analysis, firmware modification, flashing
FirmwareModUtils/      Wrappers around Firmware-Mod-Kit (unpack / repack helpers)
buildroot/             Toolchain configuration (MIPS32R2 / uClibc-ng)
scripts/               build-firmware.sh, tftp_server.sh, compare_dirs.sh, ...
firmware/              Reference to the official vendor image (not redistributed)
```

## Tools

binwalk3 · Firmware-Mod-Kit · firmwalker · Buildroot · uClibc-ng ·
mipsel cross-GCC · QEMU · nvram-faker · Ghidra

## References

- TP-Link TL-WR841N firmware downloads — vendor support page
- OpenWrt — TL-WR841N/ND device page and "return to stock" guide
- nvram-faker — https://github.com/zcutlip/nvram-faker

## Authors

- **Carlo Alberto Giordano** — https://github.com/carloalbertogiordano
- **Mattia** — https://github.com/Cvlmtt

## License

See [`LICENSE`](LICENSE).
