#!/bin/bash
# Testsuite Session-Ampel — Teil A: Hook-Skript + Anzeige-App
# Läuft komplett gegen ein temporäres State-Verzeichnis, fasst nichts Echtes an.
set -u

CODE="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$CODE/ampel_hook.py"
SRC="$CODE/SessionAmpel.swift"
BIN="$CODE/build/SessionAmpel"
TMP="$(mktemp -d)"
export SESSION_AMPEL_DIR="$TMP/state"
export AMPEL_LOG="$TMP/hook-fehler.log"
export AMPEL_BUCH="$TMP/Tokenkosten.md"          # niemals ins echte Projektbuch schreiben
export AMPEL_BUCH_JSON="$TMP/buch.json"
FEHLER=0

rot()   { echo "ROT   $1"; FEHLER=$((FEHLER+1)); }
gruen() { echo "gruen $1"; }

# Lebender und toter Prozess für PID-Tests
sleep 300 & ALIVE_PID=$!
disown
trap 'kill $ALIVE_PID 2>/dev/null; rm -rf "$TMP"' EXIT
DEAD_PID=99999
while kill -0 $DEAD_PID 2>/dev/null; do DEAD_PID=$((DEAD_PID-7)); done

hook_event() { # $1=event $2=session_id $3=cwd
  printf '{"hook_event_name":"%s","session_id":"%s","cwd":"%s","transcript_path":"/tmp/x.jsonl"}' "$1" "$2" "$3" \
    | AMPEL_PID=$ALIVE_PID python3 "$HOOK"
}

statefile() { echo "$SESSION_AMPEL_DIR/$1.json"; }
feld() { python3 -c "import json,sys;print(json.load(open('$(statefile "$1")'))['$2'])"; }

# ---------- T1: SessionStart legt Zustandsdatei an (bereit, Projektname aus Emoji-Pfad) ----------
hook_event SessionStart s1 "/Users/beispiel/Projekte/Alpha" || rot "T1 Hook-Exitcode"
if [ -f "$(statefile s1)" ] \
   && [ "$(feld s1 state)" = "bereit" ] \
   && [ "$(feld s1 project)" = "Alpha" ] \
   && [ "$(feld s1 pid)" = "$ALIVE_PID" ] \
   && [ -n "$(feld s1 started)" ]; then
  gruen "T1 SessionStart → bereit, Projektname trotz Emoji-Pfad korrekt"
else rot "T1 SessionStart-Zustandsdatei falsch oder fehlt"; fi

# ---------- T2: UserPromptSubmit → arbeitet, started bleibt erhalten ----------
START_VORHER="$(feld s1 started)"
hook_event UserPromptSubmit s1 "/Users/beispiel/Projekte/Alpha"
if [ "$(feld s1 state)" = "arbeitet" ] && [ "$(feld s1 started)" = "$START_VORHER" ]; then
  gruen "T2 UserPromptSubmit → arbeitet, Startzeit erhalten"
else rot "T2 UserPromptSubmit"; fi

# ---------- T3: Notification → freigabe, PreToolUse → arbeitet, Stop → fertig ----------
hook_event Notification s1 "/Users/beispiel/Projekte/Alpha"
Z1="$(feld s1 state)"
hook_event PreToolUse s1 "/Users/beispiel/Projekte/Alpha"
Z2="$(feld s1 state)"
hook_event Stop s1 "/Users/beispiel/Projekte/Alpha"
Z3="$(feld s1 state)"
if [ "$Z1" = "freigabe" ] && [ "$Z2" = "arbeitet" ] && [ "$Z3" = "fertig" ]; then
  gruen "T3 Notification/PreToolUse/Stop → freigabe/arbeitet/fertig"
else rot "T3 Zustandsfolge falsch: $Z1/$Z2/$Z3"; fi

# ---------- T4: SessionEnd entfernt die Datei ----------
hook_event SessionEnd s1 "/Users/beispiel/Projekte/Alpha"
if [ ! -f "$(statefile s1)" ]; then gruen "T4 SessionEnd räumt auf"; else rot "T4 Datei bleibt liegen"; fi

# ---------- T5: Kaputte Eingabe → Exit 0, kein Absturz, Fehler geloggt, keine Datei ----------
echo 'kein json {{{' | python3 "$HOOK"
RC=$?
if [ $RC -eq 0 ] && [ -s "$AMPEL_LOG" ] && [ -z "$(ls -A "$SESSION_AMPEL_DIR" 2>/dev/null)" ]; then
  gruen "T5 kaputte Eingabe: Exit 0, geloggt, kein Müll"
else rot "T5 stiller Fehler nicht sauber behandelt (rc=$RC)"; fi

# ---------- T6: Fehlendes cwd → Fallback, Exit 0 ----------
printf '{"hook_event_name":"SessionStart","session_id":"s6"}' | AMPEL_PID=$ALIVE_PID python3 "$HOOK"
if [ $? -eq 0 ] && [ "$(feld s6 project)" = "?" ]; then
  gruen "T6 fehlendes cwd → Fallback ?"
else rot "T6 Fallback"; fi
rm -f "$(statefile s6)"

# ---------- T7: Swift-Build ----------
if swiftc -O -o "$BIN" "$SRC" 2>"$TMP/buildlog"; then
  gruen "T7 swiftc-Build fehlerfrei"
else rot "T7 Build scheitert: $(head -3 "$TMP/buildlog")"; fi

# ---------- Fixtures für App-Logik ----------
mkdir -p "$SESSION_AMPEL_DIR"
NOW=$(date +%s)
ALT=$((NOW - 90000))  # 25 h alt
mkfix() { # id project state pid ts
  printf '{"session_id":"%s","project":"%s","cwd":"/x/%s","state":"%s","pid":%s,"ts":%s,"started":%s}' \
    "$1" "$2" "$2" "$3" "$4" "$5" "$5" > "$SESSION_AMPEL_DIR/$1.json"
}
mkfix a Alpha arbeitet  $ALIVE_PID $NOW          # lebendig, blau
mkfix b Alpha fertig    $ALIVE_PID $((NOW-60))   # lebendig, grün, Dublette Name
mkfix c richie     arbeitet  $DEAD_PID  $NOW          # tot + arbeitet → abgestürzt
mkfix d Steuer     fertig    $DEAD_PID  $NOW          # tot + fertig → raus
mkfix e Beta     bereit    $ALIVE_PID $ALT          # uralt → raus

DUMP="$("$BIN" --dump 2>/dev/null)"
dq() { echo "$DUMP" | python3 -c "import json,sys; d=json.load(sys.stdin); $1"; }

# ---------- T8: Zustandslogik (tot/alt/lebendig) ----------
if dq "
s={x['sessionId']:x for x in d['sessions']}
assert s['a']['state']=='arbeitet', 'a'
assert s['b']['state']=='fertig', 'b'
assert s['c']['state']=='abgestuerzt', 'c tot+arbeitet muss rot sein'
assert 'd' not in s, 'd tot+fertig muss verschwinden'
assert 'e' not in s, 'e veraltet muss verschwinden'
print('ok')" >/dev/null 2>"$TMP/t8"; then
  gruen "T8 tote und veraltete Sitzungen korrekt behandelt"
else rot "T8 Zustandslogik: $(cat "$TMP/t8" | tail -1)"; fi
[ ! -f "$SESSION_AMPEL_DIR/d.json" ] && [ ! -f "$SESSION_AMPEL_DIR/e.json" ] \
  && gruen "T8b Leichen-Dateien werden gelöscht" || rot "T8b Leichen bleiben liegen"

# ---------- T9: Namens-Dubletten werden nummeriert ----------
if dq "
labels=sorted(x['label'] for x in d['sessions'] if x['sessionId'] in ('a','b'))
assert labels==['Alpha','Alpha 2'], labels
print('ok')" >/dev/null 2>"$TMP/t9"; then
  gruen "T9 Dubletten nummeriert (Alpha / Alpha 2)"
else rot "T9 Dubletten: $(tail -1 "$TMP/t9")"; fi

# ---------- T10: Kontrast Text auf Feld ≥ 3.0 für JEDEN Zustand (kein Weiß-auf-Weiß) ----------
if dq "
def lum(h):
    h=h.lstrip('#'); r,g,b=(int(h[i:i+2],16)/255 for i in (0,2,4))
    f=lambda c: c/12.92 if c<=0.03928 else ((c+0.055)/1.055)**2.4
    r,g,b=f(r),f(g),f(b)
    return 0.2126*r+0.7152*g+0.0722*b
farben=d['farben']
assert set(farben)=={'bereit','arbeitet','freigabe','fertig','abgestuerzt'}, farben.keys()
farben=dict(farben); farben['summenfeld']=d['summeFarben']
for zustand,c in farben.items():
    l1,l2=sorted([lum(c['bg']),lum(c['fg'])],reverse=True)
    ratio=(l1+0.05)/(l2+0.05)
    assert ratio>=3.0, f'{zustand}: Kontrast {ratio:.2f} zu niedrig ({c})'
print('ok')" >/dev/null 2>"$TMP/t10"; then
  gruen "T10 Kontrast aller Zustände und des Summenfelds ≥ 3.0"
else rot "T10 Kontrast: $(tail -1 "$TMP/t10")"; fi

# ---------- T11: Fensterkonfiguration ----------
if dq "
w=d['window']
assert w['alwaysOnTop'] is True
assert w['activationPolicy']=='accessory'
assert w['level'] in ('statusBar','floating')
assert d['stateDir'].endswith('state')
print('ok')" >/dev/null 2>"$TMP/t11"; then
  gruen "T11 Fenster: always-on-top, ohne Dock-Icon"
else rot "T11 Fensterkonfig: $(tail -1 "$TMP/t11")"; fi

# ---------- T12: Ende-zu-Ende Hook → App ----------
rm -f "$SESSION_AMPEL_DIR"/*.json
hook_event SessionStart  e2e "/Users/beispiel/Projekte/Ünsere Äpp 🤖"
hook_event UserPromptSubmit e2e "/Users/beispiel/Projekte/Ünsere Äpp 🤖"
DUMP="$("$BIN" --dump 2>/dev/null)"
if dq "
s=[x for x in d['sessions'] if x['sessionId']=='e2e'][0]
assert s['state']=='arbeitet'
assert s['label']=='Ünsere Äpp 🤖', s['label']
print('ok')" >/dev/null 2>"$TMP/t12"; then
  gruen "T12 Ende-zu-Ende: Hook-Ereignis erscheint blau in der App, Umlaute+Emoji heil"
else rot "T12 Ende-zu-Ende: $(tail -1 "$TMP/t12")"; fi

# ---------- T13: Hook speichert die Terminal-Leitung (tty) ----------
printf '{"hook_event_name":"SessionStart","session_id":"s13","cwd":"/x/Alpha"}' \
  | AMPEL_PID=$ALIVE_PID AMPEL_TTY=ttys099 python3 "$HOOK"
if [ "$(feld s13 tty)" = "ttys099" ]; then
  gruen "T13 tty wird gespeichert"
else rot "T13 tty fehlt oder falsch: '$(feld s13 tty)'"; fi

# ---------- T14: --dump liefert tty mit ----------
DUMP="$("$BIN" --dump 2>/dev/null)"
if dq "
s=[x for x in d['sessions'] if x['sessionId']=='s13'][0]
assert s['tty']=='ttys099', s
print('ok')" >/dev/null 2>"$TMP/t14"; then
  gruen "T14 --dump enthält tty"
else rot "T14 tty im Dump: $(tail -1 "$TMP/t14")"; fi

# ---------- T15: --focus Trockenlauf (mit tty → Terminal-Sprung, ohne tty → App-Fallback) ----------
mkfix f15 AltOhneTty bereit $ALIVE_PID $NOW
F1="$(AMPEL_OSA_DRY=1 "$BIN" --focus s13 2>/dev/null)"
RC1=$?
F2="$(AMPEL_OSA_DRY=1 "$BIN" --focus f15 2>/dev/null)"
RC2=$?
F3="$(AMPEL_OSA_DRY=1 "$BIN" --focus gibtsnicht 2>/dev/null)"
RC3=$?
if [ $RC1 -eq 0 ] && [ $RC2 -eq 0 ] && [ $RC3 -eq 0 ] \
   && echo "$F1" | grep -q '"methode": *"terminal"' \
   && echo "$F1" | grep -q 'ttys099' \
   && echo "$F2" | grep -q '"methode": *"app"' \
   && echo "$F3" | grep -q '"methode": *"keine"'; then
  gruen "T15 --focus: Terminal-Sprung, App-Fallback und Fehlfall sauber"
else rot "T15 --focus: rc=$RC1/$RC2/$RC3 F1=$F1 F2=$F2 F3=$F3"; fi

# ---------- T16: fehlende Leitung wird beim Klick live aus der PID ermittelt ----------
TTYPID=$(ps -axo pid=,tty=,comm= | awk '$2 ~ /^ttys/ && $3 !~ /ps$/ {print $1; exit}')
if [ -z "$TTYPID" ]; then
  gruen "T16 übersprungen (kein Prozess mit Terminal-Leitung gefunden)"
else
  ERWARTET=$(ps -p "$TTYPID" -o tty= | tr -d ' ')
  mkfix f16 LiveTty bereit "$TTYPID" $NOW
  F4="$(AMPEL_OSA_DRY=1 "$BIN" --focus f16 2>/dev/null)"
  if echo "$F4" | grep -q '"methode": *"terminal"' && echo "$F4" | grep -q "$ERWARTET"; then
    gruen "T16 Leitung wird live nachermittelt ($ERWARTET)"
  else rot "T16 Live-Ermittlung: $F4 (erwartet $ERWARTET)"; fi
fi

# ---------- T17: Tokenzählung und API-Preis aus dem Verlaufsprotokoll ----------
# Zeile 1+2 sind dieselbe Antwort (gleiche message.id) und dürfen nur einmal zählen.
# fable-5: 100 Eingabe, 200 Ausgabe, 1000 Cache-Aufbau 1h, 5000 Cache-Lesen
#   = (100*10 + 1000*10*2 + 5000*10*0,1 + 200*50) / 1 Mio = 0,036 $
# sonnet-5: 1000 Eingabe, 100 Ausgabe, 2000 Cache-Aufbau 5m
#   = (1000*3 + 2000*3*1,25 + 100*15) / 1 Mio = 0,012 $  → zusammen 0,048 $
TRANS="$TMP/verlauf.jsonl"
cat > "$TRANS" <<'JSONL'
{"type":"user","message":{"role":"user","content":"hallo"}}
{"type":"assistant","requestId":"r1","message":{"id":"msg_1","model":"claude-fable-5","usage":{"input_tokens":100,"output_tokens":200,"cache_read_input_tokens":5000,"cache_creation":{"ephemeral_1h_input_tokens":1000,"ephemeral_5m_input_tokens":0}}}}
{"type":"assistant","requestId":"r1","message":{"id":"msg_1","model":"claude-fable-5","usage":{"input_tokens":100,"output_tokens":200,"cache_read_input_tokens":5000,"cache_creation":{"ephemeral_1h_input_tokens":1000,"ephemeral_5m_input_tokens":0}}}}
{"type":"assistant","requestId":"r2","message":{"id":"msg_2","model":"claude-sonnet-5","usage":{"input_tokens":1000,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":2000}}}}
JSONL

hook_verlauf() { # $1=event $2=session_id $3=transcript
  printf '{"hook_event_name":"%s","session_id":"%s","cwd":"/x/Kosten","transcript_path":"%s"}' "$1" "$2" "$3" \
    | AMPEL_PID=$ALIVE_PID python3 "$HOOK"
}

hook_verlauf SessionStart t17 "$TRANS"
if python3 -c "
import json,sys
d=json.load(open('$(statefile t17)'))
t=d['tokens']
assert t['in']==1100, t
assert t['out']==300, t
assert t['cache_w']==3000, t
assert t['cache_r']==5000, t
assert t['gesamt']==9400, t
assert abs(d['kosten_usd']-0.048)<1e-9, d['kosten_usd']
assert d['kosten_geschaetzt'] is False
" 2>"$TMP/t17"; then
  gruen "T17 Tokens summiert, Doppelzeile ignoriert, Preis exakt (0,048 \$)"
else rot "T17 Tokenrechnung: $(tail -1 "$TMP/t17")"; fi

# ---------- T18: nur neue Zeilen werden nachgezählt (inkrementell) ----------
OFF_VORHER=$(python3 -c "import json;print(json.load(open('$(statefile t17)'))['tp_off'])")
cat >> "$TRANS" <<'JSONL'
{"type":"assistant","requestId":"r3","message":{"id":"msg_3","model":"claude-fable-5","usage":{"input_tokens":0,"output_tokens":1000,"cache_read_input_tokens":0,"cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0}}}}
JSONL
hook_verlauf Stop t17 "$TRANS"
if python3 -c "
import json
d=json.load(open('$(statefile t17)'))
assert d['tokens']['gesamt']==10400, d['tokens']
assert abs(d['kosten_usd']-0.098)<1e-9, d['kosten_usd']
assert d['tp_off']>$OFF_VORHER
" 2>"$TMP/t18"; then
  gruen "T18 zweiter Durchlauf zählt nur die neue Antwort dazu"
else rot "T18 inkrementelle Zählung: $(tail -1 "$TMP/t18")"; fi

# ---------- T19: unbekanntes Modell wird als Schätzung markiert ----------
TRANS2="$TMP/verlauf2.jsonl"
cat > "$TRANS2" <<'JSONL'
kaputte zeile ohne json {{{
{"type":"assistant","requestId":"r9","message":{"id":"msg_9","model":"claude-nochnicht-9","usage":{"input_tokens":1000,"output_tokens":1000,"cache_read_input_tokens":0}}}
JSONL
hook_verlauf SessionStart t19 "$TRANS2"
if python3 -c "
import json
d=json.load(open('$(statefile t19)'))
assert d['kosten_geschaetzt'] is True, d
assert abs(d['kosten_usd']-0.030)<1e-9, d['kosten_usd']   # Opus-Klasse: 1000*5 + 1000*25
assert d['tokens']['gesamt']==2000, d['tokens']
" 2>"$TMP/t19"; then
  gruen "T19 unbekanntes Modell → Opus-Schätzung markiert, kaputte Zeile übersprungen"
else rot "T19 Schätzung: $(tail -1 "$TMP/t19")"; fi

# ---------- T20: fehlendes Verlaufsprotokoll stört nichts ----------
hook_verlauf UserPromptSubmit t20 "$TMP/gibtsnicht.jsonl"
RC=$?
if [ $RC -eq 0 ] && [ "$(feld t20 state)" = "arbeitet" ] \
   && [ "$(python3 -c "import json;print(json.load(open('$(statefile t20)'))['kosten_usd'])")" = "0.0" ]; then
  gruen "T20 ohne Verlaufsprotokoll: Zustand normal, Kosten 0"
else rot "T20 fehlendes Protokoll (rc=$RC)"; fi

# ---------- T21: Anzeige reicht Verbrauch und Preis durch ----------
DUMP="$("$BIN" --dump 2>/dev/null)"
if dq "
s={x['sessionId']:x for x in d['sessions']}
a=s['t17']
assert a['tokens']==10400, a
assert abs(a['kostenUSD']-0.098)<1e-9, a
assert a['verbrauchsZeile']=='10k · 0,10 \$', a['verbrauchsZeile']
assert '· ~' in s['t19']['verbrauchsZeile'], s['t19']   # Tilde vor dem Preis = geschätzt
print('ok')" >/dev/null 2>"$TMP/t21"; then
  gruen "T21 Feldzeile 'Tokens · Preis' korrekt formatiert (~ = geschätzt)"
else rot "T21 Verbrauchszeile: $(tail -1 "$TMP/t21")"; fi

# ---------- T22: Projektbuch schreibt Summen je Projekt und Monat fort ----------
rm -f "$AMPEL_BUCH" "$AMPEL_BUCH_JSON"          # frisches Buch, unabhängig von T17-T21
hook_verlauf UserPromptSubmit t22 "$TRANS"      # Projekt "Kosten", 10400 Tokens, 0,098 $
hook_verlauf Stop t22 "$TRANS"                  # nichts Neues → darf nicht doppelt zählen
printf '{"hook_event_name":"UserPromptSubmit","session_id":"t22b","cwd":"/x/Zweitprojekt","transcript_path":"%s"}' "$TRANS2" \
  | AMPEL_PID=$ALIVE_PID python3 "$HOOK"
if python3 -c "
import json
b=json.load(open('$AMPEL_BUCH_JSON'))
p=b['projekte']
assert p['/x/Kosten']['tokens']==10400, p
assert abs(p['/x/Kosten']['usd']-0.098)<1e-9, p
assert p['/x/Kosten']['sessions']==1, p
assert p['/x/Zweitprojekt']['tokens']==2000, p
m=list(b['monate'].values())[0]
assert m['tokens']==12400, m
assert abs(m['usd']-0.128)<1e-9, m
" 2>"$TMP/t22"; then
  gruen "T22 Projektbuch: Summen je Projekt und Monat, keine Doppelzählung"
else rot "T22 Projektbuch: $(tail -1 "$TMP/t22")"; fi

# ---------- T23: Markdown-Übersicht lesbar und vollständig ----------
if [ -f "$AMPEL_BUCH" ] \
   && grep -q "^| Kosten | 10k | 0,10 \$ | 1 |" "$AMPEL_BUCH" \
   && grep -q "^| \*\*Gesamt\*\* | \*\*12k\*\* | \*\*0,13 \$\*\*" "$AMPEL_BUCH" \
   && grep -q "^## Monate" "$AMPEL_BUCH" \
   && grep -qi "hypothetisch" "$AMPEL_BUCH"; then
  gruen "T23 Tokenkosten.md: Projekttabelle, Gesamtzeile, Monate, Hinweis auf Hypothese"
else rot "T23 Markdown-Übersicht: $(head -20 "$AMPEL_BUCH" 2>&1 | tail -8)"; fi

# ---------- T24: SessionEnd bucht den Rest und räumt trotzdem auf ----------
cat >> "$TRANS" <<'JSONL'
{"type":"assistant","requestId":"r4","message":{"id":"msg_4","model":"claude-fable-5","usage":{"input_tokens":0,"output_tokens":2000,"cache_read_input_tokens":0}}}
JSONL
printf '{"hook_event_name":"SessionEnd","session_id":"t22","cwd":"/x/Kosten","transcript_path":"%s"}' "$TRANS" \
  | AMPEL_PID=$ALIVE_PID python3 "$HOOK"
if [ ! -f "$(statefile t22)" ] && python3 -c "
import json
p=json.load(open('$AMPEL_BUCH_JSON'))['projekte']['/x/Kosten']
assert p['tokens']==12400, p          # 2000 Tokens der letzten Antwort dazu
assert abs(p['usd']-0.198)<1e-9, p    # + 2000*50/1 Mio = 0,10 \$
" 2>"$TMP/t24"; then
  gruen "T24 SessionEnd bucht die letzte Antwort nach und räumt die Zustandsdatei weg"
else rot "T24 SessionEnd: $(tail -1 "$TMP/t24")"; fi

# ---------- T25: Summenfeld über alle Sitzungen ----------
rm -f "$SESSION_AMPEL_DIR"/*.json
mkfix_tok() { # id project pid tokens usd
  printf '{"session_id":"%s","project":"%s","cwd":"/x/%s","state":"arbeitet","pid":%s,"ts":%s,"started":%s,"tokens":{"in":0,"out":0,"cache_w":0,"cache_r":%s,"gesamt":%s},"kosten_usd":%s}' \
    "$1" "$2" "$2" "$3" "$NOW" "$NOW" "$4" "$4" "$5" > "$SESSION_AMPEL_DIR/$1.json"
}
mkfix_tok s1 Eins $ALIVE_PID 1000000 1.50
mkfix_tok s2 Zwei $ALIVE_PID 500000 2.25
DUMP="$("$BIN" --dump 2>/dev/null)"
if dq "
g=d['summe']
assert g['tokens']==1500000, g
assert abs(g['kostenUSD']-3.75)<1e-9, g
assert g['zeile']=='1,5 M · 3,75 \$', g['zeile']
print('ok')" >/dev/null 2>"$TMP/t25"; then
  gruen "T25 Summenfeld addiert alle Sitzungen korrekt"
else rot "T25 Summenfeld: $(tail -1 "$TMP/t25")"; fi

# ---------- T26: Projekt bleibt fest, auch wenn die Sitzung den Ordner wechselt ----------
hook_event SessionStart t26 "/Users/beispiel/Projekte/Alpha"
hook_event PreToolUse   t26 "/Users/beispiel/Projekte/Alpha/code/unterordner"
if [ "$(feld t26 project)" = "Alpha" ]; then
  gruen "T26 Ordnerwechsel im Terminal ändert die Projektzuordnung nicht"
else rot "T26 Projekt gewandert: $(feld t26 project)"; fi

# ---------- T27: Nachtrags-Werkzeug füllt das Buch rückwirkend ----------
export AMPEL_PROJEKTE="$TMP/projekte"
mkdir -p "$AMPEL_PROJEKTE/p1"
cat > "$AMPEL_PROJEKTE/p1/n1.jsonl" <<'JSONL'
{"type":"assistant","cwd":"/x/Nachtrag","timestamp":"2026-07-15T10:00:00.000Z","message":{"id":"msg_a","model":"claude-fable-5","usage":{"input_tokens":0,"output_tokens":1000,"cache_read_input_tokens":0}}}
{"type":"assistant","cwd":"/x/Nachtrag","timestamp":"2026-08-02T10:00:00.000Z","message":{"id":"msg_b","model":"claude-fable-5","usage":{"input_tokens":0,"output_tokens":2000,"cache_read_input_tokens":0}}}
{"type":"assistant","cwd":"/x/Nachtrag","timestamp":"2026-08-02T10:00:01.000Z","message":{"id":"msg_b","model":"claude-fable-5","usage":{"input_tokens":0,"output_tokens":2000,"cache_read_input_tokens":0}}}
JSONL
mkfix n1 Nachtrag bereit $ALIVE_PID $NOW          # laufende Sitzung desselben Protokolls
python3 "$CODE/buch_nachtragen.py" Nachtrag >/dev/null 2>"$TMP/t27a"
python3 "$CODE/buch_nachtragen.py" Nachtrag >/dev/null 2>>"$TMP/t27a"   # zweimal = einmal
if python3 -c "
import json
b=json.load(open('$AMPEL_BUCH_JSON'))
p=b['projekte']['/x/Nachtrag']
assert p['tokens']==3000, p                       # Doppelzeile nur einmal
assert abs(p['usd']-0.15)<1e-9, p                 # 1000 und 2000 Ausgabe-Tokens à 50 \$/Mio
assert p['sessions']==1, p
assert abs(p['monate']['2026-07']['usd']-0.05)<1e-9, p['monate']
assert abs(p['monate']['2026-08']['usd']-0.10)<1e-9, p['monate']
assert p['zuletzt']=='02.08.2026', p
g=json.load(open('$(statefile n1)'))['gemeldet']
assert g['gesamt']==3000 and abs(g['usd']-0.15)<1e-9, g
" 2>>"$TMP/t27a" && grep -q "^| Nachtrag |" "$AMPEL_BUCH"; then
  gruen "T27 Nachtrag: Monate getrennt, wiederholbar ohne Doppelzählung, laufende Sitzung vermerkt"
else rot "T27 Nachtrag: $(tail -2 "$TMP/t27a")"; fi
unset AMPEL_PROJEKTE

# ---------- T28: Hook merkt sich Modell und Denkstufe der Hauptsitzung ----------
# Die mittlere Zeile ist ein Subagent (isSidechain) und darf die Anzeige nicht umstellen.
TRANS3="$TMP/verlauf3.jsonl"
cat > "$TRANS3" <<'JSONL'
{"type":"assistant","requestId":"m1","effort":"high","message":{"id":"msg_m1","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":10}}}
{"type":"assistant","isSidechain":true,"requestId":"m2","effort":"low","message":{"id":"msg_m2","model":"claude-haiku-4-5-20251001","usage":{"input_tokens":10,"output_tokens":10}}}
{"type":"assistant","requestId":"m3","effort":"xhigh","message":{"id":"msg_m3","model":"claude-opus-4-7[1m]","usage":{"input_tokens":10,"output_tokens":10}}}
{"type":"assistant","requestId":"m4","message":{"id":"msg_m4","model":"<synthetic>","usage":{"input_tokens":1,"output_tokens":1}}}
JSONL
hook_verlauf UserPromptSubmit t28 "$TRANS3"
if python3 -c "
import json
a=json.load(open('$(statefile t28)'))['aktuell']
assert a['modell']=='claude-opus-4-7[1m]', a   # Subagent und <synthetic> zaehlen nicht
assert a['effort']=='xhigh', a
" 2>"$TMP/t28"; then
  gruen "T28 Modell und Denkstufe gemerkt, Subagent und Systemzeilen ignoriert"
else rot "T28 Modellmerkung: $(tail -1 "$TMP/t28")"; fi

# ---------- T29: Anzeige macht daraus Kürzel und Punktreihe ----------
mkfix t29 Ohne bereit $ALIVE_PID $NOW            # Sitzung ohne Antwort: kein Chip
DUMP="$("$BIN" --dump 2>/dev/null)"
if dq "
s={x['sessionId']:x for x in d['sessions']}
a=s['t28']
assert a['modell']=='O4.7', a['modell']
assert a['modellFamilie']=='opus', a
assert a['modellLang']=='Opus 4.7 · 1M-Kontext', a['modellLang']
assert a['effortStufe']==4, a
assert a['chip']=='O4.7 ●●●●○', a['chip']
assert s['t29']['chip']=='', s['t29']           # ohne Antwort kein Chip
print('ok')" >/dev/null 2>"$TMP/t29"; then
  gruen "T29 Chip 'O4.7 ●●●●○', leer solange keine Antwort vorliegt"
else rot "T29 Chip-Aufbereitung: $(tail -1 "$TMP/t29")"; fi

# ---------- T30: Kontrast im Modell-Chip ≥ 3.0 (Chip liegt auf allen Feldfarben) ----------
if dq "
def lum(h):
    h=h.lstrip('#'); r,g,b=(int(h[i:i+2],16)/255 for i in (0,2,4))
    f=lambda c: c/12.92 if c<=0.03928 else ((c+0.055)/1.055)**2.4
    r,g,b=f(r),f(g),f(b)
    return 0.2126*r+0.7152*g+0.0722*b
chips=dict(d['modellFarben']); chips['unbekannt']=d['modellFarbeUnbekannt']
assert {'fable','opus','sonnet','haiku'} <= set(chips), chips.keys()
for name,c in chips.items():
    l1,l2=sorted([lum(c['bg']),lum(c['fg'])],reverse=True)
    ratio=(l1+0.05)/(l2+0.05)
    assert ratio>=3.0, f'Chip {name}: Kontrast {ratio:.2f} zu niedrig ({c})'
    # Chipfarbe darf nicht mit einer Zustandsfarbe verwechselbar sein
    for zustand,z in d['farben'].items():
        assert abs(lum(z['bg'])-lum(c['bg']))>0.02 or z['bg']!=c['bg'], f'{name} vs {zustand}'
print('ok')" >/dev/null 2>"$TMP/t30"; then
  gruen "T30 Modell-Chips lesbar (Kontrast ≥ 3.0) und von den Zustandsfarben unterscheidbar"
else rot "T30 Chip-Kontrast: $(tail -1 "$TMP/t30")"; fi

# ---------- T31: Terminals desselben Projekts stehen als Block zusammen ----------
# Reihenfolge der Anlage bewusst verschachtelt; gleicher Projektname in einem
# ANDEREN Ordner (g) muss ein eigener Block bleiben.
rm -f "$SESSION_AMPEL_DIR"/*.json
mkfix_cwd() { # id project cwd started
  printf '{"session_id":"%s","project":"%s","cwd":"%s","state":"bereit","pid":%s,"ts":%s,"started":%s}' \
    "$1" "$2" "$3" "$ALIVE_PID" "$NOW" "$4" > "$SESSION_AMPEL_DIR/$1.json"
}
mkfix_cwd g1 Alpha /x/Alpha $((NOW-500))
mkfix_cwd g2 Beta     /x/Beta     $((NOW-400))
mkfix_cwd g3 Alpha /x/Alpha $((NOW-300))
mkfix_cwd g4 Beta     /x/Beta     $((NOW-200))
mkfix_cwd g5 Alpha /woanders/Alpha $((NOW-100))
DUMP="$("$BIN" --dump 2>/dev/null)"
if dq "
assert d['gruppen']==[['g1','g3'],['g2','g4'],['g5']], d['gruppen']
reihe=[x['sessionId'] for x in d['sessions']]
assert reihe==['g1','g3','g2','g4','g5'], reihe
namen=[x['label'] for x in d['sessions']]
assert namen==['Alpha','Alpha 2','Beta','Beta 2','Alpha 3'], namen
print('ok')" >/dev/null 2>"$TMP/t31"; then
  gruen "T31 Sitzungen eines Projekts bilden einen Block, fremder Ordner bleibt getrennt"
else rot "T31 Gruppierung: $(tail -1 "$TMP/t31")"; fi

# ---------- T32: Innerhalb des Blocks steht das zuerst geöffnete Terminal oben ----------
# Die Kennungen laufen der Startzeit bewusst entgegen: 'aaa' ist das jüngste
# Terminal und darf trotzdem nicht nach oben rutschen.
rm -f "$SESSION_AMPEL_DIR"/*.json
mkfix_cwd aaa Alpha /x/Alpha $((NOW-100))
mkfix_cwd mmm Alpha /x/Alpha $((NOW-500))
mkfix_cwd zzz Alpha /x/Alpha $((NOW-900))
DUMP="$("$BIN" --dump 2>/dev/null)"
if dq "
assert d['gruppen']==[['zzz','mmm','aaa']], d['gruppen']
namen=[x['label'] for x in d['sessions']]
assert namen==['Alpha','Alpha 2','Alpha 3'], namen
print('ok')" >/dev/null 2>"$TMP/t32"; then
  gruen "T32 ältestes Terminal oben, jüngere darunter (Nummerierung folgt der Reihenfolge)"
else rot "T32 Reihenfolge im Block: $(tail -1 "$TMP/t32")"; fi

# ---------- T33: Ruht-Markierung setzen, aufheben, unsichtbar bleiben ----------
rm -f "$SESSION_AMPEL_DIR"/*.json "$SESSION_AMPEL_DIR"/ruht.liste
mkfix r1 Website  fertig $ALIVE_PID $NOW
mkfix r2 Alpha bereit $ALIVE_PID $NOW
[ "$("$BIN" --ruht r1)" = "an" ] && [ "$("$BIN" --ruht r1)" = "aus" ] \
  && gruen "T33a Stern schaltet um (an → aus)" || rot "T33a Umschalten kaputt"
"$BIN" --ruht r1 an >/dev/null
DUMP="$("$BIN" --dump 2>/dev/null)"
if dq "
s={x['sessionId']:x for x in d['sessions']}
assert s['r1']['ruht'] is True, s['r1']
assert s['r2']['ruht'] is False, s['r2']
assert len(d['sessions'])==2, d['sessions']   # die Merkliste darf keine Kachel erzeugen
print('ok')" >/dev/null 2>"$TMP/t33"; then
  gruen "T33b markierte Sitzung meldet 'ruht', Merkliste bleibt unsichtbar"
else rot "T33b Ruht-Markierung: $(tail -1 "$TMP/t33")"; fi

# ---------- T34: Markierung überdauert Zustände, verfällt bei neuer Eingabe ----------
# Wichtigster Fall: eine Sitzung, die auf Freigabe wartet, darf markiert bleiben.
mkfix r1 Website freigabe $ALIVE_PID $NOW
"$BIN" --ruht r1 an >/dev/null
DUMP="$("$BIN" --dump 2>/dev/null)"
if dq "
s={x['sessionId']:x for x in d['sessions']}
assert s['r1']['ruht'] is True, 'Freigabe-Sitzung muss markiert bleiben'
print('ok')" >/dev/null 2>"$TMP/t34"; then
  gruen "T34a Markierung überlebt 'braucht Freigabe' und 'arbeitet'"
else rot "T34a Markierung zu früh verfallen: $(tail -1 "$TMP/t34")"; fi

# Neue Nutzereingabe (prompt_ts nach dem Markieren) hebt sie auf
printf '{"session_id":"r1","project":"Website","cwd":"/x/Website","state":"arbeitet","pid":%s,"ts":%s,"started":%s,"prompt_ts":%s}' \
  "$ALIVE_PID" "$NOW" "$NOW" "$((NOW + 60))" > "$SESSION_AMPEL_DIR/r1.json"
DUMP="$("$BIN" --dump 2>/dev/null)"
if dq "
s={x['sessionId']:x for x in d['sessions']}
assert s['r1']['ruht'] is False, 'nach neuer Eingabe darf sie nicht mehr ruhen'
print('ok')" >/dev/null 2>"$TMP/t34b"; then
  gruen "T34b neue Eingabe in der Sitzung hebt die Markierung auf"
else rot "T34b Verfall: $(tail -1 "$TMP/t34b")"; fi

"$BIN" --ruht r2 an >/dev/null
rm -f "$SESSION_AMPEL_DIR/r2.json"
"$BIN" --dump >/dev/null 2>&1
if [ ! -s "$SESSION_AMPEL_DIR/ruht.liste" ]; then
  gruen "T34c Markierung verschwindet mit der Sitzung (Merkliste wächst nicht)"
else rot "T34c Merkliste bleibt liegen: $(cat "$SESSION_AMPEL_DIR/ruht.liste")"; fi

# ---------- T35: Hook hält den Zeitpunkt der letzten Nutzereingabe fest ----------
hook_event SessionStart t35 "/x/Projekt"
if python3 -c "import json,sys; sys.exit(0 if 'prompt_ts' not in json.load(open('$(statefile t35)')) else 1)"; then
  gruen "T35a ohne Eingabe kein Zeitstempel"
else rot "T35a unerwarteter Zeitstempel"; fi
hook_event UserPromptSubmit t35 "/x/Projekt"
if [ "$(feld t35 prompt_ts)" -gt 0 ] 2>/dev/null; then
  gruen "T35b Nutzereingabe wird mit Zeitstempel vermerkt"
else rot "T35b prompt_ts fehlt: $(feld t35 prompt_ts)"; fi

# ---------- T36: Hook liest die Cache-Frist aus der Antwort (5 min vs. 1 h) ----------
# Die Subagent-Zeile fuehrt bewusst die andere Frist und darf nicht durchschlagen.
TRANS4="$TMP/verlauf4.jsonl"
cat > "$TRANS4" <<'JSONL'
{"type":"assistant","requestId":"c1","message":{"id":"msg_c1","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":10,"cache_creation":{"ephemeral_5m_input_tokens":900,"ephemeral_1h_input_tokens":0}}}}
JSONL
hook_verlauf UserPromptSubmit t36a "$TRANS4"
TRANS5="$TMP/verlauf5.jsonl"
cat > "$TRANS5" <<'JSONL'
{"type":"assistant","requestId":"c2","message":{"id":"msg_c2","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":10,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":700}}}}
{"type":"assistant","isSidechain":true,"requestId":"c3","message":{"id":"msg_c3","model":"claude-haiku-4-5","usage":{"input_tokens":10,"output_tokens":10,"cache_creation":{"ephemeral_5m_input_tokens":500,"ephemeral_1h_input_tokens":0}}}}
JSONL
hook_verlauf UserPromptSubmit t36b "$TRANS5"
if python3 -c "
import json
a=json.load(open('$(statefile t36a)'))['aktuell']
b=json.load(open('$(statefile t36b)'))['aktuell']
assert a['cache_ttl']==300, a
assert b['cache_ttl']==3600, b   # Subagent mit 5-min-Ablage darf nicht umstellen
" 2>"$TMP/t36"; then
  gruen "T36 Cache-Frist je Sitzung erkannt (5 min / 1 h), Subagent ignoriert"
else rot "T36 Cache-Frist: $(tail -1 "$TMP/t36")"; fi

# ---------- T37: Anzeige rechnet die Restzeit und den Balkenanteil ----------
mkcache() { # id state ttl alter_in_sekunden
  printf '{"session_id":"%s","project":"C%s","cwd":"/c/%s","state":"%s","pid":%s,"ts":%s,"started":%s,"aktuell":{"modell":"claude-opus-5","cache_ttl":%s}}' \
    "$1" "$1" "$1" "$2" "$ALIVE_PID" "$((NOW-$4))" "$((NOW-$4))" "$3" \
    > "$SESSION_AMPEL_DIR/$1.json"
}
rm -f "$SESSION_AMPEL_DIR"/*.json
mkcache c1 fertig   300  60    # 4:00 uebrig
mkcache c2 freigabe 3600 240   # 56 min uebrig
mkcache c3 arbeitet 300  0     # arbeitet: kein Countdown
mkcache c4 fertig   300  420   # abgelaufen, noch im Nachlauf
mkcache c5 fertig   0    60    # Frist unbekannt: kein Countdown
DUMP="$("$BIN" --dump 2>/dev/null)"
if dq "
s={x['sessionId']:x for x in d['sessions']}
# NOW stammt vom Suite-Start, ein paar Sekunden Versatz sind normal
assert 225 <= s['c1']['cacheRest'] <= 240, s['c1']
assert s['c1']['cacheZeile'].startswith('3:') or s['c1']['cacheZeile']=='4:00', s['c1']
assert abs(s['c1']['cacheAnteil']-0.8)<0.05, s['c1']
assert s['c2']['cacheZeile'] in ('56 min','55 min'), s['c2']
assert s['c3']['cacheZeile']=='', s['c3']          # arbeitet
assert s['c4']['cacheZeile']=='kalt', s['c4']
assert s['c4']['cacheAnteil']==0, s['c4']
assert s['c5']['cacheZeile']=='', s['c5']          # Frist unbekannt
print('ok')" >/dev/null 2>"$TMP/t37"; then
  gruen "T37 Restzeit, Balkenanteil und die Faelle ohne Countdown stimmen"
else rot "T37 Cache-Countdown: $(tail -1 "$TMP/t37")"; fi

# ---------- T38: Plan-Limits aus der Konto-Antwort (Datei statt Netz) ----------
RESET_HEUTE="$(date -u -v+2H +%Y-%m-%dT%H:%M:%S.000000+00:00)"
RESET_WOCHE="$(date -u -v+6d +%Y-%m-%dT%H:%M:%S.000000+00:00)"
cat > "$TMP/limits.json" <<EOF
{"five_hour":{"utilization":3.0},"limits":[
 {"kind":"session","group":"session","percent":3,"severity":"normal","resets_at":"$RESET_HEUTE","scope":null,"is_active":true},
 {"kind":"weekly_all","group":"weekly","percent":80,"severity":"warning","resets_at":"$RESET_WOCHE","scope":null,"is_active":false},
 {"kind":"weekly_scoped","group":"weekly","percent":95,"severity":"normal","resets_at":"$RESET_WOCHE","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}
]}
EOF
DUMP="$(AMPEL_LIMITS_DATEI="$TMP/limits.json" "$BIN" --dump 2>/dev/null)"
if dq "
l={x['art']:x for x in d['limits']}
assert [x['name'] for x in d['limits']]==['5 h','Woche','Fable'], d['limits']
assert l['session']['prozent']==3 and l['weekly_all']['prozent']==80 and l['weekly_scoped']['prozent']==95
assert l['session']['farbe']=='#F2F2F7', l['session']
assert l['weekly_all']['farbe']=='#FF9F0A', l['weekly_all']     # Warnung: bernstein
assert l['weekly_scoped']['farbe']=='#FF453A', l['weekly_scoped'] # ab 90 %: rot
import re
assert re.fullmatch(r'\d\d:\d\d', l['session']['resetText']), l['session']   # heute: nur Uhrzeit
assert re.fullmatch(r'\S+ \d\d:\d\d', l['weekly_all']['resetText']), l['weekly_all']  # spaeter: Wochentag
assert l['weekly_scoped']['lang']=='Woche, Fable'
assert d['limitsFehler']==''
print('ok')" >/dev/null 2>"$TMP/t38"; then
  gruen "T38 Plan-Limits: Namen, Prozent, Farbstufen und Zurücksetzung stimmen"
else rot "T38 Plan-Limits: $(tail -1 "$TMP/t38")"; fi

# ---------- T39: kaputte Limit-Antwort und --dump ohne Datei bleiben harmlos ----------
echo '{"nix":1}' > "$TMP/limits_kaputt.json"
DUMP="$(AMPEL_LIMITS_DATEI="$TMP/limits_kaputt.json" "$BIN" --dump 2>/dev/null)"
K1="$(dq "print(len(d['limits']), bool(d['limitsFehler']))")"
DUMP="$("$BIN" --dump 2>/dev/null)"
K2="$(dq "print(len(d['limits']), d['limitsFehler'])")"
if [ "$K1" = "0 True" ] && [ "$K2" = "0 " ]; then
  gruen "T39 Kaputte Limit-Antwort liefert Fehlertext, --dump fragt nie das Konto"
else rot "T39 Limit-Fehlerfall: '$K1' / '$K2'"; fi

echo
if [ $FEHLER -eq 0 ]; then echo "ALLE TESTS GRUEN"; else echo "$FEHLER TEST(S) ROT"; exit 1; fi
