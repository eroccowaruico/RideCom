#if os(iOS)
import UIKit
#endif

@MainActor
enum AppBackgroundTime {
    typealias Request = @MainActor (@escaping @MainActor () -> Void) -> (@MainActor () -> Void)?

    static func begin(name: String, expiration: @escaping @MainActor () -> Void) -> (@MainActor () -> Void)? {
        #if os(iOS)
        guard SystemSurfaceScope.permitsSystemAccess else { return nil }
        let application = UIApplication.shared
        let identifier = application.beginBackgroundTask(withName: name) {
            // UIKit calls this synchronously on the main thread.
            MainActor.assumeIsolated { expiration() }
        }
        guard identifier != .invalid else { return nil }
        return { application.endBackgroundTask(identifier) }
        #else
        return nil
        #endif
    }
}
