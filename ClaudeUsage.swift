import Cocoa

// MARK: - Models

struct APIResponse: Codable {
    let profiles: [Profile]
    let allExhausted: Bool
    let earliestReset: String?
    let rotationStrategy: String?
    let passthrough: Bool

    enum CodingKeys: String, CodingKey {
        case profiles, allExhausted, earliestReset, rotationStrategy, passthrough
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try c.decode([Profile].self, forKey: .profiles)
        allExhausted = try c.decodeIfPresent(Bool.self, forKey: .allExhausted) ?? false
        rotationStrategy = try c.decodeIfPresent(String.self, forKey: .rotationStrategy)
        passthrough = try c.decodeIfPresent(Bool.self, forKey: .passthrough) ?? false
        // earliestReset can be string, int, or null
        if let s = try? c.decode(String.self, forKey: .earliestReset) {
            earliestReset = s
        } else if let i = try? c.decode(Int.self, forKey: .earliestReset) {
            let date = Date(timeIntervalSince1970: Double(i))
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm"
            fmt.timeZone = TimeZone.current
            earliestReset = fmt.string(from: date)
        } else {
            earliestReset = nil
        }
    }
}

struct Profile: Codable {
    let name: String
    let label: String?
    let isActive: Bool?
    let dormant: Bool?
    let rateLimits: RateLimits?
    let disabled: Bool?
    let limited: Bool?
    let retryAfter: Int?
    let blockKind: String?
    let myTokens5h: Int?
    let myTokens7d: Int?

    var displayName: String {
        label ?? name
    }
    var isDisabled: Bool { disabled == true }

    // True wall: real rate-limit cooldown with a future retryAfter, independent
    // of unified utilization (e.g. weekly Opus cap hit while 5h/7d bars look free).
    var isBlocked: Bool {
        guard limited == true, let ra = retryAfter, ra > 0 else { return false }
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        return ra > nowMs
    }

    // blockKind is the authoritative reason, unlike isLimited/fiveH.status which
    // bounce on transient probe failures and used to cause false full-red states.
    var isQuotaBlocked: Bool { blockKind == "quota-5h" || blockKind == "quota-7d" }
    var isModelBlocked: Bool { blockKind == "model" }
    var isAuthBlocked: Bool { blockKind == "auth" }
    var blockedText: String {
        guard let ra = retryAfter, ra > 0 else { return "" }
        return Self.formatReset(ra / 1000)
    }
    var retryAfterDateText: String {
        guard let ra = retryAfter, ra > 0 else { return "" }
        let date = Date(timeIntervalSince1970: Double(ra) / 1000)
        let fmt = DateFormatter()
        fmt.dateFormat = "dd/MM HH:mm"
        fmt.timeZone = TimeZone.current
        return fmt.string(from: date)
    }
    static func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }
    var u5h: Double { rateLimits?.fiveH?.utilization ?? 0 }
    var u7d: Double { rateLimits?.sevenD?.utilization ?? 0 }
    var reset5h: Int? { rateLimits?.fiveH?.reset }
    
    var reset7d: Int? { rateLimits?.sevenD?.reset }
    
    var hoursToReset5h: String {
        guard let r = reset5h else { return "" }
        return Self.formatReset(r)
    }
    var hoursToReset7d: String {
        guard let r = reset7d else { return "" }
        return Self.formatReset(r)
    }
    var hoursToReset: String { hoursToReset5h }
    
    static func formatReset(_ epoch: Int) -> String {
        let secs = epoch - Int(Date().timeIntervalSince1970)
        if secs <= 0 { return "now" }
        let d = secs / 86400
        let h = (secs % 86400) / 3600
        let m = (secs % 3600) / 60
        if d > 0 { return "\(d)d\(h)h" }
        if h > 0 { return "\(h)h\(m)m" }
        return "\(m)m"
    }
    var isLimited: Bool {
        rateLimits?.status == "limited" || rateLimits?.fiveH?.status == "limited"
    }
}

struct RateLimits: Codable {
    let status: String?
    let fiveH: Window?
    let sevenD: Window?
}

struct Window: Codable {
    let status: String?
    let reset: Int?
    let utilization: Double?
}

// MARK: - Tray Bar Drawing

class UsageBarView: NSView {
    var profiles: [Profile] = []
    var isOffline = false
    var allExhausted = false
    var earliestReset: String?
    var passthrough = false

    static let barHeight: CGFloat = 3
    static let barGap: CGFloat = 2
    static let groupGap: CGFloat = 4
    static let padding: CGFloat = 3
    static let passthroughBadge = "⚡"

    func passthroughBadgeWidth() -> CGFloat {
        guard passthrough else { return 0 }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .bold)]
        return (UsageBarView.passthroughBadge as NSString).size(withAttributes: attrs).width + UsageBarView.groupGap
    }

    func barWidth(for p: Profile) -> CGFloat {
        let label = String(p.displayName.prefix(5)).uppercased()
        let nameAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .bold)]
        let resetAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 7, weight: .regular)]
        let nameW = (label as NSString).size(withAttributes: nameAttrs).width
        let resetText = p.isBlocked ? p.blockedText : "00h00m"
        let resetW = (resetText as NSString).size(withAttributes: resetAttrs).width
        return nameW + 4 + resetW  // 4px gap so the name and countdown never touch
    }

    func idealWidth() -> CGFloat {
        if profiles.isEmpty { return UsageBarView.padding * 2 + 30 }
        var w = UsageBarView.padding * 2 + passthroughBadgeWidth()
        for (i, p) in profiles.enumerated() {
            w += barWidth(for: p)
            if i < profiles.count - 1 { w += UsageBarView.groupGap }
        }
        return w
    }
    
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        
        let pad = UsageBarView.padding
        let gg = UsageBarView.groupGap
        
        // Menu bar is 22px. Layout:
        // Top half (y 11-19): account name (left) + reset time (right)
        // Bottom half (y 2-9): two bars side by side [5h][7d]
        
        let textY: CGFloat = 11
        let barY: CGFloat = 3
        let barH: CGFloat = 5
        
        if isOffline || profiles.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 7, weight: .medium),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
            ("--" as NSString).draw(at: NSPoint(x: pad, y: 6), withAttributes: attrs)
            return
        }
        
        var x = pad

        if passthrough {
            let badgeAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: .bold),
                .foregroundColor: NSColor.systemYellow
            ]
            (UsageBarView.passthroughBadge as NSString).draw(at: NSPoint(x: x, y: 6), withAttributes: badgeAttrs)
            x += passthroughBadgeWidth()
        }

        for (i, p) in profiles.enumerated() {
            let bw = barWidth(for: p)
            let blocked = p.isBlocked
            let quotaBlocked = p.isQuotaBlocked
            let modelBlocked = p.isModelBlocked
            let disabled = p.isDisabled

            // Top row: name left, reset (or blocked countdown) right
            let shortName = String(p.displayName.prefix(5)).uppercased()
            let dimColor = disabled ? NSColor.white.withAlphaComponent(0.25)
                : quotaBlocked ? NSColor.systemRed
                : modelBlocked ? NSColor.systemOrange
                : p.isActive == true ? NSColor.white : NSColor.white.withAlphaComponent(0.5)
            let nameAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 7, weight: p.isActive == true ? .bold : .regular),
                .foregroundColor: dimColor
            ]
            (shortName as NSString).draw(at: NSPoint(x: x, y: textY), withAttributes: nameAttrs)

            let resetStr = blocked ? p.blockedText : p.hoursToReset
            if !resetStr.isEmpty {
                let resetAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 7, weight: .regular),
                    .foregroundColor: dimColor
                ]
                let resetSize = (resetStr as NSString).size(withAttributes: resetAttrs)
                (resetStr as NSString).draw(at: NSPoint(x: x + bw - resetSize.width, y: textY), withAttributes: resetAttrs)
            }

            // Bottom row: two bars stacked (5h top, 7d bottom).
            // Only a real quota wall (blockKind quota-5h/7d) forces a full red
            // bar; a model-only block (Opus/Fable capped, Haiku still usable)
            // shows the real utilization tinted amber instead.
            let singleBarH: CGFloat = 3
            let u5h = quotaBlocked ? 1.0 : p.u5h
            let u7d = quotaBlocked ? 1.0 : p.u7d
            drawHBar(ctx: ctx, x: x, y: barY + singleBarH + 1, maxW: bw, h: singleBarH, util: u5h, blockKind: p.blockKind, disabled: disabled)
            drawHBar(ctx: ctx, x: x, y: barY, maxW: bw, h: singleBarH, util: u7d, blockKind: p.blockKind, disabled: disabled)

            x += bw
            if i < profiles.count - 1 { x += gg }
        }
    }

    func drawHBar(ctx: CGContext, x: CGFloat, y: CGFloat, maxW: CGFloat, h: CGFloat, util: Double, blockKind: String?, disabled: Bool = false) {
        ctx.setFillColor(NSColor.white.withAlphaComponent(disabled ? 0.2 : 0.5).cgColor)
        let trackPath = CGPath(roundedRect: CGRect(x: x, y: y, width: maxW, height: h), cornerWidth: 1, cornerHeight: 1, transform: nil)
        ctx.addPath(trackPath)
        ctx.fillPath()

        let fillW = max(maxW * 0.03, maxW * util)
        let color: NSColor
        if disabled { color = NSColor.white.withAlphaComponent(0.3) }
        else if blockKind == "quota-5h" || blockKind == "quota-7d" || allExhausted { color = .systemRed }
        else if blockKind == "model" { color = .systemOrange }
        else if util < 0.5 { color = .systemGreen }
        else if util < 0.8 { color = .systemOrange }
        else { color = .systemRed }

        ctx.setFillColor(color.cgColor)
        let fillPath = CGPath(roundedRect: CGRect(x: x, y: y, width: fillW, height: h), cornerWidth: 1, cornerHeight: 1, transform: nil)
        ctx.addPath(fillPath)
        ctx.fillPath()
    }
}

class AccountMenuItemView: NSView {
    let profile: Profile
    let isLast: Bool
    
    init(profile: Profile, isLast: Bool) {
        self.profile = profile
        self.isLast = isLast
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: isLast ? 84 : 90))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let leftPad: CGFloat = 16
        let barX: CGFloat = 52
        let barW: CGFloat = 160
        let barH: CGFloat = 8
        let pctX: CGFloat = barX + barW + 8
        let resetX: CGFloat = pctX + 34

        // Account name + status
        let active = profile.isActive == true
        let limited = profile.isLimited
        let quotaBlocked = profile.isQuotaBlocked
        let modelBlocked = profile.isModelBlocked
        let authBlocked = profile.isAuthBlocked
        let disabled = profile.isDisabled
        var name = profile.displayName
        if active { name += " ●" }

        // blockKind is the authoritative reason (quota/model/auth wall), unlike
        // isLimited/fiveH.status which bounce on transient probe failures —
        // it takes priority over the softer unified-utilization LIMITED signal.
        // DISABLED (opt-out) overrides everything.
        let statusText: String
        let statusColor: NSColor
        if disabled {
            statusText = "OFF"
            statusColor = .tertiaryLabelColor
        } else if quotaBlocked {
            statusText = "PIENO → \(profile.retryAfterDateText)"
            statusColor = .systemRed
        } else if modelBlocked {
            statusText = "GRANDI → \(profile.retryAfterDateText)"
            statusColor = .systemOrange
        } else if authBlocked {
            statusText = "AUTH"
            statusColor = .systemYellow
        } else if profile.rateLimits?.fiveH?.status == "rejected" {
            statusText = "REJECTED"
            statusColor = .systemRed
        } else if limited {
            statusText = "LIMITED"
            statusColor = .systemOrange
        } else {
            statusText = ""
            statusColor = .clear
        }

        // Measure the status badge first so the name can be truncated to leave
        // room for it — otherwise a long email name runs under the badge.
        let statusAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .bold),
            .foregroundColor: statusColor
        ]
        let statusW = statusText.isEmpty ? 0 : (statusText as NSString).size(withAttributes: statusAttrs).width

        let nameColor: NSColor
        if disabled { nameColor = .tertiaryLabelColor }
        else if quotaBlocked { nameColor = .systemRed }
        else if modelBlocked { nameColor = .systemOrange }
        else if limited { nameColor = .systemOrange }
        else { nameColor = .labelColor }
        var nameAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: active ? .semibold : .regular),
            .foregroundColor: nameColor
        ]
        if disabled { nameAttrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        let namePara = NSMutableParagraphStyle()
        namePara.lineBreakMode = .byTruncatingTail
        nameAttrs[.paragraphStyle] = namePara
        let nameMaxW = max(40, bounds.width - leftPad * 2 - statusW - 8)
        (name as NSString).draw(in: NSRect(x: leftPad, y: bounds.height - 19, width: nameMaxW, height: 16), withAttributes: nameAttrs)

        if !statusText.isEmpty {
            (statusText as NSString).draw(at: NSPoint(x: bounds.width - leftPad - statusW, y: bounds.height - 16), withAttributes: statusAttrs)
        }

        // 5h bar + reset. Only a real quota wall forces the bar full; a
        // model-only block shows the real utilization tinted amber.
        let y5h = bounds.height - 34
        drawLabel("5h", at: NSPoint(x: leftPad, y: y5h - 1))
        drawBar(ctx: ctx, x: barX, y: y5h, w: barW, h: barH, util: quotaBlocked ? 1.0 : profile.u5h, blockKind: profile.blockKind, disabled: disabled)
        drawPct(profile.u5h, at: NSPoint(x: pctX, y: y5h - 1))
        drawReset(profile.hoursToReset5h, at: NSPoint(x: resetX, y: y5h - 1))

        // 7d bar + reset
        let y7d = bounds.height - 50
        drawLabel("7d", at: NSPoint(x: leftPad, y: y7d - 1))
        drawBar(ctx: ctx, x: barX, y: y7d, w: barW, h: barH, util: quotaBlocked ? 1.0 : profile.u7d, blockKind: profile.blockKind, disabled: disabled)
        drawPct(profile.u7d, at: NSPoint(x: pctX, y: y7d - 1))
        drawReset(profile.hoursToReset7d, at: NSPoint(x: resetX, y: y7d - 1))

        // My usage on this (possibly shared) account
        if let my7d = profile.myTokens7d, my7d > 0 {
            let youY = bounds.height - 66
            let youAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
            ("Tu: \(Profile.formatTokens(my7d)) tok / 7d" as NSString).draw(at: NSPoint(x: leftPad, y: youY), withAttributes: youAttrs)
        }

        // Separator
        if !isLast {
            ctx.setFillColor(NSColor.separatorColor.cgColor)
            ctx.fill(CGRect(x: leftPad, y: 2, width: bounds.width - leftPad * 2, height: 0.5))
        }
    }
    
    func drawLabel(_ text: String, at point: NSPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        (text as NSString).draw(at: point, withAttributes: attrs)
    }
    
    func drawPct(_ util: Double, at point: NSPoint) {
        let pct = "\(Int(util * 100))%"
        let color: NSColor
        if util < 0.5 { color = .secondaryLabelColor }
        else if util < 0.8 { color = .systemOrange }
        else { color = .systemRed }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: color
        ]
        (pct as NSString).draw(at: point, withAttributes: attrs)
    }
    
    func drawReset(_ text: String, at point: NSPoint) {
        guard !text.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        ("↻\(text)" as NSString).draw(at: point, withAttributes: attrs)
    }
    
    func drawBar(ctx: CGContext, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, util: Double, blockKind: String?, disabled: Bool = false) {
        // Track
        let trackPath = CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: 3, cornerHeight: 3, transform: nil)
        ctx.setFillColor(NSColor.white.withAlphaComponent(disabled ? 0.2 : 0.5).cgColor)
        ctx.addPath(trackPath)
        ctx.fillPath()

        // Fill
        let fillW = max(w * 0.02, w * util)
        let color: NSColor
        if disabled { color = NSColor.white.withAlphaComponent(0.3) }
        else if blockKind == "quota-5h" || blockKind == "quota-7d" { color = .systemRed }
        else if blockKind == "model" { color = .systemOrange }
        else if util < 0.5 { color = .systemGreen }
        else if util < 0.8 { color = .systemOrange }
        else { color = .systemRed }

        let fillPath = CGPath(roundedRect: CGRect(x: x, y: y, width: fillW, height: h), cornerWidth: 3, cornerHeight: 3, transform: nil)
        ctx.setFillColor(color.cgColor)
        ctx.addPath(fillPath)
        ctx.fillPath()
    }
}

class FooterMenuItemView: NSView {
    let strategy: String?
    let reset: String?
    
    init(strategy: String?, reset: String?) {
        self.strategy = strategy
        self.reset = reset
        let h: CGFloat = (strategy != nil && reset != nil) ? 36 : 22
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: h))
    }
    required init?(coder: NSCoder) { fatalError() }
    
    override func draw(_ dirtyRect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        var y = bounds.height - 16
        if let s = strategy {
            ("Strategy: \(s)" as NSString).draw(at: NSPoint(x: 16, y: y), withAttributes: attrs)
            y -= 16
        }
        if let r = reset, r != "unknown" {
            ("Next reset: \(r)" as NSString).draw(at: NSPoint(x: 16, y: y), withAttributes: attrs)
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var barView: UsageBarView!
    var timer: Timer?
    var profiles: [Profile] = []
    var allExhausted = false
    var earliestReset: String?
    var rotationStrategy: String?
    var isOffline = false
    var passthrough = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        barView = UsageBarView(frame: NSRect(x: 0, y: 0, width: barView(for: []).idealWidth(), height: 22))
        statusItem.button?.addSubview(barView)
        statusItem.length = barView.idealWidth()
        
        fetchData()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.fetchData()
        }
    }
    
    func barView(for profiles: [Profile]) -> UsageBarView {
        let v = UsageBarView()
        v.profiles = profiles
        return v
    }

    func fetchData() {
        guard let url = URL(string: "http://localhost:3335/api/profiles") else { return }
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if error != nil || data == nil {
                    self.isOffline = true
                    self.updateUI()
                    return
                }
                do {
                    let resp = try JSONDecoder().decode(APIResponse.self, from: data!)
                    self.profiles = resp.profiles
                    self.allExhausted = resp.allExhausted
                    self.earliestReset = resp.earliestReset
                    self.rotationStrategy = resp.rotationStrategy
                    self.passthrough = resp.passthrough
                    self.isOffline = false
                } catch {
                    self.isOffline = true
                }
                self.updateUI()
            }
        }
        task.resume()
    }
    
    func updateUI() {
        // Update bar view in menu bar
        barView.profiles = profiles
        barView.isOffline = isOffline
        barView.allExhausted = allExhausted
        barView.earliestReset = earliestReset
        barView.passthrough = passthrough
        
        let newWidth = barView.idealWidth()
        barView.frame = NSRect(x: 0, y: 0, width: newWidth, height: 22)
        statusItem.length = newWidth
        barView.needsDisplay = true
        
        rebuildMenu()
    }

    func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        
        // Title
        let titleView = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 28))
        let titleStr = "Claude Usage"
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold),
            .foregroundColor: NSColor.labelColor
        ]
        let titleLabel = NSTextField(labelWithAttributedString: NSAttributedString(string: titleStr, attributes: titleAttrs))
        titleLabel.frame = NSRect(x: 16, y: 4, width: 200, height: 20)
        titleView.addSubview(titleLabel)
        let titleItem = NSMenuItem()
        titleItem.view = titleView
        menu.addItem(titleItem)
        
        menu.addItem(NSMenuItem.separator())

        if !isOffline && passthrough {
            let bypassView = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 26))
            let bypassLabel = NSTextField(labelWithString: "⚡ VDM in bypass — stai usando il login diretto")
            bypassLabel.font = .systemFont(ofSize: 11, weight: .semibold)
            bypassLabel.textColor = .systemYellow
            bypassLabel.frame = NSRect(x: 16, y: 4, width: 308, height: 18)
            bypassView.addSubview(bypassLabel)
            let bypassItem = NSMenuItem()
            bypassItem.view = bypassView
            menu.addItem(bypassItem)
            menu.addItem(NSMenuItem.separator())
        }

        if isOffline {
            let offView = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 30))
            let offLabel = NSTextField(labelWithString: "⚡ Offline — cannot reach VDM")
            offLabel.font = .systemFont(ofSize: 11)
            offLabel.textColor = .secondaryLabelColor
            offLabel.frame = NSRect(x: 16, y: 6, width: 260, height: 18)
            offView.addSubview(offLabel)
            let offItem = NSMenuItem()
            offItem.view = offView
            menu.addItem(offItem)
        } else if profiles.isEmpty {
            let emptyView = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 30))
            let emptyLabel = NSTextField(labelWithString: "No accounts configured")
            emptyLabel.font = .systemFont(ofSize: 11)
            emptyLabel.textColor = .secondaryLabelColor
            emptyLabel.frame = NSRect(x: 16, y: 6, width: 260, height: 18)
            emptyView.addSubview(emptyLabel)
            let emptyItem = NSMenuItem()
            emptyItem.view = emptyView
            menu.addItem(emptyItem)
        } else {
            for (i, p) in profiles.enumerated() {
                let view = AccountMenuItemView(profile: p, isLast: i == profiles.count - 1)
                let item = NSMenuItem()
                item.view = view
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())
        
        // Footer
        if rotationStrategy != nil || earliestReset != nil {
            let footerView = FooterMenuItemView(strategy: rotationStrategy, reset: earliestReset)
            let footerItem = NSMenuItem()
            footerItem.view = footerView
            menu.addItem(footerItem)
            menu.addItem(NSMenuItem.separator())
        }

        let dashItem = NSMenuItem(title: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "d")
        dashItem.target = self
        menu.addItem(dashItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc func openDashboard() {
        NSWorkspace.shared.open(URL(string: "http://localhost:3335")!)
    }

    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Main

// Single instance guard via an advisory lock on the pidfile.
//
// A bare `kill(pid, 0)` is not a liveness test: macOS recycles PIDs, so a stale
// file from a crashed tray eventually names an unrelated live process and the
// guard exits(0) forever. Seen for real on 2026-08-30 — the file held 1120,
// which by then belonged to `jcode serve`, so KeepAlive respawned the tray
// 3360 times and it vanished from the menubar with no error anywhere.
//
// flock() cannot lie: the kernel drops the lock when the holder dies, whatever
// happens to the PID. The file still carries the pid, for humans reading it.
let pidFile = NSString(string: "~/.claude/account-switcher/usage-tray.pid").expandingTildeInPath
let lockFD = open(pidFile, O_CREAT | O_RDWR, 0o644)
if lockFD < 0 {
    FileHandle.standardError.write("usage-tray: cannot open \(pidFile): \(String(cString: strerror(errno)))\n".data(using: .utf8)!)
    exit(1)
}
if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    // Another tray holds the lock: this one is the duplicate.
    exit(0)
}
ftruncate(lockFD, 0)
let pidBytes = Array("\(ProcessInfo.processInfo.processIdentifier)\n".utf8)
_ = pidBytes.withUnsafeBufferPointer { write(lockFD, $0.baseAddress, $0.count) }
// lockFD is deliberately never closed: the lock must outlive this scope.

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
