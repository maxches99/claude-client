import SwiftUI
import ClaudeRemoteDaemon

/// A big, scannable QR with the how-to — what a fresh install opens first.
struct PairingWindow: View {
    let model: HostModel

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(spacing: 12) {
                if let qr = model.qrImage {
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 300, height: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                } else {
                    RoundedRectangle(cornerRadius: 10).fill(.quaternary).frame(width: 300, height: 300)
                }
                HStack {
                    Button("Copy link") { model.copyPairingURL() }
                    Button("Save as image…") { model.revealPairingImage() }
                        .help("Writes pairing-qr.png to the support folder and opens it")
                    Button("New token…") { confirmRotate = true }
                        .help("Invalidates existing pairings; every phone must scan again")
                }
                .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.hostName).font(.title2.weight(.semibold))
                    Text(model.headline).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    step(1, "Open **ClaudeRemote** on your iPhone.")
                    step(2, "Tap **Scan QR** and point it at this code.")
                    step(3, "That's it — the phone connects here on Wi‑Fi\(model.status?.pairing.relayURL != nil ? " and through the relay when you're away" : "").")
                }

                if !model.connectedPhones.isEmpty || !model.pairedDevices.isEmpty {
                    Divider()
                    PhonesSection(model: model).padding(.horizontal, -14).padding(.vertical, -10)
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Pairing link").font(.caption).foregroundStyle(.secondary)
                    Text(model.pairingURLString ?? "—")
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(4)
                        .foregroundStyle(.secondary)
                }

                Text("ClaudeRemote Host lives in the menu bar — click the phone icon there for status and settings.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                if let toast = model.toast {
                    Text(toast).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 330, alignment: .leading)
        }
        .padding(24)
        .alert("Generate a new pairing token?", isPresented: $confirmRotate) {
            Button("New token", role: .destructive) { model.rotateToken() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every paired phone is disconnected and must scan the new QR code.")
        }
    }

    @State private var confirmRotate = false

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .font(.caption.weight(.bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
            Text(try! AttributedString(markdown: text))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
