import AppKit

/// Keeps the selected destination visible while confirming a deletion.
final class DeletionBackupAccessory: NSView {
    private let backupCheckbox = NSButton(checkboxWithTitle: L("Vorher auf dem Mac sichern (empfohlen)"), target: nil, action: nil)
    private let pathLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    var onChooseDirectory: (() -> Void)?
    var onValidityChanged: (() -> Void)?
    var directory: URL { didSet { updateDestination() } }
    var backupFirst: Bool { backupCheckbox.state == .on }
    var canDelete: Bool { !backupFirst || destinationAvailable }
    private var destinationAvailable = false

    init(directory: URL) {
        self.directory = directory
        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: 150))
        backupCheckbox.state = .on
        backupCheckbox.target = self
        backupCheckbox.action = #selector(optionsChanged)
        pathLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        pathLabel.lineBreakMode = .byCharWrapping
        pathLabel.isSelectable = true
        pathLabel.preferredMaxLayoutWidth = 460
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.preferredMaxLayoutWidth = 460
        let choose = NSButton(title: L("Ordner wählen …"), target: self, action: #selector(chooseDirectory))
        choose.bezelStyle = .rounded
        let stack = NSStackView(views: [backupCheckbox, pathLabel, choose, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 460),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            pathLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        updateDestination()
        frame.size = fittingSize
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func updateDestination() {
        var isDirectory: ObjCBool = false
        destinationAvailable = directory.isFileURL &&
            FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) &&
            isDirectory.boolValue && FileManager.default.isWritableFile(atPath: directory.path)
        pathLabel.stringValue = directory.path
        pathLabel.toolTip = directory.path
        if !backupFirst {
            statusLabel.stringValue = L("Ohne Sicherung: Die Löschung ist endgültig.")
            statusLabel.textColor = .systemOrange
        } else if destinationAvailable {
            statusLabel.stringValue = L("Sicherung in diesem Ordner; gelöscht wird erst nach erfolgreicher Prüfung.")
            statusLabel.textColor = .secondaryLabelColor
        } else {
            statusLabel.stringValue = L("Sicherungsordner nicht erreichbar oder nicht beschreibbar. Bitte einen Ordner wählen.")
            statusLabel.textColor = .systemRed
        }
        onValidityChanged?()
    }

    @objc private func optionsChanged() { updateDestination() }
    @objc private func chooseDirectory() { onChooseDirectory?() }
}
