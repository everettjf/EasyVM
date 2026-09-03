import Foundation

public struct VMOmarchyStorageForecast: Equatable {
    public static let defaultReserveBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024

    public let downloadBytes: UInt64
    public let workspaceBytes: UInt64
    public let reserveBytes: UInt64
    public let availableBytes: UInt64

    public var requiredBytes: UInt64 {
        Self.saturatingAdd(Self.saturatingAdd(downloadBytes, workspaceBytes), reserveBytes)
    }

    public var hasEnoughSpace: Bool { availableBytes >= requiredBytes }

    public init(
        downloadBytes: UInt64,
        workspaceBytes: UInt64,
        reserveBytes: UInt64 = defaultReserveBytes,
        availableBytes: UInt64
    ) {
        self.downloadBytes = downloadBytes
        self.workspaceBytes = workspaceBytes
        self.reserveBytes = reserveBytes
        self.availableBytes = availableBytes
    }

    public static func inspect(
        volumeContaining url: URL,
        downloadBytes: UInt64,
        workspaceBytes: UInt64,
        reserveBytes: UInt64 = defaultReserveBytes
    ) throws -> Self {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available = max(values.volumeAvailableCapacityForImportantUsage ?? 0, 0)
        return Self(
            downloadBytes: downloadBytes,
            workspaceBytes: workspaceBytes,
            reserveBytes: reserveBytes,
            availableBytes: UInt64(available)
        )
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : result
    }
}
