//
//  SystemMetrics.swift
//  anubis
//
//  Created on 2026-01-25.
//

import Foundation

/// Hardware and system metrics captured during benchmarking
struct SystemMetrics: Sendable, Codable {
    /// Timestamp of the measurement
    let timestamp: Date

    /// GPU utilization (0.0 - 1.0)
    let gpuUtilization: Double

    /// CPU utilization (0.0 - 1.0)
    let cpuUtilization: Double

    /// Memory currently used in bytes
    let memoryUsedBytes: Int64

    /// Total system memory in bytes
    let memoryTotalBytes: Int64

    /// Current thermal state
    let thermalState: ThermalState

    /// Memory utilization as a percentage (0.0 - 1.0)
    var memoryUtilization: Double {
        guard memoryTotalBytes > 0 else { return 0 }
        return Double(memoryUsedBytes) / Double(memoryTotalBytes)
    }

    /// Formatted memory usage for display
    var formattedMemoryUsage: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        let used = formatter.string(fromByteCount: memoryUsedBytes)
        let total = formatter.string(fromByteCount: memoryTotalBytes)
        return "\(used) / \(total)"
    }
}

/// Thermal state mapping from ProcessInfo.ThermalState
enum ThermalState: Int, Codable, Sendable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    init(from processInfoState: ProcessInfo.ThermalState) {
        switch processInfoState {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }

    var displayName: String {
        switch self {
        case .nominal: return "Normal"
        case .fair: return "Fair"
        case .serious: return "Throttled"
        case .critical: return "Critical"
        }
    }

    var color: String {
        switch self {
        case .nominal: return "anubisSuccess"
        case .fair: return "anubisWarning"
        case .serious: return "anubisError"
        case .critical: return "anubisError"
        }
    }
}

/// Chip information for the current Mac
struct ChipInfo: Sendable {
    let name: String
    let coreCount: Int
    let performanceCores: Int
    let efficiencyCores: Int
    let gpuCores: Int
    let neuralEngineCores: Int
    let unifiedMemoryGB: Int

    static var current: ChipInfo {
        let processInfo = ProcessInfo.processInfo
        let coreCount = processInfo.activeProcessorCount

        // Detect chip type from sysctl (simplified)
        // In production, use sysctl to get hw.model
        return ChipInfo(
            name: "Apple Silicon",
            coreCount: coreCount,
            performanceCores: coreCount > 4 ? coreCount / 2 : coreCount,
            efficiencyCores: coreCount > 4 ? coreCount / 2 : 0,
            gpuCores: 0, // Would need IOKit to detect
            neuralEngineCores: 16, // Typical for M-series
            unifiedMemoryGB: Int(processInfo.physicalMemory / (1024 * 1024 * 1024))
        )
    }
}
