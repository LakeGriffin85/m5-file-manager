import AppKit

private final class UITestDefaults: UserDefaults {
    private var values: [String: Any] = [Localizer.preferenceKey: "de"]
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
}

@main
struct LanguageUITests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message); checks += 1
    }
    static func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
    static func labels(_ window: NSWindow) -> [String] {
        allViews(window.contentView!).compactMap {
            if let button = $0 as? NSButton { return button.title }
            if let label = $0 as? NSTextField { return label.stringValue }
            return nil
        }
    }
    static func snapshot(_ window: NSWindow, _ name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["M5_UI_ARTIFACTS"] else { return }
        window.contentView!.layoutSubtreeIfNeeded()
        let view = window.contentView!
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { preconditionFailure("No view renderer") }
        view.cacheDisplay(in: view.bounds, to: image)
        let target = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try image.representation(using: .png, properties: [:])!.write(to: target.appendingPathComponent(name + ".png"))
    }
    static func main() throws {
        expect(CommandLine.arguments.contains("--demo"), "UI tests must never connect to hardware")
        Localizer.preferences = UITestDefaults()
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let controller = AppController()
        application.delegate = controller
        controller.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let main = application.windows.first { $0.title == "M5 File Manager" }!
        let editorWindow = application.windows.first { $0.title == "main.py · Vorschau" }!
        let editor = allViews(editorWindow.contentView!).compactMap { $0 as? NSTextView }.first { $0.isEditable }!
        let unsaved = "Fehler\nGerät\n/sd/{1}/ä.csv\n"
        editor.string = unsaved
        expect(labels(main).contains("Hochladen …"), "German main controls")
        expect(labels(editorWindow).contains("Auf M5 speichern"), "German editor")
        try snapshot(main, "main-de")
        try snapshot(editorWindow, "editor-de")
        try PreviewWindow.show(name: "sample.csv", data: Data("Fehler,Gerät\nRoh,Löschen\n".utf8))
        let csvWindow = application.windows.first { $0.title.hasPrefix("sample.csv") }!
        let table = allViews(csvWindow.contentView!).compactMap { $0 as? NSTableView }.first!
        csvWindow.contentView!.layoutSubtreeIfNeeded()
        let cell = table.view(atColumn: 0, row: 0, makeIfNecessary: true) as! NSTextField
        expect(cell.stringValue == "Fehler", "Original CSV cell visible")
        let initialWindowCount = application.windows.count
        application.mainMenu!.items.last!.submenu!.performActionForItem(at: 1)
        expect(labels(main).contains("Upload …"), "Main controls update immediately")
        expect(labels(editorWindow).contains("Save to M5"), "Open editor controls update")
        expect(editor.string == unsaved, "Unsaved editor text is unchanged")
        expect(cell.stringValue == "Fehler", "CSV cell is not translated")
        expect(csvWindow.title == "sample.csv · Preview (read only)", "Preview title updates")
        expect(allViews(main.contentView!).compactMap { $0 as? NSTextField }.contains { $0.placeholderString == "MicroPython command, e.g. print('Hello M5')" }, "Terminal placeholder updates")
        expect(labels(main).contains("SD card"), "Storage label updates")
        expect(table.tableColumns.first?.title == "Column 1", "CSV headings are translated")
        expect(application.windows.count == initialWindowCount, "Language switch preserves windows")
        expect(editorWindow.title == "main.py · Preview", "Editor title uses English")
        try snapshot(main, "main-en")
        try snapshot(editorWindow, "editor-en")
        try snapshot(csvWindow, "csv-en")
        let languages = application.mainMenu!.items.last!.submenu!
        expect(languages.items.first { $0.title == "English" }?.state == .on, "Menu reflects English")
        application.mainMenu!.items.last!.submenu!.performActionForItem(at: 0)
        expect(labels(main).contains("Hochladen …"), "Switch back to German")
        expect(editor.string == unsaved && cell.stringValue == "Fehler", "Content preserved after round trip")
        // Closing the test process leaves no hardware or private app session involved.
        print("SUCCESS: \(checks) native language UI checks; demo only, no device access")
    }
}
