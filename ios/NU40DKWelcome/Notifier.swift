import Foundation
import UserNotifications

/// "환영합니다!" 알림.
///
/// 잠금화면 위젯(Live Activity)이 못 뜨는 경우가 있어도 이건 뜬다. 그래서 이쪽이
/// 주력이고 위젯이 보조다 — 사용자가 Live Activity를 꺼두었거나, 이미 활동이
/// 상한에 걸렸거나, 백그라운드 시작이 거부될 수 있다. 알림에는 그런 조건이 없다.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {

    private let center = UNUserNotificationCenter.current()

    func prepare(done: ((Bool) -> Void)? = nil) {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            done?(granted)
        }
    }

    func welcome(name: String) {
        let content = UNMutableNotificationContent()
        content.title = name.isEmpty ? "환영합니다!" : "\(name)님, 환영합니다!"
        content.body = "책상 위 보드가 반갑게 맞이하고 있어요."
        content.sound = .default
        // 잠금화면에서 크게 보이도록. 시간에 민감한 알림이라 집중 모드도 뚫는다
        content.interruptionLevel = .timeSensitive

        // trigger가 nil이면 즉시 발송된다. 문을 열고 몇 초 안에 울려야 하므로
        // 어떤 지연도 넣지 않는다
        let request = UNNotificationRequest(
            identifier: "welcome.\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    /// 앱을 보고 있을 때도 알림이 뜨게 한다.
    /// 리허설할 때 알림이 안 보이면 잘 되고 있는 건지 알 수가 없다
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
