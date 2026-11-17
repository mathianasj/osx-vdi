import Foundation
import AVFoundation
import CoreMedia
import VDICore

final class ClientMediaManager {
    private var cameraCapture: CameraCapture?
    private var cameraFrameNumber: UInt32 = 0

    var onVideoData: ((Data) -> Void)?
    var onCameraStarted: ((Int, Int) -> Void)?
    var onCameraStopped: (() -> Void)?

    func startCamera(width: Int = 1280, height: Int = 720, device: AVCaptureDevice? = nil) {
        stopCamera()

        let capture = CameraCapture(width: width, height: height)
        capture.onEncodedFrame = { [weak self] nalData, isKeyframe, pts, sps, pps in
            self?.handleCameraFrame(nalData: nalData, isKeyframe: isKeyframe, pts: pts, sps: sps, pps: pps)
        }

        if capture.start(device: device) {
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

    func stopAll() {
        stopCamera()
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

}
