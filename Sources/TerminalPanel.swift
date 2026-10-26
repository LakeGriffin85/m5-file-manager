import AppKit

/// Compact terminal output area. Calls to append/clear belong on the main thread.
final class TerminalPanel: NSView {
    private let transcript = TerminalTranscript()
    private let filters = NSSegmentedControl(labels: [L("Alle"), L("Gerät"), "Transfers", L("Fehler")],
                                             trackingMode: .selectOne, target: nil, action: nil)
    private let rawButton = NSButton(checkboxWithTitle: L("Roh"), target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    private var pendingRender: DispatchWorkItem?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        configure()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func append(_ event: LogEvent) {
        transcript.append(event)
        guard pendingRender == nil else { return }
        let task = DispatchWorkItem { [weak self] in
            self?.pendingRender = nil
            self?.render()
        }
        pendingRender = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: task)
    }

    func clear() {
        pendingRender?.cancel()
        pendingRender = nil
        transcript.clear()
        render()
    }

    private func configure() {
        filters.selectedSegment = 0
        filters.controlSize = .small
        filters.target = self
        filters.action = #selector(changeView)
        filters.toolTip = L("Ausgabe nach Herkunft filtern. Gerätefehler erscheinen auch unter Fehler.")
        rawButton.controlSize = .small
        rawButton.target = self
        rawButton.action = #selector(changeView)
        rawButton.toolTip = L("Vollständiger empfangener Stream, unverändert inklusive Prompts und Bannern. Filter sind in der Rohansicht ausgeschaltet.")
        status.font = .systemFont(ofSize: 10)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let clearButton = NSButton(title: "", target: self, action: #selector(clearClicked))
        clearButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: L("Terminalausgabe leeren"))
        clearButton.bezelStyle = .inline
        clearButton.isBordered = false
        clearButton.controlSize = .small
        clearButton.toolTip = L("Nur die sichtbare und gespeicherte Terminalausgabe leeren.")

        let header = NSStackView(views: [filters, rawButton, status, clearButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        header.translatesAutoresizingMaskIntoConstraints = false
        filters.setContentHuggingPriority(.required, for: .horizontal)
        rawButton.setContentHuggingPriority(.required, for: .horizontal)
        clearButton.setContentHuggingPriority(.required, for: .horizontal)

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.backgroundColor = NSColor(calibratedRed: 0.06, green: 0.08, blue: 0.12, alpha: 1)
        textView.textColor = color(for: .device)
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel(L("Terminalausgabe"))
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 7
        scrollView.layer?.masksToBounds = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(header)
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.heightAnchor.constraint(equalToConstant: 25),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 5),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 90)
        ])
        render()
    }

    @objc private func changeView() {
        filters.isEnabled = rawButton.state != .on
        render()
    }

    @objc private func clearClicked() { clear() }

    private func render() {
        let visible = scrollView.contentView.bounds
        let shouldFollow = textView.string.isEmpty || visible.maxY >= textView.bounds.maxY - 30
        let savedOrigin = visible.origin
        let savedSelection = textView.selectedRange()
        let raw = rawButton.state == .on
        let filter = TerminalLogFilter(rawValue: filters.selectedSegment) ?? .all
        let snapshot = transcript.snapshot(filter: filter, raw: raw)
        let output = NSMutableAttributedString(string: "")
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        for span in snapshot.spans {
            output.append(NSAttributedString(string: span.text, attributes: [
                .font: font, .foregroundColor: color(for: span.kind)
            ]))
        }
        textView.textStorage?.setAttributedString(output)
        let start = min(savedSelection.location, output.length)
        textView.setSelectedRange(NSRange(location: start, length: min(savedSelection.length, output.length - start)))
        if shouldFollow {
            textView.scrollToEndOfDocument(nil)
        } else {
            scrollView.contentView.scroll(to: savedOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        var labels: [String] = []
        if raw { labels.append(L("Originalstream")) }
        else if snapshot.hiddenProtocolLineCount > 0 { labels.append(L("{0} Protokollzeilen ausgeblendet", String(describing: (snapshot.hiddenProtocolLineCount)))) }
        else { labels.append(L("Bereinigt")) }
        if snapshot.discardedUTF16Count > 0 { labels.append(L("ältere Ausgabe gekürzt")) }
        status.stringValue = labels.joined(separator: " · ")
        status.toolTip = L("Prompts und wiederholte Standardbanner werden nur in der bereinigten Ansicht ausgeblendet. Warnungen und Fehler bleiben erhalten. Maximal 280'000 UTF-16-Zeichen werden gespeichert.")
    }

    private func color(for kind: LogKind) -> NSColor {
        switch kind {
        case .device: return NSColor(calibratedRed: 0.85, green: 0.90, blue: 0.94, alpha: 1)
        case .transfer: return NSColor(calibratedRed: 0.42, green: 0.76, blue: 1, alpha: 1)
        case .info: return NSColor(calibratedRed: 0.65, green: 0.72, blue: 0.82, alpha: 1)
        case .error: return NSColor(calibratedRed: 1, green: 0.58, blue: 0.49, alpha: 1)
        }
    }
}
