import Foundation

// MARK: - 125 汇率上下文
//
// A股 里的跨境 ETF 有两个价格来源：海外标的本身的涨跌，和汇率的变动。
// 513520 追踪日经，人民币计价的涨跌 ≈ 日经涨跌 + 日元/人民币涨跌。
// 于是「日经涨了，A股 怎么没跟」有一半可能根本不是跟随失败，而是日元跌了。
//
// 不把这一层拆开，领先关系里就混进了一个看不见的混淆变量。
//
// 这一项的定位和其它研究一样：**只做解释上下文，不产生交易信号**。
// 三条门槛与保护写死在这里：
//   1. 汇率数据不足 20 个独立交易日 → 不给「平均干扰度」，只说今天的方向；
//   2. 数据过期（超过 26 小时）或时间戳在未来 → 整份上下文判为不可用，宁可不说；
//   3. 单日跳变超过 3% → 先怀疑数据错误，不当成真实行情去解释标的。
// 以及最关键的一条：**没有汇率数据时不假设 0**。假设 0 等于偷偷把汇率影响
// 归因给标的本身，比不给结论错得更远。
//
// 汇率的三条「数据来源纪律」（写死在类型里，不是写在文档里）：
//   1. **必须有明确来源**：来源不明（unknown）的汇率一律不可当事实，更不可当实时值。
//      手机缓存与 NAS 归档要分开写，`source` 没有值就不给结论。
//   2. **必须有交易所时间戳**：新鲜度只认 `exchangeAt`（源自己报的时刻），
//      **绝不认 `receivedAt`（本机/NAS 什么时候收到的）**。刚收到 ≠ 数据新——
//      这正是「不把手机或 NAS 的旧值伪装成实时」的落点：缓存里存了三天的值，
//      就算刚刚才被读出来，它也是三天前的旧值。
//   3. **必须由新鲜度决定能不能叫实时**：没有 `exchangeAt` 就判缺失，不许拿
//      「我刚拿到」当新鲜的证据；过期就是过期，界面与 AI 上下文照抄「过期」。
// 以及它在本产品里的位置：**汇率永远不能单独触发做T或网格**。它只是解释层——
// 把「标的涨跌」和「汇率影响」拆开，绝不是交易理由。

/// 汇率的来源。必须可追溯：不知道哪来的，就不能当事实。
enum NextFXSource: String, Codable, CaseIterable, Equatable {
    case nasArchive = "nas-archive"
    case deviceCache = "device-cache"
    case unknown = "unknown"

    var displayName: String {
        switch self {
        case .nasArchive: return "NAS 归档"
        case .deviceCache: return "本机缓存"
        case .unknown: return "来源不明"
        }
    }

    /// 这条来源能不能被当成「实时」的凭据。来源不明的一律不能。
    var isTraceable: Bool { self != .unknown }
}

/// 被承认的**来源名称**（与 NAS 端 fx.VERIFIED_SOURCE_NAMES 一一对应）。
///
/// 这条是本产品的硬边界：**即使有汇率数字，只要来源名称未验证，就不能进入决策上下文**。
/// 数字本身没有身份证明力——一个来路不明的 6.67 和真实的 6.67 长得一模一样，
/// 所以可不可以引用，取决于"这个名字我们认不认"，而不是"这个数字看不看得出错"。
enum NextFXSourceName {
    /// 登记在册、且核对过字段格式的来源名称。加数据源必须先在 NAS 端
    /// `fx.VERIFIED_SOURCE_NAMES` 登记，否则两边会互不相认。
    static let verified = ["Sina fx"]

    static func isVerified(_ name: String?) -> Bool {
        guard let name, !name.isEmpty else { return false }
        return verified.contains(name)
    }

    static var note: String {
        "已验证的来源名称：\(verified.joined(separator: "、"))"
    }
}

/// 新鲜度。**只按交易所时间戳算**，绝不按「本机/NAS 什么时候收到的」算。
enum NextFXFreshness: Equatable {
    case fresh(ageHours: Double)
    case stale(ageHours: Double)
    case unknown

    var isFresh: Bool {
        if case .fresh = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .fresh: return "实时"
        case .stale: return "过期"
        case .unknown: return "时间不明"
        }
    }

    var note: String {
        switch self {
        case let .fresh(age): return "源时间戳 \(String(format: "%.1f", age)) 小时前（实时）"
        case let .stale(age): return "源时间戳 \(String(format: "%.1f", age)) 小时前（过期，不能当实时用）"
        case .unknown: return "没有交易所时间戳，无法判断新旧"
        }
    }
}

/// 汇率在决策里的位置。只有一种取值：它永远不能单独授权做T或网格。
enum NextFXPlanEligibility: Equatable {
    case never

    var note: String {
        "汇率只作解释上下文：它可以解释涨跌，但永远不能单独触发做T或网格计划"
    }
}

enum NextFXPair: String, CaseIterable, Codable, Equatable {
    case jpyCny = "JPYCNY"
    case usdCny = "USDCNY"
    case hkdCny = "HKDCNY"
    case krwCny = "KRWCNY"

    var market: NextCrossMarket {
        switch self {
        case .jpyCny: return .japan
        case .usdCny: return .unitedStates
        case .hkdCny: return .hongKong
        case .krwCny: return .korea
        }
    }

    var displayName: String {
        switch self {
        case .jpyCny: return "日元/人民币"
        case .usdCny: return "美元/人民币"
        case .hkdCny: return "港元/人民币"
        case .krwCny: return "韩元/人民币"
        }
    }

    /// 跨境 ETF 才需要看汇率；A股 本身没有这一层。
    static func pair(for market: NextCrossMarket) -> NextFXPair? {
        allCases.first { $0.market == market }
    }
}

/// 一个汇率观测点。三个时间/来源字段缺一不可：
///   `exchangeAt` = 源（交易所/数据方）自己报的时刻 —— 新旧只认它；
///   `receivedAt` = 本机（或 NAS）把这条值存下来的时刻 —— 只用来说明"缓存了多久"，
///                  **绝不能用来证明数据新**；
///   `source`     = 这条值是从哪来的。
/// 缺了 `exchangeAt`、来源为 unknown、或**来源名称未验证**的点，
/// 一律不能被当成实时值，也不许进入决策上下文。
struct NextFXPoint: Codable, Equatable {
    let exchangeAt: Date?
    let receivedAt: Date
    let rate: Double
    let source: NextFXSource
    /// 来源名称（如 "Sina fx"）。必须落在 NextFXSourceName.verified 里才有资格被引用。
    let sourceName: String

    /// 排序/归日用：没有源时间戳时退回本机时刻（仅用于排序，不用于判新旧）。
    var orderingTime: Date { exchangeAt ?? receivedAt }

    /// 这条汇率的来源名称是否已验证。未验证 → 有数字也不许进决策上下文。
    var isSourceVerified: Bool { NextFXSourceName.isVerified(sourceName) }
}

struct NextFXContext: Equatable {
    enum State: Equatable {
        /// A股 本身：没有汇率层，不是「缺失」。
        case notApplicable
        /// 没有接入或今天还没数据。必须明说，不许当成 0。
        case missing(String)
        /// 数据过期。旧汇率解释今天，是纯粹的错。
        case stale(String)
        /// 数值可疑（未来时间戳、异常跳变、来源不明）。
        case suspicious(String)
        case available(days: Int, todayPercent: Double)
    }

    let market: NextCrossMarket
    let pair: NextFXPair?
    let state: State
    /// 最新一条的来源（可追溯）。默认 unknown：不填来源就是不来源。
    let source: NextFXSource = .unknown
    /// 源/交易所时间戳：新鲜度只认它；nil 表示源没给时间，不能谈新旧。
    let exchangeAt: Date? = nil
    /// 本机/NAS 收到的时刻：只用于说明「缓存里存了多久」，绝不用于判新旧。
    let receivedAt: Date? = nil
    /// 新鲜度（按 exchangeAt 算）。默认 unknown：没有时间戳就没有新鲜度。
    let freshness: NextFXFreshness = .unknown
    /// 来源名称（如 "Sina fx"）。默认空串 = 未验证。
    let sourceName: String = ""

    /// 能不能当作实时值：既要看新鲜度（源时间戳够新），也要看来源可追溯。
    /// 过期或来源不明 → false，绝不许把旧值说成实时。
    var isRealTime: Bool { freshness.isFresh && source.isTraceable }

    /// 汇率永远不能单独触发做T或网格——它只是解释层。
    var planEligibility: NextFXPlanEligibility { .never }

    /// 来源名称是否已验证。
    var isSourceVerified: Bool { NextFXSourceName.isVerified(sourceName) }

    /// **能不能进入手机的决策上下文**（统一决策上下文 / AI 上下文）。
    /// 硬边界：来源名称未验证 → 就算有汇率数字也一律不许进入。
    /// 这是三道门的合取：来源名称已验证 + 数据可用 + 可作为实时值。
    var entersDecisionContext: Bool { isSourceVerified && isUsable && isRealTime }

    /// 被拦在决策上下文之外时，把原因说清楚（不许只说「没有汇率」）。
    var decisionContextGateNote: String? {
        if isSourceVerified { return nil }
        return "汇率来源名称未验证（\(sourceName.isEmpty ? "无来源名称" : sourceName)）："
            + "即使有汇率数字也不进入决策上下文（已验证的来源：\(NextFXSourceName.verified.joined(separator: "、"))）"
    }

    /// 来源与新鲜度单独一行，界面与 AI 上下文照抄，不许只写涨跌。
    var provenanceNote: String {
        guard state != .notApplicable else { return "" }
        let stamp = exchangeAt.map { Self.timeText($0) } ?? "无"
        let verified = isSourceVerified ? "已验证" : "未验证"
        return "来源 \(source.displayName)（\(sourceName.isEmpty ? "无名称" : sourceName)，\(verified)）"
            + " · 交易所时间戳 \(stamp) · 新鲜度 \(freshness.note)"
    }

    private static func timeText(_ date: Date) -> String {
        date.formatted(date: .numeric, time: .shortened)
    }

    /// 能不能拿来解释标的涨跌。
    var isUsable: Bool {
        if case .available = state { return true }
        return false
    }

    /// 样本是否够算「平均干扰度」。今天的方向不受这条限制。
    var meetsSampleBar: Bool {
        if case let .available(days, _) = state { return days >= NextFXContextEngine.minimumDays }
        return false
    }

    var todayPercent: Double? {
        if case let .available(_, percent) = state { return percent }
        return nil
    }

    var note: String {
        switch state {
        case .notApplicable:
            return "\(market.displayName)无汇率层，不需要换算"
        case let .missing(reason):
            return "\(market.displayName)汇率未接入（\(reason)）：无法把标的涨跌和汇率影响分开，也不会假设汇率为 0"
        case let .stale(reason):
            return "\(market.displayName)汇率数据已过期（\(reason)）：不用旧汇率解释今天的行情；不能当实时值"
        case let .suspicious(reason):
            return "\(market.displayName)汇率数据可疑（\(reason)）：先不当成真实行情，也不能当实时值"
        case let .available(days, percent):
            let direction = percent > 0.001 ? "升值" : (percent < -0.001 ? "贬值" : "基本持平")
            let base = "\(market.displayName)汇率 \(pair?.displayName ?? "")今日\(direction) \(String(format: "%+.2f", percent))%"
            if days >= NextFXContextEngine.minimumDays {
                return "\(base) · 已有 \(days) 个交易日，可算平均干扰度 · \(provenanceNote)"
            }
            return "\(base) · 只有 \(days) 个交易日，不足 \(NextFXContextEngine.minimumDays) 天，暂不算平均干扰度"
        }
    }
}

/// NAS `/v1/fx/series` 的解析（125 汇率上下文的数据传输）。
///
/// 三条规定：
/// 1. 结构不认识就抛错，绝不返回「空但看起来正常」的结果；
/// 2. **来源名称未验证的行直接跳过**——有汇率数字也不许进手机；
/// 3. 把 NAS 的 `stamp`（源时间戳）映射到 `exchangeAt`、`observedAt` 映射到 `receivedAt`，
///    这样手机端算新鲜度时只认交易所时间戳，不会被「刚收到」骗到。
enum NextFXFeed {
    static func parse(_ data: Data) throws -> [NextFXPoint] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let rows = root["rows"] as? [[String: Any]] else {
            throw NextError.invalid("NAS 汇率响应结构无法识别")
        }
        var points: [NextFXPoint] = []
        for row in rows {
            guard let stamp = row["stamp"] as? String,
                  let observed = row["observedAt"] as? String,
                  let sourceName = row["sourceName"] as? String,
                  let exchangeAt = Self.date(stamp),
                  let receivedAt = Self.date(observed),
                  let mid = Self.number(row["mid"]) else { continue }
            // 来源名称未验证的行一律不进手机：有数字但没有身份证明，等于没有。
            guard NextFXSourceName.isVerified(sourceName) else { continue }
            points.append(NextFXPoint(exchangeAt: exchangeAt, receivedAt: receivedAt,
                                      rate: mid, source: .nasArchive, sourceName: sourceName))
        }
        return points.sorted { $0.orderingTime < $1.orderingTime }
    }

    private static func date(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return withFraction.date(from: text) ?? plain.date(from: text)
    }

    private static func number(_ value: Any?) -> Double? {
        if let text = value as? String { return Double(text) }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }
}

/// 汇率修正后的涨跌拆分：标的本身 vs 汇率。
struct NextFXAdjustment: Equatable {
    let localPercent: Double
    let fxPercent: Double
    /// 人民币计价涨跌。
    let cnyPercent: Double
    /// 汇率在「绝对变动之和」里占多大比重（0…1）。
    /// 0.5 以上意味着这天人民币计价的变化主要不是标的走出来的。
    let fxShare: Double

    var isFXDominated: Bool { fxShare >= NextFXContextEngine.contaminationThreshold }

    var note: String {
        let cny = String(format: "%+.2f", cnyPercent)
        let local = String(format: "%+.2f", localPercent)
        let fx = String(format: "%+.2f", fxPercent)
        let share = String(format: "%.0f", fxShare * 100)
        if isFXDominated {
            return "人民币计价 \(cny)% = 标的 \(local)% + 汇率 \(fx)%；汇率解释了 \(share)% 的变动，今天的涨跌不能全算在标的头上"
        }
        return "人民币计价 \(cny)% = 标的 \(local)% + 汇率 \(fx)%；汇率占 \(share)%，标的是主要因素"
    }
}

enum NextFXContextEngine {
    /// 算「平均干扰度」需要的最少独立交易日。
    static let minimumDays = 20
    /// 超过 26 小时没更新就判过期：跨境 ETF 的汇率一天只看一次也够，再久就是没数据。
    static let staleHours = 26.0
    /// 单日跳变超过 3% 先怀疑数据（真实汇率极少单日走这么多，除非有事件）。
    static let jumpThreshold = 3.0
    /// 汇率在绝对变动里占到一半，就算「当天主要被汇率解释」。
    static let contaminationThreshold = 0.50

    static func context(market: NextCrossMarket, series: [NextFXPoint],
                        now: Date) -> NextFXContext {
        guard let pair = NextFXPair.pair(for: market) else {
            return NextFXContext(market: market, pair: nil, state: .notApplicable)
        }
        let sorted = series.filter { $0.rate > 0 }.sorted { $0.orderingTime < $1.orderingTime }
        guard let last = sorted.last else {
            return NextFXContext(market: market, pair: pair, state: .missing("没有汇率序列"))
        }
        // ① 来源必须明确：来源不明的汇率一律不当事实，更不当实时值。
        guard last.source.isTraceable else {
            return NextFXContext(market: market, pair: pair,
                                 state: .suspicious("来源不明，无法当作实时汇率"),
                                 source: last.source, exchangeAt: last.exchangeAt,
                                 receivedAt: last.receivedAt, freshness: .unknown)
        }
        // ①′ **来源名称必须先验证**：即使有汇率数字，
        //    名字不在登记名单里就一律判可疑——有数字但没有身份证明，等于没有。
        guard last.isSourceVerified else {
            return NextFXContext(market: market, pair: pair,
                                 state: .suspicious("来源名称未验证（\(last.sourceName.isEmpty ? "无来源名称" : last.sourceName)）"),
                                 source: last.source, exchangeAt: last.exchangeAt,
                                 receivedAt: last.receivedAt, freshness: .unknown,
                                 sourceName: last.sourceName)
        }
        // ② 必须有交易所时间戳：没有它就没有「新旧」可言。
        //    这是「不把手机/NAS 的旧值伪装成实时」的核心：剩下的只有
        //    「本机什么时候收到的」，而那个时刻和数据的新旧毫无关系。
        guard let exchangeAt = last.exchangeAt else {
            return NextFXContext(market: market, pair: pair,
                                 state: .missing("源没有给出交易所时间戳，不能判断新旧"),
                                 source: last.source, exchangeAt: nil,
                                 receivedAt: last.receivedAt, freshness: .unknown,
                                 sourceName: last.sourceName)
        }
        if exchangeAt > now.addingTimeInterval(60) {
            return NextFXContext(market: market, pair: pair,
                                 state: .suspicious("交易所时间戳晚于当前时间"),
                                 source: last.source, exchangeAt: exchangeAt,
                                 receivedAt: last.receivedAt, freshness: .unknown,
                                 sourceName: last.sourceName)
        }
        // ③ 新鲜度只按交易所时间戳算：**刚收到 ≠ 数据新**。
        let ageHours = now.timeIntervalSince(exchangeAt) / 3600
        let freshness: NextFXFreshness = ageHours <= staleHours
            ? .fresh(ageHours: ageHours) : .stale(ageHours: ageHours)
        if ageHours > staleHours {
            return NextFXContext(market: market, pair: pair,
                                 state: .stale(String(format: "交易所时间戳是 %.1f 小时前", ageHours)),
                                 source: last.source, exchangeAt: exchangeAt,
                                 receivedAt: last.receivedAt, freshness: freshness,
                                 sourceName: last.sourceName)
        }
        let calendar = NextLeadLagEngine.shanghai
        let days = Set(sorted.map { calendar.startOfDay(for: $0.orderingTime) }).count
        let todayPoints = sorted.filter { calendar.isDate($0.orderingTime, inSameDayAs: now) }
        guard todayPoints.count > 1, let firstToday = todayPoints.first, firstToday.rate > 0 else {
            return NextFXContext(market: market, pair: pair, state: .missing("今天还没有汇率变动数据"),
                                 source: last.source, exchangeAt: exchangeAt,
                                 receivedAt: last.receivedAt, freshness: freshness,
                                 sourceName: last.sourceName)
        }
        let percent = (last.rate / firstToday.rate - 1) * 100
        if abs(percent) > jumpThreshold {
            return NextFXContext(market: market, pair: pair,
                                 state: .suspicious(String(format: "单日变动 %.2f%% 超过 %.1f%%，先怀疑数据",
                                                           percent, jumpThreshold)),
                                 source: last.source, exchangeAt: exchangeAt,
                                 receivedAt: last.receivedAt, freshness: freshness,
                                 sourceName: last.sourceName)
        }
        return NextFXContext(market: market, pair: pair,
                             state: .available(days: days, todayPercent: percent),
                             source: last.source, exchangeAt: exchangeAt,
                             receivedAt: last.receivedAt, freshness: freshness,
                             sourceName: last.sourceName)
    }

    /// 只有「源时间戳够新且来源可追溯」才算实时；否则一律不可当实时值。
    /// 手机/NAS 的旧值就算刚刚才被读出来，也仍然过期——这条函数就是那个判断的落点。
    static func isRealTime(_ point: NextFXPoint, now: Date) -> Bool {
        guard point.source.isTraceable, let exchangeAt = point.exchangeAt else { return false }
        let ageHours = now.timeIntervalSince(exchangeAt) / 3600
        return ageHours <= staleHours && exchangeAt <= now.addingTimeInterval(60)
    }

    /// 能不能进入手机的决策上下文：**来源名称必须先验证**。
    /// 有汇率数字不等于可以引用——名字没登记，就一律不许进。
    static func entersDecisionContext(_ point: NextFXPoint, now: Date) -> Bool {
        point.isSourceVerified && isRealTime(point, now: now)
    }

    /// 本币涨跌 + 汇率涨跌 → 人民币计价涨跌。复利口径，不是简单相加。
    static func cnyReturn(localPercent: Double, fxPercent: Double) -> Double {
        ((1 + localPercent / 100) * (1 + fxPercent / 100) - 1) * 100
    }

    /// 汇率在绝对变动里占的比重。两边都接近 0 时返回 0（都无所谓，不算被汇率主导）。
    static func fxShare(localPercent: Double, fxPercent: Double) -> Double {
        let total = abs(localPercent) + abs(fxPercent)
        guard total > 0.000_001 else { return 0 }
        return abs(fxPercent) / total
    }

    /// 只有在汇率上下文可用时才给拆分。不可用时返回 nil——
    /// 宁可不说，也不能假设汇率为 0 然后把影响算到标的上。
    static func adjust(localPercent: Double, context: NextFXContext) -> NextFXAdjustment? {
        guard case let .available(_, fxPercent) = context.state else { return nil }
        return NextFXAdjustment(localPercent: localPercent,
                                fxPercent: fxPercent,
                                cnyPercent: cnyReturn(localPercent: localPercent, fxPercent: fxPercent),
                                fxShare: fxShare(localPercent: localPercent, fxPercent: fxPercent))
    }
}
