import XCTest
@testable import ClaudeRemoteCore

final class GitTests: XCTestCase {
    func testParsesPorcelainV2() {
        let text = """
        # branch.oid 0123456789abcdef
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +2 -1
        1 .M N... 100644 100644 100644 abc def Sources/App.swift
        1 M. N... 100644 100644 100644 abc def Sources/Staged.swift
        1 MM N... 100644 100644 100644 abc def Sources/Both.swift
        2 R. N... 100644 100644 100644 abc def R100 New Name.swift\tOld.swift
        u UU N... 100644 100644 100644 100644 abc def ghi Conflict.swift
        ? Untracked file.txt
        ? .ccremote-attachments/x.pdf
        """
        let s = GitStatus.parse(porcelain: text)
        XCTAssertEqual(s.branch, "main")
        XCTAssertEqual(s.upstream, "origin/main")
        XCTAssertEqual(s.ahead, 2)
        XCTAssertEqual(s.behind, 1)
        XCTAssertEqual(s.files.map(\.path), ["Sources/App.swift", "Sources/Staged.swift", "Sources/Both.swift", "New Name.swift", "Conflict.swift", "Untracked file.txt"])
        XCTAssertEqual(s.staged.map(\.path), ["Sources/Staged.swift", "Sources/Both.swift", "New Name.swift"])
        XCTAssertEqual(s.unstaged.map(\.path), ["Sources/App.swift", "Sources/Both.swift", "Conflict.swift"])
        XCTAssertEqual(s.untracked.map(\.path), ["Untracked file.txt"])
        XCTAssertTrue(s.files[4].conflicted)
    }

    func testDetachedHead() {
        let s = GitStatus.parse(porcelain: "# branch.oid abcdef1234567\n# branch.head (detached)\n")
        XCTAssertNil(s.branch)
        XCTAssertEqual(s.detachedAt, "abcdef1")
        XCTAssertTrue(s.isClean)
    }

    func testNumstatFillsLineCounts() throws {
        var s = GitStatus(branch: "main", files: [
            GitFile(path: "a.swift", indexStatus: ".", workStatus: "M"),
            GitFile(path: "logo.png", indexStatus: "M", workStatus: "."),
            GitFile(path: "notes/new file.md", indexStatus: ".", workStatus: ".", untracked: true),
        ])
        XCTAssertNil(s.linesAdded)
        s.applyNumstat("12\t3\ta.swift\n-\t-\tlogo.png\n")
        XCTAssertEqual(s.files[0].added, 12)
        XCTAssertEqual(s.files[0].removed, 3)
        XCTAssertNil(s.files[1].added)   // binary
        XCTAssertEqual(s.linesAdded, 12)
        XCTAssertEqual(s.linesRemoved, 3)
        // A status from a host that doesn't count lines still decodes.
        let legacy = try JSONDecoder().decode(GitFile.self, from: Data(#"{"path":"x","indexStatus":".","workStatus":"M","untracked":false,"conflicted":false}"#.utf8))
        XCTAssertNil(legacy.added)
    }

    func testGitMessagesRoundTrip() throws {
        let status = GitStatus(branch: "main", upstream: "origin/main", ahead: 1, files: [GitFile(path: "a.swift", indexStatus: ".", workStatus: "M")], branches: ["main", "dev"], lastCommit: "abc Subject")
        let back = try ProtocolCoding.decode(ServerMessage.self, from: ProtocolCoding.encode(ServerMessage.gitStatus(sessionId: "s", status: status, error: nil)))
        guard case .gitStatus(_, let decoded, _) = back else { return XCTFail("not gitStatus") }
        XCTAssertEqual(decoded, status)
        for action: GitAction in [.stage(paths: []), .commit(message: "m", all: true), .push(setUpstream: true), .checkout(branch: "dev")] {
            let m = try ProtocolCoding.decode(ClientMessage.self, from: ProtocolCoding.encode(ClientMessage.gitAction(sessionId: "s", action: action)))
            guard case .gitAction(_, let a) = m else { return XCTFail("not gitAction") }
            XCTAssertEqual(a, action)
        }
        // An older phone still sends gitDiff without the optional fields.
        let legacy = try ProtocolCoding.decode(ClientMessage.self, from: #"{"gitDiff":{"sessionId":"s"}}"#)
        guard case .gitDiff(let id, let path, let staged) = legacy else { return XCTFail("not gitDiff") }
        XCTAssertEqual(id, "s"); XCTAssertNil(path); XCTAssertNil(staged)
    }
}
