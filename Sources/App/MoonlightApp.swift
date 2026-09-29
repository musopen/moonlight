// MoonlightApp.swift
//
// The starting point of the Mac app. It opens the music library database when Moonlight launches,
// shows a recovery screen if that fails, and then builds the main window, menus and Settings
// window. It also handles app-wide events such as registering fonts, starting analytics, and
// asking iCloud sync to fetch or send changes when the app gains or loses focus.

import SwiftUI
import AppKit
import CoreText
import OSLog

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var cloudSync: CloudKitSyncCoordinator?
    private let cloudPushLog = Logger(subsystem: "com.musopen.moonlight", category: "CloudKitPush")

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppFontRegistrar.registerBundledFonts()
        UsageAnalytics.configureIfAvailable()
        UsageAnalytics.logAppOpen()
        NSApplication.shared.registerForRemoteNotifications()
        cloudPushLog.notice("Requested remote-notification registration")
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        // Device tokens are credentials; only record success, never the token.
        cloudPushLog.notice("Remote-notification registration succeeded")
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        cloudPushLog.error("Remote-notification registration failed: \(error.localizedDescription, privacy: .public)")
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        cloudPushLog.notice("Received remote notification with \(userInfo.count, privacy: .public) fields")
        Task { [weak self, cloudPushLog] in
            let accepted = await self?.cloudSync?.handleRemoteNotification(userInfo) ?? false
            cloudPushLog.notice("Remote notification fetch was \(accepted ? "accepted" : "ignored", privacy: .public)")
        }
    }

    // Scene-phase transitions are not consistently delivered for a background
    // macOS app with auxiliary windows (for example, Settings). Keep the
    // foreground freshness guarantee at the AppKit lifecycle boundary instead.
    func applicationDidBecomeActive(_ notification: Notification) {
        cloudPushLog.notice("App became active; requesting foreground CloudKit fetch")
        Task { [weak self] in
            await self?.cloudSync?.synchronize(force: false)
        }
    }

    func applicationWillResignActive(_ notification: Notification) {
        cloudPushLog.notice("App will resign active; flushing CloudKit changes")
        Task { [weak self] in
            await self?.cloudSync?.flushForLifecycleTransition()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func application(_ application: NSApplication, shouldSaveApplicationState coder: NSCoder) -> Bool {
        false
    }

    func application(_ application: NSApplication, shouldRestoreApplicationState coder: NSCoder) -> Bool {
        false
    }
}

enum AppFontRegistrar {
    static func registerBundledFonts() {
        let resourceNames = ["LunabitMono-Regular", "ChicagoFLF"]
        let urls = resourceNames.compactMap { resourceName -> URL? in
            Bundle.main.url(forResource: resourceName, withExtension: "ttf")
                ?? Bundle.main.url(forResource: resourceName, withExtension: "ttf", subdirectory: "Fonts")
                ?? Bundle.main.url(forResource: resourceName, withExtension: "ttf", subdirectory: "Resources/Fonts")
        }

        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

@main
struct MoonlightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var launcher = AppLauncher()

    var body: some Scene {
        WindowGroup {
            Group {
                switch launcher.state {
                case .loading:
                    ProgressView("Opening Moonlight…")
                        .frame(minWidth: 600, minHeight: 400)
                case .ready(let appState):
                    ContentView()
                        .environmentObject(appState)
                        .environmentObject(appState.playbackController)
                        .onAppear { appDelegate.cloudSync = appState.cloudSync }
                case .failed(let message):
                    DatabaseRecoveryView(message: message, retry: launcher.open)
                }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 675, height: 600)
        .commands {
            if let appState = launcher.appState {
                MoonlightCommands(appState: appState)
            }
        }

        Settings {
            if let appState = launcher.appState {
                SettingsView()
                    .environmentObject(appState)
            } else {
                DatabaseRecoveryView(message: launcher.failureMessage, retry: launcher.open)
            }
        }
    }
}

@MainActor
private final class AppLauncher: ObservableObject {
    enum State {
        case loading
        case ready(AppState)
        case failed(String)
    }

    @Published private(set) var state: State = .loading

    var appState: AppState? {
        guard case .ready(let value) = state else { return nil }
        return value
    }

    var failureMessage: String {
        guard case .failed(let message) = state else { return "Moonlight is opening its library." }
        return message
    }

    init() {
        open()
    }

    func open() {
        state = .loading
        Task { [weak self] in
            do {
                let database = try await MobileBackgroundWork.runThrowing {
                    try DatabaseManager()
                }
                guard let self else { return }
                state = .ready(AppState(db: database, startBackgroundTasks: true))
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
        }
    }
}

private struct DatabaseRecoveryView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Library Couldn’t Open", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text("Moonlight could not open or migrate its database. Your audio files were not changed.\n\n\(message)")
        } actions: {
            Button("Try Again", action: retry)
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}
