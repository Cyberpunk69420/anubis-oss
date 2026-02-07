//
//  DemoInferenceBackend.swift
//  anubis
//
//  Created on 2026-01-31.
//

import Foundation

/// Mock inference backend for App Store demo mode
/// Simulates realistic LLM responses without requiring actual backend services
actor DemoInferenceBackend: InferenceBackend {
    let backendType: InferenceBackendType = .ollama

    var isAvailable: Bool {
        get async { true }
    }

    func listModels() async throws -> [ModelInfo] {
        // Simulate network delay
        try? await Task.sleep(for: .milliseconds(200))
        return DemoMode.mockModels
    }

    func generate(request: InferenceRequest) -> AsyncThrowingStream<InferenceChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await generateStream(request: request, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func checkHealth() async -> BackendHealth {
        .healthy(version: "0.5.4 (Demo)", modelCount: DemoMode.mockModels.count)
    }

    // MARK: - Private

    private func generateStream(
        request: InferenceRequest,
        continuation: AsyncThrowingStream<InferenceChunk, Error>.Continuation
    ) async throws {
        let startTime = Date()

        // Simulate model loading delay
        try await Task.sleep(for: .milliseconds(DemoMode.Config.modelLoadDelayMs))

        // Get response text
        let responseText = DemoMode.responseFor(prompt: request.prompt)

        // Tokenize into realistic chunks (words and punctuation)
        let tokens = tokenize(responseText)
        let promptTokenCount = tokenize(request.prompt).count

        // Stream tokens with realistic timing
        for (index, token) in tokens.enumerated() {
            // Check for cancellation
            if Task.isCancelled { break }

            // Variable delay for realistic feel
            let baseDelay = DemoMode.Config.tokenDelayMs
            let variation = UInt64.random(in: 0...DemoMode.Config.tokenDelayVariation)
            try await Task.sleep(for: .milliseconds(baseDelay + variation))

            let isLast = index == tokens.count - 1

            if isLast {
                // Final chunk with stats
                let endTime = Date()
                let totalDuration = endTime.timeIntervalSince(startTime)
                let evalDuration = totalDuration - Double(DemoMode.Config.modelLoadDelayMs) / 1000.0

                let stats = InferenceStats(
                    totalTokens: promptTokenCount + tokens.count,
                    promptTokens: promptTokenCount,
                    completionTokens: tokens.count,
                    totalDuration: totalDuration,
                    promptEvalDuration: 0.05, // ~50ms for prompt
                    evalDuration: max(0.1, evalDuration),
                    loadDuration: Double(DemoMode.Config.modelLoadDelayMs) / 1000.0,
                    contextLength: 8192
                )

                continuation.yield(InferenceChunk(text: token, done: true, stats: stats))
            } else {
                continuation.yield(InferenceChunk(text: token, done: false))
            }
        }

        continuation.finish()
    }

    /// Split text into tokens (words and punctuation for realistic streaming)
    private func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var currentWord = ""

        for char in text {
            if char.isWhitespace {
                if !currentWord.isEmpty {
                    tokens.append(currentWord)
                    currentWord = ""
                }
                tokens.append(String(char))
            } else if char.isPunctuation && !currentWord.isEmpty {
                tokens.append(currentWord)
                currentWord = ""
                tokens.append(String(char))
            } else {
                currentWord.append(char)
            }
        }

        if !currentWord.isEmpty {
            tokens.append(currentWord)
        }

        return tokens
    }
}
