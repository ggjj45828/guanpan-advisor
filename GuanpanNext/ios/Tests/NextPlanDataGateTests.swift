import XCTest
@testable import GuanpanAdvisorCore

/// 数据门槛的测试重点：三档判定必须能分开，
/// 尤其是 **caution 那一档**——既不能直接拒绝可用机会，也不能让不稳定的参数照常缩小间距。
final class NextPlanDataGateTests: XCTestCase {

    private func goodProfile() -> NextPlanDataProfile {
        NextPlanDataProfile(dailyBars: 120, nasDays: 90, nasVolumeCoverage: 0.95,
                            minuteSamples: 200, expectedMinuteSamples: 240,
                            amplitudeSessions: 60, amplitudeRecent: 1.20, amplitudeLong: 1.10,
                            quoteAgeSeconds: 5, orderBookAgeSeconds: 8,
                            spreadPercent: 0.08, bidDepthLots: 40, askDepthLots: 35,
                            rulesVerified: true)
    }

    // MARK: 做T

    func testDoTIsSufficientWithCompleteData() {
        XCTAssertEqual(NextPlanDataGate.assess(kind: .doT, profile: goodProfile()), .sufficient)
    }

    func testDoTRefusesWhenNasHistoryIsShort() {
        var profile = goodProfile()
        profile.nasDays = 30
        let state = NextPlanDataGate.assess(kind: .doT, profile: profile)
        XCTAssertFalse(state.allowsPricing)
        XCTAssertTrue(state.reasons.contains { $0.contains("做T 需要 60 天") })
    }

    func testDoTRefusesWithoutNasArchive() {
        var profile = goodProfile()
        profile.nasDays = nil
        let state = NextPlanDataGate.assess(kind: .doT, profile: profile)
        XCTAssertFalse(state.allowsPricing)
        XCTAssertTrue(state.reasons.contains { $0.contains("NAS 长期分时未接入") })
    }

    func testDoTRefusesWhenIntradaySamplesTooFew() {
        var profile = goodProfile()
        profile.minuteSamples = 10
        let state = NextPlanDataGate.assess(kind: .doT, profile: profile)
        XCTAssertFalse(state.allowsPricing)
        XCTAssertTrue(state.reasons.contains { $0.contains("今日分时只有 10 点") })
    }

    /// 分时点够 30 个但只覆盖三成 → 可以出价，但必须自曝代表性有限。
    func testDoTWarnsWhenIntradayCoverageIsThin() {
        var profile = goodProfile()
        profile.minuteSamples = 72
        let state = NextPlanDataGate.assess(kind: .doT, profile: profile)
        guard case let .caution(reasons) = state else {
            return XCTFail("覆盖不足但样本够，应判 caution")
        }
        XCTAssertTrue(state.allowsPricing)
        XCTAssertTrue(reasons.contains { $0.contains("只覆盖") })
    }

    func testDoTRefusesWhenVolumeCoverageIsLow() {
        var profile = goodProfile()
        profile.nasVolumeCoverage = 0.5
        XCTAssertFalse(NextPlanDataGate.assess(kind: .doT, profile: profile).allowsPricing)
    }

    // MARK: 网格

    func testGridIsSufficientWithCompleteData() {
        XCTAssertEqual(NextPlanDataGate.assess(kind: .grid, profile: goodProfile()), .sufficient)
    }

    func testGridRefusesWithTooFewDailyBars() {
        var profile = goodProfile()
        profile.dailyBars = 40
        let state = NextPlanDataGate.assess(kind: .grid, profile: profile)
        XCTAssertFalse(state.allowsPricing)
        XCTAssertTrue(state.reasons.contains { $0.contains("日 K 只有 40 根") })
    }

    func testGridRefusesWithoutNasRange() {
        var profile = goodProfile()
        profile.nasDays = nil
        XCTAssertFalse(NextPlanDataGate.assess(kind: .grid, profile: profile).allowsPricing)
    }

    /// 振幅只估了 10 天：允许出价，但间距必须向保守一侧取。
    func testGridCautionsWhenAmplitudeHistoryIsShort() {
        var profile = goodProfile()
        profile.amplitudeSessions = 10
        let state = NextPlanDataGate.assess(kind: .grid, profile: profile)
        guard case let .caution(reasons) = state else {
            return XCTFail("振幅历史不足应判 caution 而不是直接拒绝")
        }
        XCTAssertTrue(reasons.contains { $0.contains("保守") })
    }

    func testGridCautionsWhenVolatilityRegimeShifts() {
        var profile = goodProfile()
        profile.amplitudeRecent = 3.0
        profile.amplitudeLong = 1.0
        let state = NextPlanDataGate.assess(kind: .grid, profile: profile)
        guard case let .caution(reasons) = state else {
            return XCTFail("振幅背离应判 caution")
        }
        XCTAssertTrue(reasons.contains { $0.contains("不缩间距") })
    }

    // MARK: 共同硬约束

    func testUnverifiedRulesBlockBothKinds() {
        var profile = goodProfile()
        profile.rulesVerified = false
        XCTAssertFalse(NextPlanDataGate.assess(kind: .doT, profile: profile).allowsPricing)
        XCTAssertFalse(NextPlanDataGate.assess(kind: .grid, profile: profile).allowsPricing)
    }

    func testWideSpreadBlocksBothKinds() {
        var profile = goodProfile()
        profile.spreadPercent = 0.45
        XCTAssertFalse(NextPlanDataGate.assess(kind: .doT, profile: profile).allowsPricing)
        XCTAssertFalse(NextPlanDataGate.assess(kind: .grid, profile: profile).allowsPricing)
    }

    func testStaleOrderBookBlocksBothKinds() {
        var profile = goodProfile()
        profile.orderBookAgeSeconds = 120
        XCTAssertFalse(NextPlanDataGate.assess(kind: .doT, profile: profile).allowsPricing)
    }

    func testMissingOrderBookTimestampsAreTreatedAsMissing() {
        var profile = goodProfile()
        profile.orderBookAgeSeconds = nil
        let state = NextPlanDataGate.assess(kind: .grid, profile: profile)
        XCTAssertTrue(state.reasons.contains { $0.contains("缺少五档盘口时间戳") })
    }

    // MARK: 振幅稳定性与间距护栏

    func testAmplitudeStabilityBoundaries() {
        XCTAssertFalse(NextPlanDataGate.amplitudeIsUnstable(recent: 1.0, long: 1.0))
        XCTAssertFalse(NextPlanDataGate.amplitudeIsUnstable(recent: 0.5, long: 1.0))
        XCTAssertTrue(NextPlanDataGate.amplitudeIsUnstable(recent: 0.49, long: 1.0))
        XCTAssertFalse(NextPlanDataGate.amplitudeIsUnstable(recent: 2.0, long: 1.0))
        XCTAssertTrue(NextPlanDataGate.amplitudeIsUnstable(recent: 2.01, long: 1.0))
        // 只有一个值时不判不稳：缺数据要报缺数据，不能顺手当成不稳。
        XCTAssertFalse(NextPlanDataGate.amplitudeIsUnstable(recent: nil, long: 1.0))
        XCTAssertFalse(NextPlanDataGate.amplitudeIsUnstable(recent: 1.0, long: nil))
    }

    func testSpacingKeepsBaseWhenStable() {
        XCTAssertEqual(NextPlanDataGate.spacing(base: 0.9, longAmplitude: 1.2, unstable: false), 0.9, accuracy: 0.0001)
    }

    func testSpacingNeverShrinksBelowLongRunHalfAmplitudeWhenUnstable() {
        // 近段振幅只有 0.3%，缩间距会把间距压到 0.15%——手续费直接吃掉利润。
        // 不稳定时按长段一半（1.0%）取，并保证不低于 0.4%。
        XCTAssertEqual(NextPlanDataGate.spacing(base: 0.15, longAmplitude: 2.0, unstable: true), 1.0, accuracy: 0.0001)
        XCTAssertEqual(NextPlanDataGate.spacing(base: 0.15, longAmplitude: 0.4, unstable: true), 0.4, accuracy: 0.0001)
    }
}
