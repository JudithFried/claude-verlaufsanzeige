#!/usr/bin/env python3
"""Session-Ampel: Hook-Skript.

Wird von Claude Code bei Session-Ereignissen aufgerufen (JSON auf stdin)
und pflegt pro Session eine Zustandsdatei, die die Anzeige-App liest.

Eiserne Regel: darf NIE mit Exit-Code != 0 enden und nie etwas auf
stdout/stderr schreiben, das die Session stört. Fehler landen im Log.
"""
import fcntl
import json
import os
import re
import subprocess
import sys
import time

EVENT_STATE = {
    "SessionStart": "bereit",
    "UserPromptSubmit": "arbeitet",
    "PreToolUse": "arbeitet",
    "Notification": "freigabe",
    "Stop": "fertig",
}


def state_dir():
    return os.environ.get("SESSION_AMPEL_DIR") or os.path.expanduser(
        "~/.claude/session-ampel/state"
    )


def log_file():
    return os.environ.get("AMPEL_LOG") or os.path.expanduser(
        "~/.claude/session-ampel/hook-fehler.log"
    )


def claude_pid():
    """PID des Claude-Prozesses finden: vom eigenen Elternprozess aufwärts,
    bis ein Prozessname nach Claude aussieht. Fallback: direkter Elternprozess."""
    override = os.environ.get("AMPEL_PID")
    if override:
        return int(override)
    pid = os.getppid()
    try:
        cur = pid
        for _ in range(12):
            out = subprocess.run(
                ["ps", "-p", str(cur), "-o", "ppid=,comm="],
                capture_output=True, text=True, timeout=3,
            ).stdout.strip()
            if not out:
                break
            teile = out.split(None, 1)
            ppid = int(teile[0])
            comm = teile[1] if len(teile) > 1 else ""
            if "claude" in comm.lower():
                return cur
            if ppid <= 1:
                break
            cur = ppid
    except Exception:
        pass
    return pid


def tty_von(pid):
    """Terminal-Leitung des Claude-Prozesses (z. B. 'ttys005'), für den Fenstersprung."""
    override = os.environ.get("AMPEL_TTY")
    if override:
        return override
    try:
        out = subprocess.run(
            ["ps", "-p", str(pid), "-o", "tty="],
            capture_output=True, text=True, timeout=3,
        ).stdout.strip()
        return out or "??"
    except Exception:
        return "??"


# ---------------------------------------------------------------------------
# Tokenverbrauch und hypothetischer API-Preis
#
# Claude Code führt pro Session ein Verlaufsprotokoll (JSONL). Jede Antwort
# trägt dort ihre Tokenzahlen und den Modellnamen. Wir lesen bei jedem Ereignis
# nur die neu hinzugekommenen Zeilen (Byte-Marke im Zustandssatz) und schreiben
# die Summen je Modell fort.
# ---------------------------------------------------------------------------

# US-Dollar je 1 Mio Tokens: (Eingabe, Ausgabe), Listenpreise Anthropic
PREISE = {
    "claude-fable-5":    (10.0, 50.0),
    "claude-mythos-5":   (10.0, 50.0),
    "claude-opus-5":     (5.0, 25.0),
    "claude-opus-4-8":   (5.0, 25.0),
    "claude-opus-4-7":   (5.0, 25.0),
    "claude-opus-4-6":   (5.0, 25.0),
    "claude-sonnet-5":   (3.0, 15.0),
    "claude-sonnet-4-6": (3.0, 15.0),
    "claude-haiku-4-5":  (1.0, 5.0),
}
PREIS_FALLBACK = (5.0, 25.0)      # unbekanntes Modell: Opus-Klasse, wird als Schätzung markiert
FAKTOR_CACHE_5M = 1.25            # Cache-Aufbau, 5-Minuten-Ablage
FAKTOR_CACHE_1H = 2.0             # Cache-Aufbau, 1-Stunden-Ablage
FAKTOR_CACHE_LESEN = 0.1          # Treffer aus dem Cache
MAX_SCAN_SEKUNDEN = 2.0           # Zeitdeckel je Aufruf, Rest kommt beim nächsten Ereignis
MAX_GEMERKTE_IDS = 64


def preis_fuer(modell):
    """(Eingabepreis, Ausgabepreis), bekannt? — Zusätze wie [1m] oder Datumsstempel weg."""
    m = (modell or "").split("[")[0]
    m = re.sub(r"-20\d{6}$", "", m)
    if m in PREISE:
        return PREISE[m], True
    for name, p in PREISE.items():
        if m.startswith(name):
            return p, True
    return PREIS_FALLBACK, False


def transcript_pfad(data, rec):
    pfad = data.get("transcript_path") or rec.get("tp")
    if pfad:
        return pfad
    # Nicht mitgeliefert: einmalig im Projektarchiv nach der Session-Datei suchen
    import glob
    treffer = glob.glob(
        os.path.expanduser("~/.claude/projects/*/" + data.get("session_id", "") + ".jsonl"))
    return treffer[0] if treffer else ""


def lies_neue_tokens(rec, pfad):
    """Neue Protokollzeilen einlesen und Tokensummen je Modell fortschreiben."""
    if not pfad or not os.path.exists(pfad):
        return
    groesse = os.path.getsize(pfad)
    marke = rec.get("tp_off") or 0
    if marke > groesse:          # Datei wurde ersetzt oder gekürzt: von vorn zählen
        marke = 0
        rec["modelle"] = {}
        rec["tp_seen"] = []
        rec.pop("aktuell", None)
    if marke == groesse:
        return

    modelle = rec.get("modelle") or {}
    gesehen = list(rec.get("tp_seen") or [])
    aktuell = dict(rec.get("aktuell") or {})
    frist = time.time() + MAX_SCAN_SEKUNDEN

    def verbuche(roh):
        satz = json.loads(roh.decode("utf-8", "replace"))
        nachricht = satz.get("message") or {}
        u = nachricht.get("usage") or {}
        if not u:
            return
        # Modell und Denkstufe der letzten Antwort merken. Nur die Hauptsitzung:
        # Subagenten (isSidechain) fahren oft ein anderes Modell.
        name = nachricht.get("model") or ""
        if name and not name.startswith("<") and not satz.get("isSidechain"):
            aktuell["modell"] = name
            aktuell["effort"] = satz.get("effort") or ""
        # Eine Antwort steht oft in mehreren Protokollzeilen — nur einmal zählen
        kennung = nachricht.get("id") or satz.get("requestId") or ""
        if kennung and kennung in gesehen:
            return
        if kennung:
            gesehen.append(kennung)
            del gesehen[:-MAX_GEMERKTE_IDS]
        cache = u.get("cache_creation") or {}
        if cache:
            cw5 = int(cache.get("ephemeral_5m_input_tokens") or 0)
            cw1h = int(cache.get("ephemeral_1h_input_tokens") or 0)
        else:
            cw5 = int(u.get("cache_creation_input_tokens") or 0)
            cw1h = 0
        # Ablagefrist des Prompt-Caches: nicht raten, sondern aus der Antwort ablesen.
        # Daran haengt der Ablaufbalken der Anzeige.
        if (cw1h or cw5) and not satz.get("isSidechain"):
            aktuell["cache_ttl"] = 3600 if cw1h >= cw5 else 300
        eintrag = modelle.setdefault(
            nachricht.get("model") or "unbekannt",
            {"in": 0, "out": 0, "cw5": 0, "cw1h": 0, "cr": 0})
        eintrag["in"] += int(u.get("input_tokens") or 0)
        eintrag["out"] += int(u.get("output_tokens") or 0)
        eintrag["cw5"] += cw5
        eintrag["cw1h"] += cw1h
        eintrag["cr"] += int(u.get("cache_read_input_tokens") or 0)

    with open(pfad, "rb") as f:
        f.seek(marke)
        for roh in f:
            if not roh.endswith(b"\n"):
                break            # angefangene Zeile: beim nächsten Mal komplett lesen
            marke += len(roh)
            if b'"usage"' in roh:
                try:
                    verbuche(roh)
                except Exception:
                    pass         # kaputte Zeile überspringen, Zählung läuft weiter
            if time.time() > frist:
                break

    rec["tp_off"] = marke
    rec["tp_seen"] = gesehen
    rec["modelle"] = modelle
    if aktuell:
        rec["aktuell"] = aktuell


def rechne_kosten(rec):
    """Summen und Dollarbetrag aus den Modellzahlen ableiten."""
    modelle = rec.get("modelle") or {}
    summe = {"in": 0, "out": 0, "cache_w": 0, "cache_r": 0}
    usd = 0.0
    sicher = True
    for modell, u in modelle.items():
        (p_in, p_out), bekannt = preis_fuer(modell)
        if not bekannt:
            sicher = False
        usd += (u["in"] * p_in
                + u["cw5"] * p_in * FAKTOR_CACHE_5M
                + u["cw1h"] * p_in * FAKTOR_CACHE_1H
                + u["cr"] * p_in * FAKTOR_CACHE_LESEN
                + u["out"] * p_out) / 1_000_000
        summe["in"] += u["in"]
        summe["out"] += u["out"]
        summe["cache_w"] += u["cw5"] + u["cw1h"]
        summe["cache_r"] += u["cr"]
    summe["gesamt"] = summe["in"] + summe["out"] + summe["cache_w"] + summe["cache_r"]
    rec["tokens"] = summe
    rec["kosten_usd"] = round(usd, 4)
    rec["kosten_geschaetzt"] = not sicher


# ---------------------------------------------------------------------------
# Projektbuch: dauerhafte Summen je Projekt und Monat
#
# Wahrheit steht in einer JSON-Datei (mit Dateisperre gegen gleichzeitige
# Sessions), daraus wird die lesbare Markdown-Übersicht gerendert. Jede Session
# trägt nur ihre Differenz seit der letzten Meldung nach.
# ---------------------------------------------------------------------------

def buch_json():
    return os.environ.get("AMPEL_BUCH_JSON") or os.path.expanduser(
        "~/.claude/session-ampel/buch.json")


def buch_md():
    vorgabe = os.environ.get("AMPEL_BUCH")
    if vorgabe:
        return vorgabe
    ziel = os.path.expanduser("~/🤖 Claude/Claude Verlaufsanzeige/Tokenkosten.md")
    if os.path.isdir(os.path.dirname(ziel)):
        return ziel
    return os.path.expanduser("~/.claude/session-ampel/Tokenkosten.md")


def tokens_kurz(n):
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f} Mio".replace(".", ",")
    if n >= 1_000:
        return f"{n // 1000}k"
    return str(n)


def geld_kurz(d):
    return (f"{d:.0f}" if d >= 100 else f"{d:.2f}").replace(".", ",") + " $"


def monate_sichern(p):
    """Altbestand ohne Monatsaufteilung dem laufenden Monat zuschlagen."""
    if p.get("monate"):
        return
    p["monate"] = {}
    if p.get("tokens") or p.get("usd"):
        p["monate"][time.strftime("%Y-%m")] = {
            "tokens": p.get("tokens", 0), "usd": p.get("usd", 0.0)}


def monate_ableiten(buch):
    """Gesamttabelle der Monate ist immer die Summe über alle Projekte."""
    monate = {}
    for p in buch.get("projekte", {}).values():
        for monat, w in (p.get("monate") or {}).items():
            z = monate.setdefault(monat, {"tokens": 0, "usd": 0.0})
            z["tokens"] += w.get("tokens", 0)
            z["usd"] = round(z["usd"] + w.get("usd", 0.0), 4)
    return monate


def buch_markdown(buch):
    projekte = sorted(buch.get("projekte", {}).values(),
                      key=lambda p: -p.get("usd", 0))
    zeilen = [
        "# Tokenkosten",
        "",
        "Fortgeschrieben von der Session-Ampel. Die Beträge sind **hypothetisch**:",
        "US-Listenpreise der API für dieselbe Arbeit. Bezahlt wird das Abo.",
        "",
        f"Stand: {time.strftime('%d.%m.%Y %H:%M')}",
        "",
        "## Projekte",
        "",
        "| Projekt | Tokens | Kosten | Sessions | zuletzt |",
        "| --- | ---: | ---: | ---: | --- |",
    ]
    g_tok = g_usd = g_ses = 0
    for p in projekte:
        zeilen.append("| {} | {} | {} | {} | {} |".format(
            p.get("name", "?"), tokens_kurz(p.get("tokens", 0)),
            geld_kurz(p.get("usd", 0)), p.get("sessions", 0), p.get("zuletzt", "")))
        g_tok += p.get("tokens", 0)
        g_usd += p.get("usd", 0)
        g_ses += p.get("sessions", 0)
    zeilen.append("| **Gesamt** | **{}** | **{}** | **{}** | |".format(
        tokens_kurz(g_tok), geld_kurz(g_usd), g_ses))
    zeilen += ["", "## Monate", "", "| Monat | Tokens | Kosten |", "| --- | ---: | ---: |"]
    for monat in sorted(buch.get("monate", {})):
        m = buch["monate"][monat]
        zeilen.append("| {} | {} | {} |".format(
            monat, tokens_kurz(m.get("tokens", 0)), geld_kurz(m.get("usd", 0))))
    zeilen.append("")
    return "\n".join(zeilen)


def schreibe_buch(rec):
    """Differenz dieser Session ins Projektbuch nachtragen."""
    tokens = rec.get("tokens") or {}
    jetzt = {"gesamt": tokens.get("gesamt", 0), "usd": rec.get("kosten_usd", 0.0)}
    vorher = rec.get("gemeldet") or {"gesamt": 0, "usd": 0.0}
    d_tok = jetzt["gesamt"] - vorher.get("gesamt", 0)
    d_usd = jetzt["usd"] - vorher.get("usd", 0.0)
    if d_tok == 0 and abs(d_usd) < 1e-9:
        return
    neu = "gemeldet" not in rec

    pfad = buch_json()
    os.makedirs(os.path.dirname(pfad), exist_ok=True)
    sperre = open(pfad + ".lock", "a+")
    try:
        fcntl.flock(sperre, fcntl.LOCK_EX)
    except Exception:
        sperre.close()
        return               # gesperrt: beim nächsten Stop erneut versuchen
    try:
        try:
            with open(pfad) as f:
                buch = json.load(f)
        except Exception:
            buch = {}
        buch.setdefault("projekte", {})
        buch.setdefault("monate", {})

        schluessel = rec.get("cwd") or rec.get("project") or "?"
        p = buch["projekte"].setdefault(schluessel, {
            "name": rec.get("project") or "?", "tokens": 0, "usd": 0.0, "sessions": 0})
        monate_sichern(p)
        p["name"] = rec.get("project") or p.get("name") or "?"
        p["tokens"] = max(0, p.get("tokens", 0) + d_tok)
        p["usd"] = max(0.0, round(p.get("usd", 0.0) + d_usd, 4))
        p["zuletzt"] = time.strftime("%d.%m.%Y")
        if neu:
            p["sessions"] = p.get("sessions", 0) + 1

        monat = p["monate"].setdefault(time.strftime("%Y-%m"), {"tokens": 0, "usd": 0.0})
        monat["tokens"] = max(0, monat.get("tokens", 0) + d_tok)
        monat["usd"] = max(0.0, round(monat.get("usd", 0.0) + d_usd, 4))
        buch["monate"] = monate_ableiten(buch)

        tmp = pfad + ".tmp"
        with open(tmp, "w") as f:
            json.dump(buch, f, ensure_ascii=False)
        os.replace(tmp, pfad)

        md = buch_md()
        os.makedirs(os.path.dirname(md), exist_ok=True)
        with open(md + ".tmp", "w") as f:
            f.write(buch_markdown(buch))
        os.replace(md + ".tmp", md)
    finally:
        fcntl.flock(sperre, fcntl.LOCK_UN)
        sperre.close()
    rec["gemeldet"] = jetzt


def main():
    data = json.load(sys.stdin)
    event = data.get("hook_event_name", "")
    sid = data.get("session_id", "")
    if not sid:
        return
    d = state_dir()
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, sid + ".json")

    rec = {}
    if os.path.exists(path):
        try:
            with open(path) as f:
                rec = json.load(f)
        except Exception:
            rec = {}

    if event == "SessionEnd":
        # Letzte Abrechnung ins Projektbuch, dann Zustandsdatei entfernen
        try:
            cwd = data.get("cwd") or rec.get("cwd") or ""
            rec["cwd"] = cwd
            rec["project"] = rec.get("project") or (
                os.path.basename(cwd.rstrip("/")) if cwd else "?")
            pfad = transcript_pfad(data, rec)
            if pfad:
                lies_neue_tokens(rec, pfad)
            rechne_kosten(rec)
            schreibe_buch(rec)
        except Exception:
            pass
        try:
            os.remove(path)
        except FileNotFoundError:
            pass
        return

    if event not in EVENT_STATE:
        return

    # PreToolUse feuert bei jedem Werkzeugaufruf. Wir schreiben trotzdem jedes Mal,
    # damit der Tokenzähler mitwächst — gelesen werden nur die neuen Protokollzeilen.

    now = int(time.time())
    # Arbeitsverzeichnis nur beim ersten Ereignis festhalten: wechselt die Sitzung
    # später im Terminal den Ordner, soll sie trotzdem beim selben Projekt bleiben
    cwd = rec.get("cwd") or data.get("cwd") or ""
    project = os.path.basename(cwd.rstrip("/")) if cwd else ""
    pid = rec.get("pid") or claude_pid()
    if not rec.get("tty") or rec.get("tty") == "??":
        rec["tty"] = tty_von(pid)
    # Zeitpunkt der letzten Nutzereingabe: daran erkennt die Anzeige, ob eine
    # von Hand als ruhend markierte Sitzung wieder angefasst wurde
    if event == "UserPromptSubmit":
        rec["prompt_ts"] = now

    rec.update({
        "session_id": sid,
        "project": project or "?",
        "cwd": cwd,
        "state": EVENT_STATE[event],
        "pid": pid,
        "ts": now,
        "started": rec.get("started") or now,
    })

    # Tokenverbrauch fortschreiben — darf die Zustandsmeldung nie verhindern
    try:
        pfad = transcript_pfad(data, rec)
        if pfad:
            rec["tp"] = pfad
            lies_neue_tokens(rec, pfad)
        rechne_kosten(rec)
        # Einmal je Runde ins Projektbuch nachtragen
        if event in ("Stop", "UserPromptSubmit"):
            schreibe_buch(rec)
    except Exception:
        rec.setdefault("tokens", {"in": 0, "out": 0, "cache_w": 0, "cache_r": 0, "gesamt": 0})
        rec.setdefault("kosten_usd", 0.0)

    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(rec, f, ensure_ascii=False)
    os.replace(tmp, path)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        try:
            lf = log_file()
            os.makedirs(os.path.dirname(lf), exist_ok=True)
            with open(lf, "a") as f:
                f.write(f"{time.strftime('%F %T')} {type(e).__name__}: {e}\n")
        except Exception:
            pass
    sys.exit(0)
