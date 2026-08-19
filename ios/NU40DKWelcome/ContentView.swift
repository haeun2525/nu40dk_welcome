import CoreLocation
import SwiftUI

/// 평소에는 볼 일이 없는 화면이다. 이 앱의 본체는 잠들어 있는 동안 돌아간다.
/// 그래서 여기가 하는 일은 딱 둘 — **준비가 됐는지 한눈에 보여주기**,
/// 그리고 **촬영 전에 전체를 한 번 돌려보기**.
struct ContentView: View {
    @EnvironmentObject private var arrival: ArrivalManager
    @EnvironmentObject private var board: BoardLink

    @State private var name: String = ""

    /// 촬영용. 켜면 체크리스트·버튼·로그가 전부 사라지고 인사말만 남는다.
    ///
    /// **폰 화면을 녹화할 때 '부재로 초기화' 같은 버튼이 찍히면 안 되기 때문이다.**
    /// 지우지 않고 숨기는 이유는 리테이크 때 '환영 리허설'이 다시 필요해서다.
    /// 되돌리는 손잡이는 **가방을 1초 꾹 누르기** — 화면에 아무 흔적이 없어야 하므로
    /// 버튼이 아니라 숨은 제스처여야 한다
    @AppStorage("welcome.stageMode") private var stageMode = false

    var body: some View {
        ZStack {
            background
            ScrollView {
                VStack(spacing: 26) {
                    header
                    if !stageMode {
                        checklist
                        actions
                        log
                    }
                }
                .padding(22)
            }
        }
        .onAppear {
            name = arrival.name
            arrival.startRanging()
        }
        .onDisappear { arrival.stopRanging() }
    }

    // MARK: 배경

    private var background: some View {
        // 도착하면 따뜻해진다. 화면을 안 보고 있어도 켜자마자 상태를 알 수 있게
        LinearGradient(
            colors: arrival.phase == .away
                ? [Color(red: 0.03, green: 0.04, blue: 0.07), Color(red: 0.05, green: 0.06, blue: 0.10)]
                : [Color(red: 0.16, green: 0.09, blue: 0.04), Color(red: 0.05, green: 0.04, blue: 0.07)],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: arrival.phase)
    }

    // MARK: 큰 상태

    private var header: some View {
        VStack(spacing: 10) {
            Text(arrival.phase == .away ? "👜" : "✨")
                .font(.system(size: 64))
                .scaleEffect(arrival.phase == .welcoming ? 1.15 : 1.0)
                .animation(.spring(duration: 0.6).repeatCount(3, autoreverses: true),
                           value: arrival.phase)

            Text(headline)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)

            Text(subline)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        .padding(.top, 24)
        // 화면에 보이는 버튼으로 만들면 그 버튼이 녹화에 찍힌다. 그래서 숨은 제스처다
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 1.0) {
            withAnimation(.easeInOut(duration: 0.35)) { stageMode.toggle() }
        }
    }

    private var headline: String {
        switch arrival.phase {
        case .away:      return "기다리는 중"
        case .welcoming: return name.isEmpty ? "환영합니다!" : "\(name)님, 환영합니다!"
        case .present:   return "자리에 있어요"
        }
    }

    private var subline: String {
        if arrival.phase == .away {
            return arrival.isMonitoring
                ? "보드 근처에 가면 앱이 꺼져 있어도 깨어납니다"
                : "아직 감시가 시작되지 않았습니다"
        }
        var parts: [String] = []
        if let last = arrival.lastArrival {
            parts.append(DateFormatter.localizedString(from: last, dateStyle: .none, timeStyle: .short) + " 도착")
        }
        parts.append(proximityLabel)
        return parts.joined(separator: " · ")
    }

    private var proximityLabel: String {
        switch arrival.proximity {
        case .immediate: return "바로 앞"
        case .near:      return "가까움"
        case .far:       return "멀리"
        default:         return "거리 측정 중"
        }
    }

    // MARK: 준비 상태

    private var checklist: some View {
        VStack(spacing: 0) {
            row("위치 권한 '항상'",
                ok: arrival.authorization == .authorizedAlways,
                detail: authDetail)
            divider
            row("알림 권한", ok: arrival.notificationsAllowed,
                detail: arrival.notificationsAllowed ? "환영 알림이 뜹니다" : "허용해야 알림이 뜹니다")
            divider
            row("보드 등록", ok: board.isRegistered, detail: board.statusText)
            divider
            row("보드 연결", ok: board.isConnected,
                detail: board.isConnected
                    ? "\(board.boardState?.label ?? "연결됨")\(board.rssi.map { " · \($0) dBm" } ?? "")"
                    : "사거리에 들어오면 자동으로 붙습니다")
        }
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }

    private var authDetail: String {
        switch arrival.authorization {
        case .authorizedAlways:   return "앱이 꺼져 있어도 깨어납니다"
        case .authorizedWhenInUse: return "'앱 사용 중'입니다 — 꺼지면 못 깨어납니다"
        case .denied, .restricted: return "설정 > welcome 에서 '항상'으로 바꿔주세요"
        default:                   return "아직 요청하지 않았습니다"
        }
    }

    private func row(_ title: String, ok: Bool, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? Color.green : Color.orange)
                .font(.system(size: 20))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
        }
        .padding(14)
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.leading, 46)
    }

    // MARK: 조작

    private var actions: some View {
        VStack(spacing: 12) {
            HStack {
                Text("이름").font(.system(size: 14)).foregroundStyle(.white.opacity(0.6))
                TextField("비워두면 인사만 합니다", text: $name)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.white)
                    .onSubmit { arrival.name = name }
            }
            .padding(14)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))

            if arrival.authorization != .authorizedAlways || !arrival.notificationsAllowed {
                button("권한 허용하기", tint: .orange) { arrival.requestPermissions() }
            }

            // 최초 1회. 보드 옆에서 눌러야 한다.
            //
            // **등록된 뒤에도 버튼이 남아 있어야 한다.** 보드를 새것으로 바꾸면
            // 저장된 identifier가 옛 보드를 가리켜서 영영 못 붙는데, 버튼을
            // 숨겨두면 앱에서 고칠 방법이 없어진다(앱 삭제 말고는).
            button(board.isScanning ? "찾는 중…"
                                    : (board.isRegistered ? "보드 다시 등록하기" : "보드 등록하기"),
                   tint: .blue) {
                if board.isRegistered { board.forget() }
                board.startRegistration()
            }

            // 촬영 날에는 켜두고, 끝나면 끈다. 끄는 걸 잊었을 때 어떻게 되는지가
            // 바로 아래 설명에 보이도록 문구를 상태에 따라 바꾼다
            Toggle(isOn: Binding(get: { arrival.filmMode },
                                 set: { arrival.filmMode = $0 })) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("촬영 모드")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(arrival.filmMode
                         ? "들어올 때마다 매번 환영합니다"
                         : "한 번 환영하면 10분간 쉽니다")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .tint(.pink)
            .padding(14)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))

            // 촬영장에서 제일 많이 누르게 되는 버튼.
            // 실제로 걸어 들어가지 않고도 알림 → 잠금화면 카드 → 보드 → 맥까지 전부 돈다
            button("환영 리허설", tint: .green) {
                arrival.name = name
                arrival.rehearse()
            }

            button("부재로 초기화", tint: .gray) { arrival.resetToAway() }

            Text("촬영할 때는 가방을 1초 꾹 — 이 아래가 전부 숨습니다")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.32))
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
        }
    }

    private func button(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(tint.opacity(0.22), in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(tint)
        }
    }

    // MARK: 로그

    private var log: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("최근 기록")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
            ForEach(arrival.events, id: \.self) { line in
                Text(line)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, 4)
    }
}
