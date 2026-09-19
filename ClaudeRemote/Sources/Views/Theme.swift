import SwiftUI

/// Claude's design tokens (the `--cds-*` palette Claude Code's desktop UI is built on),
/// as light/dark dynamic colors plus the radii and spacing the transcript uses.
enum CDS {
    // MARK: surfaces (page → cards → panels → popovers)

    static let surface0 = dynamic(light: 0xF9F9F7, dark: 0x0B0B0B)
    static let surface1 = dynamic(light: 0xFCFCFB, dark: 0x151515)
    static let surface2 = dynamic(light: 0xFFFFFF, dark: 0x1A1A19)
    static let surface3 = dynamic(light: 0xFFFFFF, dark: 0x20201F)

    // MARK: text

    static let textPrimary = dynamic(light: 0x0B0B0B, dark: 0xF0EFEC)
    static let textSecondary = dynamic(light: 0x52514E, dark: 0xC3C2B7)
    static let textMuted = dynamic(light: 0x898781, dark: 0x898781)

    /// `neutral-900`: the ink the alpha fills are mixed from (black on light, white on dark).
    static let ink = dynamic(light: 0x0B0B0B, dark: 0xFFFFFF)
    static let alpha1 = ink.opacity(0.05)
    static let alpha2 = ink.opacity(0.10)
    static let alpha3 = ink.opacity(0.20)
    static let alpha4 = ink.opacity(0.35)

    static let border = alpha2
    static let borderStrong = alpha3
    /// `bg-neutral` / `bg-user-message`.
    static let fillNeutral = alpha1
    static let fillControl = alpha2
    static let fillPrimary = ink
    static let onPrimary = dynamic(light: 0xFFFFFF, dark: 0x0B0B0B)

    // MARK: roles

    /// Clay — the Claude brand accent (`fill-brand-hover` / `fill-brand`).
    static let brand = Color(hex: 0xD97757)
    static let brandEmphasized = Color(hex: 0xC6613F)
    static let accent = dynamic(light: 0x184F95, dark: 0x6DA7EC)
    static let success = dynamic(light: 0x006300, dark: 0x55BF50)
    static let successFill = dynamic(light: 0x009300, dark: 0x0CA30C)
    static let warning = dynamic(light: 0x734500, dark: 0xDB9300)
    static let warningFill = Color(hex: 0xFAB219)
    static let warningBackground = dynamic(light: 0xF9DCA4, dark: 0x311A00)
    static let danger = dynamic(light: 0x8E2626, dark: 0xEC7E7E)
    static let dangerFill = dynamic(light: 0xD03B3B, dark: 0xE34948)
    static let dangerBackground = dynamic(light: 0xFAD6D6, dark: 0x3C0E0E)

    static let gitAdded = dynamic(light: 0x1E9E3C, dark: 0x32D74B)
    static let gitRemoved = dynamic(light: 0xCD2054, dark: 0xFF2C56)
    static let gitModified = dynamic(light: 0x98801F, dark: 0xFFD014)

    // MARK: metrics

    /// `radius-lg`: cards, code blocks, tool panels.
    static let radius: CGFloat = 10
    /// `radius-composer`: the composer dock and its cards.
    static let radiusComposer: CGFloat = 14
    /// `radius-xs`: chips and small controls.
    static let radiusSmall: CGFloat = 6
    /// Horizontal page gutter of the transcript.
    static let gutter: CGFloat = 16

    // MARK: fonts

    /// Assistant / user prose.
    static let prose = Font.body
    static let body = Font.subheadline
    static let bodyMedium = Font.subheadline.weight(.medium)
    static let caption = Font.caption
    static let captionMedium = Font.caption.weight(.medium)
    static let code = Font.system(.footnote, design: .monospaced)
    static let codeSmall = Font.system(.caption, design: .monospaced)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension Color {
    init(hex: UInt32) { self.init(uiColor: UIColor(hex: hex)) }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - Shared components

/// Full-width strip for connection / error / hint messages (CDS `Banner`).
struct CDSBanner: View {
    enum Kind { case info, warning, danger }
    let kind: Kind
    let text: String
    var systemImage: String?
    var showsProgress = false
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if showsProgress {
                ProgressView().controlSize(.small).tint(tint)
            } else if let systemImage {
                Image(systemName: systemImage).font(.footnote.weight(.medium)).foregroundStyle(tint)
            }
            Text(text).font(.footnote).foregroundStyle(kind == .info ? CDS.textSecondary : tint).lineLimit(3)
            Spacer(minLength: 0)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(tint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, CDS.gutter).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .overlay(alignment: .bottom) { Divider().overlay(CDS.border) }
    }

    private var tint: Color {
        switch kind {
        case .info: return CDS.textSecondary
        case .warning: return CDS.warning
        case .danger: return CDS.danger
        }
    }

    private var background: Color {
        switch kind {
        case .info: return CDS.surface1
        case .warning: return CDS.warningFill.opacity(0.14)
        case .danger: return CDS.dangerFill.opacity(0.12)
        }
    }
}

/// Small label chip (CDS `Chip`): origin badges, "Needs approval", languages.
struct CDSChip: View {
    enum Style { case neutral, warning, danger, accent }
    let text: String
    var style: Style = .neutral
    var systemImage: String?

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 9, weight: .semibold)) }
            Text(text)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(background, in: RoundedRectangle(cornerRadius: CDS.radiusSmall - 1))
        .foregroundStyle(foreground)
    }

    private var background: Color {
        switch style {
        case .neutral: return CDS.fillNeutral
        case .warning: return CDS.warningBackground
        case .danger: return CDS.dangerBackground
        case .accent: return CDS.brand.opacity(0.15)
        }
    }

    private var foreground: Color {
        switch style {
        case .neutral: return CDS.textSecondary
        case .warning: return CDS.warning
        case .danger: return CDS.danger
        case .accent: return CDS.brandEmphasized
        }
    }
}

/// Pill control in the composer's bottom row ("Opus 5 ⌄", "Auto ⌄").
struct ComposerChipLabel: View {
    let text: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 11, weight: .medium)) }
            Text(text).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(CDS.textMuted)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(CDS.textSecondary)
        .padding(.horizontal, 8).frame(height: 28)
        .background(CDS.fillNeutral, in: Capsule())
        .contentShape(Capsule())
    }
}

/// CDS `Button` variants for the permission card and sheet.
struct CDSButtonStyle: ButtonStyle {
    enum Variant { case primary, secondary, brand, danger }
    var variant: Variant = .secondary
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 36)
            .background(background(pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: CDS.radius - 2))
            .overlay {
                if variant == .secondary {
                    RoundedRectangle(cornerRadius: CDS.radius - 2).strokeBorder(CDS.border)
                }
            }
            .foregroundStyle(foreground)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }

    private func background(pressed: Bool) -> Color {
        switch variant {
        case .primary: return CDS.fillPrimary.opacity(pressed ? 0.85 : 1)
        case .secondary: return pressed ? CDS.fillControl : CDS.fillNeutral
        case .brand: return pressed ? CDS.brand : CDS.brandEmphasized
        case .danger: return CDS.dangerFill.opacity(pressed ? 0.85 : 1)
        }
    }

    private var foreground: Color {
        switch variant {
        case .primary: return CDS.onPrimary
        case .secondary: return CDS.textPrimary
        case .brand, .danger: return .white
        }
    }
}

/// Text that shimmers while the assistant works ("Thinking…", "Running Bash…").
struct ShimmerText: View {
    let text: String
    @State private var phase: CGFloat = -1

    var body: some View {
        Text(text)
            .font(CDS.bodyMedium)
            .foregroundStyle(CDS.textMuted)
            .overlay {
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, CDS.textPrimary.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.6)
                        .offset(x: phase * geo.size.width)
                        .mask(Text(text).font(CDS.bodyMedium))
                }
            }
            .onAppear {
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { phase = 1.2 }
            }
    }
}
