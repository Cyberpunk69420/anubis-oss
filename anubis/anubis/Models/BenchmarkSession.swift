//
//  BenchmarkSession.swift
//  anubis
//
//  Created on 2026-01-25.
//

import Foundation
@preconcurrency import GRDB

/// Status of a benchmark session
enum BenchmarkStatus: String, Codable, DatabaseValueConvertible {
    case running
    case completed
    case failed
    case cancelled
}

/// A benchmark session recording inference performance
struct BenchmarkSession: Identifiable, Codable, Hashable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "benchmark_session"

    var id: Int64?
    var modelId: String
    var modelName: String
    var backend: String
    var startedAt: Date
    var endedAt: Date?
    var prompt: String
    var response: String?
    var totalTokens: Int?
    var promptTokens: Int?
    var completionTokens: Int?
    var tokensPerSecond: Double?
    var totalDuration: Double?
    var promptEvalDuration: Double?
    var evalDuration: Double?
    var status: BenchmarkStatus

    // New metrics
    var timeToFirstToken: Double?      // Seconds until first token received
    var loadDuration: Double?          // Model loading time (cold start indicator)
    var contextLength: Int?            // Number of context tokens used
    var peakMemoryBytes: Int64?        // Peak memory during benchmark
    var averageTokenLatencyMs: Double? // Average ms per token

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case modelId = "model_id"
        case modelName = "model_name"
        case backend
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case prompt
        case response
        case totalTokens = "total_tokens"
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case tokensPerSecond = "tokens_per_second"
        case totalDuration = "total_duration"
        case promptEvalDuration = "prompt_eval_duration"
        case evalDuration = "eval_duration"
        case status
        case timeToFirstToken = "time_to_first_token"
        case loadDuration = "load_duration"
        case contextLength = "context_length"
        case peakMemoryBytes = "peak_memory_bytes"
        case averageTokenLatencyMs = "avg_token_latency_ms"
    }

    /// Create a new benchmark session
    init(
        modelId: String,
        modelName: String,
        backend: InferenceBackendType,
        connectionName: String? = nil,
        prompt: String
    ) {
        self.id = nil
        self.modelId = modelId
        self.modelName = modelName
        self.backend = connectionName ?? backend.rawValue
        self.startedAt = Date()
        self.endedAt = nil
        self.prompt = prompt
        self.response = nil
        self.totalTokens = nil
        self.promptTokens = nil
        self.completionTokens = nil
        self.tokensPerSecond = nil
        self.totalDuration = nil
        self.promptEvalDuration = nil
        self.evalDuration = nil
        self.status = .running
        self.timeToFirstToken = nil
        self.loadDuration = nil
        self.contextLength = nil
        self.peakMemoryBytes = nil
        self.averageTokenLatencyMs = nil
    }

    /// Update session with inference stats
    mutating func complete(
        with stats: InferenceStats,
        response: String,
        timeToFirstToken: TimeInterval? = nil,
        peakMemoryBytes: Int64? = nil
    ) {
        self.endedAt = Date()
        self.response = response
        self.totalTokens = stats.totalTokens
        self.promptTokens = stats.promptTokens
        self.completionTokens = stats.completionTokens
        self.tokensPerSecond = stats.tokensPerSecond
        self.totalDuration = stats.totalDuration
        self.promptEvalDuration = stats.promptEvalDuration
        self.evalDuration = stats.evalDuration
        self.status = .completed
        self.timeToFirstToken = timeToFirstToken
        self.loadDuration = stats.loadDuration
        self.contextLength = stats.contextLength
        self.peakMemoryBytes = peakMemoryBytes
        self.averageTokenLatencyMs = stats.averageTokenLatencyMs
    }

    /// Mark session as failed
    mutating func fail() {
        self.endedAt = Date()
        self.status = .failed
    }

    /// Mark session as cancelled
    mutating func cancel() {
        self.endedAt = Date()
        self.status = .cancelled
    }

    /// Duration of the session
    var duration: TimeInterval? {
        guard let end = endedAt else { return nil }
        return end.timeIntervalSince(startedAt)
    }

    /// Backend type
    var backendType: InferenceBackendType? {
        InferenceBackendType(rawValue: backend)
    }

    // MARK: - MutablePersistableRecord

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Database Operations

extension BenchmarkSession {
    /// Fetch all sessions ordered by date
    static func fetchAllOrdered(db: Database) throws -> [BenchmarkSession] {
        try BenchmarkSession
            .order(CodingKeys.startedAt.desc)
            .fetchAll(db)
    }

    /// Fetch recent sessions
    static func fetchRecent(db: Database, limit: Int = 20) throws -> [BenchmarkSession] {
        try BenchmarkSession
            .order(CodingKeys.startedAt.desc)
            .limit(limit)
            .fetchAll(db)
    }

    /// Fetch sessions for a specific model
    static func fetchForModel(db: Database, modelId: String) throws -> [BenchmarkSession] {
        try BenchmarkSession
            .filter(CodingKeys.modelId == modelId)
            .order(CodingKeys.startedAt.desc)
            .fetchAll(db)
    }

    /// Fetch completed sessions only
    static func fetchCompleted(db: Database) throws -> [BenchmarkSession] {
        try BenchmarkSession
            .filter(CodingKeys.status == BenchmarkStatus.completed.rawValue)
            .order(CodingKeys.startedAt.desc)
            .fetchAll(db)
    }

    /// Delete old sessions keeping the most recent
    static func pruneOld(db: Database, keepCount: Int = 100) throws {
        let idsToKeep = try BenchmarkSession
            .select(CodingKeys.id)
            .order(CodingKeys.startedAt.desc)
            .limit(keepCount)
            .fetchAll(db)
            .compactMap { $0.id }

        if !idsToKeep.isEmpty {
            try BenchmarkSession
                .filter(!idsToKeep.contains(CodingKeys.id))
                .deleteAll(db)
        }
    }
}
