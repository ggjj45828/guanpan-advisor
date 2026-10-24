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

struct NextFXPoint: Equatable {
    let timestamp: Date
    let rate: Double
}

struct NextFXContext: Equatable {
    enum State: Equatable {
        /// A股 本身：没有汇率层，不是「缺失」。
        case notApplicable
        /// 没有接入或今天还没数据。必须明说，不许当成 0。
        case missing(String)
        /// 数据过期。旧汇率解释今天，是纯粹的错。
        case stale(String)
        /// 数值可疑（未来时间戳、异常跳变）。
        case suspicious(String)
        case available(days: Int, todayPercent: Double)
    }

    let market: NextCrossMarket
    let pair: NextFXPair?
    let state: State

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
            return "\(market.displayName)汇率数据已过期（\(reason)）：不用旧汇率解释今天的行情"
        case let .suspicious(reason):
            return "\(market.displayName)汇率数据可疑（\(reason)）：先不当成真实行情"
        case let .available(days, percent):
            let direction = percent > 0.001 ? "升值" : (percent < -0.001 ? "贬值" : "基本持平")
            let base = "\(market.displayName)汇率 \(pair?.displayName ?? "")今日\(direction) \(String(format: "%+.2f", percent))%"
            if days >= NextFXContextEngine.minimumDays {
                return "\(base) · 已有 \(days) 个交易日，可算平均干扰度"
            }
            return "\(base) · 只有 \(days) 个交易日，不足 \(NextFXContextEngine.minimumDays) 天，暂不算平均干扰度"
        }
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
        let sorted = series.filter { $0.rate > 0 }.sorted { $0.timestamp < $1.timestamp }
        guard let last = sorted.last else {
            return NextFXContext(market: market, pair: pair, state: .missing("没有汇率序列"))
        }
        if last.timestamp > now.addingTimeInterval(60) {
            return NextFXContext(market: market, pair: pair, state: .suspicious("时间戳晚于当前时间"))
        }
        let ageHours = now.timeIntervalSince(last.timestamp) / 3600
        if ageHours > staleHours {
            return NextFXContext(market: market, pair: pair,
                                 state: .stale(String(format: "最新一条是 %.1f 小时前", ageHours)))
        }
        let calendar = NextLeadLagEngine.shanghai
        let days = Set(sorted.map { calendar.startOfDay(for: $0.timestamp) }).count
        let todayPoints = sorted.filter { calendar.isDate($0.timestamp, inSameDayAs: now) }
        guard todayPoints.count > 1, let firstToday = todayPoints.first, firstToday.rate > 0 else {
            return NextFXContext(market: market, pair: pair, state: .missing("今天还没有汇率变动数据"))
        }
        let percent = (last.rate / firstToday.rate - 1) * 100
        if abs(percent) > jumpThreshold {
            return NextFXContext(market: market, pair: pair,
                                 state: .suspicious(String(format: "单日变动 %.2f%% 超过 %.1f%%，先怀疑数据",
                                                           percent, jumpThreshold)))
        }
        return NextFXContext(market: market, pair: pair,
                             state: .available(days: days, todayPercent: percent))
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
