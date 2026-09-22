import SwiftUI
import UIKit
import ClaudeRemoteCore

/// Terminals running on the Mac, and a way to start one in this project.
struct TerminalsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The session whose project a new shell starts in (nil = the Mac's home folder).
    var sessionId: String?

    @State private var opened: TerminalModel?
    @State private var confirmClose: TerminalInfo?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        opened = TerminalModel(id: "", cols: 0, rows: 0)   // placeholder: the screen opens the shell once it knows its size
                    } label: {
                        Label(sessionId == nil ? "New terminal in the home folder" : "New terminal in this project", systemImage: "plus.rectangle.on.rectangle")
                    }
                    .disabled(!model.isConnected)
                    .listRowBackground(CDS.surface0)
                } footer: {
                    Text("A login shell on the Mac in a real terminal — ^C, full-screen programs and all. It keeps running when you leave; come back to it here.")
                        .font(CDS.caption).foregroundStyle(CDS.textMuted)
                }
                if !model.terminals.isEmpty {
                    Section("Running on the Mac") {
                        ForEach(model.terminals) { info in
                            Button {
                                opened = model.attachTerminal(info)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(info.displayName).font(CDS.code).foregroundStyle(CDS.textPrimary).lineLimit(1)
                                    Text("\(info.projectName) · \(info.cols)×\(info.rows) · started \(RelativeTime.string(info.startedAt))")
                                        .font(CDS.caption).foregroundStyle(CDS.textMuted)
                                }
                            }
                            .listRowBackground(CDS.surface0)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { confirmClose = info } label: { Label("Close", systemImage: "xmark") }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(CDS.surface0)
            .navigationTitle("Terminals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(CDS.surface0, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.requestTerminals() } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .navigationDestination(item: $opened) { terminal in
                TerminalScreenView(existing: terminal.id.isEmpty ? nil : terminal, sessionId: sessionId)
            }
            .confirmationDialog("Close this terminal?", isPresented: Binding(get: { confirmClose != nil }, set: { if !$0 { confirmClose = nil } }), titleVisibility: .visible) {
                Button("Close", role: .destructive) {
                    if let info = confirmClose { model.closeTerminal(info.id) }
                    confirmClose = nil
                }
            } message: {
                Text("The shell and whatever runs in it are hung up.")
            }
        }
        .onAppear { model.requestTerminals() }
    }
}

extension TerminalModel: Hashable {
    nonisolated static func == (a: TerminalModel, b: TerminalModel) -> Bool { a === b }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// One terminal: the screen, the keyboard, and a bar of the keys a phone keyboard lacks.
struct TerminalScreenView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    /// An attached shell, or nil to open a new one once the view knows how big it is.
    let existing: TerminalModel?
    let sessionId: String?

    @State private var terminal: TerminalModel?
    @State private var keyboardUp = false
    @State private var control = false
    @State private var fontSize: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 13 : 11.5
    @State private var opening = false

    private var font: UIFont { .monospacedSystemFont(ofSize: fontSize, weight: .regular) }
    private var cell: CGSize {
        let width = ("M" as NSString).size(withAttributes: [.font: font]).width
        return CGSize(width: max(1, width), height: ceil(font.lineHeight))
    }

    var body: some View {
        GeometryReader { geo in
            let size = gridSize(for: geo.size)
            ZStack(alignment: .topLeading) {
                if let terminal {
                    TerminalGrid(terminal: terminal, font: font, cell: cell, palette: TerminalPalette(scheme: scheme))
                } else {
                    ProgressView().tint(CDS.textMuted).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                TerminalKeyInput(isFirstResponder: $keyboardUp, control: $control, send: { bytes in send(bytes) }, key: { k in key(k) })
                    .frame(width: 1, height: 1).opacity(0.01)
            }
            .contentShape(Rectangle())
            .onTapGesture { keyboardUp = true }
            .onAppear { start(cols: size.cols, rows: size.rows) }
            .onChange(of: size.cols) { _, _ in resize(size) }
            .onChange(of: size.rows) { _, _ in resize(size) }
        }
        .padding(.horizontal, 6)
        .background(TerminalPalette(scheme: scheme).background)
        .safeAreaInset(edge: .bottom) { keyBar }
        .navigationTitle(terminal?.screen.title ?? "Terminal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(CDS.surface0, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Paste", systemImage: "doc.on.clipboard") { paste() }
                    Button("Copy screen and history", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = terminal?.screen.fullText
                    }
                    Section("Text size") {
                        Button("Larger", systemImage: "textformat.size.larger") { fontSize = min(18, fontSize + 1) }
                        Button("Smaller", systemImage: "textformat.size.smaller") { fontSize = max(8, fontSize - 1) }
                    }
                    if let terminal {
                        Button("Close terminal", systemImage: "xmark", role: .destructive) { model.closeTerminal(terminal.id) }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .overlay(alignment: .bottom) {
            if terminal?.exited == true {
                Text("The shell exited\(terminal?.exitCode.map { " (\($0))" } ?? "").")
                    .font(CDS.caption).foregroundStyle(CDS.textSecondary)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(CDS.surface2, in: Capsule())
                    .padding(.bottom, 56)
            }
        }
        .onDisappear { if let terminal { model.detachTerminal(terminal.id) } }
    }

    private func gridSize(for size: CGSize) -> (cols: Int, rows: Int) {
        (max(20, Int(size.width / cell.width)), max(5, Int(size.height / cell.height)))
    }

    private func start(cols: Int, rows: Int) {
        guard terminal == nil, !opening else { return }
        if let existing {
            terminal = existing
            model.resizeTerminal(existing.id, cols: cols, rows: rows)
            keyboardUp = true
            return
        }
        opening = true
        model.openTerminal(sessionId, cols: cols, rows: rows) { opened in
            opening = false
            terminal = opened
            keyboardUp = opened != nil
        }
    }

    private func resize(_ size: (cols: Int, rows: Int)) {
        guard let terminal else { return }
        model.resizeTerminal(terminal.id, cols: size.cols, rows: size.rows)
    }

    private func send(_ bytes: [UInt8]) {
        guard let terminal, !terminal.exited else { return }
        model.sendTerminal(terminal.id, bytes: bytes)
    }

    private func key(_ key: TerminalKey) {
        send(key.bytes(applicationCursor: terminal?.screen.applicationCursorKeys ?? false))
    }

    private func paste() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        var bytes = Array(text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r").utf8)
        if terminal?.screen.bracketedPaste == true { bytes = Array("\u{1B}[200~".utf8) + bytes + Array("\u{1B}[201~".utf8) }
        send(bytes)
    }

    private var keyBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                barKey("esc") { key(.escape) }
                barKey("tab") { key(.tab) }
                Button { control.toggle() } label: {
                    Text("ctrl").font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(control ? CDS.onPrimary : CDS.textPrimary)
                        .frame(minWidth: 40, minHeight: 32)
                        .background(control ? CDS.fillPrimary : CDS.fillControl, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                barKey("^C") { key(.control("c")) }
                barIcon("arrow.left") { key(.left) }
                barIcon("arrow.down") { key(.down) }
                barIcon("arrow.up") { key(.up) }
                barIcon("arrow.right") { key(.right) }
                barKey("|") { send(Array("|".utf8)) }
                barKey("~") { send(Array("~".utf8)) }
                barKey("/") { send(Array("/".utf8)) }
                barKey("-") { send(Array("-".utf8)) }
                barIcon(keyboardUp ? "keyboard.chevron.compact.down" : "keyboard") { keyboardUp.toggle() }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
        .background(CDS.surface0)
        .overlay(alignment: .top) { Divider().overlay(CDS.border) }
    }

    private func barKey(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(CDS.textPrimary)
                .frame(minWidth: 36, minHeight: 32)
                .background(CDS.fillControl, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private func barIcon(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(CDS.textPrimary)
                .frame(minWidth: 36, minHeight: 32)
                .background(CDS.fillControl, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}

/// Colours for the screen: CDS surfaces for the defaults, an xterm-like 16-colour set tuned for each
/// appearance, the 6×6×6 cube and greys for 256-colour output, and true colour as is.
struct TerminalPalette {
    let scheme: ColorScheme

    var background: Color { CDS.surface0 }
    var foreground: Color { CDS.textPrimary }

    private var base: [UInt32] {
        scheme == .dark
            ? [0x2B2B29, 0xE06C6C, 0x8FBF6A, 0xD9B45B, 0x6FA3E0, 0xC38ED9, 0x5FBFB8, 0xD8D7D2,
               0x6A6964, 0xF28B8B, 0xA8D98A, 0xEDD08A, 0x94BDF0, 0xD9ADE8, 0x86D9D2, 0xFFFFFF]
            : [0x1F1E1D, 0xB53333, 0x3D7A2E, 0x8A6A12, 0x2E5FA8, 0x8A3FA3, 0x207A73, 0x73726C,
               0x5E5D59, 0xD64545, 0x4F9A3B, 0xA88418, 0x3A76CC, 0xA552C4, 0x2A948C, 0x3D3D3A]
    }

    func color(_ c: TerminalColor, isForeground: Bool) -> Color? {
        switch c {
        case .default: return isForeground ? foreground : nil
        case .rgb(let r, let g, let b): return Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
        case .indexed(let i):
            let v: UInt32
            if i < 16 {
                v = base[Int(i)]
            } else if i < 232 {
                let n = Int(i) - 16, steps: [UInt32] = [0, 95, 135, 175, 215, 255]
                v = (steps[n / 36] << 16) | (steps[(n / 6) % 6] << 8) | steps[n % 6]
            } else {
                let g = UInt32(8 + (Int(i) - 232) * 10)
                v = (g << 16) | (g << 8) | g
            }
            return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
        }
    }
}

/// The scrollback and the screen, one `Text` per line, following the bottom as output arrives.
private struct TerminalGrid: View {
    let terminal: TerminalModel
    let font: UIFont
    let cell: CGSize
    let palette: TerminalPalette

    var body: some View {
        let screen = terminal.screen
        let history = screen.usingAlternateScreen ? [] : screen.scrollback
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(history.enumerated()), id: \.offset) { i, line in
                        row(line, cursorX: nil).id("h\(i)")
                    }
                    ForEach(0..<screen.rows, id: \.self) { y in
                        let line = y < screen.lines.count ? screen.lines[y] : []
                        row(line, cursorX: screen.cursorVisible && y == screen.cursorY ? screen.cursorX : nil).id("s\(y)")
                    }
                    Color.clear.frame(height: 1).id("end")
                }
            }
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(.bottom)
            .onChange(of: terminal.screen.cursorY) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: history.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    private func row(_ line: [TerminalCell], cursorX: Int?) -> some View {
        Text(attributed(line, cursorX: cursorX))
            .font(Font(font))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(height: cell.height, alignment: .leading)
    }

    private func attributed(_ line: [TerminalCell], cursorX: Int?) -> AttributedString {
        var out = AttributedString()
        var run = ""
        var runAttrs: TerminalAttributes?
        var runCursor = false
        func flush() {
            guard !run.isEmpty, let a = runAttrs else { return }
            var piece = AttributedString(run)
            var fg = palette.color(a.fg, isForeground: true)
            var bg = palette.color(a.bg, isForeground: false)
            if a.inverse != runCursor {
                let f = fg ?? palette.foreground
                fg = bg ?? palette.background
                bg = f
            }
            if let fg { piece.foregroundColor = a.dim ? fg.opacity(0.6) : fg }
            if let bg { piece.backgroundColor = bg }
            if a.bold { piece.font = Font(UIFont.monospacedSystemFont(ofSize: font.pointSize, weight: .bold)) }
            if a.italic { piece.font = Font(UIFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)).italic() }
            if a.underline { piece.underlineStyle = .single }
            out += piece
            run = ""
        }
        for (x, cell) in line.enumerated() where !cell.continuation {
            let isCursor = x == cursorX
            if cell.attributes != runAttrs || isCursor != runCursor { flush(); runAttrs = cell.attributes; runCursor = isCursor }
            run += cell.text.isEmpty ? " " : cell.text
        }
        flush()
        if let cursorX, cursorX >= line.count {
            var caret = AttributedString(" ")
            caret.backgroundColor = palette.foreground
            out += caret
        }
        return out
    }
}

/// An invisible view that owns the keyboard for the terminal: typed text, delete, Return, and
/// hardware-keyboard arrows / Esc / Tab / ^letters, all turned into the bytes a terminal expects.
private struct TerminalKeyInput: UIViewRepresentable {
    @Binding var isFirstResponder: Bool
    @Binding var control: Bool
    let send: ([UInt8]) -> Void
    /// Keys whose bytes depend on the screen's modes (arrows in application-cursor mode).
    let key: (TerminalKey) -> Void

    func makeUIView(context: Context) -> KeyView {
        let view = KeyView()
        view.onBytes = { bytes in send(bytes) }
        view.onKey = { k in key(k) }
        return view
    }

    func updateUIView(_ view: KeyView, context: Context) {
        view.onBytes = { bytes in send(bytes) }
        view.onKey = { k in key(k) }
        view.control = control
        view.onControlUsed = { DispatchQueue.main.async { control = false } }
        DispatchQueue.main.async {
            if isFirstResponder, !view.isFirstResponder { view.becomeFirstResponder() }
            if !isFirstResponder, view.isFirstResponder { view.resignFirstResponder() }
        }
    }

    final class KeyView: UIView, UIKeyInput {
        var onBytes: (([UInt8]) -> Void)?
        var onKey: ((TerminalKey) -> Void)?
        var onControlUsed: (() -> Void)?
        var control = false

        override var canBecomeFirstResponder: Bool { true }
        var hasText: Bool { true }
        var autocorrectionType: UITextAutocorrectionType = .no
        var autocapitalizationType: UITextAutocapitalizationType = .none
        var spellCheckingType: UITextSpellCheckingType = .no
        var smartQuotesType: UITextSmartQuotesType = .no
        var smartDashesType: UITextSmartDashesType = .no
        var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
        var keyboardAppearance: UIKeyboardAppearance = .default

        func insertText(_ text: String) {
            if control, let first = text.first {
                control = false
                onControlUsed?()
                onBytes?(TerminalKey.control(first).bytes(applicationCursor: false))
                return
            }
            onBytes?(Array(text.replacingOccurrences(of: "\n", with: "\r").utf8))
        }

        func deleteBackward() { onBytes?([0x7F]) }

        override var keyCommands: [UIKeyCommand]? {
            var commands = [
                UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(arrow(_:))),
                UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(arrow(_:))),
                UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(arrow(_:))),
                UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(arrow(_:))),
                UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escape)),
                UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(tab)),
            ]
            for letter in "abcdefghijklmnopqrstuvwxyz[]\\" {
                commands.append(UIKeyCommand(input: String(letter), modifierFlags: .control, action: #selector(controlKey(_:))))
            }
            commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
            return commands
        }

        @objc private func arrow(_ command: UIKeyCommand) {
            let key: TerminalKey
            switch command.input {
            case UIKeyCommand.inputUpArrow: key = .up
            case UIKeyCommand.inputDownArrow: key = .down
            case UIKeyCommand.inputLeftArrow: key = .left
            default: key = .right
            }
            onKey?(key)
        }

        @objc private func escape() { onBytes?([0x1B]) }
        @objc private func tab() { onBytes?([0x09]) }
        @objc private func controlKey(_ command: UIKeyCommand) {
            guard let c = command.input?.first else { return }
            onBytes?(TerminalKey.control(c).bytes(applicationCursor: false))
        }
    }
}
