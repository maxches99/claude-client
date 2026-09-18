import SwiftUI
import ClaudeRemoteCore

struct PermissionSheet: View {
    @Environment(AppModel.self) private var model
    let request: PermissionRequest

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Image(systemName: ToolIcon.symbol(for: request.toolName)).font(.title2)
                        VStack(alignment: .leading) {
                            Text(request.displayName ?? ToolSummary.displayName(request.toolName)).font(.headline)
                            if let title = request.title { Text(title).font(.subheadline).foregroundStyle(.secondary) }
                        }
                    }
                    if let description = request.description, !description.isEmpty {
                        Text(description).font(.footnote).foregroundStyle(.secondary)
                    }
                    ToolInputDetail(name: request.toolName, input: request.input)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                    if let reason = request.decisionReason, !reason.isEmpty {
                        Text(reason).font(.caption).foregroundStyle(.tertiary)
                    }
                    if let session = model.summary(for: request.sessionId) {
                        Text("\(session.projectName) · \(session.title)").font(.caption).foregroundStyle(.tertiary).lineLimit(2)
                    }
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button(role: .destructive) {
                        model.decide(request, allow: false)
                    } label: {
                        Text("Deny").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                    Button {
                        model.decide(request, allow: true)
                    } label: {
                        Text("Allow").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                }
                .padding()
                .background(.bar)
            }
            .navigationTitle("Permission")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
