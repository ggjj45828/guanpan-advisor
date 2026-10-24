import Foundation

// MARK: - 133 滚动有效性（20 / 60 / 120 日）
//
// 一条「领先关系」最容易骗人的地方不是算错，而是**只在某一段时间成立**：
// 拿 120 日数据算出一个漂亮的相关性，最近一个月其实早就没什么关系了。
// 所以这里同时算三个窗口，并且把「近 20 日已经失效」明确降权 —— 而不是
// 用长窗口的好看数字去覆盖短窗口的坏消息。

enum NextRollingVerdict: Equatable {
    /// 任何窗口都没达到样本/相关性/稳定度门槛。
    case insufficient(String)
    /// 长窗口曾经成立，但最近的窗口已经不成立。只能当背景，不得据此行动。
    case degraded(recentDays: Int, longerDays: Int, reason: String)
    /// 最近的窗口也成立。weight 表示可依赖程度（0…1）。
    case usable(days: Int, weight: Double)
}

struct NextRollingValidity: Equatable {
    let lead: NextCrossMarket
    let followCode: String
    /// 窗口天数 → 该窗口的统计。没有做的窗口直接不出现。
    let studies: [Int: NextLeadLagStudy]
    let verdict: NextRollingVerdict

    /// 方向性权重。降级与不足都必须是 0.5 以下 —— 让它无法被当成正式信号。
    var weight: Double {
        switch verdict {
        case .insufficient: return 0
        case .degraded: return 0.35
        case let .usable(_, weight): return weight
        }
    }

    /// 只有「最近的窗口也成立」才允许进入行动计划。
    var allowsAction: Bool {
        if case .usable = verdict { return true }
        return false
    }

    var note: String {
        switch verdict {
        case let .insufficient(reason):
            return "\(lead.displayName) 对 \(followCode) 的滚动有效性：暂无（\(reason)）"
        case let .degraded(recent, longer, reason):
            return "\(lead.displayName) 对 \(followCode) 近 \(recent) 日已不成立（\(longer) 日窗口曾成立，\(reason)），权重降为 \(NextRollingValidity.percent(weight))，只能当背景"
        case let .usable(days, weight):
            return "\(lead.displayName) 对 \(followCode) 的领先关系在 \(days) 日窗口内仍成立，权重 \(NextRollingValidity.percent(weight))"
        }
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }
}

enum NextRollingValidityEngine {
    /// 三个窗口固定写在代码里：短窗口抓「最近还灵不灵」，长窗口抓「历史上灵不灵」。
    static let windows = [20, 60, 120]

    /// 把三个窗口的 study 汇成一个结论。这是 133 的核心判定，与取数分开，便于测试。
    static func aggregate(lead: NextCrossMarket, followCode: String,
                          studies: [Int: NextLeadLagStudy]) -> NextRollingValidity {
        let usableDays = windows.filter { days in
            guard let study = studies[days] else { return false }
            return study.best != nil
        }
        guard let shortest = usableDays.min(), let longest = usableDays.max() else {
            let reason = studies.isEmpty
                ? "还没有任何窗口的统计"
                : "20/60/120 日窗口都没达到样本 \(NextLeadLagEngine.minimumSamples) 个且相关 \(NextLeadLagStudy.percent(NextLeadLagEngine.minimumCorrelation, digits: 0)) 的门槛"
            return NextRollingValidity(lead: lead, followCode: followCode, studies: studies,
                                       verdict: .insufficient(reason))
        }
        guard shortest == windows[0] else {
            // 短窗口不成立而长窗口成立：典型的关系衰减，必须写出来并降权。
            return NextRollingValidity(
                lead: lead, followCode: followCode, studies: studies,
                verdict: .degraded(recentDays: windows[0], longerDays: longest,
                                   reason: "近 \(windows[0]) 日窗口没有达到门槛，长窗口的数字不能代表现在"))
        }
        let weight: Double
        if longest >= 120 {
            weight = 1.0
        } else if longest >= 60 {
            weight = 0.8
        } else {
            weight = 0.6
        }
        return NextRollingValidity(lead: lead, followCode: followCode, studies: studies,
                                   verdict: .usable(days: longest, weight: weight))
    }

    /// 按窗口天数截取序列尾部。窗口越长，参与统计的样本越多。
    static func tail(_ points: [NextMarketPoint], days: Int) -> [NextMarketPoint] {
        guard let last = points.map(\.timestamp).max() else { return [] }
        let floor = last.addingTimeInterval(-Double(days) * 86_400)
        return points.filter { $0.timestamp >= floor }
    }

    /// 一次算完三个窗口。数据不够时每个窗口各自返回「不足」，不会互相借用样本。
    static func studies(lead: NextCrossMarket, leadSeries: [NextMarketPoint],
                        followCode: String, followSeries: [NextMarketPoint],
                        lastValidated: Date) -> [Int: NextLeadLagStudy] {
        var result: [Int: NextLeadLagStudy] = [:]
        for days in windows {
            result[days] = NextLeadLagEngine.study(
                lead: lead,
                leadSeries: tail(leadSeries, days: days),
                followCode: followCode,
                followSeries: tail(followSeries, days: days),
                lastValidated: lastValidated)
        }
        return result
    }
}

// MARK: - 145 完整推理链
//
// 这张表回答的是「这条建议到底是怎么来的、断在哪一步」。
// 每一步都必须能给出「通过 / 仅背景 / 断开」三态之一，而且**任何一步断开都不许产生动作**——
// 这样才能避免「海外涨了所以可以买」这种把背景当结论的推理。

struct NextReasoningStep: Equatable {
    enum Gate: Equatable {
        case pass
        case background
        case blocked(String)

        var label: String {
            switch self {
            case .pass: return "通过"
            case .background: return "仅背景"
            case let .blocked(reason): return "断开：\(reason)"
            }
        }

        /// 只有 blocked 会拦住整条链。background 表示这项没数据，但不单独构成否决理由。
        var blocksAction: Bool {
            if case .blocked = self { return true }
            return false
        }
    }

    let stage: String
    let detail: String
    let gate: Gate

    var line: String { "\(stage)｜\(gate.label)｜\(detail)" }
}

struct NextReasoningChain: Equatable {
    let code: String
    let steps: [NextReasoningStep]

    var firstBreak: NextReasoningStep? {
        steps.first { $0.gate.blocksAction }
    }

    /// 断在哪一步。没有断点才是 nil。
    var breakReason: String? {
        guard let gate = firstBreak?.gate else { return nil }
        if case let .blocked(reason) = gate { return reason }
        return nil
    }

    /// 链条一步都没断，才允许进入候选计划。空链条也不算通过。
    var allowsAction: Bool { !steps.isEmpty && firstBreak == nil }

    var verdict: String {
        guard let broken = firstBreak, let reason = breakReason else {
            return "链条完整：跨市场证据、领先关系与本地确认都成立，可进入候选计划（仓位与成本仍由你决定）"
        }
        return "链条在「\(broken.stage)」断开：\(reason)。现阶段只能观察，不构成交易建议"
    }

    var plainText: String {
        var lines = steps.map(\.line)
        lines.append(verdict)
        return lines.joined(separator: "\n")
    }
}

enum NextReasoningChainBuilder {
    /// 六个环节固定顺序。任何一环缺数据都写成「断开」或「仅背景」，不留空白。
    static func build(code: String,
                      name: String? = nil,
                      pulse: NextCrossMarketPulse,
                      studies: [NextLeadLagStudy],
                      rollings: [NextRollingValidity],
                      hypothesis: NextCrossHypothesis?,
                      execution: NextExecutionFilter? = nil) -> NextReasoningChain {
        let label = name.map { "\(code) \($0)" } ?? code
        var steps: [NextReasoningStep] = []

        // ① 海外数据新鲜度：休市与过期都不算「今天的信息」。
        let live = pulse.rows.filter(\.usable)
        if live.isEmpty {
            steps.append(NextReasoningStep(
                stage: "① 海外数据新鲜度",
                detail: "没有市场处于交易中且 30 分钟内有更新（\(pulse.footnote)）",
                gate: .blocked("没有任何可用实时数据")))
        } else {
            let text = live.map { "\(NextCrossMarketPulse.shortName($0.market)) \($0.changeText)" }
                .joined(separator: " · ")
            steps.append(NextReasoningStep(
                stage: "① 海外数据新鲜度",
                detail: "\(live.count) 个市场有效：\(text)",
                gate: .pass))
        }

        // ② 归档深度：不够 30 天就谈不上「稳定」。
        let days = [NextCrossMarket.japan, .korea, .hongKong]
            .map { pulse.archivedDays[$0] ?? 0 }
            .max() ?? 0
        if days < pulse.minimumDays {
            steps.append(NextReasoningStep(
                stage: "② 归档深度",
                detail: "最多只有 \(days) 个交易日，门槛 \(pulse.minimumDays) 天",
                gate: .blocked("归档不足 \(pulse.minimumDays) 天，统计没有意义")))
        } else {
            steps.append(NextReasoningStep(
                stage: "② 归档深度",
                detail: "已归档 \(days) 个交易日",
                gate: .pass))
        }

        // ③ 领先关系：只认 usable 的 study，不认「有个对象存在」。
        let usableStudies = studies.filter { $0.best != nil }
        if let best = usableStudies.first {
            steps.append(NextReasoningStep(
                stage: "③ 领先关系",
                detail: best.summary,
                gate: .pass))
        } else if studies.isEmpty {
            steps.append(NextReasoningStep(
                stage: "③ 领先关系",
                detail: "还没有对 \(label) 做过领先统计",
                gate: .blocked("没有已验证的领先关系")))
        } else {
            steps.append(NextReasoningStep(
                stage: "③ 领先关系",
                detail: studies.first?.summary ?? "暂无",
                gate: .blocked("统计没达到门槛，暂无稳定领先关系")))
        }

        // ④ 滚动有效性：长窗口好、短窗口坏，一律降权并拦住。
        if rollings.isEmpty {
            steps.append(NextReasoningStep(
                stage: "④ 滚动有效性",
                detail: "还没有做 20/60/120 日滚动检验",
                gate: .background))
        } else if let best = rollings.max(by: { $0.weight < $1.weight }), best.allowsAction {
            steps.append(NextReasoningStep(
                stage: "④ 滚动有效性",
                detail: best.note,
                gate: .pass))
        } else {
            let note = rollings.min(by: { $0.weight < $1.weight })?.note ?? "滚动检验未通过"
            steps.append(NextReasoningStep(
                stage: "④ 滚动有效性",
                detail: note,
                gate: .blocked("领先关系在最近窗口已衰减")))
        }

        // ⑤ 本地确认：海外证据本身永远不能变成 confirmed。
        if let hypothesis {
            let detail = "假设「\(hypothesis.statement)」\(hypothesis.state.label)"
                + (hypothesis.resolution.map { " · \($0)" } ?? "")
            let gate: NextReasoningStep.Gate = hypothesis.state.allowsPlan
                ? .pass
                : .blocked(hypothesis.state.label)
            steps.append(NextReasoningStep(
                stage: "⑤ 本地确认",
                detail: detail,
                gate: gate))
        } else {
            steps.append(NextReasoningStep(
                stage: "⑤ 本地确认",
                detail: "没有针对 \(label) 的实时假设",
                gate: .blocked("海外证据还没有经过 A股 价格与量能确认")))
        }

        // ⑥ 执行层：方向对不代表这个价格能买。
        if let execution {
            let gate: NextReasoningStep.Gate = execution.allowsChasing
                ? .pass
                : .blocked("当前价格不适合追")
            steps.append(NextReasoningStep(
                stage: "⑥ 执行层",
                detail: execution.verdict,
                gate: gate))
        } else {
            steps.append(NextReasoningStep(
                stage: "⑥ 执行层",
                detail: "没有溢折价与盘口数据，成交成本未知",
                gate: .background))
        }

        return NextReasoningChain(code: code, steps: steps)
    }
}

// MARK: - 131 领先来源排名
//
// 一只 ETF 可能同时对日经、对纳指都有统计。问题是「谁更值得看」。
// 这里不按相关系数单独排序：相关性会被趋势段放大，所以综合分里必须带上
// 同向率（能不能真的同涨同跌）和 133 的滚动权重（现在还灵不灵）。
// 没有滚动结论时给 0.5 的中性权重并在文案里写明「未做滚动检验」，不假装满分。

struct NextLeadSourceRanking: Equatable {
    struct Entry: Equatable {
        let lead: NextCrossMarket
        let minutes: Int
        let correlation: Double
        let sameDirectionRate: Double
        let sampleCount: Int
        /// 133 的权重；没做过滚动检验时是 0.5（中性，不奖不罚）。
        let rollingWeight: Double
        let rollingKnown: Bool

        /// 综合分：|相关| × 同向率 × 滚动权重。范围 0…1。
        var score: Double { abs(correlation) * max(0, min(1, sameDirectionRate)) * rollingWeight }
    }

    let code: String
    let entries: [Entry]

    var top: Entry? { entries.first }
    var hasEvidence: Bool { !entries.isEmpty }

    var summary: String {
        guard let top else { return "暂无稳定领先来源：没有任何市场通过样本与相关性门槛" }
        let head = "最值得看的是\(top.lead.displayName)：领先约 \(top.minutes) 分钟 · 同向 \(NextLeadLagStudy.percent(top.sameDirectionRate, digits: 0)) · 综合 \(String(format: "%.2f", top.score))"
        return top.rollingKnown ? head : head + "（未做滚动检验，权重按中性计）"
    }
}

enum NextLeadSourceRanker {
    /// 同一市场有多个窗口时只取最好的那一个，否则同一来源会重复占位。
    static func rank(code: String, studies: [NextLeadLagStudy],
                     rollings: [NextRollingValidity], limit: Int = 4) -> NextLeadSourceRanking {
        var weights: [NextCrossMarket: NextRollingValidity] = [:]
        for rolling in rollings where rolling.followCode == code {
            if let existing = weights[rolling.lead], existing.weight >= rolling.weight { continue }
            weights[rolling.lead] = rolling
        }
        var entries: [Entry] = []
        for study in studies where study.followCode == code {
            guard let best = study.best else { continue }
            let rolling = weights[study.lead]
            let entry = Entry(
                lead: study.lead,
                minutes: best.minutes,
                correlation: best.correlation,
                sameDirectionRate: best.sameDirectionRate,
                sampleCount: best.sampleCount,
                rollingWeight: rolling?.weight ?? 0.5,
                rollingKnown: rolling != nil)
            // 同一来源已经在列表里且分数更高就跳过（study 顺序不保证）。
            if let index = entries.firstIndex(where: { $0.lead == entry.lead }) {
                if entries[index].score >= entry.score { continue }
                entries[index] = entry
            } else {
                entries.append(entry)
            }
        }
        entries.sort { lhs, rhs in
            if lhs.score == rhs.score { return lhs.minutes < rhs.minutes }
            return lhs.score > rhs.score
        }
        return NextLeadSourceRanking(code: code, entries: Array(entries.prefix(max(1, limit))))
    }
}
