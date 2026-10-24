import XCTest
@testable import GuanpanAdvisorCore

/// 126 开盘信息消化（9:30–10:00）。
///
/// 这组用例盯四件事：
/// 窗口没走完或样本不足就不给结论、隔夜噪音级波动不当问题、
/// 已计价比例与 123 同一口径、非当日的分钟样本必须被排除。
final class NextOpenAbsorptionTests: XCTestCase {

    private func shanghai(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute
        return calendar.date(from: comps)!
    }

    /// 2026-10-23（周五）10:05（上海）：窗口已走完，仍在开盘后一小时内。
    private var afterWindow: Date { shanghai(2026, 10, 23, 10, 5) }

    /// 某交易日 9:30 起的分钟线：第一根带开盘价 firstOpen，最后一根收盘价 lastClose，中间线性过渡。
    /// 引擎只读首尾，中间只为让序列像真的；只有第一根有 open（其余模拟分时 tick 无 open）。
    private func minuteBars(count: Int, firstOpen: Double, lastClose: Double,
                            day: Date = shanghai(2026, 10, 23, 0, 0)) -> [NextChartSample] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        let start = calendar.date(from: DateComponents(year: parts.year, month: parts.month,
                                                       day: parts.day, hour: 9, minute: 30))!
        return (0..<count).map { index in
            let fraction = count <= 1 ? 1.0 : Double(index) / Double(count - 1)
            let close = firstOpen + (lastClose - firstOpen) * fraction
            return NextChartSample(timestamp: start.addingTimeInterval(Double(index) * 60),
                                   open: index == 0 ? Decimal(firstOpen) : nil,
                                   high: Decimal(max(firstOpen, close)),
                                   low: Decimal(min(firstOpen, close)),
                                   close: Decimal(close),
                                   iopv: nil, volume: 100)
        }
    }

    /// 隔夜 -2%、低开 -2.3%、10:00 仍低开 -2.5% → 本地累计位移已盖过隔夜变化，基本已计价。
    func test_fullWindowComputesAbsorption() {
        let assessment = NextOpenAbsorptionEngine.assess(
            code: "513520", at: afterWindow, minutes: minuteBars(count: 30, firstOpen: 97.7, lastClose: 97.5),
            previousClose: 100, overnightChange: -2.0)
        guard let assessment else { return XCTFail("窗口完整时必须能算出开盘消化") }
        XCTAssertEqual(assessment.windowPoints, 30)
        XCTAssertEqual(assessment.openPrice, 97.7, accuracy: 0.001)
        XCTAssertEqual(assessment.windowClose, 97.5, accuracy: 0.001)
        XCTAssertEqual(assessment.absorbedRatio, 1.0, accuracy: 0.001)
        XCTAssertEqual(assessment.verdict, "开盘半小时隔夜信息基本已计价，不宜再按隔夜方向追单")
        XCTAssertTrue(assessment.note.contains("9:30–10:00"), "口径必须写明窗口")
        XCTAssertTrue(assessment.note.contains("30 个分钟样本"), "样本数必须可核对")
        XCTAssertTrue(assessment.note.contains("已计价 100%"), "结论数字必须出现在说明里")
    }

    /// 低开 -2.3% 后 10:00 已修复到 99.0：本地净位移只有 -0.97%，隔夜 -2% 远未消化完。
    func test_underAbsorbedKeepsTransmissionSpace() {
        let assessment = NextOpenAbsorptionEngine.assess(
            code: "513520", at: afterWindow, minutes: minuteBars(count: 30, firstOpen: 97.7, lastClose: 99.0),
            previousClose: 100, overnightChange: -2.0)
        guard let assessment else { return XCTFail("窗口完整时必须能算出开盘消化") }
        XCTAssertEqual(assessment.absorbedRatio, 0.485, accuracy: 0.001)
        XCTAssertEqual(assessment.verdict, "开盘半小时隔夜信息尚未充分反映，方向仍有传导空间")
    }

    /// 中间带：消化过半但未基本计价。话术必须和两端区分开。
    func test_middleBandSaysDigestedHalfway() {
        let assessment = NextOpenAbsorptionEngine.assess(
            code: "513520", at: afterWindow, minutes: minuteBars(count: 30, firstOpen: 98.5, lastClose: 98.6),
            previousClose: 100, overnightChange: -2.0)
        guard let assessment else { return XCTFail("窗口完整时必须能算出开盘消化") }
        XCTAssertEqual(assessment.absorbedRatio, 0.699, accuracy: 0.001)
        XCTAssertEqual(assessment.verdict, "开盘半小时隔夜信息已消化过半，继续追单的依据下降")
    }

    /// 方向相反时只认开盘缺口那一段（与 123 同一口径）：高开 +2.3% 盖过隔夜 +2% 后回落，
    /// 已计价比例 = |开盘缺口| / |隔夜|，回落部分不计入「消化隔夜信息」。
    func test_reversedDirectionCountsOnlyTheOpeningGap() {
        let assessment = NextOpenAbsorptionEngine.assess(
            code: "513520", at: afterWindow, minutes: minuteBars(count: 30, firstOpen: 102.3, lastClose: 99.5),
            previousClose: 100, overnightChange: 2.0)
        guard let assessment else { return XCTFail("窗口完整时必须能算出开盘消化") }
        XCTAssertEqual(assessment.absorbedRatio, 1.0, accuracy: 0.001)
        XCTAssertTrue(assessment.verdict.contains("基本已计价"))
    }

    /// 10:00 之前调用只会有半截窗口——编不出消化度，直接 nil。
    func test_windowInProgressGivesNoConclusion() {
        let at = shanghai(2026, 10, 23, 9, 45)
        let assessment = NextOpenAbsorptionEngine.assess(
            code: "513520", at: at, minutes: minuteBars(count: 30, firstOpen: 97.7, lastClose: 97.5),
            previousClose: 100, overnightChange: -2.0)
        XCTAssertNil(assessment, "窗口没走完，30 根也只是一半窗口的价格")
    }

    /// 窗口内分钟样本不足一半：视为没看全窗口，不给结论。
    func test_tooFewWindowSamplesGivesNoConclusion() {
        let assessment = NextOpenAbsorptionEngine.assess(
            code: "513520", at: afterWindow, minutes: minuteBars(count: 10, firstOpen: 97.7, lastClose: 97.5),
            previousClose: 100, overnightChange: -2.0)
        XCTAssertNil(assessment)
    }

    /// 非当日的分钟样本必须被排除：昨天 30 根 + 今天 5 根 → 今天的窗口只有 5 根，不给结论。
    func test_samplesFromOtherDaysAreExcluded() {
        let priorDay = minuteBars(count: 30, firstOpen: 90.0, lastClose: 90.0,
                                  day: shanghai(2026, 10, 22, 0, 0))
        let mixed = priorDay + minuteBars(count: 5, firstOpen: 97.7, lastClose: 97.5)
        XCTAssertNil(NextOpenAbsorptionEngine.assess(code: "513520", at: afterWindow, minutes: mixed,
                                                     previousClose: 100, overnightChange: -2.0),
                     "昨天完整的 30 根不能顶替今天没走完的窗口")
        // 正对照：今天也有完整 30 根时，用的必须是今天的数据（30 根，不是 60 根）。
        let full = priorDay + minuteBars(count: 30, firstOpen: 97.7, lastClose: 97.5)
        let assessment = NextOpenAbsorptionEngine.assess(code: "513520", at: afterWindow, minutes: full,
                                                         previousClose: 100, overnightChange: -2.0)
        XCTAssertEqual(assessment?.windowPoints, 30, "非当日样本必须被剔除，只数今天的 30 根")
        XCTAssertEqual(assessment?.openPrice ?? 0, 97.7, accuracy: 0.001)
    }

    /// 没有昨收就不编开盘缺口。
    func test_missingPreviousCloseGivesNoConclusion() {
        XCTAssertNil(NextOpenAbsorptionEngine.assess(
            code: "513520", at: afterWindow, minutes: minuteBars(count: 30, firstOpen: 97.7, lastClose: 97.5),
            previousClose: nil, overnightChange: -2.0))
        XCTAssertNil(NextOpenAbsorptionEngine.assess(
            code: "513520", at: afterWindow, minutes: minuteBars(count: 30, firstOpen: 97.7, lastClose: 97.5),
            previousClose: 0, overnightChange: -2.0))
    }

    /// 隔夜变动不到门槛（噪音级）就不存在「消化」问题。
    func test_tinyOvernightMoveIsNotAnAbsorptionQuestion() {
        XCTAssertNil(NextOpenAbsorptionEngine.assess(
            code: "513520", at: afterWindow, minutes: minuteBars(count: 30, firstOpen: 100.2, lastClose: 100.2),
            previousClose: 100, overnightChange: -0.3))
    }

    /// 分时 tick 没有 open：今开用第一根收盘价顶上，口径在 note 里看得见。
    func test_tickDataWithoutOpenUsesFirstClose() {
        let bars = minuteBars(count: 30, firstOpen: 97.7, lastClose: 97.5).map { sample -> NextChartSample in
            NextChartSample(timestamp: sample.timestamp, open: nil, high: sample.high, low: sample.low,
                            close: sample.close, iopv: nil, volume: sample.volume)
        }
        let assessment = NextOpenAbsorptionEngine.assess(
            code: "513520", at: afterWindow, minutes: bars,
            previousClose: 100, overnightChange: -2.0)
        XCTAssertEqual(assessment?.openPrice ?? 0, 97.7, accuracy: 0.001, "没有 open 时用第一根收盘价")
        XCTAssertEqual(assessment?.absorbedRatio ?? 0, 1.0, accuracy: 0.001)
    }

    /// 引擎与信号策略分层：引擎只看「时钟过没过 10:00、窗口数据在不在」，
    /// 午后调用照样能算（供复盘用）；「要不要当信号」是闭环那层的决定。
    func test_afternoonCallStillComputesWindow() {
        let at = shanghai(2026, 10, 23, 14, 5)
        let assessment = NextOpenAbsorptionEngine.assess(
            code: "513520", at: at, minutes: minuteBars(count: 30, firstOpen: 97.7, lastClose: 97.5),
            previousClose: 100, overnightChange: -2.0)
        XCTAssertEqual(assessment?.absorbedRatio ?? 0, 1.0, accuracy: 0.001)
    }
}
