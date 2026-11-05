# AniLounge 0.9.7 · Build 18

- „Weiterschauen“ lässt sich ausblenden, ohne Fortschritt, Verlauf oder Gesehen-Markierungen zu verlieren.
- Fehlt die bevorzugte Sprachfassung, wartet die Wiedergabe auf deine Auswahl – auch beim Autoplay. Der automatische Anbieterwechsel bleibt innerhalb derselben Fassung.
- Laufende Downloads werden erst nach Rückmeldung aller Hintergrundsessions wiederhergestellt oder als unterbrochen markiert. Das behebt falsche Abbrüche zwischen den beiden HLS-Sessions.
- Startseite, Detailseite und Player nutzen dieselbe Logik für Fortsetzen, nächste ungesehene Folge, Staffelwechsel und das Ende bekannter Folgen. Eine Folge zählt erst beim tatsächlichen Ende oder nach manueller Markierung als gesehen.
- Persönliche Startseitenreihen bleiben bei Katalogfehlern sichtbar. Passende gespeicherte Folgen starten ohne Online-Katalog; abweichende oder unbekannte Downloadsprachen erfordern eine Bestätigung.

Geprüft im Release-Workflow: 48 Core-Tests, 12 Webtracker-Tests, 12 iOS-Simulatortests, WebKit-Regelkompilierung, iOS-Build und IPA-Paketprüfung.

Installation: `AniLounge.ipa` herunterladen und mit TrollStore als Update über die vorhandene App installieren. Lokale Profile und Downloads werden weiterverwendet.

Noch auf einem echten Gerät zu prüfen: Anbieterwiedergabe, HLS-Transfers und Wiederherstellung nach App-Neustart, Flugmodus, Bild-in-Bild und TrollStore-Update. Die Simulatorprüfungen ersetzen diese Gerätetests nicht.
