import SwiftUI
import AppKit
import CoreText

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
            Group {
                if userSettings.isLoggedIn {
                    ContentView()
                } else {
                    LoginView(settings: userSettings)
                }
            }
            .preferredColorScheme(userSettings.theme.colorScheme)
            .onAppear {
                configureWindow()
                applyAppAppearance()
            }
            .onChange(of: userSettings.theme) { _ in
                applyAppAppearance()
            }
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
        }
    }

    /// Register fonts from Contents/Resources using the executable path
    private static func registerBundledFonts() {
        // Resolve path: executable is in Contents/MacOS, font is in Contents/Resources
        let execURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        let macosDir = execURL.deletingLastPathComponent()           // Contents/MacOS
        let contentsDir = macosDir.deletingLastPathComponent()       // Contents
        let resourcesDir = contentsDir.appendingPathComponent("Resources")

        let fontNames = ["Horizon_Regular.otf", "Lato-Regular.ttf", "Lato-Bold.ttf", "Lato-Light.ttf", "Lato-Black.ttf"]
        for name in fontNames {
            let fontURL = resourcesDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: fontURL.path) {
                var errorRef: Unmanaged<CFError>?
                CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &errorRef)
            }
        }
    }

    /// Sync NSApp.appearance with the user's theme choice.
    /// nil = follow system, otherwise force light/dark.
    private func applyAppAppearance() {
        DispatchQueue.main.async {
            switch userSettings.theme {
            case .light:
                NSApp.appearance = NSAppearance(named: .aqua)
            case .dark:
                NSApp.appearance = NSAppearance(named: .darkAqua)
            case .system:
                NSApp.appearance = nil   // inherit from macOS
            }
        }
    }

    private func configureWindow() {
        DispatchQueue.main.async {
            guard let window = NSApplication.shared.windows.first else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.backgroundColor = NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return isDark
                    ? NSColor(red: 0.094, green: 0.094, blue: 0.094, alpha: 1)
                    : NSColor(red: 0.961, green: 0.961, blue: 0.969, alpha: 1)
            }
            window.styleMask.insert(.fullSizeContentView)
            window.minSize = NSSize(width: 680, height: 580)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
