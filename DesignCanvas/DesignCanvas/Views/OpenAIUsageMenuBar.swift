// macOS menu-bar label and compact read-only Codex usage popover. Visual
// treatment follows the existing Claude popover and the strict Linear-inspired
// Design Canvas tokens; no OpenAI-specific color is introduced.

import SwiftUI

struct OpenAIMenuBarLabel: View {
    @Bindable var service: OpenAIUsageService

    @State private var renderTick = Date()
    private let renderTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            switch service.state {
            case .connected(let snapshot):
                Text(OpenAIUsageFormatter.menuBarText(snapshot: snapshot, now: renderTick))
                    .foregroundStyle(.primary)
            case .loading:
                Image(systemName: "ellipsis")
            case .signedOut, .apiKeyUnsupported:
                Image(systemName: "key.fill")
            case .unavailable, .error:
                Image(systemName: "exclamationmark.circle")
            }
        }
        .onReceive(renderTimer) { renderTick = $0 }
    }
}

struct OpenAIUsagePopover: View {
    @Bindable var service: OpenAIUsageService

    @State private var renderTick = Date()
    @State private var isRefreshHovered = false
    private let renderTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            divider
            content
            divider
            refreshAction
        }
        .padding(16)
        .frame(width: 280)
        .background(Color(openAIHex: 0x191A1D))
        .onReceive(renderTimer) { renderTick = $0 }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("OpenAI")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(openAIHex: 0xEEEEEE))
            Text(planName)
                .font(.system(size: 13))
                .foregroundStyle(Color(openAIHex: 0x888888))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 8)
    }

    private var planName: String {
        if case .connected(let snapshot) = service.state {
            return snapshot.planDisplayName
        }
        return "Codex usage"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch service.state {
        case .connected(let snapshot):
            connectedContent(snapshot)

        case .loading:
            statusMessage(icon: nil, text: "Fetching Codex usage…", showsProgress: true)

        case .signedOut:
            statusMessage(
                icon: "key.fill",
                text: "Sign in to ChatGPT through Codex or Conductor to see subscription usage."
            )

        case .apiKeyUnsupported:
            statusMessage(
                icon: "key.fill",
                text: "This Codex session isn't using a ChatGPT subscription. Sign in with ChatGPT to see subscription usage."
            )

        case .unavailable(let message), .error(let message):
            statusMessage(icon: "exclamationmark.circle", text: message)
        }
    }

    private func connectedContent(_ snapshot: OpenAIUsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(snapshot.windows.sorted(by: OpenAIUsageSnapshot.windowSort)) { window in
                usageSection(
                    title: OpenAIUsageFormatter.windowTitle(window),
                    window: window,
                    showsReset: true
                )
            }

            ForEach(snapshot.additionalLimits) { limit in
                if let window = limit.displayWindow {
                    usageSection(title: limit.name, window: window, showsReset: false)
                }
            }

            creditsSection(snapshot.credits)
        }
    }

    private func usageSection(
        title: String,
        window: OpenAIRateLimitWindow,
        showsReset: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Color(openAIHex: 0xEEEEEE))
                .lineLimit(1)
                .truncationMode(.tail)

            HStack(spacing: 8) {
                Text("\(window.usedPercent)% used")
                Spacer(minLength: 8)
                Text("\(window.remainingPercent)% remaining")
            }
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Color(openAIHex: 0xEEEEEE))

            OpenAIUsageProgressBar(remainingPercent: window.remainingPercent)

            if showsReset, let resetsAt = window.resetsAt {
                Text("Resets \(OpenAIUsageFormatter.absoluteResetTime(resetsAt))")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color(openAIHex: 0x888888))
            }
        }
        .padding(.vertical, 16)
    }

    private func creditsSection(_ credits: OpenAICreditsSnapshot?) -> some View {
        HStack(spacing: 8) {
            Text("Credits remaining")
                .font(.system(size: 13))
                .foregroundStyle(Color(openAIHex: 0x888888))
            Spacer(minLength: 8)
            Text(credits?.displayBalance ?? "—")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color(openAIHex: 0xEEEEEE))
        }
        .padding(.vertical, 16)
    }

    private func statusMessage(
        icon: String?,
        text: String,
        showsProgress: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .tint(Color(openAIHex: 0xFFFFFF))
            } else if let icon {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(openAIHex: 0x888888))
                    .frame(width: 16)
            }
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Color(openAIHex: 0x888888))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Refresh

    private var refreshAction: some View {
        Button {
            service.refreshNow()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text("Refresh")
                    .font(.system(size: 13))
                Spacer()
            }
            .foregroundStyle(Color(openAIHex: 0xEEEEEE))
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isRefreshHovered ? Color(openAIHex: 0x2C2D30) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isRefreshHovered = $0 }
        .padding(.top, 8)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color(openAIHex: 0x2C2D30))
            .frame(height: 1)
    }

}

private struct OpenAIUsageProgressBar: View {
    let remainingPercent: Int

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(openAIHex: 0x2C2D30))
                Capsule()
                    .fill(Color(openAIHex: 0xFFFFFF))
                    .frame(
                        width: geometry.size.width * CGFloat(max(0, min(100, remainingPercent))) / 100
                    )
            }
        }
        .frame(height: 4)
    }
}

private extension Color {
    init(openAIHex value: UInt32) {
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }
}
