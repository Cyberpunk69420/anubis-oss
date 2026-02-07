//
//  InferenceChunk.swift
//  anubis
//
//  Created on 2026-01-25.
//

import Foundation

/// A chunk of streaming inference output
struct InferenceChunk: Sendable {
    /// The generated text fragment
    let text: String

    /// Whether this is the final chunk
    let done: Bool

    /// Token generation statistics (available when done)
    let stats: InferenceStats?

    /// Timestamp when this chunk was received
    let timestamp: Date

    init(text: String, done: Bool = false, stats: InferenceStats? = nil) {
        self.text = text
        self.done = done
        self.stats = stats
        self.timestamp = Date()
    }
}

/// Statistics from an inference run
struct InferenceStats: Sendable, Codable {
    /// Total tokens generated
    let totalTokens: Int

    /// Tokens in the prompt
    let promptTokens: Int

    /// Tokens generated in the response
    let completionTokens: Int

    /// Total time for inference in seconds
    let totalDuration: TimeInterval

    /// Time to process the prompt in seconds
    let promptEvalDuration: TimeInterval

    /// Time to generate tokens in seconds
    let evalDuration: TimeInterval

    /// Time to load the model in seconds (cold start indicator)
    let loadDuration: TimeInterval

    /// Number of context tokens used
    let contextLength: Int

    /// Tokens per second (completion)
    var tokensPerSecond: Double {
        guard evalDuration > 0 else { return 0 }
        return Double(completionTokens) / evalDuration
    }

    /// Average latency per token in milliseconds
    var averageTokenLatencyMs: Double {
        guard completionTokens > 0 else { return 0 }
        return (evalDuration * 1000) / Double(completionTokens)
    }

    /// Prompt processing speed (tokens/sec)
    var promptProcessingSpeed: Double {
        guard promptEvalDuration > 0 else { return 0 }
        return Double(promptTokens) / promptEvalDuration
    }
}

/// Request configuration for inference
struct InferenceRequest: Sendable {
    /// The model to use
    let model: String

    /// The prompt text
    let prompt: String

    /// System prompt (optional)
    let systemPrompt: String?

    /// Maximum tokens to generate
    let maxTokens: Int?

    /// Temperature for sampling (0.0 - 2.0)
    let temperature: Double?

    /// Top-p sampling parameter
    let topP: Double?

    /// Stop sequences
    let stopSequences: [String]?

    init(
        model: String,
        prompt: String,
        systemPrompt: String? = nil,
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        stopSequences: [String]? = nil
    ) {
        self.model = model
        self.prompt = prompt
        self.systemPrompt = systemPrompt
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.stopSequences = stopSequences
    }
}

/// Response from a complete inference run
struct InferenceResponse: Sendable {
    /// The complete generated text
    let text: String

    /// Statistics from the run
    let stats: InferenceStats

    /// The model used
    let model: String

    /// Backend that processed the request
    let backend: InferenceBackendType
}
