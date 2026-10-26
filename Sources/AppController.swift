import AppKit
import UniformTypeIdentifiers

private final class FileNode: NSObject {
    let entry: RemoteEntry
    var children: [FileNode]?
    var readError: String?
    let placeholder: Bool
    init(_ entry: RemoteEntry, children: [FileNode]? = nil, placeholder: Bool = false) {
        self.entry = entry
        self.children = children
        self.placeholder = placeholder
    }
    static func loading() -> FileNode {
        FileNode(RemoteEntry(name: L("Wird geladen …"), path: "", isDirectory: false, size: 0), placeholder: true)
    }
    static func unreadable() -> FileNode {
        FileNode(RemoteEntry(name: L("Nicht lesbar – «Aktualisieren» zum Wiederholen"), path: "", isDirectory: false, size: 0), placeholder: true)
    }
}

private final class RemotePromiseWriter: NSObject, NSFilePromiseProviderDelegate {
    let entry: RemoteEntry
    let session: UUID
    var exportGroup = UUID()
    weak var owner: AppController?
    init(entry: RemoteEntry, session: UUID, owner: AppController) { self.entry = entry; self.session = session; self.owner = owner }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { entry.name }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        DispatchQueue.main.async { [self] in
            guard let owner else { completionHandler(M5Error.message(L("Die Verbindung ist nicht mehr verfügbar."))); return }
            owner.fulfillPromise(entry: entry, session: session, exportGroup: exportGroup, destination: url, completion: completionHandler)
        }
    }
}

private final class RetainedFilePromise: NSFilePromiseProvider {
    static let remoteMoveType = NSPasteboard.PasteboardType("org.m5filemanager.desktop.remote-move")
    var writer: RemotePromiseWriter?
    let moveToken = UUID().uuidString

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [Self.remoteMoveType]
    }
    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == Self.remoteMoveType ? moveToken : super.pasteboardPropertyList(forType: type)
    }
    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        type == Self.remoteMoveType ? [] : super.writingOptions(forType: type, pasteboard: pasteboard)
    }
}

final class AppController: NSObject, NSApplicationDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate, NSWindowDelegate, NSMenuDelegate, NSMenuItemValidation, NSSplitViewDelegate {
    private let service = DeviceService()
    private let deletionBackups = DeletionBackupPreferences()
    private let demo = CommandLine.arguments.contains("--demo")
    private var window: NSWindow!
    private var ports: [DevicePort] = []
    private var roots: [FileNode] = []
    private var loadingPaths: Set<String> = []
    private var session = UUID()
    private var awaitingStartup = false
    private var emptyTreeHint: String?
    private var storage: [String: StorageUsage] = [:]
    private struct RemoteDrag {
        let session: UUID
        let sequenceNumber: Int
        let tokens: [String]
        let nodes: [FileNode]
    }
    private var activeRemoteDrag: RemoteDrag?
    private var dragProviders: [String: RetainedFilePromise] = [:]
    private var promiseExportGroup: UUID?
    private var pendingPromiseExports = 0
    private var defersRefreshForMoveError = false
    private var documentWindows: [DocumentWindow] = []
    private var liveWatcher: LiveSyncWatcher?
    private var liveToken: UUID?
    private var liveGeneration = UUID()
    private var liveApplied: [String: Data] = [:]
    private var liveNotBefore = Date.distantPast
    private let liveLabel = NSTextField(labelWithString: L("Live-Sync: aus"))
    private var isQuitting = false
    private var isClosingMainWindow = false
    private var pendingIdleClose: (() -> Void)?
    private let portPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let scanButton = NSButton(title: L("USB suchen"), target: nil, action: nil)
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: L("Nicht verbunden"))
    private let hintLabel = NSTextField(wrappingLabelWithString: L("Beim Verbinden wird das Programm auf dem M5 angehalten. «Neu starten» startet MicroPython neu."))
    private let outline = NSOutlineView()
    private let uploadButton = NSButton(title: L("Hochladen …"), target: nil, action: nil)
    private let downloadButton = NSButton(title: L("Herunterladen …"), target: nil, action: nil)
    private let folderButton = NSButton(title: L("Neuer Ordner …"), target: nil, action: nil)
    private let mountSDButton = NSButton(title: L("SD einbinden"), target: nil, action: nil)
    private let refreshButton = NSButton(title: L("Aktualisieren"), target: nil, action: nil)
    private let backupButton = NSButton(title: "Backup …", target: nil, action: nil)
    private let actionsButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let destinationLabel = NSTextField(labelWithString: L("USB-Gerät auswählen und verbinden"))
    private let storageLabel = NSTextField(labelWithString: L("Speicher: noch nicht verbunden"))
    private let terminal = TerminalPanel()
    private let contentSplit = NSSplitView()
    private let commandField = NSTextField()
    private let sendButton = NSButton(title: L("Senden"), target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop / REPL", target: nil, action: nil)
    private let restartButton = NSButton(title: L("Neu starten"), target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private let terminalHint = NSTextField(labelWithString: L("Verbindung und Übertragungen erscheinen hier."))

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(self, selector: #selector(languageChanged), name: Localizer.changed, object: nil)
        buildMenu()
        buildWindow()
        bindService()
        if demo { loadDemo() } else { refreshPorts() }
        updateControls()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if demo, CommandLine.arguments.contains("--demo-editor"), let node = findNode("/flash/main.py") {
            let row = outline.row(forItem: node)
            if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); openSelectedDocument() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isQuitting, !isClosingMainWindow else { return .terminateCancel }
        guard !service.busy else { showBusyCloseAlert(); return .terminateCancel }
        guard !documentWindows.isEmpty else { return .terminateNow }
        isQuitting = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { sender.reply(toApplicationShouldTerminate: true); return }
            self.closeDocuments(Array(self.documentWindows)) { [weak self] closed in
                guard let self else { sender.reply(toApplicationShouldTerminate: closed); return }
                guard closed else {
                    self.isQuitting = false
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
                self.closeWhenIdle { [weak self] in
                    self?.isQuitting = false
                    sender.reply(toApplicationShouldTerminate: true)
                }
            }
        }
        return .terminateLater
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isQuitting, !isClosingMainWindow else { return false }
        guard !service.busy else { showBusyCloseAlert(); return false }
        if !documentWindows.isEmpty {
            isClosingMainWindow = true
            closeDocuments(Array(documentWindows)) { [weak self] closed in
                guard let self else { return }
                guard closed else { self.isClosingMainWindow = false; return }
                self.closeWhenIdle { [weak self] in
                    self?.isClosingMainWindow = false
                    self?.window.close()
                }
            }
            return false
        }
        return true
    }
    private func closeWhenIdle(_ action: @escaping () -> Void) {
        pendingIdleClose = action
        scheduleIdleClose()
    }
    private func scheduleIdleClose() {
        // onBusy(false) precedes operation callbacks, which may enqueue a refresh.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.service.busy, let action = self.pendingIdleClose else { return }
            self.pendingIdleClose = nil
            action()
        }
    }
    private func closeDocuments(_ documents: [DocumentWindow], completion: @escaping (Bool) -> Void) {
        guard let document = documents.first else { completion(true); return }
        document.showWindow(nil)
        document.requestClose { [weak self] closed in
            guard let self, closed else { completion(false); return }
            self.closeDocuments(Array(documents.dropFirst()), completion: completion)
        }
    }
    func applicationWillTerminate(_ notification: Notification) { if !demo { service.disconnect() } }
    private func showBusyCloseAlert() {
        guard window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = L("Übertragung läuft – bitte kurz warten")
        alert.informativeText = L("Der M5 ist noch beschäftigt. Sobald die aktuelle Aktion fertig ist, kannst du das Fenster schliessen oder die App beenden.")
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    private func buildMenu() {
        let main = NSMenu()
        let item = NSMenuItem()
        main.addItem(item)
        let app = NSMenu()
        app.addItem(withTitle: L("Über M5 File Manager"), action: #selector(showAbout), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: L("M5 File Manager beenden"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = app
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: L("Bearbeiten"))
        edit.addItem(withTitle: L("Widerrufen"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: L("Wiederholen"), action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: L("Ausschneiden"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("Kopieren"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("Einfügen"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("Alles auswählen"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        let deviceItem = NSMenuItem()
        let device = NSMenu(title: "M5")
        for (title, action, key) in [(L("Neu starten"), #selector(restartProgram), "r"), (L("Hochladen …"), #selector(uploadFiles), "u"), (L("Live-Sync aktivieren …"), #selector(startLiveSync), ""), (L("Live-Sync stoppen"), #selector(stopLiveSync), "")] {
            let entry = device.addItem(withTitle: title, action: action, keyEquivalent: key)
            entry.target = self
        }
        deviceItem.submenu = device; main.addItem(deviceItem)
        let languageItem = NSMenuItem()
        let languages = NSMenu(title: L("Sprache / Language"))
        for (name, code) in [("Deutsch", "de"), ("English", "en")] {
            let entry = languages.addItem(withTitle: name, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            entry.target = self; entry.representedObject = code
            entry.state = Localizer.language == code ? .on : .off
        }
        languageItem.submenu = languages; main.addItem(languageItem)
        NSApp.mainMenu = main
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard !service.busy, window.attachedSheet == nil, let code = sender.representedObject as? String else { return }
        Localizer.select(code)
    }

    @objc private func languageChanged() {
        // Existing windows and editor buffers are preserved. No device operation is queued.
        buildMenu()
        for current in NSApp.windows { Localizer.refresh(current) }
        updateControls(); updateStorageLabel()
        for row in 0..<outline.numberOfRows {
            if let node = outline.item(atRow: row) as? FileNode,
               let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView {
                cell.textField?.stringValue = displayName(node)
            }
        }
    }

    @objc private func showAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L("Entwicklung")
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "M5 File Manager", .applicationVersion: version, .credits: NSAttributedString(string: L("Dateien zwischen Mac und M5 bewegen.\nLokal per USB · MicroPython / UIFlow2"))])
    }

    private func button(_ button: NSButton, _ action: Selector, symbol: String? = nil) {
        InterfaceTheme.configure(button)
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.contentTintColor = .white
        if let symbol { button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); button.imagePosition = .imageLeading }
    }

    private func horizontal(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 900), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "M5 File Manager"
        window.minSize = NSSize(width: 950, height: 810)
        window.delegate = self
        window.center()
        let content = InterfaceBackground()
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = content
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
        ])
        let title = PixelTitleView()
        title.setAccessibilityElement(true)
        title.setAccessibilityLabel("M5 File Manager")
        title.setAccessibilityRole(.staticText)
        title.heightAnchor.constraint(equalToConstant: 78).isActive = true
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L("Entwicklung")
        let release = NSTextField(labelWithString: "v\(version) · USB · MicroPython · Flash & SD")
        release.font = .systemFont(ofSize: 12, weight: .semibold)
        release.textColor = InterfaceTheme.ink
        let heading = NSStackView(views: [title, release])
        heading.orientation = .vertical; heading.alignment = .leading; heading.spacing = 2
        heading.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = horizontal([heading, NSView()], spacing: 14)
        let card = NSBox()
        card.boxType = .custom; card.titlePosition = .noTitle
        card.fillColor = .white; card.borderColor = InterfaceTheme.ink
        card.borderWidth = 1.5; card.cornerRadius = 10
        card.contentViewMargins = NSSize(width: 14, height: 8)
        card.contentView = header
        stack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        card.heightAnchor.constraint(equalToConstant: 124).isActive = true
        title.widthAnchor.constraint(equalToConstant: 610).isActive = true
        let subtitle = NSTextField(labelWithString: L("USB verbinden · Flash & SD öffnen · Dateien rüberziehen"))
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = InterfaceTheme.ink
        stack.addArrangedSubview(subtitle)
        stack.setCustomSpacing(12, after: subtitle)

        button(scanButton, #selector(refreshPorts), symbol: "arrow.clockwise")
        button(connectButton, #selector(toggleConnection), symbol: "cable.connector")
        connectButton.bezelColor = InterfaceTheme.blue
        portPicker.toolTip = L("USB-Seriellgeräte. Der M5 muss MicroPython oder UIFlow2 ausführen.")
        portPicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let connectRow = horizontal([portPicker, scanButton, connectButton])
        stack.addArrangedSubview(connectRow)
        connectRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        statusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        statusLabel.textColor = .secondaryLabelColor
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        let statusRow = horizontal([statusLabel, NSView(), hintLabel], spacing: 16)
        stack.addArrangedSubview(statusRow)
        statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        hintLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 620).isActive = true

        let separator = NSBox()
        separator.boxType = .separator
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        button(uploadButton, #selector(uploadFiles), symbol: "arrow.up.doc")
        button(downloadButton, #selector(downloadSelected), symbol: "arrow.down.doc")
        button(folderButton, #selector(createFolder), symbol: "folder.badge.plus")
        button(mountSDButton, #selector(mountSDCard), symbol: "sdcard")
        mountSDButton.toolTip = L("Bindet die eingesteckte SD-Karte für diese Sitzung ein. Ändert den Autostart nicht.")
        button(refreshButton, #selector(refreshFiles), symbol: "arrow.clockwise")
        button(backupButton, #selector(backupDevice), symbol: "externaldrive.badge.timemachine")
        InterfaceTheme.configure(actionsButton)
        actionsButton.menu = makeFileMenu(includeTitle: true)
        let fileActions = horizontal([uploadButton, downloadButton, folderButton, backupButton, actionsButton, NSView(), mountSDButton, refreshButton], spacing: 6)
        stack.addArrangedSubview(fileActions)
        fileActions.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // The whole lower workspace flexes; headers and USB controls stay put.
        contentSplit.isVertical = false
        contentSplit.dividerStyle = .paneSplitter
        contentSplit.delegate = self
        contentSplit.toolTip = L("Trennlinie nach oben oder unten ziehen, um das Terminal zu vergrössern oder zu verkleinern.")
        contentSplit.setAccessibilityLabel(L("Dateibaum und Terminal – verschiebbare Trennlinie"))
        let filesPane = NSView(frame: NSRect(x: 0, y: 0, width: 1036, height: 285))
        let terminalPane = NSView(frame: NSRect(x: 0, y: 0, width: 1036, height: 250))
        func paneStack(in pane: NSView, top: CGFloat, bottom: CGFloat) -> NSStackView {
            let layout = NSStackView()
            layout.orientation = .vertical
            layout.alignment = .leading
            layout.spacing = 8
            layout.translatesAutoresizingMaskIntoConstraints = false
            pane.addSubview(layout)
            NSLayoutConstraint.activate([
                layout.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
                layout.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
                layout.topAnchor.constraint(equalTo: pane.topAnchor, constant: top),
                layout.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -bottom)
            ])
            return layout
        }
        let filesStack = paneStack(in: filesPane, top: 0, bottom: 6)
        let terminalStack = paneStack(in: terminalPane, top: 6, bottom: 0)
        contentSplit.frame = NSRect(x: 0, y: 0, width: 1036, height: 535 + contentSplit.dividerThickness)
        contentSplit.addArrangedSubview(filesPane)
        contentSplit.addArrangedSubview(terminalPane)
        contentSplit.setHoldingPriority(.init(250), forSubviewAt: 0)
        contentSplit.setHoldingPriority(.init(260), forSubviewAt: 1)
        contentSplit.autosaveName = "M5FilesTerminalSplit"
        stack.addArrangedSubview(contentSplit)
        NSLayoutConstraint.activate([
            contentSplit.widthAnchor.constraint(equalTo: stack.widthAnchor),
            filesPane.heightAnchor.constraint(greaterThanOrEqualToConstant: 175),
            terminalPane.heightAnchor.constraint(greaterThanOrEqualToConstant: 200)
        ])
        contentSplit.setContentHuggingPriority(.defaultLow, for: .vertical)

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = L("Flash & SD-Karte")
        nameColumn.width = 770
        nameColumn.minWidth = 350
        let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeColumn.title = L("Grösse")
        sizeColumn.width = 110
        sizeColumn.minWidth = 90
        sizeColumn.maxWidth = 130
        outline.addTableColumn(nameColumn)
        outline.addTableColumn(sizeColumn)
        outline.outlineTableColumn = nameColumn
        outline.delegate = self
        outline.dataSource = self
        outline.target = self
        outline.doubleAction = #selector(openSelectedDocument)
        outline.menu = makeFileMenu(includeTitle: false)
        outline.toolTip = L("Doppelklick öffnet Dateien. Ziehen in einen Ordner verschiebt innerhalb von Flash oder SD. Ziehen zum Finder oder vom Finder kopiert. Weitere Befehle unter «Aktionen» und per Rechtsklick.")
        outline.rowHeight = 29
        outline.intercellSpacing = NSSize(width: 10, height: 1)
        outline.usesAlternatingRowBackgroundColors = true
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.allowsMultipleSelection = true
        outline.registerForDraggedTypes([.fileURL, RetainedFilePromise.remoteMoveType])
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.autosaveExpandedItems = false
        let fileScroll = NSScrollView()
        fileScroll.documentView = outline
        fileScroll.hasVerticalScroller = true
        fileScroll.borderType = .bezelBorder
        filesStack.addArrangedSubview(fileScroll)
        NSLayoutConstraint.activate([fileScroll.widthAnchor.constraint(equalTo: filesStack.widthAnchor), fileScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 110)])
        fileScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        destinationLabel.font = .systemFont(ofSize: 11)
        destinationLabel.textColor = .secondaryLabelColor
        destinationLabel.lineBreakMode = .byTruncatingMiddle
        liveLabel.font = .systemFont(ofSize: 11, weight: .medium)
        liveLabel.lineBreakMode = .byTruncatingMiddle
        filesStack.addArrangedSubview(liveLabel)
        liveLabel.widthAnchor.constraint(equalTo: filesStack.widthAnchor).isActive = true
        filesStack.addArrangedSubview(destinationLabel)
        destinationLabel.widthAnchor.constraint(equalTo: filesStack.widthAnchor).isActive = true
        storageLabel.font = .systemFont(ofSize: 11, weight: .medium)
        storageLabel.textColor = .secondaryLabelColor
        storageLabel.lineBreakMode = .byTruncatingTail
        filesStack.addArrangedSubview(storageLabel)
        storageLabel.widthAnchor.constraint(equalTo: filesStack.widthAnchor).isActive = true
        filesStack.setCustomSpacing(4, after: destinationLabel)
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.isHidden = true
        filesStack.addArrangedSubview(progress)
        progress.widthAnchor.constraint(equalTo: filesStack.widthAnchor).isActive = true

        let terminalTitle = NSTextField(labelWithString: "Terminal")
        terminalTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        terminalHint.font = .systemFont(ofSize: 11)
        terminalHint.textColor = .secondaryLabelColor
        let terminalHeader = horizontal([terminalTitle, terminalHint, NSView()])
        terminalStack.addArrangedSubview(terminalHeader)
        terminalHeader.widthAnchor.constraint(equalTo: terminalStack.widthAnchor).isActive = true
        terminalStack.setCustomSpacing(6, after: terminalHeader)
        terminalStack.addArrangedSubview(terminal)
        terminal.widthAnchor.constraint(equalTo: terminalStack.widthAnchor).isActive = true
        terminal.setContentHuggingPriority(.defaultLow, for: .vertical)
        commandField.placeholderString = L("MicroPython-Befehl, z. B. print('Hallo M5')")
        commandField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        commandField.target = self
        commandField.action = #selector(sendCommand)
        commandField.delegate = self
        commandField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button(sendButton, #selector(sendCommand), symbol: "paperplane")
        button(stopButton, #selector(interruptProgram))
        button(restartButton, #selector(restartProgram), symbol: "restart")
        let commandRow = horizontal([commandField, sendButton, stopButton, restartButton])
        terminalStack.addArrangedSubview(commandRow)
        commandRow.widthAnchor.constraint(equalTo: terminalStack.widthAnchor).isActive = true
        appendLog(L("M5 File Manager bereit. USB-Gerät auswählen und Connect drücken.\n"))
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, 175)
    }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, max(175, splitView.bounds.height - splitView.dividerThickness - 200))
    }

    private func bindService() {
        service.onLogEvent = { [weak self] event in self?.terminal.append(event) }
        service.onState = { [weak self] state in self?.statusLabel.stringValue = state }
        service.onConnection = { [weak self] connected in
            guard let self else { return }
            self.awaitingStartup = false
            self.emptyTreeHint = nil
            if !connected {
                self.stopLiveSync()
                self.session = UUID()
                self.clearRemoteDrag()
                self.roots = []
                self.loadingPaths.removeAll()
                self.storage = [:]
                self.documentWindows.forEach { $0.invalidate(L("Die USB-Verbindung wurde beendet.")) }
                self.outline.reloadData()
            }
            self.statusLabel.textColor = connected ? .systemGreen : .secondaryLabelColor
            self.terminalHint.stringValue = connected ? L("Dateizugriff hält dein M5-Programm an. «Neu starten» startet MicroPython neu.") : L("Verbindung und Übertragungen erscheinen hier.")
            self.updateControls()
        }
        service.onBusy = { [weak self] busy in
            guard let self else { return }
            self.progress.isHidden = !busy
            if !busy { self.progress.doubleValue = 0 }
            self.updateControls()
            self.documentWindows.forEach { $0.setDeviceAvailable(self.service.connected && !busy && !self.demo) }
            if !busy { self.scheduleIdleClose() }
        }
        service.onProgress = { [weak self] value in self?.progress.doubleValue = value }
        service.onRefresh = { [weak self] in
            guard let self, !self.defersRefreshForMoveError else { return }
            self.refreshFiles()
        }
        service.onRestart = { [weak self] in
            self?.invalidateRunningState(status: L("Verbunden · Neustart angefordert"), hint: L("Gerät fertig starten lassen, dann «Aktualisieren». Dateizugriff unterbricht das Startprogramm."))
        }
        service.onProgramStarted = { [weak self] path in
            self?.invalidateRunningState(status: L("Programmstart angefordert"), hint: L("Start angefordert: {0}. Die Ausgabe erscheint im Terminal. Dateizugriff hält das Programm wieder an.", String(describing: (path))))
        }
    }

    private func invalidateRunningState(status: String, hint: String) {
        session = UUID()
        clearRemoteDrag()
        roots = []
        loadingPaths.removeAll()
        storage = [:]
        awaitingStartup = true
        emptyTreeHint = hint
        documentWindows.forEach { $0.invalidate(L("Auf dem M5 wurde ein Programmstart oder Neustart angefordert.")) }
        outline.reloadData()
        statusLabel.stringValue = status
        terminalHint.stringValue = L("Dateizugriff unterbricht das laufende Programm.")
        updateControls()
    }

    private func appendLog(_ message: String, kind: LogKind = .info) {
        terminal.append(LogEvent(kind: kind, text: message))
    }

    private func makeFileMenu(includeTitle: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        if includeTitle { menu.addItem(withTitle: L("Aktionen"), action: nil, keyEquivalent: "") }
        let actions: [(String, Selector)] = [
            (L("Öffnen / bearbeiten …"), #selector(openSelectedDocument)),
            (L("Python-Datei starten …"), #selector(runSelected)),
            (L("Als Autostart einrichten …"), #selector(setSelectedAutostart)),
            (L("UIFlow-Startmenü aktivieren …"), #selector(enableStartupMenu)),
            (L("Umbenennen …"), #selector(renameSelected)),
            (L("Löschen …"), #selector(deleteSelected))
        ]
        for (title, action) in actions {
            if action == #selector(renameSelected) { menu.addItem(.separator()) }
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        menu.addItem(.separator())
        let backups = menu.addItem(withTitle: L("Sicherungen im Finder zeigen"), action: #selector(revealSafetyBackups), keyEquivalent: "")
        backups.target = self
        let chooseDeletion = menu.addItem(withTitle: L("Ordner für Lösch-Sicherungen wählen …"), action: #selector(configureDeletionBackups), keyEquivalent: "")
        chooseDeletion.target = self
        let revealDeletion = menu.addItem(withTitle: L("Lösch-Sicherungen im Finder zeigen"), action: #selector(revealDeletionBackups), keyEquivalent: "")
        revealDeletion.target = self
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === outline.menu {
            if outline.clickedRow >= 0, let node = outline.item(atRow: outline.clickedRow) as? FileNode, !node.placeholder {
                if !outline.selectedRowIndexes.contains(outline.clickedRow) {
                    outline.selectRowIndexes(IndexSet(integer: outline.clickedRow), byExtendingSelection: false)
                }
            } else { outline.deselectAll(nil) }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(selectLanguage(_:)) { return !service.busy && window.attachedSheet == nil }

        if menuItem.action == #selector(stopLiveSync) { return liveWatcher != nil }
        if menuItem.action == #selector(startLiveSync) { return liveWatcher == nil && !demo && service.connected && !service.busy && selectedDirectory() != nil }
        if menuItem.action == #selector(restartProgram) { return !demo && service.connected && !service.busy }
        if menuItem.action == #selector(uploadFiles) { return !demo && service.connected && !service.busy && selectedDirectory() != nil }
        let fileActions = [#selector(openSelectedDocument), #selector(runSelected), #selector(setSelectedAutostart), #selector(enableStartupMenu), #selector(renameSelected), #selector(deleteSelected), #selector(revealSafetyBackups), #selector(configureDeletionBackups), #selector(revealDeletionBackups)]
        guard let action = menuItem.action, fileActions.contains(action) else { return true }
        if menuItem.action == #selector(revealSafetyBackups) { return !demo }
        if menuItem.action == #selector(configureDeletionBackups) || menuItem.action == #selector(revealDeletionBackups) { return !demo }
        if menuItem.action == #selector(enableStartupMenu) { return !demo && service.connected && !service.busy }
        guard outline.numberOfSelectedRows == 1, let node = selectedNode(), isUsable(node), !isVolume(node) else { return false }
        if menuItem.action == #selector(openSelectedDocument) {
            return !node.entry.isDirectory && editableExtension(node.entry.name) && (demo || (service.connected && !service.busy))
        }
        guard !demo, service.connected, !service.busy else { return false }
        if menuItem.action == #selector(runSelected) || menuItem.action == #selector(setSelectedAutostart) {
            return !node.entry.isDirectory && (node.entry.name as NSString).pathExtension.lowercased() == "py"
        }
        return true
    }

    private func editableExtension(_ name: String) -> Bool {
        ["py", "txt", "json", "csv", "png", "jpg", "jpeg", "bmp"].contains((name as NSString).pathExtension.lowercased())
    }

    private func displayName(_ node: FileNode) -> String {
        if isVolume(node), node.entry.path == "/sd" { return L("SD-Karte") }
        return node.placeholder ? Localizer.displayed(node.entry.name) : node.entry.name
    }

    private func updateStorageLabel() {
        guard !roots.isEmpty else { storageLabel.stringValue = service.connected ? L("Speicher: nach «Aktualisieren» verfügbar") : L("Speicher: noch nicht verbunden"); return }
        var descriptions = roots.map { root in
            guard let usage = storage[root.entry.path] else { return L("{0}: Kapazität nicht verfügbar", String(describing: (displayName(root)))) }
            let free = ByteCountFormatter.string(fromByteCount: usage.freeBytes, countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: usage.totalBytes, countStyle: .file)
            return L("{0}: {1} von {2} frei", String(describing: (displayName(root))), String(describing: (free)), String(describing: (total)))
        }
        if !roots.contains(where: { $0.entry.path == "/sd" }) {
            descriptions.append(L("SD nicht verfügbar · «SD einbinden»"))
        }
        storageLabel.stringValue = descriptions.joined(separator: "   ·   ") + (demo ? L("   ·   Beispielwerte") : "")
    }

    @objc private func openSelectedDocument() {
        guard outline.numberOfSelectedRows == 1, let node = selectedNode(), isUsable(node) else { return }
        if node.entry.isDirectory {
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
            return
        }
        guard editableExtension(node.entry.name), !isVolume(node) else { return }
        if let existing = documentWindows.first(where: { $0.remotePath == node.entry.path && !$0.isInvalidated }) {
            existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return
        }
        if demo {
            let sample = (node.entry.name as NSString).pathExtension.lowercased() == "py" ? "# Sample held only in the Mac memory.\nfrom time import sleep\n\nfor number in range(5):\n    print('Hello M5!', number)\n    sleep(1)\n" : "zeit,temperatur\n08:00,21.4\n09:00,22.1\n"
            showDocument(RemoteDocument(entry: node.entry, original: Data(sample.utf8), text: sample, connectionID: UUID()))
            return
        }
        guard service.connected, !service.busy else { return }
        let token = session
        if ["png", "jpg", "jpeg", "bmp"].contains((node.entry.name as NSString).pathExtension.lowercased()) {
            service.previewImage(entry: node.entry) { [weak self] result in
                guard let self, self.session == token else { return }
                do { try PreviewWindow.show(name: node.entry.name, data: result.get()) }
                catch { self.showError(error) }
            }
            return
        }
        service.openDocument(entry: node.entry) { [weak self] result in
            guard let self, self.session == token else { return }
            switch result {
            case .success(let document): self.showDocument(document)
            case .failure(let error): self.showError(error)
            }
        }
    }

    private func showDocument(_ document: RemoteDocument) {
        let controller = DocumentWindow(document: document, demo: demo)
        controller.onSave = { [weak self] document, text, completion in
            guard let self, !self.demo, self.service.connected, !self.service.busy else {
                completion(.failure(M5Error.message(L("Der M5 ist nicht verbunden oder noch beschäftigt. Dein Text bleibt im Editor.")))); return
            }
            self.service.saveDocument(document, text: text, completion: completion)
        }
        controller.onCheck = { [weak self] document, text, completion in
            guard let self, !self.demo, self.service.connected, !self.service.busy else {
                completion(.failure(M5Error.message(L("M5 nicht verfügbar oder beschäftigt.")))); return
            }
            self.service.checkDocument(document, text: text, completion: completion)
        }
        controller.onClose = { [weak self, weak controller] in
            self?.documentWindows.removeAll(where: { $0 === controller })
        }
        documentWindows.append(controller)
        controller.setDeviceAvailable(service.connected && !service.busy && !demo)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func backupDevice() {
        guard !demo, service.connected, !service.busy, !roots.isEmpty else { return }
        if let path = UserDefaults.standard.string(forKey: "backupDestinationPath"), FileManager.default.fileExists(atPath: path) {
            confirmBackup(to: URL(fileURLWithPath: path, isDirectory: true))
        } else { chooseBackupFolder() }
    }

    private func chooseBackupFolder() {
        let panel = NSOpenPanel()
        panel.title = L("Ordner für M5-Dateisicherungen wählen")
        panel.prompt = L("Diesen Ordner merken")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let destination = panel.url else { return }
            UserDefaults.standard.set(destination.path, forKey: "backupDestinationPath")
            self.confirmBackup(to: destination)
        }
    }

    private func confirmBackup(to destination: URL) {
        let alert = NSAlert()
        alert.messageText = L("M5-Dateien auf dem Mac sichern")
        alert.informativeText = L("Flash-Dateien werden in einen neuen Sicherungsordner kopiert. Ziel:\n{0}\n\nDies ist eine Dateisicherung; die Firmware ist nicht enthalten.", String(describing: (destination.path)))
        alert.addButton(withTitle: L("Abbrechen"))
        alert.addButton(withTitle: L("Backup starten"))
        alert.addButton(withTitle: L("Anderer Ordner …"))
        let includeSD = NSButton(checkboxWithTitle: L("SD-Karte ebenfalls sichern"), target: nil, action: nil)
        includeSD.state = UserDefaults.standard.bool(forKey: "backupIncludeSD") ? .on : .off
        includeSD.isEnabled = roots.contains(where: { $0.entry.path == "/sd" && isUsable($0) })
        if !includeSD.isEnabled { includeSD.state = .off }
        alert.accessoryView = includeSD
        let token = session
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertThirdButtonReturn { self.chooseBackupFolder(); return }
            guard response == .alertSecondButtonReturn, self.session == token, self.service.connected, !self.service.busy else { return }
            let sd = includeSD.state == .on
            UserDefaults.standard.set(sd, forKey: "backupIncludeSD")
            self.service.backup(includeSD: sd, to: destination) { [weak self] result in
                switch result {
                case .success(let report):
                    self?.appendLog(L("Backup fertig: {0} Dateien unter {1}\n", String(describing: (report.fileCount)), String(describing: (report.directory.path))))
                    NSWorkspace.shared.activateFileViewerSelecting([report.directory])
                case .failure(let error): self?.showError(error)
                }
            }
        }
    }

    private func actionableEntry() -> RemoteEntry? {
        guard !demo, service.connected, !service.busy, outline.numberOfSelectedRows == 1,
              let node = selectedNode(), isUsable(node), !isVolume(node) else { return nil }
        return node.entry
    }

    @objc private func renameSelected() {
        guard let entry = actionableEntry() else { return }
        let alert = NSAlert()
        alert.messageText = L("«{0}» umbenennen", String(describing: (entry.name)))
        alert.informativeText = L("Der Name wird auf dem M5 geändert. Vorhandene Ziele werden nicht überschrieben.")
        alert.addButton(withTitle: L("Abbrechen"))
        alert.addButton(withTitle: L("Umbenennen"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 350, height: 24))
        field.stringValue = entry.name
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let token = session
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertSecondButtonReturn, self.session == token, !self.service.busy else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            self.service.rename(entry: entry, newName: name) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success: self.invalidateDocuments(under: entry.path, reason: L("Die Datei oder ihr Ordner wurde umbenannt."))
                case .failure(let error): self.showError(error)
                }
            }
        }
    }

    @objc private func deleteSelected() {
        guard let entry = actionableEntry() else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("«{0}» vom M5 löschen?", String(describing: (entry.name)))
        alert.informativeText = (entry.isDirectory ? L("Dieser Ordner und alle enthaltenen Dateien werden gelöscht.") : L("Die Datei wird vom M5 gelöscht.")) + L(" Mit aktivierter Sicherung wird zuerst eine Kopie auf dem Mac erstellt; schlägt sie fehl, wird nichts gelöscht. Ohne Sicherung kann die Löschung nicht rückgängig gemacht werden.")
        alert.addButton(withTitle: L("Abbrechen"))
        alert.addButton(withTitle: L("Löschen"))
        let options = DeletionBackupAccessory(directory: deletionBackups.directory)
        alert.accessoryView = options
        options.onValidityChanged = { [weak alert, weak options] in
            alert?.buttons.last?.isEnabled = options?.canDelete ?? false
        }
        options.onChooseDirectory = { [weak self, weak alert, weak options] in
            guard let self, let alert else { return }
            self.chooseDeletionBackupFolder(in: alert.window) { directory in options?.directory = directory }
        }
        alert.buttons.last?.isEnabled = options.canDelete
        let token = session
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertSecondButtonReturn, options.canDelete,
                  self.session == token, !self.service.busy else { return }
            self.service.delete(entry: entry, backupFirst: options.backupFirst,
                                backupDestination: options.backupFirst ? options.directory : nil) { [weak self] result in
                guard let self else { return }
                self.invalidateDocuments(under: entry.path, reason: L("Für diese Datei oder ihren Ordner wurde ein Löschauftrag ausgeführt."))
                switch result {
                case .success(let backup): if let backup { self.appendLog(L("Sicherung vor dem Löschen: {0}\n", String(describing: (backup.path)))) }
                case .failure(let error): self.showError(error)
                }
            }
        }
    }

    @objc private func configureDeletionBackups() {
        guard !demo else { return }
        chooseDeletionBackupFolder(in: window)
    }

    private func chooseDeletionBackupFolder(in owner: NSWindow, completion: ((URL) -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.title = L("Ordner für Lösch-Sicherungen wählen")
        panel.prompt = L("Diesen Ordner merken")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = deletionBackups.directory
        panel.beginSheetModal(for: owner) { [weak self] response in
            guard let self, response == .OK, let directory = panel.url else { return }
            do {
                try self.deletionBackups.select(directory)
                self.appendLog(L("Ordner für Lösch-Sicherungen auf diesem Mac: {0}\n", String(describing: (self.deletionBackups.directory.path))))
                completion?(self.deletionBackups.directory)
            } catch {
                let alert = NSAlert(error: error)
                alert.beginSheetModal(for: owner)
            }
        }
    }

    @objc private func revealDeletionBackups() {
        guard !demo else { return }
        let directory = deletionBackups.directory
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            showError(M5Error.message(L("Der Ordner für Lösch-Sicherungen ist nicht erreichbar:\n{0}\n\nUnter «Aktionen → Ordner für Lösch-Sicherungen wählen …» kannst du einen verfügbaren Ordner auswählen.", String(describing: (directory.path)))))
            return
        }
        NSWorkspace.shared.open(directory)
    }

    private func invalidateDocuments(under path: String, reason: String) {
        documentWindows.filter { $0.remotePath == path || $0.remotePath.hasPrefix(path + "/") }.forEach { $0.invalidate(reason) }
    }

    @objc private func runSelected() {
        guard let entry = actionableEntry(), !entry.isDirectory, (entry.name as NSString).pathExtension.lowercased() == "py" else { return }
        let alert = NSAlert()
        alert.messageText = L("«{0}» jetzt starten?", String(describing: (entry.name)))
        alert.informativeText = L("Das bisherige Python-Programm wird angehalten. Es wird die gespeicherte Datei auf dem M5 gestartet; ungespeicherter Editortext wird nicht übertragen. Der Dateibaum wird danach geleert, damit kein automatischer Zugriff das Programm unterbricht.")
        alert.addButton(withTitle: L("Abbrechen"))
        alert.addButton(withTitle: L("Starten"))
        let token = session
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertSecondButtonReturn, self.session == token, !self.service.busy else { return }
            self.service.run(entry: entry) { [weak self] result in if case .failure(let error) = result { self?.showError(error) } }
        }
    }

    @objc private func setSelectedAutostart() {
        guard let entry = actionableEntry(), !entry.isDirectory, (entry.name as NSString).pathExtension.lowercased() == "py" else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("«{0}» als Autostart einrichten?", String(describing: (entry.name)))
        alert.informativeText = L("Die bisherige main.py im Flash wird nach lokaler Sicherung durch einen Startaufruf für «{0}» ersetzt. Ist dies bereits main.py, bleibt ihr Inhalt erhalten. Bei UIFlow wird zudem «main.py direkt starten» aktiviert: Das Startmenü wird übersprungen. Wirksam erst beim nächsten Neustart; boot.py bleibt unverändert. Das Programm muss benötigte Hardware und Netzwerkverbindungen gegebenenfalls selbst initialisieren.", String(describing: (entry.path)))
        if entry.path.hasPrefix("/sd/") {
            alert.informativeText += L("\n\nDiese Datei liegt auf SD: Die Karte muss bereits beim Programmstart eingebunden sein. Eine nur eingesteckte Karte genügt dafür nicht.")
        }
        alert.addButton(withTitle: L("Abbrechen"))
        alert.addButton(withTitle: L("Autostart einrichten"))
        let token = session
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertSecondButtonReturn, self.session == token, !self.service.busy else { return }
            self.service.setAutostart(entry: entry) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let backup):
                    self.documentWindows.filter { ($0.remotePath as NSString).lastPathComponent == "main.py" }.forEach { $0.invalidate(L("Der Autostart wurde geändert.")) }
                    self.appendLog(L("Autostart eingerichtet; kein Neustart ausgelöst.\n"))
                    if let backup { self.appendLog(L("Vorheriger Autostart gesichert: {0}\n", String(describing: (backup.path)))) }
                case .failure(let error): self.showError(error)
                }
            }
        }
    }

    @objc private func revealSafetyBackups() {
        guard FileManager.default.fileExists(atPath: service.backupDirectory.path) else {
            showError(M5Error.message(L("Es gibt noch keine lokalen Sicherheitssicherungen. Sie entstehen beim Speichern, beim Löschen mit Sicherung und beim Einrichten eines Autostarts."))); return
        }
        NSWorkspace.shared.open(service.backupDirectory)
    }

    @objc private func enableStartupMenu() {
        guard !demo, service.connected, !service.busy else { return }
        let alert = NSAlert()
        alert.messageText = L("UIFlow-Startmenü aktivieren?")
        alert.informativeText = L("Beim nächsten Neustart wird wieder das UIFlow-Startmenü angezeigt. main.py bleibt erhalten. Es erfolgt kein sofortiger Neustart.")
        alert.addButton(withTitle: L("Abbrechen"))
        alert.addButton(withTitle: L("Startmenü aktivieren"))
        let token = session
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertSecondButtonReturn, self.session == token, !self.service.busy else { return }
            self.service.showStartupMenu { [weak self] result in
                switch result {
                case .success: self?.appendLog(L("UIFlow-Startmenü für den nächsten Neustart aktiviert.\n"))
                case .failure(let error): self?.showError(error)
                }
            }
        }
    }

    @objc private func refreshPorts() {
        let prior = portPicker.indexOfSelectedItem
        let previousPath = ports.indices.contains(prior) ? ports[prior].path : nil
        ports = service.ports()
        portPicker.removeAllItems()
        if ports.isEmpty { portPicker.addItem(withTitle: L("Kein USB-Seriellgerät gefunden")) }
        else {
            portPicker.addItems(withTitles: ports.map(\.title))
            if let index = ports.firstIndex(where: { $0.path == previousPath }) { portPicker.selectItem(at: index) }
            else {
                let candidates = ports.indices.filter { ports[$0].vendorID == 0x303a }
                if candidates.count == 1 { portPicker.selectItem(at: candidates[0]) }
            }
        }
        updateControls()
    }

    private func updateControls() {
        let connected = service.connected && !demo
        let available = connected && !service.busy
        portPicker.isEnabled = !connected && !demo && !service.busy && !ports.isEmpty
        scanButton.isEnabled = !connected && !demo && !service.busy
        connectButton.title = connected ? "Disconnect" : "Connect"
        connectButton.isEnabled = !demo && !service.busy && (connected || !ports.isEmpty)
        uploadButton.isEnabled = available && selectedDirectory() != nil
        downloadButton.isEnabled = available && outline.numberOfSelectedRows == 1 && isUsable(selectedNode()) && !isVolume(selectedNode())
        folderButton.isEnabled = available && selectedDirectory() != nil
        mountSDButton.isEnabled = available
        refreshButton.isEnabled = available
        backupButton.isEnabled = available && !roots.isEmpty
        actionsButton.isEnabled = !service.busy
        commandField.isEnabled = available
        sendButton.isEnabled = available
        stopButton.isEnabled = available
        restartButton.isEnabled = available
        if outline.numberOfSelectedRows > 1 {
            destinationLabel.stringValue = L("{0} ausgewählt · In einen Ordner ziehen zum Verschieben · In den Finder ziehen zum Kopieren", String(describing: (outline.numberOfSelectedRows)))
        } else if let directory = selectedDirectory() {
            destinationLabel.stringValue = L("Ziel: {0}   ·   Dateien vom Finder hierher ziehen · M5-Dateien in den Finder ziehen", String(describing: (directory)))
        } else if awaitingStartup {
            destinationLabel.stringValue = emptyTreeHint ?? L("Gerät fertig starten lassen, dann «Aktualisieren». Dateizugriff unterbricht das Startprogramm.")
        } else if selectedNode()?.readError != nil {
            destinationLabel.stringValue = L("Ordner momentan nicht lesbar · «Aktualisieren» prüft Speicher und Dateien erneut")
        } else { destinationLabel.stringValue = demo ? L("Vorschau mit Beispieldateien · keine USB-Verbindung") : L("Ordner wählen zum Hochladen · Dateien und Ordner per Drag & Drop kopieren") }
        updateStorageLabel()
    }

    @objc private func toggleConnection() {
        if service.connected { service.disconnect(); return }
        let index = portPicker.indexOfSelectedItem
        guard ports.indices.contains(index) else { return }
        let token = UUID()
        session = token
        service.connect(path: ports[index].path) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let volumes):
                guard self.session == token else { return }
                self.roots = volumes.map { FileNode(RemoteEntry(name: $0.name, path: $0.path, isDirectory: true, size: 0)) }
                self.outline.reloadData()
                self.updateControls()
                self.refreshFiles()
            case .failure(let error): self.showError(error)
            }
        }
    }

    private func selectedNode() -> FileNode? {
        guard outline.selectedRow >= 0, let node = outline.item(atRow: outline.selectedRow) as? FileNode, !node.placeholder else { return nil }
        return node
    }
    private func isVolume(_ node: FileNode?) -> Bool { guard let node else { return false }; return roots.contains(where: { $0 === node }) }
    private func isUsable(_ node: FileNode?) -> Bool {
        guard let node else { return false }
        return !node.placeholder && node.readError == nil && findNode(node.entry.path) === node
    }
    private func selectedDirectory() -> String? {
        guard outline.numberOfSelectedRows <= 1 else { return nil }
        guard let node = selectedNode() else { return roots.first(where: { isUsable($0) })?.entry.path }
        guard isUsable(node) else { return nil }
        return node.entry.isDirectory ? node.entry.path : parentPath(node.entry.path)
    }
    private func parentPath(_ path: String) -> String { let parent = (path as NSString).deletingLastPathComponent; return parent.isEmpty ? "/" : parent }

    @objc private func mountSDCard() {
        guard !demo, service.connected, !service.busy else { return }
        let token = session
        service.mountSDCard { [weak self] result in
            guard let self, self.session == token else { return }
            switch result {
            case .success: self.refreshFiles()
            case .failure(let error):
                // Refresh after dismissing the error so a second read error
                // cannot open another sheet over the mount failure.
                self.showError(error) { [weak self] in
                    guard let self, self.session == token else { return }
                    self.refreshFiles()
                }
            }
        }
    }

    @objc private func refreshFiles() {
        guard service.connected, !service.busy else { return }
        let token = session
        let selectedPath = selectedNode()?.entry.path
        var expanded = Set<String>()
        for row in 0..<outline.numberOfRows {
            if let node = outline.item(atRow: row) as? FileNode, node.entry.isDirectory, outline.isItemExpanded(node) {
                expanded.insert(node.entry.path)
            }
        }
        var paths = expanded
        if let node = selectedNode() {
            // A failed folder must stay retryable even while file actions are disabled.
            paths.insert(node.entry.isDirectory ? node.entry.path : parentPath(node.entry.path))
        }
        service.refresh(paths: Array(paths)) { [weak self] result in
            guard let self, self.session == token else { return }
            switch result {
            case .success(let snapshot):
                self.applyRefresh(snapshot, expanded: expanded, selectedPath: selectedPath)
            case .failure(let error):
                self.storage = [:]
                for root in self.roots { self.markUnreadable(root, error: error) }
                self.outline.reloadData()
                self.updateControls()
                self.showError(error)
            }
        }
    }

    private func applyRefresh(_ snapshot: FileTreeRefresh, expanded: Set<String>, selectedPath: String?) {
        awaitingStartup = false
        emptyTreeHint = nil
        storage = snapshot.storage
        terminalHint.stringValue = L("Dateizugriff hält dein M5-Programm an. «Neu starten» startet MicroPython neu.")
        let previousRoots = roots
        roots = snapshot.volumes.map { volume in
            previousRoots.first(where: { $0.entry.path == volume.path }) ?? FileNode(RemoteEntry(name: volume.name, path: volume.path, isDirectory: true, size: 0))
        }
        var errors: [Error] = []
        // Parents establish which child nodes still exist before child listings apply.
        for path in snapshot.directories.keys.sorted(by: { left, right in
            let leftDepth = left.split(separator: "/").count
            let rightDepth = right.split(separator: "/").count
            return leftDepth == rightDepth ? left < right : leftDepth < rightDepth
        }) {
            guard let node = findNode(path), let result = snapshot.directories[path] else { continue }
            switch result {
            case .success(let entries): applyEntries(entries, to: node)
            case .failure(let error): markUnreadable(node, error: error); errors.append(error)
            }
        }
        outline.reloadData()
        for path in expanded.sorted(by: { $0.count < $1.count }) {
            if let node = findNode(path) { outline.expandItem(node) }
        }
        let selection = selectedPath.flatMap { findNode($0) } ?? roots.first(where: { isUsable($0) }) ?? roots.first
        if let selection {
            // A removed SD selection falls back explicitly to the available Flash.
            var ancestors: [FileNode] = []
            var path = selection.entry.path
            while path != "/" {
                path = parentPath(path)
                if let ancestor = findNode(path) { ancestors.append(ancestor) }
            }
            for ancestor in ancestors.reversed() { outline.expandItem(ancestor) }
            if isVolume(selection), isUsable(selection) { outline.expandItem(selection) }
            let row = outline.row(forItem: selection)
            if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        } else { outline.deselectAll(nil) }
        updateControls()
        for error in errors.dropFirst() { appendLog(L("Hinweis: {0}\n", String(describing: (error.localizedDescription)))) }
        if let error = errors.first { showError(error) }
    }

    private func applyEntries(_ entries: [RemoteEntry], to node: FileNode) {
        let previous = node.children ?? []
        node.readError = nil
        // A separately displayed volume must not also appear below Flash at /.
        node.children = entries.filter { entry in !roots.contains(where: { $0.entry.path == entry.path }) }.sorted { left, right in
            left.isDirectory != right.isDirectory ? left.isDirectory : left.name.localizedStandardCompare(right.name) == .orderedAscending
        }.map { entry in
            let child = FileNode(entry)
            if let existing = previous.first(where: { !$0.placeholder && $0.entry.path == entry.path && $0.entry.isDirectory == entry.isDirectory }) {
                child.children = existing.children
                child.readError = existing.readError
            }
            return child
        }
    }

    private func markUnreadable(_ node: FileNode, error: Error) {
        node.readError = error.localizedDescription
        node.children = [FileNode.unreadable()]
    }
    private func findNode(_ path: String) -> FileNode? {
        if let root = roots.first(where: { $0.entry.path == path }) { return root }
        func search(_ nodes: [FileNode]) -> FileNode? {
            for node in nodes { if node.entry.path == path { return node }; if let found = search(node.children ?? []) { return found } }
            return nil
        }
        return search(roots)
    }
    private func load(_ node: FileNode, force: Bool = false) {
        guard !demo, service.connected, !service.busy, node.entry.isDirectory, !loadingPaths.contains(node.entry.path), force || node.children == nil else { return }
        let token = session
        let path = node.entry.path
        loadingPaths.insert(path)
        service.list(path: path) { [weak self, weak node] result in
            guard let self, self.session == token, let node else { return }
            self.loadingPaths.remove(path)
            guard self.findNode(path) === node else { return }
            switch result {
            case .success(let entries):
                self.applyEntries(entries, to: node)
                self.outline.reloadItem(node, reloadChildren: true)
            case .failure(let error):
                self.markUnreadable(node, error: error)
                self.outline.reloadItem(node, reloadChildren: true)
                self.showError(error)
            }
            self.updateControls()
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? FileNode else { return roots.count }
        return node.entry.isDirectory ? (node.children?.count ?? 1) : 0
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? FileNode else { return roots[index] }
        return node.children?[index] ?? FileNode.loading()
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? FileNode)?.entry.isDirectory ?? false }
    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let node = item as? FileNode else { return false }
        return !service.busy || node.children != nil
    }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { (item as? FileNode)?.placeholder == false }
    func outlineViewItemWillExpand(_ notification: Notification) { if let node = notification.userInfo?["NSObject"] as? FileNode { load(node) } }
    func outlineViewSelectionDidChange(_ notification: Notification) { updateControls() }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        if tableColumn?.identifier.rawValue == "size" {
            let label = NSTextField(labelWithString: node.entry.isDirectory || node.placeholder ? "—" : ByteCountFormatter.string(fromByteCount: node.entry.size, countStyle: .file))
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            return label
        }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: displayName(node))
        label.font = .systemFont(ofSize: 13, weight: isVolume(node) ? .semibold : .regular)
        label.textColor = node.readError != nil ? .systemOrange : (node.placeholder ? .secondaryLabelColor : .labelColor)
        label.toolTip = node.readError
        label.lineBreakMode = .byTruncatingMiddle
        let icon = NSImageView()
        let symbol = isVolume(node) ? (node.entry.path.lowercased().contains("sd") ? "sdcard" : "internaldrive") : (node.entry.isDirectory ? "folder.fill" : "doc")
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = node.entry.isDirectory ? .controlAccentColor : .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(icon)
        cell.addSubview(label)
        cell.textField = label
        cell.imageView = icon
        NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 18), icon.heightAnchor.constraint(equalToConstant: 18), label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5)])
        return cell
    }

    @objc private func stopLiveSync() {
        liveGeneration = UUID(); liveWatcher = nil; liveToken = nil; liveApplied = [:]
        liveLabel.stringValue = L("Live-Sync: aus")
    }

    @objc private func startLiveSync() {
        guard !demo, service.connected, !service.busy, liveWatcher == nil,
              let directory = selectedDirectory() else { return }
        let panel = NSOpenPanel()
        panel.title = L("Mac-Ordner für Live-Sync nach {0} wählen", String(describing: (directory)))
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let root = panel.url else { return }
            let alert = NSAlert()
            alert.messageText = L("Live-Sync mit automatischem Neustart aktivieren?")
            alert.informativeText = L("Mac: {0}\nM5: {1}\n\nAlle sichtbaren Dateien inklusive Unterordner werden zuerst übertragen. Vorhandene M5-Dateien werden lokal gesichert. Danach werden Änderungen nach zwei stabilen Sekunden übertragen und das Board neu gestartet. Dateizugriff stoppt Python. Lokale Löschungen löschen nichts auf dem M5. Konflikte stoppen Live-Sync. Grenzen: 128 Dateien, je 1 MiB, insgesamt 8 MiB; keine Symlinks.", String(describing: (root.path)), String(describing: (directory)))
            alert.addButton(withTitle: L("Abbrechen")); alert.addButton(withTitle: L("Live-Sync aktivieren"))
            alert.beginSheetModal(for: self.window) { [weak self] response in
                guard let self, response == .alertSecondButtonReturn, self.service.connected, !self.service.busy else { return }
                self.activateLiveSync(root: root, directory: directory)
            }
        }
    }

    private func activateLiveSync(root: URL, directory: String) {
        let generation = UUID(); liveGeneration = generation
        liveLabel.stringValue = L("Live-Sync: Ausgangsstand lesen …")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snapshot = Result { try LiveSnapshot.read(root: root) }
            DispatchQueue.main.async {
                guard let self, self.liveGeneration == generation else { return }
                do {
                    let initial = try snapshot.get()
                    guard self.service.connected, !self.service.busy else { throw M5Error.message(L("M5 ist inzwischen beschäftigt oder getrennt.")) }
                    self.service.beginLiveSync(initial, to: directory) { [weak self] result in
                        guard let self, self.liveGeneration == generation else { return }
                        do {
                            self.liveToken = try result.get()
                            self.liveApplied = [:]
                            let watcher = LiveSyncWatcher(root: root)
                            watcher.onStable = { [weak self] snapshot in
                                guard let self, self.liveGeneration == generation, !self.service.busy,
                                      Date() >= self.liveNotBefore, let token = self.liveToken else { return }
                                let names = snapshot.files.keys.filter { self.liveApplied[$0] != snapshot.files[$0] }.sorted()
                                guard !names.isEmpty else { return }
                                self.liveLabel.stringValue = L("Live-Sync: {0} Dateien übertragen …", String(describing: (names.count)))
                                self.service.liveSync(snapshot, names: names, token: token) { [weak self] result in
                                    guard let self, self.liveGeneration == generation else { return }
                                    switch result {
                                    case .success:
                                        self.liveApplied = snapshot.files
                                        self.liveNotBefore = Date().addingTimeInterval(3)
                                        self.liveLabel.stringValue = L("Live-Sync aktiv: {0} → {1} · Neustart angefordert", String(describing: (root.path)), String(describing: (directory)))
                                    case .failure(let error): self.stopLiveSync(); self.showError(error)
                                    }
                                }
                            }
                            watcher.onError = { [weak self] error in
                                guard let self, self.liveGeneration == generation else { return }
                                self.stopLiveSync(); self.showError(error)
                            }
                            self.liveWatcher = watcher
                            self.liveLabel.stringValue = L("Live-Sync aktiv: {0} → {1}", String(describing: (root.path)), String(describing: (directory)))
                        } catch { self.stopLiveSync(); self.showError(error) }
                    }
                } catch { self.stopLiveSync(); self.showError(error) }
            }
        }
    }

    @objc private func uploadFiles() {
        guard let destination = selectedDirectory() else { return }
        let panel = NSOpenPanel()
        panel.title = L("Dateien nach {0} kopieren", String(describing: (destination)))
        panel.prompt = L("Hochladen")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK { self?.upload(panel.urls, to: destination) }
        }
    }
    private func upload(_ urls: [URL], to destination: String, overwrite: Bool = false) {
        service.upload(urls: urls, to: destination, overwrite: overwrite) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success: break
            case .failure(let error):
                if !overwrite && self.isCollision(error) { self.confirmOverwrite(error) { self.upload(urls, to: destination, overwrite: true) } }
                else { self.showError(error) }
            }
        }
    }
    @objc private func downloadSelected() {
        guard outline.numberOfSelectedRows == 1, let node = selectedNode(), isUsable(node), !isVolume(node) else { return }
        let panel = NSOpenPanel()
        panel.title = L("«{0}» auf dem Mac speichern", String(describing: (node.entry.name)))
        panel.prompt = L("Hier speichern")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let directory = panel.url else { return }
            self?.download(node.entry, to: directory)
        }
    }
    private func download(_ entry: RemoteEntry, to directory: URL, overwrite: Bool = false) {
        service.download(entry: entry, to: directory, overwrite: overwrite) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let url):
                self.appendLog(L("Gespeichert: {0}\n", String(describing: (url.path))))
                NSWorkspace.shared.activateFileViewerSelecting([url])
            case .failure(let error):
                if !overwrite && self.isCollision(error) { self.confirmOverwrite(error) { self.download(entry, to: directory, overwrite: true) } }
                else { self.showError(error) }
            }
        }
    }
    @objc private func createFolder() {
        guard let directory = selectedDirectory() else { return }
        let alert = NSAlert()
        alert.messageText = L("Neuer Ordner")
        alert.informativeText = L("In {0}", String(describing: (directory)))
        alert.addButton(withTitle: L("Erstellen"))
        alert.addButton(withTitle: L("Abbrechen"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 330, height: 24))
        field.placeholderString = L("Ordnername")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.contains("\0") else { self.showError(M5Error.message(L("Bitte einen einfachen Ordnernamen ohne Schrägstriche eingeben."))); return }
            self.service.mkdir(path: remoteJoin(directory, name)) { result in
                switch result { case .success: break; case .failure(let error): self.showError(error) }
            }
        }
    }
    private func isCollision(_ error: Error) -> Bool {
        if case M5Error.fileExists = error { return true }
        let message = error.localizedDescription.lowercased()
        return message.contains("vorhanden") || message.contains("exists") || message.contains("existiert")
    }
    private func confirmOverwrite(_ error: Error, then action: @escaping () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Vorhandene Dateien ersetzen?")
        alert.informativeText = error.localizedDescription + L("\n\nGleichnamige Dateien in dieser Übertragung werden ersetzt. Beim Herunterladen ersetzt ein gleichnamiger Ordner den gesamten bisherigen Mac-Ordner – auch zusätzliche Dateien darin.")
        alert.addButton(withTitle: L("Abbrechen"))
        alert.addButton(withTitle: L("Ersetzen"))
        alert.beginSheetModal(for: window) { response in if response == .alertSecondButtonReturn { action() } }
    }
    private func showError(_ error: Error, completion: (() -> Void)? = nil) {
        appendLog(L("Hinweis: {0}\n", String(describing: (error.localizedDescription))), kind: .error)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Das hat noch nicht geklappt")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { _ in completion?() }
    }
    @objc private func sendCommand() {
        guard !demo, service.connected, !service.busy else { return }
        let command = commandField.stringValue
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        commandField.stringValue = ""
        service.send(command: command)
        invalidateRunningState(status: L("Terminalbefehl gesendet"), hint: L("Terminalbefehl gesendet. «Aktualisieren» liest die Dateien neu und hält laufenden Python-Code an."))
    }
    @objc private func interruptProgram() { if !demo, service.connected, !service.busy { service.interrupt() } }
    @objc private func restartProgram() { if !demo, service.connected, !service.busy { service.restart() } }

    private func clearRemoteDrag() {
        activeRemoteDrag = nil
        dragProviders.removeAll()
    }

    private func hasRemoteMovePayload(_ info: NSDraggingInfo) -> Bool {
        (info.draggingSource as? NSOutlineView) === outline ||
            info.draggingPasteboard.availableType(from: [RetainedFilePromise.remoteMoveType]) != nil
    }

    private func remoteMoveDrop(_ info: NSDraggingInfo, target item: Any?) -> (RemoteDrag, FileNode)? {
        guard !demo, service.connected, !service.busy,
              (info.draggingSource as? NSOutlineView) === outline,
              let drag = activeRemoteDrag, drag.session == session,
              drag.sequenceNumber == info.draggingSequenceNumber,
              let target = item as? FileNode, target.entry.isDirectory, isUsable(target),
              let pasteboardItems = info.draggingPasteboard.pasteboardItems else { return nil }
        let tokens = pasteboardItems.compactMap { $0.string(forType: RetainedFilePromise.remoteMoveType) }
        guard tokens == drag.tokens, tokens.count == pasteboardItems.count,
              !drag.nodes.isEmpty, drag.nodes.allSatisfy({ isUsable($0) && !isVolume($0) }) else { return nil }
        let sourcePaths = drag.nodes.map { $0.entry.path }
        guard Set(sourcePaths).count == sourcePaths.count else { return nil }
        for source in sourcePaths {
            guard target.entry.path != source, !target.entry.path.hasPrefix(source + "/"),
                  parentPath(source) != target.entry.path,
                  !sourcePaths.contains(where: { $0 != source && $0.hasPrefix(source + "/") }) else { return nil }
        }
        func volume(for path: String) -> String? {
            roots.map { $0.entry.path }.filter { $0 == "/" || path == $0 || path.hasPrefix($0 + "/") }
                .max(by: { $0.count < $1.count })
        }
        guard let targetVolume = volume(for: target.entry.path),
              sourcePaths.allSatisfy({ volume(for: $0) == targetVolume }) else {
            destinationLabel.stringValue = L("Verschieben nur innerhalb von Flash oder SD · Zwischen beiden Speichern bitte über den Mac kopieren")
            return nil
        }
        return (drag, target)
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        if hasRemoteMovePayload(info) {
            guard let (_, target) = remoteMoveDrop(info, target: item) else { return [] }
            outlineView.setDropItem(target, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .move
        }
        guard !demo, service.connected, !service.busy, info.draggingSource == nil, !roots.isEmpty,
              info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return [] }
        var target = item as? FileNode
        if let target, !isUsable(target) { return [] }
        if let node = target, !node.entry.isDirectory { target = findNode(parentPath(node.entry.path)) }
        if target == nil { target = roots.first(where: { isUsable($0) }) }
        guard isUsable(target) else { return [] }
        outlineView.setDropItem(target, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .copy
    }
    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        if hasRemoteMovePayload(info) {
            guard let (drag, target) = remoteMoveDrop(info, target: item) else { return false }
            let entries = drag.nodes.map(\.entry)
            let targetPath = target.entry.path
            clearRemoteDrag()
            service.move(entries: entries, toDirectory: targetPath) { [weak self] result in
                guard let self, self.session == drag.session else { return }
                for entry in entries {
                    self.invalidateDocuments(under: entry.path, reason: L("Für diese Datei oder ihren Ordner wurde ein Verschiebeauftrag ausgeführt. Bitte am aktuellen Ort neu öffnen."))
                    self.invalidateDocuments(under: remoteJoin(targetPath, entry.name), reason: L("Für diesen Dateipfad wurde ein Verschiebeauftrag ausgeführt. Bitte die aktuelle Datei neu öffnen."))
                }
                if case .failure(let error) = result {
                    // The service requests a refresh immediately after this
                    // callback. Defer it until the error sheet is dismissed.
                    self.defersRefreshForMoveError = true
                    self.showError(error) { [weak self] in
                        guard let self else { return }
                        self.defersRefreshForMoveError = false
                        if self.session == drag.session { self.refreshFiles() }
                    }
                }
            }
            return true
        }
        guard service.connected, !service.busy, !demo, info.draggingSource == nil,
              let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        let node = (item as? FileNode) ?? roots.first(where: { isUsable($0) })
        guard let node, isUsable(node) else { return false }
        let directory = node.entry.isDirectory ? node.entry.path : parentPath(node.entry.path)
        upload(urls, to: directory)
        return true
    }
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard !demo, service.connected, !service.busy, let node = item as? FileNode, isUsable(node), !isVolume(node) else { return nil }
        let writer = RemotePromiseWriter(entry: node.entry, session: session, owner: self)
        let fileType = node.entry.isDirectory ? UTType.folder.identifier : (UTType(filenameExtension: (node.entry.name as NSString).pathExtension) ?? .data).identifier
        let promise = RetainedFilePromise(fileType: fileType, delegate: writer)
        promise.writer = writer
        dragProviders[promise.moveToken] = promise
        return promise
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession dragSession: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        activeRemoteDrag = nil
        guard outlineView === outline, let nodes = draggedItems as? [FileNode], !nodes.isEmpty,
              nodes.allSatisfy({ isUsable($0) && !isVolume($0) }),
              let items = dragSession.draggingPasteboard.pasteboardItems else { clearRemoteDrag(); return }
        let tokens = items.compactMap { $0.string(forType: RetainedFilePromise.remoteMoveType) }
        guard tokens.count == nodes.count, tokens.count == items.count, Set(tokens).count == tokens.count,
              zip(tokens, nodes).allSatisfy({ dragProviders[$0.0]?.writer?.entry.path == $0.1.entry.path }) else { clearRemoteDrag(); return }
        let group = UUID()
        for token in tokens { dragProviders[token]?.writer?.exportGroup = group }
        dragProviders = dragProviders.filter { tokens.contains($0.key) }
        activeRemoteDrag = RemoteDrag(session: session, sequenceNumber: dragSession.draggingSequenceNumber, tokens: tokens, nodes: nodes)
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession dragSession: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if activeRemoteDrag?.sequenceNumber == dragSession.draggingSequenceNumber { clearRemoteDrag() }
        updateControls()
    }

    fileprivate func fulfillPromise(entry: RemoteEntry, session originalSession: UUID, exportGroup: UUID, destination: URL, completion: @escaping (Error?) -> Void) {
        guard session == originalSession else { completion(M5Error.message(L("Die USB-Verbindung wurde inzwischen gewechselt. Bitte die Datei erneut vom verbundenen M5 in den Finder ziehen."))); return }
        // Finder can fulfil a multi-selection concurrently. Only exports from
        // this same drag may join its serial queue; other busy work is rejected.
        guard service.connected, !service.busy || (promiseExportGroup == exportGroup && pendingPromiseExports > 0) else {
            completion(M5Error.message(L("Der M5 ist nicht verbunden oder noch beschäftigt. Bitte nach der laufenden Übertragung nochmals ziehen."))); return
        }
        guard isUsable(findNode(entry.path)) else { completion(M5Error.message(L("Diese Datei ist im aktuellen Dateibaum nicht mehr verfügbar. Bitte aktualisieren und erneut in den Finder ziehen."))); return }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("M5FileManager-\(UUID().uuidString)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true) }
        catch { completion(error); return }
        promiseExportGroup = exportGroup
        pendingPromiseExports += 1
        service.download(entry: entry, to: scratch, overwrite: false) { [weak self] result in
            defer { try? FileManager.default.removeItem(at: scratch) }
            if let self {
                self.pendingPromiseExports -= 1
                if self.pendingPromiseExports == 0 { self.promiseExportGroup = nil }
            }
            switch result {
            case .success(let output):
                do {
                    // Finder supplies the final destination, including its collision handling.
                    try FileManager.default.moveItem(at: output, to: destination)
                    self?.appendLog(L("Gespeichert: {0}\n", String(describing: (destination.path))))
                    completion(nil)
                } catch { completion(error) }
            case .failure(let error): completion(error)
            }
        }
    }

    private func loadDemo() {
        func file(_ name: String, _ path: String, _ size: Int64) -> FileNode { FileNode(RemoteEntry(name: name, path: path, isDirectory: false, size: size)) }
        let assets = FileNode(RemoteEntry(name: "assets", path: "/flash/assets", isDirectory: true, size: 0), children: [file("logo.png", "/flash/assets/logo.png", 18450)])
        let apps = FileNode(RemoteEntry(name: "apps", path: "/flash/apps", isDirectory: true, size: 0), children: [file("wetter.py", "/flash/apps/wetter.py", 4320)])
        roots = [FileNode(RemoteEntry(name: "Flash", path: "/flash", isDirectory: true, size: 0), children: [apps, assets, file("boot.py", "/flash/boot.py", 318), file("main.py", "/flash/main.py", 2176)]), FileNode(RemoteEntry(name: L("SD-Karte"), path: "/sd", isDirectory: true, size: 0), children: [FileNode(RemoteEntry(name: "messungen", path: "/sd/messungen", isDirectory: true, size: 0), children: [file("temperatur.csv", "/sd/messungen/temperatur.csv", 38416)])])]
        portPicker.addItem(withTitle: L("Vorschau · M5Stack per USB"))
        statusLabel.stringValue = L("Vorschau · kein Gerät verbunden")
        statusLabel.textColor = .systemOrange
        outline.reloadData()
        outline.expandItem(roots[0])
        outline.expandItem(roots[1])
        outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        storage = ["/flash": StorageUsage(path: "/flash", totalBytes: 8_388_608, freeBytes: 6_710_886), "/sd": StorageUsage(path: "/sd", totalBytes: 31_914_983_424, freeBytes: 25_022_218_240)]
        terminal.clear()
        appendLog(L("Vorschau mit Beispieldateien · Doppelklick auf eine Textdatei öffnet den Editor.\n"))
        terminal.append(LogEvent(kind: .device, text: ">>> print('Hello M5')\r\nHello M5\r\n"))
        terminal.append(LogEvent(kind: .transfer, text: L("Beispiel: main.py gelesen · 2 KB\n")))
    }
}
