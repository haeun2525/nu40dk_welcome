import ActivityKit
import Foundation

/// 잠금화면 위에 뜨는 환영 카드(Live Activity)를 띄우고 걷는다.
///
/// **백그라운드에서 시작한다.** iOS 17부터 백그라운드 실행 중인 앱도 Live Activity를
/// 시작할 수 있게 됐다. 그 전 버전에서는 불가능했고, 그래서 알림이 주력이고
/// 이건 보조다. 여기서 실패해도 도착 알림은 이미 나가 있다.
///
/// **계속 도는 애니메이션은 못 한다.** 상태가 바뀔 때 새 스냅샷으로 교체되는 구조라
/// 반짝이는 연출은 보드 LED가 맡고, 카드는 정지 화면으로 둔다.
final class LiveActivityController {

    private var activity: Activity<WelcomeAttributes>?
    private var arrivedAt: Date?
    private var celebrating = true
    private var boardNotified = false

    private var isAvailable: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    func start(arrivedAt date: Date, name: String) {
        guard isAvailable else { return }

        // 앱이 죽었다 살아난 뒤라면 지난 활동이 남아 있을 수 있다.
        // 그대로 두면 새 카드가 안 뜨고 어제 카드가 계속 붙어 있다
        stop()

        self.arrivedAt = date
        celebrating = true
        boardNotified = false

        let state = WelcomeAttributes.ContentState(
            arrivedAt: date,
            isCelebrating: true,
            boardNotified: false
        )
        do {
            activity = try Activity.request(
                attributes: WelcomeAttributes(greeting: "환영합니다!", name: name),
                // staleDate를 주면 그 시각 이후 카드가 흐려진다. 자리에 앉고 한참 뒤까지
                // "방금 도착"이라고 떠 있는 것보다 낫다
                content: .init(state: state, staleDate: date.addingTimeInterval(30 * 60)),
                pushType: nil
            )
        } catch {
            // 사용자가 Live Activity를 꺼두었거나 개수 상한에 걸린 경우.
            // 알림은 이미 나갔으므로 여기서 멈춰도 연출은 성립한다
            activity = nil
        }
    }

    func update(celebrating: Bool? = nil, boardNotified: Bool? = nil) {
        if let celebrating { self.celebrating = celebrating }
        if let boardNotified { self.boardNotified = boardNotified }
        guard let activity, let arrivedAt else { return }

        let state = WelcomeAttributes.ContentState(
            arrivedAt: arrivedAt,
            isCelebrating: self.celebrating,
            boardNotified: self.boardNotified
        )
        Task {
            await activity.update(.init(state: state, staleDate: arrivedAt.addingTimeInterval(30 * 60)))
        }
    }

    /// 카드가 이 시각에 스스로 걷히도록 iOS에 예약한다.
    ///
    /// **타이머로는 못 한다.** 3분 뒤면 앱은 이미 잠들어 있어서 `asyncAfter`가 안 불린다.
    /// 종료 정책을 iOS에 넘겨야 앱이 자고 있어도, 화면이 꺼져 있어도 걷힌다.
    ///
    /// 보드가 책상 위에서 계속 켜져 있으면 '이탈'이 영영 안 일어난다. 그래서 이게
    /// 없으면 아침에 뜬 카드가 **퇴근할 때까지 잠금화면에 남는다.**
    ///
    /// `end`를 부른 뒤에는 내용을 못 바꾼다. 그래서 연출도 보드 응답도 끝난 뒤에 부른다.
    func scheduleDismissal(at date: Date) {
        guard let activity, let arrivedAt else { return }
        let state = WelcomeAttributes.ContentState(
            arrivedAt: arrivedAt,
            isCelebrating: celebrating,
            boardNotified: boardNotified
        )
        Task {
            await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(date))
        }
    }

    func stop() {
        activity = nil
        arrivedAt = nil
        // 이 앱이 띄운 카드를 전부 걷는다. `activity` 변수만 보면 앱이 재시작된 뒤
        // 남아 있는 카드를 못 걷는다
        Task {
            for running in Activity<WelcomeAttributes>.activities {
                await running.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
