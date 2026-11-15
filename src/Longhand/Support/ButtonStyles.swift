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
    /// `framed`: the chosen row of a list that has the keyboard, a hairline round its band.
    func rowBackground(_ colour: Color, framed: Bool = false) -> some View {
        background(rounded(Layout.rowRadius).fill(colour)
            .overlay(rounded(Layout.rowRadius).strokeBorder(Color(PaperTheme.controlOnBorder), lineWidth: framed ? 1 : 0))
            .padding(.horizontal, 6))
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

// MARK: - Controls worked from the keyboard (Settings)

/// The controls of a window that is worked from the keyboard, in reading order, and which
/// one has the keyboard. The window's keys come here through a monitor (`KeyStopsMonitor`):
/// Tab and ⇧Tab move, Space or Return presses, ← → step segments, Escape closes the window.
/// (SwiftUI's own focus was tried first: in the real Settings window Tab did nothing.)
@MainActor
final class KeyStops: ObservableObject {
    @Published var current: UUID?
    struct Stop {
        var press: (() -> Void)?
        var step: ((Int) -> Void)?
        var enabled = true
        var first = false
    }
    var stops: [UUID: Stop] = [:]
    var frames: [UUID: CGRect] = [:] {
        didSet { if current == nil || !ordered.contains(current!) { current = ordered.first { stops[$0]?.first == true } ?? ordered.first } }
    }

    /// Top to bottom, then left to right (controls on one row share a top within a few points).
    var ordered: [UUID] {
        frames.filter { stops[$0.key]?.enabled == true }
            .sorted { a, b in
                abs(a.value.midY - b.value.midY) > 8 ? a.value.midY < b.value.midY : a.value.minX < b.value.minX
            }
            .map(\.key)
    }

    func move(_ by: Int) {
        let list = ordered
        guard !list.isEmpty else { return }
        let index = current.flatMap { list.firstIndex(of: $0) }
        current = list[((index ?? (by > 0 ? -1 : 0)) + by + list.count) % list.count]
    }

    /// True when the key was used.
    func key(_ event: NSEvent, in window: NSWindow) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let typing = (window.firstResponder as? NSTextView) != nil
        switch event.keyCode {
        case 53 where flags.isEmpty:                     // Escape: out of a field, else close
            if typing { window.makeFirstResponder(nil); if current == nil { move(1) } } else { window.performClose(nil) }
        case 48 where flags.isEmpty || flags == .shift:  // Tab, ⇧Tab
            let by = flags == .shift ? -1 : 1
            let list = ordered
            if typing {
                // Among the fields; from the first or last of them, back to the controls.
                let before = window.firstResponder
                if by > 0 { window.selectNextKeyView(nil) } else { window.selectPreviousKeyView(nil) }
                if window.firstResponder === before || !(window.firstResponder is NSTextView) {
                    window.makeFirstResponder(nil)
                    current = by > 0 ? list.first : list.last
                }
                return true
            }
            // Past the last control: into the pane's text fields, if it has any.
            if let current, by > 0 ? current == list.last : current == list.first, let content = window.contentView {
                if by > 0 { window.selectKeyView(following: content) } else { window.selectKeyView(preceding: content) }
                if window.firstResponder is NSTextView { self.current = nil; return true }
            }
            move(by)
        case 49, 36, 76:                                 // Space, Return, Enter
            guard !typing, flags.isEmpty, let current, let press = stops[current]?.press else { return false }
            press()
        case 123, 124:                                   // ← →
            guard !typing, flags.isEmpty, let current, let step = stops[current]?.step else { return false }
            step(event.keyCode == 124 ? 1 : -1)
        default:
            return false
        }
        return true
    }
}

private struct KeyStopsKey: EnvironmentKey { static let defaultValue: KeyStops? = nil }
private struct StopFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) { value.merge(nextValue()) { $1 } }
}

extension EnvironmentValues {
    /// Set in Settings; nil in the main window, where controls are left to the mouse.
    var keyStops: KeyStops? {
        get { self[KeyStopsKey.self] }
        set { self[KeyStopsKey.self] = newValue }
    }
}

extension View {
    /// A control worked from the keyboard, where the window has `keyStops`.
    func keyControl(radius: CGFloat = Layout.radius, first: Bool = false,
                    step: ((Int) -> Void)? = nil, action: (() -> Void)? = nil) -> some View {
        modifier(KeyControl(radius: radius, first: first, step: step, action: action))
    }

    /// Makes a window's controls keyboard stops: put on the window's root view.
    func keyStops(_ stops: KeyStops) -> some View {
        environment(\.keyStops, stops)
            .coordinateSpace(name: "keyStops")
            .onPreferenceChange(StopFrames.self) { frames in
                DispatchQueue.main.async { if stops.frames != frames { stops.frames = frames } }
            }
            .background(KeyStopsMonitor(stops: stops))
    }
}

private struct KeyControl: ViewModifier {
    let radius: CGFloat
    let first: Bool
    let step: ((Int) -> Void)?
    let action: (() -> Void)?
    @Environment(\.keyStops) private var stops
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        if let stops {
            KeyStopView(stops: stops, radius: radius,
                        stop: KeyStops.Stop(press: action, step: step, enabled: isEnabled, first: first), content: content)
        } else {
            content
        }
    }
}

private struct KeyStopView<Content: View>: View {
    @ObservedObject var stops: KeyStops
    let radius: CGFloat
    let stop: KeyStops.Stop
    let content: Content
    @State private var id = UUID()

    var body: some View {
        // Its handlers as they are now (they hold the control's current values).
        let _ = (stops.stops[id] = stop)
        content
            .overlay(rounded(radius + 2).strokeBorder(Color(PaperTheme.accent), lineWidth: stops.current == id ? 1.5 : 0).padding(-3))
            .background(GeometryReader { geometry in
                Color.clear.preference(key: StopFrames.self, value: [id: geometry.frame(in: .named("keyStops"))])
            })
            .onDisappear { stops.stops[id] = nil }
    }
}

/// Hands the window's keys to its `KeyStops`.
private struct KeyStopsMonitor: NSViewRepresentable {
    let stops: KeyStops
    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.stops = stops
        return view
    }
    func updateNSView(_ view: MonitorView, context: Context) { view.stops = stops }

    final class MonitorView: NSView {
        var stops: KeyStops?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window, window.attachedSheet == nil,
                      let stops = self.stops else { return event }
                return stops.key(event, in: window) ? nil : event
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

/// `FramedButtonStyle` for a window whose controls are keyboard stops (Settings).
struct KeyFramedButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(action: configuration.trigger) { configuration.label }
            .buttonStyle(FramedButtonStyle())
            .keyControl(action: configuration.trigger)
    }
}
