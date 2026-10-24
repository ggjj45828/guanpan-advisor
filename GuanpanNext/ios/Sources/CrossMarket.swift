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
struct NextLeadLagWindow: Equatable {
    let minutes: Int
    let sampleCount: Int
    let correlation: Double
    let sameDirectionRate: Double
    let meanFollowReturn: Double
    let medianFollowReturn: Double
    let positiveRatio: Double
    let maxAdverseReturn: Double
    /// 前后两段子样本相关系数同号的比例（0…1）。用来识别「只在某一段成立」。
    let stability: Double
}

enum NextLeadLagVerdict: Equatable {
    case insufficient(String)
    case usable(best: NextLeadLagWindow, windows: [NextLeadLagWindow], periodDays: Int, lastValidated: Date)
}

struct NextLeadLagStudy: Equatable {
    let lead: NextCrossMarket
    let followCode: String
    let verdict: NextLeadLagVerdict
    var best: NextLeadLagWindow? {
        if case let .usable(best, _, _, _) = verdict { return best }
        return nil
    }
    var summary: String {
        switch verdict {
        case let .insufficient(reason):
            return "暂无稳定领先关系（\(reason)）"
        case let .usable(best, _, days, _):
            return "\(lead.displayName) 领先 \(best.minutes) 分钟：样本 \(best.sampleCount) · 相关 \(NextLeadLagStudy.percent(best.correlation, digits: 2)) · 同向 \(NextLeadLagStudy.percent(best.sameDirectionRate, digits: 0)) · 近 \(days) 日"
        }
    }
    static func percent(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f%%", value * 100)
    }
}

enum NextLeadLagEngine {
    /// 最小样本量与最低证据门槛。样本不足时**必须**返回「暂无稳定领先关系」，
    /// 不允许用 3 个样本算出一个好看的数字再当预测能力。
    static let minimumSamples = 30
    static let minimumCorrelation = 0.20
    static let minimumStability = 0.6

    static func study(lead: NextCrossMarket, leadSeries: [NextMarketPoint],
                      followCode: String, followSeries: [NextMarketPoint],
                      windowsMinutes: [Int] = [0, 5, 10, 15, 30, 45, 60, 90],
                      observedFrom: Date? = nil,
                      lastValidated: Date) -> NextLeadLagStudy {
        let leadSorted = leadSeries.sorted { $0.timestamp < $1.timestamp }
        let followSorted = followSeries.sorted { $0.timestamp < $1.timestamp }
        guard leadSorted.count >= 2, followSorted.count >= 2 else {
            return NextLeadLagStudy(lead: lead, followCode: followCode,
                                    verdict: .insufficient("领先或跟随序列样本不足"))
        }
        var results: [NextLeadLagWindow] = []
        for minutes in windowsMinutes.sorted() {
            guard let window = window(lead: leadSorted, follow: followSorted, minutes: minutes,
                                      observedFrom: observedFrom) else { continue }
            results.append(window)
        }
        guard let best = results.filter({ $0.sampleCount >= minimumSamples })
            .max(by: { abs($0.correlation) < abs($1.correlation) }) else {
            return NextLeadLagStudy(lead: lead, followCode: followCode,
                                    verdict: .insufficient("最长窗口有效样本不足 \(minimumSamples) 个"))
        }
        guard abs(best.correlation) >= minimumCorrelation else {
            return NextLeadLagStudy(lead: lead, followCode: followCode,
                                    verdict: .insufficient("相关性 \(NextLeadLagStudy.percent(best.correlation, digits: 2)) 低于门槛，可能只是同涨同跌"))
        }
        guard best.stability >= minimumStability else {
            return NextLeadLagStudy(lead: lead, followCode: followCode,
                                    verdict: .insufficient("前后两段方向不一致（稳定度 \(NextLeadLagStudy.percent(best.stability, digits: 0))），不当作稳定关系"))
        }
        // 多窗口一致性：最佳窗口若孤立（相邻窗口都远弱），更可能是挑选偏差。
        let neighbours = results.filter { abs($0.minutes - best.minutes) == 5 || abs($0.minutes - best.minutes) == 10 }
        if !neighbours.isEmpty,
           neighbours.allSatisfy({ abs($0.correlation) < abs(best.correlation) * 0.4 }) {
            return NextLeadLagStudy(lead: lead, followCode: followCode,
                                    verdict: .insufficient("只有单一窗口吻合、相邻窗口不支持，疑似多重比较挑出来的"))
        }
        let spanDays = max(1, Int((lastValidated.timeIntervalSince(leadSorted.first!.timestamp)) / 86_400))
        return NextLeadLagStudy(lead: lead, followCode: followCode,
                                verdict: .usable(best: best, windows: results, periodDays: spanDays,
                                                 lastValidated: lastValidated))
    }

    /// 单窗口统计。返回 nil 表示这个窗口一个有效配对都没有。
    static func window(lead: [NextMarketPoint], follow: [NextMarketPoint],
                       minutes: Int, observedFrom: Date?) -> NextLeadLagWindow? {
        let windowSeconds = Double(minutes) * 60
        let tolerance = max(windowSeconds, 60) + 60
        var leadChanges: [Double] = []
        var followChanges: [Double] = []
        var pairs: [(leadTime: Date, leadChange: Double, followChange: Double)] = []
        for point in lead {
            if let floor = observedFrom, point.timestamp < floor { continue }
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
        return NextLeadLagWindow(minutes: minutes, sampleCount: pairs.count,
                                 correlation: correlation,
                                 sameDirectionRate: pairs.isEmpty ? 0 : Double(sameDirection) / Double(pairs.count),
                                 meanFollowReturn: mean,
                                 medianFollowReturn: median,
                                 positiveRatio: Double(positive) / Double(followChanges.count),
                                 maxAdverseReturn: sortedFollow.first ?? 0,
                                 stability: stability)
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
