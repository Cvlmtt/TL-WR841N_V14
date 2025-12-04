# Static analysis

- Model: `TL-WR841N`
- Hardware version: `V14.1`

This document describes how we obtained and inspected the official TP-Link firmware for the `TL-WR841N` (EU build), and how we tested flashing methods. The original firmware was downloaded from the TP-Link support page: https://www.tp-link.com/it/support/download/tl-wr841n/#Firmware. Always choose the firmware that matches the router model, hardware version and the target region (EU in our case).

We unpacked the firmware with `binwalk3` to inspect its structure.

![Binwalk extraction](imgs/binwalk3_extraction.png)

You can also use the `firmware-mod-kit` (FMK) suite, which includes `binwalk` and provides utilities to rebuild firmware 
after modifications. Firmware can be emulated with `qemu`, but qemu-based emulation often requires workarounds and may 
have issues emulating shared memory and will not emulate proprietary hardware interfaces, so results can be incomplete. 
Thus, we chose to test on the physical device.

We explored two flashing methods:
- Using the router's default web interface
- Using a TFTP server (recovery mode)

## Web interface flash

To flash a custom image from the router web interface you must provide a firmware file that the web update mechanism will accept.
To validate that the firmware extraction was successful we unpacked the firmware with `firmware-mod-kit`, modified the 
web UI in the extracted `rootfs` (for example by editing `rootfs/web/index.htm` and adding `rootfs/web/js/test.js`),
and rebuilt the image using FMK.

![FMK extract](imgs/fmk-extraction.png)
![Index.htm](imgs/index-htm.png)
![Test.js](imgs/test-js.png)
![FMK rebuild](imgs/fmk-rebuild.png)

We uploaded the rebuilt `.bin` file through the router web interface to confirm the update process accepted and flashed the image.

![Firmware upload](imgs/firmware-test-upload.png)
![Alert](imgs/alert.png)

This verified that `firmware-mod-kit` can rebuild a valid firmware image starting from the original `.bin` rootfs.

## TFTP recovery flash

If the web interface is not available (for example after a brick or during a bootloop), you can force a flash using a
TFTP server. Place a firmware file with the correct filename in the TFTP server root, force the device into recovery mode,
and the router will pull the file and flash it. For the `V14` hardware the recovery filename is `tp_recovery.bin`.

### Install TFTP server on Fedora

Run:

```
sudo dnf install tftp-server tftp -y
sudo cp /usr/lib/systemd/system/tftp.service /etc/systemd/system/tftp-server.service
sudo cp /usr/lib/systemd/system/tftp.socket /etc/systemd/system/tftp-server.socket
```

Edit `/etc/systemd/system/tftp-server.service`  (for example with `nano`) to match:

```
[Unit]
Description=TFTP Server
Requires=tftp-server.socket
Documentation=man:in.tftpd

[Service]
ExecStart=/usr/sbin/in.tftpd -c -p -s /var/lib/tftpboot
StandardInput=socket

[Install]
WantedBy=multi-user.target
Also=tftp-server.socket
```

Save the file, then run:

```
sudo systemctl daemon-reload
sudo systemctl enable --now tftp-server
sudo chmod 777 /var/lib/tftpboot
sudo firewall-cmd --add-service=tftp --permanent
sudo firewall-cmd --reload
```

Notes:
- We intentionally avoid recommending disabling the firewall or SELinux permanently. In some test environments you may temporarily stop `firewalld` or set SELinux to permissive, but do so only briefly and understand the risk.
- TFTP is insecure; do not expose it to untrusted networks.

To place a file in the TFTP root:

```
sudo mv <filename> /var/lib/tftpboot/
```

### Recovery procedure and flashing

For the router to pull the file from the TFTP server, configure the server interface with IP `192.168.0.66` and netmask `255.255.255.0`, and place the file named `tp_recovery.bin` in the TFTP root. Then follow the hardware-specific recovery sequence:

- Disconnect power
- Press and hold the WPS/RESET button
- Reconnect power while holding the button
- Release the button only when the WPS (orange) LED starts flashing rapidly

When in recovery mode the router will attempt to download `tp_recovery.bin` from `192.168.0.66`. You can monitor TFTP transfers with:

```
sudo tcpdump -ni <eth> port 69
```

After the flash completes the device reboots and the web interface should be available at `192.168.0.1`.

Il file `scripts/tftp_server.sh` automatizza il processo di setup del server tftp e la predisposizione dell'interfaccia, indirizzo IP e file di recovery. Quando lo script viene eseguito, dopo aver predisposto l'ambiente, esegue `tcpdump` sull'interfaccia specificata e quando viene interrotto con la combinazione `Ctrl+c` ripristina l'ambiente reimpostando le modalità di firewall e SELinux, e eliminando le directory non più necessarie.
Modalità di utilizzo:
```
./tftp_server.sh <interfaccia_di_rete> <firmware.bin>
```

### Note: stripped firmware
Unlike the web-update process, TFTP recovery usually expects a stripped firmware image without the boot image. To create a recovery file from a rebuilt firmware you can use:

```
dd if=new-firmware.bin of=tp_recovery.bin skip=1 bs=512
```

Note: see the OpenWRT guide on how to go back to the original firmware: https://openwrt.org/toh/tp-link/tl-wr841nd#go_back_to_original_firmware
