// Session-Ampel: schmales Always-on-top-Fenster unter der Menüleiste,
// zeigt alle laufenden Claude-Code-Sessions als farbige Felder.
// Farblogik wie beim Codex Micro: weiß=bereit, blau=arbeitet,
// bernstein=braucht Freigabe, grün=fertig, rot=abgestürzt.
//
// Aufruf ohne Argumente: Anzeige. Mit --dump: Zustandsmodell als JSON
// auf stdout (für die Testsuite), ohne UI.

import AppKit
import Darwin

// MARK: - Farbschema (einzige Quelle der Wahrheit, auch für --dump)

let FARBEN: [String: [String: String]] = [
    "bereit":      ["bg": "#F2F2F7", "fg": "#1C1C1E"],
    "arbeitet":    ["bg": "#0A66E8", "fg": "#FFFFFF"],
    "freigabe":    ["bg": "#FF9F0A", "fg": "#2B1A00"],
    "fertig":      ["bg": "#30D158", "fg": "#0A2E14"],
    "abgestuerzt": ["bg": "#D70015", "fg": "#FFFFFF"],
]

let ZUSTAND_TEXT: [String: String] = [
    "bereit": "bereit, wartet auf Eingabe",
    "arbeitet": "arbeitet",
    "freigabe": "braucht Deine Freigabe",
    "fertig": "Antwort fertig",
    "abgestuerzt": "abgestürzt",
]

// Summenfeld: neutral, damit es sich klar von den Zustandsfarben abhebt
let SUMME_BG = "#3A3A3C"
let SUMME_FG = "#F2F2F7"

// Modell-Chip: eigene Farbwelt, klar getrennt von den Zustandsfarben der Felder
let MODELL_FARBEN: [String: [String: String]] = [
    "fable":  ["bg": "#EC4899", "fg": "#FFFFFF"],
    "mythos": ["bg": "#EC4899", "fg": "#FFFFFF"],
    "opus":   ["bg": "#A855F7", "fg": "#FFFFFF"],
    "sonnet": ["bg": "#7DD3FC", "fg": "#0B2942"],
    "haiku":  ["bg": "#A3B2C2", "fg": "#12202E"],
]
let MODELL_UNBEKANNT: [String: String] = ["bg": "#8E8E93", "fg": "#FFFFFF"]

// Denkstufe: 1 bis 5 gefüllte Punkte
let EFFORT_STUFEN: [String: Int] = [
    "low": 1, "medium": 2, "high": 3, "xhigh": 4, "max": 5,
]
let EFFORT_TEXT: [String: String] = [
    "low": "niedrig", "medium": "mittel", "high": "hoch",
    "xhigh": "sehr hoch", "max": "maximal",
]

// Ablaufbalken des Prompt-Caches
let CACHE_WARNUNG: Double = 0.2    // ab hier tritt der Balken deutlich hervor
let CACHE_NACHLAUF: Int = 300      // "kalt" noch so lange anzeigen, dann Balken weg
let CACHE_BALKEN_HOEHE: CGFloat = 5    // dick genug, um auch bei schmaler Kachel zu tragen
let CACHE_BALKEN_LUFT: CGFloat = 4     // Abstand unter dem Balken bis zum Kachelrand

let MAX_ALTER: Int = 86_400        // Zustandsdateien älter als 24 h gelten als Müll
let ROT_VERFALL: Int = 1_800       // abgestürzte Sessions nach 30 min ausblenden

// Plan-Limits: Abfrage beim Konto, dieselben Werte wie /usage in Claude Code
let LIMIT_TAKT: Int = 300          // alle 5 min neu abfragen
let LIMIT_VERALTET: Int = 900      // ältere Werte gelten als veraltet
let LIMIT_WARNUNG: Int = 75        // ab hier bernstein
let LIMIT_KRITISCH: Int = 90       // ab hier rot
let LIMIT_BG = "#2C2C2E"
let LIMIT_FG = "#F2F2F7"
let LIMIT_FARBE_WARNUNG = "#FF9F0A"
let LIMIT_FARBE_KRITISCH = "#FF453A"
let LIMIT_BALKEN_BREITE: CGFloat = 60

// MARK: - Modell

struct Sitzung {
    let id: String
    var label: String
    let state: String
    let cwd: String
    /// Projektschlüssel — alle Sitzungen desselben Ordners bilden einen Block
    let gruppe: String
    let started: Int
    /// Zeitpunkt des letzten Ereignisses — Anker für die Cache-Frist
    let ts: Int
    /// Zeitpunkt der letzten Nutzereingabe (Hook), 0 = noch keine
    let promptTs: Int
    /// Ablagefrist des Prompt-Caches in Sekunden (300 oder 3600), 0 = noch unbekannt
    let cacheTtl: Int
    let pid: Int32
    let tty: String
    let tokens: Verbrauch
    let kostenUSD: Double
    let kostenGeschaetzt: Bool
    let modelle: [String]
    let modellRoh: String
    let effort: String
    /// Von Hand gesetzt: „hier arbeite ich gerade nicht weiter"
    var ruht = false
}

/// Modellname zerlegen: "claude-opus-4-7" → ("O4.7", "opus", "Opus 4.7"),
/// "opus[1m]" → ("O", "opus", "Opus · 1M-Kontext"). Unbekannte Namen behalten
/// ihren Anfangsbuchstaben und bekommen die neutrale Chipfarbe.
func modellTeile(_ roh: String) -> (kurz: String, familie: String, lang: String) {
    if roh.isEmpty { return ("", "", "") }
    var m = roh.replacingOccurrences(of: "[1m]", with: "")
    let grosserKontext = roh.contains("[1m]")
    if m.hasPrefix("claude-") { m = String(m.dropFirst("claude-".count)) }
    if let r = m.range(of: "-20[0-9]{6}$", options: .regularExpression) { m.removeSubrange(r) }
    let teile = m.split(separator: "-").map(String.init)
    let familie = teile.first ?? ""
    let version = teile.dropFirst().joined(separator: ".")
    let kurz = familie.prefix(1).uppercased() + version
    var lang = familie.prefix(1).uppercased() + familie.dropFirst()
    if !version.isEmpty { lang += " " + version }
    if grosserKontext { lang += " · 1M-Kontext" }
    return (kurz, familie, lang)
}

func modellFarben(_ familie: String) -> [String: String] {
    MODELL_FARBEN[familie] ?? MODELL_UNBEKANNT
}

func effortStufe(_ e: String) -> Int { EFFORT_STUFEN[e] ?? 0 }

/// Tokensummen einer Sitzung, wie der Hook sie aus dem Verlaufsprotokoll zieht.
struct Verbrauch {
    var eingabe = 0
    var ausgabe = 0
    var cacheAufbau = 0
    var cacheLesen = 0
    var gesamt = 0
}

/// 7916551 → "7,9 M", 84210 → "84k", 840 → "840"
func tokenKurz(_ n: Int) -> String {
    if n >= 1_000_000 {
        return String(format: "%.1f M", Double(n) / 1_000_000)
            .replacingOccurrences(of: ".", with: ",")
    }
    if n >= 1_000 { return "\(n / 1_000)k" }
    return "\(n)"
}

/// 15.4205 → "15,42 $"; ab 100 $ ohne Nachkommastellen
func geldKurz(_ d: Double) -> String {
    let roh = d >= 100 ? String(format: "%.0f", d) : String(format: "%.2f", d)
    return roh.replacingOccurrences(of: ".", with: ",") + " $"
}

/// Restsekunden, bis der Prompt-Cache dieser Sitzung verfällt.
/// nil = kein Countdown sinnvoll (Sitzung arbeitet, ist abgestürzt, oder die
/// Frist ist noch unbekannt, weil noch keine Antwort geschrieben wurde).
/// Negativ = schon abgelaufen.
func cacheRest(_ s: Sitzung, _ jetzt: Int) -> Int? {
    if s.cacheTtl <= 0 || s.ts <= 0 { return nil }
    if s.state == "arbeitet" || s.state == "abgestuerzt" { return nil }
    let rest = s.cacheTtl - (jetzt - s.ts)
    if rest < -CACHE_NACHLAUF { return nil }   // längst kalt: Kachel wieder ruhig
    return rest
}

/// Anteil der Frist, der noch übrig ist (0…1) — die Länge des Balkens.
func cacheAnteil(_ s: Sitzung, _ rest: Int) -> Double {
    if s.cacheTtl <= 0 { return 0 }
    return min(1.0, max(0.0, Double(rest) / Double(s.cacheTtl)))
}

/// 247 → "4:07", 1820 → "30 min", abgelaufen → "kalt"
func cacheZeile(_ rest: Int) -> String {
    if rest <= 0 { return "kalt" }
    if rest >= 600 { return "\(rest / 60) min" }
    return String(format: "%d:%02d", rest / 60, rest % 60)
}

func fristKurz(_ ttl: Int) -> String {
    ttl >= 3600 ? "\(ttl / 3600) h" : "\(ttl / 60) min"
}

// MARK: - Plan-Limits

struct Limit {
    let art: String        // session, weekly_all, weekly_scoped
    let name: String       // "5 h", "Woche", "Fable"
    let prozent: Int
    let resetsAt: Int      // Unix-Sekunden, 0 = unbekannt
    let severity: String
}

struct LimitStand {
    var limits: [Limit] = []
    var geholt = 0         // Zeitpunkt der letzten erfolgreichen Abfrage
    var fehler = ""
}

func isoZeit(_ s: String) -> Int {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return Int(d.timeIntervalSince1970) }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s).map { Int($0.timeIntervalSince1970) } ?? 0
}

/// Liest die Liste `limits` aus der Antwort des Kontos.
func parseLimits(_ daten: Data) throws -> [Limit] {
    guard let wurzel = try JSONSerialization.jsonObject(with: daten) as? [String: Any],
          let liste = wurzel["limits"] as? [[String: Any]] else {
        throw NSError(domain: "ampel", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Antwort ohne limits-Liste"])
    }
    return liste.compactMap { e in
        guard let art = e["kind"] as? String else { return nil }
        let name: String
        switch art {
        case "session": name = "5 h"
        case "weekly_all": name = "Woche"
        default:
            let scope = e["scope"] as? [String: Any]
            let modell = scope?["model"] as? [String: Any]
            name = modell?["display_name"] as? String ?? art
        }
        return Limit(art: art, name: name,
                     prozent: (e["percent"] as? NSNumber)?.intValue ?? 0,
                     resetsAt: isoZeit(e["resets_at"] as? String ?? ""),
                     severity: e["severity"] as? String ?? "normal")
    }
}

func limitFarbe(_ l: Limit) -> String {
    if l.prozent >= LIMIT_KRITISCH { return LIMIT_FARBE_KRITISCH }
    if l.prozent >= LIMIT_WARNUNG || l.severity != "normal" { return LIMIT_FARBE_WARNUNG }
    return LIMIT_FG
}

func limitLang(_ l: Limit) -> String {
    switch l.art {
    case "session": return "Sitzungsfenster (5 h)"
    case "weekly_all": return "Woche, alle Modelle"
    default: return "Woche, \(l.name)"
    }
}

/// "13:20" am selben Tag, sonst "Do 05:00"
func resetKurz(_ ts: Int, _ jetzt: Int) -> String {
    if ts <= 0 { return "" }
    let d = Date(timeIntervalSince1970: TimeInterval(ts))
    let heute = Calendar.current.isDate(d, inSameDayAs: Date(timeIntervalSince1970: TimeInterval(jetzt)))
    let df = DateFormatter()
    df.locale = Locale(identifier: "de_DE")
    df.dateFormat = heute ? "HH:mm" : "EEEEEE HH:mm"
    return df.string(from: d)
}

/// "noch 2 h 14 min"
func restDauer(_ ts: Int, _ jetzt: Int) -> String {
    let rest = max(0, ts - jetzt)
    if rest >= 86_400 { return "noch \(rest / 86_400) d \((rest % 86_400) / 3600) h" }
    if rest >= 3600 { return "noch \(rest / 3600) h \((rest % 3600) / 60) min" }
    return "noch \(rest / 60) min"
}

func befehl(_ pfad: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: pfad)
    p.arguments = args
    let rohr = Pipe()
    p.standardOutput = rohr
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let d = rohr.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: d, encoding: .utf8) ?? ""
}

/// Anmelde-Token von Claude Code aus dem Schlüsselbund.
func oauthToken() -> String? {
    let roh = befehl("/usr/bin/security",
                     ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
    guard let d = roh.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
          let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let o = j["claudeAiOauth"] as? [String: Any],
          let t = o["accessToken"] as? String, !t.isEmpty else { return nil }
    return t
}

/// Holt die Plan-Limits. Mit AMPEL_LIMITS_DATEI wird statt des Kontos eine
/// Datei gelesen (Testsuite); --dump fragt nie das Konto.
func holeLimits(nurDatei: Bool = false) -> LimitStand {
    var st = LimitStand()
    let jetzt = Int(Date().timeIntervalSince1970)
    if let pfad = ProcessInfo.processInfo.environment["AMPEL_LIMITS_DATEI"] {
        do {
            st.limits = try parseLimits(try Data(contentsOf: URL(fileURLWithPath: pfad)))
            st.geholt = jetzt
        } catch { st.fehler = error.localizedDescription }
        return st
    }
    if nurDatei { return st }
    guard let token = oauthToken() else {
        st.fehler = "kein Anmelde-Token im Schlüsselbund"
        return st
    }
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    req.timeoutInterval = 15
    req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    let warte = DispatchSemaphore(value: 0)
    var daten: Data? = nil
    var fehler = ""
    URLSession.shared.dataTask(with: req) { d, r, e in
        if let e = e {
            fehler = e.localizedDescription
        } else if let h = r as? HTTPURLResponse, h.statusCode != 200 {
            fehler = h.statusCode == 401
                ? "Anmeldung abgelaufen (Claude Code einmal starten)" : "HTTP \(h.statusCode)"
        } else {
            daten = d
        }
        warte.signal()
    }.resume()
    warte.wait()
    if let daten = daten {
        do { st.limits = try parseLimits(daten); st.geholt = jetzt }
        catch { st.fehler = error.localizedDescription }
    } else {
        st.fehler = fehler
    }
    return st
}

func stateDir() -> String {
    ProcessInfo.processInfo.environment["SESSION_AMPEL_DIR"]
        ?? NSHomeDirectory() + "/.claude/session-ampel/state"
}

/// Die Ruht-Markierungen liegen neben den Zustandsdateien, aber bewusst ohne
/// .json-Endung — sonst hielte die Anzeige sie für eine Sitzung.
func ruhtPfad() -> String { stateDir() + "/ruht.liste" }

/// Je Zeile eine Sitzung: "<id> <Zeitpunkt der Markierung>"
func ladeRuht() -> [String: Int] {
    guard let text = try? String(contentsOfFile: ruhtPfad(), encoding: .utf8) else { return [:] }
    var menge: [String: Int] = [:]
    for zeile in text.split(separator: "\n") {
        let teile = zeile.split(separator: " ")
        guard let id = teile.first, !id.isEmpty else { continue }
        menge[String(id)] = teile.count > 1 ? (Int(teile[1]) ?? 0) : 0
    }
    return menge
}

func speichereRuht(_ menge: [String: Int]) {
    try? FileManager.default.createDirectory(atPath: stateDir(),
                                             withIntermediateDirectories: true)
    let text = menge.keys.sorted().map { "\($0) \(menge[$0]!)" }.joined(separator: "\n")
    try? text.write(toFile: ruhtPfad(), atomically: true, encoding: .utf8)
}

/// Markierung umschalten (oder mit `an` gezielt setzen). Rückgabe: neuer Stand.
@discardableResult
func schalteRuht(_ id: String, _ an: Bool? = nil) -> Bool {
    var menge = ladeRuht()
    let neu = an ?? (menge[id] == nil)
    if neu { menge[id] = Int(Date().timeIntervalSince1970) } else { menge[id] = nil }
    speichereRuht(menge)
    return neu
}

func pidLebt(_ pid: Int32) -> Bool {
    if pid <= 0 { return true }  // PID unbekannt: im Zweifel anzeigen
    if kill(pid, 0) == 0 { return true }
    return errno == EPERM
}

func ladeSitzungen() -> [Sitzung] {
    let dir = stateDir()
    let fm = FileManager.default
    guard let dateien = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
    let jetzt = Int(Date().timeIntervalSince1970)
    var liste: [Sitzung] = []

    for name in dateien where name.hasSuffix(".json") {
        let pfad = dir + "/" + name
        guard let daten = fm.contents(atPath: pfad),
              let obj = try? JSONSerialization.jsonObject(with: daten) as? [String: Any]
        else { continue }

        let ts = (obj["ts"] as? NSNumber)?.intValue ?? 0
        if jetzt - ts > MAX_ALTER {
            try? fm.removeItem(atPath: pfad)
            continue
        }

        var state = obj["state"] as? String ?? "bereit"
        let pid = (obj["pid"] as? NSNumber)?.int32Value ?? 0
        if !pidLebt(pid) {
            if state == "arbeitet" || state == "freigabe" {
                // Prozess weg, obwohl er zu tun hatte: abgestürzt (rot), später aufräumen
                if jetzt - ts > ROT_VERFALL {
                    try? fm.removeItem(atPath: pfad)
                    continue
                }
                state = "abgestuerzt"
            } else {
                // sauber vorbei, nur die Abmeldung fehlte
                try? fm.removeItem(atPath: pfad)
                continue
            }
        }

        let t = obj["tokens"] as? [String: Any] ?? [:]
        let zahl = { (k: String) in (t[k] as? NSNumber)?.intValue ?? 0 }
        let verbrauch = Verbrauch(
            eingabe: zahl("in"), ausgabe: zahl("out"),
            cacheAufbau: zahl("cache_w"), cacheLesen: zahl("cache_r"),
            gesamt: zahl("gesamt"))

        let projekt = obj["project"] as? String ?? "?"
        let cwd = obj["cwd"] as? String ?? ""

        liste.append(Sitzung(
            id: obj["session_id"] as? String ?? String(name.dropLast(5)),
            label: projekt,
            state: state,
            cwd: cwd,
            gruppe: cwd.isEmpty ? projekt : cwd,
            started: (obj["started"] as? NSNumber)?.intValue ?? ts,
            ts: ts,
            promptTs: (obj["prompt_ts"] as? NSNumber)?.intValue ?? 0,
            cacheTtl: ((obj["aktuell"] as? [String: Any])?["cache_ttl"] as? NSNumber)?
                .intValue ?? 0,
            pid: pid,
            tty: obj["tty"] as? String ?? "",
            tokens: verbrauch,
            kostenUSD: (obj["kosten_usd"] as? NSNumber)?.doubleValue ?? 0,
            kostenGeschaetzt: (obj["kosten_geschaetzt"] as? NSNumber)?.boolValue ?? false,
            modelle: ((obj["modelle"] as? [String: Any])?.keys.sorted()) ?? [],
            modellRoh: (obj["aktuell"] as? [String: Any])?["modell"] as? String ?? "",
            effort: (obj["aktuell"] as? [String: Any])?["effort"] as? String ?? ""
        ))
    }

    liste.sort { ($0.started, $0.id) < ($1.started, $1.id) }
    // Sitzungen desselben Projekts hintereinander, Projekte nach ihrer ältesten Sitzung
    var rang: [String: Int] = [:]
    for s in liste where rang[s.gruppe] == nil { rang[s.gruppe] = rang.count }
    liste.sort {
        (rang[$0.gruppe]!, $0.started, $0.id) < (rang[$1.gruppe]!, $1.started, $1.id)
    }

    var zaehler: [String: Int] = [:]
    for i in liste.indices {
        let name = liste[i].label
        let n = (zaehler[name] ?? 0) + 1
        zaehler[name] = n
        if n > 1 { liste[i].label = "\(name) \(n)" }
    }

    // Eine Markierung überdauert jeden Zustand — gerade eine Sitzung, die auf
    // Freigabe wartet, ist der Hauptfall. Sie verfällt erst, wenn dort wieder
    // etwas eingegeben wurde, und wenn es die Sitzung nicht mehr gibt.
    let gemerkt = ladeRuht()
    if !gemerkt.isEmpty {
        var gueltig: [String: Int] = [:]
        for s in liste {
            guard let seit = gemerkt[s.id], s.promptTs <= seit else { continue }
            gueltig[s.id] = seit
        }
        if gueltig != gemerkt { speichereRuht(gueltig) }
        for i in liste.indices where gueltig[liste[i].id] != nil { liste[i].ruht = true }
    }
    return liste
}

/// Die sortierte Liste in Projektblöcke zerlegen. Die Reihenfolge bleibt erhalten,
/// jeder Block enthält alle Terminals eines Projekts.
func gruppiere(_ liste: [Sitzung]) -> [[Sitzung]] {
    var bloecke: [[Sitzung]] = []
    for s in liste {
        if var letzter = bloecke.last, letzter[0].gruppe == s.gruppe {
            letzter.append(s)
            bloecke[bloecke.count - 1] = letzter
        } else {
            bloecke.append([s])
        }
    }
    return bloecke
}

/// Zweite Zeile im Feld: Tokenverbrauch und hypothetischer API-Preis.
/// Die Tilde markiert einen Preis mit unbekanntem Modell (Opus-Klasse geschätzt).
func verbrauchsZeile(tokens: Int, usd: Double, geschaetzt: Bool) -> String {
    let geld = (geschaetzt ? "~" : "") + geldKurz(usd)
    return "\(tokenKurz(tokens)) · \(geld)"
}

func verbrauchsZeile(_ s: Sitzung) -> String {
    verbrauchsZeile(tokens: s.tokens.gesamt, usd: s.kostenUSD, geschaetzt: s.kostenGeschaetzt)
}

/// Chip als Text: Kürzel plus Punktreihe, z. B. "O5 ●●●○○".
/// Leer, solange die Sitzung noch keine Antwort geschrieben hat.
func chipZeile(_ s: Sitzung) -> String {
    let m = modellTeile(s.modellRoh)
    if m.kurz.isEmpty { return "" }
    let stufe = effortStufe(s.effort)
    if stufe == 0 { return m.kurz }
    return m.kurz + " " + String(repeating: "●", count: stufe)
        + String(repeating: "○", count: 5 - stufe)
}

/// Summe über alle sichtbaren Sitzungen — für das Feld ganz rechts.
func gesamtSumme(_ liste: [Sitzung]) -> (tokens: Verbrauch, usd: Double, geschaetzt: Bool) {
    var t = Verbrauch()
    var usd = 0.0
    var geschaetzt = false
    for s in liste {
        t.eingabe += s.tokens.eingabe
        t.ausgabe += s.tokens.ausgabe
        t.cacheAufbau += s.tokens.cacheAufbau
        t.cacheLesen += s.tokens.cacheLesen
        t.gesamt += s.tokens.gesamt
        usd += s.kostenUSD
        geschaetzt = geschaetzt || s.kostenGeschaetzt
    }
    return (t, usd, geschaetzt)
}

// MARK: - --dump für die Tests

func dumpJSON() -> String {
    let liste = ladeSitzungen()
    let jetzt = Int(Date().timeIntervalSince1970)
    let sitzungen: [[String: Any]] = liste.map { (x: Sitzung) -> [String: Any] in
        let rest = cacheRest(x, jetzt)
        return ["sessionId": x.id, "label": x.label, "state": x.state,
         "bg": FARBEN[x.state]?["bg"] ?? "", "fg": FARBEN[x.state]?["fg"] ?? "",
         "cwd": x.cwd, "gruppe": x.gruppe, "started": x.started, "tty": x.tty,
         "tokens": x.tokens.gesamt, "kostenUSD": x.kostenUSD,
         "kostenGeschaetzt": x.kostenGeschaetzt,
         "verbrauchsZeile": verbrauchsZeile(x),
         "modell": modellTeile(x.modellRoh).kurz,
         "modellFamilie": modellTeile(x.modellRoh).familie,
         "modellLang": modellTeile(x.modellRoh).lang,
         "effort": x.effort,
         "effortStufe": effortStufe(x.effort),
         "ruht": x.ruht,
         "chip": chipZeile(x),
         "cacheTtl": x.cacheTtl,
         "cacheRest": rest ?? -9999,
         "cacheAnteil": rest.map { cacheAnteil(x, $0) } ?? -1,
         "cacheZeile": rest.map { cacheZeile($0) } ?? ""]
    }
    let g = gesamtSumme(liste)
    let ls = holeLimits(nurDatei: true)
    let modell: [String: Any] = [
        "summe": ["tokens": g.tokens.gesamt, "kostenUSD": g.usd,
                  "zeile": verbrauchsZeile(tokens: g.tokens.gesamt, usd: g.usd,
                                           geschaetzt: g.geschaetzt)],
        "stateDir": stateDir(),
        "farben": FARBEN,
        "modellFarben": MODELL_FARBEN,
        "modellFarbeUnbekannt": MODELL_UNBEKANNT,
        "summeFarben": ["bg": SUMME_BG, "fg": SUMME_FG],
        "window": ["level": "statusBar", "alwaysOnTop": true, "activationPolicy": "accessory"],
        "sessions": sitzungen,
        "gruppen": gruppiere(liste).map { $0.map { $0.id } },
        "limits": ls.limits.map { (l: Limit) -> [String: Any] in
            ["art": l.art, "name": l.name, "prozent": l.prozent, "resetsAt": l.resetsAt,
             "resetText": resetKurz(l.resetsAt, jetzt), "severity": l.severity,
             "farbe": limitFarbe(l), "lang": limitLang(l)] },
        "limitsFehler": ls.fehler,
    ]
    let daten = try! JSONSerialization.data(withJSONObject: modell)
    return String(data: daten, encoding: .utf8)!
}

// MARK: - Terminalfenster der Session nach vorn holen

func osascript(_ skript: String) -> String {
    if ProcessInfo.processInfo.environment["AMPEL_OSA_DRY"] != nil { return "(trocken)" }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", skript]
    let rohr = Pipe()
    p.standardOutput = rohr
    p.standardError = Pipe()
    do { try p.run(); p.waitUntilExit() } catch { return "fehler" }
    let daten = rohr.fileHandleForReading.readDataToEndOfFile()
    return String(data: daten, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

func appLaeuft(_ bundleId: String) -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
}

/// Nur was wirklich wie eine Terminal-Leitung aussieht (z. B. 'ttys005') darf ins
/// AppleScript eingesetzt werden — sonst ließe sich über den Namen fremder Befehl einschleusen.
let TTY_ERLAUBT = CharacterSet(charactersIn:
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-")

func ttyUnbedenklich(_ tty: String) -> Bool {
    !tty.isEmpty && tty.count <= 32 && tty.unicodeScalars.allSatisfy { TTY_ERLAUBT.contains($0) }
}

func terminalSkript(_ dev: String) -> String { """
    tell application "Terminal"
        repeat with w in windows
            try
                repeat with t in tabs of w
                    if tty of t is "\(dev)" then
                        set selected tab of w to t
                        try
                            set miniaturized of w to false
                        end try
                        set index of w to 1
                        activate
                        return "ok"
                    end if
                end repeat
            end try
        end repeat
    end tell
    return "nicht gefunden"
    """ }

func itermSkript(_ dev: String) -> String { """
    tell application "iTerm2"
        repeat with w in windows
            repeat with t in tabs of w
                repeat with s in sessions of t
                    if tty of s is "\(dev)" then
                        select s
                        select t
                        select w
                        activate
                        return "ok"
                    end if
                end repeat
            end repeat
        end repeat
    end tell
    return "nicht gefunden"
    """ }

/// Elternprozesskette der Session nach einer bekannten Terminal-App absuchen (Fallback).
func terminalAppPid(_ startPid: Int32) -> Int32? {
    let bekannt = ["terminal", "iterm", "ghostty", "kitty", "alacritty", "wezterm", "warp"]
    var pid = startPid
    for _ in 0..<12 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-p", String(pid), "-o", "ppid=,comm="]
        let rohr = Pipe()
        p.standardOutput = rohr
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let zeile = String(data: rohr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !zeile.isEmpty else { return nil }
        let teile = zeile.split(separator: " ", maxSplits: 1)
        guard let ppid = Int32(teile[0]) else { return nil }
        let comm = teile.count > 1 ? String(teile[1]).lowercased() : ""
        if bekannt.contains(where: { comm.contains($0) }) { return pid }
        if ppid <= 1 { return nil }
        pid = ppid
    }
    return nil
}

/// Leitung (tty) live vom Prozess erfragen — für Sitzungen, deren Eintrag sie noch nicht führt.
func liveTty(_ pid: Int32) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-p", String(pid), "-o", "tty="]
    let rohr = Pipe()
    p.standardOutput = rohr
    guard (try? p.run()) != nil else { return "??" }
    p.waitUntilExit()
    let aus = String(data: rohr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return aus.isEmpty ? "??" : aus
}

/// Ergebnis: methode = terminal (Tab per tty gefunden) / app (nur App nach vorn) / keine
func fokussiere(_ sessionId: String) -> [String: String] {
    guard let s = ladeSitzungen().first(where: { $0.id == sessionId }) else {
        return ["methode": "keine", "grund": "Session unbekannt"]
    }
    var tty = s.tty
    if tty.isEmpty || tty == "??" { tty = liveTty(s.pid) }
    if !ttyUnbedenklich(tty) { tty = "??" }
    if tty != "??" {
        let dev = "/dev/" + tty
        if appLaeuft("com.apple.Terminal") {
            let erg = osascript(terminalSkript(dev))
            if erg != "nicht gefunden" && erg != "fehler" {
                return ["methode": "terminal", "tty": dev, "ergebnis": erg]
            }
        }
        if appLaeuft("com.googlecode.iterm2") {
            let erg = osascript(itermSkript(dev))
            if erg != "nicht gefunden" && erg != "fehler" {
                return ["methode": "terminal", "tty": dev, "ergebnis": erg]
            }
        }
    }
    if let tpid = terminalAppPid(s.pid),
       let app = NSRunningApplication(processIdentifier: tpid) {
        if ProcessInfo.processInfo.environment["AMPEL_OSA_DRY"] == nil {
            app.activate()
        }
        return ["methode": "app", "app": app.localizedName ?? "?"]
    }
    return ["methode": "app", "grund": "kein Terminal in der Prozesskette"]
}

if CommandLine.arguments.contains("--dump") {
    print(dumpJSON())
    exit(0)
}

// Diagnose: Limits einmal live vom Konto holen und ausgeben
if CommandLine.arguments.contains("--limits") {
    let st = holeLimits()
    let jetzt = Int(Date().timeIntervalSince1970)
    for l in st.limits {
        print("\(limitLang(l)): \(l.prozent) % · Zurücksetzung \(resetKurz(l.resetsAt, jetzt)) (\(restDauer(l.resetsAt, jetzt)))")
    }
    if !st.fehler.isEmpty { print("Fehler: \(st.fehler)") }
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--ruht"), i + 1 < CommandLine.arguments.count {
    let wunsch = CommandLine.arguments.count > i + 2 ? CommandLine.arguments[i + 2] : ""
    let an: Bool? = wunsch == "an" ? true : (wunsch == "aus" ? false : nil)
    print(schalteRuht(CommandLine.arguments[i + 1], an) ? "an" : "aus")
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--focus"), i + 1 < CommandLine.arguments.count {
    let erg = fokussiere(CommandLine.arguments[i + 1])
    let daten = try! JSONSerialization.data(withJSONObject: erg, options: [.sortedKeys])
    // Testbares Format mit Leerzeichen nach dem Doppelpunkt
    print(String(data: daten, encoding: .utf8)!
        .replacingOccurrences(of: "\":\"", with: "\": \""))
    exit(0)
}

// MARK: - Nur eine Instanz zulassen

let lockPfad = NSHomeDirectory() + "/.claude/session-ampel/app.lock"
try? FileManager.default.createDirectory(
    atPath: (lockPfad as NSString).deletingLastPathComponent,
    withIntermediateDirectories: true)
let lockFD = open(lockPfad, O_CREAT | O_RDWR, 0o644)
if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    exit(0)  // läuft schon
}

// MARK: - UI

func farbe(_ hex: String) -> NSColor {
    var h = hex; if h.hasPrefix("#") { h.removeFirst() }
    let v = UInt32(h, radix: 16) ?? 0
    return NSColor(
        srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
        green: CGFloat((v >> 8) & 0xFF) / 255,
        blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

final class FeldView: NSView {
    var sessionId = ""

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Beschriftungen und Chip dürfen den Klick nicht schlucken: alles außerhalb
    /// des Sterns zählt als Klick auf die Kachel.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let treffer = super.hitTest(point) else { return nil }
        var v: NSView? = treffer
        while let x = v {
            if let stern = x as? SternView { return stern }
            v = x.superview
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        klickLog("Kachel getroffen: \(sessionId)")
        let id = sessionId
        DispatchQueue.global(qos: .userInitiated).async {
            _ = fokussiere(id)
        }
    }
}

/// Klickprotokoll für die Fehlersuche. Schreibt nur, wenn die Datei bereits da ist:
/// `touch ~/.claude/session-ampel/klick.log` schaltet es ein, Löschen schaltet es aus.
func klickLog(_ text: String) {
    let pfad = NSHomeDirectory() + "/.claude/session-ampel/klick.log"
    guard let fh = FileHandle(forWritingAtPath: pfad) else { return }
    let df = DateFormatter(); df.dateFormat = "HH:mm:ss"
    fh.seekToEndOfFile()
    fh.write("\(df.string(from: Date())) \(text)\n".data(using: .utf8)!)
    try? fh.close()
}

final class SternView: NSView {
    var beiKlick: () -> Void = {}
    // Die Ampel ist nie die aktive App: ohne diese Zusage verpufft jeder Klick
    // als bloßer Aktivierungsklick, ohne die View je zu erreichen.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // Kein super-Aufruf: sonst holt der Klick zusätzlich das Terminal nach vorn
    override func mouseDown(with event: NSEvent) {
        klickLog("Stern getroffen")
        beiKlick()
    }
}

final class HintergrundView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Session-Ampel beenden",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

/// Modell-Chip: farbige Pille mit Kürzel und Denkstufe als Punktreihe.
/// Eigene Hintergrundfarbe, damit er auf jeder Zustandsfarbe des Feldes lesbar bleibt.
func chipAnsicht(_ s: Sitzung) -> NSView? {
    let m = modellTeile(s.modellRoh)
    if m.kurz.isEmpty { return nil }
    let c = modellFarben(m.familie)
    let vg = farbe(c["fg"]!)

    let text = NSMutableAttributedString(
        string: m.kurz,
        attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .bold),
                     .foregroundColor: vg])
    let stufe = effortStufe(s.effort)
    if stufe > 0 {
        text.append(NSAttributedString(string: " ", attributes: [
            .font: NSFont.systemFont(ofSize: 9)]))
        for i in 1...5 {
            text.append(NSAttributedString(string: "●", attributes: [
                .font: NSFont.systemFont(ofSize: 6),
                .baselineOffset: 1.0,
                .kern: 0.8,
                .foregroundColor: i <= stufe ? vg : vg.withAlphaComponent(0.32)]))
        }
    }

    let label = NSTextField(labelWithAttributedString: text)
    let pille = NSView()
    pille.wantsLayer = true
    pille.layer?.backgroundColor = farbe(c["bg"]!).cgColor
    pille.layer?.cornerRadius = 5
    label.translatesAutoresizingMaskIntoConstraints = false
    pille.addSubview(label)
    NSLayoutConstraint.activate([
        label.leadingAnchor.constraint(equalTo: pille.leadingAnchor, constant: 4),
        label.trailingAnchor.constraint(equalTo: pille.trailingAnchor, constant: -4),
        label.topAnchor.constraint(equalTo: pille.topAnchor, constant: 1),
        label.bottomAnchor.constraint(equalTo: pille.bottomAnchor, constant: -1),
    ])
    pille.setContentHuggingPriority(.required, for: .horizontal)
    pille.setContentCompressionResistancePriority(.required, for: .horizontal)
    return pille
}

/// Stern oben rechts in der Kachel: an = die Sitzung ruht, ich schaue hier gerade nicht hin.
/// Blass, solange nichts markiert ist — sichtbar genug zum Anklicken, leise genug zum Übersehen.
func sternAnsicht(_ s: Sitzung, fg: String, aktion: @escaping () -> Void) -> NSView {
    let flaeche = SternView()
    flaeche.beiKlick = aktion
    let zeichen = NSTextField(labelWithString: s.ruht ? "★" : "☆")
    zeichen.font = .systemFont(ofSize: 11)
    zeichen.textColor = farbe(fg).withAlphaComponent(s.ruht ? 1.0 : 0.32)
    zeichen.translatesAutoresizingMaskIntoConstraints = false
    flaeche.addSubview(zeichen)
    NSLayoutConstraint.activate([
        zeichen.leadingAnchor.constraint(equalTo: flaeche.leadingAnchor, constant: 3),
        zeichen.trailingAnchor.constraint(equalTo: flaeche.trailingAnchor, constant: -3),
        zeichen.topAnchor.constraint(equalTo: flaeche.topAnchor, constant: 2),
        zeichen.bottomAnchor.constraint(equalTo: flaeche.bottomAnchor, constant: -2),
    ])
    let hinweis = s.ruht
        ? "Ruht — Klick auf den Stern holt die Sitzung zurück in die Beobachtung"
        : "Klick auf den Stern: als ruhend markieren (Kachel tritt zurück)"
    flaeche.toolTip = hinweis
    zeichen.toolTip = hinweis
    return flaeche
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var panel: NSPanel!
    var stack: NSStackView!
    var letzterStand = ""
    /// Balken und Restzeit je Sitzung — werden im Sekundentakt nachgezogen,
    /// ohne die ganze Kachel neu zu bauen.
    struct Uhr {
        let spur: NSView
        let fuellung: CALayer
        let label: NSTextField
        let fg: NSColor
    }
    var uhren: [String: Uhr] = [:]
    let ablage = UserDefaults.standard

    var limitStand = LimitStand()
    var limitVersuch = 0        // Zeitpunkt der letzten Abfrage, auch einer fehlgeschlagenen
    var limitLaeuft = false

    /// Fragt die Limits alle LIMIT_TAKT Sekunden im Hintergrund beim Konto ab.
    func frageLimitsAb() {
        let jetzt = Int(Date().timeIntervalSince1970)
        guard !limitLaeuft, jetzt - limitVersuch >= LIMIT_TAKT else { return }
        limitLaeuft = true
        limitVersuch = jetzt
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var neu = holeLimits()
            DispatchQueue.main.async {
                guard let self = self else { return }
                // Fehlschlag: alte Werte behalten, nur den Fehler dazu merken
                if neu.limits.isEmpty, !self.limitStand.limits.isEmpty {
                    neu.limits = self.limitStand.limits
                    neu.geholt = self.limitStand.geholt
                }
                self.limitStand = neu
                self.limitLaeuft = false
                self.letzterStand = ""
                self.aktualisiere()
            }
        }
    }

    func setzeHinweis(_ v: NSView, _ t: String) {
        v.toolTip = t
        v.subviews.forEach { setzeHinweis($0, t) }
    }

    /// Feld ganz links: Plan-Limits mit Balken, Prozent und Zurücksetzung.
    func limitFeld(_ st: LimitStand, jetzt: Int) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = farbe(LIMIT_BG).cgColor
        box.layer?.cornerRadius = 6
        let vg = farbe(LIMIT_FG)
        let veraltet = st.geholt > 0 && jetzt - st.geholt > LIMIT_VERALTET

        let titel = NSTextField(labelWithString: "Limits" + (veraltet ? " (alt)" : ""))
        titel.font = .systemFont(ofSize: 13, weight: .semibold)
        titel.textColor = vg
        var zeilen: [NSView] = [titel]

        if st.limits.isEmpty {
            let t = NSTextField(labelWithString: st.fehler.isEmpty ? "wird geholt …" : "nicht erreichbar")
            t.font = .systemFont(ofSize: 11.5)
            t.textColor = farbe(st.fehler.isEmpty ? LIMIT_FG : LIMIT_FARBE_WARNUNG)
                .withAlphaComponent(0.85)
            zeilen.append(t)
        }
        for l in st.limits {
            let name = NSTextField(labelWithString: l.name)
            name.font = .systemFont(ofSize: 11.5, weight: .medium)
            name.textColor = vg.withAlphaComponent(0.85)
            name.widthAnchor.constraint(equalToConstant: 42).isActive = true

            let anteil = CGFloat(min(100, max(0, l.prozent))) / 100
            let spur = NSView()
            spur.wantsLayer = true
            spur.layer?.backgroundColor = vg.withAlphaComponent(0.18).cgColor
            spur.layer?.cornerRadius = CACHE_BALKEN_HOEHE / 2
            spur.widthAnchor.constraint(equalToConstant: LIMIT_BALKEN_BREITE).isActive = true
            spur.heightAnchor.constraint(equalToConstant: CACHE_BALKEN_HOEHE).isActive = true
            let fuellung = NSView()
            fuellung.wantsLayer = true
            fuellung.layer?.backgroundColor = farbe(limitFarbe(l)).cgColor
            fuellung.layer?.cornerRadius = CACHE_BALKEN_HOEHE / 2
            fuellung.translatesAutoresizingMaskIntoConstraints = false
            spur.addSubview(fuellung)
            NSLayoutConstraint.activate([
                fuellung.leadingAnchor.constraint(equalTo: spur.leadingAnchor),
                fuellung.topAnchor.constraint(equalTo: spur.topAnchor),
                fuellung.bottomAnchor.constraint(equalTo: spur.bottomAnchor),
                fuellung.widthAnchor.constraint(equalToConstant: LIMIT_BALKEN_BREITE * anteil),
            ])

            let reset = l.resetsAt > 0 ? " · \(resetKurz(l.resetsAt, jetzt))" : ""
            let wert = NSTextField(labelWithString: "\(l.prozent) %" + reset)
            wert.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
            wert.textColor = farbe(limitFarbe(l)).withAlphaComponent(0.9)

            let reihe = NSStackView(views: [name, spur, wert])
            reihe.orientation = .horizontal
            reihe.alignment = .centerY
            reihe.spacing = 6
            zeilen.append(reihe)
        }
        let spalte = NSStackView(views: zeilen)
        spalte.orientation = .vertical
        spalte.alignment = .leading
        spalte.spacing = 1
        spalte.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(spalte)
        NSLayoutConstraint.activate([
            spalte.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
            spalte.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
            spalte.topAnchor.constraint(equalTo: box.topAnchor, constant: 3),
            spalte.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -3),
        ])

        let df = DateFormatter(); df.dateFormat = "HH:mm"
        var hinweis = "Nutzungslimits des Abos (dieselben Werte wie /usage in Claude Code)"
        for l in st.limits {
            hinweis += "\n\(limitLang(l)): \(l.prozent) % verbraucht"
            if l.resetsAt > 0 {
                hinweis += ", Zurücksetzung \(resetKurz(l.resetsAt, jetzt)) (\(restDauer(l.resetsAt, jetzt)))"
            }
        }
        if st.geholt > 0 {
            hinweis += "\nStand \(df.string(from: Date(timeIntervalSince1970: TimeInterval(st.geholt))))"
                + ", Abfrage alle \(LIMIT_TAKT / 60) min"
        }
        if !st.fehler.isEmpty { hinweis += "\nLetzte Abfrage fehlgeschlagen: \(st.fehler)" }
        setzeHinweis(box, hinweis)
        return box
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 30),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.delegate = self

        let hintergrund = HintergrundView()
        hintergrund.wantsLayer = true
        hintergrund.layer?.backgroundColor =
            NSColor(calibratedWhite: 0.11, alpha: 0.92).cgColor
        hintergrund.layer?.cornerRadius = 9

        stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 7, bottom: 5, right: 7)
        stack.translatesAutoresizingMaskIntoConstraints = false
        hintergrund.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: hintergrund.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: hintergrund.trailingAnchor),
            stack.topAnchor.constraint(equalTo: hintergrund.topAnchor),
            stack.bottomAnchor.constraint(equalTo: hintergrund.bottomAnchor),
        ])
        panel.contentView = hintergrund

        aktualisiere()
        panel.orderFrontRegardless()
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.aktualisiere()
        }
    }

    /// Feld mit zwei Zeilen (Titel, Verbrauch) und wahlweise dem Modell-Chip darunter.
    /// Der Hinweistext muss auf allen Teilflächen liegen — sonst erscheint er nicht,
    /// sobald die Maus über der Schrift statt über dem Rand steht.
    func zweiZeilenFeld(_ box: NSView, titel: String, zeile: String,
                        bg: String, fg: String, hinweis: String,
                        chip: NSView? = nil, stern: NSView? = nil,
                        zeit: NSTextField? = nil, balken: NSView? = nil) -> NSView {
        box.wantsLayer = true
        box.layer?.backgroundColor = farbe(bg).cgColor
        box.layer?.cornerRadius = 6

        let text = NSTextField(labelWithString: titel)
        text.font = .systemFont(ofSize: 11.5, weight: .semibold)
        text.textColor = farbe(fg)
        text.lineBreakMode = .byTruncatingTail

        let verbrauch = NSTextField(labelWithString: zeile)
        verbrauch.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        verbrauch.textColor = farbe(fg).withAlphaComponent(0.8)
        verbrauch.lineBreakMode = .byTruncatingTail

        var zeilen: [NSView] = [text, verbrauch]
        if chip != nil || zeit != nil {
            let reihe = NSStackView(views: [chip, zeit].compactMap { $0 })
            reihe.orientation = .horizontal
            reihe.alignment = .centerY
            reihe.spacing = 5
            zeilen.append(reihe)
        }
        let spalte = NSStackView(views: zeilen)
        spalte.orientation = .vertical
        spalte.alignment = .leading
        spalte.spacing = 1
        spalte.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(spalte)
        NSLayoutConstraint.activate([
            spalte.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
            spalte.topAnchor.constraint(equalTo: box.topAnchor, constant: 3),
            spalte.bottomAnchor.constraint(
                equalTo: box.bottomAnchor,
                constant: balken == nil ? -3 : -(CACHE_BALKEN_HOEHE + 2 * CACHE_BALKEN_LUFT)),
            text.widthAnchor.constraint(lessThanOrEqualToConstant: 140),
        ])
        // Der Balken bekommt unten einen eigenen Streifen mit Luft darunter,
        // damit er auch bei einer einzelnen schmalen Kachel gut sichtbar ist
        if let balken = balken {
            balken.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(balken)
            NSLayoutConstraint.activate([
                balken.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 6),
                balken.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -6),
                balken.bottomAnchor.constraint(equalTo: box.bottomAnchor,
                                               constant: -CACHE_BALKEN_LUFT),
                balken.heightAnchor.constraint(equalToConstant: CACHE_BALKEN_HOEHE),
            ])
        }
        if let stern = stern {
            stern.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(stern)
            NSLayoutConstraint.activate([
                spalte.trailingAnchor.constraint(equalTo: stern.leadingAnchor, constant: -2),
                stern.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -3),
                stern.topAnchor.constraint(equalTo: box.topAnchor, constant: 1),
            ])
        } else {
            spalte.trailingAnchor.constraint(equalTo: box.trailingAnchor,
                                             constant: -8).isActive = true
        }

        var flaechen: [NSView] = [box, spalte, text, verbrauch]
        if let chip = chip { flaechen += [chip] + chip.subviews }
        if let zeit = zeit { flaechen.append(zeit) }
        for teil in flaechen { teil.toolTip = hinweis }
        return box
    }

    func feld(_ s: Sitzung) -> NSView {
        let c = FARBEN[s.state] ?? ["bg": "#888888", "fg": "#FFFFFF"]
        let box = FeldView()
        box.sessionId = s.id
        let jetzt = Int(Date().timeIntervalSince1970)
        let rest = cacheRest(s, jetzt)

        let df = DateFormatter(); df.dateFormat = "HH:mm"
        let seit = df.string(from: Date(timeIntervalSince1970: TimeInterval(s.started)))
        let t = s.tokens
        let modell = s.modelle.isEmpty ? "unbekanntes Modell" : s.modelle.joined(separator: ", ")
        let m = modellTeile(s.modellRoh)
        let denkstufe = EFFORT_TEXT[s.effort] ?? (s.effort.isEmpty ? "unbekannt" : s.effort)
        let modellZeile = m.lang.isEmpty
            ? "Modell noch unbekannt (erste Antwort abwarten)"
            : "Aktuell: \(m.lang) · Denkstufe \(denkstufe)"
        let ruhtZusatz = s.ruht ? " · ruht (von Hand markiert)" : ""
        let cacheHinweis = rest == nil ? "" : """

            Cache-Frist \(fristKurz(s.cacheTtl)) ab der letzten Antwort — der Balken \
            unten läuft ab. Danach muss der ganze Verlauf neu in den Cache \
            geschrieben werden (teurer als ein Cache-Treffer).
            """
        let hinweis = """
            \(s.label): \(ZUSTAND_TEXT[s.state] ?? s.state)\(ruhtZusatz)
            \(modellZeile)
            seit \(seit) · \(s.cwd)
            Tokens gesamt \(tokenKurz(t.gesamt)) — Eingabe \(tokenKurz(t.eingabe)) · \
            Cache-Aufbau \(tokenKurz(t.cacheAufbau)) · Cache-Lesen \(tokenKurz(t.cacheLesen)) · \
            Ausgabe \(tokenKurz(t.ausgabe))
            Über die API hätte das \(geldKurz(s.kostenUSD)) gekostet \
            (\(modell), US-Listenpreis)
            Klick holt das Terminal nach vorn · Stern rechts oben legt sie schlafen
            """
        // Umschalten erst im nächsten Durchlauf: der Klick läuft noch, während
        // die Anzeige die Kachel schon neu baut
        let stern = sternAnsicht(s, fg: c["fg"]!) { [weak self] in
            DispatchQueue.main.async {
                schalteRuht(s.id)
                self?.letzterStand = ""
                self?.aktualisiere()
            }
        }
        var zeit: NSTextField? = nil
        var balken: NSView? = nil
        if let rest = rest {
            let vg = farbe(c["fg"]!)
            let label = NSTextField(labelWithString: cacheZeile(rest))
            label.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
            label.textColor = vg.withAlphaComponent(0.9)
            let spur = NSView()
            spur.wantsLayer = true
            spur.layer?.backgroundColor = vg.withAlphaComponent(0.22).cgColor
            spur.layer?.cornerRadius = CACHE_BALKEN_HOEHE / 2
            let fuellung = CALayer()
            fuellung.backgroundColor = vg.withAlphaComponent(0.8).cgColor
            fuellung.cornerRadius = CACHE_BALKEN_HOEHE / 2
            spur.layer?.addSublayer(fuellung)
            uhren[s.id] = Uhr(spur: spur, fuellung: fuellung, label: label, fg: vg)
            zeit = label
            balken = spur
        }
        let ansicht = zweiZeilenFeld(box, titel: s.label, zeile: verbrauchsZeile(s),
                                     bg: c["bg"]!, fg: c["fg"]!, hinweis: hinweis + cacheHinweis,
                                     chip: chipAnsicht(s), stern: stern,
                                     zeit: zeit, balken: balken)
        // Ruhende Sitzung tritt zurück, behält aber ihre Zustandsfarbe
        ansicht.alphaValue = s.ruht ? 0.5 : 1.0
        return ansicht
    }

    /// Feld ganz rechts: Summe über alle sichtbaren Sitzungen.
    func summenFeld(_ liste: [Sitzung]) -> NSView {
        let g = gesamtSumme(liste)
        let t = g.tokens
        let hinweis = """
            Summe über \(liste.count) Sitzungen
            Tokens gesamt \(tokenKurz(t.gesamt)) — Eingabe \(tokenKurz(t.eingabe)) · \
            Cache-Aufbau \(tokenKurz(t.cacheAufbau)) · Cache-Lesen \(tokenKurz(t.cacheLesen)) · \
            Ausgabe \(tokenKurz(t.ausgabe))
            Über die API hätte das \(geldKurz(g.usd)) gekostet (US-Listenpreis, bezahlt wird das Abo)
            Dauersummen je Projekt: Tokenkosten.md im Projekt Claude Verlaufsanzeige
            """
        return zweiZeilenFeld(NSView(), titel: "Summe",
                              zeile: verbrauchsZeile(tokens: t.gesamt, usd: g.usd,
                                                     geschaetzt: g.geschaetzt),
                              bg: SUMME_BG, fg: SUMME_FG, hinweis: hinweis)
    }

    /// Ein Projekt mit mehreren Terminals: die Felder untereinander, eng gestapelt.
    /// Der kleine Innenabstand gegen den großen Abstand zwischen den Projekten
    /// macht den Block als Einheit lesbar — ohne zusätzlichen Rahmen.
    func gruppenSpalte(_ gruppe: [Sitzung]) -> NSView {
        let spalte = NSStackView(views: gruppe.map { feld($0) })
        spalte.orientation = .vertical
        spalte.alignment = .width   // alle Felder des Projekts gleich breit
        spalte.spacing = 2
        return spalte
    }

    /// Läuft jede Sekunde: setzt Restzeit und Balkenlänge, ohne die Kachel neu
    /// zu bauen. Bewusst getrennt vom Neuaufbau — sonst flackerte die Anzeige.
    func zieheUhrenNach(_ sitzungen: [Sitzung]) {
        guard !uhren.isEmpty else { return }
        let jetzt = Int(Date().timeIntervalSince1970)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for s in sitzungen {
            guard let u = uhren[s.id], let rest = cacheRest(s, jetzt) else { continue }
            let anteil = cacheAnteil(s, rest)
            let knapp = anteil <= CACHE_WARNUNG
            u.label.stringValue = cacheZeile(rest)
            u.label.textColor = u.fg.withAlphaComponent(knapp ? 1.0 : 0.9)
            let b = u.spur.bounds
            u.fuellung.frame = CGRect(x: 0, y: 0, width: b.width * anteil, height: b.height)
            u.fuellung.backgroundColor = u.fg.withAlphaComponent(knapp ? 1.0 : 0.8).cgColor
        }
        CATransaction.commit()
    }

    func aktualisiere() {
        frageLimitsAb()
        let sitzungen = ladeSitzungen()
        let jetzt = Int(Date().timeIntervalSince1970)
        let limitKennung = limitStand.limits
            .map { "\($0.name)=\($0.prozent)/\(resetKurz($0.resetsAt, jetzt))" }
            .joined(separator: ",")
            + "|\(limitStand.fehler)|\(limitStand.geholt > 0 && jetzt - limitStand.geholt > LIMIT_VERALTET)"
        let stand = limitKennung + "#" + sitzungen
            .map {
                "\($0.id)|\($0.gruppe)|\($0.label)|\($0.state)|\($0.ruht)|"
                    + "\(verbrauchsZeile($0))|\(chipZeile($0))|"
                    + "\(cacheRest($0, jetzt) != nil)"
            }
            .joined(separator: ";")
        if stand == letzterStand {
            zieheUhrenNach(sitzungen)
            return
        }
        letzterStand = stand

        uhren.removeAll()
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stack.addArrangedSubview(limitFeld(limitStand, jetzt: jetzt))
        if sitzungen.isEmpty {
            let leer = NSTextField(labelWithString: "keine Sitzungen")
            leer.font = .systemFont(ofSize: 11)
            leer.textColor = NSColor(calibratedWhite: 0.75, alpha: 1)
            stack.addArrangedSubview(leer)
        } else {
            for block in gruppiere(sitzungen) {
                stack.addArrangedSubview(
                    block.count == 1 ? feld(block[0]) : gruppenSpalte(block))
            }
            // Bei einer einzigen Sitzung wäre die Summe nur eine Dublette
            if sitzungen.count > 1 { stack.addArrangedSubview(summenFeld(sitzungen)) }
        }
        platziere()
        zieheUhrenNach(sitzungen)
    }

    // Fenster an der rechten oberen Ecke verankern: wächst nach links
    func platziere() {
        panel.layoutIfNeeded()
        let groesse = panel.contentView!.fittingSize
        guard let schirm = NSScreen.main else { return }
        let sicht = schirm.visibleFrame
        var ankerX = ablage.double(forKey: "ampelAnkerX")
        var ankerY = ablage.double(forKey: "ampelAnkerY")
        if ankerX == 0 && ankerY == 0 {
            ankerX = sicht.maxX - 10
            ankerY = sicht.maxY - 4
        }
        ankerX = min(max(ankerX, sicht.minX + groesse.width), sicht.maxX)
        ankerY = min(max(ankerY, sicht.minY + groesse.height), sicht.maxY)
        panel.setFrame(
            NSRect(x: ankerX - groesse.width, y: ankerY - groesse.height,
                   width: groesse.width, height: groesse.height),
            display: true)
    }

    func windowDidMove(_ note: Notification) {
        ablage.set(panel.frame.maxX, forKey: "ampelAnkerX")
        ablage.set(panel.frame.maxY, forKey: "ampelAnkerY")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
