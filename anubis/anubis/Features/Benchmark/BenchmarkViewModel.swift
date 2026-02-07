//
//  BenchmarkViewModel.swift
//  anubis
//
//  Created on 2026-01-25.
//

import Foundation
import Combine
import GRDB
import os

/// Separate observable for chart data so chart updates don't trigger
/// re-evaluation of text streaming or other UI elements.
@MainActor
final class BenchmarkChartStore: ObservableObject {
    @Published private(set) var chartData: BenchmarkChartData = BenchmarkChartData(
        gpuUtilization: [],
        cpuUtilization: [],
        memoryUtilization: [],
        tokensPerSecond: []
    )

    func update(_ data: BenchmarkChartData) {
        chartData = data
    }

    func reset() {
        chartData = BenchmarkChartData(gpuUtilization: [], cpuUtilization: [], memoryUtilization: [], tokensPerSecond: [])
    }
}

/// ViewModel for the Benchmark module
/// Manages benchmark sessions, coordinates inference with metrics collection
@MainActor
final class BenchmarkViewModel: ObservableObject {
    // MARK: - Published State

    /// Current benchmark session (if running or just completed)
    @Published private(set) var currentSession: BenchmarkSession?

    /// Whether a benchmark is currently running
    @Published private(set) var isRunning = false

    /// Current real-time metrics during benchmark
    @Published private(set) var currentMetrics: SystemMetrics?

    /// Accumulated response text
    @Published private(set) var responseText = ""

    /// Current tokens per second (real-time average)
    @Published private(set) var currentTokensPerSecond: Double = 0

    /// Peak tokens per second observed during benchmark
    @Published private(set) var peakTokensPerSecond: Double = 0

    /// Time to first token (live tracking)
    @Published private(set) var timeToFirstToken: TimeInterval?

    /// Peak memory usage during benchmark
    @Published private(set) var currentPeakMemory: Int64 = 0

    /// Model memory info (from Ollama /api/ps)
    @Published private(set) var modelMemoryTotal: Int64 = 0
    @Published private(set) var modelMemoryGPU: Int64 = 0
    @Published private(set) var modelMemoryCPU: Int64 = 0

    /// Total tokens generated so far
    @Published private(set) var tokensGenerated = 0

    /// Elapsed time since benchmark start
    @Published private(set) var elapsedTime: TimeInterval = 0

    /// Available models for selection
    @Published private(set) var availableModels: [ModelInfo] = []

    /// Selected model for benchmark
    @Published var selectedModel: ModelInfo?

    /// Selected backend (synced with inferenceService)
    @Published var selectedBackend: InferenceBackendType = .ollama {
        didSet {
            if oldValue != selectedBackend {
                // Sync with inference service
                inferenceService.setBackend(selectedBackend)
            }
        }
    }

    /// Active connection name (resolved from backend + config)
    var connectionName: String {
        switch selectedBackend {
        case .ollama:
            return inferenceService.configManager.ollamaConfig?.name ?? "Ollama"
        case .openai:
            return inferenceService.currentOpenAIConfig?.name ?? "OpenAI Compatible"
        case .mlx:
            return inferenceService.configManager.configurations.first(where: { $0.type == .mlx })?.name ?? "MLX"
        }
    }

    /// Active connection URL (resolved from backend + config)
    var connectionURL: String {
        switch selectedBackend {
        case .ollama:
            return inferenceService.configManager.ollamaConfig?.baseURL ?? "http://localhost:11434"
        case .openai:
            return inferenceService.currentOpenAIConfig?.baseURL ?? "—"
        case .mlx:
            return inferenceService.configManager.configurations.first(where: { $0.type == .mlx })?.baseURL ?? "—"
        }
    }

    /// Prompt text for benchmark
    @Published var promptText = "Explain the concept of recursion in programming with a simple example."

    /// System prompt (optional)
    @Published var systemPrompt = ""

    // MARK: - Generation Parameters

    /// Temperature for sampling (0.0 - 2.0)
    @Published var temperature: Double = 0.7

    /// Top-p sampling parameter (0.0 - 1.0)
    @Published var topP: Double = 0.9

    /// Maximum tokens to generate
    @Published var maxTokens: Int = 2048

    /// Debug inspector state
    @Published private(set) var debugState = DebugInspectorState()

    /// Error state
    @Published private(set) var error: AnubisError?

    /// Historical sessions
    @Published private(set) var recentSessions: [BenchmarkSession] = []

    /// Collected samples for current session (internal, not directly observed)
    private var currentSamplesInternal: [BenchmarkSample] = []

    /// Chart data lives in a separate observable to avoid invalidating the
    /// entire view hierarchy (especially text streaming) on every chart update.
    let chartStore = BenchmarkChartStore()

    // MARK: - Dependencies

    private let inferenceService: InferenceService
    private let metricsService: MetricsService
    let databaseManager: DatabaseManager

    private var benchmarkTask: Task<Void, Never>?
    private var metricsSubscription: AnyCancellable?
    private var elapsedTimer: Timer?
    private var benchmarkStartTime: Date?
    private var sampleTimer: Timer?
    private var uiUpdateTimer: Timer?

    // Sampling configuration
    private let sampleInterval: TimeInterval = 0.5   // Sample metrics at 2Hz (was 0.1s/10Hz — reduced to match MetricsService polling)
    private let uiUpdateInterval: TimeInterval = 0.1  // 10 FPS for smooth text streaming
    private let chartUpdateInterval: TimeInterval = 0.5  // Charts update at 2Hz (aligned with sample rate)
    private var lastChartUpdate: Date = .distantPast
    private let maxChartDataPoints = 250  // Limit chart points to keep rendering fast

    // Buffers for batched UI updates (non-published for performance)
    private var textBuffer: String = ""
    private var pendingTokenCount: Int = 0
    private var pendingTps: Double = 0
    private var pendingPeakTps: Double = 0

    // Batched DB writes — accumulate samples in memory, flush periodically
    private var pendingDBSamples: [BenchmarkSample] = []
    private let dbFlushInterval: TimeInterval = 5.0
    private var lastDBFlush: Date = .distantPast

    private var backendSubscriptions: [AnyCancellable] = []

    // MARK: - Initialization

    init(
        inferenceService: InferenceService,
        metricsService: MetricsService,
        databaseManager: DatabaseManager
    ) {
        self.inferenceService = inferenceService
        self.metricsService = metricsService
        self.databaseManager = databaseManager

        // Initialize from current backend
        self.selectedBackend = inferenceService.currentBackend

        setupMetricsSubscription()
        setupBackendSubscription()
    }

    private func setupBackendSubscription() {
        // Observe changes to inferenceService's currentBackend
        inferenceService.$currentBackend
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newBackend in
                guard let self = self else { return }
                if self.selectedBackend != newBackend {
                    self.selectedBackend = newBackend
                    Task {
                        await self.loadModels()
                    }
                }
            }
            .store(in: &backendSubscriptions)

        // Observe changes to the selected OpenAI config (switching between
        // two OpenAI-compatible backends keeps currentBackend == .openai,
        // so we need a separate subscription to detect config changes)
        inferenceService.$currentOpenAIConfig
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self, self.selectedBackend == .openai else { return }
                Task {
                    await self.loadModels()
                }
            }
            .store(in: &backendSubscriptions)
    }

    // MARK: - Public Methods

    /// Load available models from current backend
    func loadModels() async {
        // Refresh models from all backends first
        await inferenceService.refreshAllModels()

        // Sync selected backend with inference service's current backend
        selectedBackend = inferenceService.currentBackend

        // Get models for current backend (properly filters by OpenAI config ID if applicable)
        availableModels = inferenceService.modelsForCurrentBackend()

        // If switching backends and current model isn't available, select first available
        if selectedModel == nil || !availableModels.contains(where: { $0.id == selectedModel?.id }) {
            selectedModel = availableModels.first
        }

        // Check backend health
        if availableModels.isEmpty {
            let health: BackendHealth?
            if selectedBackend == .openai, let configId = inferenceService.currentOpenAIConfig?.id {
                health = inferenceService.openAIBackendHealth[configId]
            } else {
                health = inferenceService.backendHealth[selectedBackend]
            }
            if health?.isRunning != true {
                self.error = .backendNotRunning(backend: selectedBackend.rawValue)
            }
        }
    }

    /// Start a benchmark session
    func startBenchmark() {
        guard !isRunning else { return }
        guard let model = selectedModel else {
            error = .modelLoadFailed(modelId: "none", reason: "No model selected")
            return
        }

        // Reset state
        responseText = ""
        tokensGenerated = 0
        currentTokensPerSecond = 0
        peakTokensPerSecond = 0
        timeToFirstToken = nil
        currentPeakMemory = 0
        modelMemoryTotal = 0
        modelMemoryGPU = 0
        modelMemoryCPU = 0
        elapsedTime = 0
        debugState.reset()
        error = nil
        currentSamplesInternal = []
        chartStore.reset()

        // Reset buffers
        textBuffer = ""
        pendingTokenCount = 0
        pendingTps = 0
        pendingPeakTps = 0
        lastChartUpdate = .distantPast
        pendingDBSamples = []
        lastDBFlush = .distantPast

        // Create session with connection name
        var session = BenchmarkSession(
            modelId: model.id,
            modelName: model.name,
            backend: selectedBackend,
            connectionName: connectionName,
            prompt: promptText
        )

        isRunning = true
        benchmarkStartTime = Date()
        currentSession = session

        // Start metrics collection
        metricsService.startCollecting()

        // Start elapsed timer
        startElapsedTimer()

        // Start UI update timer for batched updates
        startUIUpdateTimer()

        // Set the backend on inference service
        inferenceService.setBackend(selectedBackend)

        // Run inference
        benchmarkTask = Task {
            do {
                // Save session to get ID
                try await databaseManager.queue.write { db in
                    try session.insert(db)
                }
                currentSession = session

                // Now start proper sample collection with session ID
                if let sessionId = session.id {
                    startSampleCollection(sessionId: sessionId)
                }

                let request = InferenceRequest(
                    model: model.id,
                    prompt: promptText,
                    systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt,
                    maxTokens: maxTokens,
                    temperature: temperature,
                    topP: topP
                )

                // Initialize debug state
                self.debugState.backendType = self.selectedBackend
                self.debugState.endpointURL = self.connectionURL
                self.debugState.modelId = model.id
                self.debugState.requestTimestamp = Date()
                self.debugState.promptSnippet = String(self.promptText.prefix(200))
                self.debugState.systemPrompt = self.systemPrompt.isEmpty ? nil : self.systemPrompt
                self.debugState.maxTokens = self.maxTokens
                self.debugState.temperature = self.temperature
                self.debugState.topP = self.topP
                self.debugState.phase = .connecting
                self.debugState.requestJSON = DebugInspectorState.buildRequestJSON(
                    backend: self.selectedBackend, model: model.id, prompt: self.promptText,
                    systemPrompt: self.systemPrompt.isEmpty ? nil : self.systemPrompt,
                    maxTokens: self.maxTokens, temperature: self.temperature, topP: self.topP
                )

                var stats: InferenceStats?
                var tokenCount = 0
                var debugChunkCount = 0
                let startTime = Date()
                var firstTokenTime: Date?
                var peakMemory: Int64 = 0
                var lastSampleTime = startTime
                var lastSampleTokens = 0
                let instantaneousSampleInterval: TimeInterval = 0.25  // Calculate instantaneous rate every 250ms

                for try await chunk in inferenceService.generate(request: request) {
                    if Task.isCancelled { break }

                    // Track time to first token (update Published immediately - this is a one-time event)
                    if firstTokenTime == nil && !chunk.text.isEmpty {
                        firstTokenTime = Date()
                        timeToFirstToken = firstTokenTime!.timeIntervalSince(startTime)
                        self.debugState.firstChunkAt = firstTokenTime

                        // Fetch model memory now that model is loaded
                        await self.fetchModelMemory()
                    }

                    // Track peak memory (internal tracking)
                    let currentMemory = self.getCurrentMemoryUsage()
                    peakMemory = max(peakMemory, currentMemory)

                    // Buffer text and stats (don't update @Published on every token)
                    textBuffer += chunk.text
                    tokenCount += 1
                    debugChunkCount += 1
                    self.debugState.chunksReceived = debugChunkCount
                    self.debugState.bytesReceived += chunk.text.utf8.count
                    self.debugState.lastChunkAt = Date()
                    self.debugState.phase = .streaming

                    let now = Date()
                    let totalElapsed = now.timeIntervalSince(startTime)

                    // Calculate cumulative average tok/s (buffer it)
                    if totalElapsed > 0 {
                        pendingTps = Double(tokenCount) / totalElapsed
                    }

                    // Calculate instantaneous tok/s for peak tracking
                    let sampleElapsed = now.timeIntervalSince(lastSampleTime)
                    if sampleElapsed >= instantaneousSampleInterval {
                        let tokensDelta = tokenCount - lastSampleTokens
                        let instantaneousTps = Double(tokensDelta) / sampleElapsed
                        pendingPeakTps = max(pendingPeakTps, instantaneousTps)
                        lastSampleTime = now
                        lastSampleTokens = tokenCount
                    }

                    // Update pending values for UI timer to flush
                    pendingTokenCount = tokenCount
                    currentPeakMemory = peakMemory

                    if chunk.done, let chunkStats = chunk.stats {
                        stats = chunkStats
                    }
                }

                // Final flush of any remaining buffered content
                flushUIUpdates()

                // Calculate TTFT
                let ttft: TimeInterval? = firstTokenTime.map { $0.timeIntervalSince(startTime) }

                // Complete session
                if let finalStats = stats {
                    session.complete(
                        with: finalStats,
                        response: responseText,
                        timeToFirstToken: ttft,
                        peakMemoryBytes: peakMemory > 0 ? peakMemory : nil
                    )
                } else {
                    // Create stats from our tracking
                    let duration = Date().timeIntervalSince(startTime)
                    let manualStats = InferenceStats(
                        totalTokens: tokenCount,
                        promptTokens: 0,
                        completionTokens: tokenCount,
                        totalDuration: duration,
                        promptEvalDuration: 0,
                        evalDuration: duration,
                        loadDuration: 0,
                        contextLength: 0
                    )
                    session.complete(
                        with: manualStats,
                        response: responseText,
                        timeToFirstToken: ttft,
                        peakMemoryBytes: peakMemory > 0 ? peakMemory : nil
                    )
                }

                // Update session in database
                try await databaseManager.queue.write { db in
                    try session.update(db)
                }

                currentSession = session
                self.debugState.phase = .complete
                self.debugState.completedAt = Date()
                if let finalStats = stats {
                    self.debugState.finalTokensPerSecond = finalStats.tokensPerSecond
                    self.debugState.finalTotalTokens = finalStats.totalTokens
                }
                await finishBenchmark()

            } catch is CancellationError {
                session.cancel()
                try? await databaseManager.queue.write { db in
                    try session.update(db)
                }
                currentSession = session
                await finishBenchmark()

            } catch {
                session.fail()
                try? await databaseManager.queue.write { db in
                    try session.update(db)
                }
                currentSession = session
                self.debugState.phase = .error
                self.debugState.errorMessage = error.localizedDescription
                self.debugState.completedAt = Date()
                self.error = .inferenceTimeout(after: elapsedTime)
                await finishBenchmark()
            }
        }
    }

    /// Stop the current benchmark
    func stopBenchmark() {
        benchmarkTask?.cancel()
        benchmarkTask = nil
    }

    /// Load recent benchmark sessions from database
    func loadRecentSessions() async {
        do {
            recentSessions = try await databaseManager.queue.read { db in
                try BenchmarkSession.fetchRecent(db: db, limit: 20)
            }
        } catch {
            Log.benchmark.error("Failed to load recent sessions: \(error.localizedDescription)")
        }
    }

    /// Load samples for a specific session
    func loadSamples(for session: BenchmarkSession) async -> [BenchmarkSample] {
        guard let sessionId = session.id else { return [] }
        do {
            return try await databaseManager.queue.read { db in
                try BenchmarkSample.fetchForSession(db: db, sessionId: sessionId)
            }
        } catch {
            Log.benchmark.error("Failed to load samples: \(error.localizedDescription)")
            return []
        }
    }

    /// Delete a session
    func deleteSession(_ session: BenchmarkSession) async {
        guard let sessionId = session.id else { return }
        do {
            try await databaseManager.queue.write { db in
                // Delete samples first
                try BenchmarkSample.deleteForSession(db: db, sessionId: sessionId)
                // Delete session
                try session.delete(db)
            }
            await loadRecentSessions()
        } catch {
            Log.benchmark.error("Failed to delete session: \(error.localizedDescription)")
        }
    }

    /// Delete all sessions
    func deleteAllSessions() async {
        do {
            try await databaseManager.queue.write { db in
                // Delete all samples
                try db.execute(sql: "DELETE FROM benchmark_sample")
                // Delete all sessions
                try db.execute(sql: "DELETE FROM benchmark_session")
            }
            recentSessions = []
        } catch {
            Log.benchmark.error("Failed to delete all sessions: \(error.localizedDescription)")
        }
    }

    /// Mark a session as cancelled
    func markSessionCancelled(_ session: BenchmarkSession) async {
        guard let sessionId = session.id else { return }
        do {
            try await databaseManager.queue.write { db in
                try db.execute(
                    sql: "UPDATE benchmark_session SET status = ?, ended_at = ? WHERE id = ?",
                    arguments: [BenchmarkStatus.cancelled.rawValue, Date(), sessionId]
                )
            }
            await loadRecentSessions()
        } catch {
            Log.benchmark.error("Failed to mark session as cancelled: \(error.localizedDescription)")
        }
    }

    /// Clean up all running sessions (mark as cancelled)
    func cleanupRunningSessions() async {
        do {
            try await databaseManager.queue.write { db in
                try db.execute(
                    sql: "UPDATE benchmark_session SET status = ?, ended_at = ? WHERE status = ?",
                    arguments: [BenchmarkStatus.cancelled.rawValue, Date(), BenchmarkStatus.running.rawValue]
                )
            }
            await loadRecentSessions()
        } catch {
            Log.benchmark.error("Failed to cleanup running sessions: \(error.localizedDescription)")
        }
    }

    /// Get chart data for current samples (uses cached data for performance)
    func getChartData() -> BenchmarkChartData {
        chartStore.chartData
    }

    /// Get the current samples (for history/export)
    var currentSamples: [BenchmarkSample] {
        currentSamplesInternal
    }

    // MARK: - Private Methods

    private func setupMetricsSubscription() {
        metricsSubscription = metricsService.$currentMetrics
            .receive(on: DispatchQueue.main)
            .sink { [weak self] metrics in
                self?.currentMetrics = metrics
            }
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        // Update at 1Hz — display only shows seconds, no need for 10Hz updates
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, let startTime = self.benchmarkStartTime else { return }
                self.elapsedTime = Date().timeIntervalSince(startTime)
            }
        }
    }

    private func startUIUpdateTimer() {
        uiUpdateTimer?.invalidate()
        uiUpdateTimer = Timer.scheduledTimer(withTimeInterval: uiUpdateInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.flushUIUpdates()
            }
        }
    }

    /// Flush buffered updates to @Published properties (called at fixed interval)
    private func flushUIUpdates() {
        // Only flush if there's new content
        if !textBuffer.isEmpty {
            responseText += textBuffer
            textBuffer = ""
        }

        // Update numeric values
        if pendingTokenCount != tokensGenerated {
            tokensGenerated = pendingTokenCount
        }
        if pendingTps != currentTokensPerSecond {
            currentTokensPerSecond = pendingTps
        }
        if pendingPeakTps != peakTokensPerSecond {
            peakTokensPerSecond = pendingPeakTps
        }
    }

    /// Fetch model memory breakdown from Ollama /api/ps
    private func fetchModelMemory() async {
        guard selectedBackend == .ollama else { return }

        let ollamaClient = inferenceService.ollamaClient

        do {
            let runningModels = try await ollamaClient.listRunningModels()

            // Find the current model (or just take the first one if only one loaded)
            if let running = runningModels.first(where: { $0.name == selectedModel?.id }) ?? runningModels.first {
                modelMemoryTotal = running.sizeBytes
                modelMemoryGPU = running.sizeVRAM
                modelMemoryCPU = running.sizeBytes - running.sizeVRAM
            }
        } catch {
            Log.benchmark.warning("Failed to fetch model memory: \(error.localizedDescription)")
        }
    }

    private func startSampleCollection(sessionId: Int64) {
        sampleTimer?.invalidate()

        sampleTimer = Timer.scheduledTimer(withTimeInterval: sampleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.collectSample(sessionId: sessionId)
            }
        }
    }

    private func collectSample(sessionId: Int64) async {
        guard isRunning else { return }

        // Read cached metrics — NO system calls, just a property read
        guard let metrics = metricsService.latestMetrics else { return }

        // Use current wall-clock time, not the cached metrics timestamp.
        // The cached metrics may have been collected at a slightly different time,
        // and multiple samples can read the same cached object. Using our own
        // timestamp ensures monotonically increasing x-values for charts.
        // Combine Ollama process memory with model memory footprint (from /api/ps)
        // so the chart shows total memory used by the model + server
        let combinedMemory = metrics.memoryUsedBytes + modelMemoryTotal

        var sample = BenchmarkSample(
            sessionId: sessionId,
            timestamp: Date(),
            gpuUtilization: metrics.gpuUtilization,
            cpuUtilization: metrics.cpuUtilization,
            memoryUsedBytes: combinedMemory,
            memoryTotalBytes: metrics.memoryTotalBytes,
            thermalState: metrics.thermalState.rawValue,
            tokensGenerated: pendingTokenCount,
            cumulativeTokensPerSecond: pendingTps
        )

        // Assign a local ID for in-memory tracking (DB will assign real ID on flush)
        currentSamplesInternal.append(sample)
        pendingDBSamples.append(sample)

        // Flush to database periodically (every 5s) instead of on every sample
        let now = Date()
        if now.timeIntervalSince(lastDBFlush) >= dbFlushInterval {
            await flushSamplesToDatabase()
        }

        // Update chart data at throttled rate
        if now.timeIntervalSince(lastChartUpdate) >= chartUpdateInterval {
            lastChartUpdate = now

            let samples = currentSamplesInternal
            let maxPoints = maxChartDataPoints
            Task.detached(priority: .utility) {
                let samplesToUse: [BenchmarkSample]
                if samples.count > maxPoints {
                    let stride = samples.count / maxPoints
                    samplesToUse = samples.enumerated().compactMap { index, sample in
                        index % stride == 0 || index == samples.count - 1 ? sample : nil
                    }
                } else {
                    samplesToUse = samples
                }

                let newChartData = BenchmarkSample.chartData(from: samplesToUse)

                await MainActor.run {
                    self.chartStore.update(newChartData)
                }
            }
        }
    }

    /// Flush accumulated samples to database in a single batch write
    private func flushSamplesToDatabase() async {
        guard !pendingDBSamples.isEmpty else { return }
        let samplesToWrite = pendingDBSamples
        pendingDBSamples = []
        lastDBFlush = Date()

        // Write all pending samples in one transaction — off the hot path
        Task.detached(priority: .utility) { [databaseManager] in
            do {
                try await databaseManager.queue.write { db in
                    for var sample in samplesToWrite {
                        try sample.insert(db)
                    }
                }
            } catch {
                Log.benchmark.error("Failed to flush samples to database: \(error.localizedDescription)")
            }
        }
    }

    private func finishBenchmark() async {
        isRunning = false
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        sampleTimer?.invalidate()
        sampleTimer = nil
        uiUpdateTimer?.invalidate()
        uiUpdateTimer = nil
        benchmarkStartTime = nil

        // Final flush of any remaining buffered content
        flushUIUpdates()

        // Flush any remaining samples to database before finishing
        await flushSamplesToDatabase()

        // Final chart update with all collected samples (on background thread)
        if !currentSamplesInternal.isEmpty {
            let samples = currentSamplesInternal
            Task.detached(priority: .userInitiated) {
                let newChartData = BenchmarkSample.chartData(from: samples)
                await MainActor.run {
                    self.chartStore.update(newChartData)
                }
            }
        }

        metricsService.stopCollecting()

        // Reload recent sessions
        await loadRecentSessions()
    }

    /// Get current process memory usage in bytes
    private func getCurrentMemoryUsage() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.resident_size) : 0
    }
}

// MARK: - Convenience Extensions

extension BenchmarkViewModel {
    /// Formatted elapsed time string
    var formattedElapsedTime: String {
        Formatters.duration(elapsedTime)
    }

    /// Formatted tokens per second (average)
    var formattedTokensPerSecond: String {
        // Use final stats if completed, otherwise use real-time
        if let session = currentSession, session.status == .completed, let tps = session.tokensPerSecond {
            return Formatters.tokensPerSecond(tps)
        }
        return Formatters.tokensPerSecond(currentTokensPerSecond)
    }

    /// Formatted peak tokens per second
    var formattedPeakTokensPerSecond: String {
        Formatters.tokensPerSecond(peakTokensPerSecond)
    }

    /// Formatted memory usage (process memory - not very useful)
    var formattedMemoryUsage: String? {
        guard let metrics = currentMetrics else { return nil }
        return Formatters.bytes(metrics.memoryUsedBytes)
    }

    /// Formatted total memory (model + process)
    var formattedTotalMemory: String {
        let processMemory = currentMetrics?.memoryUsedBytes ?? 0
        let total = modelMemoryTotal + processMemory
        if total > 0 {
            return Formatters.bytes(total)
        }
        return "—"
    }

    /// Formatted model memory with GPU/CPU breakdown
    var formattedModelMemory: String {
        guard modelMemoryTotal > 0 else { return "—" }
        return Formatters.bytes(modelMemoryTotal)
    }

    /// Formatted GPU memory portion
    var formattedGPUMemory: String {
        guard modelMemoryGPU > 0 else { return "—" }
        return Formatters.bytes(modelMemoryGPU)
    }

    /// Formatted CPU memory portion
    var formattedCPUMemory: String {
        guard modelMemoryCPU > 0 else { return "—" }
        return Formatters.bytes(modelMemoryCPU)
    }

    /// GPU memory percentage of total model memory
    var gpuMemoryPercent: Double {
        guard modelMemoryTotal > 0 else { return 0 }
        return Double(modelMemoryGPU) / Double(modelMemoryTotal)
    }

    /// Whether model memory info is available
    var hasModelMemory: Bool {
        modelMemoryTotal > 0
    }

    /// GPU utilization percentage
    var gpuUtilizationPercent: Double {
        (currentMetrics?.gpuUtilization ?? 0) * 100
    }

    /// CPU utilization percentage
    var cpuUtilizationPercent: Double {
        (currentMetrics?.cpuUtilization ?? 0) * 100
    }

    /// Whether hardware metrics are available
    var hasHardwareMetrics: Bool {
        metricsService.isIOReportAvailable
    }
}
