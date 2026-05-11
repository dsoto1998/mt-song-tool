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

    // Fine-pass parameters
    private static let refWindowSeconds: Double  = 2.0    // 88200 samples
    private static let aidedMaxOffsetSec: Double = 0.15   // ±150ms when guided by coarse
    private static let confidenceThreshold: Float = 4.0   // stricter — rejects spurious peaks
    private static let minRMS: Float              = 1e-4
    private static let probeStep: Double          = 5.0
    private static let probeMaxSeconds: Double    = 360.0
    private static let maxCollect: Int            = 5     // median over up to N windows

    // Coarse-pass parameters (100× downsample → 441 Hz)
    private static let coarseDownsample: Int       = 100
    private static let coarseMaxOffsetSec: Double  = 10.0  // ±10s around the -ogOffset hint

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

    // MARK: - Orchestration

    private static func computeBus(
        stemURLs: [URL],
        stemStates: [URL: StemState],
        refURL: URL,
        refState: StemState
    ) -> AlignmentResult {
        guard let refFile = try? AVAudioFile(forReading: refURL) else { return .unableToDetermine }

        let openStems: [(file: AVAudioFile, state: StemState)] = stemURLs.compactMap { url in
            guard let file = try? AVAudioFile(forReading: url),
                  let state = stemStates[url] else { return nil }
            return (file, state)
        }
        guard !openStems.isEmpty else { return .unableToDetermine }

        let sr         = sampleRate
        let ogOffset   = refState.segments.first?.sessionStart ?? 0
        let refFileDur = Double(refFile.length) / sr
        let minStemDur = openStems.map { Double($0.file.length) / sr }.min() ?? 0
        let probeMax   = min(refFileDur, minStemDur, probeMaxSeconds) + ogOffset

        Log("ogOffset=\(ogOffset)s, probeMax=\(probeMax)s, stems=\(openStems.count)", "Align")

        // Pass 1: coarse probe (±10s at 441 Hz) finds the FILE-CONTENT offset between bus
        // and OG. Invariant to OG's session position — bus window centres on OG's file
        // position, so dragging OG doesn't move the search target.
        guard let fileContentSec = coarseProbe(
            openStems: openStems, refFile: refFile, refState: refState,
            ogOffset: ogOffset, probeMax: probeMax
        ) else {
            Log("Pass 1 returned nil → unableToDetermine", "Align")
            return .unableToDetermine
        }
        Log("Pass 1 file-content offset = \(String(format: "%.3f", fileContentSec))s", "Align")

        // Pass 2: guided fine (±150ms around Pass 1 result) for sub-ms precision.
        let guidedAbs = fineSweep(
            openStems: openStems, refFile: refFile, refState: refState,
            ogOffset: ogOffset, probeMax: probeMax,
            coarseHintSec: fileContentSec, maxOffsetSec: aidedMaxOffsetSec
        )

        // Combine file-content offset with OG drag. Total session-time offset =
        //   file_content_offset - ogOffset.
        // Examples:
        //   Stems exported with 50ms render error, OG not dragged → +50ms
        //   Stems perfectly aligned, OG dragged 20s right → 0 - 20 = -20s (bus 20s early)
        //   Render error + drag → render_error - drag
        let fileContentSamples: Int
        if let fineLag = medianLag(guidedAbs) {
            fileContentSamples = Int(fileContentSec * sr) + fineLag
            Log("Pass 2 fineLag=\(fineLag) refined file-content offset", "Align")
        } else {
            fileContentSamples = Int(fileContentSec * sr)
            Log("Pass 2 failed, using coarse fallback", "Align")
        }
        let totalSamples = fileContentSamples - Int(ogOffset * sr)
        let totalMs = Double(totalSamples) / sr * 1000
        Log("Reported = fileContent \(String(format: "%.1f", Double(fileContentSamples)/sr*1000))ms − ogOffset \(String(format: "%.1f", ogOffset*1000))ms = \(String(format: "%.1f", totalMs))ms", "Align")
        return .aligned(offsetMs: totalMs, samples: totalSamples)
    }

    // MARK: - Fine sweep

    /// Probes multiple windows, collects up to maxCollect confident lag results (in full-rate samples).
    /// When coarseHintSec != 0, the bus window is centred at (matchPosition + coarseHintSec);
    /// returned lags are RELATIVE to the coarse hint — caller must add coarseHintSamples.
    private static func fineSweep(
        openStems: [(file: AVAudioFile, state: StemState)],
        refFile: AVAudioFile,
        refState: StemState,
        ogOffset: Double,
        probeMax: Double,
        coarseHintSec: Double,
        maxOffsetSec: Double
    ) -> [Int] {
        let sr        = sampleRate
        let refLen    = Int(refWindowSeconds * sr)
        let maxOff    = Int(maxOffsetSec * sr)
        let stemLen   = refLen + 2 * maxOff
        let outputLen = stemLen - refLen + 1

        var lags: [Int] = []
        var windowStart = ogOffset + 1.0

        while windowStart + refWindowSeconds <= probeMax, lags.count < maxCollect {
            guard let refBuf = renderMono(state: refState, fromSeconds: windowStart,
                                          length: refLen, file: refFile)
            else { windowStart += probeStep; continue }

            var refRms: Float = 0
            vDSP_rmsqv(refBuf, 1, &refRms, vDSP_Length(refLen))
            guard refRms > minRMS else { windowStart += probeStep; continue }

            // Bus window centred at OG's FILE position (windowStart - ogOffset). This finds
            // file-content alignment — invariant to OG's session position. The drag is
            // folded in at the end of computeBus by subtracting ogOffset from the result.
            let busCenter       = (windowStart - ogOffset) + coarseHintSec
            let intendedBusStart = busCenter - maxOffsetSec
            let busWindowStart  = max(0, intendedBusStart)
            let clampSamples    = Int((busWindowStart - intendedBusStart) * sr)

            var busBuf = [Float](repeating: 0, count: stemLen)
            var activeStemCount = 0

            for (stemFile, stemState) in openStems {
                guard let stemBuf = renderMono(state: stemState, fromSeconds: busWindowStart,
                                               length: stemLen, file: stemFile) else { continue }
                var stemRms: Float = 0
                vDSP_rmsqv(stemBuf, 1, &stemRms, vDSP_Length(stemLen))
                if stemRms > minRMS { activeStemCount += 1 }
                vDSP_vadd(busBuf, 1, stemBuf, 1, &busBuf, 1, vDSP_Length(stemLen))
            }

            guard activeStemCount > 0 else { windowStart += probeStep; continue }

            var scale = 1.0 / Float(openStems.count)
            vDSP_vsmul(busBuf, 1, &scale, &busBuf, 1, vDSP_Length(stemLen))

            var busRms: Float = 0
            vDSP_rmsqv(busBuf, 1, &busRms, vDSP_Length(stemLen))
            guard busRms > minRMS else { windowStart += probeStep; continue }

            // Cross-correlation: C[n] = Σ busBuf[n+p] * refBuf[p]
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

            // lagSamples: 0 = bus at coarseHint position (aligned relative to hint);
            // positive = bus later than hint; negative = bus earlier than hint.
            let lagSamples = (Int(peakIdx) - maxOff) + clampSamples
            lags.append(lagSamples)

            windowStart += probeStep
        }

        return lags
    }

    // MARK: - Coarse probe

    /// One wide-range probe at 441 Hz (100× downsample) covering ±10s around `hintSec`.
    /// Reads a single 22-second bus window.
    /// Returns ABSOLUTE offset in seconds (hint + measured lag), or nil if not confident.
    private static func coarseProbe(
        openStems: [(file: AVAudioFile, state: StemState)],
        refFile: AVAudioFile,
        refState: StemState,
        ogOffset: Double,
        probeMax: Double,
        hintSec: Double = 0
    ) -> Double? {
        let sr         = sampleRate
        let ds         = coarseDownsample                              // 100
        let coarseRate = sr / Double(ds)                              // 441 Hz
        let coarseRefLen  = Int(refWindowSeconds * coarseRate)        // 882
        let coarseMaxOff  = Int(coarseMaxOffsetSec * coarseRate)      // 4410
        let coarseStemLen = coarseRefLen + 2 * coarseMaxOff           // 9702
        let coarseOutLen  = coarseStemLen - coarseRefLen + 1          // 8821

        // Full-rate buffer sizes
        let fullRefLen  = coarseRefLen * ds                           // 88200 (2s)
        let fullStemLen = coarseStemLen * ds                          // 970200 (22s)

        // Scan for first OG window with good content, then run one coarse probe there.
        var windowStart = ogOffset + 1.0
        while windowStart + refWindowSeconds <= probeMax {
            guard let refBuf = renderMono(state: refState, fromSeconds: windowStart,
                                          length: fullRefLen, file: refFile)
            else { windowStart += 10.0; continue }

            var refRms: Float = 0
            vDSP_rmsqv(refBuf, 1, &refRms, vDSP_Length(fullRefLen))
            guard refRms > minRMS else { windowStart += 10.0; continue }

            // Wide bus window: ±coarseMaxOffsetSec around OG's FILE position. Finds the
            // file-content offset, invariant to OG's session position.
            let busCenter        = (windowStart - ogOffset) + hintSec
            let intendedBusStart = busCenter - coarseMaxOffsetSec
            let busWindowStart   = max(0, intendedBusStart)
            let clampSamples441  = Int((busWindowStart - intendedBusStart) * coarseRate)

            var busBuf = [Float](repeating: 0, count: fullStemLen)
            var activeStemCount = 0

            for (stemFile, stemState) in openStems {
                guard let stemBuf = renderMono(state: stemState, fromSeconds: busWindowStart,
                                               length: fullStemLen, file: stemFile) else { continue }
                var stemRms: Float = 0
                vDSP_rmsqv(stemBuf, 1, &stemRms, vDSP_Length(fullStemLen))
                if stemRms > minRMS { activeStemCount += 1 }
                vDSP_vadd(busBuf, 1, stemBuf, 1, &busBuf, 1, vDSP_Length(fullStemLen))
            }

            guard activeStemCount > 0 else { windowStart += 10.0; continue }

            var scale = 1.0 / Float(openStems.count)
            vDSP_vsmul(busBuf, 1, &scale, &busBuf, 1, vDSP_Length(fullStemLen))

            // Downsample to 441 Hz via block averaging.
            let coarseRef = downsampleBlock(refBuf,  factor: ds, outputLength: coarseRefLen)
            let coarseBus = downsampleBlock(busBuf, factor: ds, outputLength: coarseStemLen)

            var cRefRms: Float = 0, cBusRms: Float = 0
            vDSP_rmsqv(coarseRef, 1, &cRefRms, vDSP_Length(coarseRefLen))
            vDSP_rmsqv(coarseBus, 1, &cBusRms, vDSP_Length(coarseStemLen))
            guard cRefRms > minRMS, cBusRms > minRMS else { windowStart += 10.0; continue }

            // Coarse cross-correlation at 441 Hz.
            var correlation = [Float](repeating: 0, count: coarseOutLen)
            coarseBus.withUnsafeBufferPointer { busPtr in
                coarseRef.withUnsafeBufferPointer { refPtr in
                    vDSP_conv(
                        busPtr.baseAddress!, 1,
                        refPtr.baseAddress!.advanced(by: coarseRefLen - 1), -1,
                        &correlation, 1,
                        vDSP_Length(coarseOutLen), vDSP_Length(coarseRefLen)
                    )
                }
            }

            var peakVal: Float = 0
            var peakIdx: vDSP_Length = 0
            vDSP_maxvi(correlation, 1, &peakVal, &peakIdx, vDSP_Length(coarseOutLen))

            var corrRms: Float = 0
            vDSP_rmsqv(correlation, 1, &corrRms, vDSP_Length(coarseOutLen))
            guard corrRms > 0, peakVal / corrRms >= confidenceThreshold else {
                windowStart += 10.0; continue
            }

            // Convert coarse lag (441 Hz samples) → full-rate seconds, add hint for absolute offset.
            let coarseLag441   = (Int(peakIdx) - coarseMaxOff) + clampSamples441
            let measuredSec    = Double(coarseLag441 * ds) / sr
            return hintSec + measuredSec
        }

        return nil
    }

    // MARK: - Helpers

    /// Block-average downsample (signed mean) for the coarse pass.
    private static func downsampleBlock(_ buf: [Float], factor: Int, outputLength: Int) -> [Float] {
        var out = [Float](repeating: 0, count: outputLength)
        let available = buf.count / factor
        let n = min(outputLength, available)
        buf.withUnsafeBufferPointer { bufPtr in
            out.withUnsafeMutableBufferPointer { outPtr in
                for i in 0..<n {
                    var val: Float = 0
                    vDSP_meanv(bufPtr.baseAddress! + i * factor, 1, &val, vDSP_Length(factor))
                    outPtr[i] = val
                }
            }
        }
        return out
    }

    /// Median of a lag array. Returns nil for empty input.
    private static func medianLag(_ lags: [Int]) -> Int? {
        guard !lags.isEmpty else { return nil }
        let sorted = lags.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
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
