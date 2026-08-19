import ActivityKit
import SwiftUI
import WidgetKit

/// 잠금화면 위에 뜨는 환영 카드.
///
/// 출근길에 폰을 꺼내면 잠금화면에 이미 올라와 있는 그림이 목적이다.
/// 알림은 몇 초 뒤 사라지지만 이건 남아 있어서, 촬영에서 폰을 비출 때 확실하다.
struct WelcomeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WelcomeAttributes.self) { context in
            lockScreen(context)
                .activityBackgroundTint(Color(red: 0.09, green: 0.06, blue: 0.03))
                .activitySystemActionForegroundColor(.white)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text("✨").font(.system(size: 28))
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(greeting(context.attributes))
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                        Text(arrivedLine(context.state))
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    boardBadge(context.state)
                }
            } compactLeading: {
                Text("✨")
            } compactTrailing: {
                Text(context.state.arrivedAt, style: .time)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(red: 1.0, green: 0.84, blue: 0.64))
            } minimal: {
                Text("✨")
            }
        }
    }

    private func greeting(_ attributes: WelcomeAttributes) -> String {
        attributes.name.isEmpty ? attributes.greeting : "\(attributes.name)님, \(attributes.greeting)"
    }

    private func arrivedLine(_ state: WelcomeAttributes.ContentState) -> String {
        let time = DateFormatter.localizedString(from: state.arrivedAt, dateStyle: .none, timeStyle: .short)
        return "\(time) 도착"
    }

    @ViewBuilder
    private func boardBadge(_ state: WelcomeAttributes.ContentState) -> some View {
        // 보드에 도착을 알렸는지. 촬영 전 점검에 쓰는 표시라 작게 둔다
        if state.boardNotified {
            Label("보드", systemImage: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.5))
        } else {
            Label("보드", systemImage: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    private func lockScreen(_ context: ActivityViewContext<WelcomeAttributes>) -> some View {
        HStack(spacing: 16) {
            Text(context.state.isCelebrating ? "✨" : "☕️")
                .font(.system(size: 40))

            VStack(alignment: .leading, spacing: 5) {
                Text(greeting(context.attributes))
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                Text(context.state.isCelebrating
                     ? "책상 위 보드가 반갑게 맞이하고 있어요"
                     : "오늘도 좋은 하루 보내요")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.62))
                Text(arrivedLine(context.state))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }
}

@main
struct WelcomeWidgetBundle: WidgetBundle {
    var body: some Widget {
        WelcomeLiveActivity()
    }
}
