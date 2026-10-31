# Camera Bridge – eigener iOS-Client

Eigenständig geschriebener Swift-Client auf Basis der statischen Analyse von iVCam iOS 7.2.0 und Desktop 7.4.2. Das Projekt enthält keine Original-App-Binaries und keine Kaufmanipulationen.

## Stand

Version 0.6.1 ergänzt Bitraten-Vorgaben: **Niedrig 3**, **Mittel 6**, **Hoch 12 Mbit/s** sowie **Custom**. Nur Custom zeigt den freien Regler und die Feineinstellung. Der letzte eigene Wert bleibt beim Wechsel zu Vorgaben erhalten; die angewendete Auswahl wird gespeichert. Neue Installationen starten mit Mittel (6 Mbit/s), vorhandene Bitraten bleiben erhalten. Die passenden PC-Schaltflächen sind in Receiver 0.3.3 verfügbar und funktionieren auch mit der vorherigen iPhone-Version.

Version 0.6.0 startet die Kamera automatisch beim Öffnen und bei der Rückkehr in den Vordergrund. Ein geöffneter Receiver verbindet sich per USB und startet die Übertragung ohne weiteren Startknopf. USB-Listener und Encoder versuchen nach Fehlern erneut zu starten; während der Kameraaufnahme bleibt das iPhone wach. Die App muss auf dem iPhone geöffnet bleiben: Sie kann sich durch Einstecken des Kabels nicht selbst aus einem beendeten Zustand öffnen.

Die Ausrichtung folgt automatisch der Gerätehaltung (Hochformat, gedrehtes Hochformat, beide Querformate). Flache/unklare Positionen behalten den letzten Winkel. `AVCaptureVideoDataOutput` rotiert die tatsächlichen Bildpuffer; Encoder und Transport handeln die neuen Abmessungen mit dem PC aus. Für den Receiver werden Sensorauflösung und gedrehte Bildgröße getrennt gemeldet, damit FPS/Bitrate auch im Hochformat vom PC konfigurierbar bleiben. Passender Receiver: 0.3.2 oder neuer. Physische Geräte-Rotation und Vordergrundwechsel müssen nach Installation der neuen IPA geprüft werden.

Version 0.5.0 verbindet die eigenen Einstellungen mit Receiver 0.3.0 auf Windows. Unterstützte Auflösungen/FPS, Bitrate und Zoomgrenzen werden über USB/WLAN gemeldet; PC-Befehle konfigurieren Kamera und Encoder beziehungsweise den Zoom tatsächlich. Die App antwortet mit einer Anfrage-ID und den gesetzten Werten. Formatwechsel starten Kamera und Verbindung neu. Die erweiterten Einstellungen des Original-iVCam-Protokolls sind weiterhin nicht vollständig implementiert; die eigene Erweiterung steuert diese vier Videoeinstellungen.

Version 0.4.0 ergänzt konfigurierbare Videoeinstellungen auf dem iPhone: 480p, 720p, 1080p und 4K sowie 15/24/25/30/50/60/90/120 FPS werden nur angeboten, wenn die gewählte Kamera die jeweilige Kombination unterstützt. Die H.264-Zielbitrate ist in Schritten von 0,5 Mbit/s zwischen 0,5 und 50 Mbit/s einstellbar. Es handelt sich um eine durchschnittliche Zielbitrate, keine konstante oder harte Obergrenze ([Apple VideoToolbox](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_averagebitrate)).

Während der Übertragung können die Werte geändert und mit **Videoeinstellungen übernehmen** angewendet werden. Kamera, Encoder und Verbindung werden dazu neu gestartet. Die angewendeten Werte bleiben beim nächsten App-Start erhalten. Der Encoder und die USB/WLAN-Anmeldung verwenden dieselbe gewählte Bitrate. Die tatsächliche Geräteunterstützung und Bildübertragung müssen weiterhin auf dem iPhone geprüft werden.

Der zusätzliche Zoom-Regler wirkt sofort auf die laufende Kamera, damit auf Vorschau und übertragenes Bild. Er verwendet die tatsächlichen Zoomgrenzen des aktiven Kameraformats und eine logarithmische Skala für feinere Bedienung. **1×** setzt den Zoom zurück; der letzte Wert wird beim nächsten Start wiederhergestellt und an den dann verfügbaren Bereich angepasst.

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
