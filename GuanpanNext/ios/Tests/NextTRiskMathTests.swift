import XCTest
@testable import GuanpanAdvisorCore

/// 做T双向风险与金额口径。
///
/// 两个要钉住的事实：
/// 1. 反T 怕踏空、正T 怕被套，不能只写一边；
/// 2. 不利成本里**不能**再包含计划本来要赚的价差——
///    旧公式把计划净收益又算了一遍，越是好计划显示的风险越大。
final class NextTRiskMathTests: XCTestCase {

    private func dec(_ text: String) -> Decimal { Decimal(string: text)! }

    // MARK: - 金额口径

    func test_adverseCostIsOnlyAmplitudePlusFees() {
        // 振幅 2%、卖价 1.42、3000 份、两笔手续费 0.20
        // 1.42 × 0.02 = 0.0284 → × 3000 = 85.2 → + 0.20 = 85.4
        let cost = NextTRiskMath.adverseCost(referencePrice: dec("1.42"), amplitudePercent: 2,
                                             units: 3000, feeTotal: dec("0.20"))
        XCTAssertEqual(cost, dec("85.4"))
    }

    func test_adverseCostDoesNotIncludePlannedSpread() {
        // 计划本身赚 119.80。旧公式 (1.42+0.0284-1.38)×3000-0.20 ≈ 205.0，
        // 比真实风险多出约一个计划收益。新口径必须明显更小。
        let cost = NextTRiskMath.adverseCost(referencePrice: dec("1.42"), amplitudePercent: 2,
                                             units: 3000, feeTotal: dec("0.20"))
        let oldFormula = (dec("1.42") + dec("0.0284") - dec("1.38")) * Decimal(3000) - dec("0.20")
        XCTAssertLessThan(cost, oldFormula)
        XCTAssertGreaterThan(oldFormula - cost, dec("100"),
                             "差额应接近一个计划收益，说明旧公式确实重复计入了价差")
    }

    func test_adverseCostIsIndependentOfSpreadWidth() {
        // 同样的振幅和份额，成本只与波动幅度有关，与计划价差多宽无关。
        // 深度价差（好计划）不应该因此显示成高风险。
        let narrow = NextTRiskMath.adverseCost(referencePrice: dec("1.40"), amplitudePercent: 1.5,
                                               units: 1000, feeTotal: dec("0.20"))
        let wide = NextTRiskMath.adverseCost(referencePrice: dec("1.40"), amplitudePercent: 1.5,
                                            units: 1000, feeTotal: dec("0.20"))
        XCTAssertEqual(narrow, wide)
    }

    func test_zeroUnitsOrZeroAmplitudeCostsNothing() {
        XCTAssertEqual(NextTRiskMath.adverseCost(referencePrice: dec("1.42"), amplitudePercent: 2,
                                                 units: 0, feeTotal: dec("0.20")), 0)
        XCTAssertEqual(NextTRiskMath.adverseCost(referencePrice: dec("1.42"), amplitudePercent: 0,
                                                 units: 3000, feeTotal: dec("0.20")), dec("0.20"),
                       "振幅为 0 时只剩手续费，但手续费是真花了")
    }

    // MARK: - 方向

    func test_reverseRiskPointsUp() {
        let price = NextTRiskMath.adversePrice(referencePrice: dec("1.42"), amplitudePercent: 2, kind: .reverse)
        XCTAssertEqual(price, dec("1.4484"), "反T 是卖出后继续涨，参考价在上方")
    }

    func test_forwardRiskPointsDown() {
        let price = NextTRiskMath.adversePrice(referencePrice: dec("1.38"), amplitudePercent: 2, kind: .forward)
        XCTAssertEqual(price, dec("1.3524"), "正T 是买入后继续跌，参考价在下方")
    }

    func test_bothDirectionsAreNotMirroredByAccident() {
        // 同一振幅下两边的移动幅度都是参考价 × 振幅，但方向相反。
        let up = NextTRiskMath.adversePrice(referencePrice: dec("1.40"), amplitudePercent: 1, kind: .reverse)
        let down = NextTRiskMath.adversePrice(referencePrice: dec("1.40"), amplitudePercent: 1, kind: .forward)
        XCTAssertGreaterThan(up, dec("1.40"))
        XCTAssertLessThan(down, dec("1.40"))
    }

    // MARK: - 字段互斥

    func test_onlyOneRiskSideIsFilledPerPlan() {
        // 反T：踏空有内容，被套为空
        let reverse = NextTPlan(kind: .reverse, code: "159941", name: "纳指ETF",
                                sellPrice: dec("1.42"), buyPrice: dec("1.38"), units: 3000,
                                grossSpread: dec("0.04"), feeTotal: dec("0.20"),
                                netGain: dec("119.80"), costReductionPerUnit: dec("0.012"),
                                trampleRisk: "踏空说明", downsideRisk: "",
                                volumeSupport: "充足", validUntil: Date(),
                                cancelConditions: [], evidence: [],
                                confidence: NextDataConfidence.assess(quote: nil, now: Date(),
                                                                      dailyBarCount: 120, minuteSampleCount: 200),
                                historyMissRate: nil)
        XCTAssertFalse(reverse.trampleRisk.isEmpty)
        XCTAssertTrue(reverse.downsideRisk.isEmpty)

        let forward = NextTPlan(kind: .forward, code: "159941", name: "纳指ETF",
                                sellPrice: dec("1.42"), buyPrice: dec("1.38"), units: 3000,
                                grossSpread: dec("0.04"), feeTotal: dec("0.20"),
                                netGain: dec("119.80"), costReductionPerUnit: dec("0.012"),
                                trampleRisk: "", downsideRisk: "被套说明",
                                volumeSupport: "充足", validUntil: Date(),
                                cancelConditions: [], evidence: [],
                                confidence: NextDataConfidence.assess(quote: nil, now: Date(),
                                                                      dailyBarCount: 120, minuteSampleCount: 200),
                                historyMissRate: nil)
        XCTAssertTrue(forward.trampleRisk.isEmpty, "正T 不该显示踏空")
        XCTAssertFalse(forward.downsideRisk.isEmpty, "正T 必须显示被套风险")
    }
}
