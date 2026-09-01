import XCTest

final class EnhancedLyricsParserTests: XCTestCase {
    func testPlainTimedLinesParseWithoutWordTiming() {
        let lrc = """
        [00:12.00]The quick brown fox
        [00:15.50]jumps over the lazy dog
        """

        let lines = EnhancedLyricsParser.parse(lrc)

        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].start, 12_000)
        XCTAssertEqual(lines[0].text, "The quick brown fox")
        XCTAssertTrue(lines[0].words.isEmpty)
        XCTAssertEqual(lines[1].start, 15_500)
    }

    func testWordTagsProduceWordTiming() {
        let lrc = "[00:12.00]<00:12.00>The <00:12.50>quick <00:13.00>fox"

        let lines = EnhancedLyricsParser.parse(lrc)

        XCTAssertEqual(lines.count, 1)
        // The visible text keeps its spacing and drops every tag.
        XCTAssertEqual(lines[0].text, "The quick fox")
        XCTAssertEqual(lines[0].words.map(\.value), ["The", "quick", "fox"])
        XCTAssertEqual(lines[0].words.map(\.start), [12_000, 12_500, 13_000])
        // A word ends where the next one starts.
        XCTAssertEqual(lines[0].words[0].end, 12_500)
        XCTAssertEqual(lines[0].words[1].end, 13_000)
    }

    func testTheLastWordOfALineEndsWhenTheNextLineStarts() {
        let lrc = """
        [00:10.00]<00:10.00>one <00:11.00>two
        [00:14.00]<00:14.00>three
        """

        let lines = EnhancedLyricsParser.parse(lrc)

        XCTAssertEqual(lines[0].words.last?.end, 14_000)
    }

    func testMetadataTagsAndBlankLinesAreIgnored() {
        let lrc = """
        [ar:Someone]
        [ti:A song]

        [00:05.00]only line
        """

        let lines = EnhancedLyricsParser.parse(lrc)

        XCTAssertEqual(lines.map(\.text), ["only line"])
    }

    func testMillisecondTagsAreAccepted() {
        // LRCLIB writes hundredths, Navidrome's ELRC export writes thousandths.
        XCTAssertEqual(EnhancedLyricsParser.parse("[01:02.345]x").first?.start, 62_345)
        XCTAssertEqual(EnhancedLyricsParser.parse("[01:02.34]x").first?.start, 62_340)
    }

    func testLinesAreSortedByStartEvenWhenTheFileIsNot() {
        let lines = EnhancedLyricsParser.parse("[00:20.00]second\n[00:10.00]first")

        XCTAssertEqual(lines.map(\.text), ["first", "second"])
    }

    func testSerializingRoundTripsThroughTheParser() {
        let original = [
            TimedLyricLine(start: 10_000, text: "one two", words: [
                TimedWord(value: "one", start: 10_000, end: 10_500),
                TimedWord(value: "two", start: 10_500, end: 12_000)
            ]),
            TimedLyricLine(start: 12_000, text: "three", words: [])
        ]

        let reparsed = EnhancedLyricsParser.parse(EnhancedLyricsParser.serialize(original))

        XCTAssertEqual(reparsed.map(\.text), ["one two", "three"])
        XCTAssertEqual(reparsed[0].words.map(\.value), ["one", "two"])
        XCTAssertEqual(reparsed[0].words.map(\.start), [10_000, 10_500])
    }
}

final class LyricsKaraokeTimingTests: XCTestCase {
    private let line = TimedLyricLine(start: 10_000, text: "one two", words: [
        TimedWord(value: "one", start: 10_000, end: 11_000),
        TimedWord(value: "two", start: 11_000, end: 12_000)
    ])

    func testNoWordIsActiveBeforeTheLineStarts() {
        XCTAssertNil(LyricsKaraokeTiming.activeWordIndex(in: line, at: 9_999))
    }

    func testTheWordBeingSungIsTheActiveOne() {
        XCTAssertEqual(LyricsKaraokeTiming.activeWordIndex(in: line, at: 10_000), 0)
        XCTAssertEqual(LyricsKaraokeTiming.activeWordIndex(in: line, at: 10_999), 0)
        XCTAssertEqual(LyricsKaraokeTiming.activeWordIndex(in: line, at: 11_000), 1)
    }

    func testTheLastWordStaysActiveOnceTheLineIsOver() {
        // Otherwise the highlight would blink off between the last word and the
        // next line, which is exactly the transition problem raised in #10.
        XCTAssertEqual(LyricsKaraokeTiming.activeWordIndex(in: line, at: 99_000), 1)
    }

    func testProgressSweepsAcrossTheWholeLine() {
        XCTAssertEqual(LyricsKaraokeTiming.progress(in: line, at: 9_000), 0, accuracy: 0.001)
        XCTAssertEqual(LyricsKaraokeTiming.progress(in: line, at: 11_000), 0.5, accuracy: 0.001)
        XCTAssertEqual(LyricsKaraokeTiming.progress(in: line, at: 12_000), 1, accuracy: 0.001)
        XCTAssertEqual(LyricsKaraokeTiming.progress(in: line, at: 99_000), 1, accuracy: 0.001)
    }

    func testALineWithoutWordTimingHasNoKaraokeState() {
        let plain = TimedLyricLine(start: 0, text: "x", words: [])
        XCTAssertNil(LyricsKaraokeTiming.activeWordIndex(in: plain, at: 5))
        XCTAssertEqual(LyricsKaraokeTiming.progress(in: plain, at: 5), 0, accuracy: 0.001)
    }
}
