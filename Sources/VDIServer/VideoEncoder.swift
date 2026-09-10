import Foundation
import VideoToolbox
import CoreMedia

final class VideoEncoder {
    private var session: VTCompressionSession?
    private var forceNextKeyframe = false
    private let width: Int32
    private let height: Int32

    var onEncodedFrame: ((Data, Bool, CMTime, Data?, Data?) -> Void)?

    init(width: Int, height: Int) throws {
        self.width = Int32(width)
        self.height = Int32(height)

        let encoderSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true
        ]

        var sessionOut: VTCompressionSession?
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        let callback: VTCompressionOutputCallback = { refcon, _, status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer = sampleBuffer, let refcon = refcon else { return }
            let encoder = Unmanaged<VideoEncoder>.fromOpaque(refcon).takeUnretainedValue()
            encoder.handleEncodedFrame(sampleBuffer)
        }

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: self.width,
            height: self.height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: callback,
            refcon: refcon,
            compressionSessionOut: &sessionOut
        )

        guard status == noErr, let session = sessionOut else {
            throw VideoEncoderError.sessionCreationFailed(status)
        }
        self.session = session

        configureSession(session)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    private func configureSession(_ session: VTCompressionSession) {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 120 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: 20_000_000 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    }

    func encode(sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        encode(pixelBuffer: pixelBuffer, presentationTimeStamp: pts)
    }

    func encode(pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime) {
        guard let session = session else { return }

        var properties: [CFString: Any]? = nil
        if forceNextKeyframe {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true]
            forceNextKeyframe = false
        }

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: .invalid,
            frameProperties: properties as CFDictionary?,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
    }

    func forceKeyframe() {
        forceNextKeyframe = true
    }

    private func handleEncodedFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]] else { return }

        let isKeyframe: Bool
        if let notSync = attachments.first?[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKeyframe = !notSync
        } else {
            isKeyframe = true
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        var sps: Data?
        var pps: Data?

        if isKeyframe, let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            sps = extractParameterSet(from: formatDesc, index: 0)
            pps = extractParameterSet(from: formatDesc, index: 1)
        }

        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)

        guard let ptr = dataPointer else { return }
        let nalData = Data(bytes: ptr, count: totalLength)

        onEncodedFrame?(nalData, isKeyframe, pts, sps, pps)
    }

    private func extractParameterSet(from formatDesc: CMFormatDescription, index: Int) -> Data? {
        var parameterSetPointer: UnsafePointer<UInt8>?
        var parameterSetSize: Int = 0

        let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc,
            parameterSetIndex: index,
            parameterSetPointerOut: &parameterSetPointer,
            parameterSetSizeOut: &parameterSetSize,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil
        )

        guard status == noErr, let pointer = parameterSetPointer else { return nil }
        return Data(bytes: pointer, count: parameterSetSize)
    }

    deinit {
        if let session = session {
            VTCompressionSessionInvalidate(session)
        }
    }
}

enum VideoEncoderError: Error {
    case sessionCreationFailed(OSStatus)
}
