import AppKit
import UniformTypeIdentifiers

/// A device document keeps its unsaved text even after the USB session changes.
final class DocumentWindow: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    private let demoMode: Bool
    private var languageObserver: NSObjectProtocol?
    private var remoteDocument: RemoteDocument
    private let editor = NSTextView()
    private let saveButton = NSButton(title: L("Auf M5 speichern"), target: nil, action: nil)
    private let localButton = NSButton(title: L("Auf Mac sichern …"), target: nil, action: nil)
    private let backupButton = NSButton(title: L("Sicherung zeigen"), target: nil, action: nil)
    private let syncBadge = NSTextField(labelWithString: L("M5-Stand beim Öffnen gelesen"))
    private let checkButton = NSButton(title: L("Sync prüfen"), target: nil, action: nil)
    private let previewButton = NSButton(title: L("Vorschau"), target: nil, action: nil)
    var onCheck: ((RemoteDocument, String, @escaping (Result<SyncComparison, Error>) -> Void) -> Void)?
    private let status = NSTextField(wrappingLabelWithString: "")
    private var deviceAvailable = false
    private var saving = false
    private var allowClose = false
    private var backupURL: URL?
    private(set) var isInvalidated = false
    var onSave: ((RemoteDocument, String, @escaping (Result<SavedDocument, Error>) -> Void) -> Void)?
    var onClose: (() -> Void)?

    var remotePath: String { remoteDocument.entry.path }
    var isDirty: Bool { editor.string != remoteDocument.text }

    init(document: RemoteDocument, demo: Bool = false) {
        self.demoMode = demo
        self.remoteDocument = document
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 950, height: 620), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = remoteDocument.entry.name + (demo ? L(" · Vorschau") : " · M5")
        window.appearance = NSAppearance(named: .aqua)
        window.minSize = NSSize(width: 850, height: 430)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        buildContent(in: window)
        editor.string = remoteDocument.text
        status.stringValue = demo ? L("Beispieldatei · Änderungen lassen sich auf dem Mac sichern; kein Gerätezugriff.") : L("Änderungen werden erst mit «Auf M5 speichern» übertragen. Das Original wird vorher auf dem Mac gesichert.")
        if demo { isInvalidated = true }
        updateControls()
        languageObserver = NotificationCenter.default.addObserver(forName: Localizer.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self, let window = self.window else { return }
            Localizer.refresh(window)
            window.title = self.remoteDocument.entry.name + (self.demoMode ? L(" · Vorschau") : " · M5")
        }
    }

    deinit { if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) } }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildContent(in window: NSWindow) {
        let content = InterfaceBackground()
        window.contentView = content
        let path = NSTextField(labelWithString: remoteDocument.entry.path)
        path.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        editor.isRichText = false
        editor.isEditable = true
        editor.isSelectable = true
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.textContainerInset = NSSize(width: 12, height: 12)
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        saveButton.target = self; saveButton.action = #selector(saveToDevice)
        localButton.target = self; localButton.action = #selector(saveLocallyAction)
        backupButton.target = self; backupButton.action = #selector(revealBackup)
        for button in [saveButton, localButton, backupButton] { InterfaceTheme.configure(button) }
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = [.command]
        checkButton.target = self; checkButton.action = #selector(checkSync)
        previewButton.target = self; previewButton.action = #selector(showPreview)
        InterfaceTheme.configure(checkButton); InterfaceTheme.configure(previewButton)
        syncBadge.font = .systemFont(ofSize: 12, weight: .medium)
        let buttons = NSStackView(views: [saveButton, localButton, checkButton, previewButton, NSView(), backupButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let stack = NSStackView(views: [path, syncBadge, scroll, status, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            path.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 230),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    func setDeviceAvailable(_ available: Bool) { deviceAvailable = available; updateControls() }

    func invalidate(_ reason: String) {
        isInvalidated = true
        syncBadge.stringValue = L("Sync-Stand unbekannt · Sitzung geändert")
        status.stringValue = reason + L(" Der Text bleibt offen und kann auf dem Mac gesichert werden. Zum Speichern auf dem M5 die Datei neu öffnen.")
        updateControls()
    }

    func textDidChange(_ notification: Notification) {
        syncBadge.stringValue = isDirty ? L("🟡 Lokal geändert · M5 erneut prüfen") : L("M5-Stand zuletzt gelesen · erneut prüfen")
        updateControls()
    }

    @objc private func checkSync() {
        guard deviceAvailable, !isInvalidated, !saving, let onCheck else { return }
        let text = editor.string
        saving = true; updateControls()
        onCheck(remoteDocument, text) { [weak self] result in
            guard let self else { return }
            self.saving = false
            switch result {
            case .success(let comparison): self.syncBadge.stringValue = L(comparison.rawValue) + L(" · soeben geprüft")
            case .failure(let error):
                self.syncBadge.stringValue = L("Sync-Stand unbekannt")
                self.showError(error)
            }
            self.updateControls()
        }
    }

    @objc private func showPreview() {
        do { try PreviewWindow.show(name: remoteDocument.entry.name, data: Data(editor.string.utf8)) }
        catch { showError(error) }
    }

    private func updateControls() {
        window?.isDocumentEdited = isDirty
        saveButton.isEnabled = deviceAvailable && !isInvalidated && !saving && isDirty
        checkButton.isEnabled = deviceAvailable && !isInvalidated && !saving
        previewButton.isHidden = !["json", "csv"].contains((remoteDocument.entry.name as NSString).pathExtension.lowercased())
        previewButton.isEnabled = !saving
        localButton.isEnabled = !saving
        backupButton.isHidden = backupURL == nil
        editor.isEditable = !saving
    }

    @objc private func saveToDevice() { save(closeAfter: false, completion: nil) }

    private func save(closeAfter: Bool, completion: ((Bool) -> Void)?) {
        guard deviceAvailable, !isInvalidated, !saving, let onSave else { completion?(false); return }
        saving = true
        updateControls()
        status.stringValue = L("Sichere Original und speichere Änderungen auf dem M5 …")
        onSave(remoteDocument, editor.string) { [weak self] result in
            guard let self else { completion?(false); return }
            self.saving = false
            switch result {
            case .success(let saved):
                self.remoteDocument = saved.document
                self.syncBadge.stringValue = L("✅ Übertragung geprüft · M5 erneut prüfbar")
                self.backupURL = saved.backupURL
                self.status.stringValue = L("Auf dem M5 gespeichert. Die vorherige Version liegt als Sicherung auf dem Mac.")
                self.updateControls()
                if closeAfter { self.finishClose() }
                completion?(true)
            case .failure(let error):
                self.status.stringValue = L("Nicht gespeichert – deine Änderungen sind weiterhin im Editor.")
                self.updateControls()
                self.showError(error)
                completion?(false)
            }
        }
    }

    @objc private func saveLocallyAction() { saveLocally(completion: nil) }

    private func saveLocally(completion: ((Bool) -> Void)?) {
        guard let window else { completion?(false); return }
        let panel = NSSavePanel()
        panel.title = L("Text auf dem Mac sichern")
        panel.nameFieldStringValue = remoteDocument.entry.name
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { completion?(false); return }
            do {
                try Data(self.editor.string.utf8).write(to: url, options: .atomic)
                self.status.stringValue = L("Auf dem Mac gesichert: {0}. Die Datei auf dem M5 wurde dabei nicht geändert.", String(describing: (url.path)))
                completion?(true)
            } catch { self.showError(error); completion?(false) }
        }
    }

    @objc private func revealBackup() {
        if let backupURL { NSWorkspace.shared.activateFileViewerSelecting([backupURL]) }
    }

    func requestClose(completion: @escaping (Bool) -> Void) {
        guard !saving else { completion(false); return }
        guard isDirty, let window else { finishClose(); completion(true); return }
        guard window.attachedSheet == nil else { completion(false); return }
        let alert = NSAlert()
        alert.messageText = L("Änderungen in «{0}» sichern?", String(describing: (remoteDocument.entry.name)))
        alert.informativeText = L("Die Änderungen wurden noch nicht auf dem M5 gespeichert.")
        alert.addButton(withTitle: L("Abbrechen"))
        alert.addButton(withTitle: L("Auf Mac sichern …"))
        alert.addButton(withTitle: L("Verwerfen"))
        if deviceAvailable && !isInvalidated { alert.addButton(withTitle: L("Auf M5 speichern")) }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { completion(false); return }
            switch response.rawValue {
            case NSApplication.ModalResponse.alertSecondButtonReturn.rawValue:
                self.saveLocally { saved in if saved { self.finishClose() }; completion(saved) }
            case NSApplication.ModalResponse.alertThirdButtonReturn.rawValue:
                self.finishClose(); completion(true)
            case NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1:
                self.save(closeAfter: true, completion: completion)
            default: completion(false)
            }
        }
    }

    private func finishClose() { allowClose = true; window?.close() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowClose { return true }
        requestClose { _ in }
        return false
    }
    func windowWillClose(_ notification: Notification) { onClose?() }

    private func showError(_ error: Error) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = L("Datei konnte nicht gespeichert werden")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }
}
