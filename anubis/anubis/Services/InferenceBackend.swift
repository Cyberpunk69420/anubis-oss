//
//  InferenceBackend.swift
//  anubis
//
//  Created on 2026-01-25.
//

import Foundation

/// Protocol defining a backend capable of running inference
protocol InferenceBackend: Actor {
    /// The type of this backend
    var backendType: InferenceBackendType { get }

    /// Whether the backend is currently available
    var isAvailable: Bool { get async }

    /// List all available models
    func listModels() async throws -> [ModelInfo]

    /// Generate a streaming response for a prompt
    func generate(request: InferenceRequest) -> AsyncThrowingStream<InferenceChunk, Error>

    /// Check if the backend is healthy and responding
    func checkHealth() async -> BackendHealth
}

/// Health status of a backend
struct BackendHealth: Sendable {
    let isRunning: Bool
    let version: String?
    let error: String?
    let modelCount: Int?
    let checkedAt: Date

    static func healthy(version: String? = nil, modelCount: Int? = nil) -> BackendHealth {
        BackendHealth(isRunning: true, version: version, error: nil, modelCount: modelCount, checkedAt: Date())
    }

    static func unhealthy(error: String) -> BackendHealth {
        BackendHealth(isRunning: false, version: nil, error: error, modelCount: nil, checkedAt: Date())
    }
}

/// Extension providing default implementations
extension InferenceBackend {
    /// Generate a complete response (non-streaming)
    func generateComplete(request: InferenceRequest) async throws -> InferenceResponse {
        var fullText = ""
        var finalStats: InferenceStats?

        for try await chunk in generate(request: request) {
            fullText += chunk.text
            if chunk.done, let stats = chunk.stats {
                finalStats = stats
            }
        }

        guard let stats = finalStats else {
            throw AnubisError.streamingError(reason: "No completion stats received")
        }

        return InferenceResponse(
            text: fullText,
            stats: stats,
            model: request.model,
            backend: backendType
        )
    }
}
