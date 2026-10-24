import Foundation

// MARK: - 回放冻结
//
// 回放最容易骗自己的地方，是**边看边改**：
// 先看到当天午后涨了，再把「假设」调整成当天成立的样子；
// 或者规则里读到了一个冻结时点之后才有的价格。
// 这两种都会让回放结果无条件地好看，而且看不出来。
//
// 冻结的做法是把「假设」变成一份**先写死、再运行**的规格：
//   1. `cutoffMinute` 之前的点才能用来判断条件是否成立；
//   2. 条件区间必须整体落在 cutoff 之前，`baseline` / `confirm` / `horizon` 必须在 cutoff 之后；
//   3. 结果段允许读 cutoff 之后的点，但读不到就写「等后续数据」，**不许填**；
//   4. 每一天算一个指纹（冻结规格 + 那天的观测值），同一批数据重跑指纹必须一致，
//      数据被改过指纹就会变——这一步才让「冻结」可验证，而不只是一句声明。

struct NextFrozenCondition: Codable, Equatable {
    enum Series: String, Codable, Equatable {
        case leader
        case asset
    }
    enum Operator: String, Codable, Equatable {
        case gte
        case lte
        case between
    }

    let series: Series
    /// 当日第几分钟（9:30 = 570）。用分钟而不是 Date，是为了让冻结规格与具体日期无关：
    /// 同一份规格要能套到 30 个不同的交易日上。
    let fromMinute: Int
    let toMinute: Int
    let op: Operator
    let threshold: Double
    let upperThreshold: Double?
}

struct NextFrozenHypothesis: Codable, Equatable {
    let id: String
    /// 冻结时点。条件只能读到这一刻为止的数据。
    let cutoffMinute: Int
    /// 预期方向：+1 看涨、−1 看跌。0 不允许，因为「没方向」不能验证。
    let expectedDirection: Int
    /// 结果基准时刻（必须在 cutoff 之后）。
    let baselineMinute: Int
    /// 确认时刻（必须不早于基准）。
    let confirmMinute: Int
    /// 观察时点（相对同日分钟数），必须在基准之后。
    let horizonMinutes: [Int]
    let conditions: [NextFrozenCondition]

    /// 12:50 午休检查点、13:30 确认、14:30/15:00 观察。
    /// 这是项目里唯一被广泛使用的那条经验，冻结成常量避免每次手写不一致。
    static let standard = NextFrozenHypothesis(
        id: "standard-lunch-repair",
        cutoffMinute: 12 * 60 + 50,
        expectedDirection: 1,
        baselineMinute: 13 * 60,
        confirmMinute: 13 * 60 + 30,
        horizonMinutes: [14 * 60, 14 * 60 + 30, 15 * 60],
        conditions: [
            // 领先市场 11:00→12:50 的净变动 ≥ +0.5%。区间整体落在 12:50 之前，
            // 所以「条件成立」这件事在最坏情况下也只用到 12:50 的数据。
            NextFrozenCondition(series: .leader, fromMinute: 11 * 60, toMinute: 12 * 60 + 50,
                                op: .gte, threshold: 0.005, upperThreshold: nil)
        ])
}

struct NextFrozenConditionResult: Equatable {
    let series: NextFrozenCondition.Series
    let observed: Double?
    let passed: Bool
}

enum NextFrozenOutcomeState: String, Equatable {
    case evaluated
    /// 条件不成立，当天不产生假设。
    case noHypothesis
    /// 冻结段数据不完整（分钟缺口），当天无法判断。
    case incompleteAtCutoff
    /// 结果段还没有数据。**不许填**，只能等。
    case awaitingPostCutoffData
}

struct NextFrozenDayOutcome: Equatable {
    let day: String
    /// 2026-10-24 这样的日期，方便直接展示。
    let triggered: Bool
    let dataComplete: Bool
    let confirmReturn: Double?
    let horizonReturns: [Int: Double]
    let confirmed: Bool?
    let state: NextFrozenOutcomeState
    let conditionResults: [NextFrozenConditionResult]
    /// 冻结规格 + 当天观测值的指纹。同输入必须同指纹。
    let fingerprint: String

    var note: String {
        switch state {
        case .evaluated:
            return confirmed == true ? "假设成立并兑现" : "假设成立但未兑现"
        case .noHypothesis:
            return "冻结时点条件不成立，当天不产生假设"
        case .incompleteAtCutoff:
            return "冻结段分钟数据不全，当天不计入统计"
        case .awaitingPostCutoffData:
            return "结果段数据还没到，等后续数据"
        }
    }
}

enum NextReplayFreezeEngine {
    static let maximumConditions = 8
    static let maximumHorizons = 8
    /// 分钟匹配容差。超过 5 分钟的点不算「那个时刻」的价格。
    static let matchToleranceMinutes = 5

    // MARK: 规格校验
    //
    // 返回空数组表示合规。刻意不用 throws：调用方需要一次性看到**所有**问题，
    // 而不是修一个再发现下一个。
    static func validate(_ hypothesis: NextFrozenHypothesis) -> [String] {
        var problems: [String] = []
        if hypothesis.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems.append("冻结规格缺少 id")
        }
        if hypothesis.expectedDirection != 1 && hypothesis.expectedDirection != -1 {
            problems.append("预期方向必须是 +1 或 −1")
        }
        if !(1...maximumConditions).contains(hypothesis.conditions.count) {
            problems.append("条件数量必须在 1…\(maximumConditions) 之间")
        }
        if hypothesis.horizonMinutes.count > maximumHorizons {
            problems.append("观察时点最多 \(maximumHorizons) 个")
        }
        for condition in hypothesis.conditions {
            if condition.fromMinute >= condition.toMinute {
                problems.append("条件区间起点必须早于终点（\(clock(condition.fromMinute))–\(clock(condition.toMinute))）")
            }
            // 这一条是整个冻结的核心：条件不能读到冻结时点之后。
            if condition.toMinute > hypothesis.cutoffMinute {
                problems.append("条件区间 \(clock(condition.fromMinute))–\(clock(condition.toMinute)) 晚于冻结时点 \(clock(hypothesis.cutoffMinute))，等于用未来数据判断条件")
            }
            if condition.op == .between {
                guard let upper = condition.upperThreshold else {
                    problems.append("区间条件缺少上限")
                    continue
                }
                if !(condition.threshold <= upper) {
                    problems.append("区间条件下限大于上限")
                }
            }
            if abs(condition.threshold) > 1 || abs(condition.upperThreshold ?? 0) > 1 {
                problems.append("涨跌幅阈值必须在 −100%…100% 之间（用小数表示）")
            }
        }
        if hypothesis.baselineMinute <= hypothesis.cutoffMinute {
            problems.append("结果基准 \(clock(hypothesis.baselineMinute)) 必须晚于冻结时点 \(clock(hypothesis.cutoffMinute))")
        }
        if hypothesis.confirmMinute < hypothesis.baselineMinute {
            problems.append("确认时刻不能早于结果基准")
        }
        for horizon in hypothesis.horizonMinutes where horizon <= hypothesis.baselineMinute {
            problems.append("观察时点 \(clock(horizon)) 必须在结果基准之后")
        }
        return problems
    }

    // MARK: 单日评估

    static func evaluate(hypothesis: NextFrozenHypothesis,
                         day: Date,
                         leader: [NextMarketPoint], leaderZone: TimeZone,
                         asset: [NextMarketPoint], assetZone: TimeZone) -> NextFrozenDayOutcome {
        let dayText = NextLeadValidationEngine.dayKey(day)
        // 冻结段：只保留冻结时点之前的点。这一句是「不许用未来数据」的物理保证，
        // 而不是靠调用方自觉。
        let leaderFrozen = leader.filter { belongsToDay($0.timestamp, day, zone: leaderZone)
            && minuteOfDay($0.timestamp, zone: leaderZone) <= hypothesis.cutoffMinute }
        let assetFrozen = asset.filter { belongsToDay($0.timestamp, day, zone: assetZone)
            && minuteOfDay($0.timestamp, zone: assetZone) <= hypothesis.cutoffMinute }

        var results: [NextFrozenConditionResult] = []
        var complete = true
        for condition in hypothesis.conditions {
            let series = condition.series == .leader ? leaderFrozen : assetFrozen
            let zone = condition.series == .leader ? leaderZone : assetZone
            let start = price(in: series, day: day, minute: condition.fromMinute,
                              zone: zone, preferLater: false)
            let end = price(in: series, day: day, minute: condition.toMinute,
                            zone: zone, preferLater: false)
            let observed: Double?
            if let start, let end, start > 0 {
                observed = (end / start - 1)
            } else {
                observed = nil
            }
            let passed: Bool
            switch condition.op {
            case .gte: passed = observed.map { $0 >= condition.threshold } ?? false
            case .lte: passed = observed.map { $0 <= condition.threshold } ?? false
            case .between:
                passed = observed.map { value in
                    guard let upper = condition.upperThreshold else { return false }
                    return value >= condition.threshold && value <= upper
                } ?? false
            }
            if observed == nil { complete = false }
            results.append(NextFrozenConditionResult(series: condition.series, observed: observed, passed: passed))
        }

        guard complete else {
            let outcome = NextFrozenDayOutcome(day: dayText, triggered: false, dataComplete: false,
                                               confirmReturn: nil, horizonReturns: [:], confirmed: nil,
                                               state: .incompleteAtCutoff, conditionResults: results,
                                               fingerprint: "")
            return fingerprinting(outcome, hypothesis: hypothesis)
        }
        let triggered = results.allSatisfy(\.passed)
        guard triggered else {
            let outcome = NextFrozenDayOutcome(day: dayText, triggered: false, dataComplete: true,
                                               confirmReturn: nil, horizonReturns: [:], confirmed: nil,
                                               state: .noHypothesis, conditionResults: results,
                                               fingerprint: "")
            return fingerprinting(outcome, hypothesis: hypothesis)
        }

        // 结果段：允许读冻结时点之后的点，但读不到就是读不到。
        let assetOutcome = asset.filter { belongsToDay($0.timestamp, day, zone: assetZone) }
        let baseline = price(in: assetOutcome, day: day, minute: hypothesis.baselineMinute,
                             zone: assetZone, preferLater: true)
        let confirm = price(in: assetOutcome, day: day, minute: hypothesis.confirmMinute,
                            zone: assetZone, preferLater: true)
        var horizons: [Int: Double] = [:]
        for horizon in hypothesis.horizonMinutes {
            if let base = baseline, base > 0,
               let value = price(in: assetOutcome, day: day, minute: horizon, zone: assetZone, preferLater: true) {
                horizons[horizon] = value / base - 1
            }
        }
        guard let baseline, baseline > 0, let confirm else {
            let outcome = NextFrozenDayOutcome(day: dayText, triggered: true, dataComplete: true,
                                               confirmReturn: nil, horizonReturns: horizons, confirmed: nil,
                                               state: .awaitingPostCutoffData, conditionResults: results,
                                               fingerprint: "")
            return fingerprinting(outcome, hypothesis: hypothesis)
        }
        let confirmReturn = confirm / baseline - 1
        let confirmed = hypothesis.expectedDirection > 0 ? confirmReturn > 0 : confirmReturn < 0
        let outcome = NextFrozenDayOutcome(day: dayText, triggered: true, dataComplete: true,
                                           confirmReturn: confirmReturn, horizonReturns: horizons,
                                           confirmed: confirmed, state: .evaluated,
                                           conditionResults: results, fingerprint: "")
        return fingerprinting(outcome, hypothesis: hypothesis)
    }

    // MARK: 指纹

    /// FNV-1a 64 位。**不用 CryptoKit**：这里只需要「同输入同输出、改了就变」，
    /// 不需要抗碰撞到密码学强度，而 Core 保持零外部依赖更好测。
    static func fingerprint(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(text.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    static func canonicalText(_ outcome: NextFrozenDayOutcome, hypothesis: NextFrozenHypothesis) -> String {
        var parts: [String] = [hypothesis.id, outcome.day,
                               "cut=\(hypothesis.cutoffMinute)",
                               "dir=\(hypothesis.expectedDirection)",
                               "base=\(hypothesis.baselineMinute)",
                               "confirm=\(hypothesis.confirmMinute)",
                               "horizon=\(hypothesis.horizonMinutes.map(String.init).joined(separator: ","))"]
        for (index, condition) in hypothesis.conditions.enumerated() {
            parts.append("c\(index):\(condition.series.rawValue),\(condition.fromMinute)-\(condition.toMinute),\(condition.op.rawValue),\(fmt(condition.threshold)),\(condition.upperThreshold.map(fmt) ?? "-")")
        }
        for result in outcome.conditionResults {
            parts.append("obs:\(result.series.rawValue)=\(result.observed.map(fmt) ?? "nil"),\(result.passed)")
        }
        parts.append("state=\(outcome.state.rawValue)")
        parts.append("confirmReturn=\(outcome.confirmReturn.map(fmt) ?? "nil")")
        parts.append("confirmed=\(outcome.confirmed.map(String.init) ?? "nil")")
        return parts.joined(separator: "|")
    }

    private static func fingerprinting(_ outcome: NextFrozenDayOutcome,
                                       hypothesis: NextFrozenHypothesis) -> NextFrozenDayOutcome {
        let digest = fingerprint(canonicalText(outcome, hypothesis: hypothesis))
        return NextFrozenDayOutcome(day: outcome.day, triggered: outcome.triggered,
                                    dataComplete: outcome.dataComplete,
                                    confirmReturn: outcome.confirmReturn,
                                    horizonReturns: outcome.horizonReturns,
                                    confirmed: outcome.confirmed, state: outcome.state,
                                    conditionResults: outcome.conditionResults,
                                    fingerprint: digest)
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    // MARK: 重跑校验

    enum Verification: Equatable {
        case identical
        /// 同一批日子重跑，指纹变了：说明数据或规则被改过，冻结失效。
        case drifted(days: [String])
        /// 某些日子这次没跑出来，无法证明一致。
        case missing(days: [String])

        var label: String {
            switch self {
            case .identical: return "重跑结果与冻结一致"
            case let .drifted(days): return "重跑结果与冻结不一致（\(days.count) 天）：\(days.prefix(3).joined(separator: "、"))——冻结已失效，这次结果不能当证据"
            case let .missing(days): return "有 \(days.count) 天没有重跑出来，无法证明一致"
            }
        }
    }

    static func verify(frozen: [NextFrozenDayOutcome], rerun: [NextFrozenDayOutcome]) -> Verification {
        let frozenMap = Dictionary(uniqueKeysWithValues: frozen.map { ($0.day, $0.fingerprint) })
        let rerunMap = Dictionary(uniqueKeysWithValues: rerun.map { ($0.day, $0.fingerprint) })
        let missing = frozenMap.keys.filter { rerunMap[$0] == nil }.sorted()
        if !missing.isEmpty { return .missing(days: missing) }
        let drifted = frozenMap.keys.filter { key in
            guard let value = rerunMap[key] else { return false }
            return value != frozenMap[key]
        }.sorted()
        return drifted.isEmpty ? .identical : .drifted(days: drifted)
    }

    // MARK: 时间工具

    static func minuteOfDay(_ date: Date, zone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    static func belongsToDay(_ date: Date, _ day: Date, zone: TimeZone) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.isDate(date, inSameDayAs: day)
    }

    /// 取某个分钟的价格。`preferLater = false` 用在条件段（只能看已发生的），
    /// `true` 用在结果段（取该时刻之后最近的观测）。
    static func price(in series: [NextMarketPoint], day: Date, minute: Int,
                      zone: TimeZone, preferLater: Bool) -> Double? {
        let ordered = series.sorted { $0.timestamp < $1.timestamp }
        let candidates = ordered.filter { belongsToDay($0.timestamp, day, zone: zone) }
        let target = minute * 60
        if preferLater {
            return candidates.first { minuteOfDay($0.timestamp, zone: zone) * 60 >= target
                && minuteOfDay($0.timestamp, zone: zone) <= minute + matchToleranceMinutes }?.value
        }
        return candidates.last { minuteOfDay($0.timestamp, zone: zone) * 60 <= target
            && minuteOfDay($0.timestamp, zone: zone) >= minute - matchToleranceMinutes }?.value
    }

    static func clock(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }
}
