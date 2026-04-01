import SwiftUI
import AppKit

// MARK: - Song Data copy button
struct SongDataCopyButton: View {
    let value: String
    @Binding var copied: Bool
    var copyDisabled: Bool = false
    var onBlocked: (() -> Void)? = nil
    @State private var isHovered = false

    private var isBlocked: Bool { value.isEmpty }

    var body: some View {
        Button {
            guard !isBlocked else { return }
            if copyDisabled { onBlocked?(); return }
            if copied { withAnimation(.easeOut(duration: 0.1)) { copied = false }; return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            withAnimation(.easeOut(duration: 0.1)) { copied = true }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(copied ? Color.greenLight : (isHovered ? .accent : .fgDim))
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isHovered ? Color.accent.opacity(0.15) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .disabled(isBlocked)
        .onHover { h in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = h }
            if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .opacity(isBlocked ? 0.3 : 1.0)
        .animation(.easeOut(duration: 0.12), value: isBlocked)
    }
}

// MARK: - Hover-aware checkbox
struct HoverCheckbox: View {
    @Binding var isOn: Bool
    var isFocused: Bool = false
    var onTab: (() -> Void)? = nil
    @State private var isHovered = false
    @State private var keyMonitor: Any? = nil

    private var highlighted: Bool { isHovered || isFocused }

    var body: some View {
        HStack {
            Button {
                isOn.toggle()
            } label: {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundColor(isOn ? .accent : (highlighted ? .fgMid : .fgDim))
                    .brightness(isFocused ? 0.15 : 0)
                    .shadow(color: isFocused ? Color.accent.opacity(0.6) : .clear, radius: 3)
                    .animation(.easeOut(duration: 0.12), value: isFocused)
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(height: 28)
        .contentShape(Rectangle())
        .brightness(isHovered ? 0.1 : 0)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .onHover { h in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = h }
            if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .onChange(of: isFocused) { focused in
            if focused {
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    if event.keyCode == 48 { // Tab
                        onTab?()
                        return nil
                    }
                    if event.keyCode == 49 { // Space
                        isOn.toggle()
                        return nil
                    }
                    return event
                }
            } else {
                if let monitor = keyMonitor {
                    NSEvent.removeMonitor(monitor)
                    keyMonitor = nil
                }
            }
        }
    }
}
