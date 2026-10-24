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
    case openAbsorbed      // 开盘半小时隔夜信息已计价
    case openUnderAbsorbed // 开盘半小时隔夜信息未消化

    // 这里**没有** isBullish：开盘消化两个种类的方向取决于隔夜变化的符号，
    // 而符号在信号的 evidence 里、不在 kind 里；旧四种的 isBullish 也没有任何消费方，
    // 留一个按 kind 硬编的方向只会误导读者，所以整个删掉。

    var statement: String {
        switch self {
        case .lunchRepair: return "午后修复（午休期间海外风险偏好回升）"
        case .lunchWeaken: return "午后转弱（午休期间海外风险偏好下降）"
        case .divergenceCatchUp: return "补涨观察（海外已修复、本地尚未跟上）"
        case .divergenceDrop: return "补跌观察（海外已转弱、本地尚未跟上）"
        case .openAbsorbed: return "开盘半小时隔夜信息已计价，午后不宜按隔夜方向追单"
        case .openUnderAbsorbed: return "开盘半小时隔夜信息尚未消化，午后仍可能按隔夜方向传导"
        }
    }

    var label: String {
        switch self {
        case .lunchRepair: return "午休修复"
        case .lunchWeaken: return "午休转弱"
        case .divergenceCatchUp: return "向上背离"
        case .divergenceDrop: return "向下背离"
        case .openAbsorbed: return "开盘已消化"
        case .openUnderAbsorbed: return "开盘未消化"
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
    /// 跨市场不参与：没有「已验证领先关系 + 当前信号」的组合，其他引擎照常决定计划。
    /// 跨市场信号既不授权、也不拦截。
    case clear(reason: String)
    /// 跨市场风险拦截：信号来自已通过逐 ETF 长期验证 + 预注册前瞻复现的领先关系，
    /// 但按边界它**只**作为保守风险拦截器——暂停该标的已有候选计划并要求重算；
    /// 它不自行创建价格、份额或交易方向。
    case intercept(reason: String)

    var reason: String {
        switch self {
        case let .clear(reason), let .intercept(reason): return reason
        }
    }

    /// 仅这一项对主链有「拦截」副作用：true 时主链暂停该标的已有候选计划并要求重算。
    /// 跨市场信号永远不做 plan 的「授权方」。
    var isInterceptor: Bool {
        if case .intercept = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .clear: return "跨市场不参与"
        case .intercept: return "风险拦截 · 暂停并需重算"
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
                         existing: NextCrossHypothesis? = nil,
                         // 126：当日真实分钟线与昨收。没有就传空——开盘消化这一支
                         // 会明说「数据不足」，不会拿日线近似充数。
                         minutes: [NextChartSample] = [],
                         previousClose: Double? = nil,
                         // 逐 ETF 长期验证通过的领先市场集合。
                         // `nil` = 不做这一层要求（测试与旧路径）；非 nil 时即使前瞻复现达标，
                         // 也必须这条关系在长期验证里走到「候选」才允许方向性做T。
                         longTermValidatedLeads: Set<NextCrossMarket>? = nil,
                         // 该标的的长期验证台账（用于解释为什么没升级），可为空。
                         longTermEntry: NextLeadLedgerEntry? = nil) -> NextLoopOutcome {
        var explanation: [String] = []
        let signal = detectSignal(code: code, now: now, overseas: overseas, local: local, pulse: pulse,
                                  calendar: calendar, explanation: &explanation,
                                  minutes: minutes, previousClose: previousClose)

        // 没有信号：这是正式结论，不是「本次跳过」。已有假设仍按原节奏裁决（不因今天没信号就作废）。
        guard signal != nil || existing != nil else {
            let chain = NextReasoningChainBuilder.build(
                code: code, name: name, pulse: pulse, studies: studies,
                rollings: rollings, hypothesis: nil, execution: execution)
            explanation.append("跨市场今天没有达到门槛的信号：不参与计划决策，不生成任何计划")
            return NextLoopOutcome(code: code, at: now,
                                   gate: .clear(reason: "没有达到门槛的跨市场信号"),
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
                                   gate: .clear(reason: "没有达到门槛的跨市场信号"),
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
        // 148：跨市场信号要能「拦截」，必须满足「已验证领先关系 + 当前信号」两者同时成立：
        // 它不能凭一个未验证的海外波动就去暂停用户计划。验证门槛由主链第三道门
        // （逐 ETF 长期验证 + 预注册前瞻复现）把守——未通过就不进入拦截逻辑。
        let reference = studies.max { lhs, rhs in
            abs(lhs.best?.correlation ?? 0) < abs(rhs.best?.correlation ?? 0)
        }
        var longTermNote: String?
        if let longTermValidatedLeads,
           let candidate = studies.first(where: { $0.eligibleForTradingSignal }),
           !longTermValidatedLeads.contains(candidate.lead) {
            if let entry = longTermEntry {
                longTermNote = "逐 ETF 长期验证未通过（\(entry.directionalDays) 个方向性交易日、单日集中度 \(Int(entry.concentrationShare * 100))%）：不能升级为稳定领先关系"
            } else {
                longTermNote = "这条关系还没有逐 ETF 长期验证记录（需要 \(NextEvidenceEngine.minimumSessions) 个独立交易日、留出段要跑赢对照组、且不能被单日极值撑起来）"
            }
        }
        // 拦截成立的唯一条件：当前有信号，且其所在领先市场已通过逐 ETF 长期验证。
        // 两者缺一 → 跨市场不参与（clear），既不授权也不拦截。
        let signalValidated = signal.map { sig in
            longTermValidatedLeads.map { $0.contains(sig.market) } ?? false
        } ?? false
        let gate = decide(judged: judged, chain: chain, execution: execution,
                          weight: bestWeight, signal: signal,
                          signalEligible: signalValidated,
                          replicationNote: signalValidated ? nil : (longTermNote ?? reference?.signalEligibilityNote),
                          explanation: &explanation)

        return NextLoopOutcome(code: code, at: now, gate: gate, signal: signal,
                               hypothesis: judged, chain: chain, explanation: explanation)
    }

    // MARK: 信号识别（119/122/126）

    static func detectSignal(code: String,
                             now: Date,
                             overseas: [NextCrossMarket: [NextMarketPoint]],
                             local: [NextMarketPoint],
                             pulse: NextCrossMarketPulse,
                             calendar: NextMarketCalendar,
                             explanation: inout [String],
                             // 126：开盘消化的窗口数据。调用方没有传就只走午休/背离两支。
                             minutes: [NextChartSample] = [],
                             previousClose: Double? = nil) -> NextLoopSignal? {
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

        // 126：开盘信息消化。窗口锁 9:30–10:00，只用当日真实分钟线。
        // 两个时点纪律：
        // 1. 窗口没走完（10:00 前）只说明「不给结论」，不返回信号；
        // 2. 只在开盘后一小时内作为信号——午休与午后由午休/背离负责，不重复发言
        //    （「午后不宜追单」这类假设在 14:00 提出来没有意义）。
        if status == .open {
            let minute = calendar.minuteOfDay(now, .china)
            if minute >= NextOpenAbsorptionEngine.windowStartMinute,
               minute < NextOpenAbsorptionEngine.windowEndMinute {
                explanation.append("开盘消化窗口（9:30–10:00）未走完，暂不给消化结论")
            } else if minute >= NextOpenAbsorptionEngine.windowEndMinute, minute < 11 * 60 + 30 {
                if let ranked = bestOverseasMarket(pulse: pulse),
                   let series = overseas[ranked.market], series.count > 1,
                   let windowEnd = NextCrossMarket.chinaMinute(now, NextOpenAbsorptionEngine.windowEndMinute),
                   let overnightChange = overseasChangeAtWindowEnd(market: ranked.market, series: series,
                                                                   pulse: pulse, windowEnd: windowEnd) {
                    if let absorption = NextOpenAbsorptionEngine.assess(
                        code: code, at: now, minutes: minutes,
                        previousClose: previousClose, overnightChange: overnightChange,
                        calendar: calendar) {
                        explanation.append(absorption.note)
                        // 只有两端给信号：≥0.8 已计价、<0.5 未消化。
                        // 中间带（消化过半但未基本计价）只作说明，不构成闭环信号。
                        if absorption.absorbedRatio >= 0.8 {
                            return NextLoopSignal(kind: .openAbsorbed, market: ranked.market,
                                                  evidence: absorption.note,
                                                  strength: abs(overnightChange))
                        }
                        if absorption.absorbedRatio < 0.5 {
                            return NextLoopSignal(kind: .openUnderAbsorbed, market: ranked.market,
                                                  evidence: absorption.note,
                                                  strength: abs(overnightChange))
                        }
                        explanation.append("开盘半小时隔夜信息消化过半但未基本计价，不构成闭环信号")
                    } else {
                        // assess 返回 nil 的可能：分钟样本不足、没有昨收、隔夜变动不足门槛——照实说，不猜哪个。
                        explanation.append("开盘消化所需数据不齐（当日分钟样本需 ≥ \(NextOpenAbsorptionEngine.minimumWindowPoints) 根、需有昨收、隔夜变动需 ≥ \(String(format: "%.1f", NextOpenAbsorptionEngine.minimumOvernightPercent)) 个百分点），不给结论")
                    }
                } else {
                    explanation.append("开盘消化需要海外基准（排名市场的现价、涨跌幅与 10:00 前的观测），当前不齐，不给结论")
                }
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

    /// 126：海外侧的同一时刻口径——排名市场从它自己的昨收到「A股 10:00」的值。
    ///
    /// 昨收用 pulse 的现价与涨跌幅反解（prevClose = price / (1 + change/100)）：
    /// 本地窗口锁 9:30–10:00，海外侧也必须锁 10:00 那一刻，否则「日本下午继续跌」
    /// 会被算进「开盘半小时没消化」里——两个时间基混算，消化度就是假的。
    /// 拿不到基准（pulse 缺价/涨跌幅、窗口终点前没有观测）就返回 nil，不拿当前涨跌幅近似。
    static func overseasChangeAtWindowEnd(market: NextCrossMarket, series: [NextMarketPoint],
                                          pulse: NextCrossMarketPulse, windowEnd: Date) -> Double? {
        guard let row = pulse.rows.first(where: { $0.market == market }),
              let price = row.price, price > 0, let change = row.changePercent,
              let valueAtEnd = NextCrossMarketAlignment.lastPoint(atOrBefore: windowEnd, in: series)?.value,
              valueAtEnd > 0 else { return nil }
        let previousClose = price / (1 + change / 100)
        return NextCrossMarketAlignment.changePercent(from: previousClose, to: valueAtEnd)
    }

    // MARK: Risk Guard（124/129）

    /// 边界铁律：研究（跨市场信号）不能直接指挥交易。
    /// 即使信号来自已通过预注册前瞻复现的领先关系，它也**只**作为保守风险拦截器：
    /// 暂停该标的已有候选计划并要求重算，绝不自行创建价格、份额或交易方向。
    /// 因此这里只会返回 `.clear`（不参与）或 `.intercept`（暂停并需重算），
    /// 不再有「允许做T / 只做网格 / 不交易」这类由跨市场直接下达的计划指令。
    static func decide(judged: NextCrossHypothesis,
                       chain: NextReasoningChain,
                       execution: NextExecutionFilter?,
                       weight: Double,
                       signal: NextLoopSignal?,
                       signalEligible: Bool = false,
                       replicationNote: String? = nil,
                       explanation: inout [String]) -> NextCrossGate {
        // 透明说明：链条哪一环断了、A股 是否确认、执行层是否放行——照实写进解释，
        // 但不让这些结论变成「跨市场直接下的计划指令」。它们是背景，不是动作。
        if let broken = chain.firstBreak {
            switch broken.stage {
            case "⑤ 本地确认":
                explanation.append("A股 未确认「\(judged.statement)」（\(judged.state.label)），不交易；这不算错过，是规则要求的取消；跨市场仅作背景，不替用户下计划")
            case "⑥ 执行层":
                explanation.append("执行层拦截：\(execution?.verdict ?? "当前价格不适合追")；跨市场不据此直接下计划")
            default:
                explanation.append("链条「\(broken.stage)」：\(chain.breakReason ?? "数据不足")；跨市场仅作背景")
            }
        } else if !judged.state.allowsPlan {
            explanation.append("A股 未确认「\(judged.statement)」（\(judged.state.label)），不交易；这不算错过，是规则要求的取消；跨市场仅作背景，不替用户下计划")
        } else if let execution, !execution.allowsChasing {
            explanation.append("执行层拦截：\(execution.verdict)；跨市场不据此直接下计划")
        }
        if let replicationNote { explanation.append(replicationNote) }

        // 最终闸门：只有「已验证领先关系 + 当前信号」同时成立才拦截；否则跨市场不参与。
        if signalEligible, let signal {
            let label = signal.kind.label
            explanation.append("「\(label)」来自已通过逐 ETF 长期验证 + 预注册前瞻复现的领先关系：按边界它只作为保守风险拦截器——暂停该标的已有候选计划并要求重算，不自行生成价格、份额或交易方向")
            return .intercept(reason: "跨市场信号（已验证领先关系）作为风险拦截器：暂停已有候选计划并要求重算")
        }
        if let signal {
            explanation.append("跨市场「\(signal.kind.label)」出现，但其领先关系尚未通过逐 ETF 长期验证 + 预注册前瞻复现，不能作为拦截依据，也不参与计划决策")
        } else {
            explanation.append("跨市场未形成「已验证领先关系 + 当前信号」的组合，不参与本次计划决策（不拦截、不授权）")
        }
        return .clear(reason: "无已验证的跨市场信号：跨市场不参与本次计划决策")
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
    /// 注意：跨市场信号现在只是风险拦截器，不会自己下方向——所以复盘不再有「做T兑现」，
    /// 只判断「暂停/不参与」事后看是不是对的。
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
        case .intercept:
            // 跨市场把计划暂停了（没让方向执行）：事后看跌了就是「正确的取消」，
            // 涨了就是「错过」，都如实记，不算失败。
            if downward {
                return NextLoopReview(code: record.code, outcome: .avoidedLoss, movePercent: move,
                                      note: "按风险拦截暂停了计划，之后 \(String(format: "%+.2f%%", move))，取消是对的")
            }
            if upward {
                return NextLoopReview(code: record.code, outcome: .missedGain, movePercent: move,
                                      note: "按风险拦截暂停了计划，之后 \(String(format: "%+.2f%%", move))，属于错过；规则没触发，不算错")
            }
            return NextLoopReview(code: record.code, outcome: .noSignal, movePercent: move,
                                  note: "之后基本没动（\(String(format: "%+.2f%%", move))），这次拦截没有信息量")
        case .clear:
            // 跨市场未参与：没有方向可复盘，只如实说明。
            return NextLoopReview(code: record.code, outcome: .noSignal, movePercent: move,
                                  note: "跨市场本次未参与计划决策，无方向可复盘")
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
