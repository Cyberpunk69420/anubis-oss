//
//  MetricsService.swift
//  anubis
//
//  Created on 2026-01-25.
//

import Foundation
import Combine
import Darwin

// libproc constants not exposed in Swift
private let PROC_PIDPATHINFO_MAXSIZE: Int = 4096

// MARK: - Background Metrics Collector

/// Performs all expensive system calls (IOKit, proc_listpids, host_processor_info)
/// off the main thread. This actor serializes access to mutable state (PID cache,
/// CPU tick tracking) while keeping the work away from MainActor.
private actor MetricsCollector {
    // PID cache — avoids scanning all system PIDs on every sample
    private var cachedOllamaPID: pid_t?
    private var pidCacheTime: Date = .distantPast
    private let pidCacheTTL: TimeInterval = 5.0

    // CPU tick tracking for delta calculation
    private var previousCPUTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?

    /// One-time baseline sample for IOReport
    func establishBaseline(bridge: IOReportBridge) {
        _ = bridge.sample()
    }

    /// Collect a full metrics snapshot. All expensive work happens here, off MainActor.
    func collectMetrics(bridge: IOReportBridge) -> SystemMetrics {
        let processInfo = ProcessInfo.processInfo
        let memoryTotal = processInfo.physicalMemory

        // Get Ollama process memory (uses cached PID)
        let memoryUsed = getOllamaMemoryUsage()

        // IOKit GPU read
        let hardwareMetrics = bridge.sample()

        // CPU utilization
        let cpuUtilization: Double
        if hardwareMetrics.isAvailable && hardwareMetrics.cpuUtilization > 0 {
            cpuUtilization = hardwareMetrics.cpuUtilization
        } else {
            cpuUtilization = getCPUUtilization()
        }

        let gpuUtilization = hardwareMetrics.isAvailable ? hardwareMetrics.gpuUtilization : 0.0

        return SystemMetrics(
            timestamp: Date(),
            gpuUtilization: gpuUtilization,
            cpuUtilization: cpuUtilization,
            memoryUsedBytes: memoryUsed,
            memoryTotalBytes: Int64(memoryTotal),
            thermalState: ThermalState(from: processInfo.thermalState)
        )
    }

    func resetCPUTracking() {
        previousCPUTicks = nil
    }

    // MARK: - Private

    private func getOllamaMemoryUsage() -> Int64 {
        guard let pid = findOllamaPID() else { return 0 }
        return getProcessMemory(pid: pid)
    }

    /// Find Ollama PID with caching to avoid full process scan on every sample
    private func findOllamaPID() -> pid_t? {
        // Return cached PID if still valid
        let now = Date()
        if let cached = cachedOllamaPID, now.timeIntervalSince(pidCacheTime) < pidCacheTTL {
            // Quick validation — check the cached PID is still alive
            if getProcessMemory(pid: cached) > 0 {
                return cached
            }
            // PID died, invalidate cache
            cachedOllamaPID = nil
        }

        // Full scan
        let pid = scanForOllamaPID()
        cachedOllamaPID = pid
        pidCacheTime = now
        return pid
    }

    private func scanForOllamaPID() -> pid_t? {
        let bufferSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bufferSize > 0 else { return nil }

        let pidCount = bufferSize / Int32(MemoryLayout<pid_t>.size)
        var pids = [pid_t](repeating: 0, count: Int(pidCount))

        let actualSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, bufferSize)
        guard actualSize > 0 else { return nil }

        let actualCount = Int(actualSize) / MemoryLayout<pid_t>.size

        for i in 0..<actualCount {
            let pid = pids[i]
            guard pid > 0 else { continue }

            var pathBuffer = [CChar](repeating: 0, count: PROC_PIDPATHINFO_MAXSIZE)
            let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))

            if pathLength > 0 {
                let path = String(cString: pathBuffer)
                if path.hasSuffix("/ollama") || path.contains("/ollama.app/") {
                    return pid
                }
            }
        }

        // Also check for "Ollama" (GUI app) if CLI not found
        for i in 0..<actualCount {
            let pid = pids[i]
            guard pid > 0 else { continue }

            var pathBuffer = [CChar](repeating: 0, count: PROC_PIDPATHINFO_MAXSIZE)
            let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))

            if pathLength > 0 {
                let path = String(cString: pathBuffer)
                if path.contains("Ollama.app") && path.hasSuffix("Ollama") {
                    return pid
                }
            }
        }

        return nil
    }

    private func getProcessMemory(pid: pid_t) -> Int64 {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)
        return result == size ? Int64(info.pti_resident_size) : 0
    }

    private func getCPUUtilization() -> Double {
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0
        var numCPUs: natural_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCPUs,
            &cpuInfo,
            &numCPUInfo
        )

        guard result == KERN_SUCCESS, let cpuInfo = cpuInfo else {
            return 0.0
        }

        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), vm_size_t(numCPUInfo))
        }

        var totalUser: UInt64 = 0
        var totalSystem: UInt64 = 0
        var totalIdle: UInt64 = 0
        var totalNice: UInt64 = 0

        cpuInfo.withMemoryRebound(to: processor_cpu_load_info.self, capacity: Int(numCPUs)) { ptr in
            for i in 0..<Int(numCPUs) {
                totalUser += UInt64(ptr[i].cpu_ticks.0)
                totalSystem += UInt64(ptr[i].cpu_ticks.1)
                totalIdle += UInt64(ptr[i].cpu_ticks.2)
                totalNice += UInt64(ptr[i].cpu_ticks.3)
            }
        }

        guard let previous = previousCPUTicks else {
            previousCPUTicks = (totalUser, totalSystem, totalIdle, totalNice)
            return 0.0
        }

        let deltaUser = totalUser - previous.user
        let deltaSystem = totalSystem - previous.system
        let deltaIdle = totalIdle - previous.idle
        let deltaNice = totalNice - previous.nice

        previousCPUTicks = (totalUser, totalSystem, totalIdle, totalNice)

        let totalDelta = deltaUser + deltaSystem + deltaIdle + deltaNice
        guard totalDelta > 0 else { return 0.0 }

        let activeTime = deltaUser + deltaSystem + deltaNice
        return Double(activeTime) / Double(totalDelta)
    }
}

// MARK: - MetricsService

/// Service for collecting hardware and inference metrics
/// Integrates with IOReportBridge for GPU metrics on Apple Silicon (App Store compatible)
///
/// Expensive system calls (IOKit, proc_listpids, host_processor_info) run on a
/// background actor. Published properties are updated on MainActor. During benchmarks,
/// callers should read `latestMetrics` (cheap cached read) instead of `sampleOnce()`.
@MainActor
final class MetricsService: ObservableObject {
    // MARK: - Published State

    /// Current system metrics (updated on MainActor from background collection)
    @Published private(set) var currentMetrics: SystemMetrics?

    /// Whether metrics collection is active
    @Published private(set) var isCollecting = false

    /// Whether IOReport is available for hardware metrics
    @Published private(set) var isIOReportAvailable = false

    /// Polling interval in seconds
    @Published var pollingInterval: TimeInterval = 0.5

    // MARK: - Private Properties

    private var pollingTask: Task<Void, Never>?
    private var metricsHistory: [SystemMetrics] = []
    private let maxHistoryCount = 600 // 5 minutes at 0.5s intervals

    private let ioReportBridge = IOReportBridge.shared

    /// Background collector that does all expensive system calls off the main thread
    private let collector = MetricsCollector()

    // MARK: - Demo Mode Support

    /// Simulated GPU load for demo mode (ramps up/down during inference)
    private var demoSimulatedLoad: Double = 0.15
    private var demoLoadDirection: Double = 1.0

    // MARK: - Initialization

    init() {
        // In demo mode, always report IOReport as available
        isIOReportAvailable = DemoMode.isEnabled || ioReportBridge.isAvailable
        setupThermalStateObserver()
    }

    // MARK: - Collection Control

    /// Start collecting metrics
    func startCollecting() {
        guard !isCollecting else { return }
        isCollecting = true

        pollingTask = Task {
            // Use synthetic metrics in demo mode
            if DemoMode.isEnabled {
                while !Task.isCancelled && isCollecting {
                    let metrics = self.generateDemoMetrics()
                    self.currentMetrics = metrics
                    self.recordMetrics(metrics)
                    try? await Task.sleep(for: .seconds(pollingInterval))
                }
                return
            }

            // Initial IOReport sample to establish baseline (on background)
            if isIOReportAvailable {
                await collector.establishBaseline(bridge: ioReportBridge)
                try? await Task.sleep(for: .milliseconds(100))
            }

            while !Task.isCancelled && isCollecting {
                // Do all expensive work on background actor
                let metrics = await collector.collectMetrics(bridge: ioReportBridge)

                // Cheap MainActor update — just assign the result
                self.currentMetrics = metrics
                self.recordMetrics(metrics)

                try? await Task.sleep(for: .seconds(pollingInterval))
            }
        }
    }

    /// Stop collecting metrics
    func stopCollecting() {
        isCollecting = false
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Get historical metrics for charting
    func getHistory() -> [SystemMetrics] {
        metricsHistory
    }

    /// Clear historical metrics
    func clearHistory() {
        metricsHistory.removeAll()
        Task { await collector.resetCPUTracking() }
    }

    /// Returns the latest cached metrics without triggering any system calls.
    /// Use this during benchmarks to avoid blocking the main thread.
    var latestMetrics: SystemMetrics? {
        currentMetrics
    }

    /// Take a single sample. If collecting is active, returns cached value (free).
    /// Otherwise performs a full collection on the background actor.
    func sampleOnce() async -> SystemMetrics {
        if let cached = currentMetrics, isCollecting {
            return cached
        }
        // Use demo metrics in demo mode
        if DemoMode.isEnabled {
            return generateDemoMetrics()
        }
        return await collector.collectMetrics(bridge: ioReportBridge)
    }

    // MARK: - Private Methods

    private func recordMetrics(_ metrics: SystemMetrics) {
        metricsHistory.append(metrics)
        if metricsHistory.count > maxHistoryCount {
            metricsHistory.removeFirst()
        }
    }

    private func setupThermalStateObserver() {
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                let state = ProcessInfo.processInfo.thermalState
                if state == .serious || state == .critical {
                    self?.pollingInterval = 1.0
                } else {
                    self?.pollingInterval = 0.5
                }
            }
        }
    }
}

// MARK: - Metrics Snapshot for Benchmarking

extension MetricsService {
    /// Get current metrics along with inference data for benchmark recording
    func snapshotForBenchmark(
        tokensGenerated: Int,
        elapsedTime: TimeInterval
    ) -> BenchmarkMetricsSnapshot {
        let metrics = currentMetrics ?? SystemMetrics(
            timestamp: Date(),
            gpuUtilization: 0,
            cpuUtilization: 0,
            memoryUsedBytes: 0,
            memoryTotalBytes: Int64(ProcessInfo.processInfo.physicalMemory),
            thermalState: ThermalState(from: ProcessInfo.processInfo.thermalState)
        )
        let tokensPerSecond = elapsedTime > 0 ? Double(tokensGenerated) / elapsedTime : 0

        return BenchmarkMetricsSnapshot(
            timestamp: Date(),
            gpuUtilization: metrics.gpuUtilization,
            cpuUtilization: metrics.cpuUtilization,
            memoryUsedBytes: metrics.memoryUsedBytes,
            memoryTotalBytes: metrics.memoryTotalBytes,
            thermalState: metrics.thermalState,
            tokensGenerated: tokensGenerated,
            cumulativeTokensPerSecond: tokensPerSecond
        )
    }
}

/// Snapshot of metrics for benchmark recording
struct BenchmarkMetricsSnapshot: Sendable {
    let timestamp: Date
    let gpuUtilization: Double
    let cpuUtilization: Double
    let memoryUsedBytes: Int64
    let memoryTotalBytes: Int64
    let thermalState: ThermalState
    let tokensGenerated: Int
    let cumulativeTokensPerSecond: Double
}

// MARK: - Demo Mode Metrics Generation

extension MetricsService {
    /// Generate synthetic metrics for demo mode
    func generateDemoMetrics() -> SystemMetrics {
        // Update simulated load with smooth ramping
        updateDemoLoad()

        // Add some noise for realism
        let noise = Double.random(in: -0.03...0.03)

        // GPU utilization correlates with simulated load
        let gpuUtilization = min(1.0, max(0.0, demoSimulatedLoad * 0.75 + noise + 0.1))

        // CPU utilization is typically lower than GPU during inference
        let cpuUtilization = min(1.0, max(0.0, demoSimulatedLoad * 0.35 + noise + 0.08))

        // Memory usage: base + model size simulation
        let totalMemory = Int64(ProcessInfo.processInfo.physicalMemory)
        let baseMemory = Int64(4 * 1024 * 1024 * 1024) // 4GB base
        let modelMemory = Int64(Double(2 * 1024 * 1024 * 1024) * demoSimulatedLoad) // Up to 2GB
        let memoryUsed = min(baseMemory + modelMemory, totalMemory - 1024 * 1024 * 1024)

        return SystemMetrics(
            timestamp: Date(),
            gpuUtilization: gpuUtilization,
            cpuUtilization: cpuUtilization,
            memoryUsedBytes: memoryUsed,
            memoryTotalBytes: totalMemory,
            thermalState: .nominal
        )
    }

    /// Update simulated load with smooth ramping
    private func updateDemoLoad() {
        // Randomly change direction occasionally
        if Double.random(in: 0...1) < 0.08 {
            demoLoadDirection *= -1
        }

        // Update load with momentum
        demoSimulatedLoad += demoLoadDirection * Double.random(in: 0.02...0.06)

        // Clamp and bounce at boundaries
        if demoSimulatedLoad >= 0.8 {
            demoSimulatedLoad = 0.8
            demoLoadDirection = -1
        } else if demoSimulatedLoad <= 0.15 {
            demoSimulatedLoad = 0.15
            demoLoadDirection = 1
        }
    }

    /// Spike the load for demo mode (call when inference starts)
    func demoBumpLoad() {
        if DemoMode.isEnabled {
            demoSimulatedLoad = max(demoSimulatedLoad, 0.5)
            demoLoadDirection = 1
        }
    }
}
