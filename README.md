# AniLounge

Persönlicher, inoffizieller AniWorld-Client mit einer dunklen, von Streaming-Apps inspirierten SwiftUI-Oberfläche. Zielgerät: iPhone 13 mit iOS 16.4.1 und bereits eingerichtetem TrollStore. Das Layout unterstützt auch iPad; die Installation dort benötigt einen eigenen kompatiblen Installationsweg.

## Enthalten

- Startseite mit großem Titelbild, horizontalen Cover-Reihen und echten Website-Daten.
- Native Suche im vollständigen Katalog, auch nach alternativen Titeln.
- Anime-Details mit Beschreibung, Genres, Staffeln und Episoden.
- Lokale Merkliste, zuletzt geöffnete Episoden und manuell gesetzte Gesehen-Markierungen.
- Episoden öffnen im integrierten Safari-Browser.
- GitHub Actions zum Testen und Erstellen einer IPA für TrollStore.

**Versionsstand 0.1:** Der Quellcode wurde erstellt und statisch geprüft. Ein Xcode-Build und Tests auf einem echten iPhone sind noch ausstehend. Eine fertig gebaute IPA ist in diesem Quellcode-Paket nicht enthalten.

## Wiedergabe

Diese Version besitzt eine native Oberfläche für den Katalog. Nach Auswahl einer Folge erscheint deren AniWorld-Webseite in einem Safari-Fenster innerhalb der App. Sprache und Hoster wählst du dort. Die tatsächliche Wiedergabe hängt vom Anbieter und dessen Browser-Unterstützung ab und ist noch nicht auf dem Zielgerät geprüft.

Ein direkter AVPlayer, automatische Wiedergabepositionen, Downloads und Kontosynchronisation sind nicht implementiert. „Zuletzt geöffnet“ ist kein Nachweis einer angesehenen Folge. Das Häkchen an einer Episode setzt du selbst.

## Auf GitHub bauen – ohne eigenen Mac

1. Erstelle ein **öffentliches** Repository, z. B. `AniLounge`, und initialisiere es mit einer README. Wenn ChatGPT Zugriff erhalten soll, gib genau dieses Repository für die GitHub-Verbindung frei und sende den Link. Der vorbereitete Code kann dann dort eingespielt werden.
2. Alternativ lade den Inhalt dieses Projektordners in das Repository. `project.yml`, `Core`, `AniLounge`, `scripts` und `.github` müssen direkt im Hauptverzeichnis liegen. Das ZIP selbst allein löst keinen Build aus. Beim Upload auf dem iPad ist der versteckte `.github`-Ordner leicht zu übersehen; die Workflow-Datei kann über „Add file → Create new file“ unter `.github/workflows/build.yml` angelegt werden.
3. Öffne **Actions → Build AniLounge IPA → Run workflow**. Beim Push auf `main` startet der Workflow ebenfalls, sobald die relevanten Dateien dort liegen.
4. Warte auf einen erfolgreichen Lauf. Öffne unter **Artifacts** den Download `AniLounge-TrollStore`.
5. Entpacke das heruntergeladene Artefakt in der Dateien-App. Die darin liegende `AniLounge.ipa` auf dem iPhone über „Teilen → TrollStore“ öffnen und installieren.

Kein Apple-Entwicklerzertifikat wird für diesen Build verwendet. Der Workflow erstellt eine Ad-hoc-signierte IPA, deren Installation TrollStore übernimmt. GitHub Actions muss im Repository aktiviert sein und verfügbares Nutzungskontingent besitzen. Die App selbst benötigt keine zusätzlichen privilegierten Entitlements.

## Lokal mit einem Mac

Voraussetzungen: Xcode mit iOS-SDK, Xcode Command Line Tools, Homebrew und XcodeGen.

```bash
brew install xcodegen
swift test --package-path Core
bash scripts/build-ipa.sh
```

Ergebnis: `build/AniLounge.ipa`. Für die Arbeit im Simulator: `xcodegen generate`, anschließend `AniLounge.xcodeproj` öffnen und das Schema `AniLounge` wählen. Für eine reguläre Installation über Xcode muss eine eigene Signierung konfiguriert werden.

## Aufbau

- `AniLounge/`: SwiftUI-Ansichten, lokaler Speicher, Safari-Integration.
- `Core/`: Swift-Paket für Datenmodelle, Netzwerkzugriff und HTML-Auswertung.
- `Core/Tests/`: acht Parser-Tests mit einer kleinen synthetischen HTML-Fixture.
- `project.yml`: XcodeGen-Konfiguration, Mindestversion iOS 16.4.
- `.github/workflows/build.yml`: macOS-Build, Parser-Tests, IPA-Artefakt.
- `scripts/validate-ipa.py`: prüft Bundle-ID, ausführbare Datei und iOS-Mindestversion im gebauten Paket.

Die Website-Struktur wurde am 29.10.2026 an Startseite, Katalog und „One Piece“-Staffelseite untersucht. Es wird keine dokumentierte AniWorld-API vorausgesetzt. HTML-Änderungen können Anpassungen an `AniParser.swift` erfordern. Netzwerkfehler werden sichtbar angezeigt; es werden keine erfundenen Katalogdaten als Live-Daten angezeigt.

## Datenschutz und Grenzen

Merkliste und Markierungen werden lokal in `UserDefaults` gespeichert. Es gibt keinen eigenen Server und keine eingebaute Analysebibliothek. Abrufe gehen an AniWorld, Bildanbieter und bei Wiedergabe an den gewählten Hoster. Deren eigene Cookies und Verarbeitung bleiben bestehen. Der integrierte Safari-Browser teilt seine Sitzung nicht automatisch mit den nativen Kataloganfragen.

AniLounge ist unabhängig von AniWorld und Netflix. Es werden keine Serien oder Videodateien mitgeliefert. Der Zugriff auf Inhalte und deren Verwendung hängen von den jeweiligen Angeboten und Berechtigungen ab.

## Open Source

Der eigene AniLounge-Quellcode steht unter der MIT-Lizenz, siehe `LICENSE`. Abhängigkeiten behalten ihre jeweiligen Lizenzen. Die Lizenz des Quellcodes umfasst keine externen Anime-Bilder, Beschreibungen oder Videos.

## Verwendete technische Referenzen

- SwiftSoup: https://github.com/scinfu/SwiftSoup/tree/2.8.8 (MIT; als Paketabhängigkeit eingebunden)
- XcodeGen: https://github.com/yonaskolb/XcodeGen
- GitHub Runner: https://github.com/actions/runner-images
- TrollStore: https://github.com/opa334/TrollStore
- Apple SafariServices: https://developer.apple.com/documentation/safariservices/sfsafariviewcontroller
