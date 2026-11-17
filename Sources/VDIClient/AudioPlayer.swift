import Foundation
import AVFoundation
import VDICore
import os

final class AudioPlayer {
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var audioFormat: AVAudioFormat?
    private var configuredSampleRate: Double = 0
    private var configuredChannels: UInt32 = 0
    private var outputDeviceID: AudioDeviceID?
    private var pendingBuffers: Int = 0
    private var lock = os_unfair_lock()
    private var dropCount: Int = 0

    func play(header: AudioFrameHeader, data: Data) {
        let sampleRate = Double(header.sampleRate)
        let channels = UInt32(header.channels)

        if engine == nil || sampleRate != configuredSampleRate || channels != configuredChannels {
            configure(sampleRate: sampleRate, channels: channels)
        }

        guard let format = audioFormat, let playerNode = playerNode else { return }

        os_unfair_lock_lock(&lock)
        let pending = pendingBuffers
        os_unfair_lock_unlock(&lock)

        if pending > 3 {
            dropCount += 1
            if dropCount == 1 || dropCount % 100 == 0 {
                print("[AudioPlayer] Dropping frame (pending=\(pending), total dropped=\(dropCount))")
            }
            return
        }

        let frameCount = UInt32(data.count) / (channels * 4)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }

        buffer.frameLength = frameCount

        data.withUnsafeBytes { rawBuf in
            guard let src = rawBuf.baseAddress else { return }
            let srcFloat = src.assumingMemoryBound(to: Float.self)
            let samplesPerChannel = Int(frameCount)
            let chCount = Int(channels)
            for ch in 0..<chCount {
                guard let channelData = buffer.floatChannelData?[ch] else { continue }
                let offset = ch * samplesPerChannel
                memcpy(channelData, srcFloat + offset, samplesPerChannel * MemoryLayout<Float>.size)
            }
        }

        os_unfair_lock_lock(&lock)
        pendingBuffers += 1
        os_unfair_lock_unlock(&lock)

        playerNode.scheduleBuffer(buffer) { [weak self] in
            guard let self = self else { return }
            os_unfair_lock_lock(&self.lock)
            self.pendingBuffers -= 1
            os_unfair_lock_unlock(&self.lock)
        }
    }

    func setOutputDevice(_ deviceID: AudioDeviceID) {
        self.outputDeviceID = deviceID
        if engine != nil {
            configure(sampleRate: configuredSampleRate, channels: configuredChannels)
        }
    }

    private func configure(sampleRate: Double, channels: UInt32) {
        stop()

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ) else {
            print("[AudioPlayer] Failed to create format: \(sampleRate)Hz \(channels)ch")
            return
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        if let deviceID = outputDeviceID {
            do {
                try engine.outputNode.auAudioUnit.setDeviceID(deviceID)
            } catch {
                print("[AudioPlayer] Failed to set output device: \(error)")
            }
        }

        do {
            try engine.start()
            player.play()
            self.engine = engine
            self.playerNode = player
            self.audioFormat = format
            self.configuredSampleRate = sampleRate
            self.configuredChannels = channels
            dropCount = 0
            print("[AudioPlayer] Started: \(sampleRate)Hz \(channels)ch (queue limit: 3)")
        } catch {
            print("[AudioPlayer] Failed to start: \(error)")
        }
    }

    func stop() {
        playerNode?.stop()
        engine?.stop()
        engine = nil
        playerNode = nil
        audioFormat = nil
        configuredSampleRate = 0
        configuredChannels = 0
        os_unfair_lock_lock(&lock)
        pendingBuffers = 0
        os_unfair_lock_unlock(&lock)
    }
}
