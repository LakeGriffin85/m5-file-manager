import Foundation

/// Language choice is separate from the system locale and from private builds.
/// Templates are resolved before inserting values; paths and user text are opaque.
enum Localizer {
    static var preferences: UserDefaults = .standard
    static let preferenceKey = "interfaceLanguage"
    static let changed = Notification.Name("M5FileManagerLanguageChanged")
    private static let lock = NSLock()
    private struct Message { let key: String; let arguments: [String] }
    private static var rendered: [String: Message] = [:]
    static let catalog: [String: [String: String]] = {
        let candidates = [Bundle.main.url(forResource: "Localizations", withExtension: "json"),
                          URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("Localizations.json")]
        for case let url? in candidates {
            if let data = try? Data(contentsOf: url),
               let catalog = try? JSONDecoder().decode([String: [String: String]].self, from: data) { return catalog }
        }
        return [:]
    }()

    static var language: String {
        let environment = ProcessInfo.processInfo.environment["M5_FILE_MANAGER_LANGUAGE"]
        if let override = environment, ["de", "en"].contains(override) { return override }
        if let saved = preferences.string(forKey: preferenceKey), ["de", "en"].contains(saved) { return saved }
        return Locale.preferredLanguages.first?.hasPrefix("de") == true ? "de" : "en"
    }

    static func select(_ language: String) {
        guard ["de", "en"].contains(language) else { return }
        preferences.set(language, forKey: preferenceKey)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func text(_ key: String, _ arguments: [String] = []) -> String {
        let template = catalog[key]?[language] ?? key
        let output = substitute(template, arguments)
        lock.lock()
        if rendered.count >= 4096 { rendered = rendered.filter { $0.value.arguments.isEmpty } }
        rendered[output] = Message(key: key, arguments: arguments)
        lock.unlock()
        return output
    }

    /// Single-pass substitution never interprets placeholders inside user values.
    static func substitute(_ template: String, _ arguments: [String]) -> String {
        var result = "", index = template.startIndex
        while index < template.endIndex {
            if template[index] == "{", let end = template[index...].firstIndex(of: "}"),
               let number = Int(template[template.index(after: index)..<end]), arguments.indices.contains(number) {
                result += arguments[number]; index = template.index(after: end)
            } else { result.append(template[index]); index = template.index(after: index) }
        }
        return result
    }

    /// Refresh only app-generated labels already registered by L().
    static func displayed(_ value: String) -> String {
        lock.lock(); let message = rendered[value]; lock.unlock()
        guard let message else { return value }
        return text(message.key, message.arguments)
    }
}

func L(_ key: String, _ arguments: String...) -> String { Localizer.text(key, arguments) }
