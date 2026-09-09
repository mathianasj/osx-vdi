import Testing
import Foundation
@testable import VDICore

@Test func controlMessageRoundTripsAllCases() throws {
    let messages: [ControlMessage] = [
        .hello(version: "1.0"),
        .helloResponse(version: "1.0", serverName: "Test"),
        .windowList([]),
        .selectWindow(windowID: 42),
        .streamStarted(windowID: 1, width: 1920, height: 1080),
        .streamStopped(windowID: 1),
        .windowUpdated(WindowInfo(
            windowID: 1,
            bounds: CodableRect(x: 0, y: 0, width: 100, height: 100),
            isOnScreen: true,
            windowLayer: 0
        )),
        .deselectWindow(windowID: 1),
        .windowCreated(WindowInfo(
            windowID: 2,
            bounds: CodableRect(x: 0, y: 0, width: 100, height: 100),
            isOnScreen: true,
            windowLayer: 0
        )),
        .windowDestroyed(windowID: 2),
        .inputEvent(InputEvent(windowID: 1, type: .keyDown, keyCode: 0)),
        .requestKeyframe(windowID: 1),
        .error("test error"),
    ]

    for original in messages {
        let encoded = MessageCodec.encode(control: original)
        let decoder = StreamDecoder()
        var decoded: ControlMessage?
        decoder.onControlMessage = { decoded = $0 }
        decoder.feed(encoded)

        #expect(decoded != nil, "Failed to decode: \(original)")
    }
}

@Test func videoFrameRoundTripsWithSPSPPS() {
    let header = VideoFrameHeader(
        windowID: 1,
        frameNumber: 0,
        flags: 0x01,
        timestamp: 12345,
        payloadSize: 100,
        spsSize: 10,
        ppsSize: 8
    )
    let sps = Data(repeating: 0xAA, count: 10)
    let pps = Data(repeating: 0xBB, count: 8)
    let nalData = Data(repeating: 0xCC, count: 100)

    let encoded = MessageCodec.encode(videoHeader: header, sps: sps, pps: pps, payload: nalData)
    let decoder = StreamDecoder()
    var receivedHeader: VideoFrameHeader?
    var receivedPayload: Data?

    decoder.onVideoFrame = { h, p in
        receivedHeader = h
        receivedPayload = p
    }
    decoder.feed(encoded)

    #expect(receivedHeader != nil)
    #expect(receivedHeader?.windowID == 1)
    #expect(receivedHeader?.isKeyframe == true)
    #expect(receivedHeader?.spsSize == 10)
    #expect(receivedHeader?.ppsSize == 8)

    let expectedPayload = sps + pps + nalData
    #expect(receivedPayload == expectedPayload)
}

@Test func videoFrameRoundTripsWithoutSPSPPS() {
    let header = VideoFrameHeader(
        windowID: 2,
        frameNumber: 5,
        flags: 0x00,
        timestamp: 99999,
        payloadSize: 50
    )
    let nalData = Data(repeating: 0xDD, count: 50)

    let encoded = MessageCodec.encode(videoHeader: header, sps: nil, pps: nil, payload: nalData)
    let decoder = StreamDecoder()
    var receivedHeader: VideoFrameHeader?
    var receivedPayload: Data?

    decoder.onVideoFrame = { h, p in
        receivedHeader = h
        receivedPayload = p
    }
    decoder.feed(encoded)

    #expect(receivedHeader != nil)
    #expect(receivedHeader?.windowID == 2)
    #expect(receivedHeader?.isKeyframe == false)
    #expect(receivedPayload == nalData)
}

@Test func streamDecoderHandlesPartialDelivery() {
    let msg = MessageCodec.encode(control: .hello(version: "1.0"))
    let decoder = StreamDecoder()
    var received: ControlMessage?
    decoder.onControlMessage = { received = $0 }

    let splitPoint = msg.count / 2
    decoder.feed(msg[..<splitPoint])
    #expect(received == nil, "Should not decode from partial data")

    decoder.feed(msg[splitPoint...])
    #expect(received != nil, "Should decode after receiving remaining data")
}

@Test func streamDecoderHandlesMultipleMessagesInOneFeed() {
    let msg1 = MessageCodec.encode(control: .hello(version: "1.0"))
    let msg2 = MessageCodec.encode(control: .selectWindow(windowID: 42))
    let msg3 = MessageCodec.encode(control: .error("test"))

    let combined = msg1 + msg2 + msg3

    let decoder = StreamDecoder()
    var messages: [ControlMessage] = []
    decoder.onControlMessage = { messages.append($0) }

    decoder.feed(combined)
    #expect(messages.count == 3)
}

@Test func streamDecoderHandlesInterleavedPartialMessages() {
    let msg1 = MessageCodec.encode(control: .hello(version: "1.0"))
    let msg2 = MessageCodec.encode(control: .selectWindow(windowID: 7))

    let combined = msg1 + msg2
    let decoder = StreamDecoder()
    var messages: [ControlMessage] = []
    decoder.onControlMessage = { messages.append($0) }

    for byte in combined {
        decoder.feed(Data([byte]))
    }

    #expect(messages.count == 2)
}
