# Camera Bridge – eigener iOS-Client

Eigenständig geschriebener Swift-Client auf Basis der statischen Analyse von iVCam iOS 7.2.0 und Desktop 7.4.2. Das Projekt enthält keine Original-App-Binaries und keine Kaufmanipulationen.

## Stand

Version 0.2.0 startet die Kamera beim Öffnen, hält Start/Stop sichtbar und zeigt Aufnahme- und Verbindungsstatus getrennt. Der Encoder wird aus den tatsächlichen Kamerabuffer-Abmessungen eingerichtet; ein Encoderfehler stoppt die Vorschau nicht. Ohne manuelle Desktop-Adresse sucht die App den iVCam-Dienst per Bonjour. Kamerazugriff und lokaler Netzwerkzugriff müssen auf dem iPhone erlaubt werden.

Implementiert sind Kamera-Vorschau, H.264-Encoding, manuelle Desktop-Adresse, Bonjour-Suche und der rekonstruierte TCP-Verbindungsablauf. Unterstützte Auflösungen und Bildraten hängen vom iPhone ab.

Der GitHub-Build ist erfolgreich: Xcode 16.4 kompiliert die App für ARM64/iOS 15+, die Protokoll-Referenzprüfungen bestehen, und eine unsignierte IPA wird erzeugt. [Bestätigter Build](https://github.com/Daniel6649/camera-bridge-ios/actions/runs/38259282862).

Die Anmeldung ist anhand einer tatsächlichen Antwort des installierten Desktop-Clients bestätigt. Die vollständige Videoübertragung der finalen Implementierung ist noch nicht auf einem iPhone getestet. Ein früherer Test ohne die erforderliche Kontrollanmeldung zeigte nur das Wartebild; daraus folgt ausdrücklich keine bestätigte Videokompatibilität.

Bekannter offener Fehler: Auch unabhängige Tests mit erzeugtem H.264-Testbild, verschiedenen Startsequenzen und 720p/30 fps zeigten weiterhin das Wartebild der virtuellen Desktop-Kamera. Ein erfolgreicher Verbindungsstatus allein bestätigt keine Videoübertragung. Die neue Version verbessert Vorschau, Suche und Diagnose; die vollständige Desktop-Interoperabilität ist nicht bestätigt.

Nicht abgeschlossen: vollständige Rekonstruktion aller App-Funktionen, Audio, USB-Verbindung, automatische Wiederverbindung und Fernsteuerung aller Kamera-Einstellungen. Die Änderungen der Version 0.2.0 müssen auf dem iPhone geprüft werden. Dies ist ein Prototyp, kein vollständiger Ersatz der Original-App.

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
