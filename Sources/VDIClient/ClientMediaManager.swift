import Foundation
import CoreMedia
import VDICore

final class ClientMediaManager {
    private var cameraCapture: CameraCapture?
    private var microphoneCapture: MicrophoneCapture?
    private var cameraFrameNumber: UInt32 = 0

    var onVideoData: ((Data) -> Void)?
    var onAudioData: ((Data) -> Void)?
    var onCameraStarted: ((Int, Int) -> Void)?
    var onMicrophoneStarted: ((UInt32, UInt16) -> Void)?
    var onCameraStopped: (() -> Void)?
    var onMicrophoneStopped: (() -> Void)?

    func startCamera(width: Int = 1280, height: Int = 720) {
        stopCamera()

        let capture = CameraCapture(width: width, height: height)
        capture.onEncodedFrame = { [weak self] nalData, isKeyframe, pts, sps, pps in
            self?.handleCameraFrame(nalData: nalData, isKeyframe: isKeyframe, pts: pts, sps: sps, pps: pps)
        }

        if capture.start() {
            cameraCapture = capture
            onCameraStarted?(width, height)
        }
    }

    func stopCamera() {
        guard cameraCapture != nil else { return }
        cameraCapture?.stop()
        cameraCapture = nil
        cameraFrameNumber = 0
        onCameraStopped?()
    }

    func startMicrophone() {
        stopMicrophone()

        let capture = MicrophoneCapture()
        capture.onAudioSample = { [weak self] sampleBuffer in
            self?.handleMicSample(sampleBuffer)
        }

        if capture.start() {
            microphoneCapture = capture
            onMicrophoneStarted?(48000, 1)
        }
    }

    func stopMicrophone() {
        guard microphoneCapture != nil else { return }
        microphoneCapture?.stop()
        microphoneCapture = nil
        onMicrophoneStopped?()
    }

    func stopAll() {
        stopCamera()
        stopMicrophone()
    }

    private func handleCameraFrame(nalData: Data, isKeyframe: Bool, pts: CMTime, sps: Data?, pps: Data?) {
        let header = VideoFrameHeader(
            windowID: 0,
            frameNumber: cameraFrameNumber,
            flags: isKeyframe ? 0x01 : 0x00,
            timestamp: UInt64(pts.value),
            payloadSize: UInt32(nalData.count),
            spsSize: UInt16(sps?.count ?? 0),
            ppsSize: UInt16(pps?.count ?? 0)
        )
        cameraFrameNumber += 1

        let data = MessageCodec.encode(clientVideoHeader: header, sps: sps, pps: pps, payload: nalData)
        onVideoData?(data)
    }

    private func handleMicSample(_ sampleBuffer: CMSampleBuffer) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
        guard let ptr = dataPointer, totalLength > 0 else { return }

        let pcmData = Data(bytes: ptr, count: totalLength)

        var sampleRate: UInt32 = 48000
        var channels: UInt16 = 1
        if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) {
            sampleRate = UInt32(asbd.pointee.mSampleRate)
            channels = UInt16(asbd.pointee.mChannelsPerFrame)
        }

        let header = AudioFrameHeader(
            windowID: 0,
            timestamp: UInt64(pts.value),
            sampleRate: sampleRate,
            channels: channels,
            payloadSize: UInt32(pcmData.count)
        )

        let data = MessageCodec.encode(clientAudioHeader: header, payload: pcmData)
        onAudioData?(data)
    }
}
