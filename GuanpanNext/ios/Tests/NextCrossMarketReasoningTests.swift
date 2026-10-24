import XCTest
@testable import GuanpanAdvisorCore

/// 133 滚动有效性 + 145 完整推理链的验收。
///
/// 这两项都不产生新数字，只做一件事：**把「哪一部分还站不住」指出来，并拦住动作。**
/// 所以用例的重点不是数值精度，而是「该断的时候必须断」。
final class NextCrossMarketReasoningTests: XCTestCase {

    private let stamp = Date(timeIntervalSince1970: 1_790_000_000)

    private func window(minutes: Int = 15) -> NextLeadLagWindow {
        NextLeadLagWindow(minutes: minutes, sampleCount: 45, independentDays: 38,
                          correlation: 0.42, sameDirectionRate: 0.61,
                          wilsonLowerBound: 0.69, bonferroniP: 0.005, holdoutDays: 11,
                          meanFollowReturn: 0.12, medianFollowReturn: 0.10,
                          positiveRatio: 0.58, maxAdverseReturn: -0.42, stability: 0.75)
    }

    private func usableStudy(_ code: String = "510300") -> NextLeadLagStudy {
        let best = window()
        return NextLeadLagStudy(lead: .japan, followCode: code,
                                verdict: .usable(best: best, windows: [best],
                                                 periodDays: 60, lastValidated: stamp))
    }

    /// 「关系确实不成立」——相关性与稳定度不达标，不是样本长度问题。
    private func weakStudy(_ code: String = "510300") -> NextLeadLagStudy {
        NextLeadLagStudy(lead: .japan, followCode: code,
                         verdict: .insufficient("相关性 0.08% 低于门槛，可能只是同涨同跌"))
    }

    /// 「数据根本不够」——独立交易日不到门槛。
    /// 它和上面的区别必须在界面上看得出来：一个是坏消息，一个是不确定。
    private func sampleLimitedStudy(_ code: String = "510300") -> NextLeadLagStudy {
        NextLeadLagStudy(lead: .japan, followCode: code,
                         verdict: .insufficient("独立交易日只有 8 天，门槛 20 天（同一天里的 60 个分钟配对数不算独立证据）"))
    }

    private func pulse(usable: Bool, days: Int) -> NextCrossMarketPulse {
        let row = NextCrossMarketPulseRow(
            market: .japan, status: usable ? .open : .closed,
            price: 62_000, changePercent: 0.82,
            observedAt: stamp.addingTimeInterval(-120), ageMinutes: 2, usable: usable)
        return NextCrossMarketPulse(generatedAt: stamp, rows: [row],
                                    archivedDays: [.japan: days, .korea: days, .hongKong: days],
                                    minimumDays: 30, lunchNote: nil)
    }

    // MARK: - 133

    func test_rollingWindowsAreThirtySixtyOneTwenty() {
        XCTAssertEqual(NextRollingValidityEngine.windows, [30, 60, 120],
                       "窗口固定 30/60/120 日：短窗口看现在，长窗口看历史。20 自然日只有 14 个交易日，够不到样本门槛")
    }

    func test_rollingWithoutUsableStudySaysInsufficient() {
        let studies = [30: weakStudy(), 60: weakStudy(), 120: weakStudy()]
        let rolling = NextRollingValidityEngine.aggregate(lead: .japan, followCode: "510300", studies: studies)
        XCTAssertFalse(rolling.allowsAction)
        XCTAssertEqual(rolling.weight, 0, "没有任何窗口成立时权重必须是 0")
        XCTAssertTrue(rolling.note.contains("暂无"), "必须明说没有，不能沉默")
    }

    func test_rollingAllWindowsUsableGetsFullWeight() {
        let studies = [30: usableStudy(), 60: usableStudy(), 120: usableStudy()]
        let rolling = NextRollingValidityEngine.aggregate(lead: .japan, followCode: "510300", studies: studies)
        guard case let .usable(days, weight) = rolling.verdict else {
            return XCTFail("三个窗口都成立应判可用")
        }
        XCTAssertEqual(days, 120)
        XCTAssertEqual(weight, 1.0, accuracy: 0.001)
        XCTAssertTrue(rolling.allowsAction)
    }

    func test_rollingLostRecentWindowIsDegraded() {
        // 60/120 日成立、近 30 日不成立，且原因是关系本身不达标 —— 典型的关系衰减
        let studies = [30: weakStudy(), 60: usableStudy(), 120: usableStudy()]
        let rolling = NextRollingValidityEngine.aggregate(lead: .japan, followCode: "510300", studies: studies)
        guard case let .degraded(recent, longer, _) = rolling.verdict else {
            return XCTFail("近 30 日失效必须判降级，不能被长窗口的好看数字盖掉")
        }
        XCTAssertEqual(recent, 30)
        XCTAssertEqual(longer, 120)
        XCTAssertEqual(rolling.weight, 0.35, accuracy: 0.001)
        XCTAssertFalse(rolling.allowsAction, "降级不允许进入行动计划")
        XCTAssertTrue(rolling.note.contains("近 30 日"))
    }

    func test_rollingRecentWindowOnlyLacksSamplesIsNotCalledDecay() {
        // 短窗口「没结论」不等于「关系衰减」：前者是数据不够，后者是坏消息。
        // 把两者混为一谈，用户会以为策略变差了，实际只是还没攒够天数。
        let studies = [30: sampleLimitedStudy(), 60: usableStudy(), 120: usableStudy()]
        let rolling = NextRollingValidityEngine.aggregate(lead: .japan, followCode: "510300", studies: studies)
        guard case let .unverified(recent, longer, _) = rolling.verdict else {
            return XCTFail("样本不足不能判成衰减")
        }
        XCTAssertEqual(recent, 30)
        XCTAssertEqual(longer, 120)
        XCTAssertGreaterThan(rolling.weight, 0.35, "数据不够不该按衰减惩罚")
        XCTAssertLessThan(rolling.weight, 1.0, "但也不能给满分")
        XCTAssertFalse(rolling.allowsAction, "「不知道」不等于「可以」，仍然不许行动")
        XCTAssertTrue(rolling.note.contains("样本不足"), rolling.note)
        XCTAssertFalse(rolling.note.contains("已不成立"), "不能把数据长度问题说成关系失效")
    }

    func test_rollingOnlyShortWindowUsableGetsReducedWeight() {
        let studies = [30: usableStudy(), 60: weakStudy(), 120: weakStudy()]
        let rolling = NextRollingValidityEngine.aggregate(lead: .japan, followCode: "510300", studies: studies)
        guard case let .usable(days, weight) = rolling.verdict else {
            return XCTFail("近 30 日成立应判可用，但要降权")
        }
        XCTAssertEqual(days, 30)
        XCTAssertLessThan(weight, 1.0, "只有一个窗口成立不能给满权重")
        XCTAssertTrue(rolling.allowsAction)
    }

    func test_tailSliceKeepsOnlyRequestedDays() {
        var points: [NextMarketPoint] = []
        for day in 0..<130 {
            let date = stamp.addingTimeInterval(-Double(day) * 86_400)
            points.append(NextMarketPoint(timestamp: date, value: 100 + Double(day)))
        }
        XCTAssertEqual(NextRollingValidityEngine.tail(points, days: 20).count, 21)
        XCTAssertEqual(NextRollingValidityEngine.tail(points, days: 60).count, 61)
        XCTAssertEqual(NextRollingValidityEngine.tail(points, days: 120).count, 121)
        XCTAssertTrue(NextRollingValidityEngine.tail([], days: 20).isEmpty)
    }

    // MARK: - 145

    func test_chainBreaksOnFirstStepWhenNoLiveOverseasData() {
        let chain = NextReasoningChainBuilder.build(
            code: "510300", pulse: pulse(usable: false, days: 40),
            studies: [], rollings: [], hypothesis: nil)
        XCTAssertFalse(chain.allowsAction)
        XCTAssertEqual(chain.firstBreak?.stage, "① 海外数据新鲜度")
        XCTAssertTrue(chain.verdict.contains("只能观察"), "断链时必须写明只能观察")
        XCTAssertTrue(chain.verdict.contains("不构成交易建议"))
    }

    func test_chainBreaksOnArchiveDepthBeforeStatistics() {
        let chain = NextReasoningChainBuilder.build(
            code: "510300", pulse: pulse(usable: true, days: 10),
            studies: [], rollings: [], hypothesis: nil)
        XCTAssertEqual(chain.firstBreak?.stage, "② 归档深度")
        XCTAssertTrue(chain.breakReason?.contains("不足 30 天") ?? false)
    }

    func test_chainBreaksWhenNoStableLeadRelation() {
        let chain = NextReasoningChainBuilder.build(
            code: "510300", pulse: pulse(usable: true, days: 40),
            studies: [weakStudy()], rollings: [], hypothesis: nil)
        XCTAssertEqual(chain.firstBreak?.stage, "③ 领先关系")
        XCTAssertTrue(chain.breakReason?.contains("暂无稳定领先关系") ?? false)
    }

    func test_chainBreaksWhenRollingValidityDegraded() {
        let degraded = NextRollingValidityEngine.aggregate(
            lead: .japan, followCode: "510300",
            studies: [20: weakStudy(), 60: usableStudy(), 120: usableStudy()])
        let chain = NextReasoningChainBuilder.build(
            code: "510300", pulse: pulse(usable: true, days: 40),
            studies: [usableStudy()], rollings: [degraded], hypothesis: nil)
        XCTAssertEqual(chain.firstBreak?.stage, "④ 滚动有效性")
        XCTAssertFalse(chain.allowsAction)
    }

    func test_chainNeverLetsOverseasEvidenceSkipLocalConfirmation() {
        // 海外与统计全绿，但没有本地确认 —— 必须断在 ⑤，不能因为海外涨了就放行
        let rolling = NextRollingValidityEngine.aggregate(
            lead: .japan, followCode: "510300",
            studies: [20: usableStudy(), 60: usableStudy(), 120: usableStudy()])
        let chain = NextReasoningChainBuilder.build(
            code: "510300", pulse: pulse(usable: true, days: 40),
            studies: [usableStudy()], rollings: [rolling], hypothesis: nil)
        XCTAssertEqual(chain.firstBreak?.stage, "⑤ 本地确认")
        XCTAssertFalse(chain.allowsAction, "海外证据不能替代 A股 自己的价格与量能确认")
    }

    func test_chainPassesOnlyWithConfirmedHypothesis() {
        let rolling = NextRollingValidityEngine.aggregate(
            lead: .japan, followCode: "510300",
            studies: [20: usableStudy(), 60: usableStudy(), 120: usableStudy()])
        let hypothesis = NextCrossHypothesis(
            code: "510300", createdAt: stamp.addingTimeInterval(-600),
            confirmDeadline: stamp.addingTimeInterval(600),
            statement: "午后修复",
            overseasEvidence: ["日经 +0.82%"],
            state: .confirmed, resolution: "A股站上 VWAP、低点抬高且量能恢复，假设成立")
        let chain = NextReasoningChainBuilder.build(
            code: "510300", pulse: pulse(usable: true, days: 40),
            studies: [usableStudy()], rollings: [rolling], hypothesis: hypothesis)
        XCTAssertTrue(chain.allowsAction)
        XCTAssertTrue(chain.verdict.contains("链条完整"))
    }

    func test_chainPendingHypothesisStillBlocks() {
        let rolling = NextRollingValidityEngine.aggregate(
            lead: .japan, followCode: "510300",
            studies: [20: usableStudy(), 60: usableStudy(), 120: usableStudy()])
        let hypothesis = NextCrossHypothesis(
            code: "510300", createdAt: stamp.addingTimeInterval(-600),
            confirmDeadline: stamp.addingTimeInterval(600),
            statement: "午后修复", overseasEvidence: ["日经 +0.82%"], state: .pending)
        let chain = NextReasoningChainBuilder.build(
            code: "510300", pulse: pulse(usable: true, days: 40),
            studies: [usableStudy()], rollings: [rolling], hypothesis: hypothesis)
        XCTAssertEqual(chain.firstBreak?.stage, "⑤ 本地确认")
        XCTAssertTrue(chain.firstBreak?.gate.label.contains("等待 A股确认") ?? false)
        XCTAssertFalse(chain.allowsAction)
    }

    func test_chainPlainTextHasOneLinePerStepPlusVerdict() {
        let chain = NextReasoningChainBuilder.build(
            code: "510300", pulse: pulse(usable: true, days: 40),
            studies: [weakStudy()], rollings: [], hypothesis: nil)
        let lines = chain.plainText.split(separator: "\n")
        XCTAssertEqual(lines.count, chain.steps.count + 1)
        XCTAssertTrue(chain.steps.allSatisfy { $0.line.contains("｜") }, "每步都要有「阶段｜判定｜依据」三段")
    }
}
