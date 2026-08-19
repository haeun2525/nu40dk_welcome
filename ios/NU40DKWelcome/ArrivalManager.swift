import CoreLocation
import Foundation
import UIKit

/// 도착을 감지하고, 사람과 보드 양쪽에 알린다. 이 앱의 본체.
///
/// **왜 비콘(CoreLocation)이고 블루투스 스캔이 아닌가**
///
/// 요구가 "앱이 꺼져 있어도"이기 때문이다. `CBCentralManager`로 스캔하려면 앱이 살아
/// 있어야 하는데, 사용자가 앱을 위로 밀어 종료하면 스캔할 주체가 사라진다.
/// 반면 비콘 리전 모니터링은 **iOS가 대신 지켜보다가 앱을 되살려준다.** 앱이 완전히
/// 종료돼 있어도, 심지어 재부팅 뒤에도 리전에 들어가면 깨어난다.
/// 그래서 보드는 iBeacon으로 광고하고, 앱은 리전만 걸어두고 잠든다.
///
/// 블루투스는 그 다음이다. 깨어난 뒤 보드에 "왔다"고 알려주는 데만 쓴다.
final class ArrivalManager: NSObject, ObservableObject, CLLocationManagerDelegate {

    enum Phase {
        case away        // 아직 도착 전
        case welcoming   // 환영 연출 중
        case present     // 자리에 있음

        var label: String {
            switch self {
            case .away:      return "부재"
            case .welcoming: return "환영 중"
            case .present:   return "자리에 있음"
            }
        }
    }

    // MARK: 화면이 보는 값

    @Published private(set) var phase: Phase = .away
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var isMonitoring = false
    @Published private(set) var lastArrival: Date?
    @Published private(set) var proximity: CLProximity = .unknown
    @Published private(set) var notificationsAllowed = false
    @Published private(set) var events: [String] = []

    let board = BoardLink()

    // MARK: 내부

    private let manager = CLLocationManager()
    private let notifier = Notifier()
    private let island = LiveActivityController()
    private let defaults = UserDefaults.standard

    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    /// 마지막 환영으로부터 이 시간 안에는 다시 환영하지 않는다.
    ///
    /// 앱이 죽었다 살아나는 구조라 메모리 변수로는 못 센다. UserDefaults에 남긴다.
    /// 리전 진입은 원래 나갔다 들어와야 다시 오지만, 신호가 약한 자리에서는
    /// 가만히 앉아 있어도 진입/이탈이 반복될 수 있다. 그때 축포가 계속 터지면
    /// 촬영이 아니라 사고다.
    private let cooldown: TimeInterval = 10 * 60
    private let lastArrivalKey = "welcome.lastArrival"

    /// 환영 연출 길이. 펌웨어의 `WELCOME_MS`와 맞춘다
    private let celebrationSeconds: TimeInterval = 6

    /// 잠금화면 카드가 살아 있는 시간.
    ///
    /// 보드가 책상 위에 계속 켜져 있으면 리전 이탈이 안 일어나므로, 이게 없으면
    /// 카드가 하루 종일 잠금화면에 붙어 있는다. 알림 배너는 알림 센터에 따로 쌓이니
    /// 카드까지 오래 남을 이유가 없다.
    private let cardLifetime: TimeInterval = 3 * 60

    /// 카드 내용이 확정되는 시점. 연출(6초)이 끝나고 보드 응답(최대 15초)도
    /// 결판난 뒤여야 한다. 이보다 일찍 걷기를 예약하면 '보드에 알림 전달' 표시가
    /// 영영 안 켜진 채로 굳는다. `holdBackground`의 20초 안이어야 한다
    private let cardFinalizeDelay: TimeInterval = 16

    /// 촬영 모드. 켜두면 쿨다운을 무시하고 들어올 때마다 환영한다.
    ///
    /// **촬영은 같은 장면을 열 번 찍는 일이다.** 쿨다운 10분이면 하루에 여섯 번이라
    /// 두 번째 테이크부터 아무 일도 안 일어나고, 원인을 모른 채 시간을 버린다.
    /// 끄는 걸 잊어도 일상에서 크게 위험하진 않다 — 리전 진입 자체가 나갔다
    /// 들어와야 오기 때문이다.
    var filmMode: Bool {
        get { defaults.bool(forKey: filmModeKey) }
        set {
            defaults.set(newValue, forKey: filmModeKey)
            objectWillChange.send()
            note(newValue ? "촬영 모드 켜짐 — 쿨다운 없음" : "촬영 모드 꺼짐 — 쿨다운 10분")
        }
    }
    private let filmModeKey = "welcome.filmMode"

    var name: String {
        get { defaults.string(forKey: "welcome.name") ?? "" }
        set { defaults.set(newValue, forKey: "welcome.name"); objectWillChange.send() }
    }

    private var region: CLBeaconRegion {
        let r = CLBeaconRegion(
            uuid: BoardIDs.beaconUUID,
            major: BoardIDs.beaconMajor,
            minor: BoardIDs.beaconMinor,
            identifier: BoardIDs.regionID
        )
        r.notifyOnEntry = true
        r.notifyOnExit = true
        // 화면을 켤 때마다 상태를 다시 알리는 옵션. 켜두면 잠금해제할 때마다
        // 이벤트가 와서 로그가 지저분해진다. 진입 이벤트만으로 충분하다
        r.notifyEntryStateOnDisplay = false
        return r
    }

    // MARK: 시작

    /// `AppDelegate.didFinishLaunching`에서 **즉시** 불러야 한다.
    /// 늦게 부르면 위치 이벤트로 깨어난 실행에서 콜백을 놓친다.
    func bootstrap(wokenByLocation: Bool) {
        manager.delegate = self
        // 화면이 꺼진 채로도 리전 이벤트를 받으려면 필요하다.
        // (모니터링만으로도 깨어나지만, 레인징을 이어서 할 때 이게 없으면 막힌다)
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false

        authorization = manager.authorizationStatus
        lastArrival = defaults.object(forKey: lastArrivalKey) as? Date

        note(wokenByLocation ? "위치 이벤트로 깨어남" : "앱 시작")

        notifier.prepare { [weak self] granted in
            DispatchQueue.main.async { self?.notificationsAllowed = granted }
        }

        startMonitoringIfPossible()
        board.prepare()
    }

    func requestPermissions() {
        switch manager.authorizationStatus {
        case .notDetermined:
            // 한 번에 '항상'을 요구할 수 없다. iOS는 '앱 사용 중'을 먼저 받고
            // 그 뒤에야 승격 요청을 허용한다
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        default:
            break
        }
        notifier.prepare { [weak self] granted in
            DispatchQueue.main.async { self?.notificationsAllowed = granted }
        }
    }

    private func startMonitoringIfPossible() {
        guard CLLocationManager.isMonitoringAvailable(for: CLBeaconRegion.self) else {
            note("이 기기는 비콘 모니터링을 지원하지 않습니다")
            return
        }
        let status = manager.authorizationStatus
        guard status == .authorizedAlways || status == .authorizedWhenInUse else {
            isMonitoring = false
            return
        }

        let r = region
        manager.startMonitoring(for: r)
        // 지금 이미 안에 있는지 물어본다. 답은 didDetermineState로 온다
        manager.requestState(for: r)
        isMonitoring = true

        if status == .authorizedWhenInUse {
            // 여기서 멈추면 앱이 살아 있을 때만 동작한다. 기획의 핵심이 빠진다
            note("위치 권한이 '앱 사용 중'입니다 — 꺼진 상태에서는 못 깨어납니다")
        } else {
            note("보드 신호 감시 시작")
        }
    }

    /// 앱 화면에서만 쓰는 정밀 근접도. 백그라운드에서는 굳이 돌리지 않는다
    func startRanging() {
        guard authorization == .authorizedAlways || authorization == .authorizedWhenInUse else { return }
        manager.startRangingBeacons(satisfying: CLBeaconIdentityConstraint(uuid: BoardIDs.beaconUUID))
    }

    func stopRanging() {
        manager.stopRangingBeacons(satisfying: CLBeaconIdentityConstraint(uuid: BoardIDs.beaconUUID))
        proximity = .unknown
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        startMonitoringIfPossible()
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard region.identifier == BoardIDs.regionID else { return }
        note("보드 신호 감지")
        handleArrival(source: "비콘")
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier == BoardIDs.regionID else { return }
        note("보드 신호 사라짐")
        handleDeparture()
    }

    /// 지금 리전 안에 있는지에 대한 답.
    ///
    /// **여기서 환영하면 안 된다.** 이 콜백은 앱을 열 때마다, 재설치할 때마다 온다.
    /// 도착의 정의는 '밖에 있다가 들어온 것'(didEnterRegion)이지 '안에 있음'이 아니다.
    /// 이걸 도착으로 쳤다가 앱만 켜면 축포가 터지는 상태가 된다.
    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard region.identifier == BoardIDs.regionID else { return }
        switch state {
        case .inside:
            if phase == .away { phase = .present }
        case .outside:
            phase = .away
        case .unknown:
            break
        }
    }

    /// 이름이 `didRange`다. `didRangeBeacons`로 쓰면 프로토콜에 안 걸려서
    /// **경고만 뜨고 조용히 안 불린다.** 증상은 근접도가 영영 '측정 중'인 것
    func locationManager(_ manager: CLLocationManager, didRange beacons: [CLBeacon], satisfying constraint: CLBeaconIdentityConstraint) {
        proximity = beacons.first?.proximity ?? .unknown
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        note("감시 실패 — \(error.localizedDescription)")
        isMonitoring = false
    }

    // MARK: 도착

    /// 촬영 리허설용. 쿨다운을 무시하고 전체 연출을 한 번 돌린다
    func rehearse() {
        handleArrival(source: "리허설", force: true)
    }

    func resetToAway() {
        defaults.removeObject(forKey: lastArrivalKey)
        lastArrival = nil
        phase = .away
        island.stop()
        board.send(.away)
        note("부재로 초기화")
    }

    private func handleArrival(source: String, force: Bool = false) {
        let now = Date()

        if !force, !filmMode, let last = lastArrival, now.timeIntervalSince(last) < cooldown {
            let mins = Int(cooldown - now.timeIntervalSince(last)) / 60 + 1
            note("도착 신호 무시 — \(mins)분 더 지나야 다시 환영합니다")
            return
        }

        lastArrival = now
        defaults.set(now, forKey: lastArrivalKey)
        phase = .welcoming
        note("환영합니다! (\(source))")

        // 백그라운드로 깨어난 실행은 몇 초 뒤 다시 잠든다. 블루투스가 붙을 때까지
        // 버틸 시간을 사둔다. 안 사두면 연결 도중에 앱이 정지해서 보드가 조용하다
        holdBackground(seconds: 20)

        // **사람에게 알리는 게 먼저다.** 보드 연결은 실패할 수도 있고 몇 초 걸리지만,
        // 알림은 즉시 뜬다. 순서를 바꾸면 문을 열고 한참 뒤에 폰이 울린다
        notifier.welcome(name: name)
        island.start(arrivedAt: now, name: name)

        // 보드에 통보. 붙는 즉시 전송되고, 아직 사거리 밖이면 iOS가 물고 있다가 붙여준다
        board.send(.arrived) { [weak self] ok in
            DispatchQueue.main.async {
                self?.island.update(boardNotified: ok)
                self?.note(ok ? "보드에 도착 알림 전달" : "보드에 못 알림 (사거리 밖이거나 미등록)")
            }
        }

        // 연출이 끝나면 차분한 상태로 내려온다
        DispatchQueue.main.asyncAfter(deadline: .now() + celebrationSeconds) { [weak self] in
            guard let self, self.phase == .welcoming else { return }
            self.phase = .present
            self.island.update(celebrating: false)
        }

        // 카드 내용이 다 정해진 뒤에 걷을 시각을 iOS에 넘긴다.
        // 여기서 넘겨두면 그 뒤로 앱이 잠들어도 카드는 제 시간에 사라진다
        DispatchQueue.main.asyncAfter(deadline: .now() + cardFinalizeDelay) { [weak self] in
            guard let self else { return }
            self.island.scheduleDismissal(at: now.addingTimeInterval(self.cardLifetime))
        }
    }

    private func handleDeparture() {
        phase = .away
        // 잠금화면 카드는 여기서 걷는다. 자리를 뜬 뒤에도 "환영합니다"가 남아 있으면
        // 어색하고, 무엇보다 다음 출근 때 새 카드가 안 뜬다
        island.stop()
    }

    // MARK: 잡일

    private func holdBackground(seconds: TimeInterval) {
        endBackgroundHold()
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "welcome.arrival") { [weak self] in
            self?.endBackgroundHold()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.endBackgroundHold()
        }
    }

    private func endBackgroundHold() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }

    /// 최근 이벤트. 촬영 전에 "지금 잘 걸려 있나"를 눈으로 확인하는 용도다
    private func note(_ text: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        DispatchQueue.main.async {
            self.events.insert("\(stamp)  \(text)", at: 0)
            if self.events.count > 12 { self.events.removeLast() }
        }
        NSLog("[welcome] \(text)")
    }
}
