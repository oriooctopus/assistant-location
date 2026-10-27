import UIKit
import UserNotifications
import UserNotificationsUI

/// Long-press view of a Due nag: title, due-time bar, and the Quick Access chip grid (same chips and snooze maths as the web UI).
/// A chip tap updates the bar and POSTs snooze_reminder to the Due server's MCP endpoint, then clears the reminder's other
/// notifications; the view stays open so more chips can fine-tune the time.
final class NotificationViewController: UIViewController, UNNotificationContentExtension {
    private struct Chip { let n: String; let u: String; let abs: (Int, Int)?; let add: TimeInterval }
    private static let MIN: TimeInterval = 60, HR: TimeInterval = 3600, DAY: TimeInterval = 86400
    private static let chips: [[Chip]] = {
        let m = MIN, h = HR, d = DAY
        return [
            [Chip(n: "9:30", u: "AM", abs: (9, 30), add: 0), Chip(n: "12:00", u: "PM", abs: (12, 0), add: 0),
             Chip(n: "6:30", u: "PM", abs: (18, 30), add: 0), Chip(n: "10:00", u: "PM", abs: (22, 0), add: 0)],
            [Chip(n: "+10", u: "min", abs: nil, add: 10 * m), Chip(n: "+1", u: "hr", abs: nil, add: h),
             Chip(n: "+3", u: "hrs", abs: nil, add: 3 * h), Chip(n: "+1", u: "day", abs: nil, add: d)],
            [Chip(n: "-10", u: "min", abs: nil, add: -10 * m), Chip(n: "-1", u: "hr", abs: nil, add: -h),
             Chip(n: "-3", u: "hrs", abs: nil, add: -3 * h), Chip(n: "-1", u: "day", abs: nil, add: -d)],
        ]
    }()

    private static let bg = UIColor(white: 0.11, alpha: 1)
    private static let barBg = UIColor(white: 0.24, alpha: 1)
    private static let hairline = UIColor(white: 0.2, alpha: 1)
    private static func font(_ size: CGFloat) -> UIFont { UIFont(name: "GillSans", size: size)! }

    private let titleLabel = UILabel()
    private let bar = UILabel()
    private var reminderId: String?
    private var dueAt: Date?
    private var currentRequestId: String?
    private var busy = false
    private static let rowH: CGFloat = 52, titleH: CGFloat = 52, barH: CGFloat = 40

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Self.bg
        preferredContentSize = CGSize(width: 0, height: Self.titleH + Self.barH + 3 * Self.rowH)

        titleLabel.font = Self.font(20)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 1
        let titleBox = UIView()
        titleBox.addSubview(titleLabel)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: titleBox.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: titleBox.trailingAnchor, constant: -16),
            titleLabel.centerYAnchor.constraint(equalTo: titleBox.centerYAnchor),
            titleBox.heightAnchor.constraint(equalToConstant: Self.titleH),
        ])

        bar.font = Self.font(17)
        bar.textColor = UIColor(white: 0.85, alpha: 1)
        bar.backgroundColor = Self.barBg
        bar.numberOfLines = 1
        bar.adjustsFontSizeToFitWidth = true
        bar.minimumScaleFactor = 0.7
        let barBox = UIView()
        barBox.backgroundColor = Self.barBg
        barBox.addSubview(bar)
        bar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: barBox.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: barBox.trailingAnchor, constant: -16),
            bar.centerYAnchor.constraint(equalTo: barBox.centerYAnchor),
            barBox.heightAnchor.constraint(equalToConstant: Self.barH),
        ])

        // Hairlines: the grid's background is the line colour and every cell is inset by 0.5pt spacing.
        let grid = UIStackView()
        grid.axis = .vertical
        grid.spacing = 0.5
        grid.distribution = .fillEqually
        grid.backgroundColor = Self.hairline
        for (r, row) in Self.chips.enumerated() {
            let rowStack = UIStackView()
            rowStack.axis = .horizontal
            rowStack.spacing = 0.5
            rowStack.distribution = .fillEqually
            for (c, chip) in row.enumerated() {
                let b = UIButton(type: .custom)
                b.backgroundColor = Self.bg
                b.setAttributedTitle(Self.label(chip, color: .white), for: .normal)
                b.setAttributedTitle(Self.label(chip, color: UIColor(white: 0.5, alpha: 1)), for: .highlighted)
                b.tag = r * 10 + c
                b.addTarget(self, action: #selector(chipTapped(_:)), for: .touchUpInside)
                rowStack.addArrangedSubview(b)
            }
            grid.addArrangedSubview(rowStack)
        }
        grid.heightAnchor.constraint(equalToConstant: 3 * Self.rowH).isActive = true

        let all = UIStackView(arrangedSubviews: [titleBox, barBox, grid])
        all.axis = .vertical
        all.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(all)
        NSLayoutConstraint.activate([
            all.topAnchor.constraint(equalTo: view.topAnchor),
            all.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            all.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private static func label(_ chip: Chip, color: UIColor) -> NSAttributedString {
        let s = NSMutableAttributedString(string: chip.n, attributes: [.font: font(24), .foregroundColor: color])
        s.append(NSAttributedString(string: " " + chip.u, attributes: [.font: font(15), .foregroundColor: color]))
        return s
    }

    func didReceive(_ notification: UNNotification) {
        let c = notification.request.content
        currentRequestId = notification.request.identifier
        titleLabel.text = c.body
        reminderId = c.userInfo["reminderId"] as? String
        if let ms = (c.userInfo["dueAt"] as? NSNumber)?.doubleValue {
            dueAt = Date(timeIntervalSince1970: ms / 1000)
            bar.text = Self.barText(dueAt!, now: Date())
        } else {
            bar.text = "No due time in this notification"
        }
        if reminderId == nil { bar.text = "No reminder id in this notification" }
    }

    // MARK: format (mirrors web/src/format.ts dateBarText + relativeNote)

    private static func barText(_ due: Date, now: Date) -> String {
        let cal = Calendar.current
        let dow = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"], mon = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let p = cal.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: due)
        let yr = p.year == cal.component(.year, from: now) ? "" : ", \(p.year!)"
        let h = p.hour!
        let time = "\(h % 12 == 0 ? 12 : h % 12):" + String(format: "%02d", p.minute!) + (h < 12 ? " AM" : " PM")
        return "\(dow[p.weekday! - 1]), \(mon[p.month! - 1]) \(p.day!)\(yr) at \(time)  \(relative(due.timeIntervalSince(now)))"
    }

    private static func relative(_ diff: TimeInterval) -> String {
        let a = abs(diff)
        if a < MIN { return "Now" }
        let s: String
        if a < HR { s = "\(Int(a / MIN)) min" }
        else if a < DAY { s = "\(Int(a / HR)) hr" }
        else if a <= 30 * DAY { let d = Int(a / DAY); s = "\(d) \(d == 1 ? "day" : "days")" }
        else { s = a < 365 * DAY ? "< 1 year" : "> 1 year" }
        return diff > 0 ? "In \(s)" : "\(s) ago"
    }

    // MARK: snooze (copy of due-clone packages/core/src/actions.ts CHIPS/snoozeTo: an extension cannot run the web code)

    private static func snoozeTo(due: Date, chip: Chip, now: Date) -> Date {
        let cal = Calendar.current
        if let (hh, mm) = chip.abs {
            var d = cal.date(bySettingHour: hh, minute: mm, second: 0, of: now)!
            if d <= now { d = cal.date(byAdding: .day, value: 1, to: d)! }
            return d
        }
        if chip.add > 0 && due.addingTimeInterval(chip.add) < now { return now.addingTimeInterval(chip.add) }
        return due.addingTimeInterval(chip.add)
    }

    /// A chip tap moves the bar's time and saves it, keeping the view open so further chips adjust from the new time.
    @objc private func chipTapped(_ sender: UIButton) {
        guard reminderId != nil, let due = dueAt else { return }
        let chip = Self.chips[sender.tag / 10][sender.tag % 10]
        let target = Self.snoozeTo(due: due, chip: chip, now: Date())
        dueAt = target
        bar.text = Self.barText(target, now: Date())
        save()
    }

    /// One snooze_reminder POST in flight at a time; taps made meanwhile are sent as one save of the latest time when it returns.
    private func save() {
        guard !busy, let reminderId = reminderId, let target = dueAt else { return }
        busy = true
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        iso.formatOptions = [.withInternetDateTime]
        post(reminderId: reminderId, until: iso.string(from: target)) { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.busy = false
                if let error = error { self.bar.text = "Snooze failed: \(error)"; return }
                if self.dueAt != target { return self.save() }
                self.clearNotifications(reminderId: reminderId) {}
            }
        }
    }

    private func post(reminderId: String, until: String, done: @escaping (String?) -> Void) {
        guard let token = Keychain.token else { return done("not logged in") }
        var req = URLRequest(url: URL(string: Baked.server + "/mcp")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        let body: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                   "params": ["name": "snooze_reminder", "arguments": ["id": reminderId, "until": until]]]
        req.httpBody = try! JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err { return done(err.localizedDescription) }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200, let data = data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return done("HTTP \(status)")
            }
            if let e = json["error"] as? [String: Any] { return done((e["message"] as? String) ?? "MCP error") }
            guard let result = json["result"] as? [String: Any] else { return done("bad MCP response") }
            if result["isError"] as? Bool == true {
                let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "MCP error"
                return done(text)
            }
            done(nil)
        }.resume()
    }

    /// Remove the reminder's pending and delivered notifications (the nags for its old time are now stale), except the one
    /// on screen: removing it would close this view.
    private func clearNotifications(reminderId: String, done: @escaping () -> Void) {
        let center = UNUserNotificationCenter.current()
        let shown = currentRequestId
        func matches(_ id: String, _ info: [AnyHashable: Any]) -> Bool {
            id != shown && ((info["reminderId"] as? String) == reminderId || id.hasPrefix(reminderId + ":"))
        }
        center.getPendingNotificationRequests { pending in
            center.removePendingNotificationRequests(withIdentifiers: pending.filter { matches($0.identifier, $0.content.userInfo) }.map(\.identifier))
            center.getDeliveredNotifications { delivered in
                center.removeDeliveredNotifications(withIdentifiers: delivered.filter { matches($0.request.identifier, $0.request.content.userInfo) }.map(\.request.identifier))
                done()
            }
        }
    }
}
