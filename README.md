# Camera Bridge – eigener iOS-Client

Eigenständig geschriebener Swift-Client auf Basis der statischen Analyse von iVCam iOS 7.2.0 und Desktop 7.4.2. Das Projekt enthält keine Original-App-Binaries und keine Kaufmanipulationen.

## Stand

Version 0.3.1 startet mit USB als voreingestellter Verbindung. Das iPhone lauscht auf dem lokalen Port 5895; der vorhandene Windows-iVCam-Client verbindet sich über Apples USB-Multiplexing. Anmeldung, Einstellungen, Metadaten und Video werden mit dem rekonstruierten PeerTalk-Rahmen übertragen. Die Kamera startet beim Öffnen, Start/Stop bleiben sichtbar, und Aufnahme- und Verbindungsstatus werden getrennt angezeigt. Der Encoder wird aus den tatsächlichen Kamerabuffer-Abmessungen eingerichtet; ein Encoderfehler stoppt die Vorschau nicht.

Für USB: iPhone per Datenkabel anschließen, entsperren, diesem Computer vertrauen und den iVCam-Desktop öffnen. Die App im Vordergrund lassen. Eine PC-Adresse ist nicht nötig. Der vorhandene Apple-USB-Dienst hat am Entwicklungs-PC bereits ein USB-Gerät erkannt. Die tatsächliche Bildübertragung der neuen App über USB ist noch nicht bestätigt.

Implementiert sind Kamera-Vorschau, H.264-Encoding, USB-Verbindung, manuelle WLAN-Adresse, Bonjour-Suche und der rekonstruierte TCP-Verbindungsablauf. Für WLAN die Kamera stoppen, WLAN wählen und neu starten. Unterstützte Auflösungen und Bildraten hängen vom iPhone ab.

Der GitHub-Build für Version 0.3.1 ist erfolgreich: Xcode 16.4 kompiliert die App für ARM64/iOS 15+, die Protokoll-Referenzprüfungen einschließlich USB-Framing, fragmentierter Pakete und vollständiger AVCC-Bildblöcke bestehen, und eine unsignierte IPA wird erzeugt. [Bestätigter Build](https://github.com/Daniel6649/camera-bridge-ios/actions/runs/38269293272).

Die korrigierte Verpackung wurde mit einem unabhängig erzeugten Testvideo am installierten Desktop-Client geprüft: 270 Bilder bei 1280×720/30 fps erreichten Decoder und virtuelle Kamera; frische Aufnahmen zeigen das Testbild. Frühere Aufnahmen mit nackten NAL-Daten zeigten das Wartebild. Dieser Test bestätigt den Videoblock über TCP, die USB-Verbindung der neuen iPhone-Version muss gesondert geprüft werden.

Version 0.3.0 meldete eine Verbindung, zeigte aber kein Desktop-Bild. Eine passive Prüfung des tatsächlichen Desktop-Empfängers bestätigte 859 Videopakete, Metadaten 1280×720/30 fps und gültige SPS/PPS. Der Fehler lag im Videoblock: Die App entfernte die internen AVCC-NAL-Längen, die der Desktop für die Annex-B-Konvertierung braucht. Version 0.3.1 sendet einen vollständigen AVCC-Bildblock einschließlich aller internen Längen und einer zusätzlichen äußeren Blocklänge. Originaler iOS-Produzent und Desktop-Konverter bestätigen dieses Format unabhängig. Die tatsächliche USB-Bildanzeige dieser Korrektur muss auf dem iPhone geprüft werden.

Nicht abgeschlossen: vollständige Rekonstruktion aller App-Funktionen, Audio und Fernsteuerung aller Kamera-Einstellungen. Nach einer geschlossenen USB-Verbindung wartet die App erneut auf den Desktop. Dies ist ein Prototyp, kein vollständiger Ersatz der Original-App.

## Auf dem Mac starten

Ohne eigenen Mac: Die Anleitung `CLOUD-BUILD.md` beschreibt den vorbereiteten GitHub-Workflow und die anschließende Installation unter Windows mit Sideloadly.

1. Dieses Paket auf den Mac kopieren und entpacken.
2. `ios/CameraBridge.xcodeproj` in Xcode öffnen.
3. Unter **Signing & Capabilities** dein Team und eine eigene Bundle-ID auswählen.
4. Ein echtes iPhone als Ziel auswählen und **Run** drücken.
5. Kamera zunächst lokal testen. Danach die lokale IP-Adresse des Windows-PCs eingeben und mit dem dort laufenden iVCam-Client testen. Der Desktop-Empfänger darf dabei nicht bereits mit einer anderen Kamera verbunden sein.

Die Cloud erzeugt eine unsignierte IPA; diese kann unter Windows mit Sideloadly für dein iPhone signiert werden. Alternativ übernimmt `ios/scripts/build-export.sh` einen regulären signierten Export auf dem Mac. `BUILD.md` erklärt die Schritte.

## Analyse

Das Projekt basiert auf statischer Analyse beider Programme und einem Kontrollanmeldungstest. Analyse-Rohdaten bleiben im lokalen Arbeitsordner; das Repository enthält die eigenen App-Quellen und Build-Skripte.

Die Protokollanmeldung verwendet einen neutralen, nicht gekauften Status. Einschränkungen des Desktop-Clients bleiben erhalten.
