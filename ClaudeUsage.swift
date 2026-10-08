import Cocoa
import CoreText

// MARK: - Models (specchia GET :3337/api/overview)

struct Overview: Codable {
    let providers: [Provider]
    let renewals: [Renewal]
    let credit: CloudCredit?
}

struct CloudCredit: Codable {
    let remaining: Double?
    let limit: Double?
    let renewsAt: String?
    let account: String?
    let unavailable: Bool?
}

struct Provider: Codable {
    let id: String
    let name: String
    let error: String?
    let accounts: [Account]?
}

struct Account: Codable {
    let id: String
    let label: String
    let code: String
    let active: Bool
    let status: String
    let quotas: [Quota]
}

struct Quota: Codable {
    let key: String
    let usedPct: Int
    let resetsAt: Int?
    let resetText: String
    let status: String
}

struct Renewal: Codable {
    let service: String
    let account: String
    let amount: String
    let cycle: String
    let renewsAt: String?
    let note: String
    let provider: String?
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

    // Un solo passaggio di layout per misura e disegno: niente derive tra i due.
    private struct AcctFrame {
        let acct: Account
        let header: String
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
            let accs = p.accounts ?? []
            if accs.isEmpty { continue }
            let gx = x
            var frames: [AcctFrame] = []
            for a in accs {
                // larghezza = riga quota più larga; la mail si taglia a misura,
                // mai oltre. Le righe non si tagliano mai.
                let qw = a.quotas.prefix(2).map { quotaWidth($0) }.max() ?? 0
                let header = cropEmail(a.label, cap: max(30, qw - iconIndent))
                let hw = iconIndent
                    + (header as NSString).size(withAttributes: [.font: headerFont]).width
                let cw = max(hw, qw)
                frames.append(AcctFrame(acct: a, header: header, x: x, w: cw))
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

private let menuW: CGFloat = 400

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
    label.frame = NSRect(x: 38, y: 4, width: menuW - 54, height: 18)
    view.addSubview(label)
    let item = NSMenuItem()
    item.view = view
    return item
}

func shortDate(_ iso: String) -> String {
    let parts = iso.split(separator: "-")
    guard parts.count == 3, let m = Int(parts[1]), (1...12).contains(m),
          let d = Int(parts[2]) else { return iso }
    let mesi = ["", "gen", "feb", "mar", "apr", "mag", "giu", "lug", "ago", "set", "ott", "nov", "dic"]
    return "\(d) \(mesi[m])"
}

func accountRow(_ a: Account) -> NSMenuItem {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: menuW, height: 28))
    let dot = NSView(frame: NSRect(x: 19, y: 10, width: 8, height: 8))
    dot.wantsLayer = true
    dot.layer?.cornerRadius = 4
    dot.layer?.backgroundColor = statusColor(a.status).cgColor
    view.addSubview(dot)
    let label = NSTextField(labelWithString: a.label)
    label.font = .systemFont(ofSize: 12, weight: a.active ? .semibold : .regular)
    label.textColor = .labelColor
    label.frame = NSRect(x: 38, y: 5, width: 200, height: 18)
    label.lineBreakMode = .byTruncatingTail
    view.addSubview(label)
    // a destra la quota peggiore: il colpo d'occhio che conta
    if let worst = a.quotas.max(by: { $0.usedPct < $1.usedPct }) {
        let right = NSTextField(labelWithString: "\(worst.key.uppercased()) \(worst.usedPct)% · ↻ \(worst.resetText)")
        right.font = .systemFont(ofSize: 11)
        right.textColor = .secondaryLabelColor
        right.alignment = .right
        right.frame = NSRect(x: 244, y: 6, width: menuW - 260, height: 16)
        view.addSubview(right)
    }
    let item = NSMenuItem()
    item.view = view
    item.toolTip = a.id
    return item
}

// Riga quota: tag finestra + barra di progresso + % + tempo residuo.
// Solo viste layer-backed, niente draw custom: si renderizza anche offscreen.
func quotaBarRow(_ q: Quota) -> NSMenuItem {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: menuW, height: 24))
    let key = NSTextField(labelWithString: q.key.uppercased())
    key.font = .systemFont(ofSize: 11, weight: .semibold)
    key.textColor = .labelColor
    key.frame = NSRect(x: 38, y: 4, width: 26, height: 16)
    view.addSubview(key)
    let barX: CGFloat = 68
    let barW: CGFloat = 170
    let track = NSView(frame: NSRect(x: barX, y: 8, width: barW, height: 9))
    track.wantsLayer = true
    track.layer?.cornerRadius = 4.5
    track.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
    let fw = barW * CGFloat(min(100, max(0, q.usedPct))) / 100
    if fw > 1 {
        let fill = NSView(frame: NSRect(x: 0, y: 0, width: fw, height: 9))
        fill.wantsLayer = true
        fill.layer?.cornerRadius = 4.5
        fill.layer?.backgroundColor = statusColor(q.status).cgColor
        track.addSubview(fill)
    }
    view.addSubview(track)
    let pct = NSTextField(labelWithString: "\(q.usedPct)%")
    pct.font = .systemFont(ofSize: 11, weight: .semibold)
    pct.textColor = q.status == "ok" ? .labelColor : statusColor(q.status)
    pct.alignment = .right
    pct.frame = NSRect(x: 242, y: 4, width: 38, height: 16)
    view.addSubview(pct)
    let time = NSTextField(labelWithString: "↻ \(q.resetText)")
    time.font = .systemFont(ofSize: 11)
    time.textColor = .secondaryLabelColor
    time.frame = NSRect(x: 286, y: 4, width: menuW - 302, height: 16)
    view.addSubview(time)
    let item = NSMenuItem()
    item.view = view
    return item
}

func renewalRow(_ r: Renewal, providerName: String = "", accountLabels: Set<String> = []) -> NSMenuItem {
    // Sotto l'header del provider non ripetere né il suo nome né gli account già elencati sopra.
    var service = r.service
    if !providerName.isEmpty, service.lowercased().hasPrefix(providerName.lowercased() + " ") {
        service = String(service.dropFirst(providerName.count + 1))
    }
    var text = service
    if !r.account.isEmpty, r.account != r.service, !accountLabels.contains(r.account) {
        text += " — \(r.account)"
    }
    let view = NSView(frame: NSRect(x: 0, y: 0, width: menuW, height: 22))
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: 10.5)
    label.textColor = .secondaryLabelColor
    label.frame = NSRect(x: 38, y: 4, width: 196, height: 15)
    label.lineBreakMode = .byTruncatingTail
    view.addSubview(label)
    let detail = [r.amount, r.renewsAt.map { "↻ \(shortDate($0))" } ?? r.cycle].joined(separator: " · ")
    let right = NSTextField(labelWithString: detail)
    right.font = .systemFont(ofSize: 10.5)
    right.textColor = .tertiaryLabelColor
    right.alignment = .right
    right.frame = NSRect(x: 238, y: 4, width: menuW - 254, height: 15)
    view.addSubview(right)
    let item = NSMenuItem()
    item.view = view
    item.toolTip = r.note.isEmpty ? nil : r.note
    return item
}

// Riga del bonus cloud: stesso scheletro di renewalRow (label + dettaglio).
// Senza saldo (throttle 429) la riga resta e dice che aggiorna: sparire
// e riapparire confonde più di un'attesa dichiarata.
func creditRow(_ c: CloudCredit) -> NSMenuItem {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: menuW, height: 22))
    var title = "Bonus cloud Max"
    if let email = c.account, !email.isEmpty { title += " — \(email)" }
    let label = NSTextField(labelWithString: title)
    label.font = .systemFont(ofSize: 10.5)
    label.textColor = .secondaryLabelColor
    label.frame = NSRect(x: 38, y: 4, width: 196, height: 15)
    label.lineBreakMode = .byTruncatingTail
    view.addSubview(label)
    let detail: String
    if let left = c.remaining {
        let amount = String(format: "$%.2f", left)
            + (c.limit.map { String(format: " di $%.0f", $0) } ?? "")
        detail = [amount, c.renewsAt.map { "scade \(shortDate($0))" } ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    } else {
        detail = "in aggiornamento…"
    }
    let right = NSTextField(labelWithString: detail)
    right.font = .systemFont(ofSize: 10.5)
    right.textColor = .tertiaryLabelColor
    right.alignment = .right
    right.frame = NSRect(x: 238, y: 4, width: menuW - 254, height: 15)
    view.addSubview(right)
    let item = NSMenuItem()
    item.view = view
    return item
}

func emailRow(_ email: String) -> NSMenuItem {
    // Email solo-fattura (non un account live): intestazione tenue senza pallino.
    let view = NSView(frame: NSRect(x: 0, y: 0, width: menuW, height: 22))
    let label = NSTextField(labelWithString: email)
    label.font = .systemFont(ofSize: 11)
    label.textColor = .secondaryLabelColor
    label.frame = NSRect(x: 38, y: 3, width: menuW - 54, height: 16)
    label.lineBreakMode = .byTruncatingTail
    view.addSubview(label)
    let item = NSMenuItem()
    item.view = view
    return item
}

// Rinnovi raggruppati per email con la sua intestazione; le righe
// auto-nominate (service == account) restano da sole senza intestazione.
func addGroupedRenewals(_ rows: [Renewal], providerName: String, baseLabels: Set<String>,
                        menu: NSMenu, shown: inout Set<String>) {
    var keys: [String] = []
    for r in rows where !shown.contains(r.service + "|" + r.account) {
        if !keys.contains(r.account) { keys.append(r.account) }
    }
    for k in keys {
        let rs = rows.filter { $0.account == k && !shown.contains($0.service + "|" + $0.account) }
        if rs.allSatisfy({ $0.service == $0.account }) {
            for r in rs {
                menu.addItem(renewalRow(r, providerName: providerName, accountLabels: baseLabels))
                shown.insert(r.service + "|" + r.account)
            }
        } else {
            menu.addItem(emailRow(k))
            for r in rs {
                menu.addItem(renewalRow(r, providerName: providerName,
                                        accountLabels: baseLabels.union([k])))
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

func infoRow(_ text: String) -> NSMenuItem {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: menuW, height: 28))
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: 11)
    label.textColor = .secondaryLabelColor
    label.frame = NSRect(x: 16, y: 5, width: menuW - 32, height: 18)
    view.addSubview(label)
    let item = NSMenuItem()
    item.view = view
    return item
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
                .map { "\($0.label) (\($0.code)): \($0.quotas.map { "\($0.key.uppercased()) \($0.usedPct)% ↻\($0.resetText)" }.joined(separator: " "))" }
            statusItem.button?.toolTip = parts.joined(separator: "\n")
        }
        barView.needsDisplay = true
        rebuildMenu()
    }

    func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(headerRow("Usage"))
        if isOffline {
            menu.addItem(infoRow("⚡ Offline — cannot reach usage-server :3337"))
        } else {
            menu.addItem(legendRow("Nella barra: 5H sopra, 7D sotto · % e tempo di reset per quota"))
            menu.addItem(legendRow("Account affievolito: non attivo · ↻: reset o rinnovo"))
            let providers = snapshot?.providers ?? []
            let renewals = snapshot?.renewals ?? []
            var shown = Set<String>()
            for p in providers {
                menu.addItem(sectionRow(p.name, providerId: p.id))
                let accs = p.accounts ?? []
                if let err = p.error {
                    menu.addItem(infoRow("\(p.name): \(err)"))
                } else if accs.isEmpty {
                    menu.addItem(infoRow("nessun account"))
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
                        menu.addItem(quotaBarRow(q))
                    }
                    for r in pren where r.account == a.label {
                        menu.addItem(renewalRow(r, providerName: p.name, accountLabels: labels))
                        shown.insert(r.service + "|" + r.account)
                    }
                }
                // Email solo-fattura: gruppo proprio con la sua intestazione,
                // mai sotto l'account di un altro.
                addGroupedRenewals(pren, providerName: p.name, baseLabels: labels,
                                   menu: menu, shown: &shown)
            }
            let orphans = renewals.filter { !shown.contains($0.service + "|" + $0.account) }
            if !orphans.isEmpty {
                menu.addItem(sectionRow("Altri abbonamenti (fuori rotazione)", providerId: nil))
                // Stesso raggruppamento per email, senza trattini né righe piatte.
                addGroupedRenewals(orphans, providerName: "", baseLabels: [],
                                   menu: menu, shown: &shown)
            }
            // Bonus cloud Max: solo se il server lo vede (tool personale).
            if let c = snapshot?.credit {
                menu.addItem(sectionRow("Credito AI", providerId: nil))
                menu.addItem(creditRow(c))
            }
        }
        menu.addItem(NSMenuItem.separator())
        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        // Dashboard = vdm (:3335, tool privato): mostrarla solo quando vdm
        // risponde, altrove sarebbe un link morto.
        let claudeErr = snapshot?.providers.first(where: { $0.id == "claude" })?.error
        if !isOffline, claudeErr == nil {
            let dashItem = NSMenuItem(title: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "d")
            dashItem.target = self
            menu.addItem(dashItem)
        }
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    @objc func refresh() { fetchData() }

    @objc func openDashboard() {
        NSWorkspace.shared.open(URL(string: "http://localhost:3335")!)
    }

    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }
}
