import SwiftUI

/// D4：把 `NextDataConfidence.score0to100` 以环形分数呈现，颜色随分档（绿/橙/红）。
/// 与现有「置信度等级胶囊」并列，提供 0–100 可比总分，让用户一眼看到「此刻数据底气」。
struct GPDataQualityScore: View {
    let confidence: NextDataConfidence
    @Environment(\.gp) private var p

    private var score: Int { confidence.score0to100 }
    private var tint: Color {
        switch score {
        case 80...: return .green
        case 55..<80: return .orange
        default: return .red
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle().stroke(tint.opacity(0.25), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: CGFloat(score) / 100)
                    .stroke(tint, lineWidth: 3)
                    .rotationEffect(.degrees(-90))
                Text("\(score)").font(.system(size: 12, weight: .bold)).foregroundStyle(tint)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("数据质量 \(score)").font(.system(size: 10, weight: .medium)).foregroundStyle(p.muted)
                Text(confidence.level.rawValue).font(.system(size: 10)).foregroundStyle(tint)
            }
        }
        .accessibilityLabel("数据质量 \(score) 分，\(confidence.level.rawValue)")
    }
}
