import Cocoa
import CoreText

// MARK: - Models (specchia GET :3337/api/overview)

struct Overview: Codable {
    let providers: [Provider]
    let renewals: [Renewal]
    let credit: CloudCredit?
    let credits: [String: CloudCredit]?
}

struct CloudCredit: Codable {
    let remaining: Double?
    let limit: Double?
    let used: Double?
    let renewsAt: String?
    let account: String?
    let unavailable: Bool?
    let nobonus: Bool?
    let stale: Bool?
    let asOf: Int?
    let reason: String?
}

// Età di un dato stantio: "dato di 5m fa", "dato di 2h fa" (stessa dicitura
// del dato vecchio di Muse lato server). Mai il futuro (orologi storti).
func staleAge(_ asOf: Int, now: Date = Date()) -> String {
    let mins = max(0, Int(now.timeIntervalSince1970) - asOf) / 60
    return mins < 60 ? "dato di \(mins)m fa" : "dato di \(mins / 60)h fa"
}

struct Provider: Codable {
    let id: String
    let name: String
    let error: String?
    let accounts: [Account]?
    let menuOnly: Bool?
    let billing: String?
}

struct Account: Codable {
    let id: String
    let label: String
    let code: String
    let active: Bool
    let status: String
    let quotas: [Quota]
    // Reset manuali disponibili: nil = ignoti (Claude, promo senza API),
    // mai zero inventato. Il server vecchio non la manda: resta nil.
    let resetCredits: ResetCredits?
    // Speso API Anthropic dell'org di questo account (solo guedado):
    // riga a consumo sotto le quote, mai in barra. Nil = sonda giù.
    let apiSpend: Quota?
}

// available fa fede (la lista può essere cappata); solo gli available.
struct ResetCredits: Codable {
    let available: Int
    let credits: [ResetCredit]?
}

struct ResetCredit: Codable {
    let title: String?
    let expiresAt: Int?
}

struct Quota: Codable {
    let key: String
    let usedPct: Int
    let resetsAt: Int?
    let resetText: String
    let status: String
    let detail: String?
    // Testo lungo per il tooltip (es. credito API: speso su concesso e ora
    // di lettura). Il server vecchio non la manda: resta nil.
    let note: String?
}

struct Renewal: Codable {
    let service: String
    let account: String
    let amount: String
    let cycle: String
    let renewsAt: String?
    let note: String
    let provider: String?
    let tray: Bool?
}

func statusColor(_ s: String) -> NSColor {
    switch s {
    case "ok": return NSColor(red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255, alpha: 1)
    case "warning": return .systemOrange
    case "critical", "depleted": return .systemRed
    default: return .secondaryLabelColor
    }
}

// Testo con baseline ESATTA: NSString.draw(at:) sposta tutto di ~+2.4pt
// rispetto alla y data (misurato sull'inchiostro il 2026-10-07), rendendo
// inutile qualsiasi centratura calcolata. CoreText no: textPosition = baseline.
func drawBaseline(_ s: String, x: CGFloat, baseline y: CGFloat,
                  font: NSFont, color: NSColor, shadow: Bool = false) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: s, attributes: [.font: font,
                                                   .foregroundColor: color]))
    ctx.saveGState()
    if shadow {
        ctx.setShadow(offset: CGSize(width: 0, height: -0.5), blur: 1,
                      color: NSColor.black.withAlphaComponent(0.75).cgColor)
    }
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

// MARK: - Menubar view: una colonna per account, quote impilate
//
// Header con mini-logo del provider + email, sotto le quote in colonna
// (5h sopra, 7d sotto): tag finestra, barra (= quota usata), %, reset.
// Tutti i testi bianchi, sempre: i grigi su questa barra non si leggono.

class UsageBarView: NSView {
    var snapshot: Overview?
    var isOffline = false

    // Tre righe intere: mail 7pt + 5H + 7D. Icona 8px a x0 come le righe
    // (15..23, cima flush col top caps), mail rientrata dopo l'icona.
    // Tag maiuscoli 7pt (top 13.5): i gambetti di h/d toccherebbero l'icona.
    private let headerFont = NSFont.systemFont(ofSize: 7, weight: .semibold)
    private let headerBaseline: CGFloat = 17
    private let iconSize: CGFloat = 8
    private let iconY: CGFloat = 15
    private let iconIndent: CGFloat = 11
    private let tagFont = NSFont.monospacedSystemFont(ofSize: 7, weight: .semibold)
    private let tagBaselineShift: CGFloat = -0.5   // top 13.5, aria dall'icona
    private let pctFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .bold)
    private let timeFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
    private let rowTopBaseline: CGFloat = 9    // prima quota (5h)
    private let rowBotBaseline: CGFloat = 1    // seconda quota (7d)
    private let barW: CGFloat = 20      // minimo utile: il numero dà la precisione
    private let barH: CGFloat = 6
    private let pctW: CGFloat = 22      // "100%" fissa: al cambio cifra niente salta
    private let gap: CGFloat = 2
    private let timeGap: CGFloat = 3
    private let acctGap: CGFloat = 6    // uguale ovunque: niente separatori
    private let padX: CGFloat = 4

    private func flat() -> [(Provider, Account)] {
        var out: [(Provider, Account)] = []
        for p in snapshot?.providers ?? [] {
            if p.menuOnly == true { continue }
            for a in p.accounts ?? [] { out.append((p, a)) }
        }
        return out
    }

    private func quotaWidth(_ q: Quota) -> CGFloat {
        let tagW = (q.key.uppercased() as NSString).size(withAttributes: [.font: tagFont]).width
        let timeW = (q.resetText as NSString).size(withAttributes: [.font: timeFont]).width
        return tagW + gap + barW + gap + pctW + timeGap + timeW
    }

    // Email maiuscola, croppata con … oltre cap. Stessa stringa in
    // layout e disegno: si calcola qui una volta sola per cella.
    private func cropEmail(_ s: String, cap: CGFloat) -> String {
        let up = s.uppercased()
        let attrs: [NSAttributedString.Key: Any] = [.font: headerFont]
        if (up as NSString).size(withAttributes: attrs).width <= cap { return up }
        var t = up
        while t.count > 6,
              (t + "…" as NSString).size(withAttributes: attrs).width > cap {
            t.removeLast()
        }
        return t + "…"
    }

    // Badge testata: " ↻N" solo con reset manuali disponibili. Zero o
    // ignoti (Claude) = niente: la barra resta pulita, il menu dice tutto.
    private func resetBadge(_ a: Account) -> String {
        let n = a.resetCredits?.available ?? 0
        return n > 0 ? " ↻\(n)" : ""
    }

    // Un solo passaggio di layout per misura e disegno: niente derive tra i due.
    private struct AcctFrame {
        let acct: Account
        let header: String
        let badge: String
        let x: CGFloat
        let w: CGFloat
    }
    private struct GroupFrame {
        let prov: Provider
        let x: CGFloat
        let w: CGFloat
        let accts: [AcctFrame]
    }

    private func layout() -> (groups: [GroupFrame], width: CGFloat) {
        var groups: [GroupFrame] = []
        var x = padX
        for p in snapshot?.providers ?? [] {
            if p.menuOnly == true { continue }
            let accs = p.accounts ?? []
            if accs.isEmpty { continue }
            let gx = x
            var frames: [AcctFrame] = []
            for a in accs {
                // larghezza = riga quota più larga; la mail si taglia a misura,
                // mai oltre. Le righe non si tagliano mai. Il badge non si taglia:
                // ruba spazio alla mail, non alle righe.
                let badge = resetBadge(a)
                let badgeW = (badge as NSString).size(withAttributes: [.font: headerFont]).width
                let qw = a.quotas.prefix(2).map { quotaWidth($0) }.max() ?? 0
                let header = cropEmail(a.label, cap: max(30, qw - iconIndent - badgeW))
                let hw = iconIndent
                    + (header as NSString).size(withAttributes: [.font: headerFont]).width
                    + badgeW
                let cw = max(hw, qw)
                frames.append(AcctFrame(acct: a, header: header, badge: badge, x: x, w: cw))
                x += cw + acctGap
            }
            x -= acctGap
            groups.append(GroupFrame(prov: p, x: gx, w: x - gx, accts: frames))
            x += acctGap
        }
        if !groups.isEmpty { x -= acctGap }
        return (groups, x + padX)
    }

    func idealWidth() -> CGFloat {
        if isOffline || flat().isEmpty { return 26 }
        return layout().width
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()
        if isOffline || flat().isEmpty {
            let s = "···" as NSString
            s.draw(at: NSPoint(x: 6, y: 4), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.white,
            ])
            return
        }
        let (groups, _) = layout()
        for g in groups {
            for f in g.accts {
                let a = f.acct
                // non attivo: barre dimezzate, testi quasi pieni (devono leggersi)
                let barDim: CGFloat = a.active ? 1 : 0.45
                let txtDim: CGFloat = a.active ? 1 : 0.8
                let white = NSColor.white.withAlphaComponent(txtDim)
                // -1px: l'inchiostro parte dentro il rettangolo, così il bordo
                // vivo dell'icona cade sulla stessa x delle righe (misurato).
                barIcon(g.prov.id, sizePt: iconSize)
                    .draw(in: NSRect(x: f.x - 1, y: iconY, width: iconSize, height: iconSize))
                drawBaseline(f.header, x: f.x + iconIndent, baseline: headerBaseline,
                             font: headerFont, color: white, shadow: true)
                if !f.badge.isEmpty {
                    let hw = (f.header as NSString).size(withAttributes: [.font: headerFont]).width
                    drawBaseline(f.badge, x: f.x + iconIndent + hw, baseline: headerBaseline,
                                 font: headerFont, color: white, shadow: true)
                }
                // due righe quota: 5H sopra, 7D sotto (o una sola se unica).
                // Partono a x0 come l'icona: niente gutter dedicato.
                let rows = a.quotas.prefix(2)
                for (ri, q) in rows.enumerated() {
                    let base = ri == 0 ? rowTopBaseline : rowBotBaseline
                    var cx = f.x
                    let tag = q.key.uppercased()
                    let tagW = (tag as NSString).size(withAttributes: [.font: tagFont]).width
                    drawBaseline(tag, x: cx, baseline: base + tagBaselineShift,
                                 font: tagFont, color: white, shadow: true)
                    cx += tagW + gap
                    // base+0: la barra centra il corpo dei numeri (base..+6.5),
                    // non galleggia sopra (base+1 la alzava di 1px).
                    let barRect = NSRect(x: cx, y: base, width: barW, height: barH)
                    NSColor.white.withAlphaComponent(0.22 * barDim).setFill()
                    NSBezierPath(roundedRect: barRect, xRadius: 2.5, yRadius: 2.5).fill()
                    let fw = barW * min(100, max(0, q.usedPct)).double / 100
                    if fw > 0.5 {
                        NSGraphicsContext.saveGraphicsState()
                        NSBezierPath(roundedRect: barRect, xRadius: 2.5, yRadius: 2.5).setClip()
                        statusColor(q.status).withAlphaComponent(barDim).setFill()
                        NSRect(x: barRect.minX, y: barRect.minY, width: fw, height: barH).fill()
                        NSGraphicsContext.restoreGraphicsState()
                    }
                    cx += barW + gap
                    // % nel colore di stato quando c'è un problema: l'occhio ci va da solo
                    let pctColor: NSColor = q.status == "ok"
                        ? white : statusColor(q.status).withAlphaComponent(txtDim)
                    let pct = "\(q.usedPct)%"
                    let pw = (pct as NSString).size(withAttributes: [.font: pctFont]).width
                    drawBaseline(pct, x: cx + (pctW - pw) / 2, baseline: base,
                                 font: pctFont, color: pctColor, shadow: true)
                    cx += pctW + timeGap
                    drawBaseline(q.resetText, x: cx, baseline: base,
                                 font: timeFont, color: white, shadow: true)
                }
            }
        }
    }
}

private extension Int {
    var double: CGFloat { CGFloat(self) }
}

// MARK: - Menu rows

private let menuW: CGFloat = 440

// Griglia unica del menu: ogni riga sotto un account usa queste colonne,
// così tag, barre, % e testi cadono sulla stessa x in tutto il menu.
//   lead │ TAG (46) │ barra (barW) │ % (38, a destra) │ dettaglio (170)
// Le x si ricavano l'una dall'altra, non si scrivono a mano: una sola
// larghezza di barra per quote, API, bonus e hub. Larghezze misurate coi
// font qui sotto (+ ~4pt di padding di NSTextField): "BONUS" 40.3,
// "100%" 32.9, dettaglio più lungo "€109.89/mese · rinnova 06/11" 153.
enum MenuGrid {
    static let lead: CGFloat = 38                       // = email account e nome sezione
    static let tagW: CGFloat = 46
    static let barX: CGFloat = lead + tagW + 4          // 88
    static let right: CGFloat = menuW - 16              // 424
    static let detailW: CGFloat = 170
    static let detailX: CGFloat = right - detailW       // 254
    static let pctW: CGFloat = 38
    static let pctX: CGFloat = detailX - 8 - pctW       // 208
    static let barW: CGFloat = pctX - 4 - barX          // 116
    static let barH: CGFloat = 8
    static let rowH: CGFloat = 22
    static let textY: CGFloat = 3
    static let textH: CGFloat = 16
    static let tagFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    // cifre tabulari: "79%" e "100%" finiscono sullo stesso bordo
    static let pctFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    static let detailFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
    static let labelFont = NSFont.systemFont(ofSize: 10.5)
}

// Soglie identiche a statusFor() del server: un colore, un significato.
func usageStatus(_ pct: Int) -> String {
    if pct >= 100 { return "depleted" }
    if pct >= 95 { return "critical" }
    if pct >= 80 { return "warning" }
    return "ok"
}

// Rapporto → percentuale intera, limitata: un tetto minuscolo non deve
// mandare in overflow Int() (crash), la % resta comunque "oltre 100".
func pctInt(_ ratio: Double) -> Int {
    Int(min(9999, max(-9999, (ratio * 100).rounded())))
}

// Soldi col segno prima del simbolo: "-$12.50", mai "$-12.50" (né "-$0.00").
func money(_ v: Double, decimals: Int = 2) -> String {
    let s = String(format: "$%.\(decimals)f", abs(v))
    let zero = String(format: "$%.\(decimals)f", 0.0)
    return v < 0 && s != zero ? "-" + s : s
}

private func gridLabel(_ text: String, x: CGFloat, w: CGFloat, font: NSFont,
                       color: NSColor, align: NSTextAlignment = .left) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = font
    l.textColor = color
    l.alignment = align
    l.lineBreakMode = .byTruncatingTail
    l.frame = NSRect(x: x, y: MenuGrid.textY, width: w, height: MenuGrid.textH)
    return l
}

// Riga metrica: TAG · barra · % · dettaglio. Tutte le barre del menu passano
// da qui (quote, API, bonus, hub): stessa x, stessa larghezza. Barra e %
// dicono sempre il CONSUMATO: piena e rossa = finito, ovunque.
// ratio nil = rapporto ignoto (niente tetto, saldo assente): niente barra
// e "—", mai uno 0% inventato. Solo viste layer-backed, niente draw custom:
// si renderizza anche offscreen (--snapshot).
func metricRow(tag: String, ratio: Double?, status: String, detail: String,
               detailColor: NSColor = .secondaryLabelColor, tooltip: String? = nil) -> NSMenuItem {
    let g = MenuGrid.self
    let ratio = ratio.flatMap { $0.isFinite ? $0 : nil }
    let view = NSView(frame: NSRect(x: 0, y: 0, width: menuW, height: g.rowH))
    view.addSubview(gridLabel(tag, x: g.lead, w: g.tagW, font: g.tagFont, color: .labelColor))
    if let r = ratio {
        let track = NSView(frame: NSRect(x: g.barX, y: (g.rowH - g.barH) / 2,
                                         width: g.barW, height: g.barH))
        track.wantsLayer = true
        track.layer?.cornerRadius = g.barH / 2
        track.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        // oltre il 100% la barra resta piena: il numero vero lo dice la %
        let fw = (g.barW * CGFloat(min(1, max(0, r)))).rounded()
        if fw >= 1 {
            // mai più stretto che alto: un consumo minimo resta un pallino
            let fill = NSView(frame: NSRect(x: 0, y: 0, width: max(fw, g.barH), height: g.barH))
            fill.wantsLayer = true
            fill.layer?.cornerRadius = g.barH / 2
            fill.layer?.backgroundColor = statusColor(status).cgColor
            track.addSubview(fill)
        }
        view.addSubview(track)
    }
    // % nel colore di stato quando c'è un problema, come nella barra
    let pctText = ratio.map { "\(pctInt($0))%" } ?? "—"
    let pctColor: NSColor = ratio == nil ? .tertiaryLabelColor
        : status == "ok" ? .labelColor : statusColor(status)
    view.addSubview(gridLabel(pctText, x: g.pctX, w: g.pctW, font: g.pctFont,
                              color: pctColor, align: .right))
    view.addSubview(gridLabel(detail, x: g.detailX, w: g.detailW, font: g.detailFont,
                              color: detailColor))
    let item = NSMenuItem()
    item.view = view
    item.toolTip = tooltip
    return item
}

// Riga di testo (abbonamento, reset manuali, buchi): etichetta sotto
// TAG + barra, valore nella STESSA colonna dettaglio delle righe metriche.
func textRow(_ label: String, detail: String, labelColor: NSColor = .secondaryLabelColor,
             detailColor: NSColor = .secondaryLabelColor, tooltip: String? = nil) -> NSMenuItem {
    let g = MenuGrid.self
    let view = NSView(frame: NSRect(x: 0, y: 0, width: menuW, height: g.rowH))
    view.addSubview(gridLabel(label, x: g.lead, w: g.detailX - 8 - g.lead, font: g.labelFont,
                              color: labelColor))
    view.addSubview(gridLabel(detail, x: g.detailX, w: g.detailW, font: g.detailFont,
                              color: detailColor))
    let item = NSMenuItem()
    item.view = view
    item.toolTip = tooltip
    return item
}

func headerRow(_ text: String) -> NSMenuItem {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: menuW, height: 20))
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: 10, weight: .semibold)
    label.textColor = .secondaryLabelColor
    label.frame = NSRect(x: 16, y: 3, width: 300, height: 15)
    view.addSubview(label)
    let item = NSMenuItem()
    item.view = view
    return item
}

// Sezione provider: tile con l'icona del brand + nome. Senza icona
// (altri account) il testo resta allineato alla stessa colonna.
func sectionRow(_ text: String, providerId: String?) -> NSMenuItem {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: menuW, height: 26))
    if let id = providerId {
        let icon = NSImageView(frame: NSRect(x: 14, y: 4, width: 18, height: 18))
        icon.image = providerIcon(id)
        view.addSubview(icon)
    }
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: 12, weight: .semibold)
    label.textColor = .labelColor
    label.frame = NSRect(x: MenuGrid.lead, y: 4, width: MenuGrid.right - MenuGrid.lead, height: 18)
    view.addSubview(label)
    let item = NSMenuItem()
    item.view = view
    return item
}

// Data compatta per le righe Abbonamento/Bonus: "2026-11-06" → "06/11".
func dayMonth(_ iso: String) -> String {
    let parts = iso.split(separator: "-")
    guard parts.count == 3, let m = Int(parts[1]), (1...12).contains(m),
          let d = Int(parts[2]), (1...31).contains(d) else { return iso }
    return String(format: "%02d/%02d", d, m)
}

// Account: pallino di stato + email su tutta la riga. Niente riepilogo a
// destra: era il doppione della riga quota peggiore subito sotto, e fuori
// griglia (allineato a destra, formato suo).
func accountRow(_ a: Account) -> NSMenuItem {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: menuW, height: 26))
    let dot = NSView(frame: NSRect(x: 19, y: 9, width: 8, height: 8))
    dot.wantsLayer = true
    dot.layer?.cornerRadius = 4
    dot.layer?.backgroundColor = statusColor(a.status).cgColor
    view.addSubview(dot)
    let label = NSTextField(labelWithString: a.label)
    label.font = .systemFont(ofSize: 12, weight: a.active ? .semibold : .regular)
    label.textColor = .labelColor
    label.frame = NSRect(x: MenuGrid.lead, y: 4, width: MenuGrid.right - MenuGrid.lead, height: 18)
    label.lineBreakMode = .byTruncatingTail
    view.addSubview(label)
    let item = NSMenuItem()
    item.view = view
    item.toolTip = a.id
    return item
}

// Riga quota (5H/7D): ↻ solo davanti a un tempo di reset vero; il dato
// vecchio (Muse: "dato di 48m fa") resta senza freccia, in grigio.
func quotaBarRow(_ q: Quota) -> NSMenuItem {
    let stale = q.status == "stale"
    let detail = q.resetText.isEmpty ? "" : stale ? q.resetText : "↻ \(q.resetText)"
    return metricRow(tag: q.key.uppercased(), ratio: Double(q.usedPct) / 100,
                     status: q.status, detail: detail,
                     detailColor: stale ? .tertiaryLabelColor : .secondaryLabelColor)
}

// Credito API (promo Anthropic): barra = speso su concesso, come il bonus.
// Il server manda il saldo ("$X rimasti"), la tray aggiunge la scadenza da
// resetsAt: è una scadenza, non un reset, quindi niente ↻. Speso, concesso
// e ora di lettura nel tooltip (note).
func apiBarRow(_ q: Quota) -> NSMenuItem {
    var detail = q.detail ?? ""
    if let at = q.resetsAt {
        detail += (detail.isEmpty ? "" : " · ") + "scade \(dayMonthEpoch(at))"
    }
    return metricRow(tag: "API", ratio: q.status == "unknown" ? nil : Double(q.usedPct) / 100,
                     status: q.status, detail: detail,
                     tooltip: q.note.map { "Credito API Anthropic: \($0)" })
}

// Riga hub (a consumo): stessa griglia, barra solo con un tetto vero
// (status "unknown" = spesa senza tetto: niente barra e "—").
func hubQuotaRow(_ q: Quota) -> NSMenuItem {
    var detail = q.detail ?? ""
    if !q.resetText.isEmpty { detail += (detail.isEmpty ? "" : " · ") + "↻ \(q.resetText)" }
    return metricRow(tag: q.key.uppercased(),
                     ratio: q.status == "unknown" ? nil : Double(q.usedPct) / 100,
                     status: q.status, detail: detail, tooltip: q.note)
}

// Riga Abbonamento: costo, non saldo. Nome del servizio intero ("Muse Code",
// non "Code"): niente prefissi tolti, si legge uguale sotto ogni provider.
// Il dettaglio resta tenue: è un promemoria, non un consumo.
func subscriptionRow(_ r: Renewal, accountLabels: Set<String> = []) -> NSMenuItem {
    // Gli account già elencati sopra non si ripetono.
    var text = "Abbonamento \(r.service)"
    if !r.account.isEmpty, r.account != r.service, !accountLabels.contains(r.account) {
        text += " — \(r.account)"
    }
    let detail: String
    switch r.cycle {
    case "mensile":
        detail = r.amount + "/mese"
            + (r.renewsAt.map { " · rinnova \(dayMonth($0))" } ?? "")
    case "annuale":
        detail = r.amount + "/anno"
            + (r.renewsAt.map { " · rinnova \(dayMonth($0))" } ?? "")
    case "una tantum":
        detail = "\(r.amount) una tantum"
    case "disdetto":
        detail = "disdetto" + (r.renewsAt.map { " · \(dayMonth($0))" } ?? "")
    default:
        detail = [r.amount, r.renewsAt.map { "↻ \(dayMonth($0))" } ?? "", r.cycle]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
    return textRow(text, detail: detail, detailColor: .tertiaryLabelColor,
                   tooltip: r.note.isEmpty ? nil : r.note)
}

// Epoch → "gg/mm" per le scadenze dei reset (dayMonth vuole ISO).
func dayMonthEpoch(_ epoch: Int) -> String {
    let f = DateFormatter()
    f.dateFormat = "dd/MM"
    return f.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
}

// Riga reset manuali: conteggio noto (anche zero), mai se ignoto
// (Claude: promo senza API → niente riga). Scadenza del primo disponibile.
func resetCreditRow(_ rc: ResetCredits) -> NSMenuItem {
    if rc.available == 0 {
        return textRow("Reset manuali", detail: "nessuno rimasto", detailColor: .tertiaryLabelColor)
    }
    let detail = "\(rc.available) disponibil" + (rc.available == 1 ? "e" : "i")
        + ((rc.credits ?? []).compactMap { $0.expiresAt }.min()
            .map { " · scade \(dayMonthEpoch($0))" } ?? "")
    return textRow("Reset manuali", detail: detail,
                   tooltip: (rc.credits ?? []).compactMap { $0.title }.first)
}

// Account live senza voce in renewals.json: il buco si vede, in grigio.
func unregisteredRow() -> NSMenuItem {
    textRow("Abbonamento", detail: "non registrato",
            labelColor: .tertiaryLabelColor, detailColor: .tertiaryLabelColor)
}

// Oltre questa età il saldo bonus si dichiara vecchio. Sotto è rumore: il
// server marca stale anche un dato di 5' (sonda in cache FRESH 15' + poll),
// quindi la soglia sta appena sopra un giro di aggiornamento saltato.
let creditStaleS = 1200

// ISO "2026-11-05" → fine di quel giorno (ora locale): scaduto solo dopo.
func endOfDay(_ iso: String) -> Date? {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    guard let d = f.date(from: iso) else { return nil }
    return Calendar.current.date(byAdding: .day, value: 1, to: d)
}

// Bonus cloud: riga metrica come le quote. Barra e % = usato su concesso
// (stesso verso di 5H/7D e API), dettaglio = saldo rimasto + scadenza; il
// resto nel tooltip. Senza saldo (429, token) la riga resta e dice perché:
// sparire e riapparire confonde più di un'attesa dichiarata.
func creditRow(_ c: CloudCredit, now: Date = Date()) -> NSMenuItem {
    guard let left = c.remaining else {
        let token = c.reason == "token"
        return metricRow(tag: "BONUS", ratio: nil, status: "unknown",
                         detail: token ? "token scaduto" : "in aggiornamento…",
                         detailColor: .tertiaryLabelColor,
                         tooltip: token ? "Bonus cloud Max: apri Claude Code per rinnovare il token"
                                        : "Bonus cloud Max: saldo in aggiornamento")
    }
    // Senza tetto noto niente rapporto: il saldo sì, una barra finta no.
    let limit = c.limit.flatMap { $0 > 0 ? $0 : nil }
    let used = c.used ?? limit.map { $0 - left }
    let ratio = limit.flatMap { l in used.map { $0 / l } }
    let nowS = Int(now.timeIntervalSince1970)
    let old = c.stale == true && (c.asOf.map { nowS - $0 >= creditStaleS } ?? false)
    let expired = c.renewsAt.flatMap(endOfDay).map { $0 <= now } ?? false
    // scaduto o vecchio: grigio come il dato vecchio di Muse, mai verde
    let status = expired ? "off" : old ? "stale"
        : ratio.map { usageStatus(pctInt($0)) } ?? "unknown"
    var detail = "\(money(left)) rimasti"
    if expired, let r = c.renewsAt {
        detail = "\(money(left)) · scaduto \(dayMonth(r))"
    } else if old, let at = c.asOf {
        detail += " · \(staleAge(at, now: now))"
    } else if let r = c.renewsAt {
        detail += " · scade \(dayMonth(r))"
    }
    var tip = "Bonus cloud Max: \(money(left)) rimasti"
    if let l = limit { tip += " su \(money(l, decimals: 0))" }
    if let u = used { tip += " · usati \(money(u))" }
    if let r = c.renewsAt { tip += (expired ? " · scaduto " : " · scade ") + dayMonth(r) }
    if let at = c.asOf { tip += " · \(staleAge(at, now: now))" }
    return metricRow(tag: "BONUS", ratio: ratio, status: status, detail: detail,
                     detailColor: expired || old ? .tertiaryLabelColor : .secondaryLabelColor,
                     tooltip: tip)
}

func emailRow(_ email: String) -> NSMenuItem {
    // Email solo-fattura (non un account live): intestazione tenue senza pallino.
    let view = NSView(frame: NSRect(x: 0, y: 0, width: menuW, height: 22))
    let label = NSTextField(labelWithString: email)
    label.font = .systemFont(ofSize: 11)
    label.textColor = .secondaryLabelColor
    label.frame = NSRect(x: MenuGrid.lead, y: 3, width: MenuGrid.right - MenuGrid.lead, height: 16)
    label.lineBreakMode = .byTruncatingTail
    view.addSubview(label)
    let item = NSMenuItem()
    item.view = view
    return item
}

// Rinnovi raggruppati per email con la sua intestazione; le righe
// auto-nominate (service == account) restano da sole senza intestazione.
// Qui tray:false resta nascosto: sotto gli account live si usa comunque.
func addGroupedRenewals(_ rows: [Renewal], baseLabels: Set<String>,
                        menu: NSMenu, shown: inout Set<String>) {
    let rows = rows.filter { $0.tray != false }
    var keys: [String] = []
    for r in rows where !shown.contains(r.service + "|" + r.account) {
        if !keys.contains(r.account) { keys.append(r.account) }
    }
    for k in keys {
        let rs = rows.filter { $0.account == k && !shown.contains($0.service + "|" + $0.account) }
        if rs.allSatisfy({ $0.service == $0.account }) {
            for r in rs {
                menu.addItem(subscriptionRow(r, accountLabels: baseLabels))
                shown.insert(r.service + "|" + r.account)
            }
        } else {
            menu.addItem(emailRow(k))
            for r in rs {
                menu.addItem(subscriptionRow(r, accountLabels: baseLabels.union([k])))
                shown.insert(r.service + "|" + r.account)
            }
        }
    }
}

func legendRow(_ text: String) -> NSMenuItem {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: menuW, height: 18))
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: 10)
    label.textColor = .tertiaryLabelColor
    label.frame = NSRect(x: 16, y: 3, width: menuW - 32, height: 15)
    view.addSubview(label)
    let item = NSMenuItem()
    item.view = view
    return item
}

// x = 16 per i messaggi del menu intero (offline); x = lead sotto una
// sezione provider, allineato agli account che sostituisce.
func infoRow(_ text: String, x: CGFloat = 16) -> NSMenuItem {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: menuW, height: 24))
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: 11)
    label.textColor = .secondaryLabelColor
    label.frame = NSRect(x: x, y: 4, width: menuW - 16 - x, height: 16)
    view.addSubview(label)
    let item = NSMenuItem()
    item.view = view
    return item
}

// MARK: - Menu (clic e snapshot usano la stessa costruzione)

// Mappa dei bonus per email: credits del server nuovo, o il singolo credit
// del server vecchio. Senza: nessun bonus da mostrare.
func creditMap(_ snapshot: Overview?) -> [String: CloudCredit] {
    if let cs = snapshot?.credits { return cs }
    if let c = snapshot?.credit, let email = c.account, !email.isEmpty {
        return [email: c]
    }
    return [:]
}

// Preferenze della tray (persistenti): quale fascia e quale extra mostrare.
enum TrayPrefs {
    static let d = UserDefaults.standard
    static var showDaily: Bool {
        get { d.object(forKey: "showDaily") as? Bool ?? true }
        set { d.set(newValue, forKey: "showDaily") }
    }
    static var showApi: Bool {
        get { d.object(forKey: "showApi") as? Bool ?? true }
        set { d.set(newValue, forKey: "showApi") }
    }
    static var showBonus: Bool {
        get { d.object(forKey: "showBonus") as? Bool ?? true }
        set { d.set(newValue, forKey: "showBonus") }
    }
}

func buildMenu(snapshot: Overview?, isOffline: Bool, actionTarget: AnyObject?) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.addItem(headerRow("Consumi"))
    if isOffline {
        menu.addItem(infoRow("⚡ Offline — usage-server :3337 non raggiungibile"))
    } else {
        menu.addItem(legendRow("Nella barra: 5H sopra, 7D sotto · % e tempo di reset per quota"))
        menu.addItem(legendRow("Account affievolito: non attivo · ↻: reset o rinnovo"))
        menu.addItem(legendRow("↻N in testata: reset manuali disponibili"))
        menu.addItem(legendRow("Nel menu: barra e % = consumato · a destra reset, saldo o scadenza"))
        let providers = snapshot?.providers ?? []
        let renewals = snapshot?.renewals ?? []
        let cmap = creditMap(snapshot)
        var shown = Set<String>()
        var bonusShown = Set<String>()
        for p in providers {
            menu.addItem(sectionRow(p.name, providerId: p.id))
            let accs = p.accounts ?? []
            // Sotto la sezione il nome del provider non si ripete.
            if let err = p.error {
                menu.addItem(infoRow(err, x: MenuGrid.lead))
            } else if accs.isEmpty {
                menu.addItem(infoRow("nessun account", x: MenuGrid.lead))
            }
            let labels = Set(accs.map { $0.label })
            // Claude: solo i rinnovi degli account live vdm; gli altri
            // finiscono tra gli orfani in Altro, senza perdersi.
            let pren = renewals.filter {
                $0.provider == p.id && (p.id != "claude" || labels.contains($0.account))
            }
            for a in accs {
                menu.addItem(accountRow(a))
                for q in a.quotas {
                    if q.key.lowercased() == "5h", !TrayPrefs.showDaily { continue }
                    menu.addItem(p.billing == "usage" ? hubQuotaRow(q) : quotaBarRow(q))
                }
                // Speso API sotto le quote del SUO account (solo guedado):
                // è a consumo come l'hub, ma raggruppato qui e non in sezione.
                if TrayPrefs.showApi, let api = a.apiSpend {
                    menu.addItem(apiBarRow(api))
                }
                // Reset manuali sotto le quote (è roba di quote): solo se noti,
                // Codex li dà, Claude no (promo senza API → niente riga).
                if let rc = a.resetCredits {
                    menu.addItem(resetCreditRow(rc))
                }
                // Bonus cloud sotto il SUO account Claude (è un benefit Max:
                // sotto codex/muse si triplicherebbe, stessa email). Se Claude
                // è offline la voce cade nel ripiego Credito AI. nobonus: niente riga.
                if p.id == "claude", let c = cmap[a.label], c.nobonus != true {
                    if TrayPrefs.showBonus { menu.addItem(creditRow(c)) }
                    bonusShown.insert(a.label)
                }
                // Abbonamento sotto ogni account: la voce di renewals.json
                // per account+provider (anche tray:false), o il buco in grigio.
                // A consumo non c'è abbonamento: niente riga e niente buco grigio.
                if p.billing != "usage" {
                    let mine = pren.filter { $0.account == a.label }
                    if mine.isEmpty {
                        menu.addItem(unregisteredRow())
                    } else {
                        for r in mine {
                            menu.addItem(subscriptionRow(r, accountLabels: labels))
                            shown.insert(r.service + "|" + r.account)
                        }
                    }
                }
            }
            // Email solo-fattura: gruppo proprio con la sua intestazione,
            // mai sotto l'account di un altro.
            addGroupedRenewals(pren, baseLabels: labels, menu: menu, shown: &shown)
        }
        let orphans = renewals.filter {
            $0.tray != false && !shown.contains($0.service + "|" + $0.account)
        }
        if !orphans.isEmpty {
            menu.addItem(sectionRow("Altri abbonamenti (fuori rotazione)", providerId: nil))
            // Stesso raggruppamento per email, senza trattini né righe piatte.
            addGroupedRenewals(orphans, baseLabels: [], menu: menu, shown: &shown)
        }
        // Ripiego: bonus di account fuori lista (rotazione vdm) o server
        // vecchio. Solo allora la sezione a parte, che non duplica niente:
        // email come intestazione, sotto la stessa riga BONUS degli account.
        let spare = cmap.filter { !bonusShown.contains($0.key) && $0.value.nobonus != true }
        if !spare.isEmpty, TrayPrefs.showBonus {
            menu.addItem(sectionRow("Credito AI", providerId: nil))
            for email in spare.keys.sorted() {
                menu.addItem(emailRow(email))
                menu.addItem(creditRow(spare[email]!))
            }
        }
    }
    menu.addItem(NSMenuItem.separator())
    for (title, sel, on) in [
        ("Mostra fascia giornaliera (5H)", #selector(AppDelegate.toggleDaily), TrayPrefs.showDaily),
        ("Mostra credito API", #selector(AppDelegate.toggleApi), TrayPrefs.showApi),
        ("Mostra bonus cloud", #selector(AppDelegate.toggleBonus), TrayPrefs.showBonus),
    ] {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        it.target = actionTarget
        it.state = on ? .on : .off
        menu.addItem(it)
    }
    menu.addItem(NSMenuItem.separator())
    let refreshItem = NSMenuItem(title: "Aggiorna", action: #selector(AppDelegate.refresh), keyEquivalent: "r")
    refreshItem.target = actionTarget
    menu.addItem(refreshItem)
    // Dashboard = vdm (:3335, tool privato): mostrarla solo quando vdm
    // risponde, altrove sarebbe un link morto.
    let claudeErr = snapshot?.providers.first(where: { $0.id == "claude" })?.error
    if !isOffline, claudeErr == nil {
        let dashItem = NSMenuItem(title: "Apri dashboard", action: #selector(AppDelegate.openDashboard), keyEquivalent: "d")
        dashItem.target = actionTarget
        menu.addItem(dashItem)
    }
    let quitItem = NSMenuItem(title: "Esci", action: #selector(AppDelegate.quit), keyEquivalent: "q")
    quitItem.target = actionTarget
    menu.addItem(quitItem)
    return menu
}

// MARK: - Snapshot (--snapshot <file.png>: prova visiva senza barra)

// Disegna il menu in un PNG: le view delle voci una sotto l'altra su fondo
// finestra. Stesso menu del clic (buildMenu), niente status item, poi esce.
func snapshotMenu(_ menu: NSMenu, path: String) -> Bool {
    struct Row { let image: NSImage; let height: CGFloat }
    var rows: [Row] = []
    let titledFont = NSFont.systemFont(ofSize: 13)
    for item in menu.items {
        if let view = item.view {
            let w = max(1, view.frame.width), h = max(1, view.frame.height)
            let bounds = NSRect(x: 0, y: 0, width: w, height: h)
            guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { continue }
            view.cacheDisplay(in: bounds, to: rep)
            let img = NSImage(size: bounds.size)
            img.addRepresentation(rep)
            rows.append(Row(image: img, height: h))
        } else if item.isSeparatorItem {
            let h: CGFloat = 9
            let img = NSImage(size: NSSize(width: menuW, height: h))
            img.lockFocus()
            NSColor.separatorColor.setFill()
            NSRect(x: 1, y: h / 2, width: menuW - 2, height: 1).fill()
            img.unlockFocus()
            rows.append(Row(image: img, height: h))
        } else {
            let h: CGFloat = 22
            let img = NSImage(size: NSSize(width: menuW, height: h))
            img.lockFocus()
            (item.title as NSString).draw(
                at: NSPoint(x: 16, y: 4),
                withAttributes: [.font: titledFont, .foregroundColor: NSColor.labelColor])
            img.unlockFocus()
            rows.append(Row(image: img, height: h))
        }
    }
    let totalH = max(1, rows.reduce(0) { $0 + $1.height })
    let totalW = Int(menuW)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: totalW, pixelsHigh: Int(totalH),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: totalW * 4, bitsPerPixel: 32)
    else { return false }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.windowBackgroundColor.setFill()
    NSRect(x: 0, y: 0, width: menuW, height: totalH).fill()
    var y = totalH
    for r in rows {
        y -= r.height
        r.image.draw(in: NSRect(x: 0, y: y, width: menuW, height: r.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { return false }
    do {
        try png.write(to: URL(fileURLWithPath: path))
        return true
    } catch {
        return false
    }
}

func fetchOverviewSync() -> Overview? {
    guard let url = URL(string: "http://localhost:3337/api/overview") else { return nil }
    var req = URLRequest(url: url)
    req.timeoutInterval = 55
    var out: Overview?
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, _, _ in
        defer { sem.signal() }
        guard let data = data else { return }
        out = try? JSONDecoder().decode(Overview.self, from: data)
    }.resume()
    _ = sem.wait(timeout: .now() + 60)
    return out
}

func runSnapshotAndExit(path: String) -> Never {
    _ = NSApplication.shared // font/colori come nella barra, senza runloop
    guard let snapshot = fetchOverviewSync() else {
        FileHandle.standardError.write("usage-tray: --snapshot: server :3337 irraggiungibile\n".data(using: .utf8)!)
        exit(1)
    }
    let menu = buildMenu(snapshot: snapshot, isOffline: false, actionTarget: nil)
    if !snapshotMenu(menu, path: path) {
        FileHandle.standardError.write("usage-tray: --snapshot: scrittura \(path) fallita\n".data(using: .utf8)!)
        exit(1)
    }
    exit(0)
}

// MARK: - App

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var barView: UsageBarView!
    var timer: Timer?
    var snapshot: Overview?
    var isOffline = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        barView = UsageBarView(frame: NSRect(x: 0, y: 0, width: 26, height: 22))
        statusItem.button?.addSubview(barView)
        statusItem.length = 26
        fetchData()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.fetchData()
        }
    }

    func fetchData() {
        guard let url = URL(string: "http://localhost:3337/api/overview") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 55
        let task = URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if error != nil || data == nil {
                    self.isOffline = true
                } else {
                    do {
                        self.snapshot = try JSONDecoder().decode(Overview.self, from: data!)
                        self.isOffline = false
                    } catch {
                        self.isOffline = true
                    }
                }
                self.updateUI()
            }
        }
        task.resume()
    }

    func updateUI() {
        barView.snapshot = snapshot
        barView.isOffline = isOffline
        let newWidth = barView.idealWidth()
        barView.frame = NSRect(x: 0, y: 0, width: newWidth, height: 22)
        statusItem.length = newWidth
        if isOffline {
            statusItem.button?.toolTip = "usage-server offline (:3337)"
        } else {
            let parts = (snapshot?.providers ?? []).flatMap { $0.accounts ?? [] }
                .map { "\($0.label) (\($0.code)): \($0.quotas.map { "\($0.key.uppercased()) \($0.usedPct)% ↻\($0.resetText)\($0.detail.map { " " + $0 } ?? "")" }.joined(separator: " "))" + ($0.resetCredits.map { " (reset manuali: \($0.available))" } ?? "") }
            statusItem.button?.toolTip = parts.joined(separator: "\n")
        }
        barView.needsDisplay = true
        rebuildMenu()
    }

    func rebuildMenu() {
        statusItem.menu = buildMenu(snapshot: snapshot, isOffline: isOffline, actionTarget: self)
    }

    @objc func refresh() { fetchData() }
    @objc func toggleDaily() { TrayPrefs.showDaily.toggle(); rebuildMenu() }
    @objc func toggleApi() { TrayPrefs.showApi.toggle(); rebuildMenu() }
    @objc func toggleBonus() { TrayPrefs.showBonus.toggle(); rebuildMenu() }

    @objc func openDashboard() {
        NSWorkspace.shared.open(URL(string: "http://localhost:3335")!)
    }

    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }
}
