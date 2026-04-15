import SwiftUI
import AppKit

// MARK: - Auto-fix normalization

/// Attempts to automatically correct a locator name without losing meaning.
/// Returns the corrected name if one of the normalization passes produces a
/// recognized section label, or nil if the name cannot be auto-corrected.
///
/// Normalization passes (applied in order, first match wins):
///   1. Trim + uppercase + collapse internal space runs   → catches " chorus ", "Verse 1", "VERSE  1"
///   2. Pass 1 + replace "-" or "_" with " "             → catches "VERSE-1", "VERSE_2", "CHORUS-3"
///   3. Pass 2 + replace first " " with "-"              → catches "POST CHORUS", "POST CHORUS 1"
private func autoFixedLocatorName(_ text: String, mtCompleteMode: Bool = false) -> String? {
    guard !LocatorValidator.isValid(text, mtCompleteMode: mtCompleteMode) else { return nil }
    // Collapse every run of whitespace to a single space after trimming
    let base = text.trimmingCharacters(in: .whitespaces).uppercased()
        .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
    if LocatorValidator.isValid(base, mtCompleteMode: mtCompleteMode) { return base }
    let noSeparator = base.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
    if LocatorValidator.isValid(noSeparator, mtCompleteMode: mtCompleteMode) { return noSeparator }
    if let spaceRange = noSeparator.range(of: " ") {
        let firstHyphen = noSeparator.replacingCharacters(in: spaceRange, with: "-")
        if LocatorValidator.isValid(firstHyphen, mtCompleteMode: mtCompleteMode) { return firstHyphen }
    }
    return nil
}

// MARK: - Locator check content (injected into PanelView's content slot)

/// Replaces the plain RowView list for locators.
/// Renders a "Fix All" banner when auto-fixable locators exist, then one
/// LocatorRowView per marker.  Communicates fixes upward via onFix callback.
struct LocatorCheckView: View {
    let markers: [Marker]
    let copyDisabled: Bool
    let onBlocked: () -> Void
    /// Called when one or more locators should be renamed.
    /// Array of (marker, newName) — parent applies the write-back + re-parse.
    let onFix: ([(Marker, String)]) -> Void
    var mtCompleteMode: Bool = false
    var jamNightMode: Bool = false
    var firstTempoChangeMarkerIndex: Int? = nil
    @ObservedObject var stemPlayer: StemPlayerService
    @ObservedObject var audioAnalyzer: AudioAnalyzerService

    /// URL of the ORIGINAL SONG stem, derived live from scan results.
    private var originalSongURL: URL? {
        guard let folder = audioAnalyzer.lastScannedFolder,
              let result = audioAnalyzer.results.first(where: {
                  URL(fileURLWithPath: $0.filename).deletingPathExtension().lastPathComponent.uppercased() == "ORIGINAL SONG"
              }) else { return nil }
        return folder.appendingPathComponent(result.filename)
    }

    private var originalSongDuration: Double {
        audioAnalyzer.results.first(where: {
            URL(fileURLWithPath: $0.filename).deletingPathExtension().lastPathComponent.uppercased() == "ORIGINAL SONG"
        })?.duration ?? 0
    }

    private var pickerOptions: [String] {
        mtCompleteMode
            ? LocatorValidator.sortedSections
            : LocatorValidator.sortedSections.filter { !LocatorValidator.shortCodes.contains($0) }
    }

    // Markers that can be corrected by auto-fix normalization
    private var autoFixable: [(Marker, String)] {
        markers.compactMap { m in
            guard let fixed = autoFixedLocatorName(m.text, mtCompleteMode: mtCompleteMode) else { return nil }
            return (m, fixed)
        }
    }

    private var hasNextSong: Bool {
        markers.contains { $0.text == "NEXT SONG" }
    }

    private var columnHeaders: some View {
        HStack(spacing: 12) {
            Text("#")
                .frame(width: 24, alignment: .trailing)
            Text("TIME START")
                .frame(width: 108, alignment: .leading)
            // Play column — blank header, always reserved
            Text("")
                .frame(width: 12)
            Text("SECTION")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("TIME END")
                .frame(width: 108, alignment: .trailing)
        }
        .font(.lato(size: 10, weight: .semibold))
        .foregroundColor(.fgDim)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    var body: some View {
        VStack(spacing: 0) {
            columnHeaders
            Divider().background(Color.border)

            // Fix All banner — only visible when at least one locator is auto-fixable
            if !autoFixable.isEmpty {
                fixAllBanner
                Divider().background(Color.border)
            }

            ForEach(Array(markers.enumerated()), id: \.element.id) { index, m in
                if index == firstTempoChangeMarkerIndex {
                    tempoChangeDivider
                }
                LocatorRowView(
                    number: index + 1,
                    marker: m,
                    pickerOptions: pickerOptions,
                    mtCompleteMode: mtCompleteMode,
                    copyDisabled: copyDisabled,
                    onBlocked: onBlocked,
                    onFix: { newName in onFix([(m, newName)]) },
                    stemPlayer: stemPlayer,
                    originalSongURL: originalSongURL,
                    originalSongDuration: originalSongDuration
                )
            }

            // Fake placeholder row when NEXT SONG is absent or misspelled
            // Suppressed in MT Complete mode (single-song sessions don't need NEXT SONG)
            // Also suppressed in Jam Night mode
            if !hasNextSong && !mtCompleteMode && !jamNightMode {
                nextSongMissingRow
            }
        }
    }

    private var tempoChangeDivider: some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(Color.accent.opacity(0.5))
                .frame(height: 1)
            Text("1st Tempo Change")
                .font(.lato(size: 10, weight: .semibold))
                .foregroundColor(.accent)
                .fixedSize()
            Rectangle()
                .fill(Color.accent.opacity(0.5))
                .frame(height: 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    private var nextSongMissingRow: some View {
        HStack(spacing: 12) {
            // Number placeholder
            Text("")
                .frame(width: 24)

            // TIME START placeholder (matches fixed width of real rows)
            Text("—")
                .font(.lato(size: 12))
                .foregroundColor(Color.red.opacity(0.4))
                .frame(width: 108, alignment: .leading)

            // Play column placeholder
            Text("")
                .frame(width: 12)

            // Name + missing badge
            HStack(spacing: 6) {
                Text("NEXT SONG")
                    .font(.lato(size: 12))
                    .foregroundColor(Color.red.opacity(0.5))
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.red)
                    Text("Add In Session")
                        .font(.lato(size: 11, weight: .semibold))
                        .foregroundColor(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // TIME END placeholder
            Spacer()
                .frame(width: 108)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.redBg)
    }

    // MARK: Fix All banner

    private var fixAllBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 10))
                .foregroundColor(.orange)
            let n = autoFixable.count
            Text("\(n) locator\(n == 1 ? "" : "s") can be auto-fixed")
                .font(.lato(size: 11))
                .foregroundColor(.orange)
            Spacer()
            Button("Fix All") { onFix(autoFixable) }
                .buttonStyle(CompactSecondaryButtonStyle().hoverable())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.08))
    }
}

// MARK: - Per-locator row

struct LocatorRowView: View {
    let number: Int
    let marker: Marker
    var pickerOptions: [String] = LocatorValidator.sortedSections
    var mtCompleteMode: Bool = false
    var copyDisabled: Bool = false
    var onBlocked: (() -> Void)? = nil
    let onFix: (String) -> Void   // called with a validated new name
    @ObservedObject var stemPlayer: StemPlayerService
    var originalSongURL: URL? = nil
    var originalSongDuration: Double = 0

    @State private var pickerOpen = false
    @State private var pickerSelection = ""
    @State private var dismissedViaEnter = false
    @State private var isHovering = false
    @State private var copied = false
    @State private var copyHover = false
    @State private var copiedEnd = false
    @State private var copyEndHover = false
    @State private var playHover = false
    @State private var pencilHover = false

    private var isInvalid: Bool { !LocatorValidator.isValid(marker.text, mtCompleteMode: mtCompleteMode) }
    private var isBlank: Bool { marker.text.trimmingCharacters(in: .whitespaces).isEmpty }

    private func timeStringToSeconds(_ time: String) -> Double? {
        let parts = time.split(separator: ":")
        // MM:SS:mmm (parser format, e.g. "00:12:973" = 12.973s)
        if parts.count == 3,
           let minutes = Double(parts[0]),
           let seconds = Double(parts[1]),
           let millis = Double(parts[2]) {
            return minutes * 60 + seconds + millis / 1000
        }
        // MM:SS fallback
        if parts.count == 2,
           let minutes = Double(parts[0]),
           let seconds = Double(parts[1]) {
            return minutes * 60 + seconds
        }
        return nil
    }

    private var startSeconds: Double? { timeStringToSeconds(marker.time) }
    private var endSeconds: Double? { marker.timeEnd.isEmpty ? nil : timeStringToSeconds(marker.timeEnd) }

    private var isThisRowActive: Bool {
        guard stemPlayer.isPlaying,
              stemPlayer.playingStemURL == originalSongURL,
              let start = startSeconds else { return false }
        let t = stemPlayer.currentTime
        if let end = endSeconds { return t >= start && t < end }
        return t >= start
    }

    /// The corrected name if any normalization pass lands in the approved list
    private var autoFixedName: String? {
        autoFixedLocatorName(marker.text, mtCompleteMode: mtCompleteMode)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Row number
            Text("\(number)")
                .font(.lato(size: 11))
                .foregroundColor(.fgDim)
                .frame(width: 24, alignment: .trailing)

            // TIME START + copy button
            HStack(spacing: 4) {
                Text(marker.time)
                    .font(.lato(size: 12))
                    .foregroundColor(isInvalid ? Color.red : .accent)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button {
                    if copyDisabled { onBlocked?(); return }
                    if copied { withAnimation(.easeOut(duration: 0.1)) { copied = false }; return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(marker.time, forType: .string)
                    withAnimation(.easeOut(duration: 0.1)) { copied = true }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(copied ? Color.greenLight : (copyHover ? .accent : .fgDim))
                        .frame(width: 20, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(copyHover ? Color.accent.opacity(0.15) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .onHover { h in withAnimation(.easeOut(duration: 0.12)) { copyHover = h } }
            }
            .frame(width: 108, alignment: .leading)

            // Play column — always 12pt wide; button visible only when ORIGINAL SONG is available
            Group {
                if let url = originalSongURL, let start = startSeconds {
                    Button {
                        if isThisRowActive {
                            stemPlayer.stop()
                        } else if let end = endSeconds {
                            stemPlayer.playSection(url: url, start: start, end: end, knownDuration: originalSongDuration)
                        } else {
                            stemPlayer.play(url: url)
                            stemPlayer.seek(to: start)
                        }
                    } label: {
                        Image(systemName: isThisRowActive ? "stop.fill" : "play.fill")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(isThisRowActive || playHover ? .accent : .fgDim)
                            .frame(width: 20, height: 20)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(isThisRowActive || playHover ? Color.accent.opacity(0.15) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .onHover { h in withAnimation(.easeOut(duration: 0.12)) { playHover = h } }
                } else {
                    Color.clear
                }
            }
            .frame(width: 12)

            // NAME — tappable with rename picker; blank rows show "No Name" placeholder
            HStack(spacing: 4) {
                if isBlank {
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.red)
                        Text("No Name")
                            .font(.lato(size: 11, weight: .semibold))
                            .foregroundColor(.red)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .popover(isPresented: $pickerOpen, arrowEdge: .bottom) {
                        PickerPopoverContent(
                            options: pickerOptions,
                            selection: $pickerSelection,
                            isPresented: $pickerOpen,
                            dismissedViaEnter: $dismissedViaEnter
                        )
                    }
                } else {
                    Text(marker.text)
                        .font(.lato(size: 12))
                        .foregroundColor(isInvalid ? Color.red : .fgBright)
                        .lineLimit(1)
                        .popover(isPresented: $pickerOpen, arrowEdge: .bottom) {
                            PickerPopoverContent(
                                options: pickerOptions,
                                selection: $pickerSelection,
                                isPresented: $pickerOpen,
                                dismissedViaEnter: $dismissedViaEnter
                            )
                        }
                }
                if marker.offBeat {
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.red)
                        Text("Not On Beat 1")
                            .font(.lato(size: 11, weight: .semibold))
                            .foregroundColor(.red)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                if isHovering || isBlank {
                    Button {
                        pickerSelection = marker.text
                        pickerOpen = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(pencilHover ? .accent : (isInvalid ? Color.red.opacity(0.7) : .fgMid))
                            .frame(width: 20, height: 20)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(pencilHover ? Color.accent.opacity(0.15) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .onHover { h in withAnimation(.easeOut(duration: 0.12)) { pencilHover = h } }
                    .transition(.opacity)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                pickerSelection = marker.text
                pickerOpen = true
            })
            .onChange(of: pickerOpen) { isOpen in
                if !isOpen && !pickerSelection.isEmpty && pickerSelection != marker.text {
                    onFix(pickerSelection)
                }
            }

            // Fix button — shown when auto-fixable
            if let fixedName = autoFixedName {
                Button("Fix") { onFix(fixedName) }
                    .buttonStyle(CompactSecondaryButtonStyle().hoverable())
            }

            // TIME END + copy button — always renders at fixed width to keep rows aligned
            HStack(spacing: 4) {
                if !marker.timeEnd.isEmpty {
                    Text(marker.timeEnd)
                        .font(.lato(size: 12))
                        .foregroundColor(isInvalid ? Color.red.opacity(0.7) : .fgDim)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        if copyDisabled { onBlocked?(); return }
                        if copiedEnd { withAnimation(.easeOut(duration: 0.1)) { copiedEnd = false }; return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(marker.timeEnd, forType: .string)
                        withAnimation(.easeOut(duration: 0.1)) { copiedEnd = true }
                    } label: {
                        Image(systemName: copiedEnd ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(copiedEnd ? Color.greenLight : (copyEndHover ? .accent : .fgDim))
                            .frame(width: 20, height: 20)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(copyEndHover ? Color.accent.opacity(0.15) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .onHover { h in withAnimation(.easeOut(duration: 0.12)) { copyEndHover = h } }
                }
            }
            .frame(width: 108)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .background(rowBackground)
        .onHover { h in
            withAnimation(.easeOut(duration: 0.08)) { isHovering = h }
            if h && !isBlank { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }

    private var rowBackground: some View {
        Group {
            if isInvalid {
                isHovering ? Color.redBgHov : Color.redBg
            } else if marker.offBeat {
                isHovering ? Color.redBgHov : Color.redBg
            } else {
                isHovering ? Color.bgCardHov : Color.clear
            }
        }
    }
}
