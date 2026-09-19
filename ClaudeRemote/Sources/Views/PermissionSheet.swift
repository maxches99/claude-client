import SwiftUI
import ClaudeRemoteCore

/// Full details of a permission request; the inline dock card is the quick path.
struct PermissionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: PermissionRequest

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Image(systemName: ToolIcon.symbol(for: request.toolName))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(CDS.warning)
                            .frame(width: 32, height: 32)
                            .background(CDS.warningBackground, in: RoundedRectangle(cornerRadius: CDS.radius - 2))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(request.displayName ?? ToolSummary.displayName(request.toolName))
                                .font(.headline).foregroundStyle(CDS.textPrimary)
                            if let title = request.title { Text(title).font(CDS.body).foregroundStyle(CDS.textSecondary) }
                        }
                    }
                    if let description = request.description, !description.isEmpty {
                        Text(description).font(.footnote).foregroundStyle(CDS.textSecondary)
                    }
                    ToolInputDetail(name: request.toolName, input: request.input)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(CDS.surface2, in: RoundedRectangle(cornerRadius: CDS.radius))
                        .overlay(RoundedRectangle(cornerRadius: CDS.radius).strokeBorder(CDS.border))
                    if let reason = request.decisionReason, !reason.isEmpty {
                        Text(reason).font(CDS.caption).foregroundStyle(CDS.textMuted)
                    }
                    if let session = model.summary(for: request.sessionId) {
                        Text("\(session.projectName) · \(session.title)").font(CDS.caption).foregroundStyle(CDS.textMuted).lineLimit(2)
                    }
                }
                .padding()
            }
            .background(CDS.surface0)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 10) {
                    Button("Deny") {
                        model.decide(request, allow: false)
                        dismiss()
                    }
                    .buttonStyle(CDSButtonStyle(variant: .secondary, fullWidth: true))
                    Button("Allow") {
                        model.decide(request, allow: true)
                        dismiss()
                    }
                    .buttonStyle(CDSButtonStyle(variant: .primary, fullWidth: true))
                }
                .padding()
                .background(CDS.surface0)
                .overlay(alignment: .top) { Divider().overlay(CDS.border) }
            }
            .navigationTitle("Permission")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(CDS.surface0, for: .navigationBar)
        }
    }
}
