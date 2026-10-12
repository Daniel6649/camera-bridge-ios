# IPA über GitHub bauen und unter Windows installieren

## Was eingerichtet ist

`.github/workflows/build-ios.yml` verwendet einen macOS-15-Runner mit Xcode. Er prüft die Transport-Byteformate, kompiliert einen echten iOS-Geräte-Build und packt `Payload/CameraBridge.app` in `CameraBridge-unsigned.ipa`. Es sind keine Apple-Schlüssel, Zertifikate oder Kontodaten im Workflow nötig.

Der Workflow startet nach einem Upload der iOS-Dateien oder manuell unter **Actions → Build Camera Bridge IPA → Run workflow**. Ein erfolgreicher Build stellt **CameraBridge-unsigned-IPA** als Download bereit. Bei Fehlern werden die Build-Logs separat gespeichert. Ein grüner Build bestätigt die Kompilierung; die Kamera-/Desktop-Verbindung muss weiterhin auf dem iPhone geprüft werden.

## Erstes Repository

1. Bei GitHub anmelden und ein privates Repository, beispielsweise `camera-bridge-ios`, mit einer README anlegen.
2. Die Quell-Dateien dieses Pakets einschließlich `.github/workflows/build-ios.yml` hochladen. Nicht nur das ZIP hochladen: Die Verzeichnisstruktur muss im Repository erhalten bleiben.
3. Den Workflow starten und sein Ergebnis prüfen. Falls der GitHub-Zugang von Codex nur ausgewählte Repositories sieht, dieses Repository in der vorhandenen GitHub-Verbindung freigeben.

Private Repositories nutzen das enthaltene Actions-Kontingent. Der Workflow aktiviert keine zusätzlichen kostenpflichtigen Angebote und läuft höchstens 20 Minuten pro Ausführung.

## IPA auf dem iPhone installieren

1. Nach erfolgreichem Build das Artefakt **CameraBridge-unsigned-IPA** herunterladen und dessen ZIP entpacken.
2. Sideloadly ausschließlich von https://sideloadly.io/ herunterladen.
3. Das iPhone mit dem Windows-PC verbinden, die IPA in Sideloadly auswählen und mit deiner Apple-ID signieren/installieren.
4. Apple-Anmeldedaten direkt in Sideloadly eingeben, nicht in den Chat oder das Repository. Falls iOS es verlangt, den Entwickler in den Einstellungen bestätigen und den Entwicklermodus einschalten.

Eine unsignierte IPA lässt sich nicht unmittelbar durch Antippen installieren. Das Signieren für dein Gerät übernimmt Sideloadly. Die Gültigkeitsdauer hängt vom verwendeten Apple-Konto ab.

## Lokale Skripte

- `ios/scripts/build-unsigned-ipa.sh`: gleicher Geräte-Build und IPA-Paketierung wie in GitHub Actions; benötigt macOS/Xcode.
- `ios/scripts/check-wire-format.sh`: führt Prüfungen gegen rekonstruierte Referenzbytes aus.
- `ios/scripts/build-export.sh`: optionaler regulärer Export mit Apple-Signierung auf einem Mac.

Die Cloud-Konfiguration wurde lokal vorbereitet. Ein echter GitHub-Build und die Installation sind erst bestätigt, nachdem die entsprechende Ausführung erfolgreich abgeschlossen ist.
