# Camera Bridge – eigener iOS-Client

Eigenständig geschriebener Swift-Client auf Basis der statischen Analyse von iVCam iOS 7.2.0 und Desktop 7.4.2. Das Projekt enthält keine Original-App-Binaries und keine Kaufmanipulationen.

## Stand

Implementiert sind Kamera-Vorschau, H.264-Encoding, manuelle Desktop-Adresse und der rekonstruierte TCP-Verbindungsablauf. Unterstützte Auflösungen und Bildraten hängen vom iPhone ab.

Die Anmeldung ist anhand einer tatsächlichen Antwort des installierten Desktop-Clients bestätigt. Die vollständige Videoübertragung der finalen Implementierung ist noch nicht getestet. Ein früherer Test ohne die erforderliche Kontrollanmeldung zeigte nur das Wartebild; daraus folgt ausdrücklich keine bestätigte Videokompatibilität.

Nicht abgeschlossen: vollständige Rekonstruktion aller App-Funktionen, Audio, USB-Verbindung, automatische Suche/Wiederverbindung und Fernsteuerung aller Kamera-Einstellungen. Auch Xcode-Kompilierung, iPhone-Ausführung und IPA-Signierung stehen aus. Dies ist ein Prototyp, kein vollständiger Ersatz der Original-App.

## Auf dem Mac starten

Ohne eigenen Mac: Die Anleitung `CLOUD-BUILD.md` beschreibt den vorbereiteten GitHub-Workflow und die anschließende Installation unter Windows mit Sideloadly.

1. Dieses Paket auf den Mac kopieren und entpacken.
2. `ios/CameraBridge.xcodeproj` in Xcode öffnen.
3. Unter **Signing & Capabilities** dein Team und eine eigene Bundle-ID auswählen.
4. Ein echtes iPhone als Ziel auswählen und **Run** drücken.
5. Kamera zunächst lokal testen. Danach die lokale IP-Adresse des Windows-PCs eingeben und mit dem dort laufenden iVCam-Client testen. Der Desktop-Empfänger darf dabei nicht bereits mit einer anderen Kamera verbunden sein.

Eine fertige IPA kann erst auf dem Mac mit gültiger Signierung erzeugt werden. Das Skript `ios/scripts/build-export.sh` übernimmt Archivierung und Export; `BUILD.md` erklärt die erforderlichen Angaben und Einschränkungen des Apple-Kontos.

## Analyse

- `analysis/ios-protocol-findings.md`: iOS-Seite mit ARM64-Adressen.
- `analysis/desktop-findings.md`: Desktop-Seite mit x64-Adressen.
- Die vollständigen lokalen Rohdaten liegen im Arbeitsordner, nicht im kleinen Mac-Paket.

Die Protokollanmeldung verwendet einen neutralen, nicht gekauften Status. Einschränkungen des Desktop-Clients bleiben erhalten.
