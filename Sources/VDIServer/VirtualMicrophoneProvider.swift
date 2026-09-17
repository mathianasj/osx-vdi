import Foundation
import VDICore

final class VirtualMicrophoneProvider {
    private let sharedBuffer: SharedFrameBuffer
    private var isActive = false
    private var pollTimer: DispatchSourceTimer?
    private var lastIOActive = false

    var onIOStarted: (() -> Void)?
    var onIOStopped: (() -> Void)?

    init() {
        sharedBuffer = SharedFrameBuffer(name: "vdi-microphone", size: 48000 * 2 * 4)
    }

    func start() {
        guard sharedBuffer.create() else {
            print("[VirtualMic] Failed to create shared memory")
            return
        }
        isActive = true
        startPolling()
        print("[VirtualMic] Provider started")
    }

    func stop() {
        isActive = false
        pollTimer?.cancel()
        pollTimer = nil
        sharedBuffer.destroy()
        print("[VirtualMic] Provider stopped")
    }

    func handleClientAudioFrame(header: AudioFrameHeader, data: Data) {
        guard isActive else { return }
        sharedBuffer.writeAudio(
            sampleRate: header.sampleRate,
            channels: header.channels,
            data: data
        )
    }

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            self?.checkIOState()
        }
        timer.resume()
        pollTimer = timer
    }

    private func checkIOState() {
        let active = sharedBuffer.isIOActive
        if active != lastIOActive {
            lastIOActive = active
            if active {
                print("[VirtualMic] HAL plugin started IO")
                onIOStarted?()
            } else {
                print("[VirtualMic] HAL plugin stopped IO")
                onIOStopped?()
            }
        }
    }
}
