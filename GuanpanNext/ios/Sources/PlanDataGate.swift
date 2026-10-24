import Foundation

// MARK: - 动态网格 / 做T 的严格数据门槛
//
// 「动态」两个字的代价是：所有参数都是从历史估计出来的。
// 间距来自振幅、档数来自区间、份额来自资金，任何一项估计不稳，
// 生成出来的挂单价看起来精确，实际是把噪声当成了结论。
//
// 具体有两个老毛病：
//   1. 振幅只用近 20 日算过就敢用，而近 20 日可能是全年最平静的一段，
//      于是间距被压得很窄，手续费吃掉全部利润。
//   2. 振幅估计在「近 20 日」和「近 60 日」之间差一倍时，
//      说明这段行情本身在切换，此时缩间距等于在切换点上加速下单。
//
// 所以门槛分三档而不是两档：
//   - `sufficient`：可以用动态参数
//   - `caution`：能出价，但**参数必须向保守一侧收敛**（不缩间距、不加档），并写明原因
//   - `insufficient`：不出价
// 中间这档是关键：直接拒绝会浪费可用的机会，直接放行会把噪声当信号。

enum NextPlanKind: String, Equatable {
    case doT
    case grid

    var label: String {
        switch self {
        case .doT: return "做T"
        case .grid: return "网格"
        }
    }
}

struct NextPlanDataProfile: Equatable {
    var dailyBars: Int = 0
    /// NAS 归档天数（长期分时）。做T 要 60 天，网格用区间也要 60 天。
    var nasDays: Int?
    var nasVolumeCoverage: Double?
    /// 今日分时点数与理论点数（A股 240 分钟）。
    var minuteSamples: Int = 0
    var expectedMinuteSamples: Int = 240
    /// 振幅估计覆盖的交易日数，以及近段/长段两个振幅（百分点）。
    var amplitudeSessions: Int?
    var amplitudeRecent: Double?
    var amplitudeLong: Double?
    var quoteAgeSeconds: Int?
    var orderBookAgeSeconds: Int?
    var spreadPercent: Double?
    var bidDepthLots: Double?
    var askDepthLots: Double?
    var rulesVerified: Bool = false

    var minuteCoverage: Double {
        guard expectedMinuteSamples > 0 else { return 0 }
        return min(1, Double(minuteSamples) / Double(expectedMinuteSamples))
    }
}

enum NextPlanDataState: Equatable {
    case sufficient
    case caution([String])
    case insufficient([String])

    var allowsPricing: Bool {
        if case .insufficient = self { return false }
        return true
    }

    var reasons: [String] {
        switch self {
        case .sufficient: return []
        case let .caution(items): return items
        case let .insufficient(items): return items
        }
    }
}

enum NextPlanDataGate {
    static let doTMinimumNasDays = 60
    static let doTMinimumVolumeCoverage = 0.8
    static let doTMinimumMinuteSamples = 30
    /// 做T 要求今日分时覆盖到 60%。低于这个比例时仍然允许出价，
    /// 但必须提示「日内统计代表性有限」——因为缺口可能正好落在波动最大的时段。
    static let doTPreferredMinuteCoverage = 0.60
    static let gridMinimumDailyBars = 60
    /// 振幅至少要有 20 个交易日的估计，否则「半倍日均振幅」是猜的。
    static let gridPreferredAmplitudeSessions = 20
    static let maximumOrderBookAgeSeconds = 30
    static let maximumQuoteAgeSeconds = 120
    static let maximumSpreadPercent = 0.30
    static let minimumDepthLots = 10.0
    /// 近段振幅 ÷ 长段振幅 的合理区间。越界说明波动结构在切换。
    static let amplitudeStabilityLower = 0.5
    static let amplitudeStabilityUpper = 2.0

    static func assess(kind: NextPlanKind, profile: NextPlanDataProfile) -> NextPlanDataState {
        var hard: [String] = []
        var soft: [String] = []

        if !profile.rulesVerified {
            hard.append("交易规则未核实（份额单位/手续费），不出价")
        }
        if let age = profile.orderBookAgeSeconds, age > maximumOrderBookAgeSeconds {
            hard.append("五档盘口已 \(age) 秒未更新，超过 \(maximumOrderBookAgeSeconds) 秒")
        } else if profile.orderBookAgeSeconds == nil {
            hard.append("缺少五档盘口时间戳")
        }
        if let spread = profile.spreadPercent {
            if spread > maximumSpreadPercent {
                hard.append(String(format: "盘口价差 %.3f%% 超过 %.2f%%", spread, maximumSpreadPercent))
            }
        } else {
            hard.append("缺少盘口价差")
        }
        if let bid = profile.bidDepthLots, bid < minimumDepthLots {
            hard.append("买盘深度 \(Int(bid)) 手不足 \(Int(minimumDepthLots)) 手")
        } else if profile.bidDepthLots == nil {
            hard.append("缺少买盘深度")
        }
        if let ask = profile.askDepthLots, ask < minimumDepthLots {
            hard.append("卖盘深度 \(Int(ask)) 手不足 \(Int(minimumDepthLots)) 手")
        } else if profile.askDepthLots == nil {
            hard.append("缺少卖盘深度")
        }

        switch kind {
        case .doT:
            if let days = profile.nasDays {
                if days < doTMinimumNasDays {
                    hard.append("NAS 长期分时只有 \(days) 天，做T 需要 \(doTMinimumNasDays) 天")
                }
            } else {
                hard.append("NAS 长期分时未接入，无法评估做T 的历史证据")
            }
            if let coverage = profile.nasVolumeCoverage {
                if coverage < doTMinimumVolumeCoverage {
                    hard.append(String(format: "NAS 成交量覆盖 %.0f%% 低于 %.0f%%", coverage * 100, doTMinimumVolumeCoverage * 100))
                }
            } else {
                hard.append("缺少 NAS 成交量覆盖率")
            }
            if profile.minuteSamples < doTMinimumMinuteSamples {
                hard.append("今日分时只有 \(profile.minuteSamples) 点，不足 \(doTMinimumMinuteSamples) 点")
            } else if profile.minuteCoverage < doTPreferredMinuteCoverage {
                soft.append(String(format: "今日分时只覆盖 %.0f%%，日内统计代表性有限（缺口可能落在波动最大的时段）", profile.minuteCoverage * 100))
            }
        case .grid:
            if profile.dailyBars < gridMinimumDailyBars {
                hard.append("日 K 只有 \(profile.dailyBars) 根，网格需要 \(gridMinimumDailyBars) 根")
            }
            if let days = profile.nasDays {
                if days < gridMinimumDailyBars {
                    hard.append("NAS 长期区间只有 \(days) 天，网格需要 \(gridMinimumDailyBars) 天")
                }
            } else {
                hard.append("缺少 NAS 长期区间，不以本机日K替代")
            }
            if let sessions = profile.amplitudeSessions {
                if sessions < gridPreferredAmplitudeSessions {
                    soft.append("振幅只用 \(sessions) 个交易日估计，不足 \(gridPreferredAmplitudeSessions) 天：间距按更保守的一侧取")
                }
            } else {
                soft.append("缺少振幅估计的天数，无法判断间距是否稳定：间距按更保守的一侧取")
            }
        }

        if let age = profile.quoteAgeSeconds {
            if age > maximumQuoteAgeSeconds {
                hard.append("行情已 \(age) 秒未更新，超过 \(maximumQuoteAgeSeconds) 秒")
            }
        } else {
            hard.append("缺少行情时间戳")
        }

        if amplitudeIsUnstable(recent: profile.amplitudeRecent, long: profile.amplitudeLong) {
            soft.append("近段振幅 \(fmt(profile.amplitudeRecent))% 与长段 \(fmt(profile.amplitudeLong))% 相差超过一倍，波动结构在切换：不缩间距、不加档")
        }

        if !hard.isEmpty { return .insufficient(hard) }
        return soft.isEmpty ? .sufficient : .caution(soft)
    }

    /// 近段与长段振幅是否背离。只有一个值时不判「不稳」——
    /// 缺数据要报缺数据，不能顺手当成不稳。
    static func amplitudeIsUnstable(recent: Double?, long: Double?) -> Bool {
        guard let recent, let long, recent > 0, long > 0 else { return false }
        let ratio = recent / long
        return ratio < amplitudeStabilityLower || ratio > amplitudeStabilityUpper
    }

    /// 间距护栏。不稳定时不缩间距：取 base 与「长段振幅的一半」的较大者，
    /// 并保证不低于 0.4%（否则手续费吃掉全部利润）。
    static func spacing(base: Double, longAmplitude: Double?, unstable: Bool) -> Double {
        guard unstable else { return max(0.4, base) }
        let conservative = max(0.4, (longAmplitude ?? base * 2) / 2)
        return max(max(0.4, base), conservative)
    }

    static func fmt(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.2f", value)
    }
}
