import Foundation

public enum MessageType: UInt8, Sendable {
    case control = 0x01
    case video = 0x02
}

public enum MessageCodec {
    public static func encode(control message: ControlMessage) -> Data {
        let payload = try! JSONEncoder().encode(message)
        return frame(type: .control, payload: payload)
    }

    public static func encode(videoHeader: VideoFrameHeader, sps: Data?, pps: Data?, payload: Data) -> Data {
        var body = videoHeader.serialize()
        if let sps = sps {
            body.append(sps)
        }
        if let pps = pps {
            body.append(pps)
        }
        body.append(payload)
        return frame(type: .video, payload: body)
    }

    private static func frame(type: MessageType, payload: Data) -> Data {
        var data = Data(capacity: 1 + 4 + payload.count)
        data.append(type.rawValue)
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }
}

public final class StreamDecoder {
    private var buffer = Data()

    public var onControlMessage: ((ControlMessage) -> Void)?
    public var onVideoFrame: ((VideoFrameHeader, Data) -> Void)?

    public init() {}

    public func feed(_ data: Data) {
        buffer.append(data)
        parseMessages()
    }

    private func parseMessages() {
        let headerSize = 5 // 1 byte type + 4 bytes length

        while buffer.count >= headerSize {
            let typeByte = buffer[buffer.startIndex]
            let lengthBytes = buffer[buffer.startIndex + 1 ..< buffer.startIndex + 5]
            let payloadLength = lengthBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            let length = UInt32(littleEndian: payloadLength)

            let totalSize = headerSize + Int(length)
            guard buffer.count >= totalSize else { return }

            let payload = buffer[buffer.startIndex + headerSize ..< buffer.startIndex + totalSize]

            switch typeByte {
            case MessageType.control.rawValue:
                if let message = try? JSONDecoder().decode(ControlMessage.self, from: Data(payload)) {
                    onControlMessage?(message)
                }
            case MessageType.video.rawValue:
                let payloadData = Data(payload)
                if let header = VideoFrameHeader.deserialize(from: payloadData) {
                    let frameStart = payloadData.startIndex + VideoFrameHeader.serializedSize
                    let frameData = payloadData[frameStart ..< payloadData.endIndex]
                    onVideoFrame?(header, Data(frameData))
                }
            default:
                break
            }

            buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + totalSize)
        }
    }
}
