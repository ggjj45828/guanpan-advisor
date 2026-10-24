import Foundation

// MARK: - 121 条件化领先（按市场状态分组）
//
// 「日本涨 → A股跟」这句话不加条件其实没有意义：
// 单边趋势里跟随往往明显，区间震荡里可能完全失效，高波动里噪声会淹没一切。
// 把配对按「领先市场当天是什么状态」分组、各组独立统计，才能回答
// 「这种关系在什么情况下才算数」。
//
// 一条硬规矩：状态判定只用**当天已经发生**的数据（当日涨跌幅与已实现振幅）。
// 一旦用了收盘后才确定的信息（比如「这天最终是涨的」），条件化就变成偷看答案。

enum NextRegimeKind: String, CaseIterable, Equatable {
    case trendingUp
    case trendingDown
    case range
    case highVolatility

    var label: String {
        switch self {
        case .trendingUp: return "单边上行"
        case .trendingDown: return "单边下行"
        case .range: return "区间震荡"
        case .highVolatility: return "高波动"
        }
    }
}

struct NextRegimeDay: Equatable {
    let day: Date
    let kind: NextRegimeKind
    let changePercent: Double
    let rangePercent: Double

    var note: String {
        "\(kind.label)：当日 \(String(format: "%+.2f", changePercent))%，已实现振幅 \(String(format: "%.2f", rangePercent))%"
    }
}

enum NextRegimeClassifier {
    /// 单边门槛：涨跌幅绝对值 ≥ 0.60%。
    static let trendThreshold = 0.60
    /// 单边走出来的样子：振幅不会比净涨跌幅大太多。
    /// 净涨 1%、振幅 1.05% → 噪声比 1.05，算单边；
    /// 净涨 1%、振幅 2.5% → 噪声比 2.5，那是来回拉，不是单边。
    /// （振幅必然 ≥ 净涨跌幅的绝对值，所以这个比值只会 ≥ 1。）
    static let maximumNoiseRatio = 1.30
    /// 高波动门槛：振幅 ≥ 1.80% 但不够「单边」的，归为高波动。
    static let volatilityThreshold = 1.80

    /// 用一天里已经发生的点位给这一天分类。点不足两个就返回 nil，不猜。
    static func classify(day: Date, points: [NextMarketPoint]) -> NextRegimeDay? {
        let sorted = points.sorted { $0.timestamp < $1.timestamp }
        guard sorted.count > 1, let first = sorted.first, let last = sorted.last,
              first.value > 0 else { return nil }
        let change = (last.value / first.value - 1) * 100
        let values = sorted.map(\.value)
        guard let low = values.min(), let high = values.max() else { return nil }
        let range = (high - low) / first.value * 100
        let kind: NextRegimeKind
        if abs(change) >= trendThreshold, range <= abs(change) * maximumNoiseRatio {
            kind = change > 0 ? .trendingUp : .trendingDown
        } else if range >= volatilityThreshold {
            kind = .highVolatility
        } else {
            kind = .range
        }
        return NextRegimeDay(day: day, kind: kind, changePercent: change, rangePercent: range)
    }

    /// 把整段序列按自然日切开逐日分类。
    static func days(series: [NextMarketPoint],
                     calendar: Calendar = NextLeadLagEngine.shanghai) -> [NextRegimeDay] {
        let grouped = Dictionary(grouping: series) { calendar.startOfDay(for: $0.timestamp) }
        return grouped.keys.sorted().compactMap { day in
            classify(day: day, points: grouped[day] ?? [])
        }
    }
}

struct NextConditionalLead: Equatable {
    let regime: NextRegimeKind
    let study: NextLeadLagStudy

    var independentDays: Int { study.best?.independentDays ?? 0 }

    /// 这一状态下的结论。样本不足必须写成「该状态下样本不足」，
    /// 不能拿全样本的结论冒充分组结论——那等于什么都没分。
    var summary: String {
        guard study.best != nil else {
            return "\(regime.label)：暂无结论（\(insufficientReason)）"
        }
        return "\(regime.label)：\(study.summary)"
    }

    private var insufficientReason: String {
        if case let .insufficient(reason) = study.verdict { return reason }
        return "没有可用样本"
    }
}

enum NextConditionalLeadEngine {
    /// 每种市场状态各自跑一遍统计，互不借用样本。
    static func studies(lead: NextCrossMarket, leadSeries: [NextMarketPoint],
                        followCode: String, followSeries: [NextMarketPoint],
                        lastValidated: Date,
                        include: [NextRegimeKind] = NextRegimeKind.allCases) -> [NextConditionalLead] {
        let calendar = NextLeadLagEngine.shanghai
        var labels: [Date: NextRegimeKind] = [:]
        for item in NextRegimeClassifier.days(series: leadSeries, calendar: calendar) {
            labels[item.day] = item.kind
        }
        return include.map { regime in
            let study = NextLeadLagEngine.study(
                lead: lead, leadSeries: leadSeries, followCode: followCode,
                followSeries: followSeries, lastValidated: lastValidated,
                includePair: { labels[calendar.startOfDay(for: $0)] == regime })
            return NextConditionalLead(regime: regime, study: study)
        }
    }

    /// 哪一种状态下的关系最可靠。没有一条通过统计门槛时返回 nil，不硬挑一个。
    static func strongest(_ leads: [NextConditionalLead]) -> NextConditionalLead? {
        leads.filter { $0.study.passesStatisticalBar }
            .max { ($0.study.best?.wilsonLowerBound ?? 0) < ($1.study.best?.wilsonLowerBound ?? 0) }
    }
}

// MARK: - 132 分时段画像
//
// 同一个领先关系，开盘半小时、上午、午后、尾盘的表现可以完全不同：
// 开盘是信息集中释放，午后是流动性最薄，尾盘常有调仓。
// 把它们混在一起统计，得到的是一个谁都不像的平均数。
//
// 时段一律按**A股**时间划分：跟随的是 A股 ETF，配对点落在哪个时段要看 A股 当时能不能交易。
// A股 午休（11:30–13:00）期间海外还在动，但这些点不属于任何可交易时段，直接排除。

enum NextSessionBucket: String, CaseIterable, Equatable {
    case open30
    case morning
    case afternoon
    case close30

    var label: String {
        switch self {
        case .open30: return "开盘 9:30–10:00"
        case .morning: return "上午 10:00–11:30"
        case .afternoon: return "午后 13:00–14:30"
        case .close30: return "尾盘 14:30–15:00"
        }
    }

    /// 北京时间当天第几分钟的区间，左闭右开。
    var minutes: Range<Int> {
        switch self {
        case .open30: return (9 * 60 + 30)..<(10 * 60)
        case .morning: return (10 * 60)..<(11 * 60 + 30)
        case .afternoon: return (13 * 60)..<(14 * 60 + 30)
        case .close30: return (14 * 60 + 30)..<(15 * 60)
        }
    }

    static func bucket(forMinute minute: Int) -> NextSessionBucket? {
        allCases.first { $0.minutes.contains(minute) }
    }
}

struct NextSessionProfile: Equatable {
    let bucket: NextSessionBucket
    let study: NextLeadLagStudy

    var independentDays: Int { study.best?.independentDays ?? 0 }

    var summary: String {
        guard study.best != nil else {
            let reason: String
            if case let .insufficient(detail) = study.verdict { reason = detail } else { reason = "没有可用样本" }
            return "\(bucket.label)：暂无结论（\(reason)）"
        }
        return "\(bucket.label)：\(study.summary)"
    }
}

enum NextSessionProfileEngine {
    static func studies(lead: NextCrossMarket, leadSeries: [NextMarketPoint],
                        followCode: String, followSeries: [NextMarketPoint],
                        lastValidated: Date,
                        calendar: NextMarketCalendar = NextMarketCalendar(),
                        include: [NextSessionBucket] = NextSessionBucket.allCases) -> [NextSessionProfile] {
        include.map { bucket in
            let study = NextLeadLagEngine.study(
                lead: lead, leadSeries: leadSeries, followCode: followCode,
                followSeries: followSeries, lastValidated: lastValidated,
                includePair: { stamp in
                    bucket.minutes.contains(calendar.minuteOfDay(stamp, .china))
                })
            return NextSessionProfile(bucket: bucket, study: study)
        }
    }
}
