import Foundation

// MARK: - 逐 ETF 的长期领先关系验证
//
// 现有 `NextLeadLagEngine` 的门槛是 20 个独立交易日，只够回答
// 「这条关系值不值得继续看」，不够回答「这条关系是否长期成立」。
// 20 天大约一个月，正好装得下一次单边行情，也正好能被一次风格切换全部推翻。
//
// 这一层补三件事：
//   1. **长期门槛**：长期验证要 100 个独立交易日；60–99 天只能算「中期，未定」。
//   2. **留出段 + 对照组**：把样本按时间 70/30 切开，只在前 70% 上挑参数，
//      然后在后 30% 上比「触发日」与「未触发日」的确认率之差（edge）。
//      这是本项目里最容易做错的一步：只看触发日 60% 的胜率毫无意义，
//      因为市场本来就有 55% 的日子在涨。**必须有对照组**。
//   3. **有把握才否定**：edge 的 95% 区间上界 ≤ 5 个百分点，才允许说
//      「没有实用增量」；p 值不显著本身不构成证据，只写「分不开」。
//
// 三种「不够」必须分开说，因为对用户的含义完全不同：
//   - `.insufficient`：还没攒够数据，再等就有结论
//   - `.inconclusive`：数据够了但分不开有用与随机，这条路大概没戏
//   - `.rejected`：有把握地否定，别再等了

/// 一个比率的置信区间。刻意用结构体而不是元组：元组不能 Codable，
/// 而这份结论要落盘给决策记忆用。
struct NextRateInterval: Equatable {
    let lower: Double
    let upper: Double

    var text: String {
        String(format: "%.0f%%–%.0f%%", lower * 100, upper * 100)
    }
}

/// 留出段的一天。`confirmed == nil` 表示数据不全、无法判断——
/// 这种天不能当成「没兑现」，否则缺数据会被算成不利证据。
struct NextEvidenceRow: Equatable {
    let day: String
    let dataComplete: Bool
    let triggered: Bool
    let confirmed: Bool?
}

enum NextEvidenceState: String, Equatable {
    case insufficient
    case noStableRelationship
    case candidateRequiresReplication
    case inconclusive

    var label: String {
        switch self {
        case .insufficient: return "样本不足"
        case .noStableRelationship: return "没有稳定关系"
        case .candidateRequiresReplication: return "候选，待复现"
        case .inconclusive: return "分不开"
        }
    }
}

struct NextHoldoutAssessment: Equatable {
    let state: NextEvidenceState
    let eligibleSessions: Int
    /// 时间顺序上的切分位置（前段用于挑参数，后段用于检验）。
    let splitIndex: Int
    let holdoutSessions: Int
    let triggerCount: Int
    let controlCount: Int
    let triggerRate: Double?
    let controlRate: Double?
    let triggerInterval: NextRateInterval?
    let controlInterval: NextRateInterval?
    /// 增量优势的区间：触发组比率 − 对照组比率，用区间端点相减而不是点估计相减。
    let edgeInterval: NextRateInterval?
    let note: String

    /// 留出段是否支持「比对照组更好」。
    var supportsEdge: Bool { state == .candidateRequiresReplication }
}

enum NextEvidenceEngine {
    /// 长期验证需要的独立交易日。参考实现在这里用 100，理由同样是「样本单位是交易日」：
    /// 100 个独立交易日约等于五个月，能覆盖至少一次风格切换。
    static let minimumSessions = 100
    /// 留出段里触发日与对照组各至少 30 天，否则两个比率都没有意义。
    static let minimumHoldoutTriggers = 30
    /// 实用增量门槛：5 个百分点。低于这个数量级的差异扣掉成本后没有意义。
    static let practicalEdge = 0.05
    /// 前 70% 挑参数，后 30% 检验。切分点必须按时间，不能随机。
    static let holdoutFraction = 0.7

    static func wilson(successes: Int, trials: Int, z: Double = 1.96) -> NextRateInterval? {
        guard trials > 0 else { return nil }
        let n = Double(trials)
        let p = Double(successes) / n
        let denominator = 1 + z * z / n
        let centre = (p + z * z / (2 * n)) / denominator
        let radius = z * ((p * (1 - p) + z * z / (4 * n)) / n).squareRoot() / denominator
        return NextRateInterval(lower: max(0, centre - radius), upper: min(1, centre + radius))
    }

    /// 留出段检验。刻意把「对照组」写进签名：没有对照组的胜率不是证据。
    static func holdout(_ rows: [NextEvidenceRow],
                        minimumSessions: Int = NextEvidenceEngine.minimumSessions) -> NextHoldoutAssessment {
        let eligible = rows.filter { $0.dataComplete && $0.confirmed != nil }.sorted { $0.day < $1.day }
        let split = Int(Double(eligible.count) * holdoutFraction)
        let holdoutRows = eligible.count > split ? Array(eligible.suffix(from: split)) : []
        let triggered = holdoutRows.filter(\.triggered)
        let controls = holdoutRows.filter { !$0.triggered }
        let triggerHits = triggered.filter { $0.confirmed == true }.count
        let controlHits = controls.filter { $0.confirmed == true }.count
        let triggerInterval = wilson(successes: triggerHits, trials: triggered.count)
        let controlInterval = wilson(successes: controlHits, trials: controls.count)
        let edge: NextRateInterval?
        if let triggerInterval, let controlInterval {
            edge = NextRateInterval(lower: max(-1, triggerInterval.lower - controlInterval.upper),
                                    upper: min(1, triggerInterval.upper - controlInterval.lower))
        } else {
            edge = nil
        }
        let triggerRate = triggered.isEmpty ? nil : Double(triggerHits) / Double(triggered.count)
        let controlRate = controls.isEmpty ? nil : Double(controlHits) / Double(controls.count)

        // 判定顺序很重要：先看样本，再看能不能否定，最后才看是不是候选。
        // 反过来写就会出现「40 天也敢宣布规律」的老毛病。
        let state: NextEvidenceState
        if eligible.count < minimumSessions
            || triggered.count < minimumHoldoutTriggers
            || controls.count < minimumHoldoutTriggers {
            state = .insufficient
        } else if let edge, edge.upper <= practicalEdge {
            state = .noStableRelationship
        } else if let edge, edge.lower > 0 {
            state = .candidateRequiresReplication
        } else {
            state = .inconclusive
        }

        let note: String
        switch state {
        case .insufficient:
            let missing: [String] = [
                eligible.count < minimumSessions ? "可用交易日 \(eligible.count) 天，需要 \(minimumSessions) 天" : nil,
                triggered.count < minimumHoldoutTriggers ? "留出段触发 \(triggered.count) 次，需要 \(minimumHoldoutTriggers) 次" : nil,
                controls.count < minimumHoldoutTriggers ? "留出段对照 \(controls.count) 天，需要 \(minimumHoldoutTriggers) 天" : nil
            ].compactMap { $0 }
            note = "样本不足，不能判断：\(missing.joined(separator: "；"))"
        case .noStableRelationship:
            note = "留出段触发组与对照组差值的 95% 区间上界只有 \(edge?.text ?? "—")，不超过 \(Int(practicalEdge * 100)) 个百分点：有把握认为没有实用增量"
        case .candidateRequiresReplication:
            note = "留出段触发组确认率 \(percent(triggerRate))、对照组 \(percent(controlRate))，差值区间 \(edge?.text ?? "—") 下界高于 0：出现候选增量，仍必须用后续未见数据复现后才可授权"
        case .inconclusive:
            note = "留出段差值区间 \(edge?.text ?? "—") 跨过 0，且上界高于 \(Int(practicalEdge * 100)) 个百分点：分不开有用增量与随机波动。**不显著不等于没有关系**，结论是「还不知道」"
        }
        return NextHoldoutAssessment(state: state, eligibleSessions: eligible.count, splitIndex: split,
                                     holdoutSessions: holdoutRows.count,
                                     triggerCount: triggered.count, controlCount: controls.count,
                                     triggerRate: triggerRate, controlRate: controlRate,
                                     triggerInterval: triggerInterval, controlInterval: controlInterval,
                                     edgeInterval: edge, note: note)
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f%%", value * 100)
    }
}

/// 逐 ETF 的长期结论。四态与 `NextEvidenceState` 不共用，因为「中期」既不是不足也不是候选。
enum NextValidationTier: String, Codable, Equatable {
    /// 独立交易日不到 60：连中期都不算。
    case insufficient
    /// 60–99 个独立交易日：中期成立，但没到长期门槛。
    case provisional
    /// 留出段有把握否定增量。
    case rejected
    /// 长期门槛 + 留出段出现增量：可以进入预注册前瞻复现。
    case candidate

    var label: String {
        switch self {
        case .insufficient: return "样本不足"
        case .provisional: return "中期，未到长期门槛"
        case .rejected: return "没有稳定关系"
        case .candidate: return "长期候选"
        }
    }

    /// 注意这个属性叫 `allowsForwardReplication` 而不是 `allowsTrading`：
    /// 统计过关只买到「允许登记、等待前瞻兑现」的资格，买不到交易授权。
    var allowsForwardReplication: Bool { self == .candidate }
}

struct NextLeadSessionPair: Equatable {
    /// yyyy-MM-dd（北京时间），同时也是时间排序键。
    let day: String
    let leadChange: Double
    let followChange: Double
    let observations: Int
}

struct NextLeadValidation: Equatable {
    let code: String
    let lead: NextCrossMarket
    let windowMinutes: Int
    /// 独立交易日数。
    let sessions: Int
    let dailyCorrelation: Double?
    let directionalWinRate: Double?
    let stability: Double?
    let holdout: NextHoldoutAssessment
    let tier: NextValidationTier
    /// 数据截止时间：验证只用这个时刻之前的点，防止把未来数据算进历史。
    let cutoff: Date
    /// 真正有方向的交易日数（|领先净变动| ≥ 触发阈值）。
    /// 相关系数可以只用几天极值撑起来，这个数不能。
    let directionalDays: Int
    /// 方向性交易日占全部样本的比例。
    let directionalShare: Double
    /// 单日最大贡献占比（0…1）。越高说明相关性越依赖某一天。
    let concentrationShare: Double
    /// 去掉贡献最大的几天之后重算的相关系数。撑不住就说明原来那个是单日事件。
    let correlationWithoutTopDays: Double?
    /// 为什么没升到候选。空字符串表示没有短板。
    let tierBlockNote: String

    init(code: String, lead: NextCrossMarket, windowMinutes: Int, sessions: Int,
         dailyCorrelation: Double?, directionalWinRate: Double?, stability: Double?,
         holdout: NextHoldoutAssessment, tier: NextValidationTier, cutoff: Date,
         directionalDays: Int = 0, directionalShare: Double = 0,
         concentrationShare: Double = 0,
         correlationWithoutTopDays: Double? = nil, tierBlockNote: String = "") {
        self.code = code
        self.lead = lead
        self.windowMinutes = windowMinutes
        self.sessions = sessions
        self.dailyCorrelation = dailyCorrelation
        self.directionalWinRate = directionalWinRate
        self.stability = stability
        self.holdout = holdout
        self.tier = tier
        self.cutoff = cutoff
        self.directionalDays = directionalDays
        self.directionalShare = directionalShare
        self.concentrationShare = concentrationShare
        self.correlationWithoutTopDays = correlationWithoutTopDays
        self.tierBlockNote = tierBlockNote
    }

    var allowsForwardReplication: Bool { tier.allowsForwardReplication }

    var note: String {
        let corr = dailyCorrelation.map { String(format: "%.2f", $0) } ?? "—"
        let win = NextEvidenceEngine.percent(directionalWinRate)
        let stable = stability.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
        var text = "\(lead.displayName) → \(code)：\(sessions) 个独立交易日 · 日级相关 \(corr) · 方向命中 \(win)（\(directionalDays) 个方向性交易日，占 \(String(format: "%.0f%%", directionalShare * 100))）· 分段稳定 \(stable) · \(tier.label)"
        if !tierBlockNote.isEmpty { text += "（\(tierBlockNote)）" }
        return text
    }
}

enum NextLeadValidationEngine {
    /// 中期门槛。60 个交易日约三个月，能覆盖一次完整的季度风格。
    static let provisionalSessions = 60
    /// 触发阈值：领先市场当日净变动超过 0.30% 才算「有信号」。
    /// 低于这个幅度的净变动基本是噪声，拿它当触发会把对照组也污染掉。
    static let triggerThreshold = 0.30
    /// 一天至少 3 个配对才认为这天数据完整。
    static let minimumObservationsPerDay = 3
    /// 有方向的交易日最低数量。这一条专门防「伪相关」：
    /// 相关系数可以靠一两个极值日撑到 0.8，但「30 天真的动了并且跟对了」撑不出来。
    static let minimumDirectionalDays = 30
    /// 方向性交易日占全部样本的最低比例。只有 30 天方向、却掺了 200 天噪声，
    /// 说明这条关系只在少数事件日上碰巧成立——那是事件，不是关系。
    static let minimumDirectionalShare = 0.30
    /// 单日最大贡献占比上限。超过一半，说明这条关系实际上是「某一天的关系」。
    static let maximumSingleDayShare = 0.50
    /// 去掉最极端几天后相关系数的下限。撑不住就说明原来那个数是单日事件造的。
    static let minimumCorrelationWithoutTopDays = 0.20
    /// 分段稳定度门槛，与 117 的口径一致。
    static let minimumStability = 0.65

    static var shanghai: Calendar { NextLeadLagEngine.shanghai }

    static func dayKey(_ date: Date) -> String {
        let parts = shanghai.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// 逐日聚合配对。**先按天取均值再做统计**，不是把所有分钟配对数混在一起：
    /// 同一天里的 80 根 5 分钟线只提供大约 1 天的独立信息，混在一起算会得到虚高的显著性。
    static func sessionPairs(lead: [NextMarketPoint], follow: [NextMarketPoint],
                             minutes: Int, cutoff: Date?) -> [NextLeadSessionPair] {
        let windowSeconds = Double(minutes) * 60
        let tolerance = max(windowSeconds, 60) + 60
        var buckets: [String: [(lead: Double, follow: Double)]] = [:]
        for point in lead {
            if let cutoff, point.timestamp > cutoff { continue }
            guard let previous = NextCrossMarketAlignment.lastPoint(atOrBefore: point.timestamp.addingTimeInterval(-windowSeconds),
                                                                   in: lead) else { continue }
            guard let leadChange = NextCrossMarketAlignment.changePercent(from: previous.value, to: point.value) else { continue }
            guard let exit = NextCrossMarketAlignment.firstPoint(atOrAfter: point.timestamp, in: follow,
                                                                tolerance: tolerance) else { continue }
            guard let end = NextCrossMarketAlignment.firstPoint(atOrAfter: point.timestamp.addingTimeInterval(windowSeconds),
                                                               in: follow, tolerance: tolerance) else { continue }
            guard let followReturn = NextCrossMarketAlignment.changePercent(from: exit.value, to: end.value) else { continue }
            buckets[dayKey(point.timestamp), default: []].append((leadChange, followReturn))
        }
        return buckets.keys.sorted().compactMap { day in
            guard let rows = buckets[day], !rows.isEmpty else { return nil }
            let n = Double(rows.count)
            return NextLeadSessionPair(day: day,
                                       leadChange: rows.map(\.lead).reduce(0, +) / n,
                                       followChange: rows.map(\.follow).reduce(0, +) / n,
                                       observations: rows.count)
        }
    }

    static func validate(code: String, lead: NextCrossMarket,
                         leadSeries: [NextMarketPoint], followSeries: [NextMarketPoint],
                         windowMinutes: Int = 15, cutoff: Date,
                         triggerThreshold: Double = NextLeadValidationEngine.triggerThreshold) -> NextLeadValidation {
        let leadSorted = leadSeries.sorted { $0.timestamp < $1.timestamp }
        let followSorted = followSeries.sorted { $0.timestamp < $1.timestamp }
        let pairs = sessionPairs(lead: leadSorted, follow: followSorted,
                                 minutes: windowMinutes, cutoff: cutoff)
        let leads = pairs.map(\.leadChange)
        let follows = pairs.map(\.followChange)
        let correlation = pairs.count >= 3 ? NextLeadLagEngine.pearson(leads, follows) : nil

        // 方向命中率：只在领先市场真的动了的日子里统计。
        // 分母排除「领先市场几乎没动」的日子，因为那种日子本来就没有方向可跟。
        let directional = pairs.filter { abs($0.leadChange) >= triggerThreshold }
        let directionalHits = directional.filter { ($0.leadChange > 0) == ($0.followChange > 0) }.count
        let directionalDays = directional.count
        let directionalShare = pairs.isEmpty ? 0 : Double(directionalDays) / Double(pairs.count)
        let directionalWinRate = directional.isEmpty ? nil : Double(directionalHits) / Double(directional.count)

        // 分段稳定度：前后两半各自的日级相关系数差多少。1 表示完全一致。
        let stability: Double?
        if pairs.count >= 6 {
            let half = pairs.count / 2
            let first = Array(pairs.prefix(half))
            let second = Array(pairs.suffix(from: half))
            let c1 = NextLeadLagEngine.pearson(first.map(\.leadChange), first.map(\.followChange))
            let c2 = NextLeadLagEngine.pearson(second.map(\.leadChange), second.map(\.followChange))
            stability = 1 - min(1, abs(c1 - c2) / 2)
        } else {
            stability = nil
        }

        // 留出段的行：triggered = 当天领先市场净变动超过阈值，confirmed = 跟随同向。
        // 对照组就是「没超阈值」的日子——没有它，胜率无法与市场基准区分。
        let rows = pairs.map { pair in
            NextEvidenceRow(day: pair.day,
                            dataComplete: pair.observations >= minimumObservationsPerDay,
                            triggered: abs(pair.leadChange) >= triggerThreshold,
                            confirmed: pair.observations >= minimumObservationsPerDay
                                ? (pair.leadChange > 0) == (pair.followChange > 0) : nil)
        }
        let holdout = NextEvidenceEngine.holdout(rows)

        // 集中度与「去掉极值后还成不成立」。
        // 用 |领先变动 × 跟随变动| 度量单日对相关性的贡献：它同时要求两边都动，
        // 单边跳空（只有一边动）不会被误算成高贡献日。
        let weights = pairs.map { abs($0.leadChange * $0.followChange) }
        let totalWeight = weights.reduce(0, +)
        let concentrationShare = totalWeight > 0 ? (weights.max() ?? 0) / totalWeight : 1
        // 去掉前 5%（最多 3 天，至少 1 天）。不能只去 1 天：一天异常往往连着两三天。
        let dropCount = min(3, max(1, pairs.count / 20))
        let ranked = pairs.indices.sorted { weights[$0] > weights[$1] }
        let dropped = Set(ranked.prefix(min(dropCount, max(0, pairs.count - 5))))
        let trimmedLeads = pairs.indices.filter { !dropped.contains($0) }.map { pairs[$0].leadChange }
        let trimmedFollows = pairs.indices.filter { !dropped.contains($0) }.map { pairs[$0].followChange }
        let correlationWithoutTopDays = trimmedLeads.count >= 5
            ? NextLeadLagEngine.pearson(trimmedLeads, trimmedFollows) : nil

        var blockNote = ""
        let tier: NextValidationTier
        if pairs.count < provisionalSessions {
            tier = .insufficient
            blockNote = "只有 \(pairs.count) 个独立交易日，中期门槛是 \(provisionalSessions) 天"
        } else if holdout.state == .noStableRelationship {
            tier = .rejected
            blockNote = holdout.note
        } else if directionalDays < minimumDirectionalDays || directionalShare < minimumDirectionalShare {
            // 少数事件日碰巧相关 —— 这是**否定**，不是「再等等」。
            // 只有 10 个方向性交易日却掺在 200 天噪声里，那不是关系，那是几次事件。
            tier = .rejected
            blockNote = String(format: "没有稳定领先关系：方向性交易日只有 %d 天（占 %.0f%%），要求至少 %d 天且占样本 %d%%；相关系数是少数事件日凑出来的",
                               directionalDays, directionalShare * 100,
                               minimumDirectionalDays, Int(minimumDirectionalShare * 100))
        } else if concentrationShare > maximumSingleDayShare {
            tier = .rejected
            blockNote = String(format: "没有稳定领先关系：单日最大贡献占 %.0f%%，超过 %.0f%%——这条关系实际上只是某一天的关系", concentrationShare * 100, maximumSingleDayShare * 100)
        } else if (correlationWithoutTopDays ?? 0) < minimumCorrelationWithoutTopDays {
            tier = .rejected
            blockNote = "没有稳定领先关系：去掉贡献最大的 \(dropCount) 天后相关性从 \(String(format: "%.2f", correlation ?? 0)) 降到 \(String(format: "%.2f", correlationWithoutTopDays ?? 0))，低于 \(String(format: "%.2f", minimumCorrelationWithoutTopDays))——原相关性靠少数几天撑着"
        } else if pairs.count < NextEvidenceEngine.minimumSessions {
            // 稳健性都过了，只是天数还没到长期门槛。
            tier = .provisional
            blockNote = "\(pairs.count) 个独立交易日，未到长期门槛 \(NextEvidenceEngine.minimumSessions) 天"
        } else if holdout.state != .candidateRequiresReplication {
            // 留出段没跑赢对照组：不是否定，只是还没有证据。
            tier = .provisional
            blockNote = holdout.note
        } else {
            tier = .candidate
        }

        return NextLeadValidation(code: code, lead: lead, windowMinutes: windowMinutes,
                                  sessions: pairs.count,
                                  dailyCorrelation: correlation,
                                  directionalWinRate: directionalWinRate,
                                  stability: stability,
                                  holdout: holdout, tier: tier, cutoff: cutoff,
                                  directionalDays: directionalDays,
                                  directionalShare: directionalShare,
                                  concentrationShare: concentrationShare,
                                  correlationWithoutTopDays: correlationWithoutTopDays,
                                  tierBlockNote: blockNote)
    }
}

/// 逐 ETF 的长期验证台账。落盘用，也是「有没有真正验证过」的唯一凭据——
/// 内存里的 study 会随刷新消失，台账不会。
struct NextLeadLedgerEntry: Codable, Equatable, Identifiable {
    var id: String { "\(code)-\(leadRaw)" }
    let code: String
    let leadRaw: String
    let sessions: Int
    let windowMinutes: Int
    let dailyCorrelation: Double?
    let directionalWinRate: Double?
    let stability: Double?
    let triggerRate: Double?
    let controlRate: Double?
    let edgeLower: Double?
    let edgeUpper: Double?
    /// 方向性交易日数、单日集中度、去掉极值后的相关性。
    /// 落盘是必须的：这三项是「为什么没升级」的证据，丢了就只能重跑。
    let directionalDays: Int
    let directionalShare: Double
    let concentrationShare: Double
    let correlationWithoutTopDays: Double?
    let evidenceStateRaw: String
    let validatedAt: Date
    let dataCutoff: Date

    var lead: NextCrossMarket? { NextCrossMarket(rawValue: leadRaw) }
    var evidenceState: NextEvidenceState { NextEvidenceState(rawValue: evidenceStateRaw) ?? .insufficient }
}

struct NextLeadLedger: Codable, Equatable {
    var entries: [NextLeadLedgerEntry] = []

    func entry(code: String, lead: NextCrossMarket) -> NextLeadLedgerEntry? {
        entries.first { $0.code == code && $0.leadRaw == lead.rawValue }
    }

    /// 记录一次验证。同一 (ETF, 领先市场) 只保留最新一条：台账不是流水账，
    /// 它回答「现在这条关系处在什么状态」。
    mutating func record(_ validation: NextLeadValidation, at now: Date) {
        let entry = NextLeadLedgerEntry(code: validation.code,
                                        leadRaw: validation.lead.rawValue,
                                        sessions: validation.sessions,
                                        windowMinutes: validation.windowMinutes,
                                        dailyCorrelation: validation.dailyCorrelation,
                                        directionalWinRate: validation.directionalWinRate,
                                        stability: validation.stability,
                                        triggerRate: validation.holdout.triggerRate,
                                        controlRate: validation.holdout.controlRate,
                                        edgeLower: validation.holdout.edgeInterval?.lower,
                                        edgeUpper: validation.holdout.edgeInterval?.upper,
                                        directionalDays: validation.directionalDays,
                                        directionalShare: validation.directionalShare,
                                        concentrationShare: validation.concentrationShare,
                                        correlationWithoutTopDays: validation.correlationWithoutTopDays,
                                        evidenceStateRaw: validation.holdout.state.rawValue,
                                        validatedAt: now,
                                        dataCutoff: validation.cutoff)
        if let index = entries.firstIndex(where: { $0.code == entry.code && $0.leadRaw == entry.leadRaw }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }

    /// 是否已有 ETF 走到「长期候选」。空台账 = 一条都没验证过，界面必须承认这一点。
    var candidateCodes: [String] {
        entries.filter { $0.evidenceState == .candidateRequiresReplication }.map(\.code)
    }

    var summary: String {
        guard !entries.isEmpty else {
            return "还没有任何逐 ETF 的长期验证记录（需要 100 个独立交易日才可能成立）"
        }
        let candidates = entries.filter { $0.evidenceState == .candidateRequiresReplication }
        let rejected = entries.filter { $0.evidenceState == .noStableRelationship }
        return "已记录 \(entries.count) 条逐 ETF 领先验证：候选 \(candidates.count) 条、有把握否定 \(rejected.count) 条"
    }
}
