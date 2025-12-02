# Static Analysis
- Model: TL-WR841N
- Hardware Version: V14.1
Abbiamo recuperato il frimware dal sito ufficiale TP-Link: https://www.tp-link.com/it/support/download/tl-wr841n/#Firmware. La versione del firmware è specifica per il modello riportato e la versione hardware corrispondente. È necessario scaricare il firmware adeguato in base alla regione di provenienza del router, nel nostro caso EU. 

Abbiamo estratto il firmware con `binwalk3` per analizzarne la struttura. 

![Binwalk3 extraction](imgs/binwalk3_extraction.png)

Per l'estrazione del firmware è possibile utilizzare anche `firmware-mod-kit` che è un tool più ampio il quale include `binwalk`. Tramite `firmware-mod-kit` è possibile anche ri-buildare il firmware dopo averlo modificato. 
Il firmware può essere emulato utilizzando `qemu`, il quale richiede però del workaround per funzionare. Inoltre, l'emulazione non risulta completa a causa dell'impossibilità di gestire la shared memory. Disponendo dell'hardware necessario abbiamo proceduto quindi con il testing diretto sull'hardware. 
Sono state esplorate due modalità di flash del firmware:
- tramite interfaccia web di default del router
- tramite server TFTP

## Web Interface firmware flash
Per flashare correttamente il firmware tramite l'interfaccia web di default del router TP-Link è necessario fornire una versione del firmware corretta. Per verificare il funzionamento della tool-chain abbiamo estratto il firmware tramite `firmware-mod-kit`. 
![FMK extract](imgs/fmk-extraction.png)
Per verificare che il firmware flashato fosse quello custom abbiamo modificato il file `rootfs/web/index.htm` aggiungendo lo script `rootfs/web/js/test.js`:

![Index.htm](imgs/index-htm.png)

![Test.js](imgs/test-js.png)

Abbiamo re-buildato il firmware tramite `firmware-mod-kit` per verificare che il tool generasse un firmware valido e accettato dal sistema di update. 

![FMK rebuild](imgs/fmk-rebuild.png)

Una volta ottenuto il firmware re-buildato, abbiamo provato a fornire in input all'interfaccia web del router il file `.bin` per verificare che l'update venisse eseguito con successo.

![Firmware upload](imgs/firmware-test-upload.png)

Una volta completato il flash del firmware il router si è riavviato autonomamente e dopo aver eseguito il login il risultato è stato il seguente:

![Alert](imgs/alert.png)

In questo modo siamo riusciti a verificare che `firmware-mod-kit` riuscisse a buildare correttamente il firmware a partire dal `rootfs` ottenuto dal `.bin` originale.

## TFTP server
Nel caso in cui non fosse disponibile l'interfaccia web del router (ad esempio in caso di brick o bootloop del device), un'altertantiva è il flash forzato tramite un server TFTP. In sostanza, è possibile caricare all'interno della root directory del server un firmware in formato `.bin` con un nome specifico per ogni versione dell'hardware, e forzando il device in recovery mode mentre è collegato via ethernet al server, il router recupererà autonomamente il file e ne eseguirà il flash. Nel caso del nostro dispositivo, la versione hardware è la V14 e il nome da dare al file `.bin` è `tp_recovery.bin`. 

### Installazione TFTP server Fedora
Esegui: 
```
sudo dnf install tftp-server tftp -y
cp /usr/lib/systemd/system/tftp.service /etc/systemd/system/tftp-server.service
cp /usr/lib/systemd/system/tftp.socket /etc/systemd/system/tftp-server.socket
```

Modificare il file `/etc/systemd/system/tftp-server.service` nel seguente modo:
```
[Unit]
Description=Tftp Server
Requires=tftp-server.socket
Documentation=man:in.tftpd

[Service]
ExecStart=/usr/sbin/in.tftpd -c -p -s /var/lib/tftpboot
StandardInput=socket

[Install]
WantedBy=multi-user.target
Also=tftp-server.socket
```

`Ctrl+o` per salvare e `Ctrl+x` per chiudere se usato `nano`. 

Successivamente esegui:
```
sudo systemctl daemon-reload
sudo enable --now tftp-server
chmod 777 /var/lib/tftpboot
firewall-cmd --add-service=tftp --perm
firewall-cmd --reload
sudo systemctl stop firewalld
sudo setenforce 0
``` 

Le modifiche alla sicurezza del sistema host per il server sono da intendersi come momentanee e da mantenere solamente per il processo di flash tramite il server TFTP. TFTP è considerato insicuro ed è consigliabile non esporre tale servizio verso l'esterno. 

Per caricare un file nella root del server TFTP eseguire:
```
mv <filename> /var/lib/tftpboot
```
## TFTP server flash
Affinché il router sia in grado di eseguire il pull del file dal server TFTP, l'interfaccia di rete del server deve avere inidirizzo IP = `192.168.0.66`, Netmask = `255.255.255.0` e il nome del file deve essere `tp_recovery.bin`.
Una volta avviato il server e connesso il router via ethernet sarà necessario impostarlo in recovery mode. Nel caso specifico del TL-WR841N è necessario seguire i seguenti step:
- scollegare l'alimentazione
- premere e mantenere premuto il pulsante WPS/RESET
- collegare l'alimentazione
- rilasciare il pulsante WPS/RESET solo quando la luce arancione WPS inizia a lapeggiare rapidamente 

Quando il router sarà in modalità recovery proverà ad eseguire il pull del file `tp_recovery.bin` dal server TFTP all'indirizzo `192.168.0.66`. Le richieste possono essere verificate tramite:
```
sudo tcpdump -ni <eth> port 69
```

Una volta terminata l'installazione del firmware il device si riavvierà autonomamente e l'interfaccia web sarà accessibile all'indirizzo `192.168.0.1`. 

Contrariamente a quanto accade per l'installazione del firmware tramite interfaccia web, con il server TFTP è necessario fornire una versione stripped del firmware che non comprende la boot image. Per fare ciò, dal firmware ottenuto tramite `firmware-mod-kit` abbiamo eseguito:
```
dd if=new-firmware.bin of=tp_recovery.bin skip=1 bs=512
```

Note: see OpenWRT guide to [go back to original firmwar](https://openwrt.org/toh/tp-link/tl-wr841nd#go_back_to_original_firmware).
