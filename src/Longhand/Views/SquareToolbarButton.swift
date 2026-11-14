import AppKit
import SwiftUI

/// A toolbar menu row, with MainActor-isolated work.
struct ToolbarMenuItem {
    let title: String
    var separatorAfter = false
    let action: @MainActor () -> Void
}

/// A toolbar button drawn by AppKit, showing an SF Symbol.
///
/// SwiftUI's toolbar styling is overridden by AppKit's pill-like toolbar buttons, so the
/// toolbar controls use a small NSButton that draws its own subtly rounded shape.
struct SquareToolbarButton: NSViewRepresentable {
    let icon: Symbol
    let tooltip: String
    var size: CGFloat = 28
    /// Set both for a button that is not square (a framed toolbar button, 28 by 22).
    var width: CGFloat? = nil
    var height: CGFloat? = nil
    var iconSize: CGFloat = 16
    /// Without a border the button is just its icon until hovered — for the toolbar.
    var bordered = false
    /// Drawn pressed: a panel toggle whose panel is showing.
    var isOn = false
    var action: (@MainActor () -> Void)?
    var menuItems: [ToolbarMenuItem]?

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action, menuItems: menuItems)
    }

    func makeNSView(context: Context) -> SquareToolbarButtonView {
        let button = SquareToolbarButtonView(frame: NSRect(x: 0, y: 0, width: width ?? size, height: height ?? size))
        button.side = size
        button.boxSize = width.flatMap { w in height.map { NSSize(width: w, height: $0) } }
        button.showsOutline = bordered
        button.isOn = isOn
        button.contentTintColor = bordered || isOn ? PaperTheme.ink : PaperTheme.secondary
        button.image = icon.image(size: iconSize)
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        button.target = context.coordinator
        button.action = #selector(Coordinator.activate(_:))
        return button
    }

    func updateNSView(_ button: SquareToolbarButtonView, context: Context) {
        context.coordinator.action = action
        context.coordinator.menuItems = menuItems
        // Only touch what changed: each change redraws the button.
        if button.isOn != isOn { button.isOn = isOn }
        if context.coordinator.icon != icon {
            context.coordinator.icon = icon
            button.image = icon.image(size: iconSize)
        }
        if button.toolTip != tooltip {
            button.toolTip = tooltip
            button.setAccessibilityLabel(tooltip)
        }
    }

    final class Coordinator: NSObject {
        var icon: Symbol?
        var action: (@MainActor () -> Void)?
        var menuItems: [ToolbarMenuItem]?

        init(action: (@MainActor () -> Void)?, menuItems: [ToolbarMenuItem]?) {
            self.action = action
            self.menuItems = menuItems
        }

        @objc func activate(_ sender: NSButton) {
            guard let menuItems, !menuItems.isEmpty else {
                run(action)
                return
            }

            let menu = NSMenu()
            for (index, item) in menuItems.enumerated() {
                let menuItem = NSMenuItem(
                    title: item.title,
                    action: #selector(Coordinator.chooseMenuItem(_:)),
                    keyEquivalent: ""
                )
                menuItem.target = self
                menuItem.tag = index
                menu.addItem(menuItem)

                if item.separatorAfter {
                    menu.addItem(.separator())
                }
            }
            menu.popUp(positioning: nil, at: NSPoint(x: sender.bounds.minX, y: sender.bounds.maxY), in: sender)
        }

        @objc func chooseMenuItem(_ sender: NSMenuItem) {
            guard let menuItems, menuItems.indices.contains(sender.tag) else { return }
            run(menuItems[sender.tag].action)
        }

        private func run(_ action: (@MainActor () -> Void)?) {
            guard let action else { return }
            MainActor.assumeIsolated { action() }
        }
    }
}

final class SquareToolbarButtonView: NSButton {
    private var hovering = false
    private var trackingArea: NSTrackingArea?
    var side: CGFloat = 26 { didSet { invalidateIntrinsicContentSize() } }
    var boxSize: NSSize? { didSet { invalidateIntrinsicContentSize() } }
    var showsOutline = true { didSet { needsDisplay = true } }
    var isOn = false {
        didSet {
            guard isOn != oldValue else { return }
            contentTintColor = isOn || showsOutline ? PaperTheme.ink : PaperTheme.secondary
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        boxSize ?? NSSize(width: side, height: side)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        if let trackingArea {
            addTrackingArea(trackingArea)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        setNeedsDisplay(bounds)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        setNeedsDisplay(bounds)
    }

    override func mouseMoved(with event: NSEvent) {
        setNeedsDisplay(bounds)
    }

    override func draw(_ dirtyRect: NSRect) {
        let pressed = (cell as? NSButtonCell)?.isHighlighted ?? false
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: Layout.radius, yRadius: Layout.radius)

        let fill: NSColor
        if showsOutline {
            // A framed control on the window: filled, darker when pressed or on.
            fill = pressed || isOn ? PaperTheme.controlOn : hovering ? PaperTheme.hover : PaperTheme.controlFill
        } else if !isEnabled {
            fill = .clear
        } else if pressed || isOn {
            fill = PaperTheme.selection
        } else if hovering {
            fill = PaperTheme.hover
        } else {
            fill = .clear
        }

        fill.setFill()
        path.fill()

        if showsOutline {
            (isOn ? PaperTheme.controlOnBorder : PaperTheme.controlBorder).setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        super.draw(dirtyRect)
    }

    private func configure() {
        // The cell first: replacing it afterwards threw away everything set before (and
        // cost the work twice; every toolbar button is rebuilt when the theme changes).
        cell = SquareButtonCell(textCell: "")
        setButtonType(.momentaryChange)
        bezelStyle = .inline
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        controlSize = .regular
        focusRingType = .none
        contentTintColor = PaperTheme.secondary
        wantsLayer = false
    }
}

/// A button cell that draws no bezel, so the button's own rectangle is all you see.
final class SquareButtonCell: NSButtonCell {
    override func drawBezel(withFrame frame: NSRect, in view: NSView) {
        // Intentionally empty: SquareToolbarButtonView draws its own square.
    }
}
