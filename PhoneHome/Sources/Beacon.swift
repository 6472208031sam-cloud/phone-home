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
        lm.desiredAccuracy = kCLLocationAccuracyBest // one-shots stay crisp even after a session ran
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
        guard let loc = locations.last else { return }
        if liveOn {
            // Always mode: a continuous-session update — drive the ping cadence.
            liveTick(loc)
            return
        }
        // No fix pending, no live session: a significant-change delivery — a movement wake.
        log("SLC", "movement delivery — sig-change fix ±\(Int(loc.horizontalAccuracy.rounded()))m @ \(Self.stamp(loc.timestamp))")
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

    // MARK: - Always mode (v3: continuous session + Gentle/Always toggle, R8)

    /// Per-phone tracking style: "gentle" (layered wakes) or "always"
    /// (continuous location session). Default gentle.
    var trackingMode: String {
        get { d.string(forKey: "ph_mode") ?? "gentle" }
        set { d.set(newValue, forKey: "ph_mode") }
    }
    private(set) var liveOn = false
    var stoodDown: Bool { d.bool(forKey: "ph_stoodDown") }

    /// Applies the chosen style, with the low-battery stand-down (<=20% and
    /// not charging -> live session off until power recovers). Safe to call
    /// on every launch / wake / toggle; also the resurrection path after
    /// iOS kills the app and a movement event relaunches it.
    func applyTrackingMode() {
        guard trackingMode == "always" else {
            if liveOn { stopLiveSession(); log("MODE", "Gentle — live session off") }
            return
        }
        let (batt, charging) = battery()
        if batt <= 20 && !charging {
            if liveOn { stopLiveSession(); log("MODE", "Always stood down — battery \(batt)% and not charging") }
            d.set(true, forKey: "ph_stoodDown")
            return
        }
        if stoodDown { log("MODE", "power recovered (\(batt)%\(charging ? ", charging" : "")) — Always resuming") }
        d.set(false, forKey: "ph_stoodDown")
        startLiveSession()
    }

    private func startLiveSession() {
        let status = lm.authorizationStatus
        guard status == .authorizedAlways || status == .authorizedWhenInUse else {
            log("MODE", "live session not started — location not authorized (status \(status.rawValue))")
            return
        }
        if liveOn { return }
        // R10(i): NO distance filter — a still phone must keep producing
        // callbacks or the heartbeat has no driver (Day-1 evening lesson).
        // Accuracy is managed to nearest-ten-metres to bound the cost.
        lm.distanceFilter = kCLDistanceFilterNone
        lm.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        lm.allowsBackgroundLocationUpdates = true
        lm.pausesLocationUpdatesAutomatically = false
        lm.startUpdatingLocation()
        liveOn = true
        log("MODE", "live session STARTED (Always; 10 m accuracy, NO distance filter, no auto-pause)")
    }

    private func stopLiveSession() {
        lm.stopUpdatingLocation()
        lm.distanceFilter = kCLDistanceFilterNone
        lm.desiredAccuracy = kCLLocationAccuracyBest
        liveOn = false
    }

    /// One continuous-session update in Always mode: fire the hourly beat
    /// when due (>=55 min since the last ping), else a moved ping under
    /// the R4 gates (>=500 m from last reported, >=15 min since last moved).
    private func liveTick(_ loc: CLLocation) {
        if running { return }
        let (batt, charging) = battery()
        if batt <= 20 && !charging { applyTrackingMode(); return }
        let now = Date().timeIntervalSince1970
        let lastPing = d.double(forKey: "ph_lastPingAt")
        let lastAttempt = d.double(forKey: "ph_lastAttemptAt")
        // After a failed attempt the fix is safe in the outbox (v4), so a
        // re-attempt can wait 10 min instead of firing on every update.
        if (lastPing == 0 || now - lastPing >= 55 * 60) && now - lastAttempt >= 10 * 60 {
            runWake(src: everWrote ? "hourly" : "first") {}
            return
        }
        let lastLat = d.double(forKey: "ph_lastLat")
        let lastLng = d.double(forKey: "ph_lastLng")
        let lastMoved = d.double(forKey: "ph_lastMoved")
        if lastLat != 0 {
            let from = CLLocation(latitude: lastLat, longitude: lastLng)
            if loc.distance(from: from) >= 500 && now - lastMoved >= 15 * 60 {
                d.set(now, forKey: "ph_lastMoved")
                runWake(src: "moved") {}
            }
        }
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

    // MARK: - Outbox (v4, R9: queue failed pings, backfill on reconnect)

    /// Pings whose history write failed (usually no data path) are queued
    /// here with their TRUE fix time and flushed oldest-first once a write
    /// succeeds again. A flushed ping never overwrites a newer `latest`.
    private var outboxFlushing = false

    private func outboxLoad() -> [[String: Any]] {
        guard let data = d.data(forKey: "ph_outbox"),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return arr
    }

    private func outboxSave(_ q: [[String: Any]]) {
        if let data = try? JSONSerialization.data(withJSONObject: q) {
            d.set(data, forKey: "ph_outbox")
        }
    }

    var outboxCount: Int { outboxLoad().count }

    private func outboxEnqueue(_ ping: [String: Any]) {
        var q = outboxLoad()
        q.append(ping)
        if q.count > 500 { q.removeFirst(q.count - 500) }
        outboxSave(q)
        let tsMs = (ping["ts"] as? NSNumber)?.intValue ?? 0
        log("OUTBOX", "queued src=\(ping["src"] as? String ?? "?") fixTime=\(Self.stamp(Date(timeIntervalSince1970: Double(tsMs) / 1000))) — \(q.count) in queue")
    }

    /// Identity + join + flush without taking a fresh fix — for launch-time
    /// attempts (e.g. the user opening the app after being offline).
    func flushOutboxIfPossible() {
        if outboxCount == 0 { return }
        ensureIdentity { ok in
            guard ok else { return }
            self.joinIfNeeded { joinedOk in
                if joinedOk { self.flushOutbox() }
            }
        }
    }

    private func flushOutbox() {
        if outboxFlushing { return }
        var q = outboxLoad()
        if q.isEmpty { return }
        outboxFlushing = true
        log("OUTBOX", "flush starting — \(q.count) queued")
        func step() {
            guard let entry = q.first else {
                self.outboxFlushing = false
                self.log("OUTBOX", "flush complete — queue empty")
                return
            }
            let tsMs = (entry["ts"] as? NSNumber)?.intValue ?? 0
            let day = Self.torontoDay(Date(timeIntervalSince1970: Double(tsMs) / 1000))
            let base = "/households/\(Self.readId)/phones/\(Self.phoneId)"
            self.dbPut(path: base + "/pings/\(day)/\(tsMs)", obj: entry) { code in
                guard code == 200 else {
                    self.outboxFlushing = false
                    self.log("OUTBOX", "flush stopped — PUT pings -> HTTP \(code); \(q.count) remain")
                    return
                }
                q.removeFirst()
                self.outboxSave(q)
                if Double(tsMs) > self.d.double(forKey: "ph_latestTs") {
                    self.dbPut(path: base + "/latest", obj: entry) { lcode in
                        if lcode == 200 { self.d.set(Double(tsMs), forKey: "ph_latestTs") }
                        step()
                    }
                } else {
                    step()
                }
            }
        }
        step()
    }

    // MARK: - The wake cycle

    func runWake(src requestedSrc: String, completion: @escaping () -> Void) {
        if running { log("WAKE", "wake already running — skipping"); completion(); return }
        running = true
        d.set(Date().timeIntervalSince1970, forKey: "ph_lastAttemptAt")
        var src = requestedSrc
        log("WAKE", "begin src=\(src)")
        let done: () -> Void = {
            self.d.set(Date().timeIntervalSince1970, forKey: "ph_lastWake")
            self.log("WAKE", "end")
            self.running = false
            completion()
        }
        // R10(ii) capture-first: take the fix BEFORE identity. A wake that
        // cannot authenticate still leaves with its fix in the outbox
        // (Day-1 lesson: offline wakes died at the token gate, fixless).
        let proceed: (CLLocation) -> Void = { loc in
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
            self.ensureIdentity { ok in
                guard ok else {
                    self.log("WAKE", "identity failed — fix queued instead of lost")
                    self.outboxEnqueue(ping)
                    self.d.set("QUEUED (identity failed)", forKey: "ph_lastWrite")
                    done(); return
                }
                self.joinIfNeeded { joinedOk in
                    guard joinedOk else {
                        self.log("WAKE", "join failed — fix queued instead of lost")
                        self.outboxEnqueue(ping)
                        self.d.set("QUEUED (join failed)", forKey: "ph_lastWrite")
                        done(); return
                    }
                    let base = "/households/\(Self.readId)/phones/\(Self.phoneId)"
                    self.dbPut(path: base + "/latest", obj: ping) { code1 in
                        self.log("DB", "PUT latest -> HTTP \(code1)")
                        if code1 == 200 { self.d.set(Double(tsMs), forKey: "ph_latestTs") }
                        let day = Self.torontoDay(loc.timestamp)
                        self.dbPut(path: base + "/pings/\(day)/\(tsMs)", obj: ping) { code2 in
                            self.log("DB", "PUT pings/\(day)/\(tsMs) -> HTTP \(code2)")
                            if code2 == 200 {
                                // History has the ping — that is what "reported"
                                // means; a failed latest self-heals next ping.
                                self.d.set(true, forKey: "ph_everWrote")
                                self.d.set(Date().timeIntervalSince1970, forKey: "ph_lastPingAt")
                                self.d.set(loc.coordinate.latitude, forKey: "ph_lastLat")
                                self.d.set(loc.coordinate.longitude, forKey: "ph_lastLng")
                                self.d.set("OK \(Self.stamp(Date())) src=\(src)", forKey: "ph_lastWrite")
                                self.flushOutbox()
                            } else {
                                // R9: queue it with its true fix time; a later
                                // flush files it into history at its true slot.
                                self.outboxEnqueue(ping)
                                self.d.set("QUEUED latest=\(code1) ping=\(code2)", forKey: "ph_lastWrite")
                            }
                            done()
                        }
                    }
                }
            }
        }
        // R10(iii): in Always mode the session's latest location is the fix —
        // a one-shot request in the background mid-session proved unreliable.
        if liveOn, let cached = lm.location, Date().timeIntervalSince(cached.timestamp) < 10 * 60 {
            log("FIX", "using live-session location (Always wake)")
            proceed(cached)
        } else {
            getFix { loc in
                guard let loc = loc else {
                    self.log("FIX", "no fix available — write skipped this wake")
                    self.d.set("none", forKey: "ph_lastFix")
                    done(); return
                }
                proceed(loc)
            }
        }
    }
}
