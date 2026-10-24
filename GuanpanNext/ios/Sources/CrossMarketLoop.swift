import Foundation

// MARK: - 跨市场闭环（118/122/123/128/129/139/143/144）
//
// 这条链的每一环之前都有零件，但零件之间没有接线，所以结果是「统计很好看、计划照旧」。
// 这个文件只干一件事：把零件按固定顺序连起来，并且让末尾的决定**真的**能拦住计划。
//
//   采数据 → 领先关系 → 午休/背离信号 → 假设 → A股确认 → Risk Guard → 做T/网格/不交易 → 解释 → 复盘
//
// 三条不许越界的规矩：
// 1. 没有信号就是「不交易」，这是一种正式结论，不是一个空结果；
// 2. 海外证据永远不能把假设变成 confirmed，必须有 A股 自己的价格与量能；
// 3. 复盘时「正确的取消」也要算成功——否则系统会学会宁可乱做也不取消。

// MARK: 信号

enum NextLoopSignalKind: String, Equatable {
    case lunchRepair      // 午休期间海外修复
    case lunchWeaken      // 午休期间海外转弱
    case divergenceCatchUp // 海外修复、本地没跟
    case divergenceDrop    // 海外转弱、本地没跟

    var isBullish: Bool {
        self == .lunchRepair || self == .divergenceCatchUp
    }

    var statement: String {
        switch self {
        case .lunchRepair: return "午后修复（午休期间海外风险偏好回升）"
        case .lunchWeaken: return "午后转弱（午休期间海外风险偏好下降）"
        case .divergenceCatchUp: return "补涨观察（海外已修复、本地尚未跟上）"
        case .divergenceDrop: return "补跌观察（海外已转弱、本地尚未跟上）"
        }
    }

    var label: String {
        switch self {
        case .lunchRepair: return "午休修复"
        case .lunchWeaken: return "午休转弱"
        case .divergenceCatchUp: return "向上背离"
        case .divergenceDrop: return "向下背离"
        }
    }
}

struct NextLoopSignal: Equatable {
    let kind: NextLoopSignalKind
    let market: NextCrossMarket
    /// 证据原文，直接进假设与解释，不做二次美化。
    let evidence: String
    /// 幅度（百分点/百分比）。用来排序与显示，不单独当门槛。
    let strength: Double
}

// MARK: 决定

enum NextCrossGate: Equatable {
    /// 允许做 T：海外证据 + A股 确认 + 执行层都过了，且领先关系权重满。
    case doT(reason: String)
    /// 只允许网格：方向被确认过，但领先关系不够稳，不做方向性加仓。
    case grid(reason: String)
    /// 不交易：正式结论。带原因，界面照抄。
    case noTrade(reason: String)

    var reason: String {
        switch self {
        case let .doT(reason), let .grid(reason), let .noTrade(reason): return reason
        }
    }

    var allowsDirectional: Bool {
        if case .doT = self { return true }
        return false
    }

    var allowsAnyPlan: Bool {
        if case .noTrade = self { return false }
        return true
    }

    var label: String {
        switch self {
        case .doT: return "可做T"
        case .grid: return "只做网格"
        case .noTrade: return "不交易"
        }
    }
}

// MARK: 一次完整判断

struct NextLoopOutcome: Equatable {
    let code: String
    let at: Date
    let gate: NextCrossGate
    let signal: NextLoopSignal?
    let hypothesis: NextCrossHypothesis?
    let chain: NextReasoningChain
    /// 139：给 AI 与界面共用的一段解释，逐行、可核对。
    let explanation: [String]

    var headline: String {
        guard let signal else { return "不交易 · 没有跨市场信号" }
        return "\(gate.label) · \(signal.kind.label)"
    }
}

enum NextCrossMarketLoop {
    /// 午休/背离自带的门槛。低于它就不算信号，宁可今天没有结论。
    static let lunchThreshold = 0.30      // 百分点
    static let divergenceThreshold = 0.50 // 百分比
    static let divergenceLookback = 30    // 分钟

    static func evaluate(code: String,
                         name: String? = nil,
                         now: Date,
                         overseas: [NextCrossMarket: [NextMarketPoint]],
                         local: [NextMarketPoint],
                         vwap: Double?,
                         volumeRecovered: Bool,
                         execution: NextExecutionFilter? = nil,
                         studies: [NextLeadLagStudy] = [],
                         rollings: [NextRollingValidity] = [],
                         pulse: NextCrossMarketPulse,
                         calendar: NextMarketCalendar = NextMarketCalendar(),
                         existing: NextCrossHypothesis? = nil) -> NextLoopOutcome {
        var explanation: [String] = []
        let signal = detectSignal(now: now, overseas: overseas, local: local, pulse: pulse,
                                  calendar: calendar, explanation: &explanation)

        // 没有信号：这是正式结论，不是「本次跳过」。已有假设仍按原节奏裁决（不因今天没信号就作废）。
        guard signal != nil || existing != nil else {
            let chain = NextReasoningChainBuilder.build(
                code: code, name: name, pulse: pulse, studies: studies,
                rollings: rollings, hypothesis: nil, execution: execution)
            explanation.append("跨市场今天没有达到门槛的信号：不交易，且不生成任何计划")
            return NextLoopOutcome(code: code, at: now,
                                   gate: .noTrade(reason: "没有达到门槛的跨市场信号"),
                                   signal: nil, hypothesis: nil, chain: chain, explanation: explanation)
        }

        // 128：先提出假设，再由 A股 自己裁决。海外证据只进证据栏。
        // 「低点抬高」的基准必须是**当天低点之前**的价格，用最新价当基准会让上涨序列永远判不过。
        let baseline = local.first?.value
        var hypothesis = existing
        if hypothesis == nil, let signal {
            hypothesis = NextCrossHypothesis(
                code: code,
                createdAt: now,
                confirmDeadline: now.addingTimeInterval(30 * 60),
                statement: signal.kind.statement,
                overseasEvidence: [signal.evidence])
        }
        guard let pending = hypothesis else {
            let chain = NextReasoningChainBuilder.build(
                code: code, name: name, pulse: pulse, studies: studies,
                rollings: rollings, hypothesis: nil, execution: execution)
            return NextLoopOutcome(code: code, at: now,
                                   gate: .noTrade(reason: "没有达到门槛的跨市场信号"),
                                   signal: nil, hypothesis: nil, chain: chain, explanation: explanation)
        }
        if let signal { explanation.append("假设「\(signal.kind.statement)」，证据：\(signal.evidence)") }
        let judged = NextHypothesisJudge.judge(pending, local: local, vwap: vwap,
                                               referencePrice: baseline,
                                               volumeRecovered: volumeRecovered, now: now)

        let chain = NextReasoningChainBuilder.build(
            code: code, name: name, pulse: pulse, studies: studies,
            rollings: rollings, hypothesis: judged, execution: execution)

        // 129：Risk Guard。权重用 133 的滚动结论，没有滚动信息就按中性处理。
        let bestWeight = rollings.map(\.weight).max() ?? 0.5
        let gate = decide(judged: judged, chain: chain, execution: execution,
                          weight: bestWeight, signal: signal, explanation: &explanation)

        return NextLoopOutcome(code: code, at: now, gate: gate, signal: signal,
                               hypothesis: judged, chain: chain, explanation: explanation)
    }

    // MARK: 信号识别（119/122）

    static func detectSignal(now: Date,
                             overseas: [NextCrossMarket: [NextMarketPoint]],
                             local: [NextMarketPoint],
                             pulse: NextCrossMarketPulse,
                             calendar: NextMarketCalendar,
                             explanation: inout [String]) -> NextLoopSignal? {
        let status = calendar.status(.china, at: now)
        // 午休与午后：优先用午休信息差（同一基准下 11:30 与 12:50 两个时点之差）。
        if status == .lunchBreak || status == .open,
           let lunch = calendar.lunchBreak(.china, at: now),
           now >= lunch.start {
            for market in [NextCrossMarket.japan, .korea, .hongKong] {
                guard let series = overseas[market], series.count > 1 else { continue }
                // 基准取该市场当日第一个观测：shock 是同一基准下的差，基准选谁都一样。
                guard let base = series.first?.value, base > 0 else { continue }
                guard let shock = NextLunchBreakEngine.shock(market: market, series: series,
                                                             previousClose: base, lunch: lunch) else { continue }
                guard abs(shock.shock) >= lunchThreshold else { continue }
                let kind: NextLoopSignalKind = shock.shock > 0 ? .lunchRepair : .lunchWeaken
                explanation.append(shock.note)
                return NextLoopSignal(kind: kind, market: market, evidence: shock.note,
                                      strength: abs(shock.shock))
            }
        }

        // 盘中：背离。必须「海外明显动了、本地没跟」。
        if status == .open, let ranked = bestOverseasMarket(pulse: pulse) {
            if let series = overseas[ranked.market],
               let divergence = NextDivergenceDetector.detect(
                   overseas: series, local: local,
                   lookbackMinutes: divergenceLookback,
                   thresholdPercent: divergenceThreshold, now: now) {
                let kind: NextLoopSignalKind = divergence.direction == .potentialCatchUp
                    ? .divergenceCatchUp : .divergenceDrop
                explanation.append(divergence.note)
                return NextLoopSignal(kind: kind, market: ranked.market, evidence: divergence.note,
                                      strength: abs(divergence.gap))
            }
        }
        return nil
    }

    /// 选哪个海外市场做背离基准：优先「今天动得最多且数据可用」的那个。
    static func bestOverseasMarket(pulse: NextCrossMarketPulse) -> NextCrossMarketPulseRow? {
        pulse.rows
            .filter { $0.usable && $0.changePercent != nil }
            .max { abs($0.changePercent ?? 0) < abs($1.changePercent ?? 0) }
    }

    // MARK: Risk Guard（124/129）

    static func decide(judged: NextCrossHypothesis,
                       chain: NextReasoningChain,
                       execution: NextExecutionFilter?,
                       weight: Double,
                       signal: NextLoopSignal?,
                       explanation: inout [String]) -> NextCrossGate {
        // 按链条的固定顺序判定：断在哪一环，就说哪一环，绝不把执行层说成数据不足。
        if let broken = chain.firstBreak {
            switch broken.stage {
            case "⑤ 本地确认":
                explanation.append("A股 未确认「\(judged.statement)」（\(judged.state.label)），不交易；这不算错过，是规则要求的取消")
                return .noTrade(reason: "A股 未确认：\(judged.state.label)")
            case "⑥ 执行层":
                let detail = execution?.verdict ?? "当前价格不适合追"
                explanation.append("执行层拦截：\(detail)")
                return .noTrade(reason: "执行层拦截：\(detail)")
            default:
                explanation.append("链条在「\(broken.stage)」断开：\(chain.breakReason ?? "数据不足")，不交易")
                return .noTrade(reason: "\(broken.stage)未通过：\(chain.breakReason ?? "数据不足")")
            }
        }
        guard judged.state.allowsPlan else {
            explanation.append("A股 未确认「\(judged.statement)」（\(judged.state.label)），不交易；这不算错过，是规则要求的取消")
            return .noTrade(reason: "A股 未确认：\(judged.state.label)")
        }
        if let execution, !execution.allowsChasing {
            explanation.append("执行层拦截：\(execution.verdict)")
            return .noTrade(reason: "执行层拦截：\(execution.verdict)")
        }
        let label = signal?.kind.label ?? "跨市场"
        if weight >= 1.0 {
            explanation.append("方向与执行都通过，领先关系权重 \(NextRollingValidity.percent(weight))：允许做T，仓位仍按你自己的上限")
            return .doT(reason: "\(label) 已由 A股 确认")
        }
        explanation.append("已确认但领先关系权重只有 \(NextRollingValidity.percent(weight))：只做网格，不做方向性加仓")
        return .grid(reason: "领先关系不够稳（权重 \(NextRollingValidity.percent(weight))），只做网格")
    }
}

// MARK: - 143/144 记录与复盘
//
// 复盘必须能得出「什么都没做是对的」这个结论，否则系统只会奖励「做过」。
// 所以这里把「正确的取消」和「错过」分开记：前者是成功，后者是事实，都不是失败。

struct NextLoopRecord: Equatable {
    let code: String
    let at: Date
    let gate: NextCrossGate
    let statement: String?
    let referencePrice: Double?
}

enum NextLoopReviewOutcome: String, Equatable {
    case followThrough      // 做了，且方向对了
    case failedFollowThrough // 做了，但方向错了
    case avoidedLoss        // 没做，事后看确实该不做 —— 算成功
    case missedGain         // 没做，事后看踏空了 —— 如实记录，不算错
    case noSignal           // 当天没有信号

    var isSuccess: Bool {
        self == .followThrough || self == .avoidedLoss || self == .noSignal
    }

    var label: String {
        switch self {
        case .followThrough: return "按计划兑现"
        case .failedFollowThrough: return "做了但没兑现"
        case .avoidedLoss: return "正确的取消"
        case .missedGain: return "错过（不算错）"
        case .noSignal: return "没有信号"
        }
    }
}

struct NextLoopReview: Equatable {
    let code: String
    let outcome: NextLoopReviewOutcome
    let movePercent: Double?
    let note: String
}

enum NextLoopReviewer {
    /// 复盘只看一件事：当时那个方向，后来有没有发生。
    /// 没有参考价就不给结论，不拿「最近的价」凑一个。
    static func review(_ record: NextLoopRecord, laterPrice: Double) -> NextLoopReview {
        guard let reference = record.referencePrice, reference > 0 else {
            return NextLoopReview(code: record.code, outcome: .noSignal, movePercent: nil,
                                  note: "当时没有本地参考价，复盘无法判断，不强行给结论")
        }
        guard let move = NextCrossMarketAlignment.changePercent(from: reference, to: laterPrice) else {
            return NextLoopReview(code: record.code, outcome: .noSignal, movePercent: nil,
                                  note: "参考价或之后价格无效，复盘跳过")
        }
        let upward = move > 0.02
        let downward = move < -0.02
        switch record.gate {
        case .doT:
            if upward {
                return NextLoopReview(code: record.code, outcome: .followThrough, movePercent: move,
                                      note: "按假设做了，之后 \(String(format: "%+.2f%%", move))，方向兑现")
            }
            return NextLoopReview(code: record.code, outcome: .failedFollowThrough, movePercent: move,
                                  note: "按假设做了，之后 \(String(format: "%+.2f%%", move))，未兑现")
        case .grid, .noTrade:
            if downward {
                return NextLoopReview(code: record.code, outcome: .avoidedLoss, movePercent: move,
                                      note: "没有按方向做，之后 \(String(format: "%+.2f%%", move))，取消是对的")
            }
            if upward {
                return NextLoopReview(code: record.code, outcome: .missedGain, movePercent: move,
                                      note: "没有按方向做，之后 \(String(format: "%+.2f%%", move))，属于错过；规则没触发，不算错")
            }
            return NextLoopReview(code: record.code, outcome: .noSignal, movePercent: move,
                                  note: "之后基本没动（\(String(format: "%+.2f%%", move))），这次判断没有信息量")
        }
    }
}

extension NextCrossMarketLoop {
    /// 只取该市场「今天」的点。
    /// 跨日混在一起会让「最近 30 分钟」在开盘时变成「隔夜 18 小时」，背离就成了隔夜跳空。
    static func todayPoints(_ points: [NextMarketPoint], market: NextCrossMarket,
                            now: Date) -> [NextMarketPoint] {
        let key = NextCrossMarketFeed.dayKey(now, market: market)
        return points.filter { NextCrossMarketFeed.dayKey($0.timestamp, market: market) == key }
    }
}
