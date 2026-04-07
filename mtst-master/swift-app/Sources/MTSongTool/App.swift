import SwiftUI
import AppKit
import CoreText
import WebKit

@main
struct MTSongToolApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var userSettings = UserSettings.shared

    // Register fonts and pre-warm parser BEFORE any SwiftUI view is created
    init() {
        Self.registerBundledFonts()
        ParserService.warmUp()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 820, height: 680)
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Change Name…") {
                    userSettings.firstName = ""
                    userSettings.lastName = ""
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button("Release Notes…") {
                    NotificationCenter.default.post(name: .mtst_showReleaseNotes, object: nil)
                }
            }
        }
    }

    /// Register fonts from Contents/Resources using the executable path
    private static func registerBundledFonts() {
        let execURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        let resourcesDir = execURL
            .deletingLastPathComponent()   // Contents/MacOS
            .deletingLastPathComponent()   // Contents
            .appendingPathComponent("Resources")

        let fontNames = ["Horizon_Regular.otf", "Lato-Regular.ttf", "Lato-Bold.ttf", "Lato-Light.ttf", "Lato-Black.ttf"]
        for name in fontNames {
            let fontURL = resourcesDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: fontURL.path) {
                var errorRef: Unmanaged<CFError>?
                CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &errorRef)
            }
        }
    }
}

// MARK: - Root view (holds sheet state + window config)

private struct RootView: View {
    @ObservedObject private var userSettings = UserSettings.shared
    @State private var showReleaseNotes = false

    var body: some View {
        Group {
            if userSettings.isLoggedIn {
                ContentView()
            } else {
                LoginView(settings: userSettings)
            }
        }
        .overlay(alignment: .top) {
            WindowDragArea()
                .frame(height: 6)
                .allowsHitTesting(true)
        }
        .preferredColorScheme(userSettings.theme.colorScheme)
        .onAppear {
            configureWindow()
            applyAppAppearance()
        }
        .onChange(of: userSettings.theme) { _ in
            applyAppAppearance()
        }
        .sheet(isPresented: $showReleaseNotes) {
            ReleaseNotesView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mtst_showReleaseNotes)) { _ in
            showReleaseNotes = true
        }
    }

    private func applyAppAppearance() {
        DispatchQueue.main.async {
            switch userSettings.theme {
            case .light:  NSApp.appearance = NSAppearance(named: .aqua)
            case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
            case .system: NSApp.appearance = nil
            }
        }
    }

    private func configureWindow() {
        DispatchQueue.main.async {
            guard let window = NSApplication.shared.windows.first else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = false
            window.backgroundColor = NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return isDark
                    ? NSColor(red: 0.094, green: 0.094, blue: 0.094, alpha: 1)
                    : NSColor(red: 0.961, green: 0.961, blue: 0.969, alpha: 1)
            }
            window.styleMask.insert(.fullSizeContentView)
            window.minSize = NSSize(width: 680, height: 580)
            window.tabbingMode = .disallowed
        }
    }
}

extension Notification.Name {
    static let mtst_showReleaseNotes = Notification.Name("mtst.showReleaseNotes")
}

// MARK: - Window drag handle

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private class DragView: NSView {
        private var pendingDragEvent: NSEvent?

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                pendingDragEvent = nil
                fitToScreen()
            } else {
                pendingDragEvent = event
            }
        }

        override func mouseDragged(with event: NSEvent) {
            if let down = pendingDragEvent {
                pendingDragEvent = nil
                window?.performDrag(with: down)
            }
        }

        override func mouseUp(with event: NSEvent) {
            pendingDragEvent = nil
        }

        private func fitToScreen() {
            guard let window = window,
                  let screen = window.screen ?? NSScreen.main else { return }
            let visibleFrame = screen.visibleFrame
            let currentFrame = window.frame
            let newFrame = NSRect(
                x: currentFrame.minX,
                y: visibleFrame.minY,
                width: currentFrame.width,
                height: visibleFrame.height
            )
            window.setFrame(newFrame, display: true, animate: true)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

// MARK: - Release Notes sheet

struct ReleaseNotesView: View {
    @Environment(\.dismiss) private var dismiss

    private var html: String {
        guard let url = Bundle.module.url(forResource: "Release Notes", withExtension: "md"),
              let raw = try? String(contentsOf: url, encoding: .utf8)
        else { return releaseNotesWrapHTML("<p>Release notes not found.</p>") }
        return releaseNotesMarkdownToHTML(raw)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ReleaseNotesWebView(html: html)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.fgMid)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.border.opacity(0.6)))
            }
            .buttonStyle(.plain)
            .padding(12)
            .onHover { h in h ? NSCursor.pointingHand.set() : NSCursor.arrow.set() }
        }
        .frame(width: 680, height: 560)
    }
}

private struct ReleaseNotesWebView: NSViewRepresentable {
    let html: String
    func makeNSView(context: Context) -> WKWebView {
        let wv = WKWebView()
        wv.loadHTMLString(html, baseURL: nil)
        return wv
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

private func releaseNotesMarkdownToHTML(_ markdown: String) -> String {
    var body = ""
    var inList = false
    var inParagraph = false

    func inline(_ s: String) -> String {
        var r = s
        r = r.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "<strong>$1</strong>", options: .regularExpression)
        r = r.replacingOccurrences(of: #"`(.+?)`"#,       with: "<code>$1</code>",     options: .regularExpression)
        return r
    }

    for line in markdown.components(separatedBy: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty {
            if inParagraph { body += "</p>\n"; inParagraph = false }
            if inList      { body += "</ul>\n"; inList = false }
        } else if t.hasPrefix("#### ") {
            if inParagraph { body += "</p>\n"; inParagraph = false }
            if inList      { body += "</ul>\n"; inList = false }
            body += "<h4>\(inline(String(t.dropFirst(5))))</h4>\n"
        } else if t.hasPrefix("### ") {
            if inParagraph { body += "</p>\n"; inParagraph = false }
            if inList      { body += "</ul>\n"; inList = false }
            body += "<h3>\(inline(String(t.dropFirst(4))))</h3>\n"
        } else if t.hasPrefix("## ") {
            if inParagraph { body += "</p>\n"; inParagraph = false }
            if inList      { body += "</ul>\n"; inList = false }
            body += "<h2>\(inline(String(t.dropFirst(3))))</h2>\n"
        } else if t.hasPrefix("# ") {
            if inParagraph { body += "</p>\n"; inParagraph = false }
            if inList      { body += "</ul>\n"; inList = false }
            body += "<h1>\(inline(String(t.dropFirst(2))))</h1>\n"
        } else if t.hasPrefix("- ") {
            if inParagraph { body += "</p>\n"; inParagraph = false }
            if !inList     { body += "<ul>\n"; inList = true }
            body += "  <li>\(inline(String(t.dropFirst(2))))</li>\n"
        } else {
            if inList { body += "</ul>\n"; inList = false }
            if !inParagraph { body += "<p>"; inParagraph = true } else { body += " " }
            body += inline(t)
        }
    }
    if inParagraph { body += "</p>\n" }
    if inList      { body += "</ul>\n" }

    return releaseNotesWrapHTML(body)
}

private func releaseNotesWrapHTML(_ body: String) -> String {
    """
    <!DOCTYPE html><html><head><meta charset="utf-8"><style>
    :root { color-scheme: light dark; }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; font-size: 13px; line-height: 1.6; padding: 24px 28px; max-width: 640px; margin: 0 auto; }
    @media (prefers-color-scheme: dark) {
        body { color: #e5e7eb; background: #1e1e1e; }
        code { background: #2d2d2d; color: #c4b5fd; }
        h3 { border-bottom: 1px solid #333; }
    }
    @media (prefers-color-scheme: light) {
        body { color: #1f2937; background: #ffffff; }
        code { background: #f3f4f6; color: #7c3aed; }
        h3 { border-bottom: 1px solid #e5e7eb; }
    }
    h1 { font-size: 20px; font-weight: 700; margin-bottom: 4px; }
    h2 { font-size: 15px; font-weight: 600; margin-top: 32px; margin-bottom: 8px; opacity: 0.6; }
    h3 { font-size: 13px; font-weight: 600; padding-bottom: 6px; margin-top: 24px; margin-bottom: 10px; }
    h4 { font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.06em; opacity: 0.5; margin-top: 16px; margin-bottom: 6px; }
    ul { padding-left: 18px; margin: 4px 0; }
    li { margin: 5px 0; }
    code { font-family: "SF Mono", Menlo, monospace; font-size: 11px; padding: 1px 5px; border-radius: 4px; }
    strong { font-weight: 600; }
    p { margin: 6px 0; }
    </style></head><body>
    \(body)
    </body></html>
    """
}
