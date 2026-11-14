import SwiftUI

/// Every control Longhand draws has the Mac's subtle corner (`Layout.radius`): no pill, no capsule.

/// A text button with a hairline frame. `primary` is ink on paper reversed.
struct SquareButtonStyle: ButtonStyle {
    var primary = false

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: primary ? .semibold : .regular))
            .foregroundStyle(primary ? Color(PaperTheme.paper) : Color(PaperTheme.ink))
            .padding(.horizontal, 14)
            .frame(minHeight: 28)
            .background(fill(pressed: configuration.isPressed))
            .roundedFrame(primary ? Color.clear : Color(PaperTheme.cardBorder), lineWidth: 1)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
            .onHover { hovering = isEnabled && $0 }
    }

    private func fill(pressed: Bool) -> Color {
        if primary { return Color(PaperTheme.ink).opacity(pressed ? 0.8 : hovering ? 0.9 : 1) }
        if pressed { return Color(PaperTheme.selection) }
        if hovering { return Color(PaperTheme.hover) }
        return Color(PaperTheme.card)
    }
}

/// A compact framed control on the window's grey (Classic Mac): "+ New scene" at the foot of
/// the contents, "New note", "Show 2 resolved".
struct FramedButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: Layout.chromeSize))
            .foregroundStyle(Color(PaperTheme.ink))
            .padding(.horizontal, 8)
            .frame(minHeight: Layout.controlHeight)
            .background(Color(configuration.isPressed ? PaperTheme.controlOn : hovering ? PaperTheme.hover : PaperTheme.controlFill))
            .roundedFrame(Color(configuration.isPressed ? PaperTheme.controlOnBorder : PaperTheme.controlBorder), lineWidth: 1)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
            .onHover { hovering = isEnabled && $0 }
    }
}

/// A frameless button: an icon, a label, or both. Fills on hover and press.
struct PlainSquareButtonStyle: ButtonStyle {
    var height: CGFloat = 26
    var horizontalPadding: CGFloat = 8
    var isOn = false

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: Layout.chromeSize))
            .foregroundStyle(isOn || hovering ? Color(PaperTheme.ink) : Color(PaperTheme.secondary))
            .padding(.horizontal, horizontalPadding)
            .frame(minWidth: height, minHeight: height)
            .background(fill(pressed: configuration.isPressed), in: rounded(Layout.rowRadius))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
            .onHover { hovering = isEnabled && $0 }
    }

    private func fill(pressed: Bool) -> Color {
        if pressed || isOn { return Color(PaperTheme.selection) }
        if hovering { return Color(PaperTheme.hover) }
        return .clear
    }
}

extension Text {
    /// A text field's hint, always in the tertiary grey. Left to SwiftUI, a field styled in ink
    /// sometimes drew its hint in ink too, so it read as something typed.
    static func placeholder(_ text: String) -> Text {
        Text(text).foregroundStyle(Color(PaperTheme.tertiary))
    }
}

/// A rounded rectangle at one of the `Layout` radii, continuous like the Mac's own.
func rounded(_ radius: CGFloat = Layout.radius) -> RoundedRectangle {
    RoundedRectangle(cornerRadius: radius, style: .continuous)
}

extension View {
    /// Clipped to a rounded rectangle and framed with a hairline inside it.
    func roundedFrame(_ colour: Color, lineWidth: CGFloat = 1, radius: CGFloat = Layout.radius) -> some View {
        clipShape(rounded(radius))
            .overlay(rounded(radius).strokeBorder(colour, lineWidth: lineWidth))
    }

    /// A selected or hovered row, Mac sidebar style: a rounded band inset from the panel's edges.
    func rowBackground(_ colour: Color) -> some View {
        background(rounded(Layout.rowRadius).fill(colour).padding(.horizontal, 6))
    }
}

extension View {
    /// An editable field, Mac style: an inset box on the page's colour with a hairline, which
    /// darkens under the pointer and takes the accent while you type in it. Every field has
    /// one, empty or not, so a field always reads as a field (owner, 2026-11-08).
    func fieldBox(focused: Bool, minHeight: CGFloat = 26) -> some View {
        modifier(FieldBox(focused: focused, minHeight: minHeight))
    }
}

private struct FieldBox: ViewModifier {
    let focused: Bool
    let minHeight: CGFloat
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(minHeight: minHeight, alignment: .topLeading)
            .background(Color(PaperTheme.paper), in: rounded())
            .overlay(rounded().strokeBorder(
                Color(focused ? PaperTheme.accent : hovering ? PaperTheme.controlOnBorder : PaperTheme.controlBorder),
                lineWidth: focused ? 1.5 : 1))
            .onHover { hovering = $0 }
    }
}

/// A field's label: small, secondary, above its field.
struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: Layout.detailSize, weight: .medium))
            .foregroundStyle(Color(PaperTheme.secondary))
    }
}

/// A number or a short fact set in a small box (a count, a branch, a date's badge), so it
/// reads as a label on the thing beside it rather than as loose text (owner, 2026-11-12).
struct Badge: View {
    let text: String
    var colour: NSColor = PaperTheme.secondary
    init(_ text: String, colour: NSColor = PaperTheme.secondary) {
        self.text = text
        self.colour = colour
    }

    var body: some View {
        Text(text)
            .font(.system(size: Layout.smallSize, weight: .medium).monospacedDigit())
            .foregroundStyle(Color(colour))
            .lineLimit(1)
            .boxed()
    }
}

extension View {
    /// The box a `Badge` sits in, for content that isn't plain text.
    func boxed(height: CGFloat = 17, padding: CGFloat = 5) -> some View {
        self
            .padding(.horizontal, padding)
            .frame(minWidth: height, minHeight: height, maxHeight: height)
            .background(Color(PaperTheme.controlFill), in: rounded(Layout.smallRadius + 1))
            .overlay(rounded(Layout.smallRadius + 1).strokeBorder(Color(PaperTheme.controlBorder), lineWidth: 1))
    }
}
