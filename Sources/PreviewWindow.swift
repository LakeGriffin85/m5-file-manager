import AppKit
import ImageIO

/// Separate read-only views never rewrite a CSV/JSON just to display it.
final class PreviewWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static var windows: [PreviewWindow] = []
    private var languageObserver: NSObjectProtocol?
    private var rows: [[String]] = []

    static func show(name: String, data: Data) throws {
        let controller = PreviewWindow(window: NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 580), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false))
        guard let window = controller.window else { return }
        window.title = name + L(" · Vorschau (nur lesen)")
        controller.languageObserver = NotificationCenter.default.addObserver(forName: Localizer.changed, object: nil, queue: .main) { [weak controller] _ in
            guard let window = controller?.window else { return }
            Localizer.refresh(window)
            window.title = name + L(" · Vorschau (nur lesen)")
        }
        window.isReleasedWhenClosed = false
        window.delegate = controller
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        window.contentView?.addSubview(scroll)
        let ext = (name as NSString).pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "bmp"].contains(ext) {
            guard data.count <= 8 * 1_048_576,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = metadata[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = metadata[kCGImagePropertyPixelHeight] as? NSNumber,
                  width.doubleValue * height.doubleValue <= 24_000_000,
                  let image = NSImage(data: data) else { throw M5Error.message(L("Bild nicht lesbar oder zu gross (8 MiB / 24 Megapixel).")) }
            let view = NSImageView(frame: NSRect(origin: .zero, size: image.size))
            view.image = image
            view.imageScaling = .scaleProportionallyDown
            scroll.documentView = view
        } else if ext == "csv" {
            guard let text = String(data: data, encoding: .utf8) else { throw M5Error.message(L("CSV ist kein UTF-8-Text.")) }
            controller.rows = try CSVPreview.parse(text)
            let table = NSTableView()
            table.rowHeight = 24; table.usesAlternatingRowBackgroundColors = true
            for column in 0..<(controller.rows.map(\.count).max() ?? 0) {
                let item = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(column)))
                item.title = L("Spalte {0}", String(describing: (column + 1))); item.width = 150
                table.addTableColumn(item)
            }
            table.dataSource = controller; table.delegate = controller
            scroll.documentView = table
        } else {
            let formatted = try JSONPreview.format(data)
            let text = NSTextView(frame: scroll.bounds)
            text.isEditable = false; text.isRichText = false
            text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            text.textContainerInset = NSSize(width: 12, height: 12)
            text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
            text.string = formatted
            scroll.documentView = text
        }
        windows.append(controller)
        window.center(); controller.showWindow(nil); window.makeKeyAndOrderFront(nil)
    }
    deinit { if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) } }
    func windowWillClose(_ notification: Notification) { Self.windows.removeAll { $0 === self } }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = Int(tableColumn?.identifier.rawValue ?? ""), row < rows.count else { return nil }
        let label = NSTextField(labelWithString: column < rows[row].count ? rows[row][column] : "")
        label.lineBreakMode = .byTruncatingTail; label.toolTip = label.stringValue
        return label
    }
}
