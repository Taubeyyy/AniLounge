# AniLounge

Persönlicher, inoffizieller AniWorld-Client mit einer dunklen, von Streaming-Apps inspirierten SwiftUI-Oberfläche. Zielgerät: iPhone 13 mit iOS 16.4.1 und bereits eingerichtetem TrollStore. Das Layout unterstützt auch iPad; die Installation dort benötigt einen eigenen kompatiblen Installationsweg.

## Version 0.9.4

- Ladebildschirm verdeckt die Anbieter-Seite, bis der Player übernimmt; mehrere Wiedergabe-Bugs behoben (VOE-Stream, Webplayer-Fallback, Schließen im Querformat, Downloads-Ruckeln).

## Version 0.9.3

- Vollbild füllt im Querformat den ganzen Bildschirm; der Player öffnet zentral und geht beim Drehen nicht mehr verloren.

## Version 0.9.2

- Weiche Bild-Übergänge, dehnbares Detail-Kopfbild, Bestätigungs-Toasts, neue Downloads-Seite, sortierbare Watchlist und letzte Suchen.

## Version 0.9.1

- Video füllt im Querformat den Bildschirm und im Hochformat die volle Breite; kompaktere Steuerung.

## Version 0.9.0

- Eigener Player mit Gesten, Zeitleiste, Geschwindigkeit, Vollbild-Knopf, Bild-in-Bild und Sperrbildschirm-Steuerung.
- Browsing bleibt im Hochformat; behebt den weißen Bildschirm nach dem Drehen.
- VOE startet über die JW-Player-Schnittstelle; Master-Playlists gehen an den iOS-Player.
- Tab „Ich“ mit Statistik, Verlauf und Einstellungen.

## Version 0.8.0

- Aufgeräumte Oberfläche mit eigenen Kopfleisten, Staffel-Pills, Folgenliste mit Bildern und eigenen Bottom-Sheets.
- „Opening überspringen“ und „Nächste Folge“ zur richtigen Zeit dank AniSkip; Staffel-Folgen direkt unter dem Player.
- Autostart ohne extra Tippen bei Playern mit `preload="none"`; Folgen gelten im Abspann als gesehen.

## Version 0.7.0

- Zusatzdaten über die IMDb-ID der AniWorld-Seite: Bewertung, Studio, Status, Trailer und nächster Sendetermin (AniList), Episodenbilder, Laufzeiten und Titel (ani.zip). Ohne Konto oder API-Schlüssel; fällt ein Dienst aus, fehlen nur die Zusätze.
- „Ähnliche Anime“ aus AniList-Empfehlungen, abgeglichen mit dem AniWorld-Katalog.

## Version 0.6.0

- Neues Design im Streaming-Stil mit Hero-Karussell, Poster-Rastern, neuer Detailseite und neuem App-Icon.
- Neuer Player: Bild-in-Bild beim Weiterstöbern, Querformat randlos, „Opening überspringen“ und Countdown zur nächsten Folge auf dem Video.
- Downloads auch über Mobilfunk; Anfragen senden den Referer des Anbieters.

- Downloads pro Profil für MP4/M4V und geeignete HLS-Streams, mit Fortschritt, Abbrechen, Löschen und nativer Offline-Wiedergabe.
- Automatische Ersatzquellen, nächste Folge und optionaler Autoplay-Countdown. Vollbild behält die Wiedergabesitzung.

- Eigene lila Navigationsleiste, Profilkarten, Suchfeld und Quellenkarten für iPhone und iPad.
- Fehlende Cover werden für sichtbare Karten von der Detailseite nachgeladen. Bilder verwenden einen Speicher-/HTTP-Cache und wiederholen vorübergehend fehlgeschlagene Abrufe einmal.
- Native Startseite, Suche, Anime-Details, Staffeln und Episoden.
- Bis zu sechs lokale Profile mit Namen und Symbol. Jedes hat eine eigene Watchlist, einen Verlauf und Wiedergabefortschritt.
- „Weiterschauen“ öffnet die gemerkte Folge; vorhandene 0.1-Merklisten und Markierungen werden ins erste Profil übernommen.
- Native Sprach-/Anbieterauswahl und AVPlayer für erkannte MP4-/HLS-Streams.
- Eingebetteter Webplayer als Alternative; neue Popup-Fenster und externe App-Aufrufe werden blockiert.
- Automatisches Speichern und Fortsetzen im iOS-Player sowie bei unterstützten HTML5-Videos. Manuelle Korrektur über das Menü einer Episode.

**Buildstatus:** Version 0.5.0 wurde mit 38 erfolgreichen Tests geprüft und als Ad-hoc-signierte IPA gebaut. Der aktuelle geprüfte Stand steht in `VALIDATION.json`. Installation und Anbieter-Wiedergabe auf einem echten Gerät sind noch nicht geprüft.

[Aktuelle IPA direkt herunterladen](https://github.com/Taubeyyy/AniLounge/releases/download/v0.9.6/AniLounge.ipa) · [Release 0.9.6](https://github.com/Taubeyyy/AniLounge/releases/tag/v0.9.6)

[Builds und IPA-Artefakte](https://github.com/Taubeyyy/AniLounge/actions)

Unter **Artifacts → AniLounge-TrollStore** herunterladen, ZIP in der Dateien-App entpacken und `AniLounge.ipa` über **Teilen → TrollStore** öffnen. Als Update über die vorhandene App installieren, damit lokale Daten erhalten bleiben. GitHub-Artefakte dieses Workflows werden nach 14 Tagen gelöscht.

## Überarbeitete Kernabläufe

- „Aus Weiterschauen ausblenden“ bewahrt Fortschritt, Verlauf und Gesehen-Markierungen. Ein erneuter bewusster Wiedergabestart blendet den Titel wieder ein.
- Startseite und Detailseite unterscheiden Fortsetzen, nächste ungesehene Folge und „Du bist auf dem neuesten Stand“. Der Player verwendet dieselbe Folgen- und Staffelauflösung.
- Persönliche Startseitenreihen bleiben bei einem Katalogfehler sichtbar. Ein lokaler Katalogcache erlaubt die Fortsetzung bekannter Serien.
- Beim Start wird eine gespeicherte Folge des aktuellen Profils bevorzugt. Eine abweichende oder unbekannte Downloadsprache verlangt eine Bestätigung; passende Downloads brauchen keinen Online-Katalog.
- Die Wiederherstellung laufender Downloads wartet auf alle drei Hintergrundsessions, bevor sie fehlende Aufgaben als fehlgeschlagen markiert.
- Pull Requests werden mit Core-, Webtracker- und iOS-Tests sowie einem IPA-Build geprüft. Das Artefakt heißt `AniLounge-review-IPA`; dieser Prüfworkflow erstellt keinen Release.

## Wiedergabe

Ein Tipp auf eine Folge startet automatisch die pro Profil gemerkte Quelle; ohne Vorgabe werden Deutsch und VOE bevorzugt, sonst ein verfügbarer Anbieter derselben Sprachfassung. Fehlt diese Fassung, wartet die Wiedergabe auf eine bewusste Sprachauswahl – auch beim automatischen Folgenwechsel. Über „Quelle“ änderst du Anbieter und Sprache. Die Auswahl gilt auch für folgende Episoden. Die App versucht unterstützte HTML5-Videos automatisch zu starten, ohne Buttons oder Werbelinks auf Webseiten anzuklicken. Bis der eigene Player das Video übernimmt, verdeckt ein Ladebildschirm die Anbieterseite. Dauert der Start länger als zwölf Sekunden, lässt sich der Webplayer einblenden oder die Quelle wechseln; spielt die Seite das Video schon, ohne dass der eigene Player übernehmen kann, erscheint sie nach wenigen Sekunden von selbst. Der isolierte WebKit-Tracker erkennt laufende HTML5-Videos, direkte MP4-/HLS-URLs und bei Blob-Playern einen eindeutig zuordenbaren, bereits geladenen HLS-Manifestlink. Dann versucht AVPlayer die Wiedergabe und setzt eine gemerkte Position fort. Erst wenn der native Player bereit ist, wird die Webwiedergabe angehalten. Apple-Player-Steuerelemente bieten Vollbild und Bild-in-Bild, soweit das Gerät dies unterstützt.

Abgelaufene oder an Browser-Header gebundene Links, DRM, andere Formate und nicht erkannte Quellen können die native Wiedergabe verhindern. Dann bleibt der Webplayer verfügbar; über „Quelle“ lässt sich wechseln. „Webplayer verwenden“ beendet einen nativen Versuch. Es gibt keine Garantie, dass jeder Hoster funktioniert. Popup-Blocking entfernt keine in die Seite oder ins Video eingebettete Werbung. Kurze Clips unter 90 Sekunden werden vom Webtracker ignoriert, um typische Werbeclips nicht als Folgenfortschritt zu speichern; längere Werbung kann nicht zuverlässig erkannt werden.

Fortschritt wird ungefähr alle fünf Sekunden, bei nativer Wiedergabe auch beim Schließen und beim Wechsel in den Hintergrund gespeichert. Unterstützte Webvideos speichern zusätzlich beim Pausieren. Bei abruptem Beenden können die letzten Sekunden fehlen. Eine Folge gilt erst beim gemeldeten Wiedergabeende oder nach manueller Markierung als gesehen. Ein Abbruch kurz vor dem Ende bleibt fortsetzbar. Abweichende Videolängen werden beim automatischen Fortsetzen geprüft. Manuelle Korrekturen sind im Episodenmenü möglich.

Profile sind lokale Sammlungen, keine passwortgeschützten Onlinekonten. Sie synchronisieren sich nicht zwischen iPhone und iPad. Browser-Cookies werden von den lokalen Profilen gemeinsam genutzt.

## Auf GitHub bauen – ohne eigenen Mac

1. Für dieses Repository direkt bei Schritt 3 beginnen. Für einen eigenen Build kannst du das öffentliche Repository forken oder den Quellcode in ein eigenes Repository übernehmen.
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
node --test scripts/playback-tracker.test.cjs
bash scripts/build-ipa.sh
```

Ergebnis: `build/AniLounge.ipa`. Für die Arbeit im Simulator: `xcodegen generate`, anschließend `AniLounge.xcodeproj` öffnen und das Schema `AniLounge` wählen. Für eine reguläre Installation über Xcode muss eine eigene Signierung konfiguriert werden.

## Aufbau

- `AniLounge/`: SwiftUI-Ansichten, Profilspeicher, WebKit-/AVKit-Player und isoliertes Tracking-Skript.
- `Core/`: Swift-Paket für Datenmodelle, Profilpersistenz, Netzwerkzugriff und HTML-Auswertung.
- `Core/Tests/`: Parser-, Profil-, Migrations- und Wiedergabequellen-Tests mit synthetischen Testdaten.
- `project.yml`: XcodeGen-Konfiguration, Mindestversion iOS 16.4.
- `.github/workflows/build.yml`: macOS-Build, Swift- und JavaScript-Tests, IPA-Artefakt.
- `scripts/validate-ipa.py`: prüft Bundle-ID, ausführbare Datei, PlaybackTracker-Ressource und iOS-Mindestversion im gebauten Paket.

Die Website-Struktur wurde am 29.10.2026 an Startseite, Katalog und „One Piece“-Staffelseite untersucht. Es wird keine dokumentierte AniWorld-API vorausgesetzt. HTML-Änderungen können Anpassungen an `AniParser.swift` erfordern. Netzwerkfehler werden sichtbar angezeigt; es werden keine erfundenen Katalogdaten als Live-Daten angezeigt.

## Datenschutz und Grenzen

Profile, Watchlists und Positionen werden lokal in `UserDefaults` gespeichert. Es gibt keinen eigenen Server und keine eingebaute Analysebibliothek. Abrufe gehen an AniWorld, Bildanbieter und bei Wiedergabe an den gewählten Hoster. Deren eigene Cookies und Verarbeitung bleiben bestehen. WebKit verwendet einen persistenten Browser-Speicher. Für native Videos werden ausschließlich zur Video-URL passende Cookies an AVURLAsset übergeben; sie werden nicht protokolliert. Native Kataloganfragen haben eine eigene Sitzung.

AniLounge ist unabhängig von AniWorld und Netflix. Es werden keine Serien oder Videodateien mitgeliefert. Der Zugriff auf Inhalte und deren Verwendung hängen von den jeweiligen Angeboten und Berechtigungen ab.

## Open Source

Der eigene AniLounge-Quellcode steht unter der MIT-Lizenz, siehe `LICENSE`. Abhängigkeiten behalten ihre jeweiligen Lizenzen. Die Lizenz des Quellcodes umfasst keine externen Anime-Bilder, Beschreibungen oder Videos.

## Verwendete technische Referenzen

- SwiftSoup: https://github.com/scinfu/SwiftSoup/tree/2.8.8 (MIT; als Paketabhängigkeit eingebunden)
- XcodeGen: https://github.com/yonaskolb/XcodeGen
- GitHub Runner: https://github.com/actions/runner-images
- TrollStore: https://github.com/opa334/TrollStore
- Apple AVKit: https://developer.apple.com/documentation/avkit/avplayerviewcontroller
- Apple WebKit: https://developer.apple.com/documentation/webkit/wkwebview
- Apple AVURLAsset-Cookies: https://developer.apple.com/documentation/avfoundation/avurlassethttpcookieskey


## Werbeblocker (0.3.1)

Der Webplayer blockiert standardmäßig zehn bekannte Werbedomains einschließlich ihrer Subdomains über WebKit-Inhaltsregeln. Die kleine mitgelieferte Liste wird mit der App aktualisiert; sie ist keine vollständige EasyList-/uBlock-Liste. Neue oder wechselnde Werbedomains und in den Stream eingebettete Werbung können durchkommen. Die bestehenden Popup-Sperren bleiben zusätzlich aktiv. Der Filter gilt nur im App-Webplayer, nicht systemweit.

Unter **Quelle → Werbeblocker** lässt er sich ausschalten. Im Webplayer lädt **Ohne Blocker neu laden** dieselbe Quelle erneut. Bei einem Filterfehler zeigt die App ausdrücklich an, dass der Blocker nicht geladen wurde. Video-CDNs und Playerbibliotheken werden nicht pauschal gesperrt.

Der Start zeigt nun Verbindungsphasen und vergangene Ladezeit. Bei 0:00 startet AVPlayer ohne zusätzlichen Seek; beim Fortsetzen beträgt die erlaubte Abweichung höchstens eine Sekunde. Eine schnellere Verbindung zum Anbieter oder eine bestimmte Startdauer ist damit nicht garantiert.

## Wiedergabekomfort (0.4.0)

- Bei einem Verbindungs-/Playerfehler oder 35 Sekunden ohne erkannten Start wird eine noch nicht versuchte Quelle derselben Sprache geöffnet. Maximal drei Anbieter pro Versuch; danach bleiben Webplayer, Wiederholen und manuelle Quellenauswahl verfügbar. Eine manuelle Auswahl beginnt einen neuen Versuch. Automatische Ersatzquellen überschreiben die gespeicherte Lieblingsquelle nicht.
- „Nächste Folge“ verwendet die Reihenfolge der Episodenliste und berücksichtigt die nächste vorhandene Staffel. Für Filme erfolgt kein automatischer Staffelwechsel. Bei einem Fehler lässt sich die Ermittlung erneut starten.
- Unter **Quelle → Nächste Folge automatisch** lässt sich ein Zehn-Sekunden-Countdown nach dem tatsächlichen Wiedergabeende aktivieren. Standardmäßig ist er aus. Abbrechen, Zurückspulen, Quellenwechsel und der Wechsel in den Hintergrund stoppen den Countdown.
- Downloads wurden mit Version 0.5.0 ergänzt, siehe unten.

Version 0.3.2 hat außerdem die Wiedergabesitzung vom Sichtbarkeitswechsel getrennt: Vollbild darf den Player nicht leeren. Ein iOS-Simulator-Test prüft Überdecken, Zurückkehren und tatsächliches Entfernen der Playeransicht. Der Test ersetzt keinen echten Anbieter-Test auf iOS 16.4.1.


## Downloads (0.5.0)

Eine Folge im nativen Player starten, dann **Herunterladen · WLAN** wählen. Der Bereich **Downloads** zeigt nur die Folgen des aktiven Profils und bietet Fortschritt, Abbrechen, Löschen und Offline-Wiedergabe. Der native Offline-Player benötigt weder Katalog- noch Quellenabruf und speichert den Wiedergabefortschritt im Profil.

MP4/M4V-Dateien und geeignete HLS-Streams mit `.m3u8`-URL werden unterstützt. Downloads laufen ausschließlich über WLAN mit iOS-Hintergrundsessions. Nach erzwungenem Beenden können sie abbrechen. Ein Download wird erst nach erfolgreichem Abschluss und lokaler Medienprüfung freigegeben; HLS muss zusätzlich `isPlayableOffline` erfüllen. Keine DRM-Unterstützung. Anbieter können Downloads ablehnen oder kurzlebige Links verwenden. Dann die Folge online öffnen, gegebenenfalls die Quelle wechseln und neu herunterladen. Pausieren/Fortsetzen und Qualitätsauswahl sind noch nicht enthalten.

MP4-Dateien liegen in Application Support und sind vom Backup ausgeschlossen. HLS-Pakete bleiben am von iOS zugewiesenen Ort. Die Download-Liste speichert relative lokale Pfade und Profilzuordnung, keine Quell-URLs oder Cookies. Profile und Downloads synchronisieren nicht zwischen Geräten. iOS kann HLS-Pakete bei Speicherknappheit entfernen; fehlende Dateien müssen neu heruntergeladen werden.

Automatisierte Download-Tests verwenden ein selbst erzeugtes zweisekündiges Testvideo: lokale Validierung, Wiederherstellung, Offline-Player ohne Quellenabruf, Abbruch/Löschen mit verspäteten Callbacks, ungültige Dateien und Pfadbegrenzung. Reale Anbieter, WLAN-Wechsel und Hintergrundübertragung auf iOS 16.4 müssen am Gerät geprüft werden.
