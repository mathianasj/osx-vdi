import Testing
import Foundation
@testable import VDICore

@Test func headerSerializesToExactly24Bytes() {
    let header = VideoFrameHeader(
        windowID: 1,
        frameNumber: 100,
        flags: 0x01,
        timestamp: 999999,
        payloadSize: 4096,
        spsSize: 32,
        ppsSize: 8
    )
    let data = header.serialize()
    #expect(data.count == 25)
}

@Test func headerRoundTrips() {
    let original = VideoFrameHeader(
        windowID: 42,
        frameNumber: 500,
        flags: 0x01,
        timestamp: 1234567890,
        payloadSize: 65536,
        spsSize: 64,
        ppsSize: 16
    )
    let data = original.serialize()
    let restored = VideoFrameHeader.deserialize(from: data)

    #expect(restored != nil)
    #expect(restored == original)
}

@Test func headerDeserializeRejectsShortData() {
    let data = Data(repeating: 0, count: 23)
    let result = VideoFrameHeader.deserialize(from: data)
    #expect(result == nil)
}

@Test func isKeyframeFlag() {
    var header = VideoFrameHeader(
        windowID: 1,
        frameNumber: 0,
        timestamp: 0,
        payloadSize: 0
    )
    #expect(header.isKeyframe == false)

    header.isKeyframe = true
    #expect(header.isKeyframe == true)
    #expect(header.flags & 0x01 == 1)

    header.isKeyframe = false
    #expect(header.isKeyframe == false)
    #expect(header.flags & 0x01 == 0)
}

@Test func headerRoundTripsWithZeroValues() {
    let original = VideoFrameHeader(
        windowID: 0,
        frameNumber: 0,
        flags: 0,
        timestamp: 0,
        payloadSize: 0,
        spsSize: 0,
        ppsSize: 0
    )
    let data = original.serialize()
    let restored = VideoFrameHeader.deserialize(from: data)

    #expect(restored == original)
}

@Test func headerRoundTripsMaxValues() {
    let original = VideoFrameHeader(
        windowID: .max,
        frameNumber: .max,
        flags: .max,
        timestamp: .max,
        payloadSize: .max,
        spsSize: .max,
        ppsSize: .max
    )
    let data = original.serialize()
    let restored = VideoFrameHeader.deserialize(from: data)

    #expect(restored == original)
}
