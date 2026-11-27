import XCTest

@testable import FarcastCore

final class RsyncTests: XCTestCase {
    func testDiscoveryRanking() throws {
        let versions = ["2.6.9", "3.2.7", "3.4.0pre1", "3.4.0", "3.10.0"]
        let items = try versions.map {
            try XCTUnwrap(RsyncInstall(path: "/tool/" + $0, output: "rsync  version " + $0 + "  protocol version 32"))
        }
        let open = try XCTUnwrap(
            RsyncInstall(
                path: "/usr/bin/rsync", output: "openrsync: protocol version 29\nrsync version 2.6.9 compatible"))
        XCTAssertEqual(RsyncInstall.ranked([open] + items, override: nil), items.reversed() + [open])
        XCTAssertEqual(RsyncInstall.ranked(items, override: items[0].path).first, items[0])
        XCTAssertNil(RsyncInstall(path: "/tool", output: "version 3.10.0"))
    }
    func testLegacyDefaultAndOptions() {
        let profile = SavedConnection(draft: ConnectionDraft())
        profile.sshFileTransfer = nil
        XCTAssertEqual(ConnectionDraft(profile).fileTransfer, FileTransferSettings())
        var settings = FileTransferSettings()
        for option in ["-e", "--rsh=ssh", "--rsync-path=other", "--delete", "--remove-source-files", "-az"] {
            settings.extraRsyncArgs = [option]
            XCTAssertNotNil(settings.validationMessage)
        }
        settings.extraRsyncArgs = ["--bwlimit=512"]
        XCTAssertNil(settings.validationMessage)
        profile.fileTransfer = settings
        XCTAssertEqual(ConnectionDraft(profile.duplicate()).fileTransfer, settings)
    }
}
