import Foundation
import AVFoundation
import Accelerate

// MARK: - AlignmentResult

enum AlignmentResult: Equatable {
    /// Positive offsetMs = stems bus is late vs ORIGINAL SONG. Negative = early.
    case aligned(offsetMs: Double, samples: Int)
    case unableToDetermine
    case skipped

    var isActionable: Bool {
        guard case .aligned(let ms, _) = self else { return false }
        return abs(ms) >= 2.0
    }

    var offsetSamples: Int? {
        guard case .aligned(_, let s) = self else { return nil }
        return s
    }

    var displayText: String {
        switch self {
        case .aligned(let ms, let samples):
            let absMs  = abs(ms)
            let sign   = ms >= 0 ? "+" : "−"
            let dir    = ms >= 0 ? "late" : "early"
            let absSamples = abs(samples)
            if absMs >= 1000 {
                let secs = absMs / 1000.0
                return "\(sign)\(String(format: "%.2f", secs))s (\(absSamples) samples \(dir))"
            } else {
                return "\(sign)\(String(format: "%.1f", absMs))ms (\(absSamples) samples \(dir))"
            }
        case .unableToDetermine:
            return "Unable to determine"
        case .skipped:
            return "—"
        }
    }

    var isInSync: Bool {
        guard case .aligned(let ms, _) = self else { return false }
        return abs(ms) < 2.0
    }
}

// MARK: - AlignmentService

struct AlignmentService {
    static let sampleRate: Double = 44100.0

    // 2-second fingerprint window
    private static let refWindowSeconds: Double = 2.0   // 88200 samples

    // ±300ms search range
    private static let maxOffsetSeconds: Double = 0.3   // 13230 samples each side

    // Peak/RMS confidence gate
    private static let confidenceThreshold: Float = 2.5

    // Min RMS to consider a signal has content
    private static let minRMS: Float = 1e-4

    // Probe parameters — 5s steps, up to 6 min
    private static let probeStep: Double = 5.0
    private static let probeMaxSeconds: Double = 360.0

    // MARK: - Public API

    /// Sums all collective stems into one bus and cross-correlates against ORIGINAL SONG.
    /// Returns a single global offset — all stems shift by the same amount.
    static func checkBus(
        stemURLs: [URL],
        stemStates: [URL: StemState],
        referenceURL: URL,
        referenceState: StemState
    ) async -> AlignmentResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: computeBus(
                    stemURLs: stemURLs, stemStates: stemStates,
                    refURL: referenceURL, refState: referenceState
                ))
            }
        }
    }

    // MARK: - Bus correlation

    private static func computeBus(
        stemURLs: [URL],
        stemStates: [URL: StemState],
        refURL: URL,
        refState: StemState
    ) -> AlignmentResult {
        guard let refFile = try? AVAudioFile(forReading: refURL) else { return .unableToDetermine }

        // Open all stem files upfront — reused across every probe window.
        let openStems: [(file: AVAudioFile, state: StemState)] = stemURLs.compactMap { url in
            guard let file = try? AVAudioFile(forReading: url),
                  let state = stemStates[url] else { return nil }
            return (file, state)
        }
        guard !openStems.isEmpty else { return .unableToDetermine }

        let sr        = sampleRate
        let refLen    = Int(refWindowSeconds * sr)   // 88200
        let maxOff    = Int(maxOffsetSeconds * sr)   // 13230
        let stemLen   = refLen + 2 * maxOff          // 114660
        let outputLen = stemLen - refLen + 1         // 2*maxOff + 1 = 26461

        let refFileDur    = Double(refFile.length) / sr
        let minStemDur    = openStems.map { Double($0.file.length) / sr }.min() ?? 0
        let probeMax      = min(refFileDur, minStemDur, probeMaxSeconds)

        var windowStart = 1.0
        while windowStart + refWindowSeconds <= probeMax {
            let busWindowStart = max(0, windowStart - maxOffsetSeconds)

            guard let refBuf = renderMono(state: refState,
                                           fromSeconds: windowStart, length: refLen,
                                           file: refFile)
            else { windowStart += probeStep; continue }

            var refRms: Float = 0
            vDSP_rmsqv(refBuf, 1, &refRms, vDSP_Length(refLen))
            guard refRms > minRMS else { windowStart += probeStep; continue }

            // Sum all stems into one bus buffer for this window.
            var busBuf = [Float](repeating: 0, count: stemLen)
            var activeStemCount = 0

            for (stemFile, stemState) in openStems {
                guard let stemBuf = renderMono(state: stemState,
                                               fromSeconds: busWindowStart, length: stemLen,
                                               file: stemFile) else { continue }
                var stemRms: Float = 0
                vDSP_rmsqv(stemBuf, 1, &stemRms, vDSP_Length(stemLen))
                if stemRms > minRMS { activeStemCount += 1 }
                vDSP_vadd(busBuf, 1, stemBuf, 1, &busBuf, 1, vDSP_Length(stemLen))
            }

            guard activeStemCount > 0 else { windowStart += probeStep; continue }

            // Normalise bus level.
            var scale = 1.0 / Float(openStems.count)
            vDSP_vsmul(busBuf, 1, &scale, &busBuf, 1, vDSP_Length(stemLen))

            var busRms: Float = 0
            vDSP_rmsqv(busBuf, 1, &busRms, vDSP_Length(stemLen))
            guard busRms > minRMS else { windowStart += probeStep; continue }

            // Cross-correlation via vDSP_conv (negative stride = correlation, not convolution).
            //   C[n] = sum_{p=0}^{P-1} busBuf[n+p] * refBuf[p]
            var correlation = [Float](repeating: 0, count: outputLen)
            busBuf.withUnsafeBufferPointer { busPtr in
                refBuf.withUnsafeBufferPointer { refPtr in
                    vDSP_conv(
                        busPtr.baseAddress!, 1,
                        refPtr.baseAddress!.advanced(by: refLen - 1), -1,
                        &correlation, 1,
                        vDSP_Length(outputLen), vDSP_Length(refLen)
                    )
                }
            }

            var peakVal: Float = 0
            var peakIdx: vDSP_Length = 0
            vDSP_maxvi(correlation, 1, &peakVal, &peakIdx, vDSP_Length(outputLen))

            var corrRms: Float = 0
            vDSP_rmsqv(correlation, 1, &corrRms, vDSP_Length(outputLen))
            guard corrRms > 0, peakVal / corrRms >= confidenceThreshold else {
                windowStart += probeStep; continue
            }

            // Lag: peakIdx=0 → bus maxOff early; peakIdx=maxOff → aligned; peakIdx=2*maxOff → bus maxOff late
            let lagSamples = Int(peakIdx) - maxOff
            let lagMs      = Double(lagSamples) / sr * 1000.0
            return .aligned(offsetMs: lagMs, samples: lagSamples)
        }

        return .unableToDetermine
    }

    // MARK: - Mono rendering

    private static func renderMono(
        state: StemState,
        fromSeconds: Double,
        length: Int,
        file: AVAudioFile
    ) -> [Float]? {
        let fileSR          = file.processingFormat.sampleRate
        let nChannels       = Int(file.processingFormat.channelCount)
        let totalFileFrames = Int(file.length)
        guard totalFileFrames > 0, length > 0 else { return nil }

        var output    = [Float](repeating: 0, count: length)
        let windowEnd = fromSeconds + Double(length) / fileSR
        let fileDur   = Double(totalFileFrames) / fileSR

        let segments: [AudioSegment] = state.segments.isEmpty
            ? [AudioSegment(sourceStart: 0, sourceEnd: fileDur, sessionStart: 0)]
            : state.segments

        for seg in segments {
            let overlapStart = max(seg.sessionStart, fromSeconds)
            let overlapEnd   = min(seg.sessionEnd,   windowEnd)
            guard overlapEnd > overlapStart + 0.001 else { continue }

            let srcStart   = seg.sourceStart + (overlapStart - seg.sessionStart)
            let srcLen     = overlapEnd - overlapStart
            let startFrame = Int(srcStart * fileSR)
            let frameCount = min(Int(ceil(srcLen * fileSR)), totalFileFrames - startFrame)
            guard frameCount > 0, startFrame >= 0, startFrame < totalFileFrames else { continue }

            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                              frameCapacity: AVAudioFrameCount(frameCount))
            else { continue }

            file.framePosition = Int64(startFrame)
            guard (try? file.read(into: buf)) != nil,
                  let ch = buf.floatChannelData else { continue }

            let framesRead = Int(buf.frameLength)
            let outStart   = Int((overlapStart - fromSeconds) * fileSR)
            let writeCount = min(framesRead, length - outStart)
            guard writeCount > 0, outStart >= 0 else { continue }

            output.withUnsafeMutableBufferPointer { outBuf in
                let dest = outBuf.baseAddress!.advanced(by: outStart)
                if nChannels >= 2 {
                    var tmp = [Float](repeating: 0, count: writeCount)
                    vDSP_vadd(ch[0], 1, ch[1], 1, &tmp, 1, vDSP_Length(writeCount))
                    var half: Float = 0.5
                    vDSP_vsmul(tmp, 1, &half, dest, 1, vDSP_Length(writeCount))
                } else {
                    memcpy(dest, ch[0], writeCount * MemoryLayout<Float>.size)
                }
            }
        }

        return output
    }
}
