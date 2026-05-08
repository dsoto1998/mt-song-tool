import Foundation
import AVFoundation
import Accelerate

// MARK: - AlignmentResult

enum AlignmentResult: Equatable {
    /// Positive offsetMs = stem is late (arrives after ORIGINAL SONG). Negative = early.
    case aligned(offsetMs: Double, samples: Int)
    case unableToDetermine
    case skipped

    /// True when the offset is large enough to matter (≥2ms).
    var isActionable: Bool {
        guard case .aligned(let ms, _) = self else { return false }
        return abs(ms) >= 2.0
    }

    var offsetMs: Double? {
        guard case .aligned(let ms, _) = self else { return nil }
        return ms
    }

    var offsetSamples: Int? {
        guard case .aligned(_, let s) = self else { return nil }
        return s
    }

    var displayText: String {
        switch self {
        case .aligned(let ms, let samples):
            let sign = ms >= 0 ? "+" : ""
            let dir = ms >= 0 ? "late" : "early"
            return "\(sign)\(String(format: "%.1f", ms))ms (\(abs(samples)) samples \(dir))"
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
    private static let sampleRate: Double = 44100.0

    // 2-second fingerprint window starting at 1s (skips count-off)
    private static let refStartSeconds: Double = 1.0
    private static let refWindowSeconds: Double = 2.0  // 88200 samples

    // ±300ms search range
    private static let maxOffsetSeconds: Double = 0.3  // 13230 samples each side

    // Peak/RMS confidence ratio — below this, return .unableToDetermine
    private static let confidenceThreshold: Float = 4.0

    // Min RMS to consider signal has content
    private static let minRMS: Float = 1e-4

    static func check(
        url: URL,
        state: StemState,
        referenceURL: URL,
        referenceState: StemState
    ) async -> AlignmentResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: compute(
                    url: url, state: state,
                    refURL: referenceURL, refState: referenceState
                ))
            }
        }
    }

    // MARK: - Core correlation

    private static func compute(
        url: URL, state: StemState,
        refURL: URL, refState: StemState
    ) -> AlignmentResult {
        let sr = sampleRate
        let refLen    = Int(refWindowSeconds * sr)     // 88200
        let maxOff    = Int(maxOffsetSeconds * sr)     // 13230
        let stemStart = max(0.0, refStartSeconds - maxOffsetSeconds)  // 0.7s
        let stemLen   = refLen + 2 * maxOff            // 114660

        guard let refBuf  = renderMono(url: refURL, state: refState,
                                        fromSeconds: refStartSeconds, length: refLen),
              let stemBuf = renderMono(url: url,    state: state,
                                        fromSeconds: stemStart, length: stemLen)
        else { return .unableToDetermine }

        // Abort on silent signals
        var refRms: Float = 0
        vDSP_rmsqv(refBuf, 1, &refRms, vDSP_Length(refLen))
        guard refRms > minRMS else { return .unableToDetermine }

        var stemRms: Float = 0
        vDSP_rmsqv(stemBuf, 1, &stemRms, vDSP_Length(stemLen))
        guard stemRms > minRMS else { return .unableToDetermine }

        // Cross-correlation via vDSP_conv.
        // With B pointer at last element and stride -1:
        //   C[n] = sum_{p=0}^{P-1} A[n+p] * refBuf[p]
        // This is true cross-correlation (not convolution).
        let outputLen = stemLen - refLen + 1   // 2*maxOff + 1 = 26461
        var correlation = [Float](repeating: 0, count: outputLen)

        stemBuf.withUnsafeBufferPointer { stemPtr in
            refBuf.withUnsafeBufferPointer { refPtr in
                vDSP_conv(
                    stemPtr.baseAddress!, 1,
                    refPtr.baseAddress!.advanced(by: refLen - 1), -1,
                    &correlation, 1,
                    vDSP_Length(outputLen), vDSP_Length(refLen)
                )
            }
        }

        // Find correlation peak
        var peakVal: Float = 0
        var peakIdx: vDSP_Length = 0
        vDSP_maxvi(correlation, 1, &peakVal, &peakIdx, vDSP_Length(outputLen))

        // Confidence: peak must stand out from RMS of correlation
        var corrRms: Float = 0
        vDSP_rmsqv(correlation, 1, &corrRms, vDSP_Length(outputLen))
        guard corrRms > 0, peakVal / corrRms >= confidenceThreshold else {
            return .unableToDetermine
        }

        // Lag interpretation:
        //   peakIdx = 0       → stem is maxOff early (stem content starts maxOff before refStart)
        //   peakIdx = maxOff  → aligned
        //   peakIdx = 2*maxOff → stem is maxOff late
        let lagSamples = Int(peakIdx) - maxOff
        let lagMs = Double(lagSamples) / sr * 1000.0

        return .aligned(offsetMs: lagMs, samples: lagSamples)
    }

    // MARK: - Mono rendering

    /// Renders `length` samples of mono audio starting at `fromSeconds` in session time,
    /// applying the AudioSegment model (cuts, moves). Gaps between segments stay zero.
    private static func renderMono(
        url: URL,
        state: StemState,
        fromSeconds: Double,
        length: Int
    ) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let fileSR = file.processingFormat.sampleRate
        let nChannels = Int(file.processingFormat.channelCount)
        let totalFileFrames = Int(file.length)
        guard totalFileFrames > 0, length > 0 else { return nil }

        var output = [Float](repeating: 0, count: length)
        let windowEnd = fromSeconds + Double(length) / fileSR

        // Derive duration from file directly — state.duration may be 0 if peaks haven't loaded yet.
        let fileDuration = Double(totalFileFrames) / fileSR
        let segments: [AudioSegment] = state.segments.isEmpty
            ? [AudioSegment(sourceStart: 0, sourceEnd: fileDuration, sessionStart: 0)]
            : state.segments

        for seg in segments {
            let overlapStart = max(seg.sessionStart, fromSeconds)
            let overlapEnd   = min(seg.sessionEnd,   windowEnd)
            guard overlapEnd > overlapStart + 0.001 else { continue }

            let srcStart = seg.sourceStart + (overlapStart - seg.sessionStart)
            let srcLen   = overlapEnd - overlapStart

            let startFrame = Int(srcStart * fileSR)
            let frameCount = min(Int(ceil(srcLen * fileSR)), totalFileFrames - startFrame)
            guard frameCount > 0, startFrame >= 0, startFrame < totalFileFrames else { continue }

            guard let buf = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(frameCount)
            ) else { continue }

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
