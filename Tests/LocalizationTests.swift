import Foundation

final class LocalizationTestDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
}

@main
struct LocalizationTests {
    static func main() throws {
        Localizer.preferences = LocalizationTestDefaults()
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); checks += 1
        }
        expect(Localizer.catalog.count >= 450, "Catalog is bundled")
        let placeholders = try NSRegularExpression(pattern: #"\{[0-9]+\}"#)
        func tokens(_ value: String) -> [String] {
            placeholders.matches(in: value, range: NSRange(value.startIndex..., in: value))
                .compactMap { Range($0.range, in: value).map { String(value[$0]) } }.sorted()
        }
        for (key, values) in Localizer.catalog {
            expect(values["de"] == key, "German fallback is complete")
            expect(values["en"]?.isEmpty == false, "English translation is present")
            expect(tokens(values["de"]!) == tokens(values["en"]!), "Interpolation is preserved: \(key)")
        }
        Localizer.select("de")
        let old = L("Lese Vorschau …")
        expect(old == "Lese Vorschau …", "German chosen")
        Localizer.select("en")
        expect(Localizer.language == "en", "English choice persisted")
        expect(Localizer.displayed(old) == "Reading preview …", "Existing label changes")
        expect(L("Spalte {0}", "7") == "Column 7", "Interpolation localized")
        expect(Localizer.substitute("{0} / {1}", ["{1}", "raw"]) == "{1} / raw", "Values are opaque")
        let path = "/sd/Fehler/{1}/ä.csv"
        expect(L("Keine reguläre Datei: {0}", path) == "Not a regular file: " + path, "Paths are not translated")
        expect(Localizer.displayed("unchanged-user-text") == "unchanged-user-text", "Unregistered data is preserved")
        expect(M5Error.filesystem(path: path, code: 2).localizedDescription.contains("no longer exists"), "Structured errors use English")
        Localizer.select("fr")
        expect(Localizer.language == "en", "Unsupported language rejected")
        Localizer.select("de")
        expect(Localizer.displayed("Reading preview …") == "Lese Vorschau …", "Switch back without restart")
        print("SUCCESS: \(checks) localization checks; isolated preferences, no device access")
    }
}
