import SwiftUI
import Network
import ClaudeRemoteCore

/// First-run screen: pick the Mac (Bonjour), scan the QR, or type host + token.
struct PairingView: View {
    @Environment(AppModel.self) private var model
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
            .navigationTitle("Pair with your Mac")
            .sheet(isPresented: $showScanner) {
                QRScannerView { payload in
                    showScanner = false
                    if let info = PairingInfo.parse(pairURL: payload) {
                        model.pair(info)
                    } else {
                        scanError = "That QR code is not a ccremote pairing code."
                    }
                }
            }
            .onAppear { browser.start() }
            .onDisappear { browser.stop() }
        }
    }

    private var canConnect: Bool {
        token.trimmingCharacters(in: .whitespaces).count >= 8 && (selectedService != nil || !manualHost.isEmpty)
    }

    private func connect() {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if let service = selectedService {
            model.pair(PairingInfo(name: service, host: nil, port: 7811, serviceName: service, token: t))
        } else {
            let port = UInt16(manualPort) ?? 7811
            model.pair(PairingInfo(name: manualHost, host: manualHost.trimmingCharacters(in: .whitespaces), port: port, serviceName: nil, token: t))
        }
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
