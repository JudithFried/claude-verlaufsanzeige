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

## Installation

Es gibt kein Installationsprogramm. Fünf Schritte von Hand, zehn Minuten.

**Voraussetzungen:** macOS, Claude Code, Python 3 und die Xcode Command Line
Tools für den Swift-Übersetzer (`xcode-select --install`).

### 1. Holen und bauen

```bash
git clone https://github.com/JudithFried/claude-verlaufsanzeige.git
cd claude-verlaufsanzeige
mkdir -p code/build
swiftc -O -o code/build/SessionAmpel code/SessionAmpel.swift
```

Der letzte Befehl braucht einen Moment und sagt nichts, wenn er geklappt hat.

### 2. Gleich ausprobieren

Noch ohne Autostart, einfach starten:

```bash
./code/build/SessionAmpel
```

Unter der Menüleiste erscheint ein schmales Band. Solange keine Claude-Session
läuft, ist es leer, das ist richtig so. Mit `Strg-C` im Terminal wieder beenden.

### 3. Hook verknüpfen

Der Hook ist das Teil, das Claude Code bei jedem Ereignis aufruft und den
Zustand der Session aufschreibt.

```bash
mkdir -p ~/.claude/hooks
ln -s "$PWD/code/ampel_hook.py" ~/.claude/hooks/session-ampel.py
```

### 4. Hooks eintragen

Jetzt muss Claude Code erfahren, dass es den Hook aufrufen soll. Das steht in
`~/.claude/settings.json`.

> **Achtung:** In dieser Datei stehen womöglich schon eigene Hooks. Die neuen
> Einträge kommen **zu den vorhandenen dazu**, sie ersetzen sie nicht. Vorher
> eine Kopie anlegen:
>
> ```bash
> cp ~/.claude/settings.json ~/.claude/settings.json.sicherung
> ```

Der Abschnitt `hooks` sieht danach so aus. Wer schon Hooks hat, fügt die
jeweiligen Einträge in die vorhandenen Listen ein:

```json
{
  "hooks": {
    "SessionStart": [
      { "matcher": "*", "hooks": [{ "type": "command", "command": "python3 ~/.claude/hooks/session-ampel.py" }] }
    ],
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "python3 ~/.claude/hooks/session-ampel.py" }] }
    ],
    "PreToolUse": [
      { "matcher": "*", "hooks": [{ "type": "command", "command": "python3 ~/.claude/hooks/session-ampel.py" }] }
    ],
    "Notification": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "python3 ~/.claude/hooks/session-ampel.py" }] }
    ],
    "Stop": [
      { "matcher": "*", "hooks": [{ "type": "command", "command": "python3 ~/.claude/hooks/session-ampel.py" }] }
    ],
    "SessionEnd": [
      { "matcher": "*", "hooks": [{ "type": "command", "command": "python3 ~/.claude/hooks/session-ampel.py" }] }
    ]
  }
}
```

Die Unterschiede beim `matcher` sind kein Versehen, das ist die Form, in der es
läuft: `UserPromptSubmit` kennt keinen, `Notification` einen leeren.

Danach Claude Code einmal neu starten, sonst greifen die Einträge nicht. Beim
nächsten Start einer Session erscheint ein Feld im Band.

### 5. Autostart einrichten

Damit die Anzeige nach dem Anmelden von selbst läuft. Datei
`~/Library/LaunchAgents/de.session-ampel.anzeige.plist` anlegen, im Pfad den
eigenen Projektordner eintragen:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>de.session-ampel.anzeige</string>
    <key>ProgramArguments</key>
    <array>
        <string>/PFAD/ZUM/PROJEKT/code/build/SessionAmpel</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
</dict>
</plist>
```

Anmelden und alles zusammen prüfen:

```bash
launchctl bootstrap "gui/$UID" ~/Library/LaunchAgents/de.session-ampel.anzeige.plist
code/tests/test_install.sh
```

Die Prüfung meldet am Ende `INSTALLATION GRUEN`, wenn Hook, Verknüpfung,
Autostart und laufende App stimmen.

### Zum Limit-Feld

Das dunkle Feld links zeigt die Nutzungslimits des Abos. Dafür fragt die App den
Konto-Endpunkt von Anthropic ab und liest den Zugang dafür zur Laufzeit aus dem
macOS-Schlüsselbund. Ohne Claude-Code-Abo bleibt das Feld leer, alles andere
funktioniert normal weiter.

### Wieder loswerden

```bash
launchctl bootout "gui/$UID/de.session-ampel.anzeige"
rm ~/Library/LaunchAgents/de.session-ampel.anzeige.plist
rm ~/.claude/hooks/session-ampel.py
rm -rf ~/.claude/session-ampel
```

Dazu die Einträge aus `~/.claude/settings.json` wieder entfernen. Der letzte
Befehl löscht auch das Projektbuch mit den gesammelten Verbrauchszahlen.

## Bauen und Testen

```bash
# Testsuite (baut das Binary mit)
code/tests/test_ampel.sh

# Installations-Prüfung (Hooks, LaunchAgent, laufende App)
code/tests/test_install.sh
```


## Hinweis zu den Kosten

Der angezeigte Betrag ist hypothetisch. Er rechnet den Verbrauch zu
API-Listenpreisen um, obwohl die Nutzung über ein Abo läuft. Er dient dem
Größenvergleich zwischen Sessions und Projekten, nicht der Abrechnung.

## Lizenz

MIT, siehe [LICENSE](LICENSE).
