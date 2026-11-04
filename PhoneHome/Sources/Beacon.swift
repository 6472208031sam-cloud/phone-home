import Foundation
import CoreLocation
import UIKit
import CryptoKit

/// Phone Home Step 1 spike — one beacon cycle:
/// wake → identity → join (once) → one fix → battery → write latest + ping.
/// The write side mirrors the Follow Me REST lifecycle: anonymous sign-up
/// ONCE, persist idToken/refreshToken/uid, refresh-first (near expiry and
/// on any 401, one retry), never a blind re-sign-up (a new uid would
/// orphan this phone's DB entry). RTDB REST takes ?auth=<idToken>.
final class Beacon: NSObject, CLLocationManagerDelegate {
    static let shared = Beacon()

    // MARK: - Config (public web config + spike test-household values)
    static let apiKey = "AIzaSyC5pJQN2nNhTf4g2Ud-JD--mzWheOcGaKo"
    static let dbURL = "https://phone-home-2b7ee-default-rtdb.firebaseio.com"
    static let readId = "SPIKE1"
    static let joinCode = "phonehome-spike-join-2026"
    static let phoneId = "spikeI"
    static let label = "Spike iPhone"
    static let devTag = "i-SP"

    private let lm = CLLocationManager()
    private var fixCompletion: ((CLLocation?) -> Void)?
    private var fixTimeoutWork: DispatchWorkItem?
    private(set) var running = false

    private override init() {
        super.init()
        lm.delegate = self
        lm.desiredAccuracy = kCLLocationAccuracyBest
    }

    // MARK: - Persisted state (UserDefaults)

    private let d = UserDefaults.standard
    var uid: String { d.string(forKey: "ph_uid") ?? "" }
    var idToken: String { d.string(forKey: "ph_idToken") ?? "" }
    var refreshTokenStored: String { d.string(forKey: "ph_refreshToken") ?? "" }
    var tokenExp: Date { Date(timeIntervalSince1970: d.double(forKey: "ph_tokenExp")) }
    var joined: Bool { d.bool(forKey: "ph_joined") }
    var everWrote: Bool { d.bool(forKey: "ph_everWrote") }
    var beaconOn: Bool {
        get { d.object(forKey: "ph_beaconOn") == nil ? true : d.bool(forKey: "ph_beaconOn") }
        set { d.set(newValue, forKey: "ph_beaconOn") }
    }

    private func saveIdentity(uid: String, idToken: String, refreshToken: String, exp: Date) {
        d.set(uid, forKey: "ph_uid")
        d.set(idToken, forKey: "ph_idToken")
        d.set(refreshToken, forKey: "ph_refreshToken")
        d.set(exp.timeIntervalSince1970, forKey: "ph_tokenExp")
    }

    // MARK: - Log (file-backed; Toronto stamps; last 500 lines)

    private var logFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("beacon.log")
    }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/Toronto")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }

    static func torontoDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/Toronto")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    func log(_ tag: String, _ msg: String) {
        let line = "[\(Self.stamp(Date()))] [\(tag)] \(msg)"
        NSLog("PhoneHomeSpike %@", line)
        DispatchQueue.main.async {
            var lines: [String] = []
            if let existing = try? String(contentsOf: self.logFileURL, encoding: .utf8) {
                lines = existing.components(separatedBy: "\n").filter { !$0.isEmpty }
            }
            lines.append(line)
            if lines.count > 500 { lines.removeFirst(lines.count - 500) }
            try? lines.joined(separator: "\n").write(to: self.logFileURL, atomically: true, encoding: .utf8)
            NotificationCenter.default.post(name: Notification.Name("phLogUpdated"), object: nil)
        }
    }

    func logText() -> String {
        (try? String(contentsOf: logFileURL, encoding: .utf8)) ?? ""
    }

    // MARK: - HTTP

    private func http(method: String, url: String, body: Data?, contentType: String = "application/json",
                      completion: @escaping (Int, String) -> Void) {
        guard let u = URL(string: url) else { completion(-1, "bad url"); return }
        var req = URLRequest(url: u)
        req.httpMethod = method
        req.timeoutInterval = 20
        if let body = body {
            req.httpBody = body
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let text = data != nil ? String(data: data!, encoding: .utf8) ?? "" : ""
            completion(code, text)
        }.resume()
    }

    private func jsonData(_ obj: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: obj)
    }

    // MARK: - Identity (Follow Me lifecycle)

    func ensureIdentity(completion: @escaping (Bool) -> Void) {
        if uid.isEmpty {
            log("AUTH", "no identity — anonymous sign-up")
            signUp(completion: completion)
            return
        }
        if tokenExp.timeIntervalSinceNow < 10 * 60 {
            log("AUTH", "token near expiry — refreshing first")
            refresh(completion: completion)
            return
        }
        completion(true)
    }

    private func signUp(completion: @escaping (Bool) -> Void) {
        http(method: "POST",
             url: "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=\(Self.apiKey)",
             body: jsonData(["returnSecureToken": true])) { code, text in
            guard code == 200, let j = self.parseJSON(text),
                  let uid = j["localId"] as? String,
                  let idt = j["idToken"] as? String,
                  let rft = j["refreshToken"] as? String else {
                self.log("AUTH", "signUp FAILED HTTP \(code) \(String(text.prefix(160)))")
                completion(false); return
            }
            let expIn = Double(j["expiresIn"] as? String ?? "3600") ?? 3600
            self.saveIdentity(uid: uid, idToken: idt, refreshToken: rft, exp: Date(timeIntervalSinceNow: expIn))
            self.log("AUTH", "signUp ok uid=\(uid)")
            completion(true)
        }
    }

    func refresh(completion: @escaping (Bool) -> Void) {
        guard !refreshTokenStored.isEmpty else {
            log("AUTH", "refresh requested but no refresh token stored")
            completion(false); return
        }
        let body = "grant_type=refresh_token&refresh_token="
            + (refreshTokenStored.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? refreshTokenStored)
        http(method: "POST",
             url: "https://securetoken.googleapis.com/v1/token?key=\(Self.apiKey)",
             body: body.data(using: .utf8),
             contentType: "application/x-www-form-urlencoded") { code, text in
            guard code == 200, let j = self.parseJSON(text),
                  let uid = j["user_id"] as? String,
                  let idt = j["id_token"] as? String,
                  let rft = j["refresh_token"] as? String else {
                self.log("AUTH", "refresh FAILED HTTP \(code) \(String(text.prefix(160)))")
                completion(false); return
            }
            let expIn = (j["expires_in"] as? NSNumber)?.doubleValue ?? 3600
            self.saveIdentity(uid: uid, idToken: idt, refreshToken: rft, exp: Date(timeIntervalSinceNow: expIn))
            self.log("AUTH", "token refreshed uid=\(uid)")
            completion(true)
        }
    }

    private func parseJSON(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// PUT with ?auth= token; on 401 refresh + retry once.
    private func dbPut(path: String, obj: [String: Any], retried: Bool = false,
                       completion: @escaping (Int) -> Void) {
        http(method: "PUT",
             url: "\(Self.dbURL)\(path).json?auth=\(idToken)",
             body: jsonData(obj)) { code, _ in
            if code == 401 && !retried {
                self.log("DB", "401 on PUT \(path) — refreshing token, retrying once")
                self.refresh { ok in
                    if ok { self.dbPut(path: path, obj: obj, retried: true, completion: completion) }
                    else { completion(401) }
                }
                return
            }
            completion(code)
        }
    }

    // MARK: - Join (once)

    private func joinIfNeeded(completion: @escaping (Bool) -> Void) {
        if joined { completion(true); return }
        let info: [String: Any] = [
            "label": Self.label,
            "devTag": Self.devTag,
            "uid": uid,
            "joinedAt": Int(Date().timeIntervalSince1970 * 1000),
            "joinProof": Self.sha256Hex(Self.joinCode),
        ]
        dbPut(path: "/households/\(Self.readId)/phones/\(Self.phoneId)/info", obj: info) { code in
            self.log("JOIN", "PUT info -> HTTP \(code)")
            guard code == 200 else { completion(false); return }
            self.d.set(true, forKey: "ph_joined")
            self.dbPut(path: "/phonesByUid/\(self.uid)", obj: ["householdPath": "households/\(Self.readId)"]) { pcode in
                self.log("JOIN", "PUT phonesByUid pointer -> HTTP \(pcode)")
                completion(true)
            }
        }
    }

    static func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Location (one-shot)

    func requestAuthorization() {
        let status = lm.authorizationStatus
        if status == .notDetermined {
            lm.requestWhenInUseAuthorization()
        } else if status == .authorizedWhenInUse {
            lm.requestAlwaysAuthorization()
        }
    }

    private func getFix(completion: @escaping (CLLocation?) -> Void) {
        let status = lm.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            log("FIX", "location not authorized (status \(status.rawValue))")
            completion(nil); return
        }
        fixCompletion = completion
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, let cb = self.fixCompletion else { return }
            self.fixCompletion = nil
            self.log("FIX", "single fix timed out — using cached location if any")
            cb(self.lm.location)
        }
        fixTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
        lm.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let cb = fixCompletion, let loc = locations.last {
            fixCompletion = nil
            fixTimeoutWork?.cancel()
            cb(loc)
            return
        }
        // No fix pending: a significant-change delivery — a movement wake.
        if let loc = locations.last {
            log("SLC", "movement delivery — sig-change fix ±\(Int(loc.horizontalAccuracy.rounded()))m @ \(Self.stamp(loc.timestamp))")
        } else {
            log("SLC", "movement delivery (no location attached)")
        }
        startSignificantChanges() // keep the service armed after a relaunch
        movedWake()
    }

    // MARK: - Significant location changes (v2 movement wakes)

    /// Arms Apple's significant-location-change service — a separate wake
    /// channel from BG refresh: iOS relaunches the app on ~500 m moves,
    /// even after the user has closed it, and it is not rationed the way
    /// background refresh is for a little-used app.
    func startSignificantChanges() {
        let status = lm.authorizationStatus
        guard status == .authorizedAlways || status == .authorizedWhenInUse else {
            log("SLC", "not armed — location not authorized (status \(status.rawValue))")
            return
        }
        lm.startMonitoringSignificantLocationChanges()
        d.set(true, forKey: "ph_slcArmed")
        log("SLC", "significant-change monitoring started")
    }

    var slcArmed: Bool { d.bool(forKey: "ph_slcArmed") }

    /// A movement wake (SLC delivery or location relaunch), de-duped to at
    /// most one per 5 minutes so a launch + its delivery can't double-ping.
    func movedWake() {
        let last = d.double(forKey: "ph_lastMoved")
        if last > 0 && Date().timeIntervalSince1970 - last < 300 {
            log("SLC", "movement wake skipped — last moved wake <5 min ago")
            return
        }
        d.set(Date().timeIntervalSince1970, forKey: "ph_lastMoved")
        runWake(src: everWrote ? "moved" : "first") {}
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard let cb = fixCompletion else { return }
        fixCompletion = nil
        fixTimeoutWork?.cancel()
        log("FIX", "requestLocation failed: \(error.localizedDescription) — using cached if any")
        cb(lm.location)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        log("SYS", "location authorization -> \(manager.authorizationStatus.rawValue) (2=whenInUse 3=always)")
        requestAuthorization() // escalates whenInUse -> Always once
        startSignificantChanges()
        if (manager.authorizationStatus == .authorizedWhenInUse
            || manager.authorizationStatus == .authorizedAlways) && !everWrote {
            runWake(src: "first") {}
        }
    }

    // MARK: - Battery

    private func battery() -> (Int, Bool) {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        let pct = level >= 0 ? Int((level * 100).rounded()) : 0
        let state = UIDevice.current.batteryState
        return (pct, state == .charging || state == .full)
    }

    // MARK: - The wake cycle

    func runWake(src requestedSrc: String, completion: @escaping () -> Void) {
        if running { log("WAKE", "wake already running — skipping"); completion(); return }
        running = true
        var src = requestedSrc
        log("WAKE", "begin src=\(src)")
        let done: () -> Void = {
            self.d.set(Date().timeIntervalSince1970, forKey: "ph_lastWake")
            self.log("WAKE", "end")
            self.running = false
            completion()
        }
        ensureIdentity { ok in
            guard ok else {
                self.log("WAKE", "identity failed — write skipped this wake")
                self.d.set("identity failed", forKey: "ph_lastWrite")
                done(); return
            }
            self.joinIfNeeded { joinedOk in
                guard joinedOk else {
                    self.d.set("join failed", forKey: "ph_lastWrite")
                    done(); return
                }
                self.getFix { loc in
                    guard let loc = loc else {
                        self.log("FIX", "no fix available — write skipped this wake")
                        self.d.set("none", forKey: "ph_lastFix")
                        done(); return
                    }
                    let tsMs = Int(loc.timestamp.timeIntervalSince1970 * 1000)
                    let acc = loc.horizontalAccuracy >= 0 ? loc.horizontalAccuracy : 0
                    self.log("FIX", "lat=\(loc.coordinate.latitude) lng=\(loc.coordinate.longitude) "
                        + "acc=\(acc)m fixTime=\(Self.stamp(loc.timestamp))")
                    self.d.set("\(loc.coordinate.latitude), \(loc.coordinate.longitude) ±\(Int(acc.rounded()))m @ \(Self.stamp(loc.timestamp))",
                               forKey: "ph_lastFix")
                    let (batt, charging) = self.battery()
                    if !self.everWrote { src = "first" }
                    let ping: [String: Any] = [
                        "lat": loc.coordinate.latitude,
                        "lng": loc.coordinate.longitude,
                        "acc": (acc * 10).rounded() / 10,
                        "ts": tsMs,
                        "batt": batt,
                        "charging": charging,
                        "src": src,
                    ]
                    let base = "/households/\(Self.readId)/phones/\(Self.phoneId)"
                    self.dbPut(path: base + "/latest", obj: ping) { code1 in
                        self.log("DB", "PUT latest -> HTTP \(code1)")
                        let day = Self.torontoDay(loc.timestamp)
                        self.dbPut(path: base + "/pings/\(day)/\(tsMs)", obj: ping) { code2 in
                            self.log("DB", "PUT pings/\(day)/\(tsMs) -> HTTP \(code2)")
                            if code1 == 200 && code2 == 200 {
                                self.d.set(true, forKey: "ph_everWrote")
                                self.d.set("OK \(Self.stamp(Date())) src=\(src)", forKey: "ph_lastWrite")
                            } else {
                                self.d.set("FAILED latest=\(code1) ping=\(code2)", forKey: "ph_lastWrite")
                            }
                            done()
                        }
                    }
                }
            }
        }
    }
}
