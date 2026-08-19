import ActivityKit
import Foundation

/// 앱과 위젯 익스텐션이 함께 쓰는 계약.
///
/// 잠금화면에 뜨는 "환영합니다!" 카드가 이걸로 그려진다.
/// 카드는 도착 순간에 시작해서 몇 분 뒤 스스로 사라진다 — 하루 종일 붙어 있으면
/// 잠금화면이 지저분해지고, 그때쯤이면 이미 자리에 앉아 있다.
struct WelcomeAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// 도착한 시각. 카드에 "08:42 도착"으로 찍힌다
        var arrivedAt: Date
        /// 보드가 아직 반짝이는 중인지. 연출이 끝나면 카드도 차분해진다
        var isCelebrating: Bool
        /// 보드에 도착을 알리는 데 성공했는지.
        /// 실패해도 카드는 뜬다 — 사람에게 인사하는 게 먼저다
        var boardNotified: Bool
    }

    /// 활동 내내 안 바뀌는 값
    var greeting: String = "환영합니다!"
    var name: String = ""
}
