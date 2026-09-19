import SwiftUI
import ClaudeRemoteCore

/// Live view of a booted iOS Simulator on the Mac — what the agent is looking at while it drives the app.
struct SimulatorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var selected: String?
    /// Ticks so the "Live" indicator and fps readout stay current between frames.
    @State private var now = Date()

    private var feed: SimulatorFeed { model.simulatorFeed }
    private var device: SimulatorInfo? { feed.devices.first { $0.udid == selected } }

    var body: some View {
        NavigationStack {
            Group {
                if feed.devices.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 14) {
                        screen
                        status
                    }
                    .padding(.horizontal, CDS.gutter).padding(.vertical, 12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CDS.surface0)
            .navigationTitle(device?.name ?? "Simulator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(CDS.surface0, for: .navigationBar)
            .toolbar {
                if feed.devices.count > 1 {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            ForEach(feed.devices) { d in
                                Button {
                                    select(d.udid)
                                } label: {
                                    if d.udid == selected { Label("\(d.name) · \(d.runtime)", systemImage: "checkmark") } else { Text("\(d.name) · \(d.runtime)") }
                                }
                            }
                        } label: {
                            Image(systemName: "iphone.gen3.radiowaves.left.and.right").foregroundStyle(CDS.textSecondary)
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { select(feed.watching ?? feed.devices.first?.udid) }
        .onDisappear { model.stopWatchingSimulator() }
        .onChange(of: feed.devices) { _, devices in
            // The simulator we were watching shut down (or the first one just booted).
            if selected == nil || !devices.contains(where: { $0.udid == selected }) { select(devices.first?.udid) }
        }
        .onChange(of: scenePhase) { _, phase in
            // No point streaming into a backgrounded app.
            switch phase {
            case .background: model.stopWatchingSimulator()
            case .active: if let selected, feed.watching == nil { model.watchSimulator(selected) }
            default: break
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                now = Date()
            }
        }
    }

    private func select(_ udid: String?) {
        selected = udid
        if let udid { model.watchSimulator(udid) } else { model.stopWatchingSimulator() }
    }

    // MARK: pieces

    private var screen: some View {
        GeometryReader { geo in
            ZStack {
                if let frame = feed.frame {
                    Image(uiImage: frame.image)
                        .resizable()
                        .aspectRatio(CGFloat(max(frame.width, 1)) / CGFloat(max(frame.height, 1)), contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                        .padding(6)
                        .background(Color.black, in: RoundedRectangle(cornerRadius: 28))
                        .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(CDS.border))
                        .opacity(feed.isAlive(now: now) ? 1 : 0.6)
                } else {
                    VStack(spacing: 10) {
                        ProgressView().tint(CDS.textMuted)
                        Text("Connecting to \(device?.name ?? "the simulator")…")
                            .font(CDS.body).foregroundStyle(CDS.textMuted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(CDS.surface1, in: RoundedRectangle(cornerRadius: 28))
                    .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(CDS.border))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private var status: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(feed.isAlive(now: now) ? CDS.successFill : CDS.textMuted)
                .frame(width: 7, height: 7)
            Text(statusText).font(CDS.caption).foregroundStyle(CDS.textSecondary)
            Spacer(minLength: 0)
            if let device { Text(device.runtime).font(CDS.caption).foregroundStyle(CDS.textMuted) }
        }
    }

    private var statusText: String {
        guard feed.frame != nil else { return "Waiting for the first frame" }
        guard feed.isAlive(now: now) else { return "No signal from the Mac" }
        let fps = feed.measuredFPS
        var parts = ["Live"]
        parts.append(fps >= 0.5 ? String(format: "%.0f fps", fps) : "screen is static")
        if let frame = feed.frame, frame.width > 0 { parts.append("\(frame.width)×\(frame.height)") }
        return parts.joined(separator: " · ")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "iphone.slash").font(.system(size: 28, weight: .medium)).foregroundStyle(CDS.textMuted)
            Text("No simulator is running").font(.title3.weight(.semibold)).foregroundStyle(CDS.textPrimary)
            Text("When the agent boots an iOS Simulator on the Mac, its screen shows up here live.")
                .font(CDS.body).foregroundStyle(CDS.textMuted).multilineTextAlignment(.center)
        }
        .padding(32)
    }
}

/// Toolbar entry point: visible only while a simulator is booted on the Mac.
struct SimulatorToolbarButton: View {
    @Environment(AppModel.self) private var model
    @Binding var isPresented: Bool

    var body: some View {
        if !model.simulatorFeed.devices.isEmpty {
            Button { isPresented = true } label: {
                Image(systemName: "iphone")
                    .foregroundStyle(CDS.textSecondary)
                    .overlay(alignment: .topTrailing) {
                        Circle().fill(CDS.successFill).frame(width: 6, height: 6).offset(x: 2, y: -1)
                    }
            }
            .accessibilityLabel("Simulator live view")
        }
    }
}
