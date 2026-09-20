import SwiftUI
import ClaudeRemoteCore

/// Live view of a booted iOS Simulator on the Mac — what the agent is looking at while it drives the app.
/// Touches on the picture, the keyboard bar and the hardware buttons are forwarded to the simulator.
struct SimulatorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var selected: String?
    /// Ticks so the "Live" indicator and fps readout stay current between frames.
    @State private var now = Date()
    /// The finger currently on the screen: where it has been and since when.
    @State private var stroke: [(point: CGPoint, at: Date)] = []
    /// Brief ring where the last tap landed.
    @State private var tapMark: (point: CGPoint, id: UUID)?
    @State private var showKeyboard = false
    @State private var draft = ""
    @FocusState private var draftFocused: Bool

    private var feed: SimulatorFeed { model.simulatorFeed }
    private var device: SimulatorInfo? { feed.devices.first { $0.udid == selected } }

    var body: some View {
        NavigationStack {
            Group {
                if feed.devices.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 12) {
                        screen
                        status
                        if showKeyboard { keyboardBar }
                        controls
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
                        .overlay { touchSurface }
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

    /// Sits exactly over the picture, so gesture locations are fractions of the simulator screen.
    private var touchSurface: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.clear
                if let tapMark {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.9), lineWidth: 2)
                        .background(Circle().fill(Color.white.opacity(0.25)))
                        .frame(width: 28, height: 28)
                        .position(tapMark.point)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                        .id(tapMark.id)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        if stroke.isEmpty { model.setSimulatorInteracting(true) }
                        stroke.append((value.location, Date()))
                    }
                    .onEnded { value in
                        stroke.append((value.location, Date()))
                        finishStroke(in: geo.size)
                    }
            )
        }
    }

    /// Tap, long press or a drag path — decided when the finger lifts, then sent as one event.
    private func finishStroke(in size: CGSize) {
        defer { stroke = []; model.setSimulatorInteracting(false) }
        guard size.width > 0, size.height > 0, let first = stroke.first, let last = stroke.last else { return }
        let unit = { (p: CGPoint) in (x: Double(min(max(p.x / size.width, 0), 1)), y: Double(min(max(p.y / size.height, 0), 1))) }
        let travelled = stroke.map { hypot($0.point.x - first.point.x, $0.point.y - first.point.y) }.max() ?? 0
        let duration = last.at.timeIntervalSince(first.at)
        if travelled < 10 {
            let p = unit(first.point)
            model.sendSimulatorInput(.tap(x: p.x, y: p.y, holdSeconds: duration > 0.35 ? duration : nil))
            withAnimation(.easeOut(duration: 0.15)) { tapMark = (first.point, UUID()) }
            let marked = tapMark?.id
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                if tapMark?.id == marked { withAnimation(.easeIn(duration: 0.2)) { tapMark = nil } }
            }
            return
        }
        // Thin a long drag to ~48 samples (keeping both ends) so a scroll does not become hundreds of messages.
        let step = max(1, Int((Double(stroke.count) / 48).rounded(.up)))
        var kept = stride(from: 0, to: stroke.count, by: step).map { stroke[$0] }
        if kept.last?.at != last.at { kept.append(last) }
        var previous = first.at
        let path = kept.map { sample -> SimulatorTouchSample in
            let p = unit(sample.point)
            let dt = sample.at.timeIntervalSince(previous)
            previous = sample.at
            return SimulatorTouchSample(x: p.x, y: p.y, dt: max(dt, 0))
        }
        model.sendSimulatorInput(.touch(path: path))
    }

    private var controls: some View {
        HStack(spacing: 10) {
            controlButton("house", label: "Home") { model.sendSimulatorInput(.button(button: .home)) }
            controlButton("lock", label: "Lock") { model.sendSimulatorInput(.button(button: .lock)) }
            controlButton("keyboard", label: "Keyboard", active: showKeyboard) {
                showKeyboard.toggle()
                draftFocused = showKeyboard
            }
            Spacer(minLength: 0)
            controlButton("delete.left", label: "Backspace") { model.sendSimulatorInput(.key(key: .backspace)) }
            controlButton("return", label: "Return") { model.sendSimulatorInput(.key(key: .return)) }
        }
    }

    private func controlButton(_ symbol: String, label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(active ? CDS.onPrimary : CDS.textSecondary)
                .frame(width: 44, height: 36)
                .background(active ? CDS.fillPrimary : CDS.fillControl, in: RoundedRectangle(cornerRadius: CDS.radius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// Text typed here lands in whatever field has focus in the simulator (pasted, so any script works).
    private var keyboardBar: some View {
        HStack(spacing: 8) {
            TextField("Type into the simulator", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .font(CDS.body)
                .focused($draftFocused)
                .submitLabel(.send)
                .onSubmit(sendDraft)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(CDS.surface2, in: RoundedRectangle(cornerRadius: CDS.radius))
                .overlay(RoundedRectangle(cornerRadius: CDS.radius).strokeBorder(CDS.border))
            Button(action: sendDraft) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(CDS.onPrimary)
                    .frame(width: 36, height: 36)
                    .background(CDS.fillPrimary, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(draft.isEmpty)
            .opacity(draft.isEmpty ? 0.4 : 1)
            .accessibilityLabel("Send text")
        }
    }

    private func sendDraft() {
        let text = draft
        guard !text.isEmpty else { return }
        model.sendSimulatorInput(.text(text: text))
        draft = ""
    }

    private var status: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(inputErrorShowing ? CDS.dangerFill : feed.isAlive(now: now) ? CDS.successFill : CDS.textMuted)
                .frame(width: 7, height: 7)
            Text(statusText).font(CDS.caption).foregroundStyle(CDS.textSecondary)
            Spacer(minLength: 0)
            if let device { Text(device.runtime).font(CDS.caption).foregroundStyle(CDS.textMuted) }
        }
    }

    private var inputErrorShowing: Bool {
        guard let error = feed.inputError else { return false }
        return now.timeIntervalSince(error.at) < 6
    }

    private var statusText: String {
        if let error = feed.inputError, now.timeIntervalSince(error.at) < 6 { return error.message }
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
            Text("When the agent boots an iOS Simulator on the Mac, its screen shows up here live — and you can tap, swipe and type into it from here.")
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
