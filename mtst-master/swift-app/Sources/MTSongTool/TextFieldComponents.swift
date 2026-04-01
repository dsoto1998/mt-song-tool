import SwiftUI
import AppKit

// MARK: - Song Data TextField (hover-aware, Tab-intercepting)
struct SongDataTextFieldView: View {
    @Binding var text: String
    let placeholder: String
    let numbersOnly: Bool
    var isMissing: Bool = false
    var isFocused: Bool = false
    var onTab: (() -> Void)? = nil
    var onFocus: (() -> Void)? = nil
    @State private var isHovered = false

    private var highlighted: Bool { isHovered || isFocused }

    var body: some View {
        SongDataNSTextField(text: $text, placeholder: placeholder, numbersOnly: numbersOnly, isFocused: isFocused, onTab: onTab ?? {}, onFocus: onFocus)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.inputBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(isMissing ? Color.red : (highlighted ? Color.accent.opacity(0.5) : Color.border), lineWidth: isMissing ? 1.5 : 1)
                    )
            )
            .animation(.easeOut(duration: 0.2), value: isMissing)
            .brightness(highlighted ? 0.07 : 0)
            .scaleEffect(highlighted ? 1.01 : 1.0)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.12), value: isFocused)
            .onHover { h in
                withAnimation(.easeOut(duration: 0.12)) { isHovered = h }
            }
    }
}

// MARK: - NSViewRepresentable text field with Tab interception
struct SongDataNSTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let numbersOnly: Bool
    var isFocused: Bool
    var onTab: () -> Void
    var onFocus: (() -> Void)?
    var onEnter: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ManagedNSTextField {
        let field = ManagedNSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont(name: "Lato-Regular", size: 12) ?? .systemFont(ofSize: 12)
        field.textColor = NSColor(Color.fgBright)
        field.placeholderString = placeholder
        field.cell?.lineBreakMode = .byClipping
        (field.cell as? NSTextFieldCell)?.wraps = false
        field.allowFocus = isFocused
        return field
    }

    func updateNSView(_ nsView: ManagedNSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        context.coordinator.parent = self
        nsView.allowFocus = isFocused
        // Programmatic focus
        if isFocused {
            DispatchQueue.main.async {
                if nsView.window?.firstResponder != nsView && nsView.window?.firstResponder != nsView.currentEditor() {
                    nsView.window?.makeFirstResponder(nsView)
                }
            }
        }
    }

    /// NSTextField subclass that refuses focus unless explicitly allowed
    /// or the user is directly interacting (mouse inside the field).
    /// Prevents macOS from auto-focusing this field when a popover closes.
    class ManagedNSTextField: NSTextField {
        var allowFocus: Bool = false
        private var mouseInside = false

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil))
        }
        override func mouseEntered(with event: NSEvent) { mouseInside = true }
        override func mouseExited(with event: NSEvent) { mouseInside = false }
        override var acceptsFirstResponder: Bool { allowFocus || mouseInside }
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SongDataNSTextField
        init(_ parent: SongDataNSTextField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            var val = field.stringValue
            if parent.numbersOnly {
                val = val.filter { $0.isNumber || $0 == "." }
                if val != field.stringValue { field.stringValue = val }
            }
            parent.text = val
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            parent.onFocus?()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.insertTab(_:)) {
                parent.onTab()
                return true
            }
            if sel == #selector(NSResponder.insertNewline(_:)) {
                parent.onEnter?()
                return true
            }
            return false
        }
    }
}
