// MoonlightMobileApp.swift
//
// The starting point of the iPhone and iPad app. On launch it opens the library database and then
// shows the main screens, or a "Library Couldn't Open" screen with a retry button if that fails.
// It also passes iCloud change notifications to the sync system and tells the library when the app
// moves to or from the background.

import SwiftUI
import UIKit

final class MobileAppDelegate: NSObject, UIApplicationDelegate {
    weak var cloudSync: CloudKitSyncCoordinator?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard let cloudSync else {
            completionHandler(.noData)
            return
        }
        Task {
            let handled = await cloudSync.handleRemoteNotification(userInfo)
            completionHandler(handled ? .newData : .noData)
        }
    }
}

@main
struct MoonlightMobileApp: App {
    @UIApplicationDelegateAdaptor(MobileAppDelegate.self) private var appDelegate
    @StateObject private var launcher = MobileAppLauncher()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                switch launcher.state {
                case .loading:
                    ProgressView("Opening Moonlight…")
                case .ready(let library):
                    MobileRootView()
                        .environmentObject(library)
                        .environmentObject(library.playback)
                        .onAppear { appDelegate.cloudSync = library.cloudSync }
                        .onChange(of: scenePhase) { _, phase in
                            library.handleScenePhase(phase)
                        }
                case .failed(let message):
                    MobileDatabaseRecoveryView(message: message, retry: launcher.open)
                }
            }
        }
    }
}

@MainActor
private final class MobileAppLauncher: ObservableObject {
    enum State {
        case loading
        case ready(MobileLibraryModel)
        case failed(String)
    }

    @Published private(set) var state: State = .loading

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
                self?.state = .ready(MobileLibraryModel(database: database))
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
        }
    }
}

private struct MobileDatabaseRecoveryView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Library Couldn’t Open", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text("Moonlight could not open or migrate its database. Your imported audio is still in the Files app.\n\n\(message)")
        } actions: {
            Button("Try Again", action: retry)
        }
    }
}
