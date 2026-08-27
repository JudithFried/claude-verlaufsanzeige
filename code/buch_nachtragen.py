#!/usr/bin/env python3
"""Projektbuch rückwirkend füllen.

Liest alle Verlaufsprotokolle eines Projekts aus ~/.claude/projects, rechnet
Tokens und API-Listenpreis zusammen und trägt das Ergebnis ins Projektbuch ein.
Der Eintrag eines Projekts wird dabei ERSETZT, nicht addiert — der Nachtrag ist
also beliebig oft wiederholbar, ohne doppelt zu zählen.

    python3 buch_nachtragen.py Alpha Beta
    python3 buch_nachtragen.py --probe Alpha     # nur rechnen, nichts schreiben

Läuft eine Sitzung des Projekts gerade, wird in ihrer Zustandsdatei vermerkt,
was bereits im Buch steht — damit der Hook danach nur noch den Zuwachs nachträgt.
"""
import fcntl
import glob
import importlib.util
import json
import os
import sys
import time

HIER = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("ampel_hook", os.path.join(HIER, "ampel_hook.py"))
hook = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(hook)


def protokoll_ordner():
    return os.environ.get("AMPEL_PROJEKTE") or os.path.expanduser("~/.claude/projects")


def cwd_von(pfad):
    """Arbeitsverzeichnis aus den ersten Zeilen eines Protokolls."""
    try:
        with open(pfad, "rb") as f:
            for _ in range(50):
                zeile = f.readline()
                if not zeile:
                    break
                try:
                    c = json.loads(zeile).get("cwd")
                except Exception:
                    continue
                if c:
                    return c
    except Exception:
        pass
    return ""


def kosten_einer_antwort(modell, u):
    (p_in, p_out), bekannt = hook.preis_fuer(modell)
    cache = u.get("cache_creation") or {}
    if cache:
        cw5 = int(cache.get("ephemeral_5m_input_tokens") or 0)
        cw1h = int(cache.get("ephemeral_1h_input_tokens") or 0)
    else:
        cw5 = int(u.get("cache_creation_input_tokens") or 0)
        cw1h = 0
    ein = int(u.get("input_tokens") or 0)
    aus = int(u.get("output_tokens") or 0)
    cr = int(u.get("cache_read_input_tokens") or 0)
    usd = (ein * p_in
           + cw5 * p_in * hook.FAKTOR_CACHE_5M
           + cw1h * p_in * hook.FAKTOR_CACHE_1H
           + cr * p_in * hook.FAKTOR_CACHE_LESEN
           + aus * p_out) / 1_000_000
    return ein + aus + cw5 + cw1h + cr, usd, bekannt


def lies_protokoll(pfad):
    """(Tokens, USD, Monatszahlen, letzter Tag, alle Modelle bekannt?) eines Protokolls."""
    gesehen = set()
    tokens = 0
    usd = 0.0
    monate = {}
    zuletzt = ""
    sicher = True
    with open(pfad, "rb") as f:
        for roh in f:
            if b'"usage"' not in roh:
                continue
            try:
                satz = json.loads(roh.decode("utf-8", "replace"))
                nachricht = satz.get("message") or {}
                u = nachricht.get("usage") or {}
                if not u:
                    continue
                kennung = nachricht.get("id") or satz.get("requestId") or ""
                if kennung and kennung in gesehen:
                    continue
                if kennung:
                    gesehen.add(kennung)
                t, d, bekannt = kosten_einer_antwort(nachricht.get("model"), u)
                sicher = sicher and bekannt
                tokens += t
                usd += d
                stempel = satz.get("timestamp") or ""
                monat = stempel[:7] if len(stempel) >= 7 else time.strftime("%Y-%m")
                m = monate.setdefault(monat, {"tokens": 0, "usd": 0.0})
                m["tokens"] += t
                m["usd"] += d
                if stempel > zuletzt:
                    zuletzt = stempel
            except Exception:
                continue
    return tokens, usd, monate, zuletzt, sicher


def sammle(namen):
    """Alle Protokolle den gewünschten Projekten zuordnen und auswerten."""
    projekte = {}
    sitzungen = {}          # session_id -> (cwd, tokens, usd)
    for pfad in sorted(glob.glob(protokoll_ordner() + "/*/*.jsonl")):
        cwd = cwd_von(pfad)
        if not cwd or os.path.basename(cwd.rstrip("/")) not in namen:
            continue
        tokens, usd, monate, zuletzt, sicher = lies_protokoll(pfad)
        if tokens == 0:
            continue
        p = projekte.setdefault(cwd, {
            "name": os.path.basename(cwd.rstrip("/")), "tokens": 0, "usd": 0.0,
            "sessions": 0, "monate": {}, "zuletzt": "", "geschaetzt": False})
        p["tokens"] += tokens
        p["usd"] += usd
        p["sessions"] += 1
        p["geschaetzt"] = p["geschaetzt"] or not sicher
        for monat, w in monate.items():
            z = p["monate"].setdefault(monat, {"tokens": 0, "usd": 0.0})
            z["tokens"] += w["tokens"]
            z["usd"] += w["usd"]
        if zuletzt > p["zuletzt"]:
            p["zuletzt"] = zuletzt
        sitzungen[os.path.basename(pfad)[:-6]] = (cwd, tokens, usd)
    return projekte, sitzungen


def runde(p):
    p["usd"] = round(p["usd"], 4)
    for m in p["monate"].values():
        m["usd"] = round(m["usd"], 4)
    tag = p.get("zuletzt", "")
    p["zuletzt"] = f"{tag[8:10]}.{tag[5:7]}.{tag[0:4]}" if len(tag) >= 10 else ""
    return p


def merke_gemeldet(sitzungen):
    """Laufenden Sitzungen mitgeben, was schon im Buch steht."""
    angepasst = 0
    for datei in glob.glob(hook.state_dir() + "/*.json"):
        sid = os.path.basename(datei)[:-5]
        if sid not in sitzungen:
            continue
        _, tokens, usd = sitzungen[sid]
        try:
            with open(datei) as f:
                rec = json.load(f)
            rec["gemeldet"] = {"gesamt": tokens, "usd": round(usd, 4)}
            with open(datei + ".tmp", "w") as f:
                json.dump(rec, f, ensure_ascii=False)
            os.replace(datei + ".tmp", datei)
            angepasst += 1
        except Exception:
            pass
    return angepasst


def main():
    argumente = sys.argv[1:]
    probe = "--probe" in argumente
    namen = [a for a in argumente if not a.startswith("--")]
    if not namen:
        print(__doc__)
        return 1

    projekte, sitzungen = sammle(set(namen))
    if not projekte:
        print("Keine Protokolle gefunden für: " + ", ".join(namen))
        return 1

    for cwd, p in sorted(projekte.items(), key=lambda x: -x[1]["usd"]):
        runde(p)
        print("{:<28} {:>10} Tokens {:>10}  {} Sitzungen  bis {}".format(
            p["name"], hook.tokens_kurz(p["tokens"]), hook.geld_kurz(p["usd"]),
            p["sessions"], p["zuletzt"]))
        print("    Monate: " + ", ".join(
            f"{m} {hook.geld_kurz(w['usd'])}" for m, w in sorted(p["monate"].items())))
        print("    Pfad:   " + cwd)

    if probe:
        print("\nProbelauf — nichts geschrieben.")
        return 0

    pfad = hook.buch_json()
    os.makedirs(os.path.dirname(pfad), exist_ok=True)
    sperre = open(pfad + ".lock", "a+")
    fcntl.flock(sperre, fcntl.LOCK_EX)
    try:
        try:
            with open(pfad) as f:
                buch = json.load(f)
        except Exception:
            buch = {}
        buch.setdefault("projekte", {})
        for p in buch["projekte"].values():
            hook.monate_sichern(p)          # Altbestand ohne Monatsaufteilung retten
        for cwd, p in projekte.items():
            buch["projekte"][cwd] = p       # ersetzen, nicht addieren
        buch["monate"] = hook.monate_ableiten(buch)

        with open(pfad + ".tmp", "w") as f:
            json.dump(buch, f, ensure_ascii=False)
        os.replace(pfad + ".tmp", pfad)
        md = hook.buch_md()
        os.makedirs(os.path.dirname(md), exist_ok=True)
        with open(md + ".tmp", "w") as f:
            f.write(hook.buch_markdown(buch))
        os.replace(md + ".tmp", md)
    finally:
        fcntl.flock(sperre, fcntl.LOCK_UN)
        sperre.close()

    n = merke_gemeldet(sitzungen)
    print(f"\nEingetragen in {hook.buch_md()}")
    if n:
        print(f"{n} laufende Sitzung(en) auf den neuen Stand gesetzt.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
