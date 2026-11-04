import UIKit

/// Single-screen spike UI: beacon toggle, status, Ping Now, log + share.
/// Deliberately minimal — the log is the cadence evidence.
class ViewController: UIViewController {
    private let statusLabel = UILabel()
    private let logView = UITextView()
    private let beaconSwitch = UISwitch()
    private var timer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildUi()
        NotificationCenter.default.addObserver(self, selector: #selector(refresh),
                                               name: Notification.Name("phLogUpdated"), object: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
    }

    private func buildUi() {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])

        let title = UILabel()
        title.text = "Phone Home Spike v4"
        title.font = .boldSystemFont(ofSize: 22)
        stack.addArrangedSubview(title)

        let sub = UILabel()
        sub.numberOfLines = 0
        sub.font = .systemFont(ofSize: 13)
        sub.text = "Step 1 cadence spike — household \(Beacon.readId) · phone \(Beacon.phoneId)\n"
            + "v4 adds the R9 outbox: failed pings queue on-phone and backfill on reconnect.\n"
            + "Cadence is ABOUT hourly: iOS decides; this log is the evidence."
        stack.addArrangedSubview(sub)

        let toggleRow = UIStackView()
        toggleRow.axis = .horizontal
        toggleRow.spacing = 8
        let toggleLabel = UILabel()
        toggleLabel.text = "Beacon"
        toggleRow.addArrangedSubview(toggleLabel)
        beaconSwitch.isOn = Beacon.shared.beaconOn
        beaconSwitch.addTarget(self, action: #selector(toggleChanged), for: .valueChanged)
        toggleRow.addArrangedSubview(beaconSwitch)
        stack.addArrangedSubview(toggleRow)

        let modeRow = UIStackView()
        modeRow.axis = .horizontal
        modeRow.spacing = 8
        let modeLabel = UILabel()
        modeLabel.text = "Tracking style"
        modeRow.addArrangedSubview(modeLabel)
        let modeSeg = UISegmentedControl(items: ["Gentle", "Always"])
        modeSeg.selectedSegmentIndex = Beacon.shared.trackingMode == "always" ? 1 : 0
        modeSeg.addTarget(self, action: #selector(modeChanged(_:)), for: .valueChanged)
        modeRow.addArrangedSubview(modeSeg)
        stack.addArrangedSubview(modeRow)

        statusLabel.numberOfLines = 0
        statusLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        stack.addArrangedSubview(statusLabel)

        let pingBtn = UIButton(type: .system)
        pingBtn.setTitle("Ping Now (manual)", for: .normal)
        pingBtn.titleLabel?.font = .boldSystemFont(ofSize: 17)
        pingBtn.addTarget(self, action: #selector(pingNow), for: .touchUpInside)
        stack.addArrangedSubview(pingBtn)

        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 16
        let shareBtn = UIButton(type: .system)
        shareBtn.setTitle("Share log", for: .normal)
        shareBtn.addTarget(self, action: #selector(shareLog), for: .touchUpInside)
        row.addArrangedSubview(shareBtn)
        let refreshBtn = UIButton(type: .system)
        refreshBtn.setTitle("Refresh", for: .normal)
        refreshBtn.addTarget(self, action: #selector(refresh), for: .touchUpInside)
        row.addArrangedSubview(refreshBtn)
        stack.addArrangedSubview(row)

        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        stack.addArrangedSubview(logView)
    }

    @objc private func toggleChanged() {
        Beacon.shared.beaconOn = beaconSwitch.isOn
        Beacon.shared.log("SYS", "beacon toggled \(beaconSwitch.isOn ? "ON" : "OFF")")
        if beaconSwitch.isOn {
            AppDelegate.scheduleAppRefresh()
            if !Beacon.shared.everWrote { Beacon.shared.runWake(src: "first") {} }
        }
        refresh()
    }

    @objc private func modeChanged(_ seg: UISegmentedControl) {
        let mode = seg.selectedSegmentIndex == 1 ? "always" : "gentle"
        Beacon.shared.trackingMode = mode
        Beacon.shared.log("MODE", "tracking style set to \(mode) in app")
        Beacon.shared.applyTrackingMode()
        refresh()
    }

    @objc private func pingNow() {
        Beacon.shared.runWake(src: "manual") { [weak self] in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    @objc private func shareLog() {
        let text = Beacon.shared.logText()
        let vc = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        present(vc, animated: true)
    }

    @objc private func refresh() {
        let d = UserDefaults.standard
        let lastWake = d.double(forKey: "ph_lastWake")
        let nextWake = d.double(forKey: "ph_nextWake")
        let exp = Beacon.shared.tokenExp
        statusLabel.text =
            "uid: \(Beacon.shared.uid.isEmpty ? "(none yet)" : Beacon.shared.uid)\n"
            + "joined: \(Beacon.shared.joined) · token exp: \(exp.timeIntervalSince1970 > 0 ? Beacon.stamp(exp) : "—")\n"
            + "last wake: \(lastWake > 0 ? Beacon.stamp(Date(timeIntervalSince1970: lastWake)) : "never")\n"
            + "last fix: \(d.string(forKey: "ph_lastFix") ?? "—")\n"
            + "last write: \(d.string(forKey: "ph_lastWrite") ?? "—")\n"
            + "next wake armed (earliest): \(nextWake > 0 ? Beacon.stamp(Date(timeIntervalSince1970: nextWake)) : "not armed")\n"
            + "bg refresh status: \(UIApplication.shared.backgroundRefreshStatus.rawValue) (2=available)\n"
            + "movement wakes (SLC): \(Beacon.shared.slcArmed ? "armed" : "not armed")\n"
            + "outbox: \(Beacon.shared.outboxCount) queued\n"
            + "tracking style: \(Beacon.shared.trackingMode)"
            + (Beacon.shared.trackingMode == "always"
                ? (Beacon.shared.stoodDown ? " (stood down — low battery)" : " · live session \(Beacon.shared.liveOn ? "ON" : "off")")
                : "")
        logView.text = Beacon.shared.logText()
    }
}
