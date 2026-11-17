import AVFoundation
import Foundation

final class AudioAnalyzer {
    private var engine: AVAudioEngine?
    private var samples: [Float] = []
    private var lock = os_unfair_lock()
    private let sampleRate: Double = 48000

    func analyzeFile(path: String) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            print("ERROR: Cannot read file at \(path)")
            return
        }

        let floatCount = data.count / MemoryLayout<Float>.size
        print("[Analyzer] Read \(floatCount) samples (\(String(format: "%.1f", Double(floatCount) / sampleRate))s) from \(path)")
        print("")

        let captured: [Float] = data.withUnsafeBytes { raw in
            let floatPtr = raw.bindMemory(to: Float.self)
            return Array(floatPtr)
        }

        analyze(samples: captured, sampleRate: sampleRate)
    }

    func record(seconds: Double) {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        print("[Analyzer] Recording format: \(format.sampleRate)Hz \(format.channelCount)ch")
        print("[Analyzer] Recording \(seconds)s of audio from default input...")
        print("[Analyzer] Play audio through VDI now.")
        print("")

        let expectedSamples = Int(format.sampleRate * seconds)
        samples.reserveCapacity(expectedSamples)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self, let data = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            os_unfair_lock_lock(&self.lock)
            self.samples.append(contentsOf: UnsafeBufferPointer(start: data, count: count))
            os_unfair_lock_unlock(&self.lock)
        }

        do {
            try engine.start()
            self.engine = engine
        } catch {
            print("ERROR: Cannot start audio engine: \(error)")
            return
        }

        Thread.sleep(forTimeInterval: seconds)

        inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil

        os_unfair_lock_lock(&lock)
        let captured = samples
        os_unfair_lock_unlock(&lock)

        print("[Analyzer] Captured \(captured.count) samples (\(String(format: "%.1f", Double(captured.count) / format.sampleRate))s)")
        print("")

        analyze(samples: captured, sampleRate: format.sampleRate)
    }

    private func analyze(samples: [Float], sampleRate: Double) {
        guard samples.count > Int(sampleRate * 0.1) else {
            print("Not enough audio captured.")
            return
        }

        // Use 1ms windows for fine-grained analysis
        let windowMs: Double = 1
        let windowSize = Int(sampleRate * windowMs / 1000.0)
        let windowCount = samples.count / windowSize

        var rmsValues: [Double] = []
        var peakValues: [Double] = []
        rmsValues.reserveCapacity(windowCount)
        peakValues.reserveCapacity(windowCount)

        for i in 0..<windowCount {
            let start = i * windowSize
            var sum: Double = 0
            var peak: Double = 0
            for j in start..<(start + windowSize) {
                let s = Double(abs(samples[j]))
                sum += s * s
                if s > peak { peak = s }
            }
            rmsValues.append(sqrt(sum / Double(windowSize)))
            peakValues.append(peak)
        }

        // Estimate noise floor from the quietest 10% of windows
        let sortedRms = rmsValues.sorted()
        let noiseFloorIdx = max(1, windowCount / 10)
        let noiseFloor = sortedRms[noiseFloorIdx]

        // Active audio = windows above 3x noise floor
        let audioThreshold = max(noiseFloor * 3, 0.002)
        let audioWindows = rmsValues.enumerated().filter { $0.element > audioThreshold }

        guard audioWindows.count > windowCount / 10 else {
            print("WARNING: Less than 10% of windows have audio above noise floor.")
            print("  Noise floor: \(String(format: "%.6f", noiseFloor))")
            print("  Threshold: \(String(format: "%.6f", audioThreshold))")
            return
        }

        let audioRms = audioWindows.map { $0.element }.reduce(0, +) / Double(audioWindows.count)
        let firstAudioIdx = audioWindows.first!.offset
        let lastAudioIdx = audioWindows.last!.offset

        // Detect HARD CUT dropouts (buffer underruns)
        // A real underrun: audio is playing, then ABRUPTLY drops to near noise floor
        // Natural pauses: audio fades gradually
        let hardCutThreshold = noiseFloor * 1.5
        var hardDropouts: [(startMs: Double, durationMs: Double, priorRms: Double)] = []
        var softDropouts: [(startMs: Double, durationMs: Double)] = []

        var inDropout = false
        var dropStartIdx = 0
        var priorLevel: Double = 0

        for i in firstAudioIdx...lastAudioIdx {
            if rmsValues[i] < hardCutThreshold {
                if !inDropout {
                    inDropout = true
                    dropStartIdx = i
                    priorLevel = i > 0 ? rmsValues[i - 1] : 0
                }
            } else {
                if inDropout {
                    let durWindows = i - dropStartIdx
                    let durMs = Double(durWindows) * windowMs
                    let startMs = Double(dropStartIdx) * windowMs

                    if durMs >= 3 {
                        let isHardCut = priorLevel > audioThreshold * 2 &&
                                        priorLevel / max(rmsValues[dropStartIdx], 0.00001) > 5.0

                        if isHardCut {
                            hardDropouts.append((startMs: startMs, durationMs: durMs, priorRms: priorLevel))
                        } else {
                            softDropouts.append((startMs: startMs, durationMs: durMs))
                        }
                    }
                    inDropout = false
                }
            }
        }

        // Detect glitches: rapid energy spikes/drops within audio regions
        var glitchCount = 0
        for i in (firstAudioIdx + 1)..<lastAudioIdx {
            if rmsValues[i] > audioThreshold && rmsValues[i - 1] > audioThreshold {
                let ratio = max(rmsValues[i], rmsValues[i - 1]) / max(min(rmsValues[i], rmsValues[i - 1]), 0.00001)
                if ratio > 10 { glitchCount += 1 }
            }
        }

        let activeDurMs = Double(lastAudioIdx - firstAudioIdx) * windowMs

        print("═══════════════════════════════════════════")
        print("  CLIENT AUDIO QUALITY ANALYSIS")
        print("═══════════════════════════════════════════")
        print("")
        print("  SIGNAL LEVEL")
        print("  ────────────")
        print("  Noise floor:           \(String(format: "%.6f", noiseFloor)) RMS")
        print("  Audio threshold:       \(String(format: "%.6f", audioThreshold)) RMS")
        print("  Active audio RMS:      \(String(format: "%.4f", audioRms))")
        print("  Active duration:       \(String(format: "%.1f", activeDurMs / 1000))s")
        print("  Audio coverage:        \(String(format: "%.0f", Double(audioWindows.count) / Double(lastAudioIdx - firstAudioIdx + 1) * 100))%")
        print("")
        print("  BUFFER UNDERRUNS (hard cuts to silence)")
        print("  ────────────────────────────────────────")
        print("  Hard dropouts:         \(hardDropouts.count)")
        if !hardDropouts.isEmpty {
            let totalHardMs = hardDropouts.reduce(0.0) { $0 + $1.durationMs }
            print("  Total dropout time:    \(String(format: "%.0f", totalHardMs))ms")
            print("  Dropout rate:          \(String(format: "%.1f", totalHardMs / activeDurMs * 100))%")
            let durations = hardDropouts.map { $0.durationMs }.sorted()
            print("  Shortest:              \(String(format: "%.0f", durations.first!))ms")
            print("  Longest:               \(String(format: "%.0f", durations.last!))ms")
            print("  Median:                \(String(format: "%.0f", durations[durations.count / 2]))ms")
            print("")
            print("  Dropout details:")
            for (i, d) in hardDropouts.prefix(20).enumerated() {
                print("    #\(i + 1)  \(String(format: "%7.0f", d.startMs))ms  dur=\(String(format: "%.0f", d.durationMs))ms  prior=\(String(format: "%.4f", d.priorRms))")
            }
        }
        print("")
        print("  NATURAL PAUSES (gradual fades)")
        print("  ──────────────────────────────")
        print("  Soft dropouts:         \(softDropouts.count)")
        if !softDropouts.isEmpty {
            let totalSoftMs = softDropouts.reduce(0.0) { $0 + $1.durationMs }
            print("  Total pause time:      \(String(format: "%.0f", totalSoftMs))ms")
        }
        print("")
        print("  GLITCHES (rapid >10x energy change)")
        print("  ────────────────────────────────────")
        print("  Glitch events:         \(glitchCount)")
        print("")

        let quality: String
        if hardDropouts.count == 0 && glitchCount < 5 {
            quality = "EXCELLENT — clean audio, no buffer underruns"
        } else if hardDropouts.count <= 2 && glitchCount < 15 {
            quality = "GOOD — minor imperfections"
        } else if hardDropouts.count <= 5 {
            quality = "FAIR — some buffer underruns detected"
        } else {
            quality = "POOR — frequent buffer underruns"
        }
        print("  VERDICT: \(quality)")
        print("")
        print("═══════════════════════════════════════════")
    }
}
