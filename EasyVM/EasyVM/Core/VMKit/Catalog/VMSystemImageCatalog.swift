//
//  VMSystemImageCatalog.swift
//  EasyVM
//
//  Created by everettjf on 2026/8/18.
//

import Foundation

#if arch(arm64)

/*
 A dynamic list of restore images (macOS) and curated install ISOs (Linux, aarch64)
 that can be downloaded directly from the create-machine guide, so users can
 pick a system version instead of hunting for an ipsw/iso themselves.

 The URLs point to the vendors' official CDNs. When a vendor retires a point
 release the URL may stop working; refresh the entries here in that case.
 Users can always fall back to "Custom URL" or a local file.
 */
struct VMSystemImageCatalogItem: Identifiable, Hashable {
    let id: String
    let osType: VMOSType
    let name: String
    let detail: String
    let url: URL
    let version: String?
    let build: String?
    let fileSize: Int64?

    init(
        id: String,
        osType: VMOSType,
        name: String,
        detail: String,
        urlString: String,
        version: String? = nil,
        build: String? = nil,
        fileSize: Int64? = nil
    ) {
        self.id = id
        self.osType = osType
        self.name = name
        self.detail = detail
        self.url = URL(string: urlString)!
        self.version = version
        self.build = build
        self.fileSize = fileSize
    }
}

@MainActor
final class VMMacOSImageCatalogService: ObservableObject {
    @Published private(set) var items = VMSystemImageCatalog.macOSItems
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var errorMessage: String?

    private static let endpoint = URL(string: "https://api.ipsw.me/v4/device/VirtualMac2,1?type=ipsw")!
    private static let cacheMaxAge: TimeInterval = 6 * 60 * 60

    init() {
        loadCache()
    }

    var featuredItems: [VMSystemImageCatalogItem] {
        let grouped = Dictionary(grouping: items) { item in
            item.version?.split(separator: ".").first.map(String.init) ?? item.id
        }
        return grouped.values.compactMap { releases in
            releases.max { lhs, rhs in
                (lhs.version ?? "0").compare(rhs.version ?? "0", options: .numeric) == .orderedAscending
            }
        }
        .sorted { lhs, rhs in
            (lhs.version ?? "0").compare(rhs.version ?? "0", options: .numeric) == .orderedDescending
        }
    }

    func refresh(force: Bool = false) async {
        if !force, let lastUpdated, Date().timeIntervalSince(lastUpdated) < Self.cacheMaxAge {
            return
        }
        isRefreshing = true
        errorMessage = nil
        defer { isRefreshing = false }

        do {
            var request = URLRequest(url: Self.endpoint)
            request.timeoutInterval = 20
            request.setValue("EasyVM/3", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let catalog = try JSONDecoder().decode(VMMacOSCatalogPayload.self, from: data)
            let remoteItems = catalog.availableFirmwares.map(Self.makeItem)
            guard !remoteItems.isEmpty else { throw CatalogError.emptyCatalog }
            items = remoteItems
            let fetchedAt = Date()
            lastUpdated = fetchedAt
            try? FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let cache = VMMacOSCatalogCache(fetchedAt: fetchedAt, payload: catalog)
            if let cacheData = try? JSONEncoder().encode(cache) {
                try? cacheData.write(to: cacheURL, options: .atomic)
            }
        } catch {
            errorMessage = items == VMSystemImageCatalog.macOSItems
                ? "Couldn’t reach the online catalog. Built-in versions are available, or choose Latest compatible macOS."
                : "Couldn’t refresh the catalog. Showing the last saved version list."
        }
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL) else { return }
        let decoder = JSONDecoder()
        let cache: VMMacOSCatalogCache
        if let currentCache = try? decoder.decode(VMMacOSCatalogCache.self, from: data) {
            cache = currentCache
        } else if let legacyPayload = try? decoder.decode(VMMacOSCatalogPayload.self, from: data) {
            cache = VMMacOSCatalogCache(
                fetchedAt: UserDefaults.standard.object(forKey: "VMMacOSCatalogLastUpdated") as? Date ?? .distantPast,
                payload: legacyPayload
            )
        } else {
            return
        }
        let cachedItems = cache.payload.availableFirmwares.map(Self.makeItem)
        if !cachedItems.isEmpty { items = cachedItems }
        lastUpdated = cache.fetchedAt
    }

    private var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "EasyVM", directoryHint: .isDirectory)
            .appending(path: "macos-catalog.json")
    }

    private static func makeItem(_ firmware: VMMacOSCatalogPayload.Firmware) -> VMSystemImageCatalogItem {
        let size = ByteCountFormatter.string(fromByteCount: firmware.filesize, countStyle: .file)
        return VMSystemImageCatalogItem(
            id: "macos-\(firmware.version)-\(firmware.buildid)",
            osType: .macOS,
            name: macOSName(version: firmware.version),
            detail: "Build \(firmware.buildid) · \(size)",
            urlString: firmware.url.absoluteString,
            version: firmware.version,
            build: firmware.buildid,
            fileSize: firmware.filesize
        )
    }

    private static func macOSName(version: String) -> String {
        let major = version.split(separator: ".").first.map(String.init) ?? version
        let names = ["12": "Monterey", "13": "Ventura", "14": "Sonoma", "15": "Sequoia", "26": "Tahoe"]
        if let name = names[major] { return "macOS \(name) \(version)" }
        return "macOS \(version)"
    }

    private enum CatalogError: Error { case emptyCatalog }
}

struct VMSystemImageCatalog {

    static let macOSItems: [VMSystemImageCatalogItem] = [
        VMSystemImageCatalogItem(
            id: "macos-15.0",
            osType: .macOS,
            name: "macOS Sequoia 15.0",
            detail: "Build 24A335",
            urlString: "https://updates.cdn-apple.com/2024FallFCS/fullrestores/062-78489/BDA44327-C79E-4608-A7E0-455A7E91911F/UniversalMac_15.0_24A335_Restore.ipsw"
        ),
        VMSystemImageCatalogItem(
            id: "macos-14.0",
            osType: .macOS,
            name: "macOS Sonoma 14.0",
            detail: "Build 23A344",
            urlString: "https://updates.cdn-apple.com/2023FallFCS/fullrestores/042-54934/0E101AD6-3117-4B63-9BF1-143B6DB9270A/UniversalMac_14.0_23A344_Restore.ipsw"
        ),
        VMSystemImageCatalogItem(
            id: "macos-13.0",
            osType: .macOS,
            name: "macOS Ventura 13.0",
            detail: "Build 22A380",
            urlString: "https://updates.cdn-apple.com/2022FallFCS/fullrestores/012-92188/2C38BCD1-2BFF-4A10-B358-94E8E28BE805/UniversalMac_13.0_22A380_Restore.ipsw"
        ),
        VMSystemImageCatalogItem(
            id: "macos-12.0.1",
            osType: .macOS,
            name: "macOS Monterey 12.0.1",
            detail: "Build 21A559",
            urlString: "https://updates.cdn-apple.com/2021FallFCS/fullrestores/002-23589/A54AC135-A25C-4C21-B47A-3C4930D18C13/UniversalMac_12.0.1_21A559_Restore.ipsw"
        ),
    ]

    static let linuxItems: [VMSystemImageCatalogItem] = [
        VMSystemImageCatalogItem(
            id: "ubuntu-24.04-server",
            osType: .linux,
            name: "Ubuntu Server 24.04 LTS",
            detail: "arm64, live server installer",
            urlString: "https://cdimage.ubuntu.com/releases/24.04/release/ubuntu-24.04.4-live-server-arm64.iso"
        ),
        VMSystemImageCatalogItem(
            id: "ubuntu-24.04-desktop",
            osType: .linux,
            name: "Ubuntu Desktop 24.04 LTS",
            detail: "arm64, desktop installer",
            urlString: "https://cdimage.ubuntu.com/releases/24.04/release/ubuntu-24.04.4-desktop-arm64.iso"
        ),
        VMSystemImageCatalogItem(
            id: "debian-13-netinst",
            osType: .linux,
            name: "Debian 13 (trixie)",
            detail: "arm64, network installer",
            urlString: "https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/debian-13.1.0-arm64-netinst.iso"
        ),
        VMSystemImageCatalogItem(
            id: "fedora-42-server",
            osType: .linux,
            name: "Fedora Server 42",
            detail: "aarch64, DVD installer",
            urlString: "https://download.fedoraproject.org/pub/fedora/linux/releases/42/Server/aarch64/iso/Fedora-Server-dvd-aarch64-42-1.1.iso"
        ),
    ]

    static func items(for osType: VMOSType) -> [VMSystemImageCatalogItem] {
        switch osType {
        case .macOS:
            return macOSItems
        case .linux:
            return linuxItems
        }
    }
}


/*
 Shared store for downloaded system images, so an image downloaded once can
 be reused by every machine created afterwards instead of being downloaded
 into each VM bundle again.
 */
class VMImageStore {

    static func directory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "EasyVM", directoryHint: .isDirectory)
            .appending(path: "Images", directoryHint: .isDirectory)
    }

    // returns the target path for fileName, creating the store directory on demand
    static func preparePath(fileName: String) -> URL? {
        let dir = directory()
        if !FileManager.default.fileExists(atPath: dir.path(percentEncoded: false)) {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                print("failed to create image store directory : \(error)")
                return nil
            }
        }
        return dir.appending(path: fileName)
    }

    static func exists(fileName: String) -> Bool {
        FileManager.default.fileExists(atPath: directory().appending(path: fileName).path(percentEncoded: false))
    }
}

#endif
