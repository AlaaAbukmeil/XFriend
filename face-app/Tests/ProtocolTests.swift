import XCTest

/// Same golden bytes as tests/test_protocol.py, so both sides agree on the wire format.
final class ProtocolTests: XCTestCase {
    func testGoldenMood() {
        let frame = Frame.encodeJSON(.mood, ["mood": "happy"])
        XCTAssertEqual(Array(frame.prefix(5)), [0x11, 0x00, 0x00, 0x00, 0x10])
        XCTAssertEqual(String(data: frame.dropFirst(5), encoding: .utf8), #"{"mood":"happy"}"#)
    }

    func testGoldenStop() {
        XCTAssertEqual(Array(Frame.encode(.stop)), [0x13, 0x00, 0x00, 0x00, 0x00])
    }

    func testDecoderHandlesSplitAndMergedChunks() throws {
        var data = Frame.encodeJSON(.state, ["state": "listening"])
        data.append(Frame.encode(.ttsAudio, Data(repeating: 1, count: 640)))
        data.append(Frame.encode(.stop))
        var decoder = FrameDecoder()
        var frames: [Frame] = []
        var i = 0
        while i < data.count {  // deliberately awkward chunk size
            frames += try decoder.feed(data.subdata(in: i..<min(i + 7, data.count)))
            i += 7
        }
        XCTAssertEqual(frames.map(\.type), [.state, .ttsAudio, .stop])
        XCTAssertEqual(frames[0].json()["state"] as? String, "listening")
        XCTAssertEqual(frames[1].payload.count, 640)
    }

    func testUnknownTypeIsKeptButUntyped() throws {
        var decoder = FrameDecoder()
        let frames = try decoder.feed(Data([0x7F, 0, 0, 0, 1, 0xAA]))
        XCTAssertEqual(frames.count, 1)
        XCTAssertNil(frames[0].type)
    }

    func testDecoderRejectsOversized() {
        var decoder = FrameDecoder()
        XCTAssertThrowsError(try decoder.feed(Data([0x10, 0x7F, 0xFF, 0xFF, 0xFF])))
    }
}
