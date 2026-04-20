import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Pill shapes for unified MTID + Submit
struct LeftPillShape: Shape {
    var radius: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius),
                 radius: radius, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        p.addArc(center: CGPoint(x: rect.minX + radius, y: rect.minY + radius),
                 radius: radius, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

struct RightPillShape: Shape {
    var radius: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius),
                 radius: radius, startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        p.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius),
                 radius: radius, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Settings pill button (theme/copy-all toggles)
struct SettingsPillButton: View {
    let label: String
    let isActive: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.lato(size: 10, weight: .semibold))
                .foregroundColor(isActive ? .fgBright : (isHovered ? .fgMid : .fgDim))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isActive ? Color.border : (isHovered ? Color.border.opacity(0.4) : Color.clear))
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(.easeOut(duration: 0.1)) { isHovered = h }
            if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }
}

// MARK: - Log Out button with hover
struct LogOutButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text("Log Out")
                .font(.lato(size: 11))
                .foregroundColor(isHovered ? .fgBright : .fgDim)
                .opacity(isHovered ? 1.0 : 0.7)
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = h }
            if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }
}

// MARK: - Drop Zone
struct DropZoneView: View {
    let errorMessage: String?
    var onFolderDrop: ((URL) -> Void)? = nil
    let onDrop: (URL) -> Void

    @State private var isHovering = false
    @State private var isTargeted = false
    @State private var flashBorder = false

    var body: some View {
        ZStack {
            // Background
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovering || isTargeted
                      ? Color.dropHovBg
                      : Color.bgCard)

            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    flashBorder
                        ? Color.dropHovIcon
                        : (isTargeted ? Color.accent : (isHovering ? Color.accent.opacity(0.6) : Color.border)),
                    lineWidth: flashBorder ? 2 : 1
                )
                .animation(.easeInOut(duration: 0.15), value: flashBorder)

            // Content
            VStack(spacing: 12) {
                Image(systemName: isTargeted ? "arrow.down.doc.fill" : "arrow.down.doc")
                    .font(.lato(size: 38, weight: .light))
                    .foregroundColor(isTargeted ? .accent : .fgDim)
                    .animation(.spring(response: 0.25), value: isTargeted)

                VStack(spacing: 4) {
                    Text("Drop your .als or session folder")
                        .font(.lato(size: 16, weight: .medium))
                        .foregroundColor(.fgBright)

                    Text("or click to browse for an .als file")
                        .font(.lato(size: 13))
                        .foregroundColor(.fgDim)
                }

                if let err = errorMessage {
                    Text(err)
                        .font(.lato(size: 12))
                        .foregroundColor(Color.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
        }
        .onTapGesture {
            openFilePicker()
        }
        .onDrop(of: [UTType.fileURL, .folder], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            // loadItem(forTypeIdentifier:) is required on macOS — folders are delivered as
            // bookmark Data via public.file-url, not as URL objects, so loadObject(ofClass: URL.self)
            // silently returns nil for folder drops from Finder.
            let typeId = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                ? UTType.fileURL.identifier : "public.folder"
            Log("provider types=\(provider.registeredTypeIdentifiers) → loading as \(typeId)", "DropZone")
            provider.loadItem(forTypeIdentifier: typeId, options: nil) { item, error in
                Log("loadItem: itemType=\(type(of: item)) error=\(String(describing: error))", "DropZone")
                DispatchQueue.main.async {
                    var url: URL?
                    if let data = item as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else if let u = item as? NSURL {
                        url = u as URL
                    } else if let u = item as? URL {
                        url = u
                    }
                    Log("resolved url=\(url?.path ?? "nil")", "DropZone")
                    guard let url else { return }
                    var isDir: ObjCBool = false
                    FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                    if isDir.boolValue {
                        flashSuccess()
                        onFolderDrop?(url)
                    } else if url.pathExtension.lowercased() == "als" {
                        flashSuccess()
                        onDrop(url)
                    }
                }
            }
            return true
        }
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "als") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an Ableton Live Set (.als)"
        panel.prompt = "Open"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            flashSuccess()
            onDrop(url)
        }
    }

    private func flashSuccess() {
        flashBorder = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            flashBorder = false
        }
    }
}

// MARK: - Panel
struct PanelView<Content: View>: View {
    let title: String
    let icon: String
    let isEmpty: Bool
    let emptyMessage: String
    let copyLabel: String
    let showCopyButton: Bool
    var copyDisabled: Bool = false
    var copyBlockedReason: String = ""
    var onCopyBlocked: (() -> Void)? = nil
    let onCopy: () -> Void
    @ViewBuilder let content: () -> Content

    private var copyBlocked: Bool { isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack {
                Image(systemName: icon)
                    .foregroundColor(.accent)
                    .font(.lato(size: 12, weight: .semibold))
                Text(title)
                    .font(.lato(size: 13, weight: .semibold))
                    .foregroundColor(.fgBright)
                Spacer()
                if showCopyButton {
                    Button(copyLabel) {
                        if copyDisabled { onCopyBlocked?() } else { onCopy() }
                    }
                        .buttonStyle(CompactSecondaryButtonStyle().hoverable())
                        .disabled(copyBlocked)
                        .opacity(copyBlocked ? 0.4 : 1)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 38)

            Divider()
                .background(Color.border)

            if isEmpty {
                Text(emptyMessage)
                    .font(.lato(size: 12))
                    .foregroundColor(.fgDim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        content()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardStyle()
    }
}

// MARK: - Row
struct RowView: View {
    let number: Int
    let left: String
    let right: String
    var isInvalid: Bool = false
    var rampBadge: Bool = false
    var copyDisabled: Bool = false
    var onBlocked: (() -> Void)? = nil
    var leftMinWidth: CGFloat = 0
    var rightMinWidth: CGFloat = 0
    @State private var isHovering = false
    @State private var copied = false
    @State private var buttonHover = false
    @State private var copiedRight = false
    @State private var buttonHoverRight = false

    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.lato(size: 11))
                .foregroundColor(isInvalid ? Color.red : .fgDim)
                .frame(width: 22, alignment: .trailing)

            // TIME + copy button inline, matching LocatorRowView pattern
            HStack(spacing: 4) {
                Text(left)
                    .font(.lato(size: 12))
                    .foregroundColor(isInvalid ? Color.red : .accent)
                    .lineLimit(1)
                    .frame(minWidth: leftMinWidth, alignment: .leading)
                Button {
                    if copyDisabled { onBlocked?(); return }
                    if copied { withAnimation(.easeOut(duration: 0.1)) { copied = false }; return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(left, forType: .string)
                    withAnimation(.easeOut(duration: 0.1)) { copied = true }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(copied ? Color.greenLight : (buttonHover ? .accent : .fgDim))
                        .frame(width: 20, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(buttonHover ? Color.accent.opacity(0.15) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .onHover { h in
                    withAnimation(.easeOut(duration: 0.12)) { buttonHover = h }
                }
            }
            .frame(width: 108, alignment: .leading)

            HStack(spacing: 4) {
                Text(right)
                    .font(.lato(size: 12))
                    .foregroundColor(isInvalid ? Color.red : .fgBright)
                    .lineLimit(1)
                    .frame(minWidth: rightMinWidth, alignment: .leading)
                Button {
                    if copyDisabled { onBlocked?(); return }
                    if copiedRight { withAnimation(.easeOut(duration: 0.1)) { copiedRight = false }; return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(right, forType: .string)
                    withAnimation(.easeOut(duration: 0.1)) { copiedRight = true }
                } label: {
                    Image(systemName: copiedRight ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(copiedRight ? Color.greenLight : (buttonHoverRight ? .accent : .fgDim))
                        .frame(width: 20, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(buttonHoverRight ? Color.accent.opacity(0.15) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .onHover { h in
                    withAnimation(.easeOut(duration: 0.12)) { buttonHoverRight = h }
                }
                if rampBadge {
                    Spacer()
                    Text("RAMP")
                        .font(.lato(size: 10, weight: .bold))
                        .foregroundColor(Color.red)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .background(
            isInvalid
                ? (isHovering ? Color.redBgHov : Color.redBg)
                : (isHovering ? Color.bgCardHov : Color.clear)
        )
        .onHover { h in
            withAnimation(.easeOut(duration: 0.08)) { isHovering = h }
            if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }
}
