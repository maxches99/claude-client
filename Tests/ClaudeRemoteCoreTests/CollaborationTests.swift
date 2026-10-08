import XCTest
@testable import ClaudeRemoteCore

final class CollaborationTests: XCTestCase {
    func testExtractPlan() {
        let reply = "Sure.\n\nPlan:\n1. Read the parser\n2) Fix the off-by-one\n- Add a test\n\nNow working on it."
        XCTAssertEqual(TaskReview.extractPlan(reply), ["Read the parser", "Fix the off-by-one", "Add a test"])
        XCTAssertNil(TaskReview.extractPlan("No plan here."))
    }

    func testParsePlanCheck() {
        let plan = ["Read the parser", "Fix the bug", "Add a test"]
        let reply = """
        Looks fine.
        ```json
        {"steps": [{"step": 1, "status": "done"}, {"step": 2, "status": "done"}, {"step": 3, "status": "missing", "note": "no test added"}],
         "extras": ["renamed a variable"], "summary": "Fixed, untested."}
        ```
        """
        let check = TaskReview.parsePlanCheck(reply, plan: plan)
        XCTAssertEqual(check?.steps.map(\.status), [.done, .done, .missing])
        XCTAssertEqual(check?.steps.last?.note, "no test added")
        XCTAssertEqual(check?.doneCount, 2)
        XCTAssertEqual(check?.extras, ["renamed a variable"])
        // Steps the reviewer skipped still show up.
        let partial = TaskReview.parsePlanCheck(#"{"steps": [{"step": 1, "status": "done"}], "summary": ""}"#, plan: plan)
        XCTAssertEqual(partial?.steps.count, 3)
    }

    func testTranscriptRewrite() {
        let line = #"{"cwd":"/Users/a/proj","message":{"content":"see /Users/a/proj/file.swift"},"x":"/Users/a/project2"}"#
        let out = SessionPackage.rewrite(transcript: line, from: "/Users/a/proj", to: "/home/b/work/proj")
        XCTAssertTrue(out.contains(#""cwd":"/home/b/work/proj""#))
        XCTAssertTrue(out.contains("see /home/b/work/proj/file.swift"))
    }

    func testFileHash() {
        XCTAssertEqual(FileHash.hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testOldHostInfoHasNoMe() throws {
        let info = try ProtocolCoding.decode(HostInfo.self, from: #"{"hostName":"Mac","daemonVersion":"1","cliPath":"/c","protocolVersion":8}"#)
        XCTAssertNil(info.me)
    }
}

final class PackageStripTests: XCTestCase {
    func testImagesLeftOut() throws {
        let withImage = #"{"type":"user","message":{"content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}},{"type":"text","text":"hi"}]}}"#
        let plain = #"{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]}}"#
        let out = String(decoding: SessionPackage.strippingImages(Data((withImage + "\n" + plain + "\n").utf8)), as: UTF8.self)
        XCTAssertFalse(out.contains("AAAA"))
        XCTAssertTrue(out.contains("image left out"))
        XCTAssertTrue(out.contains(plain))   // untouched lines go through byte for byte
    }
}
