import UIKit

/// Supplies the interface orientations the app allows at the moment (see `OrientationLock`).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }
}

/// Locks the interface to landscape for full screen and releases it afterwards.
///
/// Leaving full screen on an iPhone rotates back to portrait and keeps portrait until the device itself
/// is held upright; otherwise a phone still held sideways would rotate straight back to landscape.
@MainActor
enum OrientationLock {
    private static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private static var defaultMask: UIInterfaceOrientationMask { isPad ? .all : .allButUpsideDown }
    private static var locked: UIInterfaceOrientationMask?
    private static var observer: NSObjectProtocol?
    /// Bumped on every release so a delayed unlock from an earlier one does nothing.
    private static var generation = 0

    static var mask: UIInterfaceOrientationMask { locked ?? defaultMask }

    static func lockLandscape() {
        stopObserving()
        generation += 1
        apply(.landscape)
    }

    static func release() {
        stopObserving()
        generation += 1
        if isPad {
            apply(nil)
            return
        }
        // The interface may be landscape while the phone is held upright (full screen was chosen with the
        // button), so always ask for portrait first.
        apply(.portrait)
        if UIDevice.current.orientation.isPortrait {
            // Unlock once the rotation has been requested; the device keeps it in portrait.
            let g = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                if g == generation, locked == .portrait { apply(nil) }
            }
            return
        }
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        observer = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard UIDevice.current.orientation.isPortrait else { return }
                stopObserving()
                apply(nil)
            }
        }
    }

    private static func stopObserving() {
        guard let observer else { return }
        NotificationCenter.default.removeObserver(observer)
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        self.observer = nil
    }

    private static func apply(_ lock: UIInterfaceOrientationMask?) {
        locked = lock
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            if let lock {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: lock)) { _ in }
            }
        }
    }
}
