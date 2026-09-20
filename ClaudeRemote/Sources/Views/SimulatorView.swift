import SwiftUI
import ClaudeRemoteCore

/// Live view of a booted iOS Simulator on the Mac — what the agent is looking at while it drives the app.
/// Touches on the picture, the keyboard bar and the hardware buttons are forwarded to the simulator.
struct SimulatorView: View {
    /// Presented from a chat: a captured screenshot goes into that chat's composer as a file (files
    /// reach every kind of session — hosted ones inline it, desktop ones get it staged on the Mac).
    /// Without it (the session list), captures are copied to the clipboard instead.
    var onCapture: ((Attachment) -> Void)? = nil

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var selected: String?
    /// Ticks so the "Live" indicator and fps readout stay current between frames.
    @State private var now = Date()
    @State private var showKeyboard = false
    @State private var capturing = false
    @State private var draft = ""
    @FocusState private var draftFocused: Bool

    private var feed: SimulatorFeed { model.simulatorFeed }
    private var device: SimulatorInfo? { feed.devices.first { $0.udid == selected } }

    @State private var showApps = false
    @State private var showBoot = false
    @State private var fullScreen = false
    @State private var showOpenURL = false
    @State private var urlDraft = ""

    var body: some View {
        NavigationStack {
            Group {
                if feed.booted.isEmpty {
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
                ToolbarItem(placement: .topBarLeading) {
                    devicesMenu
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showApps) {
                if let udid = selected { SimulatorAppsView(udid: udid) }
            }
            .sheet(isPresented: $showBoot) { SimulatorBootView() }
            .fullScreenCover(isPresented: $fullScreen) { SimulatorFullScreenView(onCapture: onCapture) }
            .alert("Open URL in \(device?.name ?? "the simulator")", isPresented: $showOpenURL) {
                TextField("https://… or myapp://…", text: $urlDraft)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Button("Open") {
                    let url = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let selected, !url.isEmpty { model.sendSimulatorAction(.openURL(url: url), udid: selected) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Deep links and universal links land in the app that handles them; http(s) opens Safari.")
            }
        }
        .onAppear { select(feed.watching ?? feed.booted.first?.udid) }
        .onDisappear { model.stopWatchingSimulator() }
        .onChange(of: feed.devices) { _, devices in
            // The simulator we were watching shut down (or the first one just booted).
            let booted = devices.filter(\.isBooted)
            if selected == nil || !booted.contains(where: { $0.udid == selected }) { select(booted.first?.udid) }
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

    /// Running simulators to switch between, the rest to boot, and what to do with the current one.
    private var devicesMenu: some View {
        Menu {
            if !feed.booted.isEmpty {
                Section("Running") {
                    ForEach(feed.booted) { d in
                        Button { select(d.udid) } label: {
                            if d.udid == selected { Label("\(d.name) · \(d.runtime)", systemImage: "checkmark") } else { Text("\(d.name) · \(d.runtime)") }
                        }
                    }
                }
            }
            if let device, device.isBooted {
                Section(device.name) {
                    Button { model.requestSimulatorApps(device.udid); showApps = true } label: { Label("Open an app…", systemImage: "app.badge") }
                    Button { urlDraft = ""; showOpenURL = true } label: { Label("Open URL…", systemImage: "link") }
                    Button(role: .destructive) { model.sendSimulatorAction(.shutdown, udid: device.udid) } label: { Label("Shut down", systemImage: "power") }
                }
            }
            bootMenu
        } label: {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right").foregroundStyle(CDS.textSecondary)
        }
    }

    /// Opens the picker of simulators that are not running (a sheet: the list is long and a nested
    /// menu closes every time the status clock ticks).
    @ViewBuilder private var bootMenu: some View {
        if feed.devices.contains(where: { !$0.isBooted }) {
            Button { showBoot = true } label: { Label("Boot a simulator…", systemImage: "power.circle") }
        }
    }

    // MARK: pieces

    private var screen: some View {
        SimulatorScreenView()
            .opacity(feed.isAlive(now: now) ? 1 : 0.6)
    }

    private var controls: some View {
        SimulatorControls(showKeyboard: $showKeyboard, capturing: capturing, canCapture: feed.pictureSize != nil,
                          captureLabel: onCapture != nil ? "Attach a screenshot to the chat" : "Copy a screenshot",
                          onCapture: capture, onFullScreen: { fullScreen = true }, onKeyboard: { draftFocused = showKeyboard })
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

    /// A full-resolution still from the Mac — into the chat's composer, or onto the clipboard.
    private func capture() {
        capturing = true
        model.requestSimulatorScreenshot { image, error in
            capturing = false
            guard let image, let jpeg = image.jpegData(compressionQuality: 0.85) else {
                feed.show(error ?? "Could not capture the screen", error: true)
                return
            }
            if let onCapture {
                let stamp = Date().formatted(.dateTime.hour().minute().second()).replacingOccurrences(of: ":", with: "-")
                let name = (device?.name ?? "simulator").replacingOccurrences(of: " ", with: "-")
                guard let attachment = Media.attachment(data: jpeg, filename: "\(name)-\(stamp).jpg", mediaType: "image/jpeg") else {
                    feed.show("The screenshot is too large to attach", error: true)
                    return
                }
                onCapture(attachment)
                dismiss()
            } else {
                UIPasteboard.general.image = image
                feed.show("Screenshot copied — paste it into a chat")
            }
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
                .fill(inputErrorShowing ? CDS.dangerFill : model.simulatorDriver != nil ? CDS.warningFill : feed.isAlive(now: now) ? CDS.successFill : CDS.textMuted)
                .frame(width: 7, height: 7)
            Text(statusText).font(CDS.caption).foregroundStyle(CDS.textSecondary)
            Spacer(minLength: 0)
            if let device { Text(device.runtime).font(CDS.caption).foregroundStyle(CDS.textMuted) }
        }
    }

    private var inputErrorShowing: Bool { feed.notice(at: now)?.isError == true }

    private var statusText: String {
        if let notice = feed.notice(at: now) { return notice.message }
        if let pending = feed.pendingAction {
            let name = feed.devices.first { $0.udid == pending.udid }?.name ?? "simulator"
            return pending.udid == selected ? "\(pending.action.label)…" : "\(pending.action.label) \(name)…"
        }
        if let driver = model.simulatorDriver { return "\(driver) is driving the simulator" }
        guard feed.pictureSize != nil else { return "Waiting for the first frame" }
        guard feed.isAlive(now: now) else { return "No signal from the Mac" }
        let fps = feed.measuredFPS
        var parts = ["Live"]
        parts.append(fps >= 0.5 ? String(format: "%.0f fps", fps) : "screen is static")
        if let size = feed.pictureSize { parts.append("\(Int(size.width))×\(Int(size.height))" + (feed.videoSize != nil ? " video" : "")) }
        return parts.joined(separator: " · ")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if let pending = feed.pendingAction, pending.action == .boot {
                ProgressView().tint(CDS.textMuted).padding(.bottom, 4)
                Text("Booting \(feed.devices.first { $0.udid == pending.udid }?.name ?? "the simulator")…").font(.title3.weight(.semibold)).foregroundStyle(CDS.textPrimary)
                Text("Usually 20–60 seconds. The screen appears here as soon as it is up.")
                    .font(CDS.body).foregroundStyle(CDS.textMuted).multilineTextAlignment(.center)
            } else {
                Image(systemName: "iphone.slash").font(.system(size: 28, weight: .medium)).foregroundStyle(CDS.textMuted)
                Text("No simulator is running").font(.title3.weight(.semibold)).foregroundStyle(CDS.textPrimary)
                Text("When the agent boots an iOS Simulator on the Mac, its screen shows up here live — and you can tap, swipe and type into it.")
                    .font(CDS.body).foregroundStyle(CDS.textMuted).multilineTextAlignment(.center)
                if feed.devices.contains(where: { !$0.isBooted }) {
                    Button { showBoot = true } label: {
                        Label("Boot a simulator", systemImage: "power.circle")
                            .font(CDS.bodyMedium).foregroundStyle(CDS.onPrimary)
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(CDS.fillPrimary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                }
                if let notice = feed.notice(at: now), notice.isError {
                    Text(notice.message).font(CDS.caption).foregroundStyle(CDS.danger).multilineTextAlignment(.center).padding(.top, 4)
                }
            }
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
                        if !model.simulatorFeed.booted.isEmpty {
                            Circle().fill(CDS.successFill).frame(width: 6, height: 6).offset(x: 2, y: -1)
                        }
                    }
            }
            .accessibilityLabel("Simulator")
        }
    }
}

/// Apps installed on a simulator; tapping one launches it (user-installed apps first).
struct SimulatorAppsView: View {
    let udid: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var apps: (udid: String, items: [SimulatorApp], error: String?)? {
        model.simulatorFeed.apps?.udid == udid ? model.simulatorFeed.apps : nil
    }

    private var filtered: [SimulatorApp] {
        let items = apps?.items ?? []
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.bundleId.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let apps {
                    if let error = apps.error {
                        ContentUnavailableView("Could not list apps", systemImage: "exclamationmark.triangle", description: Text(error))
                    } else {
                        List {
                            ForEach(["User", "System"], id: \.self) { kind in
                                let section = filtered.filter { $0.kind == kind }
                                if !section.isEmpty {
                                    Section(kind == "User" ? "Your apps" : "System") {
                                        ForEach(section) { app in
                                            Button {
                                                model.sendSimulatorAction(.launch(bundleId: app.bundleId), udid: udid)
                                                dismiss()
                                            } label: {
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(app.name).font(CDS.bodyMedium).foregroundStyle(CDS.textPrimary)
                                                    Text(app.bundleId).font(CDS.codeSmall).foregroundStyle(CDS.textMuted)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .listStyle(.insetGrouped)
                        .searchable(text: $query, prompt: "Name or bundle id")
                    }
                } else {
                    ProgressView().tint(CDS.textMuted)
                }
            }
            .background(CDS.surface0)
            .navigationTitle("Open an app")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

/// Simulators that are not running, grouped by runtime; tapping one boots it headless on the Mac.
struct SimulatorBootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var idle: [SimulatorInfo] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return model.simulatorFeed.devices.filter { !$0.isBooted && (q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) || $0.runtime.localizedCaseInsensitiveContains(q)) }
    }

    var body: some View {
        NavigationStack {
            List {
                let runtimes = Array(Set(idle.map(\.runtime))).sorted(by: SimulatorInfo.runtimePrecedes)
                ForEach(runtimes, id: \.self) { runtime in
                    Section(runtime) {
                        ForEach(idle.filter { $0.runtime == runtime }) { d in
                            Button {
                                model.sendSimulatorAction(.boot, udid: d.udid)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(d.name).font(CDS.bodyMedium).foregroundStyle(CDS.textPrimary)
                                    Spacer()
                                    if d.isBooting { ProgressView().tint(CDS.textMuted) }
                                }
                            }
                            .disabled(d.isBooting)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: "Device or runtime")
            .background(CDS.surface0)
            .navigationTitle("Boot a simulator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

/// Home / Lock / keyboard / screenshot / full screen / Backspace / Return — shared by the sheet and the full-screen view.
struct SimulatorControls: View {
    @Environment(AppModel.self) private var model
    @Binding var showKeyboard: Bool
    var capturing: Bool
    var canCapture: Bool
    var captureLabel: String
    var dark = false
    var onCapture: () -> Void
    var onFullScreen: (() -> Void)?
    var onKeyboard: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            button("house", label: "Home") { model.sendSimulatorInput(.button(button: .home)) }
            button("lock", label: "Lock") { model.sendSimulatorInput(.button(button: .lock)) }
            button("keyboard", label: "Keyboard", active: showKeyboard) {
                showKeyboard.toggle()
                onKeyboard()
            }
            button(capturing ? "hourglass" : "camera", label: captureLabel, action: onCapture)
                .disabled(capturing || !canCapture)
            if let onFullScreen {
                button("arrow.up.left.and.arrow.down.right", label: "Full screen", action: onFullScreen)
                    .disabled(!canCapture)
            }
            Spacer(minLength: 0)
            button("delete.left", label: "Backspace") { model.sendSimulatorInput(.key(key: .backspace)) }
            button("return", label: "Return") { model.sendSimulatorInput(.key(key: .return)) }
        }
    }

    private func button(_ symbol: String, label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(active ? (dark ? Color.black : CDS.onPrimary) : (dark ? Color.white.opacity(0.85) : CDS.textSecondary))
                .frame(width: 44, height: 36)
                .background(active ? (dark ? Color.white : CDS.fillPrimary) : (dark ? Color.white.opacity(0.14) : CDS.fillControl), in: RoundedRectangle(cornerRadius: CDS.radius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The picture on black, edge to edge; a landscape simulator is shown rotated to fill a portrait phone.
struct SimulatorFullScreenView: View {
    var onCapture: ((Attachment) -> Void)?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showKeyboard = false
    @State private var draft = ""
    @State private var capturing = false
    @FocusState private var draftFocused: Bool

    private var feed: SimulatorFeed { model.simulatorFeed }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            VStack(spacing: 10) {
                SimulatorScreenView(rotateLandscape: true, bezel: false)
                if showKeyboard {
                    HStack(spacing: 8) {
                        TextField("Type into the simulator", text: $draft, axis: .vertical)
                            .lineLimit(1...3).font(CDS.body).foregroundStyle(.white)
                            .focused($draftFocused).submitLabel(.send).onSubmit(sendDraft)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: CDS.radius))
                        Button(action: sendDraft) {
                            Image(systemName: "arrow.up").font(.system(size: 15, weight: .semibold)).foregroundStyle(.black)
                                .frame(width: 36, height: 36).background(Color.white, in: Circle())
                        }
                        .buttonStyle(.plain).disabled(draft.isEmpty).opacity(draft.isEmpty ? 0.4 : 1)
                    }
                }
                SimulatorControls(showKeyboard: $showKeyboard, capturing: capturing, canCapture: feed.pictureSize != nil,
                                  captureLabel: onCapture != nil ? "Attach a screenshot to the chat" : "Copy a screenshot", dark: true,
                                  onCapture: capture, onFullScreen: nil, onKeyboard: { draftFocused = showKeyboard })
            }
            .padding(.horizontal, 12).padding(.top, 44).padding(.bottom, 8)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 32, height: 32).background(Color.white.opacity(0.18), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, 8).padding(.trailing, 12)
            .accessibilityLabel("Leave full screen")
        }
        .statusBarHidden(true)
        .onChange(of: feed.booted.isEmpty) { _, empty in if empty { dismiss() } }
        .onDisappear {
            // Hand the video layer back to the sheet underneath (its host gets no SwiftUI update for this).
            if let host = feed.player.activeHost { feed.player.rehome(from: host) }
        }
    }

    private func sendDraft() {
        let text = draft
        guard !text.isEmpty else { return }
        model.sendSimulatorInput(.text(text: text))
        draft = ""
    }

    private func capture() {
        capturing = true
        model.requestSimulatorScreenshot { image, error in
            capturing = false
            guard let image, let jpeg = image.jpegData(compressionQuality: 0.85) else { feed.show(error ?? "Could not capture the screen", error: true); return }
            if let onCapture, let attachment = Media.attachment(data: jpeg, filename: "simulator-\(Int(Date().timeIntervalSince1970)).jpg", mediaType: "image/jpeg") {
                onCapture(attachment)
                dismiss()
            } else {
                UIPasteboard.general.image = image
                feed.show("Screenshot copied — paste it into a chat")
            }
        }
    }
}
