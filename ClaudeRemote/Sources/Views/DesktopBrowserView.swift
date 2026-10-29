import SwiftUI
import ClaudeRemoteCore

/// Over the agent's shoulder: what Claude Desktop's built-in browser has open on the host — each page's
/// address, title and opening text, and a picture of Desktop's window. Refreshes every few seconds while open.
struct DesktopBrowserView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let macId: String

    private var latest: (snapshot: DesktopBrowserSnapshot?, error: String?)? { model.desktopBrowserByMac[macId] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let error = latest?.error {
                        Text(error).font(CDS.caption).foregroundStyle(CDS.danger)
                    }
                    if let snapshot = latest?.snapshot {
                        if snapshot.pages.isEmpty {
                            Text("The built-in browser has no page open.").font(CDS.body).foregroundStyle(CDS.textMuted)
                        }
                        ForEach(snapshot.pages) { page in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(page.title.isEmpty ? page.url : page.title).font(CDS.captionMedium).foregroundStyle(CDS.textPrimary)
                                Text(page.url).font(.caption2.monospaced()).foregroundStyle(CDS.textMuted).lineLimit(2)
                                if !page.text.isEmpty {
                                    Text(page.text).font(CDS.caption).foregroundStyle(CDS.textSecondary).lineLimit(8)
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(CDS.surface1, in: RoundedRectangle(cornerRadius: CDS.radius))
                        }
                        if let image = snapshot.windowJpegBase64.flatMap({ Data(base64Encoded: $0) }).flatMap({ UIImage(data: $0) }) {
                            Image(uiImage: image).resizable().scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: CDS.radius))
                                .overlay(RoundedRectangle(cornerRadius: CDS.radius).strokeBorder(CDS.border))
                        } else {
                            Text("No picture of the window: the Host needs Screen Recording access, and Claude Desktop has to be on screen.")
                                .font(CDS.caption).foregroundStyle(CDS.textMuted)
                        }
                        Text("Updated \(snapshot.takenAt.formatted(date: .omitted, time: .standard))")
                            .font(.caption2).foregroundStyle(CDS.textMuted)
                    } else if latest?.error == nil {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }
                .padding()
            }
            .background(CDS.surface0)
            .navigationTitle("Desktop browser")
            .inlineNavigationTitle()
            .navigationBarBackground(CDS.surface0)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .task {
                while !Task.isCancelled {
                    model.loadDesktopBrowser(mac: macId)
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                }
            }
        }
    }
}
