import Foundation

// MARK: - 149 分时样本时效与「不倒退」
//
// 这里要分清三件完全不同的事，混在一起就会得出错误结论：
//
//   1. **接收时间**（`NextChartDataset.observedAt`）：我什么时候从接口拿到这份数据；
//   2. **样本时间**（`samples` 里最后一根的时间戳）：数据描述的行情发生在什么时候；
//   3. **交易日**：样本属于哪一天。
//
// 上游在盘前、休市、接口降级时都可能返回「昨天收盘后的分时」。
// 如果只看接收时间，界面会显示「刚刚更新」，而实际策略和图表看到的都是昨天的价格。
// 更糟的是刷新流程会直接用新数据覆盖旧缓存：一次降级响应就能把当天的完整分时
// 换成昨天的残段，而且看不出任何异常。
//
// 所以：判定只看样本时间，覆盖必须单调前进。

enum NextSampleFreshness: Equatable {
    /// 今天、且仍在交易中。age 是最后一根样本距现在多少分钟。
    case live(ageMinutes: Int)
    /// 今天是交易日，但已收盘；样本就是今天的收盘序列。
    case closedToday
    /// 样本来自更早的交易日。盘中出现这一态就是异常，必须拦住。
    case previousSession(days: Int)
    /// 样本时间晚于现在：时钟或数据有问题，同样不可信。
    case future
    case empty

    /// 是否可以被盘中判断（做T、背离、盘中提醒）当作今日数据使用。
    var usableForIntraday: Bool {
        switch self {
        case .live, .closedToday: return true
        case .previousSession, .future, .empty: return false
        }
    }

    var label: String {
        switch self {
        case let .live(age):
            return age <= 5 ? "实时" : "延迟 \(age) 分钟"
        case .closedToday:
            return "今日已收盘"
        case let .previousSession(days):
            return days <= 1 ? "样本来自上一交易日" : "样本来自 \(days) 天前"
        case .future:
            return "样本时间晚于当前时间"
        case .empty:
            return "没有样本"
        }
    }

    /// 给用户看的一句实话。异常态必须说清「这不是今天的数据」。
    var note: String {
        switch self {
        case let .live(age):
            return age <= 5 ? "分时数据为实时更新" : "分时数据延迟约 \(age) 分钟"
        case .closedToday:
            return "分时数据为今日收盘序列，可用于今日复盘"
        case let .previousSession(days):
            return "数据接收时间很新，但样本来自 \(days <= 1 ? "上一交易日" : "\(days) 天前")，不能当作今天的分时"
        case .future:
            return "样本时间晚于当前时间，已停止使用这份数据"
        case .empty:
            return "这份分时没有可用样本"
        }
    }
}

enum NextSampleAudit {
    /// A股 交易日以北京时间为准。
    static var shanghai: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 样本所属交易日＝最后一根样本的自然日。
    /// 刻意用**最后一根**而不是第一根：跨日残段里第一根可能还是昨天的。
    static func sampleDay(of samples: [NextChartSample]) -> Date? {
        guard let last = samples.map(\.timestamp).max() else { return nil }
        return shanghai.startOfDay(for: last)
    }

    static func sampleDay(of dataset: NextChartDataset) -> Date? {
        sampleDay(of: dataset.samples)
    }

    /// 样本日与「今天」差几个自然日。
    static func dayGap(sampleDay: Date, now: Date) -> Int {
        let from = shanghai.startOfDay(for: sampleDay)
        let to = shanghai.startOfDay(for: now)
        return shanghai.dateComponents([.day], from: from, to: to).day ?? 0
    }

    /// 判定这份分时到底是不是「今天的」。
    /// - Parameter marketOpen: 现在 A股 是否处于开市或午休。由调用方用交易日历算好传进来，
    ///   这样这个判定器不依赖日历实现，也就更容易测。
    static func freshness(samples: [NextChartSample], now: Date, marketOpen: Bool) -> NextSampleFreshness {
        guard let last = samples.map(\.timestamp).max() else { return .empty }
        if last > now.addingTimeInterval(60) { return .future }
        guard let day = sampleDay(of: samples) else { return .empty }
        let gap = dayGap(sampleDay: day, now: now)
        if gap == 0 {
            if marketOpen {
                let age = max(0, Int(now.timeIntervalSince(last) / 60))
                return .live(ageMinutes: age)
            }
            return .closedToday
        }
        return .previousSession(days: max(1, gap))
    }

    /// 刷新时是否允许用新数据覆盖旧缓存。
    ///
    /// 单调规则：
    /// - 新样本日更早 → 拒绝（这是最危险的一种：降级响应把今天换回昨天）；
    /// - 新样本日更晚 → 接受；
    /// - 同一日：样本条数不减少才接受（盘中本来就在增长，条数变少说明被截断）。
    ///
    /// 不看 `observedAt`：接收时间新不代表数据新，这正是要修的那个洞。
    static func shouldReplace(existing: NextChartDataset, incoming: NextChartDataset) -> Bool {
        guard let oldDay = sampleDay(of: existing) else { return true }
        guard let newDay = sampleDay(of: incoming) else { return false }
        if newDay > oldDay { return true }
        if newDay < oldDay { return false }
        return incoming.samples.count >= existing.samples.count
    }
}
