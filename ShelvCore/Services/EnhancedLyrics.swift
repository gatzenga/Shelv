import Foundation

/// One word or syllable with its own timing, as carried by Enhanced LRC word
/// tags and by the OpenSubsonic v2 `cueLine` array.
nonisolated struct TimedWord: Equatable, Sendable {
    let value: String
    let start: Int
    let end: Int
}

/// A line of lyrics. `words` is empty for ordinary line-timed lyrics, which is
/// the normal case: LRCLIB serves no word timing at all.
nonisolated struct TimedLyricLine: Equatable, Sendable {
    let start: Int
    let text: String
    let words: [TimedWord]

    var hasWordTiming: Bool { !words.isEmpty }
}

/// Reads and writes LRC, including the Enhanced LRC word tags that carry
/// karaoke timing:
///
///     [00:12.00]<00:12.00>The <00:12.50>quick <00:13.00>fox
///
/// Enhanced LRC is a superset of LRC, so one parser covers both and a file
/// without word tags simply yields lines with no words.
nonisolated enum EnhancedLyricsParser {
    static func parse(_ lrc: String) -> [TimedLyricLine] {
        var parsed: [(start: Int, text: String, words: [TimedWord])] = []

        for raw in lrc.split(separator: "\n", omittingEmptySubsequences: false) {
            var rest = Substring(raw).trimmingCharacters(in: .whitespaces)[...]
            var starts: [Int] = []

            // A line may repeat: [00:10.00][01:20.00]same chorus.
            while let tag = leadingTag(in: rest, open: "[", close: "]") {
                guard let millis = milliseconds(tag.body) else { break }
                starts.append(millis)
                rest = tag.remainder
            }
            guard !starts.isEmpty else { continue }

            let (rawText, words) = splitWordTags(String(rest))
            // LRC writers commonly put a space after the closing bracket.
            let text = rawText.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            for start in starts {
                parsed.append((start: start, text: text, words: words))
            }
        }

        parsed.sort { $0.start < $1.start }

        // The last word of a line runs until the next line begins; without this
        // the highlight would blink off in every gap between lines.
        return parsed.enumerated().map { index, line in
            let lineEnd = index + 1 < parsed.count ? parsed[index + 1].start : nil
            return TimedLyricLine(
                start: line.start,
                text: line.text,
                words: closeOpenEnds(line.words, lineEnd: lineEnd)
            )
        }
    }

    static func serialize(_ lines: [TimedLyricLine]) -> String {
        lines.map { line in
            guard line.hasWordTiming else {
                return "[\(timestamp(line.start))]\(line.text)"
            }
            let body = line.words
                .map { "<\(timestamp($0.start))>\($0.value)" }
                .joined(separator: " ")
            return "[\(timestamp(line.start))]\(body)"
        }
        .joined(separator: "\n")
    }

    // MARK: - Scanning

    private static func leadingTag(
        in text: Substring,
        open: Character,
        close: Character
    ) -> (body: String, remainder: Substring)? {
        guard text.first == open, let end = text.firstIndex(of: close) else { return nil }
        let body = text[text.index(after: text.startIndex)..<end]
        return (String(body), text[text.index(after: end)...])
    }

    /// Splits `<mm:ss.xx>word` runs into visible text and word timings. A line
    /// with no word tags comes back unchanged with no words.
    private static func splitWordTags(_ content: String) -> (text: String, words: [TimedWord]) {
        var text = ""
        var words: [TimedWord] = []
        var pendingStart: Int?
        var buffer = ""
        var rest = content[...]

        func flush() {
            guard let start = pendingStart else { return }
            let value = buffer.trimmingCharacters(in: .whitespaces)
            if !value.isEmpty {
                words.append(TimedWord(value: value, start: start, end: start))
            }
            pendingStart = nil
            buffer = ""
        }

        while let index = rest.firstIndex(of: "<") {
            let head = rest[rest.startIndex..<index]
            text += head
            buffer += head
            guard let tag = leadingTag(in: rest[index...], open: "<", close: ">"),
                  let millis = milliseconds(tag.body) else {
                // Not a timing tag: a literal "<" belongs to the lyrics.
                text.append("<")
                buffer.append("<")
                rest = rest[rest.index(after: index)...]
                continue
            }
            flush()
            pendingStart = millis
            rest = tag.remainder
        }

        text += rest
        buffer += rest
        flush()

        return (text, words)
    }

    /// Each word ends where the next one starts; the last ends with the line.
    private static func closeOpenEnds(_ words: [TimedWord], lineEnd: Int?) -> [TimedWord] {
        words.enumerated().map { index, word in
            let next = index + 1 < words.count ? words[index + 1].start : lineEnd
            return TimedWord(value: word.value, start: word.start, end: max(word.start, next ?? word.start))
        }
    }

    /// `mm:ss`, `mm:ss.xx` (hundredths) or `mm:ss.xxx` (thousandths).
    private static func milliseconds(_ tag: String) -> Int? {
        let parts = tag.split(separator: ":")
        guard parts.count == 2, let minutes = Int(parts[0]) else { return nil }

        let secondsPart = parts[1].split(whereSeparator: { $0 == "." || $0 == ":" })
        guard let seconds = Int(secondsPart.first ?? ""), seconds >= 0 else { return nil }

        var fraction = 0
        if secondsPart.count > 1 {
            let digits = secondsPart[1]
            guard let value = Int(digits) else { return nil }
            switch digits.count {
            case 1: fraction = value * 100
            case 2: fraction = value * 10
            case 3: fraction = value
            default: return nil
            }
        }
        return minutes * 60_000 + seconds * 1_000 + fraction
    }

    private static func timestamp(_ millis: Int) -> String {
        let total = max(0, millis)
        return String(format: "%02d:%02d.%03d", total / 60_000, (total / 1_000) % 60, total % 1_000)
    }
}

/// Which word is being sung, and how far the line has swept.
nonisolated enum LyricsKaraokeTiming {
    /// The word being sung at `millis`, or nil before the line starts or when
    /// the line carries no word timing.
    ///
    /// After the last word the highlight stays on it rather than clearing: the
    /// alternative blinks off in the gap before the next line.
    static func activeWordIndex(in line: TimedLyricLine, at millis: Int) -> Int? {
        guard let first = line.words.first, millis >= first.start else { return nil }
        return line.words.lastIndex { $0.start <= millis }
    }

    /// 0 before the line, 1 once it is over, sweeping in between. Drives the
    /// fill of the active line without a per-word animation.
    static func progress(in line: TimedLyricLine, at millis: Int) -> Double {
        guard let first = line.words.first, let last = line.words.last else { return 0 }
        let span = last.end - first.start
        guard span > 0 else { return millis >= first.start ? 1 : 0 }
        return min(1, max(0, Double(millis - first.start) / Double(span)))
    }
}
