import Foundation

enum TerminalLogFilter: Int, CaseIterable {
    case all, device, transfers, errors
}

struct TerminalSpan {
    let kind: LogKind
    let text: String
}

struct TerminalSnapshot {
    let spans: [TerminalSpan]
    let hiddenProtocolLineCount: Int
    let discardedUTF16Count: Int

    var text: String { spans.map(\.text).joined() }
}

/// Stores the captured stream without changing its characters. Cleaning and filtering
/// are projections, so switching to raw never depends on previously hidden output.
final class TerminalTranscript {
    private struct Capture {
        let kind: LogKind
        var text: String
    }

    private struct Line {
        let source: LogKind
        let text: String
        let complete: Bool
        let order: Int
        var diagnostic = false
    }

    private struct PendingLine {
        let kind: LogKind
        var text = ""
        var order = 0
        var followsCR = false
    }

    private var captures: [Capture] = []
    private(set) var retainedUTF16Count = 0
    private(set) var discardedUTF16Count = 0
    let maximumUTF16Count: Int

    init(maximumUTF16Count: Int = 280_000) {
        self.maximumUTF16Count = min(300_000, max(1, maximumUTF16Count))
    }

    func append(_ event: LogEvent) {
        guard !event.text.isEmpty else { return }
        if let last = captures.indices.last, captures[last].kind == event.kind {
            captures[last].text.append(event.text)
        } else {
            captures.append(Capture(kind: event.kind, text: event.text))
        }
        retainedUTF16Count += event.text.utf16.count
        while retainedUTF16Count > maximumUTF16Count, !captures.isEmpty {
            let excess = retainedUTF16Count - maximumUTF16Count
            let length = captures[0].text.utf16.count
            if length <= excess {
                captures.removeFirst()
                retainedUTF16Count -= length
                discardedUTF16Count += length
            } else {
                let suffix = Self.suffix(captures[0].text, droppingAtLeast: excess)
                let removed = length - suffix.utf16.count
                captures[0].text = suffix
                retainedUTF16Count -= removed
                discardedUTF16Count += removed
                if suffix.isEmpty { captures.removeFirst() }
            }
        }
    }

    func clear() {
        captures.removeAll(keepingCapacity: false)
        retainedUTF16Count = 0
        discardedUTF16Count = 0
    }

    func snapshot(filter: TerminalLogFilter = .all, raw: Bool = false) -> TerminalSnapshot {
        if raw {
            // Raw means the full captured stream; the UI disables filters in this mode.
            return TerminalSnapshot(spans: captures.map { TerminalSpan(kind: $0.kind, text: $0.text) },
                                    hiddenProtocolLineCount: 0, discardedUTF16Count: discardedUTF16Count)
        }
        var lines = assembledLines()
        var tracebackSources = Set<String>()
        for index in lines.indices {
            let text = lines[index].text
            let key = lines[index].source.rawValue
            let header = Self.isTracebackHeader(text)
            let continuation = tracebackSources.contains(key) &&
                (text.isEmpty || text.first?.isWhitespace == true ||
                 text.hasPrefix("During handling of the above exception") ||
                 text.hasPrefix("The above exception was the direct cause"))
            lines[index].diagnostic = lines[index].source == .error || Self.isDiagnostic(text) || continuation
            if header { tracebackSources.insert(key) }
            else if !continuation { tracebackSources.remove(key) }
        }

        var seenBanners = Set<String>()
        var hidden = 0
        var visible: [Line] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.source == .device, !line.diagnostic {
                if Self.isOnlyFriendlyPrompts(line.text) {
                    hidden += 1
                    index += 1
                    continue
                }
                // A banner-looking user message is not enough: require the following
                // exact standard help line too. Keep the first confirmed occurrence.
                if line.complete, Self.isStandardBanner(line.text), index + 1 < lines.count {
                    let help = lines[index + 1]
                    if help.source == .device, help.complete, !help.diagnostic,
                       help.text == "Type \"help()\" for more information." {
                        if seenBanners.contains(line.text) {
                            hidden += 2
                        } else {
                            seenBanners.insert(line.text)
                            visible.append(line)
                            visible.append(help)
                        }
                        index += 2
                        continue
                    }
                }
            }
            visible.append(line)
            index += 1
        }

        var spans: [TerminalSpan] = []
        var previousWasIncomplete = false
        for line in visible where includes(line, filter: filter) {
            if previousWasIncomplete { Self.appendSpan("\n", kind: spans.last?.kind ?? .info, to: &spans) }
            let kind: LogKind = line.diagnostic ? .error : line.source
            Self.appendSpan(line.text + (line.complete ? "\n" : ""), kind: kind, to: &spans)
            previousWasIncomplete = !line.complete
        }
        // Clean projections may add a separator between interleaved incomplete sources.
        // Their visible text must obey the same bound as the captured stream.
        Self.boundSpans(&spans, maximum: maximumUTF16Count)
        return TerminalSnapshot(spans: spans, hiddenProtocolLineCount: hidden,
                                discardedUTF16Count: discardedUTF16Count)
    }

    private func includes(_ line: Line, filter: TerminalLogFilter) -> Bool {
        switch filter {
        case .all: return true
        case .device: return line.source == .device
        case .transfers: return line.source == .transfer
        case .errors: return line.diagnostic
        }
    }

    private func assembledLines() -> [Line] {
        // App status messages are out of band: do not splice them into a fragmented
        // device line. The raw projection still preserves their exact arrival order.
        var pending: [String: PendingLine] = [:]
        var lines: [Line] = []
        var order = 0
        for capture in captures {
            let key = capture.kind.rawValue
            var current = pending[key] ?? PendingLine(kind: capture.kind)
            for scalar in capture.text.unicodeScalars {
                if scalar.value == 10, current.followsCR {
                    current.followsCR = false
                    continue
                }
                if current.text.isEmpty {
                    current.order = order
                    order += 1
                }
                if scalar.value == 10 || scalar.value == 13 {
                    lines.append(Line(source: current.kind, text: current.text,
                                      complete: true, order: current.order))
                    current.text = ""
                    current.followsCR = scalar.value == 13
                } else {
                    current.text.unicodeScalars.append(scalar)
                    current.followsCR = false
                }
            }
            pending[key] = current
        }
        for value in pending.values where !value.text.isEmpty {
            lines.append(Line(source: value.kind, text: value.text, complete: false, order: value.order))
        }
        return lines.sorted { $0.order < $1.order }
    }

    private static func isOnlyFriendlyPrompts(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return false }
        return value.range(of: "^(?:>>>[ \\t]*)+$", options: .regularExpression) != nil
    }

    private static func isStandardBanner(_ text: String) -> Bool {
        text.range(of: "^MicroPython v[0-9]+(?:\\.[0-9]+){1,2}[^\\r\\n]* on [0-9]{4}-[0-9]{2}-[0-9]{2}; [^\\r\\n]+$",
                   options: .regularExpression) != nil
    }

    private static func isTracebackHeader(_ text: String) -> Bool {
        text.range(of: "^\\s*Traceback\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func isDiagnostic(_ text: String) -> Bool {
        if text.contains("⚠") || isTracebackHeader(text) { return true }
        return text.range(of: "\\b(?:[A-Za-z_]*(?:Error|Exception)|warning|warnung|warn|error|fehler|exception|failed|failure|keyboardinterrupt|zeitüberschreitung)\\b",
                          options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func appendSpan(_ text: String, kind: LogKind, to spans: inout [TerminalSpan]) {
        guard !text.isEmpty else { return }
        if let last = spans.last, last.kind == kind {
            spans[spans.count - 1] = TerminalSpan(kind: kind, text: last.text + text)
        } else {
            spans.append(TerminalSpan(kind: kind, text: text))
        }
    }

    private static func boundSpans(_ spans: inout [TerminalSpan], maximum: Int) {
        var count = spans.reduce(0) { $0 + $1.text.utf16.count }
        while count > maximum, let first = spans.first {
            let length = first.text.utf16.count
            if length <= count - maximum {
                spans.removeFirst()
                count -= length
            } else {
                let suffix = Self.suffix(first.text, droppingAtLeast: count - maximum)
                spans[0] = TerminalSpan(kind: first.kind, text: suffix)
                count -= length - suffix.utf16.count
            }
        }
    }

    private static func suffix(_ text: String, droppingAtLeast count: Int) -> String {
        let utf16 = text.utf16
        var offset = utf16.index(utf16.startIndex, offsetBy: min(count, utf16.count))
        // Do not split surrogate pairs or composed characters when dropping old output.
        while offset < utf16.endIndex, String.Index(offset, within: text) == nil {
            offset = utf16.index(after: offset)
        }
        guard let index = String.Index(offset, within: text) else { return "" }
        return String(text[index...])
    }
}
