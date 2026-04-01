import SwiftUI
import AppKit

// MARK: - Song Data Picker (custom popover with search)
struct SongDataPickerView: View {
    @Binding var selection: String
    let options: [String]
    let placeholder: String
    var isMissing: Bool = false
    var onEnter: (() -> Void)? = nil
    var onTab: (() -> Void)? = nil
    @Binding var triggerOpen: Bool
    @State private var isHovered = false
    @State private var showPopover = false
    @State private var stayFocused = false
    @State private var keyMonitor: Any? = nil

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(selection.isEmpty ? placeholder : selection)
                    .font(.lato(size: 12))
                    .foregroundColor(selection.isEmpty ? .fgDim : .fgBright)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.fgDim)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.inputBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(
                                isMissing ? Color.red : ((isHovered || stayFocused) ? Color.accent.opacity(0.5) : Color.border),
                                lineWidth: isMissing ? 1.5 : 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .brightness((isHovered || stayFocused) ? 0.07 : 0)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: stayFocused)
        .animation(.easeOut(duration: 0.2), value: isMissing)
        .onHover { h in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = h }
            if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            if !h && stayFocused {
                withAnimation(.easeOut(duration: 0.12)) { stayFocused = false }
            }
        }
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            PickerPopoverContent(
                options: options,
                selection: $selection,
                isPresented: $showPopover,
                dismissedViaEnter: $stayFocused,
                onEnterOut: onEnter,
                onTabOut: onTab
            )
        }
        .onChange(of: triggerOpen) { open in
            if open {
                showPopover = true
                triggerOpen = false
            }
        }
        .onChange(of: stayFocused) { focused in
            if focused {
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    if event.keyCode == 48 { // Tab
                        stayFocused = false
                        onTab?()
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

// MARK: - Picker popover content (search + keyboard nav + hover)
struct PickerPopoverContent: View {
    let options: [String]
    @Binding var selection: String
    @Binding var isPresented: Bool
    @Binding var dismissedViaEnter: Bool
    var onEnterOut: (() -> Void)? = nil
    var onTabOut: (() -> Void)? = nil
    @State private var searchText: String = ""
    @State private var highlightedIndex: Int = -1
    @State private var scrollTarget: Int? = nil

    private var filteredOptions: [String] {
        if searchText.isEmpty { return options }
        let query = searchText.lowercased()
        return options
            .filter { $0.lowercased().hasPrefix(query) }
            .sorted { a, b in
                let aPri = Self.keyModifierPriority(a)
                let bPri = Self.keyModifierPriority(b)
                if aPri != bPri { return aPri < bPri }
                return a < b
            }
    }

    /// Sort priority: plain=0, minor=1, flat=2, flat minor=3, sharp=4, sharp minor=5
    private static func keyModifierPriority(_ key: String) -> Int {
        guard let first = key.first, first.isLetter else { return 0 }
        let suffix = String(key.dropFirst())
        switch suffix {
        case "":   return 0
        case "m":  return 1
        case "b":  return 2
        case "bm": return 3
        case "#":  return 4
        case "#m": return 5
        default:   return 0
        }
    }

    private func applySelection() {
        if highlightedIndex >= 0 && highlightedIndex < filteredOptions.count {
            selection = filteredOptions[highlightedIndex]
        } else if filteredOptions.count == 1 {
            selection = filteredOptions[0]
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PickerSearchField(
                text: $searchText,
                onUp: {
                    let idx = highlightedIndex > 0 ? highlightedIndex - 1 : filteredOptions.count - 1
                    highlightedIndex = idx
                    scrollTarget = idx
                },
                onDown: {
                    let idx = highlightedIndex < filteredOptions.count - 1 ? highlightedIndex + 1 : 0
                    highlightedIndex = idx
                    scrollTarget = idx
                },
                onEnter: {
                    applySelection()
                    dismissedViaEnter = true
                    isPresented = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { onEnterOut?() }
                },
                onTab: {
                    applySelection()
                    dismissedViaEnter = false
                    isPresented = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { onTabOut?() }
                },
                onEscape: { isPresented = false }
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.inputBg)

            Divider().background(Color.border)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(filteredOptions.enumerated()), id: \.element) { index, option in
                            PickerOptionRow(
                                option: option,
                                isSelected: selection == option,
                                isHighlighted: highlightedIndex == index
                            ) {
                                selection = option
                                isPresented = false
                            }
                            .onHover { h in
                                if h { highlightedIndex = index }
                            }
                            .id(index)
                        }
                    }
                }
                .onChange(of: scrollTarget) { idx in
                    if let idx, idx >= 0 && idx < filteredOptions.count {
                        proxy.scrollTo(idx, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 160, height: min(CGFloat(options.count) * 28 + 34, 260))
        .onAppear {
            searchText = ""
            if let idx = filteredOptions.firstIndex(of: selection) {
                highlightedIndex = idx
            } else {
                highlightedIndex = 0
            }
        }
        .onChange(of: searchText) { _ in
            highlightedIndex = filteredOptions.isEmpty ? -1 : 0
        }
    }
}

// MARK: - Auto-focused search field with key interception
struct PickerSearchField: NSViewRepresentable {
    @Binding var text: String
    let onUp: () -> Void
    let onDown: () -> Void
    let onEnter: () -> Void
    let onTab: () -> Void
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = SearchNSTextField()
        field.delegate = context.coordinator
        field.coordinator = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont(name: "Lato-Regular", size: 11) ?? .systemFont(ofSize: 11)
        field.textColor = NSColor(Color.fgBright)
        field.placeholderString = "Type to search…"
        field.cell?.lineBreakMode = .byClipping
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PickerSearchField
        init(_ parent: PickerSearchField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSTextField { parent.text = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.moveUp(_:)) { parent.onUp(); return true }
            if sel == #selector(NSResponder.moveDown(_:)) { parent.onDown(); return true }
            if sel == #selector(NSResponder.insertNewline(_:)) { parent.onEnter(); return true }
            if sel == #selector(NSResponder.insertTab(_:)) { parent.onTab(); return true }
            if sel == #selector(NSResponder.cancelOperation(_:)) { parent.onEscape(); return true }
            return false
        }
    }

    class SearchNSTextField: NSTextField {
        weak var coordinator: Coordinator?
    }
}

// MARK: - Picker option row (hover-aware)
struct PickerOptionRow: View {
    let option: String
    let isSelected: Bool
    var isHighlighted: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(option)
                    .font(.lato(size: 12))
                    .foregroundColor(isSelected ? .accent : (isHighlighted ? .fgBright : .fgMid))
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.accent)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .contentShape(Rectangle())
            .background(isHighlighted ? Color.bgCardHov : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { h in
            if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }
}
