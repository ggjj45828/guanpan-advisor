import Foundation

// MARK: - 126 开盘信息消化（9:30–10:00）
//
// 回答一个问题：隔夜信息在开盘首半小时里被消化了多少。
// 这是 123「隔夜信息消化」的开盘窗口版本——123 用任意时点的现价，
// 126 把窗口锁死在 9:30–10:00，而且**只用当日真实分钟线**。
//
// 三条诚实性要求：
// 1. 窗口没走完（10:00 前）或窗口内分钟样本不足，一律不给结论——
//    不拿半截窗口编消化度，也不拿日线近似；
// 2. 隔夜变动本身不到门槛（噪音级）就不存在「消化」问题，直接 nil；
// 3. 已计价比例与 123 同一口径（`NextAbsorptionEngine.absorbedRatio`），
//    两个窗口的数字之间不允许各算各的。

/// 开盘半小时内隔夜信息的消化观察。
struct NextOpenAbsorption: Equatable {
    let code: String
    /// 观察时点（闭环判断时间，不是窗口内时间）。
    let at: Date
    /// 今开：窗口第一根分钟线的开盘价；分时 tick 没有 open 时用第一根收盘价。
    let openPrice: Double
    /// 窗口最后价格：10:00 前最后一根分钟线的收盘价。
    let windowClose: Double
    /// 实际参与计算的分钟样本数。
    let windowPoints: Int
    /// 昨收 → 今开（百分点）。
    let openGap: Double
    /// 今开 → 10:00 窗口最后价（百分点）。
    let sinceOpen: Double
    /// 隔夜变化（百分点）：海外市场相对其昨收、截至 A股 10:00 的值。
    let overnightChange: Double

    /// 已被计价比例（0…1），与 123 同一口径。
    var absorbedRatio: Double {
        NextAbsorptionEngine.absorbedRatio(overnightChange: overnightChange,
                                           openGap: openGap, sinceOpen: sinceOpen)
    }

    var verdict: String {
        if absorbedRatio >= 0.8 { return "开盘半小时隔夜信息基本已计价，不宜再按隔夜方向追单" }
        if absorbedRatio >= 0.5 { return "开盘半小时隔夜信息已消化过半，继续追单的依据下降" }
        return "开盘半小时隔夜信息尚未充分反映，方向仍有传导空间"
    }

    /// 一段可核对的说明：口径、样本数、四个数字、结论。
    var note: String {
        String(format: "开盘半小时（9:30–10:00，%d 个分钟样本）：今开 %.3f（较昨收 %+.2f%%），10:00 报 %.3f（较今开 %+.2f%%）；隔夜 %+.2f%% 已计价 %.0f%%",
               windowPoints, openPrice, openGap, windowClose, sinceOpen,
               overnightChange, absorbedRatio * 100)
    }
}

enum NextOpenAbsorptionEngine {
    /// 窗口起点：A股 9:30。
    static let windowStartMinute = 9 * 60 + 30
    /// 窗口终点（不含）：A股 10:00。
    static let windowEndMinute = 10 * 60
    /// 窗口内至少多少根分钟线才给结论。半小时理论 30 根；缺一半以上视为没看全窗口。
    static let minimumWindowPoints = 15
    /// 隔夜变动低于这个幅度就不存在「消化」问题（噪音级波动不追）。
    static let minimumOvernightPercent = 0.50

    /// 用当日真实分钟线计算开盘半小时的隔夜消化。
    ///
    /// 任何前提不满足都返回 nil——**没有「估算」路径**：
    /// - 窗口还没走完（调用时点早于 10:00）；
    /// - 昨收无效，或隔夜变动不足 `minimumOvernightPercent`；
    /// - 当日窗口内分钟样本不足 `minimumWindowPoints`；
    /// - 窗口第一根/最后一根价格无效。
    static func assess(code: String, at: Date, minutes: [NextChartSample],
                       previousClose: Double?, overnightChange: Double?,
                       calendar: NextMarketCalendar = NextMarketCalendar()) -> NextOpenAbsorption? {
        // 窗口必须已走完：10:00 之前调用只会有半截窗口，编不出消化度。
        guard calendar.minuteOfDay(at, .china) >= windowEndMinute else { return nil }
        guard let previousClose, previousClose > 0,
              let overnightChange, abs(overnightChange) >= minimumOvernightPercent else { return nil }
        let dayKey = NextCrossMarketFeed.dayKey(at, market: .china)
        let window = minutes.filter { sample in
            guard NextCrossMarketFeed.dayKey(sample.timestamp, market: .china) == dayKey else { return false }
            let minute = calendar.minuteOfDay(sample.timestamp, .china)
            return minute >= windowStartMinute && minute < windowEndMinute
        }.sorted { $0.timestamp < $1.timestamp }
        guard window.count >= minimumWindowPoints,
              let first = window.first, let last = window.last else { return nil }
        let openPrice = NextNum.double(first.open ?? first.close)
        let closePrice = NextNum.double(last.close)
        guard openPrice > 0, closePrice > 0,
              let openGap = NextCrossMarketAlignment.changePercent(from: previousClose, to: openPrice),
              let sinceOpen = NextCrossMarketAlignment.changePercent(from: openPrice, to: closePrice) else { return nil }
        return NextOpenAbsorption(code: code, at: at, openPrice: openPrice, windowClose: closePrice,
                                  windowPoints: window.count, openGap: openGap, sinceOpen: sinceOpen,
                                  overnightChange: overnightChange)
    }
}

extension NextCrossMarket {
    /// A股 当天某个「分钟时刻」的绝对时间（126 的开盘消化窗口边界用）。
    /// 与 `NextMarketClock.sessionClose` 一样用「取年月日再设时分秒」的写法：
    /// `date(bySettingHour:)` 在已过目标时刻时会按 `.next` 顺延，会把窗口滚到次日。
    static func chinaMinute(_ date: Date, _ minute: Int) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = china.timeZone
        var comps = calendar.dateComponents([.year, .month, .day], from: date)
        comps.hour = minute / 60
        comps.minute = minute % 60
        comps.second = 0
        return calendar.date(from: comps)
    }
}
