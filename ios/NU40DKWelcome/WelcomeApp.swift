import SwiftUI
import UIKit

@main
struct WelcomeApp: App {
    // 앱의 시작점을 SwiftUI에 맡기면 안 된다. 아래 AppDelegate 설명 참고
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(delegate.arrival)
                .environmentObject(delegate.arrival.board)
                .preferredColorScheme(.dark)
        }
    }
}

/// **이 앱은 대부분의 시간을 죽어 있는 채로 보낸다.**
///
/// 출근길에 보드 신호가 잡히면 iOS가 앱을 백그라운드로 되살리는데, 그때 살아나는 것은
/// SwiftUI 씬이 아니라 이 델리게이트다. `ArrivalManager`(= `CLLocationManager`의 주인)를
/// 여기 `didFinishLaunching`에서 **즉시** 만들어야 리전 진입 콜백이 전달된다.
///
/// 뷰가 뜰 때 만들도록 두면, 화면이 없는 백그라운드 실행에서는 영영 안 만들어지고
/// 이벤트는 조용히 버려진다. 증상은 "앱을 열어두면 되는데 닫으면 안 됨"이다.
final class AppDelegate: NSObject, UIApplicationDelegate {
    let arrival = ArrivalManager()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // launchOptions에 .location이 있으면 사람이 아이콘을 누른 게 아니라
        // 위치 이벤트가 앱을 깨운 것이다. 로그로 구분해두면 디버깅이 쉬워진다
        let wokenByLocation = launchOptions?[.location] != nil
        arrival.bootstrap(wokenByLocation: wokenByLocation)
        return true
    }
}
