import Foundation
import AVFoundation
import VDICore

final class AudioPlayer {
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var audioFormat: AVAudioFormat?
    private var configuredSampleRate: Double = 0
    private var configuredChannels: UInt32 = 0

    func play(header: AudioFrameHeader, data: Data) {
        let sampleRate = Double(header.sampleRate)
        let channels = UInt32(header.channels)

        if engine == nil || sampleRate != configuredSampleRate || channels != configuredChannels {
            configure(sampleRate: sampleRate, channels: channels)
        }

        guard let format = audioFormat, let playerNode = playerNode else { return }

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

        playerNode.scheduleBuffer(buffer, completionHandler: nil)
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

        do {
            try engine.start()
            player.play()
            self.engine = engine
            self.playerNode = player
            self.audioFormat = format
            self.configuredSampleRate = sampleRate
            self.configuredChannels = channels
            print("[AudioPlayer] Started: \(sampleRate)Hz \(channels)ch")
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
    }
}
