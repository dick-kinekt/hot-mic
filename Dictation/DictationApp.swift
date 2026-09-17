import AppKit
import KeyboardShortcuts
import SwiftUI

@main
struct DictationApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            DictationMenu(model: delegate.model, showWindow: delegate.showWindow, startDictation: delegate.startDictation)
        } label: {
            StatusIcon(model: delegate.model)
        }
        .menuBarExtraStyle(.menu)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…", action: delegate.showWindow)
                    .keyboardShortcut(",")
            }
            CommandGroup(replacing: .appInfo) {
                Button("About Hot Mic") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: "Hot Mic",
                        .credits: NSAttributedString(string: "For the record.\nBy Kinekt")
                    ])
                }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = DictationSettings()
    private var window: NSWindow?

    lazy var archive = TranscriptArchive(settings: settings)
    lazy var model = TranscriptionCoordinator(settings: settings, archive: archive)
    lazy var recordingBar = RecordingBarController(model: model, openSetup: { [weak self] in
        self?.showWindow()
    })
    lazy var shortcuts = RecordingShortcutController(onActivate: { [weak self] in
        guard let self else { return }
        _ = self.recordingBar
        self.model.togglePresentation()
    })

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        _ = shortcuts
        _ = recordingBar
        showWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing settings does not disable the global shortcut or an active recording.
        false
    }

    func startDictation() {
        _ = recordingBar
        model.start()
    }

    func showWindow() {
        model.refreshPermissions()
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Hot Mic"
            window.minSize = NSSize(width: 780, height: 620)
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.tabbingMode = .disallowed
            window.contentView = NSHostingView(
                rootView: SettingsView(model: model, settings: settings, archive: archive, shortcuts: shortcuts)
            )
            window.center()
            window.setFrameAutosaveName("HotMicSettings")
            self.window = window
        }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        shortcuts.shutdown()
        model.cancel()
        recordingBar.shutdown()
        archive.shutdown()
    }
}

private struct StatusIcon: View {
    @ObservedObject var model: TranscriptionCoordinator

    var body: some View {
        Image(systemName: model.capturing ? "mic.fill" :
            model.state == .finalizing ? "ellipsis.circle" : model.isError ? "exclamationmark.mic" : "mic")
            .accessibilityLabel("Hot Mic: \(model.state.rawValue)")
    }
}

private struct DictationMenu: View {
    @ObservedObject var model: TranscriptionCoordinator
    let showWindow: () -> Void
    let startDictation: () -> Void

    var body: some View {
        Text(model.state.rawValue)
        if model.active {
            Button("Pause & copy") { model.pause() }
                .disabled(model.state == .finalizing || model.isClosing)
        } else {
            Button(model.isPresented && (!model.transcript.isEmpty || model.recordingSeconds > 0)
                   ? "Resume" : "Start dictation", action: startDictation)
                .disabled(model.isClosing)
        }
        if model.isPresented {
            Button("Copy & close") { model.close() }
                .disabled(model.isClosing)
            Button("Cancel dictation") { model.discardAndDismiss() }
        }
        Divider()
        Button("Settings…", action: showWindow)
            .keyboardShortcut(",")
        Button("Quit Hot Mic") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
