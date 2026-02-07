//
//  OpenAICompatibleClient.swift
//  anubis
//
//  Created on 2026-01-26.
//

import Foundation

/// Client for OpenAI-compatible API endpoints (LM Studio, LocalAI, vLLM, etc.)
actor OpenAICompatibleClient: InferenceBackend {
    // MARK: - Properties

    let backendType: InferenceBackendType = .openai
    let configuration: BackendConfiguration

    private let baseURL: URL
    private let session: URLSession
    private let apiKey: String?

    // MARK: - Initialization

    init(configuration: BackendConfiguration) {
        self.configuration = configuration
        self.baseURL = Constants.URLs.parse(configuration.baseURL, fallback: Constants.URLs.openAIDefault)
        self.apiKey = configuration.apiKey

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: config)
    }

    // MARK: - InferenceBackend

    var isAvailable: Bool {
        get async {
            let health = await checkHealth()
            return health.isRunning
        }
    }

    func checkHealth() async -> BackendHealth {
        // Try to hit the models endpoint
        let url = baseURL.appendingPathComponent("v1/models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5

        if let apiKey = apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .unhealthy(error: "Not an HTTP response")
            }

            if httpResponse.statusCode == 200 {
                return .healthy(version: nil)
            } else if httpResponse.statusCode == 401 {
                return .unhealthy(error: "Authentication required")
            } else {
                return .unhealthy(error: "Status \(httpResponse.statusCode)")
            }
        } catch {
            return .unhealthy(error: error.localizedDescription)
        }
    }

    func listModels() async throws -> [ModelInfo] {
        let url = baseURL.appendingPathComponent("v1/models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        if let apiKey = apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnubisError.invalidResponse(details: "Not an HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            throw AnubisError.invalidResponse(details: "Status \(httpResponse.statusCode)")
        }

        let modelsResponse = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
        let configId = configuration.id
        return modelsResponse.data.map { model in
            ModelInfo(
                id: model.id,
                name: model.id,
                family: nil,
                parameterCount: nil,
                quantization: nil,
                sizeBytes: nil,
                contextLength: nil,
                backend: .openai,
                openAIConfigId: configId,
                path: nil,
                modifiedAt: nil
            )
        }
    }

    func generate(request: InferenceRequest) -> AsyncThrowingStream<InferenceChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await streamGenerate(request: request, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Private Methods

    private func streamGenerate(
        request: InferenceRequest,
        continuation: AsyncThrowingStream<InferenceChunk, Error>.Continuation
    ) async throws {
        let url = baseURL.appendingPathComponent("v1/chat/completions")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let apiKey = apiKey, !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        var messages: [[String: String]] = []
        if let systemPrompt = request.systemPrompt {
            messages.append(["role": "system", "content": systemPrompt])
        }
        messages.append(["role": "user", "content": request.prompt])

        let body = OpenAIChatRequest(
            model: request.model,
            messages: messages,
            stream: true,
            maxTokens: request.maxTokens,
            temperature: request.temperature,
            topP: request.topP,
            stop: request.stopSequences
        )

        urlRequest.httpBody = try JSONEncoder().encode(body)

        let (bytes, response) = try await session.bytes(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnubisError.invalidResponse(details: "Not an HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            // Try to read error body for better diagnostics
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
                if errorBody.count > 500 { break } // Limit error body size
            }
            throw AnubisError.invalidResponse(details: "Status \(httpResponse.statusCode): \(errorBody)")
        }

        var totalTokens = 0
        let startTime = Date()

        for try await line in bytes.lines {
            // SSE format: "data: {...}" or "data: [DONE]"
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))

            if jsonString == "[DONE]" {
                let duration = Date().timeIntervalSince(startTime)
                let stats = InferenceStats(
                    totalTokens: totalTokens,
                    promptTokens: 0,  // Not provided in streaming
                    completionTokens: totalTokens,
                    totalDuration: duration,
                    promptEvalDuration: 0,
                    evalDuration: duration,
                    loadDuration: 0,
                    contextLength: 0
                )
                continuation.yield(InferenceChunk(text: "", done: true, stats: stats))
                continuation.finish()
                return
            }

            guard let data = jsonString.data(using: .utf8) else { continue }

            do {
                let chunk = try JSONDecoder().decode(OpenAIChatStreamResponse.self, from: data)
                let content = chunk.choices.first?.delta.content

                if let content = content, !content.isEmpty {
                    totalTokens += 1  // Approximate token count
                    continuation.yield(InferenceChunk(text: content, done: false, stats: nil))
                }

                // Check finish_reason - generation complete before [DONE]
                if let finishReason = chunk.choices.first?.finishReason,
                   finishReason == "stop" || finishReason == "length" {
                    let duration = Date().timeIntervalSince(startTime)
                    let stats = InferenceStats(
                        totalTokens: totalTokens,
                        promptTokens: 0,
                        completionTokens: totalTokens,
                        totalDuration: duration,
                        promptEvalDuration: 0,
                        evalDuration: duration,
                        loadDuration: 0,
                        contextLength: 0
                    )
                    continuation.yield(InferenceChunk(text: "", done: true, stats: stats))
                    continuation.finish()
                    return
                }
            } catch {
                // Skip malformed chunks
                continue
            }
        }

        continuation.finish()
    }
}

// MARK: - OpenAI API Types

private struct OpenAIModelsResponse: Codable {
    let data: [OpenAIModel]
}

private struct OpenAIModel: Codable {
    let id: String
    let object: String?
    let created: Int?
    let ownedBy: String?

    enum CodingKeys: String, CodingKey {
        case id, object, created
        case ownedBy = "owned_by"
    }
}

private struct OpenAIChatRequest: Codable {
    let model: String
    let messages: [[String: String]]
    let stream: Bool
    let maxTokens: Int?
    let temperature: Double?
    let topP: Double?
    let stop: [String]?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature, stop
        case maxTokens = "max_tokens"
        case topP = "top_p"
    }
}

private struct OpenAIChatStreamResponse: Codable {
    let id: String?
    let object: String?
    let created: Int?
    let model: String?
    let choices: [OpenAIStreamChoice]
}

private struct OpenAIStreamChoice: Codable {
    let index: Int?
    let delta: OpenAIDelta
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case index, delta
        case finishReason = "finish_reason"
    }
}

private struct OpenAIDelta: Codable {
    let role: String?
    let content: String?
}
