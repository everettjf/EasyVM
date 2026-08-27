import XCTest
@testable import EZVMCore

final class VMMacOSCatalogPayloadTests: XCTestCase {
    func testAvailableFirmwaresKeepsOnlySignedAppleDownloadsAndSortsNewestFirst() throws {
        let data = #"{"firmwares":[{"version":"26.0","buildid":"25A1","filesize":12,"url":"https://updates.cdn-apple.com/new.ipsw","signed":true},{"version":"15.7","buildid":"24G1","filesize":10,"url":"https://updates.cdn-apple.com/old.ipsw","signed":true},{"version":"27.0","buildid":"26A1","filesize":20,"url":"https://updates.cdn-apple.com/beta.ipsw","signed":false},{"version":"99.0","buildid":"evil","filesize":20,"url":"https://notapple.com/evil.ipsw","signed":true}]}"#.data(using: .utf8)!

        let payload = try JSONDecoder().decode(VMMacOSCatalogPayload.self, from: data)

        XCTAssertEqual(payload.availableFirmwares.map(\.version), ["26.0", "15.7"])
    }

    func testAvailableFirmwaresDeduplicatesBuildsAndRejectsInvalidMetadata() throws {
        let valid = VMMacOSCatalogPayload.Firmware(version: "26.1", buildid: "25B1", filesize: 100, url: URL(string: "https://updates.apple.com/a.ipsw")!, signed: true)
        let payload = VMMacOSCatalogPayload(firmwares: [
            valid,
            valid,
            .init(version: "26.2", buildid: "25C1", filesize: 0, url: URL(string: "https://updates.apple.com/b.ipsw")!, signed: true),
            .init(version: "26.3", buildid: "25D1", filesize: 100, url: URL(string: "http://updates.apple.com/c.ipsw")!, signed: true),
        ])

        XCTAssertEqual(payload.availableFirmwares, [valid])
    }

    func testCacheRoundTripPreservesFetchDateAndPayload() throws {
        let payload = VMMacOSCatalogPayload(firmwares: [
            .init(version: "26.0", buildid: "25A1", filesize: 42, url: URL(string: "https://updates.apple.com/a.ipsw")!, signed: true)
        ])
        let cache = VMMacOSCatalogCache(fetchedAt: Date(timeIntervalSince1970: 1234), payload: payload)

        let decoded = try JSONDecoder().decode(VMMacOSCatalogCache.self, from: JSONEncoder().encode(cache))

        XCTAssertEqual(decoded, cache)
    }
}
