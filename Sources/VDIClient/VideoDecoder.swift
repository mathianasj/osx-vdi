import Foundation
import VideoToolbox
import CoreMedia
import VDICore

final class VideoDecoder {
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var currentSPS: Data?
    private var currentPPS: Data?

    var onDecodedFrame: ((CVPixelBuffer, CMTime) -> Void)?

    func decode(frameHeader: VideoFrameHeader, frameData: Data) {
        let nalOffset: Int

        if frameHeader.isKeyframe {
            let spsSize = Int(frameHeader.spsSize)
            let ppsSize = Int(frameHeader.ppsSize)
            let sps = Data(frameData[frameData.startIndex ..< frameData.startIndex + spsSize])
            let pps = Data(frameData[frameData.startIndex + spsSize ..< frameData.startIndex + spsSize + ppsSize])
            nalOffset = spsSize + ppsSize

            if sps != currentSPS || pps != currentPPS {
                currentSPS = sps
                currentPPS = pps
                recreateSession(sps: sps, pps: pps)
            }
        } else {
            nalOffset = 0
        }

        guard let formatDescription = formatDescription, let session = session else { return }

        let nalData = Data(frameData[frameData.startIndex + nalOffset ..< frameData.endIndex])
        guard !nalData.isEmpty else { return }

        guard let blockBuffer = createBlockBuffer(from: nalData) else { return }
        guard let sampleBuffer = createSampleBuffer(blockBuffer: blockBuffer, formatDescription: formatDescription, timestamp: frameHeader.timestamp) else { return }

        var flagsOut: VTDecodeInfoFlags = []
        _ = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: &flagsOut
        ) { [weak self] status, _, imageBuffer, _, pts, _ in
            guard status == noErr, let pixelBuffer = imageBuffer else { return }
            self?.onDecodedFrame?(pixelBuffer, pts)
        }
    }

    private func recreateSession(sps: Data, pps: Data) {
        if let session = session {
            VTDecompressionSessionInvalidate(session)
            self.session = nil
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

        guard status == noErr, let formatDesc = formatDescOut else { return }
        self.formatDescription = formatDesc

        let decoderConfig: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA
        ]

        var sessionOut: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDesc,
            decoderSpecification: nil,
            imageBufferAttributes: decoderConfig as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &sessionOut
        )

        guard createStatus == noErr, let newSession = sessionOut else { return }
        self.session = newSession
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

    deinit {
        if let session = session {
            VTDecompressionSessionInvalidate(session)
        }
    }
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
