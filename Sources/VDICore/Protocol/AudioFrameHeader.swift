import Foundation

public struct AudioFrameHeader: Sendable, Equatable {
    public static let serializedSize = 22

    public var windowID: UInt32
    public var timestamp: UInt64
    public var sampleRate: UInt32
    public var channels: UInt16
    public var payloadSize: UInt32

    public init(
        windowID: UInt32,
        timestamp: UInt64,
        sampleRate: UInt32,
        channels: UInt16,
        payloadSize: UInt32
    ) {
        self.windowID = windowID
        self.timestamp = timestamp
        self.sampleRate = sampleRate
        self.channels = channels
        self.payloadSize = payloadSize
    }

    public func serialize() -> Data {
        var data = Data(capacity: Self.serializedSize)
        withUnsafeBytes(of: windowID.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: timestamp.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: sampleRate.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: channels.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: payloadSize.littleEndian) { data.append(contentsOf: $0) }
        return data
    }

    public static func deserialize(from data: Data) -> AudioFrameHeader? {
        guard data.count >= serializedSize else { return nil }

        var offset = 0
        func read<T: FixedWidthInteger>(_ type: T.Type) -> T {
            let value = data[data.startIndex + offset ..< data.startIndex + offset + MemoryLayout<T>.size]
                .withUnsafeBytes { $0.loadUnaligned(as: T.self) }
            offset += MemoryLayout<T>.size
            return T(littleEndian: value)
        }

        let windowID = read(UInt32.self)
        let timestamp = read(UInt64.self)
        let sampleRate = read(UInt32.self)
        let channels = read(UInt16.self)
        let payloadSize = read(UInt32.self)

        return AudioFrameHeader(
            windowID: windowID,
            timestamp: timestamp,
            sampleRate: sampleRate,
            channels: channels,
            payloadSize: payloadSize
        )
    }
}
