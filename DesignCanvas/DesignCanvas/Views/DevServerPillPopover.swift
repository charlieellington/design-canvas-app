// Popover anchored under the DevServerPill. Concise server picker — Running list,
// switch-to-demo, connect-to-port input. Recents and MCP-setup stay in the full
// WorkspaceSwitcher (reachable via ⌘T) for B0; they migrate here in A1 once the
// canvas dropdown takes over the left chip.

import SwiftUI

struct DevServerPillPopover: View {
    let boundServers: [ServerBinding]
    let detectedServers: [DetectedServer]
    let primaryBindingId: UUID?
    let activePort: Int?
    let isInDemoMode: Bool

    var onSelectBoundServer: (ServerBinding) -> Void
    var onBindDetectedServer: (DetectedServer) -> Void
    var onConnectToPort: (Int) -> Void
    var onUnbindServer: (ServerBinding) -> Void
    var onSwitchToDemo: () -> Void
    var onDismiss: () -> Void

    @State private var hovered: String? = nil
    @State private var manualPortText: String = ""
    @FocusState private var portFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !boundServers.isEmpty {
                boundSection
                divider
            }
            let detectedUnbound = detectedServers.filter { detected in
                !boundServers.contains { $0.port == detected.port }
            }
            if !detectedUnbound.isEmpty {
                detectedSection(servers: detectedUnbound)
                divider
            }
            connectRow
            divider
            demoRow
        }
        .frame(width: 300)
        .padding(.vertical, 6)
        .background(Color(hex: 0x191A1D))
    }

    // MARK: - Bound

    @ViewBuilder
    private var boundSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionHeader("Plugged in")
            ForEach(boundServers) { binding in
                boundRow(binding)
            }
        }
        .padding(.vertical, 4)
    }

    private func boundRow(_ binding: ServerBinding) -> some View {
        let id = "bound:\(binding.id.uuidString)"
        let isPrimary = binding.id == primaryBindingId
        let dotColor: Color = {
            switch binding.status {
            case .connected: return .green
            case .stale:     return .orange
            case .offline:   return Color(hex: 0x666666)
            }
        }()
        let projectTail = binding.projectDir
            .map { (($0 as NSString).lastPathComponent) }
        return HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
            Text(binding.port.map { ":\($0)" } ?? binding.origin.absoluteString)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color(hex: 0xEEEEEE))
            Text("·")
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: 0x555555))
            VStack(alignment: .leading, spacing: 0) {
                Text(binding.displayName)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: 0xEEEEEE))
                    .lineLimit(1)
                if let tail = projectTail, tail != binding.displayName {
                    Text(tail)
                        .font(.system(size: 10))
                        .foregroundStyle(Color(hex: 0x666666))
                        .lineLimit(1)
                }
            }
            Spacer()
            if isPrimary {
                Text("primary")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(hex: 0x888888))
            }
            if !isPrimary {
                Button {
                    onUnbindServer(binding)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x888888))
                        .frame(width: 16, height: 16)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white.opacity(hovered == "unbind:\(binding.id.uuidString)" ? 0.10 : 0))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? "unbind:\(binding.id.uuidString)" : nil }
                .help("Unbind this server from the canvas")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(hovered == id ? Color(hex: 0x2C2D30).opacity(0.7) : Color.clear)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? id : nil }
        .onTapGesture {
            onDismiss()
            onSelectBoundServer(binding)
        }
    }

    // MARK: - Detected-but-not-bound

    @ViewBuilder
    private func detectedSection(servers: [DetectedServer]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionHeader("Detected")
            ForEach(servers) { server in
                detectedRow(server)
            }
        }
        .padding(.vertical, 4)
    }

    private func detectedRow(_ server: DetectedServer) -> some View {
        let id = "det:\(server.port)"
        return Button {
            onDismiss()
            onBindDetectedServer(server)
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .stroke(Color(hex: 0x888888), lineWidth: 1)
                    .frame(width: 7, height: 7)
                Text(":\(server.port)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color(hex: 0xCCCCCC))
                Text("·")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: 0x555555))
                Text(server.projectName)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: 0xCCCCCC))
                    .lineLimit(1)
                Spacer()
                Text("bind")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(hex: 0x5E6AD2))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(hovered == id ? Color(hex: 0x2C2D30).opacity(0.7) : Color.clear)
            )
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? id : nil }
    }

    // MARK: - Connect

    @ViewBuilder
    private var connectRow: some View {
        let id = "connect"
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(hex: 0x888888))
                .frame(width: 16)
            Text("Connect to port…")
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: 0xEEEEEE))
            Spacer(minLength: 8)
            TextField("3000", text: $manualPortText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(hex: 0xEEEEEE))
                .frame(width: 54)
                .focused($portFieldFocused)
                .onSubmit { commitManualPort() }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(hex: 0x2C2D30).opacity(0.7))
                )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(hovered == id ? Color(hex: 0x2C2D30).opacity(0.4) : Color.clear)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture { portFieldFocused = true }
        .onHover { hovered = $0 ? id : nil }
    }

    private func commitManualPort() {
        let trimmed = manualPortText.trimmingCharacters(in: .whitespaces)
        guard let port = Int(trimmed), port >= 1, port <= 65535 else { return }
        manualPortText = ""
        portFieldFocused = false
        onDismiss()
        onConnectToPort(port)
    }

    // MARK: - Demo toggle

    @ViewBuilder
    private var demoRow: some View {
        let id = "demo"
        let label = isInDemoMode ? "Already in demo" : "Switch to demo"
        Button {
            guard !isInDemoMode else { return }
            onDismiss()
            onSwitchToDemo()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: 0x888888))
                    .frame(width: 16)
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(isInDemoMode ? Color(hex: 0x888888) : Color(hex: 0xEEEEEE))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(hovered == id && !isInDemoMode ? Color(hex: 0x2C2D30).opacity(0.7) : Color.clear)
            )
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isInDemoMode)
        .onHover { hovered = $0 ? id : nil }
    }

    // MARK: - Chrome

    private var divider: some View {
        Rectangle()
            .fill(Color(hex: 0x2C2D30))
            .frame(height: 1)
            .padding(.horizontal, 6)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(Color(hex: 0x888888))
            .padding(.horizontal, 18)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }
}

private extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}
