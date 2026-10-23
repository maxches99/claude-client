import SwiftUI

/// Placeholder rows while a session's history is on its way from the host: the shapes of a prompt card,
/// a folded activity row and a few lines of reply, with a soft shimmer — so opening a long session shows
/// that something is coming instead of an empty page.
struct TranscriptSkeleton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    /// Line widths of each reply, as fractions of the column; varied so it reads as text, not a grid.
    private static let replies: [[CGFloat]] = [
        [0.94, 0.88, 0.97, 0.52],
        [0.9, 0.76],
        [0.96, 0.92, 0.84, 0.9, 0.38],
    ]
    private static let prompts: [CGFloat] = [0.62, 0.4, 0.74]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(0..<Self.replies.count, id: \.self) { i in
                promptCard(width: Self.prompts[i])
                if i != 1 { activityRow }
                reply(Self.replies[i])
            }
        }
        .padding(.horizontal, CDS.gutter).padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .mask(shimmer)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading the conversation")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1 }
        }
    }

    /// The user's prompt: the same neutral card, holding one or two bars.
    private func promptCard(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            bar(width: width, height: 11)
            if width > 0.6 { bar(width: width * 0.55, height: 11) }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CDS.fillNeutral, in: RoundedRectangle(cornerRadius: CDS.radius + 2))
    }

    /// "Ran 3 commands ›": an icon dot and a short label.
    private var activityRow: some View {
        HStack(spacing: 8) {
            Circle().fill(CDS.fillControl).frame(width: 14, height: 14)
            bar(width: 0.32, height: 10)
        }
        .padding(.horizontal, 4)
    }

    private func reply(_ widths: [CGFloat]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(widths.enumerated()), id: \.offset) { _, width in
                bar(width: width, height: 10)
            }
        }
        .padding(.horizontal, 4)
    }

    /// A rounded bar `width` of the available column wide.
    private func bar(width: CGFloat, height: CGFloat) -> some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: height / 2)
                .fill(CDS.fillControl)
                .frame(width: geo.size.width * width)
        }
        .frame(height: height)
    }

    /// Mostly opaque with a lighter band sweeping across — the shimmer.
    private var shimmer: some View {
        GeometryReader { geo in
            LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black.opacity(0.45), location: 0.5),
                .init(color: .black, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
            .frame(width: geo.size.width * 3)
            .offset(x: geo.size.width * (phase - 1))
        }
    }
}
