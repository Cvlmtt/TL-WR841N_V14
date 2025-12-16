# Firmware Modification
This section presents a comprehensive and methodical analysis of the firmware modification process for the 
`TP-LINK WR841N V14` router, based on a Linux operating system running on a `MIPS32 Release 2 little-endian (mipsel)` 
architecture. The objective of this phase is to extract, analyze, modify, and correctly reconstruct the firmware 
image in a manner that preserves device stability, configuration persistence, and flash memory integrity.

The workflow described here is tightly integrated with the static analysis, backdooring, and flashing procedures 
detailed in the accompanying documents, and is designed to reflect best practices in embedded and IoT security research.

## Firmware Extraction
Firmware extraction represents the foundational step for both static analysis and active modification. 
The official TP-Link firmware image was unpacked using *Firmware Mod Kit* (FMK), augmented by a wrapper script located
at `FirmwareModUtils/unpackFirmware.sh`. This script abstracts the interaction with FMK and automatically prepares 
a working directory structure by creating a symbolic link to the FMK output at `FirmwareModUtils/fmk`.
To execute the extraction procedure, it is sufficient to navigate to the `FirmwareModUtils` directory and run the 
following command:
```bash
sudo ./unpackFirmware.sh <firmware-fullpath>
```
Upon completion, the extracted SquashFS root filesystem is available at `fmk/rootfs`. This directory represents the 
immutable root filesystem that is mounted read-only at runtime on the target device. All firmware-level modifications, 
including binary injection, script alteration, and configuration changes, are performed within this directory prior 
to repacking.

## Toolchain Setup
While firmware extraction enables inspection and static analysis, meaningful modification requires the ability to compile
custom binaries compatible with the target platform. This necessitates a cross-compilation toolchain targeting the 
`MIPS32R2 little-endian` architecture.

Although TP-Link provides GPL source packages and toolchains via its GPL Source Center, these resources depend on 
obsolete build environments (Ubuntu 12.04), rendering them unsuitable for reproducible modern research workflows.
Reconstructing such legacy environments is impractical for modern research without significant effort to recreate
legacy systems.

To address this limitation, Buildroot was adopted. This framework enabled the configuration of a fully customized 
toolchain precisely tailored to the target architecture. Fortunately, the configuration process proved to be 
straightforward and reproducible.

The applied configuration, set through the following command, is briefly reviewed below:
```bash
 make menuconfig
```
The key configuration options selected were as follows:
- **Target Architecture**: MIPS (little endian)  
- **Target Architecture Variant**: Generic MIPS32R2  
- **C Library**: uClibc-ng, with C++ support enabled  
- **Toolchain Options**: Enabled "Build cross gdb for the host"  
- **Filesystem Images**: Enabled "squashfs root filesystem" along with the option to "pad to a 4K boundary"; all other filesystem image formats were disabled.

After applying and saving these modifications, the toolchain and associated components were built using:
```bash
 make toolchain
```

This command triggers the build process, resulting in the generation of the cross-compilation toolchain.
For convenience, an `env.sh` script was prepared to configure the necessary environment variables for invoking the 
cross-compiler. 

This script can be sourced using:
``` bash
source env.sh
```
Researchers may need to adjust the `PATH` and `SYSROOT` variables according to their local filesystem layout.

### Compile
Once configured, compiling target‑architecture binaries becomes straightforward:
``` bash
mipsel-linux-gcc -o <output_filename> <input_source.c>
```
and the resulting artifact can be examined with:
```bash
file <output_filename>
```
to validate that the output corresponds to a MIPS32 Release2 executable.
Integrating the compiled binary into the working filesystem involves placing it within the unpacked firmware tree using
appropriate privileges.

## Optimization of Compiled Binaries in Buildroot with mipsel-linux-gcc and uClibc

The optimization of embedded binaries within the Buildroot framework, utilizing the `mipsel-linux-gcc` toolchain and the
uClibc library, constitutes a multidimensional process that balances performance, binary size, and system stability.
A principled approach organizes optimization strategies into successive tiers of increasing potency and concomitant 
risk. The foundational tier employs robust, low-risk techniques universally deemed safe for production. This includes 
the selection of standard compiler optimization levels, most notably `-Os` for size-critical applications or `-O2` 
for performance-oriented systems, which activate a suite of transformations within the GNU Compiler Collection (GCC). 
Post-compilation, the application of `mipsel-linux-strip -s` to final executables and shared libraries safely removes 
symbolic debugging information, yielding a leaner binary without impacting execution logic. Concurrently, a disciplined
configuration of the uClibc library, disabling unnecessary features such as extensive locale support or legacy 
compatibility layers, reduces the foundational footprint of the runtime environment.

Advancing to an intermediate tier introduces more sophisticated techniques that, while offering substantial gains, 
require careful consideration of the application profile and toolchain coherence. The use of linker section garbage 
collection, enabled by the `-ffunction-sections -fdata-sections` compiler flags paired with the `-Wl,--gc-sections` 
linker flag, facilitates the elimination of unused code and data segments. The integration of Link-Time Optimization
(LTO) via `-flto` can further enhance performance and reduce size by enabling cross-module analysis during the final 
linking phase, albeit at the cost of increased build complexity and memory consumption. Within this tier, stripping 
can be intensified to `--strip-unneeded`, which removes symbols not necessary for relocation processing—a operation 
that demands caution with shared libraries to avoid rendering them non-functional.

The subsequent tier enters the realm of target-specific and aggressive optimizations, where benefits are counterbalanced 
by significant risks to portability and correctness. Here, compiler flags are tailored to the precise 
microarchitecture of the target MIPS processor using `-march` and `-mtune` directives. While this unlocks 
instruction-level efficiencies, it results in binaries incompatible with earlier or variant cores in the same family. 
Explicit control over the floating-point ABI (e.g., `-mhard-float`) must be perfectly synchronized with the uClibc 
configuration; a mismatch guarantees runtime failure. Manual intervention in the linking process, through custom linker 
scripts, allows for meticulous control over memory section placement but can lead to catastrophic boot failures if 
address spaces are misconfigured.

The final, and most hazardous, tier encompasses optimizations that border on the experimental, where marginal returns 
are overwhelmingly outweighed by the peril of introducing non-deterministic behavior or binary corruption. 
The use of `-Ofast`, which violates strict language standards for speed, or the activation of unsafe mathematical 
optimizations in systems without a floating-point unit, can lead to subtle, irreproducible errors. Employing non-standard
binary utilities, such as aggressive ELF strippers that operate beyond the specifications of `strip`, poses a direct 
threat to the structural integrity of the executable file format. Optimization at this level effectively trades the 
reliability and debuggability of the system for hypothetical gains, a transaction rarely justified outside constrained
research or proof-of-concept scenarios where exhaustive, target-specific validation is performed. Thus, the optimization
trajectory demands a methodical, incremental validation at each stage, ensuring that enhancements in efficiency or size
do not undermine the functional integrity of the embedded system.


## Emulation
Emulating the original firmware using QEMU is non-trivial due to hardware-specific dependencies, including NVRAM access,
proprietary ioctl calls, and limited peripheral emulation. To partially mitigate these issues, the helper script 
`FirmwareModUtils/repackFirmware.py` was employed. which performs additional automated adjustments to the unpacked 
filesystem; including the injection of a fake `libnvram` implementation that emulates the shared-memory behavior 
expected by the firmware. This is essential because configuration storage on the physical device relies on dedicated 
flash-backed NVRAM partitions, which are unavailable in emulated environments.

The script can be used as follows:
```
sudo python repackFirmware.py <path to an unmodified firmware>
```
**Note:** By default, the tool detects and injects a “fake libnvram” implementation to emulate shared‑memory behaviour 
expected by the firmware. If this library is unavailable, the script copies a fallback version from the FAT directory into
the root filesystem. A `--no-rootfs-patch` option is provided for researchers who wish to disable automated rootfs modifications.
You may also need to compile `nvramfaker` from [source](https://github.com/zcutlip/nvram-faker).

This workflow enables a reproducible and controlled environment for firmware analysis, facilitating experimentation 
without requiring continuous flashing of physical hardware.

Although this approach enables controlled experimentation without repeatedly flashing physical hardware, emulation 
was used selectively in this project. Final validation and behavioral analysis were conducted directly on the physical 
router to avoid discrepancies between emulated and real hardware behavior.


## Firmware Repacking and Layout Constraints
Reconstructing a firmware image that is accepted by the router and preserves configuration persistence proved to be one 
of the most challenging aspects of the workflow.
Initial attempts relied on FMK’s `build-firmware.sh` script, which successfully generated flashable images but 
consistently resulted in the loss of persistent configuration. The reasons for its failure were found to be not caused by 
filesystem content differences, but by subtle violations of firmware layout constraints. We first 
examine this constraints and then we provide  a description of the successful alternative approach.

### Attempted Repacking with FMK
The Firmware Mod Kit provides a dedicated script for rebuilding the firmware, located at 
`firmware-mod-kit/build-firmware.sh`. This script can be executed as follows:
```bash
 sudo ./build-firmware.sh
```
This process generates a new firmware file named `fmk/new-firmware.bin`, which is constructed by concatenating the 
unmodified U-Boot partition with the modified `rootfs` (located in `fmk/rootfs`) after compressing it using XZ compression.

The resulting file has a size equal to the sum of the U-Boot partition (54,544 bytes) and the original LZMA-compressed 
archive (982,528 bytes), totaling 1,037,072 bytes, plus the size of the newly XZ-compressed `rootfs`. 
Additionally, the XZ-compressed `rootfs` is produced with a block size of 262,144 bytes, corresponding to a 256 KB alignment.

As described in the firmware flashing section ([Firmware-flashing.md](Firmware-flashing.md)), this reconstructed image 
can be installed on the router.

### Issues with the FMK-Generated Image
The firmware image produced by FMK disrupts the persistence of configuration settings on the router. To understand the 
underlying cause, the actual `ROM` layout of the router must be examined related to the actual mounted partitions.
Inspection of the router’s flash memory revealed the following `MTD` partition layout:
```bash
>>> mount
<<< rootfs on / type rootfs (rw)
<<< /dev/root on / type squashfs (ro,relatime)
<<< proc on /proc type proc (rw,relatime)
<<< ramfs on /var type ramfs (rw,relatime)
<<< /sys on /sys type sysfs (rw,relatime)

>>> cat /proc/mtd
<<< dev:    size   erasesize  name
<<< mtd0: 00010000 00010000 "boot"
<<< mtd1: 000f0000 00010000 "kernel"
<<< mtd2: 002e0000 00010000 "rootfs"
<<< mtd3: 00010000 00010000 "config"
<<< mtd4: 00010000 00010000 "radio"
```
For reasons that remain unfortunately unclear if the reconstructed firmware deviates from the expected size, 
alignment, or compression parameters, the configuration partition (`mtd3`) fails to load correctly at boot. This results
in loss of all persistent settings, effectively rendering the device unusable. A router lacking persistence of the configuration
is effectively useless.

### The Fortunate Anomaly
During experimentation, the Firmware Mod Kit unexpectedly produced an erroneous yet highly valuable firmware 
image, hereafter referred to as the "blessed" firmware, that successfully preserved and loaded the configuration partition. 
Analysis of this anomalous image provided critical properties giving us an insight into resolving the persistence issue.

The following presents the `binwalk` output for this blessed firmware:
```bash
DECIMAL       HEXADECIMAL     DESCRIPTION
--------------------------------------------------------------------------------
54544         0xD510          U-Boot version string, "U-Boot 1.1.3 (Nov 19 2023 - 18:30:02)"
66560         0x10400         LZMA compressed data, properties: 0x5D, dictionary size: 8388608 bytes, uncompressed size: 2986732 bytes
1049088       0x100200        Squashfs filesystem, little endian, version 4.0, compression:xz, size: 2835891 bytes, 768 inodes, blocksize: 1048576 bytes, created: 2025-12-04 14:05:17
```
The file size is also noteworthy:
```bash
-rw-r--r--. 1 root root 4063744  4 dic 15.05 firmware-backdoored.bin

-rw-r--r--. 1 root root 3,9M  4 dic 15.05 firmware-backdoored.bin
```
For completeness, the `binwalk` output for the original firmware is also reported below:
```bash
DECIMAL       HEXADECIMAL     DESCRIPTION
--------------------------------------------------------------------------------
54544         0xD510          U-Boot version string, "U-Boot 1.1.3 (Nov 19 2023 - 18:30:02)"
66560         0x10400         LZMA compressed data, properties: 0x5D, dictionary size: 8388608 bytes, uncompressed size: 2986732 bytes
1049088       0x100200        Squashfs filesystem, little endian, version 4.0, compression:xz, size: 3002156 bytes, 552 inodes, blocksize: 262144 bytes, created: 2023-11-20 02:39:18
```
And its size:
```bash
-rw-r--r--. 1 carlo carlo 4063744  4 dic 10.16 TL-WR841Nv14_EU.bin

-rw-r--r--. 1 carlo carlo 3,9M  4 dic 10.16 TL-WR841Nv14_EU.bin
```

To investigate potential differences in the extracted filesystems, a script located at `scripts/compare_dirs.sh` was developed.
This script performs a recursive `diff` between the `rootfs` extracted from the original firmware and that from the *blessed* 
firmware. The comparison yielded no meaningful differences, indicating that the filesystems were functionally identical.

It is noteworthy that, in this anomalous case, `binwalk` reported a block size of 1 MiB (1 mebibyte, equivalent to 1,048,576 bytes)
of the `squashfs` filesystem. Furthermore, the total size of both the *blessed* firmware and the original 
factory firmware was identical. In none of our other experiments did FMK re-produce a firmware exhibiting these exact 
characteristics. Crucially, **this was the only FMK-generated image that preserved configuration persistence**.

These observations led to the hypothesis that successful persistence requires generating a firmware image with properties 
closely matching those of the *blessed* file, particularly the 1 MiB block size and identical overall file size.

An additional experiment involved the script `scripts/auto-block.sh` (subsequently removed), which attempted to automatically 
determine the optimal `XZ` block size for the compressed `rootfs` in order to achieve a final firmware size matching the 
expected 4,063,744 bytes. This approach also proved unsuccessful in restoring configuration persistence.

These inconclusive results led to the conclusion that configuration persistence likely depends on satisfying multiple 
constraints simultaneously: both the specific size and alignment parameters of the XZ-compressed SquashFS image and the
exact total size of the resulting firmware binary.

We decided to add another seemingly arbitrary constraint, that proved to be the missing piece to solve this puzzle.
The `rootfs` has to be padded with `0xFF` bytes until the total firmware size is exactly 4,063,744 bytes long.

### Controlled Firmware Reconstruction
To reiterate on the previous observations, reconstructing the SquashFS image containing the `rootfs`, compressed with `XZ` and 
aligned to a 1 MiB block size was identified as a necessary condition. Additionally, the final firmware binary must reach
an exact total size of 4,063,744 bytes using padding.

To automate the process while enforcing the required constraints, a custom script was developed: 
`scripts/build-firmware.sh`.

The script accepts the following parameters:
- `-f | --firmware`: Required – path to the original firmware file  
- `-r | --rootfs`: Required – path to the modified `rootfs` directory  
- `-o | --output`: Required – desired name/path for the output firmware file  
- `--strict`: Optional – aborts firmware rebuilding if the compressed size of the modified `rootfs` exceeds that of the original  

A typical execution of the script is as follows:
```bash
========================================
 Binwalk analysis
========================================

DECIMAL       HEXADECIMAL     DESCRIPTION
--------------------------------------------------------------------------------
54544         0xD510          U-Boot version string, "U-Boot 1.1.3 (Nov 19 2023 - 18:30:02)"
66560         0x10400         LZMA compressed data, properties: 0x5D, dictionary size: 8388608 bytes, uncompressed size: 2986732 bytes
1049088       0x100200        Squashfs filesystem, little endian, version 4.0, compression:xz, size: 3002156 bytes, 552 inodes, blocksize: 262144 bytes, created: 2023-11-20 02:39:18


Enter SquashFS OFFSET (decimal or 0xhex): 1049088 # Offset to the compressed rootfs
Block size [default 1048576]: # Default to 1Mib but can be changed
[*] Using block size: 1048576
[*] Creating SquashFS...
[*] New SquashFS size: 2830336 bytes
[*] Padding SquashFS with 171820 bytes (0xFF)...
[*] Building firmware...
[*] Adding final padding: 12500 bytes (0xFF)...
[*] Creating stripped firmware (removing first 512 bytes)...
[+] Stripped firmware created: /tmp/new-firmware-stripped.bin
[*] Stripped firmware size: 4063232 bytes
========================================
[*] FINAL CHECK
[*] SquashFS size: 3002156 (target 3002156)
[*] Firmware size: 4063744 (target 4063744)
[+] Firmware created: /tmp/new-firmware.bin
========================================
```
**Note:** The script automatically generates a `stripped` version of the firmware (without the U-Boot header), which
is particularly useful for flashing via `TFTP`. For a detailed explanation of this requirement, refer to the corresponding 
document ([Firmware-flashing.md](Firmware-flashing.md)).

## Security Implications
From an IoT security perspective, this phase highlights a critical property of embedded systems: firmware integrity is 
not limited to cryptographic verification. Even in the absence of secure boot mechanisms, strict assumptions about 
firmware layout, compression, and alignment can enforce implicit integrity constraints.

Failure to respect these constraints can lead to persistent misconfiguration, denial of service, or irreversible device
states. Conversely, understanding and reproducing these constraints enables reliable firmware modification, controlled 
exploitation, and forensic analysis without unnecessary device damage.