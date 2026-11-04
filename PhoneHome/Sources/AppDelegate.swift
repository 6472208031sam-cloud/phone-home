import UIKit
import BackgroundTasks
import CoreLocation

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    /// Must match project.yml's BGTaskSchedulerPermittedIdentifiers and the
    /// `fetch` background mode. Same shape as the Bus iOS refresh pattern.
    static let refreshTaskID = "io.github.phonehome.refresh"

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // BGTaskScheduler registration must happen BEFORE launch finishes.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskID, using: nil) { task in
            Self.handleAppRefresh(task as! BGAppRefreshTask)
        }
        Self.scheduleAppRefresh()
        Beacon.shared.requestAuthorization()
        Beacon.shared.startSignificantChanges()
        if launchOptions?[.location] != nil {
            // iOS relaunched the app for a significant-change event.
            Beacon.shared.log("WAKE", "launched by a location event (significant-change relaunch)")
            Beacon.shared.movedWake()
        }
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = ViewController()
        window?.makeKeyAndVisible()
        // First launch with permission already granted: join + first ping.
        let status = CLLocationManager().authorizationStatus
        if (status == .authorizedWhenInUse || status == .authorizedAlways) && !Beacon.shared.everWrote {
            Beacon.shared.runWake(src: "first") {}
        }
        return true
    }

    /// Asks iOS for a background-refresh slot ~1h out; +1h is a FLOOR —
    /// iOS alone decides if/when it runs (the honest-cadence contract).
    static func scheduleAppRefresh() {
        let status = UIApplication.shared.backgroundRefreshStatus
        Beacon.shared.log("ARM", "backgroundRefreshStatus=\(status.rawValue) (0=restricted 1=denied/off 2=available)")
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            let next = Date(timeIntervalSinceNow: 60 * 60)
            UserDefaults.standard.set(next.timeIntervalSince1970, forKey: "ph_nextWake")
            Beacon.shared.log("ARM", "BG refresh submitted, earliest \(Beacon.stamp(next))")
        } catch {
            Beacon.shared.log("ARM", "BG refresh submit FAILED: \(error.localizedDescription)")
        }
    }

    /// iOS woke the app: run one beacon cycle, then book the next slot.
    private static func handleAppRefresh(_ task: BGAppRefreshTask) {
        Beacon.shared.log("WAKE", "BGAppRefresh fired")
        Beacon.shared.startSignificantChanges() // re-arm movement wakes on every refresh wake too
        var finished = false
        task.expirationHandler = {
            if !finished {
                finished = true
                Beacon.shared.log("WAKE", "BG refresh expired before the cycle finished")
                task.setTaskCompleted(success: false)
            }
        }
        Beacon.shared.runWake(src: Beacon.shared.everWrote ? "hourly" : "first") {
            scheduleAppRefresh()
            if !finished {
                finished = true
                task.setTaskCompleted(success: true)
            }
        }
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        Self.scheduleAppRefresh()
    }
}
