import SwiftUI

/// High contrast on black, with yellow as the accent: the scheme most low-vision users find easiest.
enum Theme {
    static let accent = Color(red: 1.0, green: 0.84, blue: 0.0)
    static let card = Color(white: 0.13)
    static let cardSelected = Color(red: 0.25, green: 0.21, blue: 0.0)
    static let go = Color(red: 0.1, green: 0.65, blue: 0.3)
    static let stop = Color(red: 0.85, green: 0.15, blue: 0.15)
    static let route = Color(red: 0.3, green: 0.6, blue: 1.0)
}

/// Large, rounded, full-width card button with an icon, a title, and an optional line of detail.
struct CardButton: View {
    let icon: String
    let title: String
    var detail: String?
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title)
                    .frame(width: 40)
                    .foregroundStyle(selected ? Theme.accent : .white)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title3.bold())
                    if let detail {
                        Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(Theme.accent)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(selected ? Theme.cardSelected : Theme.card, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(selected ? Theme.accent : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
