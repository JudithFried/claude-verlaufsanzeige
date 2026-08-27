#!/bin/bash
# Testsuite Session-Ampel — Teil B: Installation auf diesem Mac
set -u
FEHLER=0
rot()   { echo "ROT   $1"; FEHLER=$((FEHLER+1)); }
gruen() { echo "gruen $1"; }

SETTINGS="$HOME/.claude/settings.json"
CMD="python3 ~/.claude/hooks/session-ampel.py"
BIN="$HOME/🤖 Claude/Claude Verlaufsanzeige/code/build/SessionAmpel"
PLIST="$HOME/Library/LaunchAgents/de.session-ampel.anzeige.plist"

# B1: settings.json gültig, Ampel-Hook in allen sechs Ereignissen, Alt-Hooks unversehrt
if jq -e . "$SETTINGS" >/dev/null 2>&1; then gruen "B1a settings.json ist gültiges JSON"; else rot "B1a settings.json kaputt"; fi
for ev in SessionStart UserPromptSubmit PreToolUse Notification Stop SessionEnd; do
  if jq -e --arg ev "$ev" --arg cmd "$CMD" \
    '.hooks[$ev][]?.hooks[]? | select(.command == $cmd)' "$SETTINGS" >/dev/null 2>&1; then
    gruen "B1b Ampel-Hook in $ev"
  else rot "B1b Ampel-Hook fehlt in $ev"; fi
done
for alt in "osascript" "test-riegel-stop" "sitzungsprotokoll" "block-destructive" "test-riegel-commit" "block-env-edit"; do
  if jq -e --arg a "$alt" '[.hooks[][].hooks[].command] | map(select(contains($a))) | length > 0' "$SETTINGS" >/dev/null 2>&1; then
    gruen "B1c Alt-Hook '$alt' unversehrt"
  else rot "B1c Alt-Hook '$alt' verschwunden!"; fi
done

# B2: Symlink zeigt auf existierendes, ausführbares Skript
if [ -x "$(readlink -f "$HOME/.claude/hooks/session-ampel.py")" ]; then
  gruen "B2 Hook-Symlink löst auf und ist ausführbar"
else rot "B2 Hook-Symlink kaputt"; fi

# B3: LaunchAgent-Plist vorhanden und wohlgeformt
if plutil -lint "$PLIST" >/dev/null 2>&1; then gruen "B3 LaunchAgent-Plist wohlgeformt"; else rot "B3 Plist fehlt/kaputt"; fi

# B4: Binary vorhanden und ausführbar
if [ -x "$BIN" ]; then gruen "B4 App-Binary vorhanden"; else rot "B4 Binary fehlt"; fi

# B5: App läuft
if pgrep -f "build/SessionAmpel" >/dev/null; then gruen "B5 Anzeige-App läuft"; else rot "B5 App läuft nicht"; fi

echo
if [ $FEHLER -eq 0 ]; then echo "INSTALLATION GRUEN"; else echo "$FEHLER PRUEFUNG(EN) ROT"; exit 1; fi
