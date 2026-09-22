import Foundation

/// A cell colour as xterm names them: the terminal's default, one of the 256 indexed colours, or
/// true colour.
public enum TerminalColor: Equatable, Hashable, Sendable {
    case `default`
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

public struct TerminalAttributes: Equatable, Hashable, Sendable {
    public var fg: TerminalColor = .default
    public var bg: TerminalColor = .default
    public var bold = false
    public var dim = false
    public var italic = false
    public var underline = false
    public var inverse = false

    public init() {}
    public static let plain = TerminalAttributes()
}

/// One character position. `text` is usually one character; combining marks attach to it, and the
/// right half of a wide character is an empty `text` with `continuation` set.
public struct TerminalCell: Equatable, Sendable {
    public var text: String
    public var attributes: TerminalAttributes
    public var continuation: Bool

    public init(text: String = " ", attributes: TerminalAttributes = .plain, continuation: Bool = false) {
        self.text = text
        self.attributes = attributes
        self.continuation = continuation
    }

    public static let blank = TerminalCell()
}

/// Keys the phone's key bar and keyboard send, encoded the way xterm does.
public enum TerminalKey: Equatable, Sendable {
    case up, down, left, right, home, end, pageUp, pageDown
    case escape, tab, backTab, backspace, enter, delete
    /// Control + a letter or one of `@[\]^_ `.
    case control(Character)

    public func bytes(applicationCursor: Bool) -> [UInt8] {
        func csi(_ s: String) -> [UInt8] { Array("\u{1B}[\(s)".utf8) }
        func ss3(_ s: String) -> [UInt8] { Array("\u{1B}O\(s)".utf8) }
        switch self {
        case .up: return applicationCursor ? ss3("A") : csi("A")
        case .down: return applicationCursor ? ss3("B") : csi("B")
        case .right: return applicationCursor ? ss3("C") : csi("C")
        case .left: return applicationCursor ? ss3("D") : csi("D")
        case .home: return applicationCursor ? ss3("H") : csi("H")
        case .end: return applicationCursor ? ss3("F") : csi("F")
        case .pageUp: return csi("5~")
        case .pageDown: return csi("6~")
        case .escape: return [0x1B]
        case .tab: return [0x09]
        case .backTab: return csi("Z")
        case .backspace: return [0x7F]
        case .enter: return [0x0D]
        case .delete: return csi("3~")
        case .control(let c):
            guard let ascii = c.uppercased().unicodeScalars.first?.value, ascii < 0x80 else { return [] }
            if ascii == 0x20 { return [0x00] }                 // ^Space = NUL
            if ascii == 0x3F { return [0x7F] }                 // ^? = DEL
            return [UInt8(ascii & 0x1F)]
        }
    }
}

/// A VT100 / xterm screen, fed the bytes a shell writes to its pseudo-terminal. It covers what shells,
/// prompts, `less`, `top`, `git` and most full-screen tools use: cursor movement, erasing, insert and
/// delete, scroll regions, SGR colours (16 / 256 / true colour), the alternate screen, UTF-8 with
/// wide characters, and the status queries (cursor position, device attributes) programs send —
/// their answers come back from `feed` for the caller to write to the terminal.
public struct TerminalScreen: Sendable {
    public private(set) var cols: Int
    public private(set) var rows: Int
    public private(set) var cursorX = 0
    public private(set) var cursorY = 0
    public private(set) var cursorVisible = true
    public private(set) var applicationCursorKeys = false
    public private(set) var bracketedPaste = false
    public private(set) var usingAlternateScreen = false
    public private(set) var title: String?
    /// Lines that scrolled off the top of the main screen, oldest first.
    public private(set) var scrollback: [[TerminalCell]] = []
    public static let scrollbackLimit = 2000

    private var main: [[TerminalCell]]
    private var alternate: [[TerminalCell]]
    private var attributes = TerminalAttributes.plain
    private var scrollTop = 0
    private var scrollBottom: Int
    private var autowrap = true
    private var wrapPending = false
    private var saved = SavedCursor()
    private var savedMain = SavedCursor()

    private struct SavedCursor: Sendable {
        var x = 0, y = 0
        var attributes = TerminalAttributes.plain
    }

    // Parser
    private enum State: Sendable { case ground, escape, csi, osc, oscEscape, charset }
    private var state = State.ground
    private var csiParams = ""
    private var csiPrivate: Character?
    private var csiIntermediate = ""
    private var oscBuffer: [UInt8] = []
    private var utf8Pending: [UInt8] = []
    private var utf8Needed = 0

    public init(cols: Int = 80, rows: Int = 24) {
        self.cols = max(2, cols)
        self.rows = max(2, rows)
        main = TerminalScreen.blankGrid(cols: self.cols, rows: self.rows)
        alternate = main
        scrollBottom = self.rows - 1
    }

    private static func blankGrid(cols: Int, rows: Int) -> [[TerminalCell]] {
        Array(repeating: Array(repeating: .blank, count: cols), count: rows)
    }

    // MARK: reading

    /// The screen as it is shown now (the alternate one while a full-screen program runs).
    public var lines: [[TerminalCell]] { usingAlternateScreen ? alternate : main }

    /// A visible row as plain text, trailing blanks trimmed — for tests and copying.
    public func text(row: Int) -> String {
        guard row >= 0, row < rows else { return "" }
        return TerminalScreen.plainText(lines[row])
    }

    public static func plainText(_ line: [TerminalCell]) -> String {
        var s = line.filter { !$0.continuation }.map(\.text).joined()
        while s.hasSuffix(" ") { s.removeLast() }
        return s
    }

    /// Scrollback plus the screen, as text — "Copy all".
    public var fullText: String {
        (scrollback + main).map(TerminalScreen.plainText).joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
    }

    // MARK: size

    public mutating func resize(cols newCols: Int, rows newRows: Int) {
        let newCols = max(2, newCols), newRows = max(2, newRows)
        guard newCols != cols || newRows != rows else { return }
        func fit(_ grid: [[TerminalCell]], keepScrollback: Bool) -> [[TerminalCell]] {
            var g = grid.map { line -> [TerminalCell] in
                if line.count > newCols { return Array(line.prefix(newCols)) }
                return line + Array(repeating: .blank, count: newCols - line.count)
            }
            if newRows < g.count {
                // Keep the cursor's line on screen: what falls off the top goes to the scrollback.
                let drop = max(0, min(g.count - newRows, cursorY + 1 - newRows))
                if drop > 0 {
                    if keepScrollback { appendScrollback(Array(g.prefix(drop))) }
                    g.removeFirst(drop)
                }
                if g.count > newRows { g.removeLast(g.count - newRows) }
            } else if newRows > g.count {
                g += Array(repeating: Array(repeating: .blank, count: newCols), count: newRows - g.count)
            }
            return g
        }
        let drop = max(0, cursorY + 1 - newRows)
        main = fit(main, keepScrollback: !usingAlternateScreen)
        alternate = fit(alternate, keepScrollback: false)
        cols = newCols
        rows = newRows
        cursorY = max(0, min(rows - 1, cursorY - drop))
        cursorX = min(cursorX, cols - 1)
        scrollTop = 0
        scrollBottom = rows - 1
        wrapPending = false
    }

    // MARK: input

    /// Applies output from the terminal. Returns bytes the terminal must answer with (replies to
    /// status queries), usually none.
    @discardableResult
    public mutating func feed(_ data: [UInt8]) -> [UInt8] {
        var replies: [UInt8] = []
        for byte in data { step(byte, replies: &replies) }
        return replies
    }

    @discardableResult
    public mutating func feed(_ text: String) -> [UInt8] { feed(Array(text.utf8)) }

    private mutating func step(_ b: UInt8, replies: inout [UInt8]) {
        switch state {
        case .ground:
            ground(b)
        case .escape:
            escape(b)
        case .csi:
            if b >= 0x30 && b <= 0x3F {
                let c = Character(UnicodeScalar(b))
                if csiParams.isEmpty && csiPrivate == nil && "<=>?".contains(c) { csiPrivate = c } else { csiParams.append(c) }
            } else if b >= 0x20 && b <= 0x2F {
                csiIntermediate.append(Character(UnicodeScalar(b)))
            } else if b >= 0x40 && b <= 0x7E {
                state = .ground
                dispatchCSI(Character(UnicodeScalar(b)), replies: &replies)
            } else if b == 0x1B {
                state = .escape
            } else if b < 0x20 {
                ground(b)          // C0 controls still act inside a sequence
            } else {
                state = .ground    // malformed
            }
        case .osc:
            if b == 0x07 { finishOSC(); state = .ground }
            else if b == 0x1B { state = .oscEscape }
            else if oscBuffer.count < 4096 { oscBuffer.append(b) }
        case .oscEscape:
            finishOSC()
            state = .ground
            if b != 0x5C { escape(b) }   // ESC \ is the terminator; anything else starts a new escape
        case .charset:
            state = .ground           // the designated character set itself: UTF-8 is all we do
        }
    }

    private mutating func ground(_ b: UInt8) {
        if utf8Needed > 0 {
            if b & 0xC0 == 0x80 {
                utf8Pending.append(b)
                utf8Needed -= 1
                if utf8Needed == 0 {
                    let text = String(decoding: utf8Pending, as: UTF8.self)
                    utf8Pending = []
                    put(text)
                }
                return
            }
            utf8Pending = []
            utf8Needed = 0
            put("\u{FFFD}")
        }
        switch b {
        case 0x1B: state = .escape
        case 0x07: break
        case 0x08:
            if cursorX > 0 { cursorX -= 1 }
            wrapPending = false
        case 0x09:
            cursorX = min(cols - 1, (cursorX / 8 + 1) * 8)
            wrapPending = false
        case 0x0A, 0x0B, 0x0C: lineFeed()
        case 0x0D:
            cursorX = 0
            wrapPending = false
        case 0x00..<0x20, 0x7F: break
        case 0x20..<0x7F: put(String(UnicodeScalar(b)))
        case 0xC0..<0xE0: utf8Pending = [b]; utf8Needed = 1
        case 0xE0..<0xF0: utf8Pending = [b]; utf8Needed = 2
        case 0xF0..<0xF8: utf8Pending = [b]; utf8Needed = 3
        default: put("\u{FFFD}")
        }
    }

    private mutating func escape(_ b: UInt8) {
        state = .ground
        switch b {
        case 0x5B: // [
            state = .csi
            csiParams = ""
            csiPrivate = nil
            csiIntermediate = ""
        case 0x5D: // ]
            state = .osc
            oscBuffer = []
        case 0x28, 0x29, 0x2A, 0x2B: state = .charset   // ( ) * +
        case 0x37: saveCursor()                          // 7
        case 0x38: restoreCursor()                       // 8
        case 0x44: lineFeed()                            // D  index
        case 0x45: cursorX = 0; lineFeed()               // E  next line
        case 0x4D: reverseIndex()                        // M
        case 0x63: reset()                               // c
        default: break                                   // = > \ and the rest
        }
    }

    private mutating func finishOSC() {
        let text = String(decoding: oscBuffer, as: UTF8.self)
        oscBuffer = []
        if text.hasPrefix("0;") || text.hasPrefix("2;") { title = String(text.dropFirst(2)) }
    }

    // MARK: printing

    private mutating func put(_ text: String) {
        guard let scalar = text.unicodeScalars.first else { return }
        if TerminalScreen.isCombining(scalar) {
            // Joins the character before it.
            var x = wrapPending ? cursorX : cursorX - 1
            let y = cursorY
            guard x >= 0 else { return }
            if lines[y][x].continuation, x > 0 { x -= 1 }
            let column = x
            withGrid { $0[y][column].text += text }
            return
        }
        let width = TerminalScreen.isWide(scalar) ? 2 : 1
        if wrapPending {
            if autowrap { cursorX = 0; lineFeed() }
            wrapPending = false
        }
        if width == 2 && cursorX == cols - 1 {
            guard autowrap else { return }
            let y = cursorY, x = cursorX, filler = TerminalCell(text: " ", attributes: attributes)
            withGrid { $0[y][x] = filler }
            cursorX = 0
            lineFeed()
        }
        let attrs = attributes
        let y = cursorY, x = cursorX
        withGrid { grid in
            // Overwriting half of a wide character blanks the other half.
            if grid[y][x].continuation, x > 0 { grid[y][x - 1] = TerminalCell(text: " ", attributes: grid[y][x - 1].attributes) }
            if x + 1 < grid[y].count, grid[y][x + 1].continuation, width == 1 { grid[y][x + 1] = TerminalCell(text: " ", attributes: grid[y][x + 1].attributes) }
            grid[y][x] = TerminalCell(text: text, attributes: attrs)
            if width == 2, x + 1 < grid[y].count { grid[y][x + 1] = TerminalCell(text: "", attributes: attrs, continuation: true) }
        }
        if cursorX + width >= cols {
            cursorX = cols - 1
            wrapPending = true
        } else {
            cursorX += width
        }
    }

    static func isCombining(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x0300...0x036F, 0x1AB0...0x1AFF, 0x1DC0...0x1DFF, 0x20D0...0x20FF, 0xFE20...0xFE2F,
             0x200D, 0xFE00...0xFE0F, 0x1F3FB...0x1F3FF, 0xE0100...0xE01EF:
            return true
        default:
            return false
        }
    }

    static func isWide(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
             0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F300...0x1F64F, 0x1F680...0x1F6FF, 0x1F900...0x1F9FF, 0x1FA70...0x1FAFF, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }

    // MARK: grid helpers

    private mutating func withGrid<T>(_ body: (inout [[TerminalCell]]) -> T) -> T {
        if usingAlternateScreen { return body(&alternate) }
        return body(&main)
    }

    private var blankCell: TerminalCell {
        // Erased cells take the current background, as in xterm.
        var a = TerminalAttributes.plain
        a.bg = attributes.bg
        return TerminalCell(text: " ", attributes: a)
    }

    private func blankLine() -> [TerminalCell] { Array(repeating: blankCell, count: cols) }

    private mutating func appendScrollback(_ lines: [[TerminalCell]]) {
        scrollback += lines
        if scrollback.count > TerminalScreen.scrollbackLimit { scrollback.removeFirst(scrollback.count - TerminalScreen.scrollbackLimit) }
    }

    private mutating func lineFeed() {
        wrapPending = false
        if cursorY == scrollBottom {
            scrollUp(1)
        } else if cursorY < rows - 1 {
            cursorY += 1
        }
    }

    private mutating func reverseIndex() {
        wrapPending = false
        if cursorY == scrollTop { scrollDown(1) } else if cursorY > 0 { cursorY -= 1 }
    }

    private mutating func scrollUp(_ n: Int) {
        let n = max(1, min(n, scrollBottom - scrollTop + 1))
        let top = scrollTop, bottom = scrollBottom, blank = blankLine()
        let toScrollback = !usingAlternateScreen && top == 0
        let removed: [[TerminalCell]] = withGrid { grid in
            let gone = Array(grid[top..<(top + n)])
            grid.removeSubrange(top..<(top + n))
            grid.insert(contentsOf: Array(repeating: blank, count: n), at: bottom - n + 1)
            return gone
        }
        if toScrollback { appendScrollback(removed) }
    }

    private mutating func scrollDown(_ n: Int) {
        let n = max(1, min(n, scrollBottom - scrollTop + 1))
        let top = scrollTop, bottom = scrollBottom, blank = blankLine()
        withGrid { grid in
            grid.removeSubrange((bottom - n + 1)...bottom)
            grid.insert(contentsOf: Array(repeating: blank, count: n), at: top)
        }
    }

    private mutating func saveCursor() {
        saved = SavedCursor(x: cursorX, y: cursorY, attributes: attributes)
    }

    private mutating func restoreCursor() {
        cursorX = min(saved.x, cols - 1)
        cursorY = min(saved.y, rows - 1)
        attributes = saved.attributes
        wrapPending = false
    }

    private mutating func reset() {
        let c = cols, r = rows, back = scrollback
        self = TerminalScreen(cols: c, rows: r)
        scrollback = back
    }

    private mutating func setAlternateScreen(_ on: Bool, saveCursor save: Bool) {
        guard on != usingAlternateScreen else { return }
        if on {
            if save { savedMain = SavedCursor(x: cursorX, y: cursorY, attributes: attributes) }
            alternate = TerminalScreen.blankGrid(cols: cols, rows: rows)
            usingAlternateScreen = true
        } else {
            usingAlternateScreen = false
            if save {
                cursorX = min(savedMain.x, cols - 1)
                cursorY = min(savedMain.y, rows - 1)
                attributes = savedMain.attributes
            }
        }
        scrollTop = 0
        scrollBottom = rows - 1
        wrapPending = false
    }

    // MARK: CSI

    private var params: [Int] {
        csiParams.split(separator: ";", omittingEmptySubsequences: false).map { Int($0.split(separator: ":").first ?? "") ?? 0 }
    }

    private func param(_ i: Int, default d: Int = 1) -> Int {
        let p = params
        guard i < p.count, p[i] != 0 else { return d }
        return p[i]
    }

    private mutating func dispatchCSI(_ final: Character, replies: inout [UInt8]) {
        if csiPrivate == "?" {
            if final == "h" || final == "l" { setPrivateModes(final == "h") }
            return
        }
        if csiPrivate == ">" {
            if final == "c" { replies += Array("\u{1B}[>0;0;0c".utf8) }
            return
        }
        guard csiPrivate == nil else { return }
        if !csiIntermediate.isEmpty { return }   // cursor style (SP q) and friends
        let n = param(0)
        switch final {
        case "A": cursorY = max(cursorY >= scrollTop ? scrollTop : 0, cursorY - n); wrapPending = false
        case "B", "e": cursorY = min(cursorY <= scrollBottom ? scrollBottom : rows - 1, cursorY + n); wrapPending = false
        case "C", "a": cursorX = min(cols - 1, cursorX + n); wrapPending = false
        case "D": cursorX = max(0, cursorX - n); wrapPending = false
        case "E": cursorX = 0; cursorY = min(rows - 1, cursorY + n); wrapPending = false
        case "F": cursorX = 0; cursorY = max(0, cursorY - n); wrapPending = false
        case "G", "`": cursorX = min(cols - 1, max(0, n - 1)); wrapPending = false
        case "d": cursorY = min(rows - 1, max(0, n - 1)); wrapPending = false
        case "H", "f":
            cursorY = min(rows - 1, max(0, param(0) - 1))
            cursorX = min(cols - 1, max(0, param(1) - 1))
            wrapPending = false
        case "J": eraseDisplay(param(0, default: 0))
        case "K": eraseLine(param(0, default: 0))
        case "L": insertLines(n)
        case "M": deleteLines(n)
        case "P": deleteChars(n)
        case "@": insertChars(n)
        case "X": eraseChars(n)
        case "S": scrollUp(n)
        case "T": scrollDown(n)
        case "r":
            let top = max(0, param(0) - 1)
            let bottom = min(rows - 1, param(1, default: rows) - 1)
            if top < bottom { scrollTop = top; scrollBottom = bottom }
            cursorX = 0; cursorY = 0; wrapPending = false
        case "s": saveCursor()
        case "u": restoreCursor()
        case "m": selectGraphicRendition()
        case "n":
            if param(0, default: 0) == 5 { replies += Array("\u{1B}[0n".utf8) }
            if param(0, default: 0) == 6 { replies += Array("\u{1B}[\(cursorY + 1);\(cursorX + 1)R".utf8) }
        case "c":
            if param(0, default: 0) == 0 { replies += Array("\u{1B}[?1;2c".utf8) }
        default:
            break
        }
    }

    private mutating func setPrivateModes(_ on: Bool) {
        for mode in params {
            switch mode {
            case 1: applicationCursorKeys = on
            case 7: autowrap = on
            case 25: cursorVisible = on
            case 47, 1047: setAlternateScreen(on, saveCursor: false)
            case 1049: setAlternateScreen(on, saveCursor: true)
            case 2004: bracketedPaste = on
            default: break
            }
        }
    }

    private mutating func eraseDisplay(_ mode: Int) {
        let blank = blankCell, x = cursorX, y = cursorY, c = cols, r = rows
        withGrid { grid in
            switch mode {
            case 0:
                for i in x..<c { grid[y][i] = blank }
                for row in (y + 1)..<max(y + 1, r) { grid[row] = Array(repeating: blank, count: c) }
            case 1:
                for row in 0..<y { grid[row] = Array(repeating: blank, count: c) }
                for i in 0...min(x, c - 1) { grid[y][i] = blank }
            default:
                grid = Array(repeating: Array(repeating: blank, count: c), count: r)
            }
        }
        if mode == 3 && !usingAlternateScreen { scrollback = [] }
        wrapPending = false
    }

    private mutating func eraseLine(_ mode: Int) {
        let blank = blankCell, x = cursorX, y = cursorY, c = cols
        withGrid { grid in
            switch mode {
            case 0: for i in x..<c { grid[y][i] = blank }
            case 1: for i in 0...min(x, c - 1) { grid[y][i] = blank }
            default: grid[y] = Array(repeating: blank, count: c)
            }
        }
        wrapPending = false
    }

    private mutating func insertLines(_ n: Int) {
        guard cursorY >= scrollTop, cursorY <= scrollBottom else { return }
        let n = min(n, scrollBottom - cursorY + 1), y = cursorY, bottom = scrollBottom, blank = blankLine()
        withGrid { grid in
            grid.removeSubrange((bottom - n + 1)...bottom)
            grid.insert(contentsOf: Array(repeating: blank, count: n), at: y)
        }
        cursorX = 0
        wrapPending = false
    }

    private mutating func deleteLines(_ n: Int) {
        guard cursorY >= scrollTop, cursorY <= scrollBottom else { return }
        let n = min(n, scrollBottom - cursorY + 1), y = cursorY, bottom = scrollBottom, blank = blankLine()
        withGrid { grid in
            grid.removeSubrange(y..<(y + n))
            grid.insert(contentsOf: Array(repeating: blank, count: n), at: bottom - n + 1)
        }
        cursorX = 0
        wrapPending = false
    }

    private mutating func deleteChars(_ n: Int) {
        let n = min(n, cols - cursorX), x = cursorX, y = cursorY, blank = blankCell
        withGrid { grid in
            grid[y].removeSubrange(x..<(x + n))
            grid[y] += Array(repeating: blank, count: n)
        }
        wrapPending = false
    }

    private mutating func insertChars(_ n: Int) {
        let n = min(n, cols - cursorX), x = cursorX, y = cursorY, c = cols, blank = blankCell
        withGrid { grid in
            grid[y].insert(contentsOf: Array(repeating: blank, count: n), at: x)
            grid[y] = Array(grid[y].prefix(c))
        }
        wrapPending = false
    }

    private mutating func eraseChars(_ n: Int) {
        let end = min(cols, cursorX + n), x = cursorX, y = cursorY, blank = blankCell
        withGrid { grid in for i in x..<end { grid[y][i] = blank } }
        wrapPending = false
    }

    private mutating func selectGraphicRendition() {
        var p = params
        if p.isEmpty { p = [0] }
        var i = 0
        while i < p.count {
            let code = p[i]
            switch code {
            case 0: attributes = .plain
            case 1: attributes.bold = true
            case 2: attributes.dim = true
            case 3: attributes.italic = true
            case 4: attributes.underline = true
            case 7: attributes.inverse = true
            case 21, 22: attributes.bold = false; attributes.dim = false
            case 23: attributes.italic = false
            case 24: attributes.underline = false
            case 27: attributes.inverse = false
            case 30...37: attributes.fg = .indexed(UInt8(code - 30))
            case 39: attributes.fg = .default
            case 40...47: attributes.bg = .indexed(UInt8(code - 40))
            case 49: attributes.bg = .default
            case 90...97: attributes.fg = .indexed(UInt8(code - 90 + 8))
            case 100...107: attributes.bg = .indexed(UInt8(code - 100 + 8))
            case 38, 48:
                var color: TerminalColor?
                if i + 2 < p.count, p[i + 1] == 5 {
                    color = .indexed(UInt8(clamping: p[i + 2])); i += 2
                } else if i + 4 < p.count, p[i + 1] == 2 {
                    color = .rgb(UInt8(clamping: p[i + 2]), UInt8(clamping: p[i + 3]), UInt8(clamping: p[i + 4])); i += 4
                }
                if let color { if code == 38 { attributes.fg = color } else { attributes.bg = color } }
            default: break
            }
            i += 1
        }
    }
}
