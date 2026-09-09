import Foundation

public struct VideoFrameHeader: Sendable, Equatable {
    public static let serializedSize = 25

    public var windowID: UInt32
    public var frameNumber: UInt32
    public var flags: UInt8
    public var timestamp: UInt64
    public var payloadSize: UInt32
    public var spsSize: UInt16
    public var ppsSize: UInt16

    public var isKeyframe: Bool {
        get { flags & 0x01 != 0 }
        set {
            if newValue {
                flags |= 0x01
            } else {
                flags &= ~0x01
            }
        }
    }

    public init(
        windowID: UInt32,
        frameNumber: UInt32,
        flags: UInt8 = 0,
        timestamp: UInt64,
        payloadSize: UInt32,
        spsSize: UInt16 = 0,
        ppsSize: UInt16 = 0
    ) {
        self.windowID = windowID
        self.frameNumber = frameNumber
        self.flags = flags
        self.timestamp = timestamp
        self.payloadSize = payloadSize
        self.spsSize = spsSize
        self.ppsSize = ppsSize
    }

    public func serialize() -> Data {
        var data = Data(capacity: Self.serializedSize)
        withUnsafeBytes(of: windowID.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: frameNumber.littleEndian) { data.append(contentsOf: $0) }
        data.append(flags)
        withUnsafeBytes(of: timestamp.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: payloadSize.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: spsSize.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: ppsSize.littleEndian) { data.append(contentsOf: $0) }
        return data
    }

    public static func deserialize(from data: Data) -> VideoFrameHeader? {
        guard data.count >= serializedSize else { return nil }

        var offset = 0
        func read<T: FixedWidthInteger>(_ type: T.Type) -> T {
            let value = data[data.startIndex + offset ..< data.startIndex + offset + MemoryLayout<T>.size]
                .withUnsafeBytes { $0.loadUnaligned(as: T.self) }
            offset += MemoryLayout<T>.size
            return T(littleEndian: value)
        }

        let windowID = read(UInt32.self)
        let frameNumber = read(UInt32.self)
        let flags = data[data.startIndex + offset]
        offset += 1
        let timestamp = read(UInt64.self)
        let payloadSize = read(UInt32.self)
        let spsSize = read(UInt16.self)
        let ppsSize = read(UInt16.self)

        return VideoFrameHeader(
            windowID: windowID,
            frameNumber: frameNumber,
            flags: flags,
            timestamp: timestamp,
            payloadSize: payloadSize,
            spsSize: spsSize,
            ppsSize: ppsSize
        )
    }
}
