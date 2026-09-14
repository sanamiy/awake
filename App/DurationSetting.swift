import SwiftUI

struct DurationSetting: View {
    @Binding var minutes: Int
    // The last stop is unlimited. Custom values remain exact in storage;
    // the thumb shows their nearest finite preset until the slider is moved.
    static let presets = [15, 30, 60, 120, 240, 480, 1440, 0]

    static func position(for minutes: Int) -> Double {
        if minutes == 0 { return Double(presets.count - 1) }
        return Double(presets.dropLast().indices.min {
            abs(presets[$0] - minutes) < abs(presets[$1] - minutes)
        } ?? 0)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            Text(L10n.text("スリープ防止時間"))
                .fixedSize().frame(height: 28)
            Spacer(minLength: 0)
            VStack(spacing: 4) {
                Slider(value: Binding(
                    get: { Self.position(for: minutes) },
                    set: { minutes = Self.presets[min(max(Int($0.rounded()), 0), Self.presets.count - 1)] }),
                       in: 0...Double(Self.presets.count - 1), step: 1)
                    .frame(height: 28)
                    .accessibilityLabel(L10n.text("スリープ防止時間"))
                    .accessibilityValue(minutes == 0 ? L10n.text("無制限") : L10n.text("%@分", String(minutes)))
                HStack {
                    Text(L10n.text("%@分", "15"))
                    Spacer()
                    Text(minutes == 0 ? L10n.text("無制限") : L10n.text("%@分", String(minutes)))
                        .monospacedDigit().foregroundStyle(.primary)
                    Spacer()
                    Text("∞ " + L10n.text("無制限"))
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 220)
        }
    }
}
