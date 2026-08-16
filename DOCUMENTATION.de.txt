FTPSVC.R4X
==========

FTPSVC.R4X ist der FTP-Serverdienst fuer R4OS.

Stand 0.60.20 (Kommandoumfang seit 0.55.13):

- Service-Name: `FTPSVC`
- Zielpfad im Image: `C:\R4OS\SERVICES\FTPSVC.R4X`
- Control-Port im Gast: `21`
- Passiver Datenport im Gast: `2020`
- QEMU-Standardweiterleitung: Host `127.0.0.1:10021` -> R4OS
  `10.0.2.15:21`, Host `127.0.0.1:10020` -> R4OS `10.0.2.15:2020`
- Standard-Zugangsdaten: `r4os` / `rosebud`
- Standard-Service-Start: `auto`

FTPSVC ist ein normaler R4X-Service. Der Dienst registriert einen Service-
Endpunkt, lauscht ueber `TCPSVC` auf Port 21 und nutzt R4NET fuer TCP sowie
R4SYS fuer Laufwerke, Directories und Datei-I/O. Es gibt keinen Kernel-FTP-
Pfad, keinen zweiten Datei-I/O-Fallback und keine eigene User-, Gruppen-,
Rechte- oder Sandboxlogik. Authentifiziert wird ausschliesslich gegen die
festen Zugangsdaten `r4os:rosebud`.

Die FTP-Wurzel ist keine echte FAT32-Directory, sondern eine virtuelle
Laufwerksansicht. `PWD` meldet dort `/`, `LIST /` und `STAT /` zeigen die
verfuegbaren gemounteten Laufwerke als Eintraege `C`, `D`, `E` usw. `CWD C`
und `CWD /C` wechseln nach `C:\`; FTP-Pfade wie `/C/R4OS` sowie DOS-Pfade wie
`C:\R4OS` und `C:/R4OS` werden auf denselben R4SYS-Pfad normalisiert.
Relative Segmente, doppelte Trenner, `.` und `..` werden vor Dateisystemzugriff
aufgeloest.

Unterstuetzte Kommandos in 0.55.13:

- `USER`, `PASS`, `QUIT`, `NOOP`
- `SYST`, `FEAT`, `OPTS UTF8 ON`, `TYPE A`, `TYPE I`
- `PWD`, `CWD`, `CDUP`
- `PASV`, `EPSV` und `PORT`
- `LIST`, `NLST`, `STAT`
- `SIZE`, `RETR`, `STOR`
- `DELE`, `RNFR`, `RNTO`
- `MKD`, `RMD`
- `ABOR` fuer vorbereitete Datenkanaele

`LIST` und `NLST` verwenden nach `PASV`, `EPSV` oder `PORT` einen echten
FTP-Datenkanal. Ohne vorbereiteten Datenkanal bleibt ein Control-Listing fuer
Diagnose und alte 0.55.12-Abnahme moeglich; `STAT` bleibt bewusst Control-
basiert. Downloads laufen ueber `fileReadAt`.

Seit 0.60.20 schreibt `STOR` nie direkt in den sichtbaren Zielnamen. Der
Dienst reserviert einen privaten 8.3-Sibling-Stage, streamt ihn mit
`fileStreamBegin(open_create)`/`fileStreamWrite`, behaelt die Ownership bei
`fileStreamFinish` und publiziert ihn anschliessend atomar und create-only.
Ein bereits vorhandenes Ziel wird sichtbar abgelehnt; auch leere Uploads
durchlaufen denselben Vertrag. Bei einem mehrdeutigen Storage-I/O-Ergebnis
bleiben exakter Stage-, Ziel- und Backupname erhalten, bis der owner-gepruefte
Abort beziehungsweise die atomare Publish-Wiederaufnahme abgeschlossen ist.
Lookup-I/O wird als temporaerer FTP-Fehler `451` und nicht als vermeintliches
`not found` gemeldet.

Direkte FTP-Mutationen unter `C:\R4OS`, den Bootbaeumen auf C: sowie
`D:\BOOT`, `D:\EFI` und `D:\LIMINE` sind gesperrt. Systemupdate-Payloads
werden ausschliesslich unter `C:\R4OS\UPDATE\INBOX\` angenommen; das eigentliche
Ersetzen bleibt SYSUPD vorbehalten. Rename, Delete, MKD und RMD nutzen die
entsprechenden R4SYS-Operationen unter derselben Pfadregel.

Nuetzliche Aufrufe:

    SERVMAN STATUS FTPSVC

Host-Abnahmen:

    Tests/Runtime/Run-FtpServiceControlLiveTest05512.ps1
    Tests/Runtime/Run-FtpServiceTransferLiveTest05513.ps1
