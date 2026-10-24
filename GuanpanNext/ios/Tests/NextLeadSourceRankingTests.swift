import XCTest
@testable import GuanpanAdvisorCore

/// 131 领先来源排名。
///
/// 要防的是「相关系数最大的那个就是最好的来源」这种直觉：
/// 相关系数会被趋势段放大，同向率低说明两点之间其实并不同涨同跌，
/// 133 的滚动权重低说明这条关系最近已经不灵了。三者都要进综合分。
final class NextLeadSourceRankingTests: XCTestCase {

    private func study(_ lead: NextCrossMarket, code: String = "513520", minutes: Int = 15,
                       correlation: Double, sameDirection: Double) -> NextLeadLagStudy {
        let window = NextLeadLagWindow(minutes: minutes, sampleCount: 60, independentDays: 40,
                                       correlation: correlation, sameDirectionRate: sameDirection,
                                       wilsonLowerBound: 0.66, bonferroniP: 0.007, holdoutDays: 12,
                                       meanFollowReturn: 0.10, medianFollowReturn: 0.08,
                                       positiveRatio: 0.55, maxAdverseReturn: -0.30, stability: 0.80)
        return NextLeadLagStudy(lead: lead, followCode: code,
                                verdict: .usable(best: window, windows: [window],
                                                 periodDays: 60,
                                                 lastValidated: Date(timeIntervalSince1970: 1_790_000_000)))
    }

    private func degraded(_ lead: NextCrossMarket, code: String = "513520") -> NextRollingValidity {
        NextRollingValidity(lead: lead, followCode: code, studies: [:],
                            verdict: .degraded(recentDays: 20, longerDays: 120,
                                               reason: "近 20 日窗口没有达到门槛"))
    }

    private func usable(_ lead: NextCrossMarket, code: String = "513520", weight: Double = 1.0) -> NextRollingValidity {
        NextRollingValidity(lead: lead, followCode: code, studies: [:],
                            verdict: .usable(days: 120, weight: weight))
    }

    func test_rankingWithoutEvidenceSaysNoSource() {
        let ranking = NextLeadSourceRanker.rank(code: "513520", studies: [], rollings: [])
        XCTAssertFalse(ranking.hasEvidence)
        XCTAssertNil(ranking.top)
        XCTAssertTrue(ranking.summary.contains("暂无稳定领先来源"))
    }

    func test_rankingWeighsSameDirectionNotJustCorrelation() {
        // 相关系数更高但同向率低的那条，不应该排在前面
        let studies = [
            study(.japan, correlation: 0.90, sameDirection: 0.50),
            study(.korea, correlation: 0.60, sameDirection: 0.95)
        ]
        let ranking = NextLeadSourceRanker.rank(code: "513520", studies: studies, rollings: [])
        XCTAssertEqual(ranking.entries.count, 2)
        XCTAssertEqual(ranking.top?.lead, .korea, "同向率高的来源应排在相关系数高的前面")
        XCTAssertTrue(ranking.summary.contains("未做滚动检验"), "没有滚动结论时必须说清楚权重是按中性算的")
    }

    func test_rankingDemotesSourceWhoseRelationDecayed() {
        let studies = [
            study(.japan, correlation: 0.90, sameDirection: 0.90),
            study(.korea, correlation: 0.50, sameDirection: 0.90)
        ]
        let rollings = [degraded(.japan), usable(.korea)]
        let ranking = NextLeadSourceRanker.rank(code: "513520", studies: studies, rollings: rollings)
        XCTAssertEqual(ranking.top?.lead, .korea, "已经衰减的来源即使相关性更高也不能排第一")
        let japan = ranking.entries.first { $0.lead == .japan }
        XCTAssertEqual(japan?.rollingWeight ?? -1, 0.35, accuracy: 0.001)
        XCTAssertTrue(japan?.rollingKnown ?? false)
    }

    func test_rankingIgnoresOtherCodesAndRespectsLimit() {
        let studies = [
            study(.japan, code: "513520", correlation: 0.8, sameDirection: 0.8),
            study(.korea, code: "513520", correlation: 0.7, sameDirection: 0.8),
            study(.unitedStates, code: "999999", correlation: 0.9, sameDirection: 0.9)
        ]
        let ranking = NextLeadSourceRanker.rank(code: "513520", studies: studies, rollings: [], limit: 1)
        XCTAssertEqual(ranking.entries.count, 1, "别的标的的 study 不能算进来，limit 也要生效")
        XCTAssertFalse(ranking.entries.contains { $0.lead == .unitedStates })
    }
}
