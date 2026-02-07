//
//  ArenaComparison.swift
//  anubis
//
//  Created on 2026-01-26.
//

import Foundation
@preconcurrency import GRDB

/// Winner of an Arena comparison
enum ArenaWinner: String, Codable, DatabaseValueConvertible {
    case modelA = "a"
    case modelB = "b"
    case tie = "tie"
}

/// Execution mode for Arena comparisons
enum ArenaExecutionMode: String, Codable {
    case sequential  // Run one after the other, unload between
    case parallel    // Run both simultaneously
}

/// An Arena comparison between two models
struct ArenaComparison: Identifiable, Codable, Hashable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "arena_comparison"

    var id: Int64?
    var sessionAId: Int64
    var sessionBId: Int64
    var prompt: String
    var systemPrompt: String?
    var executionMode: String
    var winner: ArenaWinner?
    var notes: String?
    var createdAt: Date

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case sessionAId = "session_a_id"
        case sessionBId = "session_b_id"
        case prompt
        case systemPrompt = "system_prompt"
        case executionMode = "execution_mode"
        case winner
        case notes
        case createdAt = "created_at"
    }

    init(
        sessionAId: Int64,
        sessionBId: Int64,
        prompt: String,
        systemPrompt: String? = nil,
        executionMode: ArenaExecutionMode
    ) {
        self.id = nil
        self.sessionAId = sessionAId
        self.sessionBId = sessionBId
        self.prompt = prompt
        self.systemPrompt = systemPrompt
        self.executionMode = executionMode.rawValue
        self.winner = nil
        self.notes = nil
        self.createdAt = Date()
    }

    var executionModeType: ArenaExecutionMode {
        ArenaExecutionMode(rawValue: executionMode) ?? .sequential
    }

    // MARK: - MutablePersistableRecord

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Database Operations

extension ArenaComparison {
    /// Fetch all comparisons ordered by date
    static func fetchAllOrdered(db: Database) throws -> [ArenaComparison] {
        try ArenaComparison
            .order(CodingKeys.createdAt.desc)
            .fetchAll(db)
    }

    /// Fetch recent comparisons
    static func fetchRecent(db: Database, limit: Int = 20) throws -> [ArenaComparison] {
        try ArenaComparison
            .order(CodingKeys.createdAt.desc)
            .limit(limit)
            .fetchAll(db)
    }

    /// Fetch comparison with both sessions
    static func fetchWithSessions(db: Database, id: Int64) throws -> (ArenaComparison, BenchmarkSession?, BenchmarkSession?)? {
        guard let comparison = try ArenaComparison.fetchOne(db, key: id) else {
            return nil
        }
        let sessionA = try BenchmarkSession.fetchOne(db, key: comparison.sessionAId)
        let sessionB = try BenchmarkSession.fetchOne(db, key: comparison.sessionBId)
        return (comparison, sessionA, sessionB)
    }

    /// Update winner
    mutating func setWinner(_ winner: ArenaWinner?, notes: String? = nil) {
        self.winner = winner
        if let notes = notes {
            self.notes = notes
        }
    }
}

// MARK: - Comparison Result

/// A fully loaded comparison with both sessions
struct ArenaComparisonResult {
    let comparison: ArenaComparison
    let sessionA: BenchmarkSession
    let sessionB: BenchmarkSession

    var winnerSession: BenchmarkSession? {
        switch comparison.winner {
        case .modelA: return sessionA
        case .modelB: return sessionB
        case .tie, .none: return nil
        }
    }

    var loserSession: BenchmarkSession? {
        switch comparison.winner {
        case .modelA: return sessionB
        case .modelB: return sessionA
        case .tie, .none: return nil
        }
    }
}
