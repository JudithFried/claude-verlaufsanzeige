# Projekt: Claude Verlaufsanzeige (Session-Ampel)

## Ziel
Kleine macOS-Anzeige (schmales Always-on-top-Fenster unter der Menüleiste), die alle laufenden Claude-Code-Sessions als farbige Felder zeigt — Farblogik wie beim Codex Micro.

## Landkarte
- code/ampel_hook.py → Hook-Skript, schreibt pro Session eine Zustandsdatei nach ~/.claude/session-ampel/state/
- code/SessionAmpel.swift → Anzeige-App (AppKit, Einzeldatei), liest die Zustandsdateien im Sekundentakt
- code/buch_nachtragen.py → trägt ein Projekt rückwirkend aus allen alten Verlaufsprotokollen ins Buch nach (`python3 buch_nachtragen.py --probe Name`)
- code/tests/ → Testsuite (test_ampel.sh = App und Hook, test_install.sh = Installation)
- code/build/ → kompiliertes Binary (nicht einchecken, wird von swiftc erzeugt)

## Konventionen
- Zustände und Farben: bereit=weiß, arbeitet=blau, freigabe=bernstein, fertig=grün, abgestuerzt=rot
- State-Verzeichnis überschreibbar per Umgebungsvariable SESSION_AMPEL_DIR (für Tests), PID per AMPEL_PID
- Hook-Skript darf NIE mit Exit-Code ≠ 0 enden (würde Claude-Sessions stören); Fehler landen in ~/.claude/session-ampel/hook-fehler.log
- Eingebunden über globale Hooks in ~/.claude/settings.json (SessionStart, UserPromptSubmit, PreToolUse, Notification, Stop, SessionEnd) via Symlink ~/.claude/hooks/session-ampel.py
- Autostart: LaunchAgent ~/Library/LaunchAgents/de.session-ampel.anzeige.plist

## Aktueller Stand
- Stand 2026-08-20: Erstbau abgeschlossen, beide Testsuiten grün, installiert und aktiv (Hooks in settings.json, LaunchAgent für Autostart, App läuft).
- Stand 2026-08-21: Verbrauchszeile ergänzt — jedes Feld zeigt unter dem Projektnamen Tokens gesamt und den hypothetischen API-Listenpreis in US-Dollar (Tilde = Modell unbekannt, Opus-Preis geschätzt). Details im Tooltip. Dazu Summenfeld rechts (ab zwei Sitzungen) und dauerhaftes Projektbuch Tokenkosten.md.
- Stand 2026-08-21: Modell-Chip ergänzt — dritte Zeile im Sessionfeld, farbige Pille mit Modellkürzel (O5, F5, S5, H4.5) und der Denkstufe als Punktreihe (1-5). Quelle: `message.model` und `effort` der letzten Antwort im Verlaufsprotokoll, Subagenten (isSidechain) und `<synthetic>` ausgenommen. Chipfarben je Modellfamilie in `MODELL_FARBEN`, bewusst getrennt von den Zustandsfarben.
- Stand 2026-08-21: Projektblöcke — Sitzungen desselben Ordners stehen untereinander in einer Spalte, Projekte nebeneinander (Abstand 2 px innen, 9 px außen, Blöcke oben bündig). Gruppenschlüssel ist das eingefrorene `cwd`, gleicher Projektname aus einem anderen Ordner bleibt ein eigener Block. Blockreihenfolge nach der ältesten Sitzung des Projekts.
- Stand 2026-08-21: Ruht-Stern — kleiner Stern oben rechts in jeder Kachel, Klick markiert die Sitzung als ruhend (Kachel auf halbe Deckkraft, Zustandsfarbe bleibt). Markierungen stehen in `<state>/ruht.liste` (bewusst ohne .json-Endung, sonst hielte die Anzeige sie für eine Sitzung), umschaltbar per `--ruht <id> [an|aus]`. Sie verfallen automatisch, sobald die Sitzung wieder arbeitet oder verschwindet. Summe und Buch zählen ruhende Sitzungen normal mit.
- Stand 2026-08-21: Cache-Ablaufbalken — wartet eine Sitzung auf eine Eingabe, zeigt die Kachel unten einen dünnen Balken, der die verbleibende Prompt-Cache-Frist abläuft, plus Restzeit als Text neben dem Modell-Chip (`4:07`, ab 10 min `56 min`, danach `kalt`). Die Frist wird nicht geraten, sondern je Sitzung aus `cache_creation` der letzten Antwort gelesen (5 min oder 1 h, Subagenten ausgenommen) und als `cache_ttl` im Zustandssatz geführt. Kein Balken bei `arbeitet`, `abgestuerzt` oder solange die Frist unbekannt ist; 5 min nach Ablauf verschwindet er wieder. Der Sekundentakt zieht nur Balken und Text nach, die Kachel wird dafür nicht neu gebaut. Balkenhöhe und Luft darunter stehen in `CACHE_BALKEN_HOEHE`/`CACHE_BALKEN_LUFT`; der Balken hat einen eigenen Streifen am Kachelfuß.
- Stand 2026-08-27: Limit-Feld — ganz links ein dunkles Feld mit den Plan-Limits des Abos (dieselben Werte wie `/usage`): Sitzungsfenster 5 h, Woche alle Modelle, Woche Fable, je mit Balken, Prozent und Zeitpunkt der Zurücksetzung (heute nur Uhrzeit, sonst mit Wochentag). Farbstufen: weiß, ab 75 % oder Warnung des Kontos bernstein, ab 90 % rot. Quelle ist der Konto-Endpunkt `api.anthropic.com/api/oauth/usage`, Token kommt per `security` aus dem Schlüsselbund-Eintrag „Claude Code-credentials"; Abfrage alle 5 min im Hintergrund (`LIMIT_TAKT`), bei Fehlschlag bleiben die alten Werte stehen, nach 15 min ohne Erfolg steht „(alt)" im Titel. `--dump` fragt nie das Konto, sondern liest nur `AMPEL_LIMITS_DATEI` (Testsuite); `--limits` holt die Werte einmal live zur Diagnose.
- Nächster Schritt: Praxiseindruck abwarten (Position, Farben, Verhalten bei vielen Sessions).

## Tokenzählung und Preis
- Quelle: Verlaufsprotokoll der Session (`transcript_path` aus dem Hook-Ereignis, sonst Suche in ~/.claude/projects). Der Hook liest je Ereignis nur die neu hinzugekommenen Zeilen (Byte-Marke `tp_off` im Zustandssatz) und merkt sich die letzten Antwort-Kennungen gegen Doppelzählung.
- Gezählt wird alles Abrechenbare: Eingabe, Ausgabe, Cache-Aufbau, Cache-Lesen — je Modell getrennt, Subagenten eingeschlossen.
- Preisfaktoren: Cache-Aufbau 5 min = 1,25× Eingabepreis, 1 h = 2×, Cache-Lesen = 0,1×. Preistabelle `PREISE` in ampel_hook.py, unbekannte Modelle fallen auf Opus-Preise zurück und werden als geschätzt markiert.
- Der Betrag ist hypothetisch (Abo statt API) und dient nur dem Größenvergleich.
- Projektbuch: Wahrheit in ~/.claude/session-ampel/buch.json (Dateisperre gegen gleichzeitige Sessions), daraus gerendert die lesbare Tokenkosten.md im Projektordner (git-ignoriert). Jede Session trägt bei Stop, UserPromptSubmit und SessionEnd nur ihre Differenz seit der letzten Meldung nach (`gemeldet` im Zustandssatz).
- Beide Buch-Pfade sind per AMPEL_BUCH und AMPEL_BUCH_JSON überschreibbar — die Testsuite MUSS das gleich im Kopf tun, sonst schreiben Tests ins echte Buch.
- Monatszahlen werden je Projekt geführt, die Monatstabelle ist immer die abgeleitete Summe. Nachtragen ersetzt den Projekteintrag und ist deshalb beliebig wiederholbar.
- Die Projektzuordnung einer Sitzung wird beim ersten Ereignis festgehalten; ein späterer Ordnerwechsel im Terminal verschiebt sie nicht mehr.

## Tabu
- Bestehende Hook-Einträge in ~/.claude/settings.json (Testriegel, Sitzungsprotokoll, Benachrichtigung) nie entfernen oder überschreiben
- Vor jeder Änderung an settings.json datierte Sicherungskopie nach ~/.claude/archiv/
