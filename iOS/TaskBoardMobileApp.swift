import SwiftUI
import UIKit

@main
struct TaskBoardMobileApp: App {
    @UIApplicationDelegateAdaptor(MobileAppDelegate.self) private var appDelegate
    @State private var store = TaskBoardStore()

    var body: some Scene {
        WindowGroup {
            MobileBoardView(store: store)
                .preferredColorScheme(.dark)
                .onReceive(NotificationCenter.default.publisher(for: .cloudKitDataDidChange)) { _ in
                    store.handleRemoteNotification()
                }
        }
    }
}

final class MobileAppDelegate: NSObject, UIApplicationDelegate {
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
        NotificationCenter.default.post(name: .cloudKitDataDidChange, object: nil)
        completionHandler(.newData)
    }
}
