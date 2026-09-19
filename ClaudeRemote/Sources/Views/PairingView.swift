import SwiftUI
import Network
import ClaudeRemoteCore

/// Pair with a Mac: pick it on the LAN (Bonjour), scan the QR, or type host + token. The root
/// screen until the first Mac is paired; after that a sheet ("Add Mac…") for the next ones.
struct PairingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var browser = BonjourBrowser()
    @State private var selectedService: String?
    @State private var manualHost = ""
    @State private var manualPort = "7811"
    @State private var token = ""
    @State private var showScanner = false
    @State private var scanError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Run `ccremote` on your Mac, then pick it below or scan the QR code it prints.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Macs on this network") {
                    if browser.results.isEmpty {
                        HStack { ProgressView().controlSize(.small); Text("Looking for ccremote…").foregroundStyle(.secondary) }
                    }
                    ForEach(browser.results, id: \.self) { name in
                        Button {
                            selectedService = name
                            manualHost = ""
                        } label: {
                            HStack {
                                Image(systemName: "desktopcomputer")
                                Text(name)
                                if isPaired(name) { CDSChip(text: "Paired") }
                                Spacer()
                                if selectedService == name { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                        .tint(.primary)
                    }
                }
                Section("Or connect by address") {
                    TextField("Host (e.g. 192.168.1.40 or mac.tail-net.ts.net)", text: $manualHost)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .onChange(of: manualHost) { if !manualHost.isEmpty { selectedService = nil } }
                    TextField("Port", text: $manualPort).keyboardType(.numberPad)
                }
                Section("Pairing token") {
                    TextField("Token from ccremote", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().font(.system(.body, design: .monospaced))
                    Button {
                        showScanner = true
                    } label: {
                        Label("Scan QR code", systemImage: "qrcode.viewfinder")
                    }
                    if let scanError { Text(scanError).font(.footnote).foregroundStyle(.red) }
                }
                Section {
                    Button("Connect") { connect() }
                        .disabled(!canConnect)
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle(isAddingAnother ? "Add a Mac" : "Pair with your Mac")
            .toolbar {
                if isAddingAnother {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
            }
            .sheet(isPresented: $showScanner) {
                QRScannerView { payload in
                    showScanner = false
                    if let info = PairingInfo.parse(pairURL: payload) {
                        pair(info)
                    } else {
                        scanError = "That QR code is not a ccremote pairing code."
                    }
                }
            }
            // A pairing that arrived some other way (the ccremote:// URL from Camera) also ends this sheet.
            .onChange(of: model.activeMacId) { _, _ in dismiss() }
            .onAppear { browser.start() }
            .onDisappear { browser.stop() }
        }
    }

    /// Presented over the session list rather than as the first-run screen.
    private var isAddingAnother: Bool { !model.macs.isEmpty }

    private func isPaired(_ service: String) -> Bool {
        model.macs.contains { $0.serviceName == service || $0.hostName == service }
    }

    private var canConnect: Bool {
        token.trimmingCharacters(in: .whitespaces).count >= 8 && (selectedService != nil || !manualHost.isEmpty)
    }

    private func connect() {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if let service = selectedService {
            pair(PairingInfo(name: service, host: nil, port: 7811, serviceName: service, token: t))
        } else {
            let port = UInt16(manualPort) ?? 7811
            pair(PairingInfo(name: manualHost, host: manualHost.trimmingCharacters(in: .whitespaces), port: port, serviceName: nil, token: t))
        }
    }

    private func pair(_ info: PairingInfo) {
        model.pair(info)
        dismiss()
    }
}

@MainActor
@Observable
final class BonjourBrowser {
    private(set) var results: [String] = []
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_ccremote._tcp", domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let names = results.compactMap { result -> String? in
                if case .service(let name, _, _, _) = result.endpoint { return name }
                return nil
            }.sorted()
            Task { @MainActor [weak self] in self?.results = names }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}
