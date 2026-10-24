import Foundation

// MARK: - 历史回放验证器（研究工具，不是模拟账户）
//
// 目的只有一个：**证伪**。给一个「午休期间日韩反弹 → A股午后修复」这类市场经验，
// 用过去 N 个交易日回放，看它到底成立还是我们主观感觉。
//
// 三条硬约束，缺一条这个工具就没有意义：
// 1. 知识截断是结构性的：假设生成函数只能拿到 `CutoffView`，它在类型上就没有 12:50 之后的数据。
//    不是「我们记得不要用」，而是「拿不到」。
// 2. 不做模拟账户/虚拟持仓/虚拟成交：这里只统计「假设对不对」，不产生任何订单、份额或资金变动。
// 3. 数据不够就明说「没有稳定领先关系」，绝不为了满足需求硬造信号。

/// 截断视图：只包含给定时刻（含）之前的数据。回放时被注入给假设生成逻辑。
struct NextReplayCutoffView {
    let market: NextCrossMarket
    let previousClose: Double
    let points: [NextMarketPoint]
    let cutoff: Date

    /// 截止时刻前最后一个价。
    var lastPrice: Double? { points.last?.value }
    var changePercent: Double? {
        guard let last = lastPrice else { return nil }
        return NextCrossMarketAlignment.changePercent(from: previousClose, to: last)
    }
    /// 上午区间高低点，只用截止前的数据算。
    var high: Double? { points.map(\.value).max() }
    var low: Double? { points.map(\.value).min() }
}

/// 一个交易日的回放素材。分「本地（A股/ETF）」与「外部市场」两摞。
struct NextReplayDay {
    let date: Date
    let code: String
    let name: String
    let local: NextCrossMarketDaySeries
    let overseas: [NextCrossMarketDaySeries]

    /// 结构式截断：只把 ≤ cutoff 的点交出去。调用方拿不到之后的数据。
    func cutoffView(_ series: NextCrossMarketDaySeries, at cutoff: Date) -> NextReplayCutoffView {
        NextReplayCutoffView(market: series.market, previousClose: series.previousClose,
                             points: series.points.filter { $0.timestamp <= cutoff }, cutoff: cutoff)
    }
}

struct NextCrossMarketDaySeries: Equatable {
    let market: NextCrossMarket
    let previousClose: Double
    let points: [NextMarketPoint]
}

/// 被验证的「市场经验」。换成另一条经验只需换 `statement` 与两个门槛，不必改引擎。
struct NextReplayHypothesisRule: Equatable {
    let id: String
    let statement: String
    /// 海外午休期间至少修复多少个百分点，才算「出现新信息」。
    var overseasRepairThreshold: Double = 0.5
    /// A股上午至少跌多少，才算「还没反映」。
    var localMorningDropThreshold: Double = -0.3
    /// 假设确认窗口（分钟）。默认 13:00–13:10。
    var confirmWindowMinutes: Int = 10

    static let lunchRepair = NextReplayHypothesisRule(
        id: "lunch-repair",
        statement: "A股午休期间日韩科技明显修复，且A股上午已下跌 → 13:00 后存在修复可能")
}

enum NextReplayOutcome: String, CaseIterable, Equatable {
    /// 当日条件不满足，不产生假设——这也是一个正确结果（不交易）。
    case noHypothesis
    /// 假设成立且午后确实上涨。
    case confirmedFollowThrough
    /// 假设成立但午后没有走出来。
    case confirmedFailed
    /// 提出了假设，但 A股 13:00 后没有确认，主动取消。
    case rejectedNoConfirmation

    var label: String {
        switch self {
        case .noHypothesis: return "未产生假设"
        case .confirmedFollowThrough: return "确认后上涨"
        case .confirmedFailed: return "确认后未涨"
        case .rejectedNoConfirmation: return "未确认，已取消"
        }
    }
}

struct NextReplayDayResult: Equatable {
    let date: Date
    let outcome: NextReplayOutcome
    let overseasRepair: Double?
    let localMorningChange: Double?
    let afternoonReturn: Double?
    let note: String
}

struct NextReplayStats: Equatable {
    let sampleDays: Int
    let hypothesisDays: Int
    let confirmedDays: Int
    let followThroughDays: Int
    /// 确认率 = 确认天数 / 提出假设天数。低确认率说明这条经验根本不准。
    var confirmationRate: Double { hypothesisDays > 0 ? Double(confirmedDays) / Double(hypothesisDays) : 0 }
    /// 走出来的比例 = 确认后上涨天数 / 确认天数。
    var followThroughRate: Double { confirmedDays > 0 ? Double(followThroughDays) / Double(confirmedDays) : 0 }
    let meanAfternoonReturn: Double
    let medianAfternoonReturn: Double
    let maxAdverseReturn: Double
    /// 前后两段确认率方向是否一致（1 一致 / 0 不一致）。
    let stability: Double

    var summary: String {
        let confirm = String(format: "%.0f", confirmationRate * 100)
        let follow = String(format: "%.0f", followThroughRate * 100)
        return "样本 \(sampleDays) 日 · 提出假设 \(hypothesisDays) 次 · 确认 \(confirmedDays) 次（\(confirm)%）"
            + " · 确认后上涨 \(follow)% · 午后均值 \(String(format: "%+.2f", meanAfternoonReturn))%"
            + " · 中位 \(String(format: "%+.2f", medianAfternoonReturn))%"
            + " · 最大不利 \(String(format: "%+.2f", maxAdverseReturn))%"
    }
}

enum NextReplayVerdict: Equatable {
    /// 明确否定：数据不支持这条规律。这是**正常且有用**的结论。
    case noStableEvidence(String)
    case evidence(NextReplayStats)

    var headline: String {
        switch self {
        case let .noStableEvidence(reason): return "没有稳定领先关系：\(reason)"
        case let .evidence(stats): return "规律成立：" + stats.summary
        }
    }
}

struct NextReplayReport: Equatable {
    let code: String
    let name: String
    let rule: NextReplayHypothesisRule
    let results: [NextReplayDayResult]
    let verdict: NextReplayVerdict

    var hypothesisCount: Int { results.filter { $0.outcome != .noHypothesis }.count }
    var confirmedCount: Int {
        results.filter { $0.outcome == .confirmedFollowThrough || $0.outcome == .confirmedFailed }.count
    }
}

enum NextReplayEngine {
    /// 最少要多少个「提出假设」的样本才允许下结论。低于此数一律返回没有稳定关系。
    static let minimumHypothesisDays = 30
    static let minimumConfirmationRate = 0.5
    static let minimumFollowThroughRate = 0.5

    /// 强制知识截断：假设生成只使用 cutoff（12:50）。这里用参数把这条规则钉死在引擎里，
    /// 任何调用方都无法把全量数据塞进来。
    static func run(days: [NextReplayDay], rule: NextReplayHypothesisRule,
                    calendar: NextMarketCalendar = NextMarketCalendar()) -> NextReplayReport {
        let sorted = days.sorted { $0.date < $1.date }
        var results: [NextReplayDayResult] = []
        for day in sorted {
            results.append(replay(day: day, rule: rule, calendar: calendar))
        }
        return NextReplayReport(code: sorted.first?.code ?? "",
                                name: sorted.first?.name ?? "",
                                rule: rule, results: results,
                                verdict: verdict(rule: rule, results: results))
    }

    static func replay(day: NextReplayDay, rule: NextReplayHypothesisRule,
                       calendar: NextMarketCalendar) -> NextReplayDayResult {
        guard let lunch = calendar.lunchBreak(.china, at: day.date) else {
            return NextReplayDayResult(date: day.date, outcome: .noHypothesis, overseasRepair: nil,
                                       localMorningChange: nil, afternoonReturn: nil, note: "无法取到 A股午休区间")
        }
        // 12:50 检查点：之后的数据一律不进假设。
        let cutoff = lunch.end.addingTimeInterval(-10 * 60)
        let localView = day.cutoffView(day.local, at: cutoff)
        guard let morningChange = localView.changePercent else {
            return NextReplayDayResult(date: day.date, outcome: .noHypothesis, overseasRepair: nil,
                                       localMorningChange: nil, afternoonReturn: nil, note: "当日缺少 A股上午数据")
        }

        // 海外修复幅度：只取「11:30 时」与「12:50 时」两个截止时点。
        var bestRepair: Double?
        var bestMarket: NextCrossMarket?
        for series in day.overseas {
            let pre = day.cutoffView(series, at: lunch.start)
            let late = day.cutoffView(series, at: cutoff)
            guard let preChange = pre.changePercent, let lateChange = late.changePercent else { continue }
            let repair = lateChange - preChange
            if bestRepair == nil || repair > (bestRepair ?? 0) {
                bestRepair = repair
                bestMarket = series.market
            }
        }

        guard let repair = bestRepair, let market = bestMarket,
              repair >= rule.overseasRepairThreshold,
              morningChange <= rule.localMorningDropThreshold else {
            let reason = bestRepair.map { String(format: "海外修复 %+.2f%% 或上午 %+.2f%% 未达门槛，不产生假设", $0, morningChange) }
                ?? "当日缺少海外数据，不产生假设"
            return NextReplayDayResult(date: day.date, outcome: .noHypothesis, overseasRepair: bestRepair,
                                       localMorningChange: morningChange, afternoonReturn: nil, note: reason)
        }

        // —— 以下才开始看 13:00 之后的数据，仅用于「确认/否定」，绝不回流到假设里 ——
        let confirmEnd = lunch.end.addingTimeInterval(Double(rule.confirmWindowMinutes) * 60)
        let afternoonPoints = day.local.points.filter { $0.timestamp >= lunch.end && $0.timestamp <= confirmEnd }
        let reference = localView.lastPrice
        let confirmed = afternoonPoints.contains { point in
            guard let reference else { return false }
            return point.value > reference
        }
        let closes = day.local.points.filter { $0.timestamp > confirmEnd }
        let afternoonReturn: Double? = {
            guard let start = afternoonPoints.first?.value, let end = closes.last?.value else { return nil }
            return NextCrossMarketAlignment.changePercent(from: start, to: end)
        }()
        let marketName = market.displayName

        if !confirmed {
            return NextReplayDayResult(date: day.date, outcome: .rejectedNoConfirmation,
                                       overseasRepair: repair, localMorningChange: morningChange,
                                       afternoonReturn: afternoonReturn,
                                       note: String(format: "%@午休修复 %+.2f%%，但 13:00 后未站回上午收盘价，取消本次假设", marketName, repair))
        }
        guard let afternoonReturn else {
            return NextReplayDayResult(date: day.date, outcome: .confirmedFollowThrough,
                                       overseasRepair: repair, localMorningChange: morningChange,
                                       afternoonReturn: nil, note: "已确认，但当日午后数据不足，无法评估结果")
        }
        let outcome: NextReplayOutcome = afternoonReturn > 0 ? .confirmedFollowThrough : .confirmedFailed
        return NextReplayDayResult(date: day.date, outcome: outcome, overseasRepair: repair,
                                   localMorningChange: morningChange, afternoonReturn: afternoonReturn,
                                   note: String(format: "%@修复 %+.2f%% → 已确认，午后 %+.2f%%", marketName, repair, afternoonReturn))
    }

    static func verdict(rule: NextReplayHypothesisRule, results: [NextReplayDayResult]) -> NextReplayVerdict {
        let hypothesis = results.filter { $0.outcome != .noHypothesis }
        guard hypothesis.count >= minimumHypothesisDays else {
            return .noStableEvidence("提出假设的样本只有 \(hypothesis.count) 个，少于 \(minimumHypothesisDays) 个，不能下结论")
        }
        let confirmed = hypothesis.filter { $0.outcome == .confirmedFollowThrough || $0.outcome == .confirmedFailed }
        let followed = confirmed.filter { $0.outcome == .confirmedFollowThrough }
        let returns = confirmed.compactMap { $0.afternoonReturn }
        let confirmationRate = Double(confirmed.count) / Double(hypothesis.count)
        guard confirmationRate >= minimumConfirmationRate else {
            let rate = String(format: "%.0f", confirmationRate * 100)
            return .noStableEvidence("\(hypothesis.count) 次假设只有 \(confirmed.count) 次得到 A股确认（\(rate)%），这条经验不成立")
        }
        let followRate = confirmed.isEmpty ? 0 : Double(followed.count) / Double(confirmed.count)
        guard followRate >= minimumFollowThroughRate else {
            return .noStableEvidence(String(format: "确认后只有 %.0f%% 继续上涨，说明确认条件本身没有预测价值", followRate * 100))
        }
        let sorted = returns.sorted()
        let mean = returns.isEmpty ? 0 : returns.reduce(0, +) / Double(returns.count)
        let median = sorted.isEmpty ? 0 : (sorted.count % 2 == 0 ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2 : sorted[sorted.count / 2])
        // 稳定度：把样本按时间切两半，两段确认率同侧才算稳定。
        let half = hypothesis.count / 2
        let firstHalf = Array(hypothesis.prefix(half))
        let secondHalf = Array(hypothesis.suffix(half))
        func rate(_ slice: [NextReplayDayResult]) -> Double {
            guard !slice.isEmpty else { return 0 }
            let hit = slice.filter { $0.outcome == .confirmedFollowThrough || $0.outcome == .confirmedFailed }.count
            return Double(hit) / Double(slice.count)
        }
        let stability: Double = (rate(firstHalf) >= 0.5) == (rate(secondHalf) >= 0.5) ? 1 : 0
        let stats = NextReplayStats(sampleDays: results.count, hypothesisDays: hypothesis.count,
                                    confirmedDays: confirmed.count, followThroughDays: followed.count,
                                    meanAfternoonReturn: mean, medianAfternoonReturn: median,
                                    maxAdverseReturn: sorted.first ?? 0, stability: stability)
        guard stability >= 0.5 else {
            return .noStableEvidence("前后两段确认率方向不一致，关系不稳定：" + stats.summary)
        }
        return .evidence(stats)
    }
}
