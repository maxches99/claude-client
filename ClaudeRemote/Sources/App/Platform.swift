import SwiftUI
#if os(iOS)
import UIKit
import AVFoundation
#else
import AppKit
#endif

/// The audio-session dance iOS needs before speaking, dictating or recording. macOS has no audio
/// session — the same calls are no-ops there.
enum AudioSession {
    enum Use { case playback, record, playAndRecord }

    static func activate(_ use: Use) throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        switch use {
        case .playback: try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        case .record: try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        case .playAndRecord: try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers])
        }
        try session.setActive(true, options: [])
        #endif
    }

    static func deactivate() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }
}

#if os(macOS)
// The native Mac client compiles the iOS app's model and feature views as they are. These stand-ins
// give AppKit the handful of UIKit spellings that code uses (images, the pasteboard, fonts, colors).

typealias UIImage = NSImage
typealias UIFont = NSFont
typealias UIColor = NSColor

extension NSImage {
    convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    var cgImage: CGImage? { cgImage(forProposedRect: nil, context: nil, hints: nil) }

    func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }

    func pngData() -> Data? {
        guard let cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    /// A copy scaled to `target` points (one pixel per point).
    func resized(to target: CGSize) -> NSImage {
        let image = NSImage(size: target)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(in: CGRect(origin: .zero, size: target), from: .zero, operation: .copy, fraction: 1)
        image.unlockFocus()
        return image
    }

    func byPreparingThumbnail(ofSize target: CGSize) async -> NSImage? { resized(to: target) }

    /// AppKit decodes lazily at draw time and has no pre-decode step; the image is used as is.
    func preparingForDisplay() -> NSImage? { self }
}

/// `UIPasteboard.general.string = …` / `.image = …` on the Mac's general pasteboard.
final class UIPasteboard {
    static let general = UIPasteboard()

    var string: String? {
        get { NSPasteboard.general.string(forType: .string) }
        set {
            NSPasteboard.general.clearContents()
            if let newValue { NSPasteboard.general.setString(newValue, forType: .string) }
        }
    }

    var image: NSImage? {
        get { NSImage(pasteboard: NSPasteboard.general) }
        set {
            NSPasteboard.general.clearContents()
            if let newValue { NSPasteboard.general.writeObjects([newValue]) }
        }
    }

    var hasStrings: Bool { string != nil }
}

extension Image {
    init(uiImage: NSImage) { self.init(nsImage: uiImage) }
}

extension Color {
    init(uiColor: NSColor) { self.init(nsColor: uiColor) }
}
#endif

// MARK: - iOS-only SwiftUI modifiers, spelled once for both platforms

/// The width of the window a view is in, set by the Mac client's root (infinite where nobody sets it):
/// lets a screen drop optional side panels before the window gets too narrow for them.
private struct WindowWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = .infinity
}

extension EnvironmentValues {
    var windowWidth: CGFloat {
        get { self[WindowWidthKey.self] }
        set { self[WindowWidthKey.self] = newValue }
    }
}

/// The keyboard a text field asks for on iOS (the Mac has only one).
enum KeyboardKind {
    case url, email, number, decimal
}

extension View {
    /// A compact title in the navigation bar (iOS); the Mac shows titles in the window toolbar anyway.
    @ViewBuilder func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// The navigation bar's background (iOS) / the window toolbar's (Mac).
    @ViewBuilder func navigationBarBackground<S: ShapeStyle>(_ style: S) -> some View {
        #if os(iOS)
        toolbarBackground(style, for: .navigationBar)
        #else
        // Solid, so the transcript doesn't scroll visibly under the window title.
        toolbarBackground(style, for: .windowToolbar).toolbarBackground(.visible, for: .windowToolbar)
        #endif
    }

    @ViewBuilder func navigationBarBackgroundVisible() -> some View {
        #if os(iOS)
        toolbarBackground(.visible, for: .navigationBar)
        #else
        self
        #endif
    }

    @ViewBuilder func keyboardKind(_ kind: KeyboardKind) -> some View {
        #if os(iOS)
        switch kind {
        case .url: keyboardType(.URL)
        case .email: keyboardType(.emailAddress)
        case .number: keyboardType(.numberPad)
        case .decimal: keyboardType(.decimalPad)
        }
        #else
        self
        #endif
    }

    /// Addresses, tokens, paths, commands: no capital first letter.
    @ViewBuilder func noAutocapitalization() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    @ViewBuilder func autocapitalizeCharacters() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.characters)
        #else
        self
        #endif
    }

    /// iOS's inset-grouped list; the Mac's inset list reads the same way in a sheet or a pane.
    @ViewBuilder func groupedListStyle() -> some View {
        #if os(iOS)
        listStyle(.insetGrouped)
        #else
        listStyle(.inset)
        #endif
    }

    /// A picker over a long list: its own pushed screen on iOS, a pop-up menu on the Mac.
    @ViewBuilder func longListPickerStyle() -> some View {
        #if os(iOS)
        pickerStyle(.navigationLink)
        #else
        pickerStyle(.menu)
        #endif
    }

    @ViewBuilder func hidesStatusBar(_ hidden: Bool) -> some View {
        #if os(iOS)
        statusBarHidden(hidden)
        #else
        self
        #endif
    }

    /// A menu drawn only by its label: AppKit would otherwise wrap it in a pop-up button with its own chevron.
    @ViewBuilder func plainMenu() -> some View {
        #if os(macOS)
        menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        #else
        self
        #endif
    }

    /// The Mac keeps the transcript and the composer in one centred column of reading width, like the
    /// desktop app; the phone uses the whole screen.
    @ViewBuilder func readingColumn() -> some View {
        #if os(macOS)
        frame(minWidth: 0, maxWidth: 860).frame(minWidth: 0, maxWidth: .infinity)
        #else
        self
        #endif
    }

    /// A full-screen cover on iOS, a (large) sheet on the Mac.
    @ViewBuilder func coverFullScreen<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented, content: content)
        #else
        sheet(isPresented: isPresented) { content().frame(minWidth: 640, minHeight: 520) }
        #endif
    }

    @ViewBuilder func coverFullScreen<Item: Identifiable, Content: View>(item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        #if os(iOS)
        fullScreenCover(item: item, content: content)
        #else
        sheet(item: item) { content($0).frame(minWidth: 640, minHeight: 520) }
        #endif
    }
}

extension ToolbarItemPlacement {
    /// The trailing end of the navigation bar on iOS; the window toolbar's action area on the Mac.
    static var trailingBar: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }

    static var leadingBar: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }
}
