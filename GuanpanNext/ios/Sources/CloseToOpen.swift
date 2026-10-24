import Foundation

// MARK: - 127 尾盘 → 次日观察
//
// 这是一个**只读研究**，不是交易信号：
// 它只回答「历史上尾盘偏强的那些天，次日开盘与全天更容易怎么走」，
// 并且必须同时给出样本数、置信下界和「口径是什么」。
// 任何一次调用都不会产生计划、不会改持仓、不会进闸门。
//
// 两条诚实性要求：
// 1. **口径必须写明**。有分时时用真实的 14:30→15:00 涨跌；
//    只有日 K 时只能用「收盘价在当日区间的位置」当代理，这是代理不是尾盘涨跌，
//    输出里必须说清楚，否则用户会把代理当成事实。
// 2. **频率不是概率**。20 天里 13 天高开，不等于明天有 65% 概率高开。
//    所以同时给 Wilson 下界，并且在文案里直接写明这句话。

enum NextTailBucket: String, CaseIterable, Equatable {
    case strong
    case weak
    case flat

    var label: String {
        switch self {
        case .strong: return "尾盘偏强"
        case .weak: return "尾盘偏弱"
        case .flat: return "尾盘中性"
        }
    }
}

struct NextCloseToOpenBucket: Equatable {
    let bucket: NextTailBucket
    let sampleDays: Int
    /// 次日高开（缺口 > 0）的比例。没有样本时是 nil，不是 0。
    let gapUpRate: Double?
    /// 高开率的 Wilson 95% 下界。
    let gapUpLowerBound: Double
    let meanGapPercent: Double?
    let meanNextDayPercent: Double?

    var note: String {
        guard sampleDays > 0 else { return "\(bucket.label)：没有样本" }
        guard sampleDays >= NextCloseToOpenEngine.minimumDays else {
            return "\(bucket.label)：只有 \(sampleDays) 天，不足 \(NextCloseToOpenEngine.minimumDays) 天，不能下结论"
        }
        let rate = gapUpRate.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
        let lower = String(format: "%.0f%%", gapUpLowerBound * 100)
        let gap = meanGapPercent.map { String(format: "%+.2f%%", $0) } ?? "—"
        let next = meanNextDayPercent.map { String(format: "%+.2f%%", $0) } ?? "—"
        return "\(bucket.label)：\(sampleDays) 天 · 次日高开 \(rate)（Wilson 下界 \(lower)）· 平均缺口 \(gap) · 平均次日涨跌 \(next)"
    }
}

struct NextCloseToOpenStudy: Equatable {
    let code: String
    /// 参与统计的独立交易日数（能同时看到尾盘口径与次日开盘的天数）。
    let days: Int
    /// true = 用真实分时尾盘；false = 用收盘位置代理。
    let usesIntraday: Bool
    let buckets: [NextCloseToOpenBucket]

    /// 这是研究，不是建议。固定为 true，防止有人把它接到行动计划上。
    var isReadOnlyResearch: Bool { true }

    var caliberNote: String {
        usesIntraday
            ? "口径：真实分时 14:30→15:00 涨跌幅（≥+0.30% 偏强，≤−0.30% 偏弱）"
            : "口径：当日收盘在区间的位置（≥70% 偏强，≤30% 偏弱）。**这是代理，不是尾盘涨跌**——没有分时数据时只能这样近似"
    }

    var summary: String {
        guard days > 0 else {
            return "\(code) 暂无尾盘→次日统计（\(caliberNote)）"
        }
        let title = "\(code) 尾盘→次日观察：\(days) 个交易日"
        let lines = buckets.map(\.note)
        let disclaimer = "以上是历史频率，不是概率，也不构成入场依据；样本在 \(NextCloseToOpenEngine.minimumDays) 天以下时不给结论"
        return ([title, caliberNote] + lines + [disclaimer]).joined(separator: "\n")
    }
}

enum NextCloseToOpenEngine {
    /// 每桶至少 20 天。低于这个数就说「不能下结论」，不给数字。
    static let minimumDays = 20
    /// 真实分时口径的尾盘强弱门槛（百分点）。
    static let tailThresholdPercent = 0.30
    /// 代理口径的收盘位置门槛（0…1）。
    static let strongPosition = 0.70
    static let weakPosition = 0.30

    /// - Parameter minute: 分时样本。为空时自动退化为收盘位置代理，并在输出里标明。
    static func study(code: String, daily: [NextChartSample], minute: [NextChartSample] = [],
                      calendar: NextMarketCalendar = NextMarketCalendar()) -> NextCloseToOpenStudy {
        let bars = daily.filter { $0.close > 0 }.sorted { $0.timestamp < $1.timestamp }
        guard bars.count >= 2 else {
            return NextCloseToOpenStudy(code: code, days: 0, usesIntraday: false, buckets: [])
        }
        let usesIntraday = minute.count > 2
        var minutesByDay: [Date: [NextChartSample]] = [:]
        if usesIntraday {
            minutesByDay = Dictionary(grouping: minute) {
                NextLeadLagEngine.shanghai.startOfDay(for: $0.timestamp)
            }
        }
        var samples: [NextTailBucket: [(gap: Double, next: Double)]] = [:]
        var counted = 0
        for index in 0..<(bars.count - 1) {
            let bar = bars[index]
            let following = bars[index + 1]
            // 次日必须是紧邻的下一个交易日：中间缺数据（停牌、长假）就不算，
            // 否则「隔了五天」的缺口会被当成隔夜缺口。
            guard isAdjacentSession(bar.timestamp, following.timestamp) else { continue }
            guard let bucket = bucket(for: bar, minutes: minutesByDay, usesIntraday: usesIntraday,
                                      calendar: calendar) else { continue }
            guard let open = following.open.map({ NextNum.double($0) }), open > 0 else { continue }
            let close = NextNum.double(bar.close)
            guard close > 0 else { continue }
            let nextClose = NextNum.double(following.close)
            let gap = (open / close - 1) * 100
            let nextDay = (nextClose / close - 1) * 100
            samples[bucket, default: []].append((gap, nextDay))
            counted += 1
        }
        let buckets = NextTailBucket.allCases.map { key -> NextCloseToOpenBucket in
            let rows = samples[key] ?? []
            let gapUps = rows.filter { $0.gap > 0 }.count
            let rate = rows.isEmpty ? nil : Double(gapUps) / Double(rows.count)
            let lower = NextLeadLagEngine.wilsonLowerBound(successes: gapUps, trials: rows.count)
            let meanGap = rows.isEmpty ? nil : rows.map(\.gap).reduce(0, +) / Double(rows.count)
            let meanNext = rows.isEmpty ? nil : rows.map(\.next).reduce(0, +) / Double(rows.count)
            return NextCloseToOpenBucket(bucket: key, sampleDays: rows.count,
                                         gapUpRate: rate, gapUpLowerBound: lower,
                                         meanGapPercent: meanGap, meanNextDayPercent: meanNext)
        }
        return NextCloseToOpenStudy(code: code, days: counted, usesIntraday: usesIntraday, buckets: buckets)
    }

    /// 尾盘强弱分桶。真实分时优先；没有分时用收盘位置代理。
    static func bucket(for bar: NextChartSample, minutes: [Date: [NextChartSample]],
                       usesIntraday: Bool, calendar: NextMarketCalendar) -> NextTailBucket? {
        let day = NextLeadLagEngine.shanghai.startOfDay(for: bar.timestamp)
        if usesIntraday, let points = minutes[day], points.count > 1 {
            let tail = points.filter { calendar.minuteOfDay($0.timestamp, .china) >= 14 * 60 + 30 }
                .sorted { $0.timestamp < $1.timestamp }
            if tail.count > 1, let first = tail.first, let last = tail.last,
               NextNum.double(first.close) > 0 {
                let change = (NextNum.double(last.close) / NextNum.double(first.close) - 1) * 100
                if change >= tailThresholdPercent { return .strong }
                if change <= -tailThresholdPercent { return .weak }
                return .flat
            }
        }
        // 代理口径：收盘在当日区间的位置。区间为 0（一字板/停牌）时无法判断，返回 nil。
        guard let high = bar.high.map({ NextNum.double($0) }),
              let low = bar.low.map({ NextNum.double($0) }) else { return nil }
        let close = NextNum.double(bar.close)
        guard high > low else { return nil }
        let position = (close - low) / (high - low)
        if position >= strongPosition { return .strong }
        if position <= weakPosition { return .weak }
        return .flat
    }

    /// 两个时间戳是不是紧邻的两个交易日（允许周末，不允许缺一个交易日以上）。
    /// 这里用自然日差 ≤ 4 天做近似：覆盖周末与单日假，超过 4 天视为中间缺数据。
    static func isAdjacentSession(_ previous: Date, _ next: Date) -> Bool {
        let gap = NextLeadLagEngine.shanghai.dateComponents(
            [.day],
            from: NextLeadLagEngine.shanghai.startOfDay(for: previous),
            to: NextLeadLagEngine.shanghai.startOfDay(for: next)).day ?? 99
        return gap >= 1 && gap <= 4
    }
}
