//
//  BenchmarkSample.swift
//  anubis
//
//  Created on 2026-01-25.
//

import Foundation
@preconcurrency import GRDB

/// A time-series sample of metrics during a benchmark
struct BenchmarkSample: Identifiable, Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "benchmark_sample"

    var id: Int64?
    var sessionId: Int64
    var timestamp: Date
    var gpuUtilization: Double?
    var cpuUtilization: Double?
    var anePowerWatts: Double?
    var memoryUsedBytes: Int64?
    var memoryTotalBytes: Int64?
    var thermalState: Int?
    var tokensGenerated: Int?
    var cumulativeTokensPerSecond: Double?

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case sessionId = "session_id"
        case timestamp
        case gpuUtilization = "gpu_utilization"
        case cpuUtilization = "cpu_utilization"
        case anePowerWatts = "ane_power_watts"
        case memoryUsedBytes = "memory_used_bytes"
        case memoryTotalBytes = "memory_total_bytes"
        case thermalState = "thermal_state"
        case tokensGenerated = "tokens_generated"
        case cumulativeTokensPerSecond = "cumulative_tokens_per_second"
    }

    /// Create a sample from current metrics
    init(
        sessionId: Int64,
        metrics: SystemMetrics,
        tokensGenerated: Int? = nil,
        cumulativeTokensPerSecond: Double? = nil
    ) {
        self.id = nil
        self.sessionId = sessionId
        self.timestamp = metrics.timestamp
        self.gpuUtilization = metrics.gpuUtilization
        self.cpuUtilization = metrics.cpuUtilization
        self.anePowerWatts = nil  // Removed - was pm (requires r)
        self.memoryUsedBytes = metrics.memoryUsedBytes
        self.memoryTotalBytes = metrics.memoryTotalBytes
        self.thermalState = metrics.thermalState.rawValue
        self.tokensGenerated = tokensGenerated
        self.cumulativeTokensPerSecond = cumulativeTokensPerSecond
    }

    /// Create from raw values
    init(
        sessionId: Int64,
        timestamp: Date = Date(),
        gpuUtilization: Double? = nil,
        cpuUtilization: Double? = nil,
        anePowerWatts: Double? = nil,
        memoryUsedBytes: Int64? = nil,
        memoryTotalBytes: Int64? = nil,
        thermalState: Int? = nil,
        tokensGenerated: Int? = nil,
        cumulativeTokensPerSecond: Double? = nil
    ) {
        self.id = nil
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.gpuUtilization = gpuUtilization
        self.cpuUtilization = cpuUtilization
        self.anePowerWatts = anePowerWatts
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.thermalState = thermalState
        self.tokensGenerated = tokensGenerated
        self.cumulativeTokensPerSecond = cumulativeTokensPerSecond
    }

    // MARK: - MutablePersistableRecord

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Database Operations

extension BenchmarkSample {
    /// Fetch all samples for a session
    static func fetchForSession(db: Database, sessionId: Int64) throws -> [BenchmarkSample] {
        try BenchmarkSample
            .filter(CodingKeys.sessionId == sessionId)
            .order(CodingKeys.timestamp.asc)
            .fetchAll(db)
    }

    /// Fetch samples in a time range
    static func fetchInRange(
        db: Database,
        sessionId: Int64,
        from: Date,
        to: Date
    ) throws -> [BenchmarkSample] {
        try BenchmarkSample
            .filter(CodingKeys.sessionId == sessionId)
            .filter(CodingKeys.timestamp >= from && CodingKeys.timestamp <= to)
            .order(CodingKeys.timestamp.asc)
            .fetchAll(db)
    }

    /// Delete samples for a session
    static func deleteForSession(db: Database, sessionId: Int64) throws {
        try BenchmarkSample
            .filter(CodingKeys.sessionId == sessionId)
            .deleteAll(db)
    }

    /// Get statistics for a session
    static func statistics(db: Database, sessionId: Int64) throws -> SampleStatistics? {
        let samples = try fetchForSession(db: db, sessionId: sessionId)
        guard !samples.isEmpty else { return nil }

        let gpuValues = samples.compactMap { $0.gpuUtilization }
        let cpuValues = samples.compactMap { $0.cpuUtilization }
        let tpsValues = samples.compactMap { $0.cumulativeTokensPerSecond }

        return SampleStatistics(
            sampleCount: samples.count,
            avgGpuUtilization: gpuValues.isEmpty ? nil : gpuValues.reduce(0, +) / Double(gpuValues.count),
            maxGpuUtilization: gpuValues.max(),
            avgCpuUtilization: cpuValues.isEmpty ? nil : cpuValues.reduce(0, +) / Double(cpuValues.count),
            maxCpuUtilization: cpuValues.max(),
            avgTokensPerSecond: tpsValues.isEmpty ? nil : tpsValues.reduce(0, +) / Double(tpsValues.count),
            peakTokensPerSecond: tpsValues.max()
        )
    }
}

// MARK: - Statistics

/// Aggregated statistics from benchmark samples
struct SampleStatistics {
    let sampleCount: Int
    let avgGpuUtilization: Double?
    let maxGpuUtilization: Double?
    let avgCpuUtilization: Double?
    let maxCpuUtilization: Double?
    let avgTokensPerSecond: Double?
    let peakTokensPerSecond: Double?
}

// MARK: - Chart Data

extension BenchmarkSample {
    /// Convert samples to chart-friendly data points
    static func chartData(from samples: [BenchmarkSample]) -> BenchmarkChartData {
        var gpuPoints: [(Date, Double)] = []
        var cpuPoints: [(Date, Double)] = []
        var memoryPoints: [(Date, Double)] = []
        var tpsPoints: [(Date, Double)] = []

        for sample in samples {
            if let gpu = sample.gpuUtilization {
                gpuPoints.append((sample.timestamp, gpu * 100))
            }
            if let cpu = sample.cpuUtilization {
                cpuPoints.append((sample.timestamp, cpu * 100))
            }
            if let memUsed = sample.memoryUsedBytes {
                // Store as GB for charting (raw bytes / 1 billion)
                let memGB = Double(memUsed) / 1_000_000_000.0
                memoryPoints.append((sample.timestamp, memGB))
            }
            if let tps = sample.cumulativeTokensPerSecond {
                tpsPoints.append((sample.timestamp, tps))
            }
        }

        return BenchmarkChartData(
            gpuUtilization: gpuPoints,
            cpuUtilization: cpuPoints,
            memoryUtilization: memoryPoints,
            tokensPerSecond: tpsPoints
        )
    }
}

/// Chart-ready data from benchmark samples
struct BenchmarkChartData {
    let gpuUtilization: [(Date, Double)]
    let cpuUtilization: [(Date, Double)]
    let memoryUtilization: [(Date, Double)]
    let tokensPerSecond: [(Date, Double)]

    var isEmpty: Bool {
        gpuUtilization.isEmpty && cpuUtilization.isEmpty &&
        memoryUtilization.isEmpty && tokensPerSecond.isEmpty
    }
}
