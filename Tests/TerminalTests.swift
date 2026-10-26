import Foundation

private struct TerminalTestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
private struct TerminalTests {
    static var checks = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ description: String) throws {
        guard condition() else { throw TerminalTestFailure(description: description) }
        checks += 1
    }

    static func occurrences(_ needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    static func run() throws {
        let fragments = ["Tempe", "ratur: 24 °C\r", "\nGrüezi 🧌\n", ">", ">", "> "]
        let transcript = TerminalTranscript()
        for fragment in fragments { transcript.append(LogEvent(kind: .device, text: fragment)) }
        try expect(transcript.snapshot(raw: true).text == fragments.joined(), "Raw preserves exact fragments and CRLF")
        try expect(transcript.snapshot().text == "Temperatur: 24 °C\nGrüezi 🧌\n", "Clean reassembles lines and hides incomplete prompt")
        try expect(transcript.snapshot().hiddenProtocolLineCount == 1, "One fragmented prompt counted")
        transcript.append(LogEvent(kind: .device, text: "print('Hallo')\r\nHallo\r\n"))
        try expect(transcript.snapshot().text.contains(">>> print('Hallo')\nHallo"), "Prompt plus a real command is retained")
        try expect(transcript.snapshot(raw: true).text == fragments.joined() + "print('Hallo')\r\nHallo\r\n", "Raw still includes formerly hidden prompt")

        let banner = "MicroPython v1.25.0 on 2025-04-15; M5Stack Core2 with ESP32"
        let help = "Type \"help()\" for more information."
        let banners = TerminalTranscript()
        banners.append(LogEvent(kind: .device, text: banner + "\r\n" + help + "\r\n>>> \r\n"))
        banners.append(LogEvent(kind: .device, text: "MicroPython v1.25.0 on 2025-04-15; "))
        banners.append(LogEvent(kind: .device, text: "M5Stack Core2 with ESP32\r\nType \"help()\" "))
        banners.append(LogEvent(kind: .device, text: "for more information.\r\nWARNING: low battery\r\n"))
        let cleanedBanners = banners.snapshot()
        try expect(occurrences(banner, in: cleanedBanners.text) == 1, "First confirmed banner retained; duplicate collapsed")
        try expect(cleanedBanners.hiddenProtocolLineCount == 3, "Only duplicate pair and standalone prompt hidden")
        try expect(occurrences(banner, in: banners.snapshot(raw: true).text) == 2, "Both banners remain captured in raw")
        try expect(cleanedBanners.text.contains("WARNING: low battery"), "Warning after duplicate banner retained")
        try expect(banners.snapshot(filter: .errors).text == "WARNING: low battery\n", "Device warning enters Errors filter")

        let ordinary = TerminalTranscript()
        ordinary.append(LogEvent(kind: .device, text: "MicroPython makes me happy\n" + banner + "\nmy script says hello\n" + banner + "\nmy script says hello\n"))
        ordinary.append(LogEvent(kind: .info, text: banner + "\n" + help + "\n" + banner + "\n" + help + "\n"))
        ordinary.append(LogEvent(kind: .device, text: ">>> WARNING: keep this prompt text\nprint('" + banner + "')\n"))
        try expect(ordinary.snapshot().text.contains("MicroPython makes me happy"), "User text beginning with MicroPython stays visible")
        try expect(occurrences(banner, in: ordinary.snapshot().text) == 5, "Unconfirmed banners, info banners and source code are never swallowed")
        try expect(ordinary.snapshot().text.contains(">>> WARNING: keep this prompt text"), "A warning is never mistaken for a bare prompt")
        try expect(ordinary.snapshot().hiddenProtocolLineCount == 0, "No false banner suppression")

        let traceback = TerminalTranscript()
        for part in ["Trace", "back (most recent call last):\r", "\n  File \"main.py\", line 10\n", "    run()\n", "ValueError: bad value\r\n", ">>> "] {
            traceback.append(LogEvent(kind: .device, text: part))
        }
        traceback.append(LogEvent(kind: .info, text: "Connected\n"))
        traceback.append(LogEvent(kind: .transfer, text: "↑ /flash/data.bin\n"))
        traceback.append(LogEvent(kind: .error, text: "USB disconnected\n"))
        let errors = traceback.snapshot(filter: .errors)
        try expect(errors.text.contains("Traceback (most recent call last):\n"), "Fragmented traceback header retained")
        try expect(errors.text.contains("  File \"main.py\", line 10\n    run()\n"), "Traceback frames preserved in Errors filter")
        try expect(errors.text.contains("ValueError: bad value"), "Exception summary retained")
        try expect(errors.text.contains("USB disconnected"), "Explicit error-kind event retained without keyword")
        try expect(!errors.text.contains("Connected") && !errors.text.contains("data.bin"), "Errors filter excludes routine info/transfers")
        try expect(errors.spans.allSatisfy { $0.kind == .error }, "Detected diagnostic lines get error color category")
        try expect(traceback.snapshot(filter: .device).text.contains("ValueError"), "Device filter includes its diagnostics")
        try expect(traceback.snapshot(filter: .transfers).text == "↑ /flash/data.bin\n", "Transfer filter contains only transfer source")
        try expect(traceback.snapshot(filter: .errors, raw: true).text == traceback.snapshot(raw: true).text,
                   "Raw always provides the complete captured stream even with saved Errors selection")

        let interleaved = TerminalTranscript()
        interleaved.append(LogEvent(kind: .device, text: "Tempe"))
        interleaved.append(LogEvent(kind: .transfer, text: "↑ file.bin\n"))
        interleaved.append(LogEvent(kind: .device, text: "ratur\n"))
        try expect(interleaved.snapshot().text == "Temperatur\n↑ file.bin\n", "Out-of-band messages do not corrupt fragmented device lines")
        try expect(interleaved.snapshot(raw: true).text == "Tempe↑ file.bin\nratur\n", "Interleaved raw event arrival order exact")
        interleaved.append(LogEvent(kind: .error, text: "pending error without newline"))
        try expect(interleaved.snapshot(filter: .errors).text == "pending error without newline", "Incomplete diagnostics are immediately visible")

        let errorBanners = TerminalTranscript()
        errorBanners.append(LogEvent(kind: .error, text: banner + "\n" + help + "\n" + banner + "\n" + help + "\n>>>\n"))
        try expect(occurrences(banner, in: errorBanners.snapshot().text) == 2, "Error-tagged banner text is never hidden")
        try expect(errorBanners.snapshot().text.hasSuffix(">>>\n"), "Error-tagged prompt text is never hidden")

        let bounded = TerminalTranscript(maximumUTF16Count: 21)
        let longUnicode = String(repeating: "A🧌e\u{301}", count: 90)
        bounded.append(LogEvent(kind: .device, text: longUnicode))
        let boundedRaw = bounded.snapshot(raw: true).text
        try expect(bounded.retainedUTF16Count <= 21, "Model bounds storage in UTF-16 units")
        try expect(longUnicode.hasSuffix(boundedRaw), "Truncation retains an exact Unicode suffix")
        try expect(!boundedRaw.contains("�"), "Truncation never creates replacement characters")
        try expect(bounded.discardedUTF16Count > 0, "Truncation is explicitly reported")
        try expect(bounded.retainedUTF16Count + bounded.discardedUTF16Count == longUnicode.utf16.count, "Retained and discarded lengths account for every original unit")
        try expect(bounded.snapshot().text.utf16.count <= 21, "Clean output obeys the bound too")
        for index in 0..<400 {
            bounded.append(LogEvent(kind: index.isMultiple(of: 2) ? .device : .info, text: "x"))
        }
        try expect(bounded.snapshot(raw: true).text == String(repeating: "x", count: 21), "Many alternating small events remain bounded without raw insertion")
        try expect(bounded.snapshot().text.utf16.count <= 21, "Separators for interleaved partial sources cannot exceed limit")
        bounded.clear()
        try expect(bounded.snapshot(raw: true).text.isEmpty, "Clear empties raw data")
        try expect(bounded.snapshot().text.isEmpty, "Clear empties clean projection")
        try expect(bounded.retainedUTF16Count == 0 && bounded.discardedUTF16Count == 0, "Clear resets accounting")

        let capped = TerminalTranscript(maximumUTF16Count: 1_000_000)
        capped.append(LogEvent(kind: .device, text: String(repeating: "z", count: 310_000)))
        try expect(capped.snapshot(raw: true).text.utf16.count == 300_000, "Configured capacity never exceeds 300k")
        try expect(capped.snapshot().text.utf16.count <= 300_000, "Rendered clean text never exceeds 300k")
        print("SUCCESS: \(checks) terminal transcript checks; no device or app connection")
    }

    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }
}
