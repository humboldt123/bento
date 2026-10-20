import SwiftUI

// The bento look, shared by every tool: warm paper background, white cards with a
// black outline and a small hard shadow, black buttons, rounded type.

extension Color {
    /// Warm off-white behind the cards
    static let bentoPaper = Color(light: Color(red: 0.97, green: 0.96, blue: 0.93), dark: Color(white: 0.08))
    /// Activity squares (GitHub-style), the one accent the app keeps
    static let bentoActivity = Color(red: 0.13, green: 0.68, blue: 0.33)

    init(light: Color, dark: Color) {
        self.init(UIColor { $0.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
    }
}

extension View {
    /// White card, black outline, small hard shadow
    func bentoCard(cornerRadius: CGFloat = 24) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(shape.fill(Color(.systemBackground)))
            .overlay(shape.stroke(Color.primary, lineWidth: 1.5))
            .background(shape.fill(Color.primary).offset(x: 3, y: 3))
    }

    /// Paper background behind a List or ScrollView
    func bentoScreen() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Color.bentoPaper.ignoresSafeArea())
    }

    /// Outlined capsule label, e.g. "Push"
    func bentoPill() -> some View {
        self
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .overlay(Capsule().stroke(Color.primary, lineWidth: 1))
    }
}

/// Cards sink into their shadow when pressed
struct BentoPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .offset(x: configuration.isPressed ? 2 : 0, y: configuration.isPressed ? 2 : 0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Main action button: filled black (prominent) or white, outlined, with the hard shadow
struct BentoButtonStyle: ButtonStyle {
    var prominent = true
    var cornerRadius: CGFloat = 16

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(prominent ? Color(.systemBackground) : .primary)
            .background(shape.fill(prominent ? Color.primary : Color(.systemBackground)))
            .overlay(shape.stroke(Color.primary, lineWidth: 1.5))
            .background(shape.fill(Color.primary).offset(x: 3, y: 3))
            .offset(x: configuration.isPressed ? 2 : 0, y: configuration.isPressed ? 2 : 0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Round outlined icon button (the −/+ steppers)
struct BentoCircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title2.bold())
            .frame(width: 56, height: 56)
            .foregroundStyle(.primary)
            .background(Circle().fill(Color(.systemBackground)))
            .overlay(Circle().stroke(Color.primary, lineWidth: 1.5))
            .background(Circle().fill(Color.primary).offset(x: 2, y: 2))
            .offset(x: configuration.isPressed ? 2 : 0, y: configuration.isPressed ? 2 : 0)
    }
}
