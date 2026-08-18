//
//  VMSystemImageCatalog.swift
//  EasyVM
//
//  Created by everettjf on 2026/8/18.
//

import Foundation

#if arch(arm64)

/*
 A curated list of restore images (macOS) and install ISOs (Linux, aarch64)
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

    init(id: String, osType: VMOSType, name: String, detail: String, urlString: String) {
        self.id = id
        self.osType = osType
        self.name = name
        self.detail = detail
        self.url = URL(string: urlString)!
    }
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

#endif
