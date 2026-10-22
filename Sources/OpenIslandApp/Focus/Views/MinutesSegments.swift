import OpenIslandCore
import FocusCore
import SwiftUI

struct MinutesSegments: View {
    let choices: [Int]
    let selected: Int
    var customRange: ClosedRange<Int>?
    let onSelect: (Int) -> Void
    @State private var showsCustom = false
    @State private var customMinutes = 50

    var body: some View {
        let isCustom = !choices.contains(selected)
        HStack(spacing: 2) {
            ForEach(choices, id: \.self) { minutes in
                segment("\(minutes)", isOn: selected == minutes) { onSelect(minutes) }
                    .accessibilityLabel(L10n.tr("focus.minutes_325", "\(minutes)"))
            }
            if let customRange {
                segment(isCustom ? "\(selected)" : L10n.tr("focus.custom"), isOn: isCustom) {
                    customMinutes = selected
                    showsCustom = true
                }
                .accessibilityLabel(L10n.tr("focus.custom_duration"))
                .popover(isPresented: $showsCustom, arrowEdge: .bottom) {
                    popover(range: customRange)
                }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
    }

    private func segment(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: isOn ? .semibold : .medium))
                .monospacedDigit()
                .foregroundStyle(isOn ? Color.white : FocusStyle.tagText)
                .padding(.horizontal, 11)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(isOn ? Color.white.opacity(0.16) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func popover(range: ClosedRange<Int>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Stepper(L10n.tr("focus.min", "\(customMinutes)"), value: $customMinutes, in: range, step: 5)
                .monospacedDigit()
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(L10n.tr("focus.cancel_207")) { showsCustom = false }
                    .buttonStyle(FocusButtonStyle(kind: .secondary, height: 28))
                Button(L10n.tr("focus.done_328")) {
                    onSelect(min(range.upperBound, max(range.lowerBound, customMinutes)))
                    showsCustom = false
                }
                .buttonStyle(FocusButtonStyle(kind: .primary, height: 28))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 240)
        .preferredColorScheme(.dark)
    }
}
