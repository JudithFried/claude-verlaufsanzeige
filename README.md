# Claude Verlaufsanzeige

Eine kleine macOS-Anzeige für alle laufenden Claude-Code-Sessions: ein schmales,
immer sichtbares Band unter der Menüleiste, ein farbiges Feld pro Session.
Inspiriert von den Status-Leuchttasten des OpenAI Codex Micro, nur als Software,
für Claude Code.

## Farben

| Farbe | Bedeutung |
|---|---|
| Weiß | bereit, wartet auf Eingabe |
| Blau | arbeitet |
| Bernstein | braucht eine Freigabe oder Antwort |
| Grün | Antwort fertig |
| Rot | Sitzung abgestürzt |

## Was eine Kachel zeigt

Jede Session bekommt eine Kachel mit drei Zeilen:

1. **Projektname.** Sessions desselben Ordners stehen untereinander in einer
   Spalte, verschiedene Projekte nebeneinander. Gleicher Projektname aus einem
   anderen Ordner bleibt ein eigener Block.
2. **Verbrauch.** Tokens gesamt und der hypothetische API-Listenpreis in
   US-Dollar. Gezählt wird alles Abrechenbare (Eingabe, Ausgabe, Cache-Aufbau,
   Cache-Lesen), je Modell getrennt, Subagenten eingeschlossen. Eine Tilde heißt:
   Modell unbekannt, mit Opus-Preisen geschätzt. Details im Tooltip.
3. **Modell und Denkstufe.** Farbige Pille mit dem Modellkürzel (O5, F5, S5,
   H4.5) und der Denkstufe als Punktreihe von eins bis fünf. Daneben steht die
   Restzeit des Prompt-Caches.

Dazu auf der Kachel:

- **Ruht-Stern** oben rechts. Ein Klick nimmt eine Session optisch zurück: halbe
  Deckkraft, Zustandsfarbe bleibt. Verbrauch und Buchführung laufen normal
  weiter. Die Markierung verfällt von selbst, sobald die Session wieder arbeitet
  oder verschwindet.
- **Cache-Ablaufbalken** am Fuß. Wartet eine Session auf eine Eingabe, läuft dort
  die verbleibende Prompt-Cache-Frist ab, als Text daneben `4:07`, ab zehn
  Minuten `56 min`, danach `kalt`. Die Frist wird nicht geraten, sondern je
  Session aus der letzten Antwort gelesen (fünf Minuten oder eine Stunde).

Am Rand des Bandes:

- **Limit-Feld** ganz links mit den Nutzungslimits des Abos, dieselben Werte wie
  `/usage`: Sitzungsfenster (5 h), Woche über alle Modelle, Woche Fable. Je mit
  Balken, Prozent und Zeitpunkt der Zurücksetzung. Ab 75 Prozent bernstein, ab
  90 Prozent rot.
- **Summenfeld** rechts, sobald mehr als eine Session läuft.

## Funktionen

- Dauerüberblick über alle Sessions statt einzelner Benachrichtigungen
- **Klick auf ein Feld** holt das zugehörige Terminalfenster samt richtigem Tab
  nach vorn (Apple Terminal und iTerm2)
- Fenster frei verschiebbar, Position wird gemerkt; Tooltip mit Details
- Räumt beendete und abgestürzte Sessions selbst auf
- Dauerhaftes Projektbuch über den Tokenverbrauch, je Projekt und Monat
- Autostart per LaunchAgent, läuft ohne Dock-Symbol

## Wie es funktioniert

Claude-Code-Hooks (`SessionStart`, `UserPromptSubmit`, `PreToolUse`,
`Notification`, `Stop`, `SessionEnd`) rufen `code/ampel_hook.py` auf, das pro
Session eine kleine Zustandsdatei unter `~/.claude/session-ampel/state/` pflegt.
Die Anzeige-App (`code/SessionAmpel.swift`, ein einzelnes AppKit-Programm)
liest diese Dateien im Sekundentakt.

Verbrauch, Modell und Cache-Frist stammen aus dem Verlaufsprotokoll der Session.
Der Hook liest je Ereignis nur die neu hinzugekommenen Zeilen.

Die Plan-Limits holt die App alle fünf Minuten vom Konto-Endpunkt von Anthropic.
Der Zugang dafür wird zur Laufzeit aus dem macOS-Schlüsselbund gelesen
(Eintrag „Claude Code-credentials"), er steht nirgends im Code.

## Bedienung von der Kommandozeile

```bash
SessionAmpel --dump            # Zustand als JSON
SessionAmpel --limits          # Plan-Limits einmal live abfragen
SessionAmpel --ruht <id>       # Ruht-Markierung umschalten
SessionAmpel --focus <id>      # Terminalfenster der Session nach vorn holen
```

## Bauen und Testen

```bash
# Testsuite (baut das Binary mit)
code/tests/test_ampel.sh

# Installations-Prüfung (Hooks, LaunchAgent, laufende App)
code/tests/test_install.sh
```

Voraussetzungen: macOS mit Swift-Toolchain (Xcode Command Line Tools), Python 3.

## Hinweis zu den Kosten

Der angezeigte Betrag ist hypothetisch. Er rechnet den Verbrauch zu
API-Listenpreisen um, obwohl die Nutzung über ein Abo läuft. Er dient dem
Größenvergleich zwischen Sessions und Projekten, nicht der Abrechnung.
