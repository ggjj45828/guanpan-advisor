import Foundation

// MARK: - 136/137 时间统一与市场日历
//
// 跨市场研究最容易错的两件事：把不同时区的数据按「第几根 K 线」对齐，以及
// 把休市市场的上一交易日数据当成今天的实时信号。本文件所有时间内部一律用 UTC `Date`，
// 只在展示层转北京时间；时区/夏令时交给 `TimeZone` + `Calendar`，手写偏移一定会错。

/// 交易时段窗口，用「本地时间当天第几分钟」表示，避免再引入一个 Date 造成时区歧义。
struct NextMarketWindow: Equatable {
    let startMinute: Int
    let endMinute: Int
    func contains(_ minute: Int) -> Bool { minute >= startMinute && minute < endMinute }
}

/// 市场开闭状态。`holiday` 与 `weekend` 分开：前者要注入节假日表，后者由日历直接算。
enum NextMarketStatus: String, Equatable {
    case open, lunchBreak, preOpen, closed, weekend, holiday
    var isTrading: Bool { self == .open }
    /// 只有真正在交易的市场，其最新价才可以当作「今天的信息」。
    var providesLiveInformation: Bool { self == .open || self == .lunchBreak }
}

enum NextCrossMarket: String, CaseIterable, Codable, Identifiable {
    case china, hongKong, japan, korea, unitedStates
    var id: String { rawValue }

    var timeZoneID: String {
        switch self {
        case .china: return "Asia/Shanghai"
        case .hongKong: return "Asia/Hong_Kong"
        case .japan: return "Asia/Tokyo"
        case .korea: return "Asia/Seoul"
        case .unitedStates: return "America/New_York"
        }
    }
    var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? TimeZone(identifier: "UTC")! }
    var displayName: String {
        switch self {
        case .china: return "A股"
        case .hongKong: return "香港"
        case .japan: return "日本"
        case .korea: return "韩国"
        case .unitedStates: return "美股"
        }
    }
    /// 常规时段。A股/港股有午休，日韩没有；美股无午休。
    var windows: [NextMarketWindow] {
        switch self {
        case .china:
            return [NextMarketWindow(startMinute: 9 * 60 + 30, endMinute: 11 * 60 + 30),
                    NextMarketWindow(startMinute: 13 * 60, endMinute: 15 * 60)]
        case .hongKong:
            return [NextMarketWindow(startMinute: 9 * 60 + 30, endMinute: 12 * 60),
                    NextMarketWindow(startMinute: 13 * 60, endMinute: 16 * 60)]
        case .japan:
            return [NextMarketWindow(startMinute: 9 * 60, endMinute: 11 * 60 + 30),
                    NextMarketWindow(startMinute: 12 * 60 + 30, endMinute: 15 * 60 + 30)]
        case .korea:
            return [NextMarketWindow(startMinute: 9 * 60, endMinute: 15 * 60 + 30)]
        case .unitedStates:
            return [NextMarketWindow(startMinute: 9 * 60 + 30, endMinute: 16 * 60)]
        }
    }
}

/// 市场日历。节假日**必须由调用方注入**（每年初由交易所公告发布），
/// 这里不内置一张会过期的表——猜节假日等于猜哪天有实时信号。
struct NextMarketCalendar {
    var holidays: [NextCrossMarket: Set<String>] = [:]

    private func dayKey(_ date: Date, _ market: NextCrossMarket) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = market.timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    func minuteOfDay(_ date: Date, _ market: NextCrossMarket) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = market.timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    func status(_ market: NextCrossMarket, at date: Date) -> NextMarketStatus {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = market.timeZone
        let weekday = calendar.component(.weekday, from: date)
        if weekday == 1 || weekday == 7 { return .weekend }
        if holidays[market]?.contains(dayKey(date, market)) == true { return .holiday }
        let minute = minuteOfDay(date, market)
        let windows = market.windows
        if windows.contains(where: { $0.contains(minute) }) { return .open }
        guard let first = windows.first, let last = windows.last else { return .closed }
        if windows.count > 1 {
            for index in 1..<windows.count {
                if minute >= windows[index - 1].endMinute && minute < windows[index].startMinute { return .lunchBreak }
            }
        }
        if minute < first.startMinute { return .preOpen }
        if minute >= last.endMinute { return .closed }
        return .closed
    }

    /// 某市场的午休区间（用于 119 午休信息差）；没有午休返回 nil。
    func lunchBreak(_ market: NextCrossMarket, at date: Date) -> (start: Date, end: Date)? {
        let windows = market.windows
        guard windows.count >= 2 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = market.timeZone
        let day = calendar.startOfDay(for: date)
        func stamp(_ minute: Int) -> Date? {
            calendar.date(byAdding: .minute, value: minute, to: day)
        }
        guard let start = stamp(windows[0].endMinute), let end = stamp(windows[1].startMinute) else { return nil }
        return (start, end)
    }
}

// MARK: - 138 新鲜度
//
// 每个跨市场信号都必须能回答：谁给的、几点给的、多久了、那个市场现在开没开。
// 过期或休市的价格不能当今天的先行信号用，权重直接降为 0。

struct NextCrossMarketFreshness: Equatable {
    let market: NextCrossMarket
    let source: String
    let observedAt: Date
    let ageMinutes: Int
    let marketStatus: NextMarketStatus

    var usable: Bool { marketStatus.providesLiveInformation && ageMinutes <= 30 }
    var note: String {
        let stamp = NextCrossMarketFreshness.timeText(observedAt)
        if marketStatus == .holiday { return "\(market.displayName) 今日休市，最新数据 \(stamp) 仅作历史参考" }
        if marketStatus == .weekend { return "\(market.displayName) 周末休市" }
        if ageMinutes > 30 { return "\(market.displayName) 数据已 \(ageMinutes) 分钟未更新（\(stamp)），不参与今日判断" }
        if marketStatus == .lunchBreak { return "\(market.displayName) 午休中 · \(stamp)" }
        return "\(market.displayName) \(stamp) · \(ageMinutes) 分钟前"
    }
    /// 权重：0 表示这条数据不得进入结论。
    var weight: Double {
        if !usable { return 0 }
        if ageMinutes <= 5 { return 1 }
        if ageMinutes <= 15 { return 0.6 }
        return 0.3
    }
    static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - 序列与对齐（135 防未来函数）
//
// 对齐铁律：领先市场的 t 时刻信息，只能与跟随市场 **t 之后** 的观测配对。
// 反向配对（用跟随市场的 t 去解释领先市场的 t）就是把未来当已知。

struct NextMarketPoint: Equatable {
    let timestamp: Date
    let value: Double
}

enum NextCrossMarketAlignment {
    /// 跟随序列中第一个 >= 给定时间的观测。找不到就返回 nil，不拿更早的数据顶替。
    static func firstPoint(atOrAfter time: Date, in series: [NextMarketPoint], tolerance: TimeInterval) -> NextMarketPoint? {
        series.first { $0.timestamp >= time && $0.timestamp.timeIntervalSince(time) <= tolerance }
    }

    /// 给定时间之前（含）最后一个观测。用于「12:50 只能看 12:50 以前」。
    static func lastPoint(atOrBefore time: Date, in series: [NextMarketPoint]) -> NextMarketPoint? {
        series.last { $0.timestamp <= time }
    }

    static func changePercent(from: Double, to: Double) -> Double? {
        guard from > 0, to > 0 else { return nil }
        return (to / from - 1) * 100
    }
}

// MARK: - 117 Lead-Lag 统计

/// 一个领先窗口的完整统计。刻意不只存一个相关系数：
/// 相关系数会被趋势段放大，胜率/中位收益/最大不利波动才回答「能不能用」。
///
/// 148 起样本单位改成**独立交易日**。原因很硬：同一天里的分钟观测彼此高度相关，
/// 80 根 5 分钟 K 线看上去有 80 个样本，真实的独立信息量大概只有 1 天。
/// 按分钟计数会让任何两条曲线在单日里都「显著」，这是假信心的主要来源。
struct NextLeadLagWindow: Equatable {
    let minutes: Int
    /// 分钟级配对数量。**不再是证据门槛**，只作为「够不够算相关系数」的技术底线。
    let sampleCount: Int
    /// 独立交易日数量。这是唯一被承认的样本单位。
    let independentDays: Int
    let correlation: Double
    /// 分钟级同向率，只用于展示。
    let sameDirectionRate: Double
    /// 日级同向率的 Wilson 95% 置信下界，n 取独立交易日数。
    /// 用它而不是点估计：8 个窗口里挑最高的那个，点估计天然偏高。
    let wilsonLowerBound: Double
    /// 相关性 Fisher z 检验后乘以窗口数的 Bonferroni 校正 p 值。
    let bonferroniP: Double
    /// 留出段（按时间最后 1/3）的独立交易日数。前段拟合、后段必须还有样本。
    let holdoutDays: Int
    let meanFollowReturn: Double
    let medianFollowReturn: Double
    let positiveRatio: Double
    let maxAdverseReturn: Double
    /// 前后两段子样本相关系数同号的比例（0…1）。用来识别「只在某一段成立」。
    let stability: Double

    /// 统计层门槛：全部通过才叫「值得登记前瞻复现」。
    /// 注意它**不等于**可以交易——那只由 `NextLeadLagStudy.eligibleForTradingSignal` 决定。
    var passesStatisticalBar: Bool {
        independentDays >= NextLeadLagEngine.minimumIndependentDays
            && sampleCount >= NextLeadLagEngine.minimumPairs
            && abs(correlation) >= NextLeadLagEngine.minimumCorrelation
            && stability >= NextLeadLagEngine.minimumStability
            && wilsonLowerBound >= NextLeadLagEngine.minimumWilsonLowerBound
            && bonferroniP <= NextLeadLagEngine.maximumBonferroniP
            && holdoutDays >= NextLeadLagEngine.minimumHoldoutDays
    }
}

enum NextLeadLagVerdict: Equatable {
    case insufficient(String)
    case usable(best: NextLeadLagWindow, windows: [NextLeadLagWindow], periodDays: Int, lastValidated: Date)
}

struct NextLeadLagStudy: Equatable {
    let lead: NextCrossMarket
    let followCode: String
    let verdict: NextLeadLagVerdict
    /// 预注册前瞻复现进度。默认 `.none`（没登记过），因此默认不具备交易资格。
    let replication: NextSignalReplication

    init(lead: NextCrossMarket, followCode: String, verdict: NextLeadLagVerdict,
         replication: NextSignalReplication = .none) {
        self.lead = lead
        self.followCode = followCode
        self.verdict = verdict
        self.replication = replication
    }

    var best: NextLeadLagWindow? {
        if case let .usable(best, _, _, _) = verdict { return best }
        return nil
    }

    /// 统计门槛是否通过。通过只代表「这条关系值得继续跟踪」。
    var passesStatisticalBar: Bool { best?.passesStatisticalBar == true }

    /// 是否能作为方向性交易信号。**默认 False**：
    /// 历史统计再漂亮也不算授权，必须有预注册之后发生的前瞻兑现。
    var eligibleForTradingSignal: Bool {
        guard passesStatisticalBar else { return false }
        return NextSignalReplicationEngine.allowsTradingSignal(replication)
    }

    /// 没通过时给人看的一句话，指出差在统计还是差在前瞻。
    var signalEligibilityNote: String {
        guard passesStatisticalBar else {
            return "统计门槛未通过，暂无稳定领先关系"
        }
        if eligibleForTradingSignal {
            return "前瞻复现已达标（\(replication.confirmedCount) 次兑现），可作为信号使用"
        }
        return NextSignalReplicationEngine.blockReason(replication)
    }

    /// 回填复现进度，其余字段不动。
    func with(replication newValue: NextSignalReplication) -> NextLeadLagStudy {
        NextLeadLagStudy(lead: lead, followCode: followCode, verdict: verdict, replication: newValue)
    }

    var summary: String {
        switch verdict {
        case let .insufficient(reason):
            return "暂无稳定领先关系（\(reason)）"
        case let .usable(best, _, days, _):
            let p = String(format: "%.3f", best.bonferroniP)
            return "\(lead.displayName) 领先 \(best.minutes) 分钟：独立 \(best.independentDays) 日 · 相关 \(NextLeadLagStudy.percent(best.correlation, digits: 2)) · 同向下界 \(NextLeadLagStudy.percent(best.wilsonLowerBound, digits: 0)) · p校正 \(p) · 近 \(days) 日"
        }
    }
    static func percent(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f%%", value * 100)
    }
}

enum NextLeadLagEngine {
    // 148：证据门槛全部改成「独立交易日」口径。
    /// 技术底线：配对太少连相关系数都不该算。
    static let minimumPairs = 30
    /// 证据门槛：至少 20 个独立交易日。30 个自然日大约只有 20 个交易日，
    /// 所以这条线基本要求「至少一个月的真实数据」，单日分时永远过不了。
    static let minimumIndependentDays = 20
    static let minimumCorrelation = 0.20
    static let minimumStability = 0.6
    /// 日级同向率的 Wilson 95% 下界。0.55 意味着「即便按最悲观估计，也比掷硬币好」。
    static let minimumWilsonLowerBound = 0.55
    /// Bonferroni 校正后的显著性门槛。默认比较 8 个窗口，等于把单次门槛压到 0.006。
    static let maximumBonferroniP = 0.05
    /// 留出段至少要有 5 个独立交易日，否则「后段还成立」这句话没有证据。
    static let minimumHoldoutDays = 5
    /// 默认窗口数，用于 Bonferroni 校正。调用方传了就按传入的算。
    static let defaultWindowCount = 8

    static var shanghai: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(identifier: "UTC")!
        return calendar
    }

    static func study(lead: NextCrossMarket, leadSeries: [NextMarketPoint],
                      followCode: String, followSeries: [NextMarketPoint],
                      windowsMinutes: [Int] = [0, 5, 10, 15, 30, 45, 60, 90],
                      observedFrom: Date? = nil,
                      lastValidated: Date,
                      replication: NextSignalReplication = .none,
                      includePair: ((Date) -> Bool)? = nil) -> NextLeadLagStudy {
        let leadSorted = leadSeries.sorted { $0.timestamp < $1.timestamp }
        let followSorted = followSeries.sorted { $0.timestamp < $1.timestamp }
        guard leadSorted.count >= 2, followSorted.count >= 2 else {
            return NextLeadLagStudy(lead: lead, followCode: followCode,
                                    verdict: .insufficient("领先或跟随序列样本不足"))
        }
        let comparisonCount = max(1, windowsMinutes.count)
        var results: [NextLeadLagWindow] = []
        for minutes in windowsMinutes.sorted() {
            guard let window = window(lead: leadSorted, follow: followSorted, minutes: minutes,
                                      observedFrom: observedFrom,
                                      comparisonCount: comparisonCount,
                                      includePair: includePair) else { continue }
            results.append(window)
        }
        // 先按全部统计门槛筛。挑不出任何一条时，把「最接近及格」的那条的短板说出来，
        // 不能只回一句「样本不足」——那样用户没法知道是缺数据还是关系真的不存在。
        let passing = results.filter(\.passesStatisticalBar)
        guard let best = passing.max(by: { abs($0.correlation) < abs($1.correlation) }) else {
            let closest = results.max { lhs, rhs in
                score(lhs) < score(rhs)
            }
            let reason = closest.map { whyNot($0) } ?? "没有任何窗口算出有效配对"
            return NextLeadLagStudy(lead: lead, followCode: followCode,
                                    verdict: .insufficient(reason), replication: replication)
        }
        // 多窗口一致性：最佳窗口若孤立（相邻窗口都远弱），更可能是挑选偏差。
        let neighbours = results.filter { abs($0.minutes - best.minutes) == 5 || abs($0.minutes - best.minutes) == 10 }
        if !neighbours.isEmpty,
           neighbours.allSatisfy({ abs($0.correlation) < abs(best.correlation) * 0.4 }) {
            return NextLeadLagStudy(lead: lead, followCode: followCode,
                                    verdict: .insufficient("只有单一窗口吻合、相邻窗口不支持，疑似多重比较挑出来的"),
                                    replication: replication)
        }
        let spanDays = max(1, Int((lastValidated.timeIntervalSince(leadSorted.first!.timestamp)) / 86_400))
        return NextLeadLagStudy(lead: lead, followCode: followCode,
                                verdict: .usable(best: best, windows: results, periodDays: spanDays,
                                                 lastValidated: lastValidated),
                                replication: replication)
    }

    /// 及格项数，用来在全部不及格时挑出「最接近」的一条做解释。
    private static func score(_ window: NextLeadLagWindow) -> Int {
        var value = 0
        if window.independentDays >= minimumIndependentDays { value += 1 }
        if window.sampleCount >= minimumPairs { value += 1 }
        if abs(window.correlation) >= minimumCorrelation { value += 1 }
        if window.stability >= minimumStability { value += 1 }
        if window.wilsonLowerBound >= minimumWilsonLowerBound { value += 1 }
        if window.bonferroniP <= maximumBonferroniP { value += 1 }
        if window.holdoutDays >= minimumHoldoutDays { value += 1 }
        return value
    }

    /// 说清短板。顺序按「最根本的缺什么」排：样本量永远排在显著性前面。
    static func whyNot(_ window: NextLeadLagWindow) -> String {
        if window.independentDays < minimumIndependentDays {
            return "独立交易日只有 \(window.independentDays) 天，门槛 \(minimumIndependentDays) 天（同一天里的 \(window.sampleCount) 个分钟配对数不算独立证据）"
        }
        if window.holdoutDays < minimumHoldoutDays {
            return "留出段只有 \(window.holdoutDays) 个交易日，不到 \(minimumHoldoutDays) 天，无法验证后段是否仍成立"
        }
        if abs(window.correlation) < minimumCorrelation {
            return "相关性 \(NextLeadLagStudy.percent(window.correlation, digits: 2)) 低于门槛，可能只是同涨同跌"
        }
        if window.bonferroniP > maximumBonferroniP {
            return "Bonferroni 校正后 p = \(String(format: "%.3f", window.bonferroniP)) 不显著（\(defaultWindowCount) 个窗口的多重比较已扣除）"
        }
        if window.wilsonLowerBound < minimumWilsonLowerBound {
            return "日级同向率 \(NextLeadLagStudy.percent(window.sameDirectionRate, digits: 0))，但 Wilson 95% 下界只有 \(NextLeadLagStudy.percent(window.wilsonLowerBound, digits: 0))，低于 \(NextLeadLagStudy.percent(minimumWilsonLowerBound, digits: 0))"
        }
        if window.stability < minimumStability {
            return "前后两段方向不一致（稳定度 \(NextLeadLagStudy.percent(window.stability, digits: 0))），不当作稳定关系"
        }
        return "统计门槛未通过"
    }

    /// 这条「不足」是**数据长度不够**，还是**关系确实不成立**？
    /// 两者对用户的含义完全相反：前者是「再等几天就有结论」，后者是「别指望它」。
    /// 判定靠原因文案，因为 insufficient 的文案只在本文件产生，属于内部契约。
    static func isSampleLimited(_ reason: String) -> Bool {
        reason.contains("独立交易日只有")
            || reason.contains("留出段只有")
            || reason.contains("样本不足")
            || reason.contains("没有任何窗口算出有效配对")
            || reason.contains("序列样本不足")
    }

    /// 单窗口统计。返回 nil 表示这个窗口一个有效配对都没有。
    /// - Parameter includePair: 只统计时间戳满足条件的配对点（条件化领先 121 与时间段画像 132 用）。
    ///   刻意放在「配对生成」这一层过滤，而不是先切片序列：
    ///   序列切片会破坏 t → t+窗口 的配对关系，得到的相关系数没有意义。
    static func window(lead: [NextMarketPoint], follow: [NextMarketPoint],
                       minutes: Int, observedFrom: Date?,
                       comparisonCount: Int = NextLeadLagEngine.defaultWindowCount,
                       includePair: ((Date) -> Bool)? = nil) -> NextLeadLagWindow? {
        let windowSeconds = Double(minutes) * 60
        let tolerance = max(windowSeconds, 60) + 60
        var leadChanges: [Double] = []
        var followChanges: [Double] = []
        var pairs: [(leadTime: Date, leadChange: Double, followChange: Double)] = []
        for point in lead {
            if let floor = observedFrom, point.timestamp < floor { continue }
            if let includePair, !includePair(point.timestamp) { continue }
            guard let previous = NextCrossMarketAlignment.lastPoint(atOrBefore: point.timestamp.addingTimeInterval(-windowSeconds),
                                                                   in: lead) else { continue }
            guard let leadChange = NextCrossMarketAlignment.changePercent(from: previous.value, to: point.value) else { continue }
            guard let exit = NextCrossMarketAlignment.firstPoint(atOrAfter: point.timestamp, in: follow,
                                                                 tolerance: tolerance) else { continue }
            // 跟随序列的收益必须覆盖「t → t+窗口」：用 t 之后窗口末端的点，而不是 t 当点。
            guard let followEnd = NextCrossMarketAlignment.firstPoint(atOrAfter: point.timestamp.addingTimeInterval(windowSeconds),
                                                                      in: follow, tolerance: tolerance) else { continue }
            guard let followReturn = NextCrossMarketAlignment.changePercent(from: exit.value, to: followEnd.value) else { continue }
            leadChanges.append(leadChange)
            followChanges.append(followReturn)
            pairs.append((point.timestamp, leadChange, followReturn))
        }
        guard pairs.count >= 3 else { return nil }
        let correlation = pearson(leadChanges, followChanges)
        let sameDirection = zip(leadChanges, followChanges)
            .filter { pair in pair.0 != 0 && (pair.0 > 0) == (pair.1 > 0) }
            .count
        let positive = followChanges.filter { $0 > 0 }.count
        let sortedFollow = followChanges.sorted()
        let median = sortedFollow[sortedFollow.count / 2]
        let mean = followChanges.reduce(0, +) / Double(followChanges.count)
        let stability = splitStability(pairs)

        // 独立交易日：按北京时间自然日归组。
        let grouped = Dictionary(grouping: pairs) { shanghai.startOfDay(for: $0.leadTime) }
        let days = grouped.keys.sorted()
        let independentDays = days.count
        // 日级同向：当天领先净变化与跟随净变化同号，才算这一天「支持」这条关系。
        var dailyAgree = 0
        for day in days {
            let group = grouped[day] ?? []
            let leadNet = group.reduce(0.0) { $0 + $1.leadChange }
            let followNet = group.reduce(0.0) { $0 + $1.followChange }
            if leadNet != 0, followNet != 0, (leadNet > 0) == (followNet > 0) { dailyAgree += 1 }
        }
        let lowerBound = wilsonLowerBound(successes: dailyAgree, trials: independentDays)
        let p = fisherTwoSidedP(r: correlation, n: independentDays)
        let adjustedP = min(1, p * Double(max(1, comparisonCount)))
        // 留出段：按时间最后 1/3 的配对覆盖到几个独立交易日。
        let ordered = pairs.sorted { $0.leadTime < $1.leadTime }
        let holdoutStart = ordered.count >= 6 ? ordered.count * 2 / 3 : ordered.count
        let holdoutPairs = Array(ordered.suffix(from: holdoutStart))
        let holdoutDays = Set(holdoutPairs.map { shanghai.startOfDay(for: $0.leadTime) }).count

        return NextLeadLagWindow(minutes: minutes, sampleCount: pairs.count,
                                 independentDays: independentDays,
                                 correlation: correlation,
                                 sameDirectionRate: pairs.isEmpty ? 0 : Double(sameDirection) / Double(pairs.count),
                                 wilsonLowerBound: lowerBound,
                                 bonferroniP: adjustedP,
                                 holdoutDays: holdoutDays,
                                 meanFollowReturn: mean,
                                 medianFollowReturn: median,
                                 positiveRatio: Double(positive) / Double(followChanges.count),
                                 maxAdverseReturn: sortedFollow.first ?? 0,
                                 stability: stability)
    }

    /// Wilson 区间下界。小样本时比 p̂ 低很多，这正是我们要的保守性。
    static func wilsonLowerBound(successes: Int, trials: Int, z: Double = 1.96) -> Double {
        guard trials > 0 else { return 0 }
        let n = Double(trials)
        let p = Double(successes) / n
        let denominator = 1 + z * z / n
        let centre = p + z * z / (2 * n)
        let margin = z * (p * (1 - p) / n + z * z / (4 * n * n)).squareRoot()
        return max(0, (centre - margin) / denominator)
    }

    /// 相关系数的双尾显著性：Fisher z 变换 + 正态近似。
    /// n 用独立交易日数，所以「一天里多少根 K 线」不会把 p 值压低。
    static func fisherTwoSidedP(r: Double, n: Int) -> Double {
        guard n > 3 else { return 1 }
        let clamped = max(-0.999_999, min(0.999_999, r))
        // 用 log 展开而不是 atanh：两者等价，但 log 在所有平台都不需要额外导入。
        let fisherZ = 0.5 * log((1 + clamped) / (1 - clamped))
        let z = fisherZ * Double(n - 3).squareRoot()
        return 1 - NextLeadLagEngine.erf(abs(z) / Double(2).squareRoot())
    }

    /// Abramowitz & Stegun 7.1.26，绝对误差 < 1.5e-7。够用了，不值得为此引入依赖。
    static func erf(_ x: Double) -> Double {
        let sign: Double = x < 0 ? -1 : 1
        let ax = abs(x)
        let t = 1 / (1 + 0.3275911 * ax)
        let a1 = 0.254829592, a2 = -0.284496736, a3 = 1.421413741
        let a4 = -1.453152027, a5 = 1.061405429
        let poly = ((((a5 * t + a4) * t + a3) * t + a2) * t + a1)
        return sign * (1 - poly * t * exp(-ax * ax))
    }

    /// 前后两段相关系数是否同号。只在某一段成立的关系，不能当稳定关系用。
    private static func splitStability(_ pairs: [(leadTime: Date, leadChange: Double, followChange: Double)]) -> Double {
        guard pairs.count >= 6 else { return 0 }
        let half = pairs.count / 2
        let first = Array(pairs.prefix(half))
        let second = Array(pairs.suffix(half))
        let a = pearson(first.map(\.leadChange), first.map(\.followChange))
        let b = pearson(second.map(\.leadChange), second.map(\.followChange))
        if a == 0 || b == 0 { return 0 }
        return (a > 0) == (b > 0) ? 1 : 0
    }

    static func pearson(_ xs: [Double], _ ys: [Double]) -> Double {
        guard xs.count == ys.count, xs.count >= 2 else { return 0 }
        let n = Double(xs.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        var covariance = 0.0, varianceX = 0.0, varianceY = 0.0
        for index in xs.indices {
            let dx = xs[index] - meanX
            let dy = ys[index] - meanY
            covariance += dx * dy
            varianceX += dx * dx
            varianceY += dy * dy
        }
        guard varianceX > 0, varianceY > 0 else { return 0 }
        return covariance / (varianceX.squareRoot() * varianceY.squareRoot())
    }
}

// MARK: - 119/120 午休信息差

struct NextLunchBreakShock: Equatable {
    let market: NextCrossMarket
    let lunchStart: Date
    let lateLunch: Date
    /// A股 11:30 时该市场相对其前收的涨跌幅。
    let preLunchChange: Double
    /// 12:50 时同一基准的涨跌幅。
    let lateLunchChange: Double
    /// 休市期间新增的信息量（百分点）。正数代表风险偏好在修复。
    var shock: Double { lateLunchChange - preLunchChange }
    var note: String {
        let direction = shock > 0.05 ? "修复" : (shock < -0.05 ? "转弱" : "基本持平")
        return "\(market.displayName)午休期间\(direction) \(String(format: "%+.2f", shock)) 个百分点"
    }
}

enum NextLunchBreakEngine {
    /// 只允许用 11:30 前与 12:50 前这两个时点的数据，12:50 之后的数据一律不许进来（135）。
    static func shock(market: NextCrossMarket, series: [NextMarketPoint],
                      previousClose: Double, lunch: (start: Date, end: Date),
                      lastLunchCheckpoint: TimeInterval = 10 * 60) -> NextLunchBreakShock? {
        let cutoff = lunch.end.addingTimeInterval(-lastLunchCheckpoint)
        guard let pre = NextCrossMarketAlignment.lastPoint(atOrBefore: lunch.start, in: series),
              let late = NextCrossMarketAlignment.lastPoint(atOrBefore: cutoff, in: series),
              pre.timestamp < late.timestamp,
              let preChange = NextCrossMarketAlignment.changePercent(from: previousClose, to: pre.value),
              let lateChange = NextCrossMarketAlignment.changePercent(from: previousClose, to: late.value) else { return nil }
        return NextLunchBreakShock(market: market, lunchStart: lunch.start, lateLunch: late.timestamp,
                                   preLunchChange: preChange, lateLunchChange: lateChange)
    }
}

// MARK: - 120 午后反应统计
//
// 回答的是「午休期间出现的新信息，A股午后多久反应、反应多大、最坏能逆行多少」。
// 这不是预测，是把过去 N 天同一时点的表现摊开：每个检查点用了几天、涨的比例、
// 中位涨幅、最大不利波动。样本不够就明说「暂无稳定规律」。

/// 一个检查点（相对 13:00 的分钟数；nil 表示收盘）。
struct NextAfternoonCheckpoint: Equatable {
    let label: String
    let minutes: Int?
    static let standard: [NextAfternoonCheckpoint] = [
        NextAfternoonCheckpoint(label: "13:05", minutes: 5),
        NextAfternoonCheckpoint(label: "13:15", minutes: 15),
        NextAfternoonCheckpoint(label: "13:30", minutes: 30),
        NextAfternoonCheckpoint(label: "14:00", minutes: 60),
        NextAfternoonCheckpoint(label: "收盘", minutes: nil),
    ]
}

/// 单个检查点的统计。
struct NextAfternoonReactionBucket: Equatable {
    let label: String
    let sampleDays: Int
    /// 上涨天数占比（0…1）。
    let positiveRate: Double
    let meanReturn: Double
    let medianReturn: Double
    /// 最大不利波动（最小的那个收益，负数即逆行）。
    let maxAdverseReturn: Double
    var text: String {
        let positive = String(format: "%.0f", positiveRate * 100)
        return "\(label) 涨 \(positive)% · 中位 \(String(format: "%+.2f", medianReturn))% · 最差 \(String(format: "%+.2f", maxAdverseReturn))%"
    }
}

/// 一个交易日午后的原始素材。
struct NextAfternoonSession: Equatable {
    let date: Date
    let lunchEnd: Date
    /// 当日是否满足前置条件（例如「海外午休修复 ≥0.5pp 且 A股上午下跌」）。
    let conditionMet: Bool
    let points: [NextMarketPoint]
}

struct NextAfternoonReactionStudy: Equatable {
    let code: String
    let conditionText: String
    let totalDays: Int
    let conditionedDays: Int
    /// 满足条件的样本。
    let conditioned: [NextAfternoonReactionBucket]
    /// 全部样本，用作对照：条件成立时是否真的比平常更好。
    let unconditional: [NextAfternoonReactionBucket]
    let hasStablePattern: Bool
    let note: String

    var summary: String {
        guard let close = conditioned.last else { return "暂无稳定规律（没有可用样本）" }
        if !hasStablePattern { return "暂无稳定规律：\(note)" }
        return "\(conditionText)：\(conditionedDays) 天样本，\(close.text)"
    }
}

enum NextAfternoonReactionEngine {
    /// 少于此天数一律不下结论。
    static let minimumDays = 20
    /// 收盘检查点的上涨比例要偏离 50% 至少这么多，才算「有方向」。
    static let minimumEdge = 0.10

    static func study(code: String, conditionText: String, sessions: [NextAfternoonSession],
                      checkpoints: [NextAfternoonCheckpoint] = NextAfternoonCheckpoint.standard) -> NextAfternoonReactionStudy {
        let ordered = sessions.sorted { $0.date < $1.date }
        let conditionedSessions = ordered.filter { $0.conditionMet }
        let conditioned = buckets(sessions: conditionedSessions, checkpoints: checkpoints)
        let unconditional = buckets(sessions: ordered, checkpoints: checkpoints)
        let closeBucket = conditioned.last
        let sampleDays = closeBucket?.sampleDays ?? 0
        var stable = false
        var note = ""
        if sampleDays < minimumDays {
            note = "满足条件的样本只有 \(sampleDays) 天，少于 \(minimumDays) 天，不能下结论"
        } else if let closeBucket {
            let edge = abs(closeBucket.positiveRate - 0.5)
            stable = edge >= minimumEdge
            if !stable {
                note = "收盘上涨比例 \(String(format: "%.0f", closeBucket.positiveRate * 100))% 与随机无异（偏离不足 \(String(format: "%.0f", minimumEdge * 100)) 个百分点）"
            } else {
                note = "收盘上涨比例 \(String(format: "%.0f", closeBucket.positiveRate * 100))%，样本 \(sampleDays) 天"
            }
        } else {
            note = "没有可用的午后分时"
        }
        return NextAfternoonReactionStudy(code: code, conditionText: conditionText,
                                          totalDays: ordered.count, conditionedDays: sampleDays,
                                          conditioned: conditioned, unconditional: unconditional,
                                          hasStablePattern: stable, note: note)
    }

    static func buckets(sessions: [NextAfternoonSession],
                        checkpoints: [NextAfternoonCheckpoint]) -> [NextAfternoonReactionBucket] {
        var result: [NextAfternoonReactionBucket] = []
        for checkpoint in checkpoints {
            var returns: [Double] = []
            for session in sessions {
                guard let base = NextCrossMarketAlignment.firstPoint(atOrAfter: session.lunchEnd,
                                                                     in: session.points, tolerance: 15 * 60) else { continue }
                let target: NextMarketPoint?
                if let minutes = checkpoint.minutes {
                    target = NextCrossMarketAlignment.lastPoint(atOrBefore: session.lunchEnd.addingTimeInterval(Double(minutes) * 60),
                                                                in: session.points)
                } else {
                    target = session.points.last
                }
                guard let target, target.timestamp > base.timestamp,
                      let change = NextCrossMarketAlignment.changePercent(from: base.value, to: target.value) else { continue }
                returns.append(change)
            }
            guard !returns.isEmpty else {
                result.append(NextAfternoonReactionBucket(label: checkpoint.label, sampleDays: 0,
                                                          positiveRate: 0, meanReturn: 0, medianReturn: 0,
                                                          maxAdverseReturn: 0))
                continue
            }
            let sorted = returns.sorted()
            let positive = returns.filter { $0 > 0 }.count
            let median = sorted.count % 2 == 0
                ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
                : sorted[sorted.count / 2]
            result.append(NextAfternoonReactionBucket(
                label: checkpoint.label, sampleDays: returns.count,
                positiveRate: Double(positive) / Double(returns.count),
                meanReturn: returns.reduce(0, +) / Double(returns.count),
                medianReturn: median, maxAdverseReturn: sorted.first ?? 0))
        }
        return result
    }
}

// MARK: - 122 跨市场背离

enum NextDivergenceDirection: String, Equatable { case potentialCatchUp, potentialDrop }

struct NextCrossDivergence: Equatable {
    let direction: NextDivergenceDirection
    let overseasChange: Double
    let localChange: Double
    let gap: Double
    var note: String {
        switch direction {
        case .potentialCatchUp:
            return "海外已修复 \(String(format: "%+.2f", overseasChange))% 而本地仍 \(String(format: "%+.2f", localChange))%，存在补涨观察价值（需本地确认，不直接买）"
        case .potentialDrop:
            return "海外转弱 \(String(format: "%+.2f", overseasChange))% 而本地仍 \(String(format: "%+.2f", localChange))%，注意补跌与反T观察"
        }
    }
}

enum NextDivergenceDetector {
    /// 背离必须是「海外明显动了、本地没动」，不是两个方向不同就算。
    static func detect(overseas: [NextMarketPoint], local: [NextMarketPoint],
                       lookbackMinutes: Int, thresholdPercent: Double,
                       now: Date) -> NextCrossDivergence? {
        let lookback = Double(lookbackMinutes) * 60
        guard let overseasStart = NextCrossMarketAlignment.lastPoint(atOrBefore: now.addingTimeInterval(-lookback), in: overseas),
              let overseasNow = NextCrossMarketAlignment.lastPoint(atOrBefore: now, in: overseas),
              let localStart = NextCrossMarketAlignment.lastPoint(atOrBefore: now.addingTimeInterval(-lookback), in: local),
              let localNow = NextCrossMarketAlignment.lastPoint(atOrBefore: now, in: local),
              let overseasChange = NextCrossMarketAlignment.changePercent(from: overseasStart.value, to: overseasNow.value),
              let localChange = NextCrossMarketAlignment.changePercent(from: localStart.value, to: localNow.value) else { return nil }
        let gap = abs(overseasChange) - abs(localChange)
        guard abs(overseasChange) >= thresholdPercent, gap >= thresholdPercent else { return nil }
        if overseasChange > 0, localChange < overseasChange {
            return NextCrossDivergence(direction: .potentialCatchUp, overseasChange: overseasChange,
                                       localChange: localChange, gap: gap)
        }
        if overseasChange < 0, localChange > overseasChange {
            return NextCrossDivergence(direction: .potentialDrop, overseasChange: overseasChange,
                                       localChange: localChange, gap: gap)
        }
        return nil
    }
}

// MARK: - 123 隔夜信息消化

struct NextAbsorptionAssessment: Equatable {
    let overnightChange: Double
    let openGap: Double
    let sinceOpen: Double
    /// 已被计价的比例（0…1）。方向相反时视为已消化并开始反向修复。
    var absorbedRatio: Double {
        guard abs(overnightChange) > 0.01 else { return 1 }
        let travelled = openGap + sinceOpen
        let sameDirection = (overnightChange > 0) == (travelled > 0)
        if sameDirection { return min(1, abs(travelled) / abs(overnightChange)) }
        return min(1, abs(openGap) / abs(overnightChange))
    }
    var verdict: String {
        if absorbedRatio >= 0.8 { return "隔夜信息基本已计价，不宜再按隔夜方向追单" }
        if absorbedRatio >= 0.5 { return "隔夜信息已消化过半，继续追单的依据下降" }
        return "隔夜信息尚未充分反映，方向仍有传导空间"
    }
}

enum NextAbsorptionEngine {
    static func assess(overnightChange: Double, previousClose: Double, openPrice: Double,
                       currentPrice: Double) -> NextAbsorptionAssessment? {
        guard let gap = NextCrossMarketAlignment.changePercent(from: previousClose, to: openPrice),
              let sinceOpen = NextCrossMarketAlignment.changePercent(from: openPrice, to: currentPrice) else { return nil }
        return NextAbsorptionAssessment(overnightChange: overnightChange, openGap: gap, sinceOpen: sinceOpen)
    }
}

// MARK: - 128 假设 → 确认 / 拒绝

enum NextHypothesisState: String, Equatable {
    case pending          // 只是假设，不是交易信号
    case confirmed        // 本地价格/量能确认，才允许进入候选计划
    case rejected         // 本地没确认，明确放弃
    case expired          // 确认窗口已过，未确认
    var allowsPlan: Bool { self == .confirmed }
    var label: String {
        switch self {
        case .pending: return "等待 A股确认"
        case .confirmed: return "已确认"
        case .rejected: return "假设失效"
        case .expired: return "确认窗口已过"
        }
    }
}

struct NextCrossHypothesis: Equatable {
    let id: String
    let code: String
    let createdAt: Date
    let confirmDeadline: Date
    /// 假设内容，例如「午后修复」。
    let statement: String
    let overseasEvidence: [String]
    var state: NextHypothesisState
    var resolution: String?

    init(id: String = UUID().uuidString, code: String, createdAt: Date, confirmDeadline: Date,
         statement: String, overseasEvidence: [String], state: NextHypothesisState = .pending,
         resolution: String? = nil) {
        self.id = id
        self.code = code
        self.createdAt = createdAt
        self.confirmDeadline = confirmDeadline
        self.statement = statement
        self.overseasEvidence = overseasEvidence
        self.state = state
        self.resolution = resolution
    }
}

enum NextHypothesisJudge {
    /// 确认条件必须是本地自己的证据：站上 VWAP、低点抬高、成交量恢复。
    /// 海外反弹本身**不能**把假设变成 confirmed。
    static func judge(_ hypothesis: NextCrossHypothesis, local: [NextMarketPoint], vwap: Double?,
                      referencePrice: Double?, volumeRecovered: Bool, now: Date) -> NextCrossHypothesis {
        var result = hypothesis
        guard result.state == .pending else { return result }
        let windowPoints = local.filter { $0.timestamp >= hypothesis.createdAt && $0.timestamp <= hypothesis.confirmDeadline }
        if !windowPoints.isEmpty {
            let aboveVWAP = vwap.map { reference in windowPoints.contains { $0.value > reference } } ?? false
            let higherLow = referencePrice.map { reference in windowPoints.contains { $0.value > reference } } ?? false
            if aboveVWAP && higherLow && volumeRecovered {
                result.state = .confirmed
                result.resolution = "A股站上 VWAP、低点抬高且量能恢复，假设成立"
                return result
            }
        }
        if now > hypothesis.confirmDeadline {
            result.state = .rejected
            let missing = [
                vwap == nil ? "缺少 VWAP" : nil,
                volumeRecovered ? nil : "成交量未恢复"
            ].compactMap { $0 }
            result.resolution = "确认窗口内未见价格与量能同步确认（\(missing.isEmpty ? "条件未同时满足" : missing.joined(separator: "、"))），放弃本次假设"
        }
        return result
    }
}

// MARK: - 124 ETF 执行层过滤

struct NextExecutionFilter: Equatable {
    let premiumPercent: Double?
    let spreadPercent: Double?
    let verdict: String
    let allowsChasing: Bool
}

enum NextETFExecution {
    /// 方向对不代表价格能买：溢价高、盘口薄的时候必须明说「不建议在当前价格追」。
    static func assess(price: Double, iopv: Double?, bestBid: Double?, bestAsk: Double?,
                       premiumLimit: Double = 0.8, spreadLimit: Double = 0.35) -> NextExecutionFilter {
        let premium = iopv.flatMap { $0 > 0 ? (price / $0 - 1) * 100 : nil }
        var spread: Double?
        if let bid = bestBid, let ask = bestAsk, bid > 0, ask >= bid {
            spread = (ask - bid) / bid * 100
        }
        var notes: [String] = []
        var allows = true
        if let premium {
            if premium > premiumLimit {
                notes.append("ETF 溢价 \(String(format: "%.2f", premium))% 偏高")
                allows = false
            } else if premium < -premiumLimit {
                notes.append("ETF 折价 \(String(format: "%.2f", premium))%，可在方向确认后提高关注")
            }
        }
        if let spread, spread > spreadLimit {
            notes.append("买卖价差 \(String(format: "%.2f", spread))% 偏宽，成交成本会吃掉利润")
            allows = false
        }
        if notes.isEmpty { notes.append("溢折价与价差正常，执行层无额外限制") }
        return NextExecutionFilter(premiumPercent: premium, spreadPercent: spread,
                                   verdict: notes.joined(separator: "；"), allowsChasing: allows)
    }
}

// MARK: - 130 统一上下文

/// 进入 DecisionContext 的跨市场部分。只给结论与依据，不在这里另起一套 AI。
struct NextCrossMarketContext: Equatable {
    var abroad: [NextCrossMarket: NextCrossMarketFreshness] = [:]
    var lunchShock: NextLunchBreakShock?
    var divergence: NextCrossDivergence?
    var absorption: NextAbsorptionAssessment?
    var leadLag: [NextLeadLagStudy] = []
    var hypothesis: NextCrossHypothesis?
    var execution: NextExecutionFilter?
    var fxNote: String?

    /// 给 DecisionContext 的文本行。数据不足时只说明不足，不生成方向。
    var contextLines: [String] {
        var lines: [String] = []
        for market in NextCrossMarket.allCases {
            guard let freshness = abroad[market] else { continue }
            lines.append(freshness.note)
        }
        if let lunchShock { lines.append(lunchShock.note) }
        if let divergence { lines.append(divergence.note) }
        if let absorption { lines.append("隔夜消息：\(absorption.verdict)") }
        for study in leadLag.prefix(3) { lines.append(study.summary) }
        if let hypothesis {
            lines.append("假设「\(hypothesis.statement)」：\(hypothesis.state.label)\(hypothesis.resolution.map { " · \($0)" } ?? "")")
        }
        if let execution { lines.append("执行层：\(execution.verdict)") }
        if let fxNote { lines.append(fxNote) }
        return lines
    }

    /// 方向性权重：休市/过期数据的市场权重为 0；假设未确认时不允许计划。
    var allowsPlan: Bool {
        guard let hypothesis else { return true }
        return hypothesis.state.allowsPlan
    }

    var usableMarketCount: Int { abroad.values.filter { $0.usable }.count }
}
