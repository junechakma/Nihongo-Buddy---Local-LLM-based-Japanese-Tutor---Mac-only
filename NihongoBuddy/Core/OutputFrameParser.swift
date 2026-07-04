import Foundation

/// Incremental parser for the model's output frame (§3.3, §7.3, §7.5.4):
///
///   <heard>…verbatim user speech…</heard>
///   <reply emotion="happy|shocked|proud|teasing|neutral">…</reply>
///   <mistake wrong="…" correct="…" point="…"/>
///
/// Feed raw streamed tokens; it emits typed events as tags complete. Reply
/// text streams out incrementally (for the sentence splitter) — it is never
/// held back until </reply>.
struct OutputFrameParser {
    enum Event {
        case heard(String)
        case emotion(Emotion)
        case replyText(String)
        case mistake(wrong: String, correct: String, point: String)
    }

    enum Emotion: String {
        case happy, shocked, proud, teasing, neutral
    }

    private enum Section { case preamble, heard, betweenTags, reply, done }
    private var section: Section = .preamble
    private var buffer = ""
    private var rawText = ""

    /// If the model ignored the output frame entirely (no <heard> tag ever
    /// appeared), return the raw accumulated text so the reply is never lost.
    var untaggedFallback: String? {
        guard section == .preamble else { return nil }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Call once at end of stream: releases reply text still buffered because
    /// no </reply> arrived (e.g. generation hit the token cap mid-frame, or
    /// ended exactly on a partial closing tag). Tag remnants are stripped so
    /// they never reach the transcript or TTS.
    mutating func flushTail() -> String? {
        guard section == .reply, !buffer.isEmpty else { return nil }
        defer { buffer = "" }
        var tail = buffer.replacingOccurrences(of: "</reply>", with: "")
        // Drop a trailing partial closing tag ("<", "</r", "</reply", …).
        let closing = "</reply>"
        for length in stride(from: closing.count - 1, through: 1, by: -1) {
            let prefix = String(closing.prefix(length))
            if tail.hasSuffix(prefix) {
                tail.removeLast(length)
                break
            }
        }
        let cleaned = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    mutating func push(_ token: String) -> [Event] {
        buffer += token
        if section == .preamble { rawText += token }
        var events: [Event] = []
        var progressed = true
        while progressed {
            progressed = false
            switch section {
            case .preamble:
                if let range = buffer.range(of: "<heard>") {
                    buffer.removeSubrange(..<range.upperBound)
                    section = .heard
                    progressed = true
                }
            case .heard:
                if let range = buffer.range(of: "</heard>") {
                    events.append(.heard(String(buffer[..<range.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)))
                    buffer.removeSubrange(..<range.upperBound)
                    section = .betweenTags
                    progressed = true
                }
            case .betweenTags:
                if let open = buffer.range(of: "<reply"), let close = buffer.range(of: ">", range: open.upperBound..<buffer.endIndex) {
                    let attrs = String(buffer[open.upperBound..<close.lowerBound])
                    if let emotion = Self.attribute("emotion", in: attrs).flatMap(Emotion.init(rawValue:)) {
                        events.append(.emotion(emotion))
                    } else {
                        events.append(.emotion(.neutral))
                    }
                    buffer.removeSubrange(..<close.upperBound)
                    section = .reply
                    progressed = true
                }
            case .reply:
                if let end = buffer.range(of: "</reply>") {
                    let text = String(buffer[..<end.lowerBound])
                    if !text.isEmpty { events.append(.replyText(text)) }
                    buffer.removeSubrange(..<end.upperBound)
                    section = .done
                    progressed = true
                } else {
                    // Stream out everything that cannot be the start of a closing
                    // or embedded tag; keep a small tail in case a tag is split
                    // across tokens.
                    events.append(contentsOf: drainReplyText())
                }
            case .done:
                if let mistake = parseMistakeTag() {
                    events.append(mistake)
                    progressed = true
                }
            }
        }
        return events
    }

    private mutating func drainReplyText() -> [Event] {
        guard let tagStart = buffer.lastIndex(of: "<") else {
            let text = buffer
            buffer = ""
            return text.isEmpty ? [] : [.replyText(text)]
        }
        let safe = String(buffer[..<tagStart])
        buffer.removeSubrange(..<tagStart)
        return safe.isEmpty ? [] : [.replyText(safe)]
    }

    private mutating func parseMistakeTag() -> Event? {
        guard let open = buffer.range(of: "<mistake"),
              let close = buffer.range(of: "/>", range: open.upperBound..<buffer.endIndex) else { return nil }
        let attrs = String(buffer[open.upperBound..<close.lowerBound])
        buffer.removeSubrange(..<close.upperBound)
        return .mistake(wrong: Self.attribute("wrong", in: attrs) ?? "",
                        correct: Self.attribute("correct", in: attrs) ?? "",
                        point: Self.attribute("point", in: attrs) ?? "")
    }

    private static func attribute(_ name: String, in attrs: String) -> String? {
        guard let nameRange = attrs.range(of: "\(name)=\""),
              let end = attrs.range(of: "\"", range: nameRange.upperBound..<attrs.endIndex) else { return nil }
        return String(attrs[nameRange.upperBound..<end.lowerBound])
    }
}
