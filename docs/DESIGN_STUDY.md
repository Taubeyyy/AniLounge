# Design-Studie: Netflix, Disney+ und Crunchyroll für AniLounge

Ziel: AniLounge soll sich wie eine große Streaming-App anfühlen, ohne eine davon zu kopieren. Diese Studie fasst zusammen, was die drei Apps auf dem iPhone (Stand 2025/26) gut machen, und was AniLounge davon übernimmt.

## 1. Was die drei gemeinsam haben

| Muster | Netflix | Disney+ | Crunchyroll | AniLounge bisher |
|---|---|---|---|---|
| Dunkler, ruhiger Grund; Inhalt liefert die Farbe | ja | ja (Blau-Verlauf) | ja (Orange als einziger Akzent) | ja, Lila-Akzent |
| Großer Einstieg oben (Hero) | hohe Karte mit Titel-Logo, Genres, „Abspielen“ + „Meine Liste“ | breites Karussell mit Logo | Karussell mit „Jetzt ansehen“ + „Merken“ | Karussell, aber ohne Genres und ohne Farbe aus dem Bild |
| Umgebungsfarbe aus dem Bild | Hintergrund färbt sich passend zum Hero | Farbverlauf je Titel | dezent | fehlt |
| „Weiterschauen“ ganz oben | ja, mit Fortschrittsbalken | ja | ja | ja |
| Ranking-Reihe | „Top 10“ mit riesigen Ziffern | – | „Beliebt“ | fehlt |
| Reihen-Überschriften | schlicht, fett, ohne Deko | schlicht | schlicht | mit lila Balken (wirkt verspielt) |
| Detailseite: Reiter | Folgen · Ähnliche Titel · Trailer | Folgen · Vorschläge · Extras · Details | Folgen · Ähnliche | alles untereinander |
| Metadaten-Zeile unter dem Titel | Jahr · Altersfreigabe · Staffeln · HD | Jahr · Staffeln · Genres | Untertitel/Synchro-Abzeichen | Jahr · Genres |
| Folgenzeile | Vorschaubild, Titel, Laufzeit, 2–3 Zeilen Beschreibung | ähnlich | Vorschaubild, Titel, Untertitel/Synchro | ohne Beschreibung |
| Player | wenige große Knöpfe, „Nächste Folge“, Folgenliste im Player | ähnlich | „Intro überspringen“, Autoplay-Karte | erledigt (0.8–0.9) |

## 2. Was jede App besonders gut macht

**Netflix**
- Die Startseite ist eine Bühne: eine hohe Hero-Karte, deren Bildfarbe den ganzen oberen Bildschirm einfärbt. Dadurch wirkt jede Rückkehr zur Startseite anders und lebendig.
- „Top 10“ mit übergroßen Ziffern: sofort erkennbar, macht neugierig, braucht keine zusätzlichen Daten.
- Detailseite mit Reitern hält die Seite kurz; „Ähnliche Titel“ verschwindet nicht am Seitenende.
- Konsequente Zurückhaltung: kaum Rahmen, kaum Farbe außerhalb der Bilder, Überschriften ohne Schmuck.

**Disney+**
- Titel-Logos statt Schrift im Hero; Farbverläufe pro Titel.
- Marken-Kacheln als Einstieg (Disney, Pixar, Marvel …). Für Anime entspricht das Genres oder „Simulcast“.
- Reiter „Details“ sammelt Studio, Jahr, Bewertung, Sprachen an einer Stelle statt verstreut.

**Crunchyroll**
- Anime-spezifisch: Untertitel/Synchro-Kennzeichnung überall sichtbar, „Folge X weiterschauen“ als Hauptknopf.
- „Intro überspringen“ und Autoplay-Karte im Player (in AniLounge seit 0.8 mit AniSkip).
- Simulcast-Kalender: wann kommt die nächste Folge. AniLounge zeigt das bisher nur pro Serie.

## 3. Was AniLounge übernimmt (diese Runde)

1. **Umgebungsfarbe:** Die Durchschnittsfarbe des Hero- bzw. Kopfbilds färbt den oberen Bildschirm (Startseite und Detailseite). Berechnet einmal pro Bild, auf ein dunkles, ruhiges Niveau gezogen, damit Text lesbar bleibt.
2. **Top 10 auf AniWorld:** neue Reihe mit großen Ziffern aus der Beliebt-Liste.
3. **Schlichte Überschriften:** lila Balken entfällt; fett, klar, wie bei allen drei Vorbildern.
4. **Hero:** Hauptknopf heißt „Ansehen“ mit Play-Symbol statt „Details“.
5. **Detailseite mit Reitern:** Folgen · Ähnliche · Details. „Details“ sammelt Studio, Status, Bewertung, Genres, Staffeln, Sprachen und nächste Folge.
6. **Metadaten-Zeile** unter dem Titel: Jahr · Anzahl Staffeln · Sprachen (DE, DE-Sub, EN-Sub) im Crunchyroll-Stil.
7. **Folgenzeilen** zeigen zwei Zeilen Beschreibung, wenn vorhanden (Netflix).

## 4. Bewusst (noch) nicht übernommen

- **Autoplay-Trailer im Kopf der Detailseite (Netflix):** Trailer liegen auf YouTube; einbetten wäre unzuverlässig und datenhungrig.
- **Titel-Logos (Disney+):** AniWorld und AniList liefern keine freigestellten Logos.
- **Simulcast-Kalender (Crunchyroll):** braucht eine AniList-Abfrage für alle laufenden Serien; guter nächster Schritt.
- **Genre-Kacheln als Einstieg (Disney+):** AniWorld-Genres müssten erst aus dem Katalog gesammelt werden; ebenfalls ein guter nächster Schritt.

## 5. Gestaltungsregeln für alles Weitere

- Farbe kommt aus den Bildern; Lila nur für Fortschritt, Auswahl und den einen Hauptknopf je Ansicht.
- Ein Hauptknopf pro Ansicht, weiß mit schwarzer Schrift (wie alle drei Vorbilder).
- Überschriften ohne Deko; Abstände statt Linien und Rahmen.
- Karten: Poster 2:3 mit kleinen Ecken, breite Kacheln 16:9; Fortschritt immer als dünner Balken unten im Bild.
- Bewegung sparsam: Einblenden, Gleiten, keine verspielten Effekte; „Bewegung reduzieren“ wird respektiert.
