import Foundation
import SwiftUI

// MARK: - 五套视觉主题

/// 五套主题只改变「怎么展示」，不改变任何数据与业务判断：
/// 同一份持仓、同一份 AI 结论、同一份行情，换主题只是换排版与配色。
enum AppTheme: String, CaseIterable, Identifiable, Codable, Equatable {
    case editorial = "editorial"     // 东方编辑室
    case modern = "modern"           // 现代卡片
    case dashboard = "dashboard"     // 交易仪表盘
    case magazine = "magazine"       // 杂志卡片
    case puzzle = "puzzle"           // 创意拼图

    var id: String { rawValue }

    var title: String {
        switch self {
        case .editorial: return "东方编辑室"
        case .modern: return "现代卡片"
        case .dashboard: return "交易仪表盘"
        case .magazine: return "杂志卡片"
        case .puzzle: return "创意拼图"
        }
    }

    var tagline: String {
        switch self {
        case .editorial: return "暖纸底 + 金色 AI 卡，像一份私人晨报"
        case .modern: return "白卡 + 蓝色主色，信息密度最高"
        case .dashboard: return "深色盘面 + 仪表盘数字，盯盘最省眼"
        case .magazine: return "衬线大标题 + 留白，适合慢慢读"
        case .puzzle: return "彩色拼图块，一眼分清每类信息"
        }
    }

    /// 深色盘面主题：无论系统设置如何都走深色，否则数字读不清。
    var forcesDark: Bool { self == .dashboard }

    /// 首页骨架样式（与主题一一对应，但独立成类型，方便后续单独调整某一套）。
    var layout: LayoutStyle { LayoutStyle(rawValue: rawValue) ?? .modern }

    /// 设置页主题选择的小色块预览。
    var previewHexes: [UInt32] {
        switch self {
        case .editorial: return [0xFBF4E4, 0xF3CE8A, 0x7C5CE0]
        case .modern: return [0xF2F5FA, 0x2F6BFF, 0xFFFFFF]
        case .dashboard: return [0x0B1220, 0x7C3AED, 0x19C08A]
        case .magazine: return [0xFBF4F1, 0xE7B7C4, 0x1F2A37]
        case .puzzle: return [0xF7F3FB, 0xF6C64B, 0x4DB8F5]
        }
    }
}

/// 首页布局风格。刻意与 `AppTheme` 分开：以后允许「主题配色 A + 布局 B」的组合，
/// 也允许某个主题只换排版不改配色。
enum LayoutStyle: String, CaseIterable, Identifiable, Codable, Equatable {
    case editorial, modern, dashboard, magazine, puzzle
    var id: String { rawValue }
}

/// 场景：主题可以「跟随场景」自动切换——首页用编辑室、盘中用仪表盘……
enum ThemeScene: String, CaseIterable, Identifiable, Equatable {
    case home
    case market
    case aiReport
    case holdings
    case detail

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "首页"
        case .market: return "盘中行情"
        case .aiReport: return "AI 日报 / 指导"
        case .holdings: return "持仓快览"
        case .detail: return "详情与设置"
        }
    }

    /// 用户拍的「场景 → 主题」映射，与参考图一致：
    /// 普通首页→东方编辑室；盘中→交易仪表盘；AI 日报→杂志卡片；持仓快览→创意拼图；复杂详情/设置→现代卡片。
    var recommendedTheme: AppTheme {
        switch self {
        case .home: return .editorial
        case .market: return .dashboard
        case .aiReport: return .magazine
        case .holdings: return .puzzle
        case .detail: return .modern
        }
    }
}

/// 用户的主题选择：跟随场景，或固定一套。手动选择永远优先于场景推断。
enum ThemeSelection: Codable, Equatable {
    case auto
    case fixed(AppTheme)

    var isAuto: Bool { self == .auto }
    var fixedTheme: AppTheme? {
        if case let .fixed(theme) = self { return theme }
        return nil
    }
    var title: String {
        switch self {
        case .auto: return "跟随场景"
        case .fixed(let theme): return theme.title
        }
    }
}

/// 统一主题解析入口。这里只做「选择 → 主题」的纯函数计算，
/// 不持有状态（状态在 `LocalPreferences.themeSelection`），避免出现第二个真相源。
enum ThemeManager {
    static func resolve(selection: ThemeSelection, scene: ThemeScene) -> AppTheme {
        selection.fixedTheme ?? scene.recommendedTheme
    }

    static func selection(from preferences: LocalPreferences) -> ThemeSelection {
        if let fixed = preferences.themeStyle { return .fixed(fixed) }
        return .auto
    }

    /// 跟随场景时更新场景；固定主题时也把场景记下来，用户切回「跟随场景」立刻生效。
    static func selection(fixed theme: AppTheme?) -> ThemeSelection {
        guard let theme else { return .auto }
        return .fixed(theme)
    }
}

// MARK: - 设计令牌

/// 一套主题的全部设计令牌。`GPPalette` 从这里取值，
/// 因此任何页面只要用了 `p.ink` / `p.paper`，就会自动跟随主题。
struct DesignTokens {
    let canvas: Color
    let canvasEdge: Color
    let paper: Color
    let paperAlt: Color
    let raised: Color
    let ink: Color
    let muted: Color
    let line: Color
    let primary: Color
    let primaryDeep: Color
    let secondary: Color
    let jade: Color
    let risk: Color
    let tint: Color
    let heroSurface: Color
    let chartBlue: Color
    let chartViolet: Color
    let chartGold: Color
    let chartCost: Color
    let up: Color
    let down: Color
    /// AI 卡渐变（两色）。
    let heroStart: Color
    let heroEnd: Color
    /// AI 卡上的文字颜色（深色渐变卡上用白字）。
    let heroInk: Color
    let heroMutedInk: Color
    let cardRadius: CGFloat
    let heroRadius: CGFloat
    let chipRadius: CGFloat
    let shadowOpacity: Double
    let shadowRadius: CGFloat
    let showsBorder: Bool

    static func resolve(theme: AppTheme, scheme: ColorScheme, comfort: Bool, appearance: GPAppearance) -> DesignTokens {
        // 用户自定义颜色优先级最高：预览/夜间都被覆盖，尊重「我要这个底色」。
        let base = theme.tokens(dark: theme.forcesDark || scheme == .dark)
        let canvas = appearance.canvasHex.map { Color(hex: $0) } ?? (comfort ? Color(hex: 0xF3F1E6) : base.canvas)
        let paper = appearance.paperHex.map { Color(hex: $0) } ?? (comfort ? Color(hex: 0xFBFAF2) : base.paper)
        let ink = appearance.inkHex.map { Color(hex: $0) } ?? (comfort ? Color(hex: 0x2A2F24) : base.ink)
        return DesignTokens(canvas: canvas, canvasEdge: base.canvasEdge, paper: paper, paperAlt: base.paperAlt,
                            raised: base.raised, ink: ink, muted: base.muted, line: base.line,
                            primary: base.primary, primaryDeep: base.primaryDeep, secondary: base.secondary,
                            jade: base.jade, risk: base.risk, tint: base.tint, heroSurface: base.heroSurface,
                            chartBlue: base.chartBlue, chartViolet: base.chartViolet, chartGold: base.chartGold,
                            chartCost: base.chartCost, up: base.up, down: base.down,
                            heroStart: base.heroStart, heroEnd: base.heroEnd,
                            heroInk: base.heroInk, heroMutedInk: base.heroMutedInk,
                            cardRadius: base.cardRadius, heroRadius: base.heroRadius, chipRadius: base.chipRadius,
                            shadowOpacity: base.shadowOpacity, shadowRadius: base.shadowRadius, showsBorder: base.showsBorder)
    }
}

private extension AppTheme {
    /// 每套主题的具体色值。数值来自「五套观盘 App 视觉设计参考图」的取色方向：
    /// 编辑室暖米 + 金，现代冷白 + 蓝，仪表盘深海军 + 紫，杂志米粉 + 墨，拼图淡紫 + 多彩。
    func tokens(dark: Bool) -> DesignTokens {
        switch self {
        case .editorial:
            return DesignTokens(
                canvas: dark ? Color(hex: 0x1B1710) : Color(hex: 0xFBF4E4),
                canvasEdge: dark ? Color(hex: 0x241E14) : Color(hex: 0xF6EAD2),
                paper: dark ? Color(hex: 0x241E15) : Color(hex: 0xFFFDF7),
                paperAlt: dark ? Color(hex: 0x2C2419) : Color(hex: 0xFDF3DF),
                raised: dark ? Color(hex: 0x31281B) : Color(hex: 0xF3E6CE),
                ink: dark ? Color(hex: 0xF6EEDD) : Color(hex: 0x332A1E),
                muted: dark ? Color(hex: 0xC3B49A) : Color(hex: 0x8C7C63),
                line: dark ? Color(hex: 0x41331F) : Color(hex: 0xEEDFC3),
                primary: dark ? Color(hex: 0xE9B45C) : Color(hex: 0xB8802A),
                primaryDeep: dark ? Color(hex: 0xC28F35) : Color(hex: 0x96661B),
                secondary: dark ? Color(hex: 0xB69BF0) : Color(hex: 0x7C5CE0),
                jade: dark ? Color(hex: 0x5FC79B) : Color(hex: 0x1E9E6A),
                risk: dark ? Color(hex: 0xF08A7E) : Color(hex: 0xD9503F),
                tint: dark ? Color(hex: 0x3A2F1E) : Color(hex: 0xF7EAD1),
                heroSurface: dark ? Color(hex: 0x362A19) : Color(hex: 0xFBEBCB),
                chartBlue: dark ? Color(hex: 0x8FB6F0) : Color(hex: 0x3E7BD6),
                chartViolet: dark ? Color(hex: 0xB69BF0) : Color(hex: 0x7C5CE0),
                chartGold: dark ? Color(hex: 0xE9B45C) : Color(hex: 0xC08A2E),
                chartCost: dark ? Color(hex: 0xD9A0A8) : Color(hex: 0xA85F6C),
                up: dark ? Color(hex: 0xFF7A6B) : Color(hex: 0xD93B2B),
                down: dark ? Color(hex: 0x4FBF8B) : Color(hex: 0x1E9E5A),
                heroStart: dark ? Color(hex: 0x4A3413) : Color(hex: 0xF7CE8A),
                heroEnd: dark ? Color(hex: 0x6B4A1C) : Color(hex: 0xFBEBCC),
                heroInk: dark ? Color(hex: 0xFFF8E9) : Color(hex: 0x3B2C16),
                heroMutedInk: dark ? Color(hex: 0xE4CFA6) : Color(hex: 0x8A6B36),
                cardRadius: 16, heroRadius: 18, chipRadius: 12,
                shadowOpacity: 0.10, shadowRadius: 8, showsBorder: true)
        case .modern:
            return DesignTokens(
                canvas: dark ? Color(hex: 0x0F1522) : Color(hex: 0xF2F5FA),
                canvasEdge: dark ? Color(hex: 0x131A29) : Color(hex: 0xE9EFF7),
                paper: dark ? Color(hex: 0x18202F) : Color(hex: 0xFFFFFF),
                paperAlt: dark ? Color(hex: 0x1E2738) : Color(hex: 0xF7FAFE),
                raised: dark ? Color(hex: 0x232D40) : Color(hex: 0xEBF1F9),
                ink: dark ? Color(hex: 0xEDF1FA) : Color(hex: 0x16233A),
                muted: dark ? Color(hex: 0xA6B2C6) : Color(hex: 0x6C7C93),
                line: dark ? Color(hex: 0x2C384D) : Color(hex: 0xE3EAF3),
                primary: dark ? Color(hex: 0x7AA7FF) : Color(hex: 0x2F6BFF),
                primaryDeep: dark ? Color(hex: 0x3E6FE0) : Color(hex: 0x1C4FD6),
                secondary: dark ? Color(hex: 0x9FB4FF) : Color(hex: 0x4C63E8),
                jade: dark ? Color(hex: 0x45C6A2) : Color(hex: 0x0E9C7F),
                risk: dark ? Color(hex: 0xF5857E) : Color(hex: 0xE0544C),
                tint: dark ? Color(hex: 0x22304A) : Color(hex: 0xE8EFFF),
                heroSurface: dark ? Color(hex: 0x1B2B4A) : Color(hex: 0xE9F0FF),
                chartBlue: dark ? Color(hex: 0x7AA7FF) : Color(hex: 0x2F6BFF),
                chartViolet: dark ? Color(hex: 0xA99BFF) : Color(hex: 0x6B5CE8),
                chartGold: dark ? Color(hex: 0xE9B45C) : Color(hex: 0xD08C1E),
                chartCost: dark ? Color(hex: 0xE39FB0) : Color(hex: 0xB0576E),
                up: dark ? Color(hex: 0xFF6F63) : Color(hex: 0xDB3B34),
                down: dark ? Color(hex: 0x3FC489) : Color(hex: 0x1B9E5B),
                heroStart: dark ? Color(hex: 0x1B3A86) : Color(hex: 0x1E52D8),
                heroEnd: dark ? Color(hex: 0x2F6BFF) : Color(hex: 0x3E8BFF),
                heroInk: Color.white, heroMutedInk: Color(hex: 0xDAE6FF),
                cardRadius: 16, heroRadius: 18, chipRadius: 10,
                shadowOpacity: 0.07, shadowRadius: 6, showsBorder: false)
        case .dashboard:
            return DesignTokens(
                canvas: Color(hex: 0x080E18),
                canvasEdge: Color(hex: 0x0C1422),
                paper: Color(hex: 0x121B2B),
                paperAlt: Color(hex: 0x162134),
                raised: Color(hex: 0x1B2740),
                ink: Color(hex: 0xE9EFFC),
                muted: Color(hex: 0x8E9DB6),
                line: Color(hex: 0x233149),
                primary: Color(hex: 0x8B7BFF),
                primaryDeep: Color(hex: 0x6C5CE7),
                secondary: Color(hex: 0x59D2C6),
                jade: Color(hex: 0x2ED3A0),
                risk: Color(hex: 0xFF7A6B),
                tint: Color(hex: 0x1C2740),
                heroSurface: Color(hex: 0x1A1F45),
                chartBlue: Color(hex: 0x5B8CFF),
                chartViolet: Color(hex: 0xA78BFA),
                chartGold: Color(hex: 0xF0B44C),
                chartCost: Color(hex: 0xE389A6),
                up: Color(hex: 0xFF5F52),
                down: Color(hex: 0x21C77E),
                heroStart: Color(hex: 0x3B1E7A),
                heroEnd: Color(hex: 0x6D3BE0),
                heroInk: Color.white, heroMutedInk: Color(hex: 0xD6CCFF),
                cardRadius: 14, heroRadius: 16, chipRadius: 8,
                shadowOpacity: 0.35, shadowRadius: 10, showsBorder: true)
        case .magazine:
            return DesignTokens(
                canvas: dark ? Color(hex: 0x171314) : Color(hex: 0xFBF4F1),
                canvasEdge: dark ? Color(hex: 0x1E1819) : Color(hex: 0xF7E9E6),
                paper: dark ? Color(hex: 0x211A1C) : Color(hex: 0xFFFFFF),
                paperAlt: dark ? Color(hex: 0x281F22) : Color(hex: 0xFDF1EC),
                raised: dark ? Color(hex: 0x2E2326) : Color(hex: 0xF5E4DE),
                ink: dark ? Color(hex: 0xF6ECE8) : Color(hex: 0x1F2A37),
                muted: dark ? Color(hex: 0xC0ADA7) : Color(hex: 0x857470),
                line: dark ? Color(hex: 0x3A2C2F) : Color(hex: 0xEEDCD6),
                primary: dark ? Color(hex: 0xE9A8B6) : Color(hex: 0xB4516A),
                primaryDeep: dark ? Color(hex: 0xC97E8F) : Color(hex: 0x8E3A50),
                secondary: dark ? Color(hex: 0xE0B98F) : Color(hex: 0x9A6B3F),
                jade: dark ? Color(hex: 0x6FC79A) : Color(hex: 0x2A8F63),
                risk: dark ? Color(hex: 0xEF8A80) : Color(hex: 0xC4453B),
                tint: dark ? Color(hex: 0x33262A) : Color(hex: 0xFAE7E2),
                heroSurface: dark ? Color(hex: 0x2A2023) : Color(hex: 0xFDF1E4),
                chartBlue: dark ? Color(hex: 0x9FB6E8) : Color(hex: 0x4A6FA5),
                chartViolet: dark ? Color(hex: 0xD3A8C6) : Color(hex: 0x9A5B84),
                chartGold: dark ? Color(hex: 0xE0B98F) : Color(hex: 0xB4813E),
                chartCost: dark ? Color(hex: 0xDFA0A0) : Color(hex: 0xA5575F),
                up: dark ? Color(hex: 0xF97F70) : Color(hex: 0xC43C2F),
                down: dark ? Color(hex: 0x58C08D) : Color(hex: 0x1D8B57),
                heroStart: dark ? Color(hex: 0x3D2A2E) : Color(hex: 0xFDEFE2),
                heroEnd: dark ? Color(hex: 0x50403F) : Color(hex: 0xF9E3D8),
                heroInk: dark ? Color(hex: 0xFFF6F2) : Color(hex: 0x2A2024),
                heroMutedInk: dark ? Color(hex: 0xDCC7C0) : Color(hex: 0x8A7168),
                cardRadius: 4, heroRadius: 6, chipRadius: 3,
                shadowOpacity: 0.05, shadowRadius: 3, showsBorder: true)
        case .puzzle:
            return DesignTokens(
                canvas: dark ? Color(hex: 0x120F19) : Color(hex: 0xF7F3FB),
                canvasEdge: dark ? Color(hex: 0x171320) : Color(hex: 0xEFE8F8),
                paper: dark ? Color(hex: 0x1B1626) : Color(hex: 0xFFFFFF),
                paperAlt: dark ? Color(hex: 0x221B30) : Color(hex: 0xFBF7FF),
                raised: dark ? Color(hex: 0x2A2138) : Color(hex: 0xF0E9F9),
                ink: dark ? Color(hex: 0xF2ECFA) : Color(hex: 0x241C33),
                muted: dark ? Color(hex: 0xB4A8C6) : Color(hex: 0x7B6E8F),
                line: dark ? Color(hex: 0x332844) : Color(hex: 0xEBE2F6),
                primary: dark ? Color(hex: 0x9C8BFF) : Color(hex: 0x6C4CF0),
                primaryDeep: dark ? Color(hex: 0x7B62EA) : Color(hex: 0x5334D6),
                secondary: dark ? Color(hex: 0xFFC65C) : Color(hex: 0xE9A31B),
                jade: dark ? Color(hex: 0x5FD8A8) : Color(hex: 0x18A46F),
                risk: dark ? Color(hex: 0xFF8A7A) : Color(hex: 0xE2503F),
                tint: dark ? Color(hex: 0x2A2140) : Color(hex: 0xF0E9FF),
                heroSurface: dark ? Color(hex: 0x2B2340) : Color(hex: 0xFFF3CF),
                chartBlue: dark ? Color(hex: 0x8AA8FF) : Color(hex: 0x3F72F0),
                chartViolet: dark ? Color(hex: 0xB79BFF) : Color(hex: 0x7C5CE0),
                chartGold: dark ? Color(hex: 0xFFC65C) : Color(hex: 0xE0A02A),
                chartCost: dark ? Color(hex: 0xE8A2B8) : Color(hex: 0xB05A76),
                up: dark ? Color(hex: 0xFF7565) : Color(hex: 0xD93B34),
                down: dark ? Color(hex: 0x45CE92) : Color(hex: 0x17975A),
                heroStart: dark ? Color(hex: 0xFFC65C) : Color(hex: 0xFDD87A),
                heroEnd: dark ? Color(hex: 0xF0A44A) : Color(hex: 0xF8C766),
                heroInk: Color(hex: 0x3A2A08), heroMutedInk: Color(hex: 0x6B5218),
                cardRadius: 22, heroRadius: 24, chipRadius: 14,
                shadowOpacity: 0.12, shadowRadius: 10, showsBorder: false)
        }
    }
}

/// 拼图主题需要一组「每块不同颜色」的拼图色，其他主题用主色系即可。
enum PuzzlePalette {
    static func tones(_ tokens: DesignTokens) -> [(fill: Color, ink: Color)] {
        [
            (Color(hex: 0xFDE08A), Color(hex: 0x6B4E0B)),   // 暖黄：今日指导
            (Color(hex: 0xF9BBD0), Color(hex: 0x8C2E52)),   // 粉：市场状态
            (Color(hex: 0x8CC4F7), Color(hex: 0x10395E)),   // 蓝：个股/ETF
            (Color(hex: 0x9BE3BF), Color(hex: 0x0F5138)),   // 绿：长期持有
            (Color(hex: 0xC0AEF7), Color(hex: 0x3A2470)),   // 紫：网格
            (Color(hex: 0xFBBFA0), Color(hex: 0x6E2F12))    // 橙：其他
        ]
    }
}

/// 主题里会用到的排版差异（标题字体、数字字体）。
enum ThemeType {
    static func headerFont(_ theme: AppTheme) -> Font.Design {
        switch theme {
        case .editorial, .magazine: return .serif
        case .dashboard: return .rounded
        case .modern: return .default
        case .puzzle: return .rounded
        }
    }
    static func numberFont(_ theme: AppTheme) -> Font.Design {
        switch theme {
        case .dashboard, .modern: return .monospaced
        default: return .rounded
        }
    }
}
