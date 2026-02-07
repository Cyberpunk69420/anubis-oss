//
//  BackendConfiguration.swift
//  anubis
//
//  Created on 2026-01-26.
//

import Foundation
import Combine

/// Configuration for a backend endpoint
struct BackendConfiguration: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var type: BackendType
    var baseURL: String
    var isEnabled: Bool
    var apiKey: String?  // Optional API key for some servers

    enum BackendType: String, Codable, CaseIterable {
        case ollama = "ollama"
        case openaiCompatible = "openai"
        case mlx = "mlx"

        var displayName: String {
            switch self {
            case .ollama: return "Ollama"
            case .openaiCompatible: return "OpenAI Compatible"
            case .mlx: return "MLX"
            }
        }

        var icon: String {
            switch self {
            case .ollama: return "server.rack"
            case .openaiCompatible: return "globe"
            case .mlx: return "apple.logo"
            }
        }

        var supportsCustomURL: Bool {
            switch self {
            case .ollama, .openaiCompatible: return true
            case .mlx: return false
            }
        }
    }

    /// Default Ollama configuration
    static let defaultOllama = BackendConfiguration(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Ollama (Local)",
        type: .ollama,
        baseURL: "http://localhost:11434",
        isEnabled: true
    )

    /// Default MLX configuration
    static let defaultMLX = BackendConfiguration(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        name: "MLX",
        type: .mlx,
        baseURL: "http://127.0.0.1:8080",
        isEnabled: true
    )

    /// Example LM Studio configuration
    static let exampleLMStudio = BackendConfiguration(
        id: UUID(),
        name: "LM Studio",
        type: .openaiCompatible,
        baseURL: "http://localhost:1234",
        isEnabled: false
    )
}

/// Manages backend configurations
class BackendConfigurationManager: ObservableObject {
    @Published var configurations: [BackendConfiguration] {
        didSet {
            save()
        }
    }

    private let userDefaultsKey = "backend_configurations"

    init() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let configs = try? JSONDecoder().decode([BackendConfiguration].self, from: data) {
            self.configurations = configs
        } else {
            // Default configurations
            self.configurations = [
                .defaultOllama,
                .defaultMLX
            ]
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(configurations) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }

    func addConfiguration(_ config: BackendConfiguration) {
        configurations.append(config)
    }

    func removeConfiguration(_ config: BackendConfiguration) {
        // Don't allow removing default backends
        guard config.type == .openaiCompatible else { return }
        configurations.removeAll { $0.id == config.id }
    }

    func updateConfiguration(_ config: BackendConfiguration) {
        if let index = configurations.firstIndex(where: { $0.id == config.id }) {
            configurations[index] = config
        }
    }

    /// Get enabled configurations
    var enabledConfigurations: [BackendConfiguration] {
        configurations.filter { $0.isEnabled }
    }

    /// Get Ollama configuration (there should be exactly one)
    var ollamaConfig: BackendConfiguration? {
        configurations.first { $0.type == .ollama }
    }

    /// Get all OpenAI-compatible configurations
    var openAIConfigs: [BackendConfiguration] {
        configurations.filter { $0.type == .openaiCompatible && $0.isEnabled }
    }
}
