import Foundation
import CoreMediaIO
import CoreMedia
import CoreVideo
import VideoToolbox
import IOKit.audio

let kFrameRate: Int = 30
let kWidth: Int = 1280
let kHeight: Int = 720
let kFrameServerPort: UInt16 = 18423

// MARK: - H.264 TCP Frame Reader

class H264FrameReader {
    private let host: String
    private let port: UInt16
    private var sockFd: Int32 = -1
    private var latestPixelBuffer: CVPixelBuffer?
    private let lock = NSLock()
    private var running = false

    private var vtSession: VTDecompressionSession?
    private var formatDesc: CMVideoFormatDescription?
    private var currentSPS: Data?
    private var currentPPS: Data?

    init(host: String = "127.0.0.1", port: UInt16 = kFrameServerPort) {
        self.host = host
        self.port = port
    }

    func start() -> Bool {
        guard tryConnect() else { return false }
        running = true
        Thread.detachNewThread { [weak self] in
            self?.readLoop()
        }
        return true
    }

    private func tryConnect() -> Bool {
        sockFd = socket(AF_INET, SOCK_STREAM, 0)
        guard sockFd >= 0 else { return false }

        var opt: Int32 = 1
        setsockopt(sockFd, Int32(IPPROTO_TCP), TCP_NODELAY, &opt, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(sockFd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if result != 0 {
            Darwin.close(sockFd)
            sockFd = -1
            return false
        }
        return true
    }

    private func readLoop() {
        while running {
            if sockFd < 0 {
                Thread.sleep(forTimeInterval: 1.0)
                _ = tryConnect()
                continue
            }

            // Read 4-byte length prefix
            var lenBuf = [UInt8](repeating: 0, count: 4)
            guard readExactly(count: 4, into: &lenBuf) else {
                Darwin.close(sockFd)
                sockFd = -1
                continue
            }

            let totalPayload = Int(lenBuf.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian)
            guard totalPayload > 25 && totalPayload < 10_000_000 else {
                Darwin.close(sockFd)
                sockFd = -1
                continue
            }

            var payload = [UInt8](repeating: 0, count: totalPayload)
            guard readExactly(count: totalPayload, into: &payload) else {
                Darwin.close(sockFd)
                sockFd = -1
                continue
            }

            decodeFrame(Data(payload))
        }
    }

    private func decodeFrame(_ payload: Data) {
        // Parse VideoFrameHeader (25 bytes, matching VDICore format)
        guard payload.count >= 25 else { return }

        var offset = 0
        func readU32() -> UInt32 {
            let v = payload[payload.startIndex + offset ..< payload.startIndex + offset + 4]
                .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            offset += 4
            return UInt32(littleEndian: v)
        }
        func readU16() -> UInt16 {
            let v = payload[payload.startIndex + offset ..< payload.startIndex + offset + 2]
                .withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
            offset += 2
            return UInt16(littleEndian: v)
        }
        func readU64() -> UInt64 {
            let v = payload[payload.startIndex + offset ..< payload.startIndex + offset + 8]
                .withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
            offset += 8
            return UInt64(littleEndian: v)
        }

        _ = readU32() // windowID
        _ = readU32() // frameNumber
        let flags = payload[payload.startIndex + offset]
        offset += 1
        let timestamp = readU64()
        _ = readU32() // payloadSize
        let spsSize = readU16()
        let ppsSize = readU16()

        let isKeyframe = flags & 0x01 != 0
        let frameData = Data(payload[payload.startIndex + 25 ..< payload.endIndex])
        let nalOffset: Int

        if isKeyframe {
            let sps = Data(frameData[frameData.startIndex ..< frameData.startIndex + Int(spsSize)])
            let pps = Data(frameData[frameData.startIndex + Int(spsSize) ..< frameData.startIndex + Int(spsSize) + Int(ppsSize)])
            nalOffset = Int(spsSize) + Int(ppsSize)

            if sps != currentSPS || pps != currentPPS {
                currentSPS = sps
                currentPPS = pps
                recreateSession(sps: sps, pps: pps)
            }
        } else {
            nalOffset = 0
        }

        guard let formatDesc = formatDesc, let session = vtSession else { return }

        let nalData = Data(frameData[frameData.startIndex + nalOffset ..< frameData.endIndex])
        guard !nalData.isEmpty else { return }

        guard let blockBuffer = createBlockBuffer(from: nalData) else { return }
        guard let sampleBuffer = createSampleBuffer(blockBuffer: blockBuffer, formatDescription: formatDesc, timestamp: timestamp) else { return }

        var flagsOut: VTDecodeInfoFlags = []
        VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: &flagsOut
        ) { [weak self] status, _, imageBuffer, _, _, _ in
            guard status == noErr, let pb = imageBuffer else { return }
            self?.lock.lock()
            self?.latestPixelBuffer = pb
            self?.lock.unlock()
        }
    }

    private func recreateSession(sps: Data, pps: Data) {
        if let session = vtSession {
            VTDecompressionSessionInvalidate(session)
            vtSession = nil
        }

        var formatDescOut: CMVideoFormatDescription?
        let parameterSets: [Data] = [sps, pps]
        let sizes = parameterSets.map { $0.count }

        let status = parameterSets.withUnsafeBufferPointers { pointers in
            CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: 2,
                parameterSetPointers: pointers.baseAddress!,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                formatDescriptionOut: &formatDescOut
            )
        }

        guard status == noErr, let fd = formatDescOut else { return }
        self.formatDesc = fd

        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]

        var sessionOut: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: fd,
            decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &sessionOut
        )

        guard createStatus == noErr, let s = sessionOut else { return }
        vtSession = s
    }

    private func createBlockBuffer(from data: Data) -> CMBlockBuffer? {
        var blockBuffer: CMBlockBuffer?
        let length = data.count

        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr, let buffer = blockBuffer else { return nil }

        status = data.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!,
                blockBuffer: buffer,
                offsetIntoDestination: 0,
                dataLength: length
            )
        }

        return status == noErr ? buffer : nil
    }

    private func createSampleBuffer(blockBuffer: CMBlockBuffer, formatDescription: CMVideoFormatDescription, timestamp: UInt64) -> CMSampleBuffer? {
        var sampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(timestamp), timescale: 1_000_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = CMBlockBufferGetDataLength(blockBuffer)

        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        return status == noErr ? sampleBuffer : nil
    }

    private func readExactly(count: Int, into buffer: inout [UInt8]) -> Bool {
        var offset = 0
        while offset < count {
            let n = buffer.withUnsafeMutableBytes { ptr in
                Darwin.read(sockFd, ptr.baseAddress! + offset, count - offset)
            }
            if n <= 0 { return false }
            offset += n
        }
        return true
    }

    func getLatestPixelBuffer() -> CVPixelBuffer? {
        lock.lock()
        let pb = latestPixelBuffer
        lock.unlock()
        return pb
    }

    var isConnected: Bool { sockFd >= 0 }

    func stop() {
        running = false
        if sockFd >= 0 { Darwin.close(sockFd); sockFd = -1 }
        if let session = vtSession {
            VTDecompressionSessionInvalidate(session)
            vtSession = nil
        }
        currentSPS = nil
        currentPPS = nil
        formatDesc = nil
        lock.lock()
        latestPixelBuffer = nil
        lock.unlock()
    }

    deinit { stop() }
}

private extension Array where Element == Data {
    func withUnsafeBufferPointers<R>(_ body: (UnsafeBufferPointer<UnsafePointer<UInt8>>) -> R) -> R {
        var pointers: [UnsafePointer<UInt8>] = []
        func withPointers(index: Int, body: (UnsafeBufferPointer<UnsafePointer<UInt8>>) -> R) -> R {
            if index == count {
                return pointers.withUnsafeBufferPointer(body)
            }
            return self[index].withUnsafeBytes { rawBuf in
                pointers.append(rawBuf.baseAddress!.assumingMemoryBound(to: UInt8.self))
                return withPointers(index: index + 1, body: body)
            }
        }
        return withPointers(index: 0, body: body)
    }
}

// MARK: - Stream Source

class VDICameraStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private var timer: DispatchSourceTimer?
    private let frameReader = H264FrameReader()
    private let streamQueue = DispatchQueue(label: "com.osx-vdi.camera-stream")
    private var _activeFormatIndex: Int = 0
    private var tcpConnected = false

    let formats: [CMIOExtensionStreamFormat]

    init(device: CMIOExtensionDevice) {
        var formatDesc: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: Int32(kWidth),
            height: Int32(kHeight),
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )

        let format = CMIOExtensionStreamFormat(
            formatDescription: formatDesc!,
            maxFrameDuration: CMTime(value: 1, timescale: CMTimeScale(kFrameRate)),
            minFrameDuration: CMTime(value: 1, timescale: CMTimeScale(kFrameRate)),
            validFrameDurations: nil
        )
        self.formats = [format]

        super.init()

        self.stream = CMIOExtensionStream(
            localizedName: "VDI Camera",
            streamID: UUID(),
            direction: .source,
            clockType: .hostTime,
            source: self
        )
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let props = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            props.activeFormatIndex = _activeFormatIndex
        }
        if properties.contains(.streamFrameDuration) {
            props.frameDuration = CMTime(value: 1, timescale: CMTimeScale(kFrameRate))
        }
        return props
    }

    func setStreamProperties(_ properties: CMIOExtensionStreamProperties) throws {
        if let index = properties.activeFormatIndex {
            _activeFormatIndex = index
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws {
        tcpConnected = frameReader.start()
        let t = DispatchSource.makeTimerSource(queue: streamQueue)
        t.schedule(deadline: .now(), repeating: .milliseconds(1000 / kFrameRate))
        t.setEventHandler { [weak self] in self?.emitFrame() }
        t.resume()
        timer = t
    }

    func stopStream() throws {
        timer?.cancel()
        timer = nil
        frameReader.stop()
    }

    private func emitFrame() {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        if let pb = frameReader.getLatestPixelBuffer() {
            sendBuffer(pb, timestamp: now)
        } else {
            emitBlankFrame(timestamp: now)
        }
    }

    private func emitBlankFrame(timestamp: CMTime) {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        CVPixelBufferCreate(kCFAllocatorDefault, kWidth, kHeight, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
        guard let pb = pixelBuffer else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb) {
            let bpr = CVPixelBufferGetBytesPerRow(pb)
            let ptr = base.assumingMemoryBound(to: UInt8.self)
            let b: UInt8 = frameReader.isConnected ? 0 : 200
            let g: UInt8 = frameReader.isConnected ? 200 : 0
            for y in 0..<kHeight {
                for x in 0..<kWidth {
                    let i = y * bpr + x * 4
                    ptr[i]   = b
                    ptr[i+1] = g
                    ptr[i+2] = 0
                    ptr[i+3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        sendBuffer(pb, timestamp: timestamp)
    }

    private func sendBuffer(_ pb: CVPixelBuffer, timestamp: CMTime) {
        var formatDesc: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &formatDesc)
        guard let fd = formatDesc else { return }

        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(kFrameRate)), presentationTimeStamp: timestamp, decodeTimeStamp: .invalid)
        var sbuf: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescription: fd, sampleTiming: &timing, sampleBufferOut: &sbuf)

        if let sb = sbuf {
            stream.send(sb, discontinuity: [], hostTimeInNanoseconds: UInt64(timestamp.seconds * 1_000_000_000))
        }
    }
}

// MARK: - Device Source

class VDICameraDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private(set) var streamSource: VDICameraStreamSource!

    override init() {
        super.init()
        self.device = CMIOExtensionDevice(localizedName: "VDI Camera", deviceID: UUID(), legacyDeviceID: nil, source: self)
        self.streamSource = VDICameraStreamSource(device: device)
        try! device.addStream(streamSource.stream)
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let props = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            props.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            props.model = "VDI Camera"
        }
        return props
    }

    func setDeviceProperties(_ properties: CMIOExtensionDeviceProperties) throws {}
}

// MARK: - Provider Source

class VDICameraProviderSource: NSObject, CMIOExtensionProviderSource {
    var provider: CMIOExtensionProvider!
    var deviceSource: VDICameraDeviceSource!

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerManufacturer]
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let props = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            props.manufacturer = "OSX VDI"
        }
        return props
    }

    func setProviderProperties(_ properties: CMIOExtensionProviderProperties) throws {}
}

// MARK: - Entry Point

let providerSource = VDICameraProviderSource()
let provider = CMIOExtensionProvider(source: providerSource, clientQueue: nil)
providerSource.provider = provider

let deviceSource = VDICameraDeviceSource()
providerSource.deviceSource = deviceSource
try provider.addDevice(deviceSource.device)

CMIOExtensionProvider.startService(provider: provider)
dispatchMain()
