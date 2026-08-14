import AppKit

/// A menu row that does its job without taking the menu down with it.
///
/// NSMenu closes the moment an item's action fires. That is right for
/// "Settings…", which opens the window you are about to look at, and wrong for a
/// switch or a refresh, where the thing you asked to see appears in the menu that
/// just vanished. A menu item with a view never sends its action: the view
/// receives the click instead, and a menu that never hears about the click has no
/// reason to dismiss.
///
/// The cost is that AppKit stops drawing the row, so everything below here is the
/// part it would have done — text, icon, checkmark, hover highlight.
@MainActor
final class MenuActionRow: NSView {
    /// What the row should say *now*.
    ///
    /// Read through a closure rather than handed over once, because a menu stays
    /// open for as long as somebody holds it there: a row reading "Refreshing…"
    /// has to stop saying so when the refresh ends, and by then nobody is going to
    /// build this row again.
    struct Content: Equatable {
        var title: String
        var symbol: String
        var isChecked: Bool = false
        var isEnabled: Bool = true
        var toolTip: String?
    }

    private let content: @MainActor () -> Content
    private let onClick: @MainActor () -> Void

    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let checkView = NSImageView()

    private var shown: Content?
    private var isHighlighted = false

    init(
        width: CGFloat,
        content: @escaping @MainActor () -> Content,
        onClick: @escaping @MainActor () -> Void
    ) {
        self.content = content
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 22))

        iconView.frame = NSRect(x: 13, y: 4, width: 14, height: 14)
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        titleField.frame = NSRect(x: 34, y: 2, width: width - 66, height: 16)
        titleField.font = NSFont.menuFont(ofSize: 0)
        titleField.lineBreakMode = .byTruncatingTail
        addSubview(titleField)

        checkView.frame = NSRect(x: width - 26, y: 4, width: 13, height: 13)
        checkView.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        checkView.imageScaling = .scaleProportionallyDown
        addSubview(checkView)

        setAccessibilityRole(.menuItem)
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("MenuActionRow is built in code, never from a nib")
    }

    /// Look at the app again and redraw if anything moved.
    func refresh() {
        let content = self.content()
        guard content != shown else { return }
        shown = content

        iconView.image = NSImage(systemSymbolName: content.symbol, accessibilityDescription: nil)
        titleField.stringValue = content.title
        checkView.isHidden = !content.isChecked
        toolTip = content.toolTip
        setAccessibilityLabel(content.title)
        setAccessibilityValue(content.isChecked ? "on" : "off")

        if !content.isEnabled { isHighlighted = false }
        applyColors(for: content)

        needsDisplay = true
        displayIfNeeded()
    }

    private func applyColors(for content: Content) {
        let color: NSColor = !content.isEnabled
            ? .disabledControlTextColor
            : isHighlighted ? .selectedMenuItemTextColor : .labelColor
        titleField.textColor = color
        iconView.contentTintColor = color
        checkView.contentTintColor = color
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isHighlighted else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 5, yRadius: 5).fill()
    }

    // MARK: - Events

    // The subviews are decoration. Sending them the click would leave the row
    // itself never hearing about it, which is the one thing it exists to do.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    /// Swallowed on purpose: an unhandled press is how the menu decides the click
    /// was meant for it.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard shown?.isEnabled ?? true else { return }
        onClick()
        refresh()
    }

    override func mouseEntered(with event: NSEvent) {
        setHighlighted(shown?.isEnabled ?? true)
    }

    override func mouseExited(with event: NSEvent) {
        setHighlighted(false)
    }

    private func setHighlighted(_ highlighted: Bool) {
        guard highlighted != isHighlighted else { return }
        isHighlighted = highlighted
        if let shown = shown { applyColors(for: shown) }
        needsDisplay = true
        displayIfNeeded()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            )
        )
    }
}
