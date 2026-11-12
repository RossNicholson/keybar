import XCTest
@testable import KeyBar

/// Two Macs, each with its own login keychain, sharing one iCloud Keychain
@MainActor
final class SyncTests: XCTestCase {
    let iCloud = MemoryVault()

    func mac(_ values: [String: String] = [:], syncs: Bool = false) -> (SecretStore, LiveVault) {
        let live = LiveVault(thisMac: MemoryVault(values), iCloud: iCloud, syncs: syncs)
        return (SecretStore(vault: live, indexURL: nil), live)
    }

    func testOffUsesThisMacOnly() throws {
        try iCloud.write("OTHER_MACS_KEY", value: "x")
        let (store, live) = mac(["MINE": "1"])
        XCTAssertEqual(store.records.map(\.name), ["MINE"])
        try store.add(name: "NEW_KEY", value: "2")
        XCTAssertEqual(try live.thisMac.read("NEW_KEY"), "2")
        XCTAssertNil(try iCloud.read("NEW_KEY"))
        XCTAssertThrowsError(try store.value("OTHER_MACS_KEY"), "off, iCloud's keys aren't this Mac's")
    }

    func testTurningOnMovesKeysAndDetails() throws {
        let (store, live) = mac(["STRIPE_KEY": "sk"])
        var record = try XCTUnwrap(store.record("STRIPE_KEY"))
        record.group = "Shop"
        record.projectFolders = ["/Users/me/shop"]
        store.update(record)

        XCTAssertEqual(try store.moveToICloud(live), [:])
        XCTAssertTrue(store.syncs)
        XCTAssertEqual(try iCloud.read("STRIPE_KEY"), "sk")
        XCTAssertNil(try live.thisMac.read("STRIPE_KEY"), "moved, not copied")
        XCTAssertEqual(try store.value("STRIPE_KEY"), "sk")

        // The second Mac sees the key with its group and folder limit
        let (other, _) = mac(syncs: true)
        let seen = try XCTUnwrap(other.record("STRIPE_KEY"))
        XCTAssertEqual(seen.group, "Shop")
        XCTAssertEqual(seen.projectFolders, ["/Users/me/shop"], "a folder limit must follow the key")
    }

    func testSameNameDifferentValueIsRenamed() throws {
        let (first, firstLive) = mac(["GITHUB_TOKEN": "aaa"])
        try first.moveToICloud(firstLive)
        let (second, secondLive) = mac(["GITHUB_TOKEN": "bbb", "SAME": "s"])
        try iCloud.write("SAME", value: "s")
        let renamed = try second.moveToICloud(secondLive)
        XCTAssertEqual(renamed, ["GITHUB_TOKEN": "GITHUB_TOKEN_2"])
        XCTAssertEqual(try iCloud.read("GITHUB_TOKEN"), "aaa", "the key already in iCloud keeps its name")
        XCTAssertEqual(try iCloud.read("GITHUB_TOKEN_2"), "bbb")
        XCTAssertEqual(Set(second.records.map(\.name)), ["GITHUB_TOKEN", "GITHUB_TOKEN_2", "SAME"])
    }

    func testChangesArriveOnRefresh() throws {
        let (first, _) = mac(syncs: true)
        let (second, _) = mac(syncs: true)
        try first.add(name: "OPENAI_API_KEY", value: "o", note: "work")
        XCTAssertNil(second.record("OPENAI_API_KEY"))
        second.refresh()
        XCTAssertEqual(second.record("OPENAI_API_KEY")?.note, "work")

        first.setArchived("OPENAI_API_KEY", true)
        second.refresh()
        XCTAssertEqual(second.record("OPENAI_API_KEY")?.isArchived, true, "archiving syncs")

        try first.delete("OPENAI_API_KEY")
        second.refresh()
        XCTAssertNil(second.record("OPENAI_API_KEY"), "deleting syncs")
    }

    func testLastUsedStaysOnEachMac() throws {
        let (first, _) = mac(syncs: true)
        try first.add(name: "A_KEY", value: "a")
        let before = try XCTUnwrap(iCloud.details()["A_KEY"])
        first.markUsed(["A_KEY"])
        XCTAssertEqual(try iCloud.details()["A_KEY"], before, "using a key doesn't rewrite its synced item")
    }

    func testTurningOffKeepsCopies() throws {
        let (store, live) = mac(["MINE": "1"])
        try store.moveToICloud(live)
        try iCloud.write("FROM_OTHER_MAC", value: "2")
        store.refresh()
        try store.keepOnThisMac(live)
        XCTAssertFalse(store.syncs)
        XCTAssertEqual(try live.thisMac.read("MINE"), "1")
        XCTAssertEqual(try live.thisMac.read("FROM_OTHER_MAC"), "2")
        XCTAssertEqual(try iCloud.read("MINE"), "1", "the other Macs keep theirs")
        XCTAssertEqual(Set(store.records.map(\.name)), ["MINE", "FROM_OTHER_MAC"])
    }

    func testBridgeSeesKeyAddedOnAnotherMac() throws {
        let (first, _) = mac(syncs: true)
        let (second, _) = mac(syncs: true)
        let policy = BridgePolicy(store: second, log: ActivityLog(url: nil))
        try first.add(name: "NEW_TOKEN", value: "fresh-value-123")
        let reply = policy.handle(BridgeRequest(action: .list, cwd: "/tmp"))
        XCTAssertEqual(reply.secrets?.map(\.name), ["NEW_TOKEN"])
    }

    func testFreeName() {
        XCTAssertEqual(SecretStore.freeName("K", taken: ["K"]), "K_2")
        XCTAssertEqual(SecretStore.freeName("K", taken: ["K", "K_2"]), "K_3")
    }
}
