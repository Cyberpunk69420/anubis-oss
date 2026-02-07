//
//  BenchmarkView.swift
//  anubis
//
//  Created on 2026-01-25.
//

import SwiftUI
import Charts
import AppKit

/// Main benchmark dashboard view
struct BenchmarkView: View {
    @StateObject private var viewModel: BenchmarkViewModel
    @State private var showingHistory = false
    @State private var showingExpandedMetrics = false
    @State private var showSystemPrompt = false
    @State private var showParameters = false
    @State private var showLiveCharts = true

    init(
        inferenceService: InferenceService,
        metricsService: MetricsService,
        databaseManager: DatabaseManager
    ) {
        _viewModel = StateObject(wrappedValue: BenchmarkViewModel(
            inferenceService: inferenceService,
            metricsService: metricsService,
            databaseManager: databaseManager
        ))
    }

    var body: some View {
        HSplitView {
            // Left panel - Controls and Response
            VStack(spacing: 0) {
                controlsSection
                Divider()
                DebugInspectorPanel(debugState: viewModel.debugState) {
                    responseSection
                }
            }
            .frame(minWidth: 400, idealWidth: 500)

            // Right panel - Metrics Dashboard
            ScrollView {
                VStack(spacing: Spacing.md) {
                    metricsCardsSection
                    detailedStatsSection
                    chartsSection
                }
                .padding(Spacing.md)
            }
            .frame(minWidth: 400)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showingExpandedMetrics.toggle()
                } label: {
                    Label("Expand Results", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .help("Expand metrics dashboard")

                Button {
                    showingHistory.toggle()
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
            }
        }
        .sheet(isPresented: $showingHistory) {
            SessionHistoryView(viewModel: viewModel)
        }
        .sheet(isPresented: $showingExpandedMetrics) {
            ExpandedMetricsView(viewModel: viewModel)
        }
        .task {
            await viewModel.loadModels()
            await viewModel.loadRecentSessions()
        }
        .onChange(of: viewModel.selectedBackend) { _, _ in
            Task {
                await viewModel.loadModels()
            }
        }
    }

    // MARK: - Controls Section

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            // Model Selection
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.xs) {
                    Text("Model")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // Show current backend as badge
                    Text(viewModel.selectedBackend.displayName)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background {
                            Capsule()
                                .fill(Color.cardBackground)
                                .overlay {
                                    Capsule()
                                        .strokeBorder(Color.cardBorder, lineWidth: 0.5)
                                }
                        }

                    Text(viewModel.connectionURL)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                HStack(spacing: Spacing.md) {
                    Picker("Model", selection: $viewModel.selectedModel) {
                        if viewModel.availableModels.isEmpty {
                            Text("No models available").tag(nil as ModelInfo?)
                        } else {
                            ForEach(viewModel.availableModels) { model in
                                Text(model.name).tag(model as ModelInfo?)
                            }
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .frame(minWidth: 300, alignment: .leading)

                    Spacer()

                    // Refresh models button
                    Button {
                        Task { await viewModel.loadModels() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh model list")
                }
            }

            // System Prompt (collapsible)
            DisclosureGroup(isExpanded: $showSystemPrompt) {
                TextEditor(text: $viewModel.systemPrompt)
                    .font(.body)
                    .frame(height: 60)
                    .scrollContentBackground(.hidden)
                    .padding(Spacing.xs)
                    .background {
                        RoundedRectangle(cornerRadius: CornerRadius.md)
                            .fill(.regularMaterial)
                            .overlay {
                                RoundedRectangle(cornerRadius: CornerRadius.md)
                                    .strokeBorder(Color.cardBorder, lineWidth: 1)
                            }
                    }
                    .disabled(viewModel.isRunning)
            } label: {
                HStack {
                    Text("System Prompt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !viewModel.systemPrompt.isEmpty {
                        Text("(\(viewModel.systemPrompt.count) chars)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture { showSystemPrompt.toggle() }
            }

            // Generation parameters (collapsible)
            DisclosureGroup(isExpanded: $showParameters) {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    // Temperature
                    HStack {
                        Text("Temperature")
                            .font(.caption)
                            .frame(width: 80, alignment: .leading)
                        Slider(value: $viewModel.temperature, in: 0...2, step: 0.1)
                            .frame(width: 200)
                        Text(String(format: "%.1f", viewModel.temperature))
                            .font(.mono(11, weight: .medium))
                            .frame(width: 40, alignment: .trailing)
                    }

                    // Top-P
                    HStack {
                        Text("Top-P")
                            .font(.caption)
                            .frame(width: 80, alignment: .leading)
                        Slider(value: $viewModel.topP, in: 0...1, step: 0.05)
                            .frame(width: 200)
                        Text(String(format: "%.2f", viewModel.topP))
                            .font(.mono(11, weight: .medium))
                            .frame(width: 40, alignment: .trailing)
                    }

                    // Max Tokens
                    HStack {
                        Text("Max Tokens")
                            .font(.caption)
                            .frame(width: 80, alignment: .leading)
                        Slider(value: Binding(
                            get: { Double(viewModel.maxTokens) },
                            set: { viewModel.maxTokens = Int($0) }
                        ), in: 256...8192, step: 256)
                            .frame(width: 200)
                        Text("\(viewModel.maxTokens)")
                            .font(.mono(11, weight: .medium))
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Spacing.xs)
                .disabled(viewModel.isRunning)
            } label: {
                HStack {
                    Text("Parameters")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("T:\(String(format: "%.1f", viewModel.temperature)) P:\(String(format: "%.1f", viewModel.topP)) Tokens:\(viewModel.maxTokens)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture { showParameters.toggle() }
            }

            // Prompt Input
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack {
                    Text("Prompt")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    // Preset prompt selector
                    Menu {
                        ForEach(BenchmarkPrompt.PromptCategory.allCases, id: \.self) { category in
                            if let prompts = BenchmarkPrompt.presetsByCategory[category] {
                                Section(category.rawValue) {
                                    ForEach(prompts) { preset in
                                        Button {
                                            viewModel.promptText = preset.prompt
                                        } label: {
                                            HStack {
                                                Text(preset.name)
                                                Spacer()
                                                Text(preset.expectedLength.rawValue)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "text.badge.star")
                            Text("Presets")
                        }
                        .font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .disabled(viewModel.isRunning)
                }

                TextEditor(text: $viewModel.promptText)
                    .font(.body)
                    .frame(height: 100)
                    .scrollContentBackground(.hidden)
                    .padding(Spacing.xs)
                    .background {
                        RoundedRectangle(cornerRadius: CornerRadius.md)
                            .fill(.regularMaterial)
                            .overlay {
                                RoundedRectangle(cornerRadius: CornerRadius.md)
                                    .strokeBorder(Color.cardBorder, lineWidth: 1)
                            }
                    }
                    .disabled(viewModel.isRunning)
            }

            // Action Bar
            HStack {
                // Start/Stop Button
                if viewModel.isRunning {
                    Button(action: viewModel.stopBenchmark) {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    Button(action: viewModel.startBenchmark) {
                        Label("Run", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.selectedModel == nil)
                }

                // Status indicator
                if viewModel.isRunning {
                    ProgressView()
                        .controlSize(.small)
                    Text("Running...")
                        .foregroundStyle(.secondary)
                } else if let session = viewModel.currentSession, session.status == .completed {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Completed")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(viewModel.formattedElapsedTime)
                    .font(.mono(14, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if let error = viewModel.error {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.anubisWarning)
                    Text(error.localizedDescription)
                        .font(.caption)
                }
                .padding(Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: CornerRadius.md)
                        .fill(Color.anubisWarning.opacity(0.1))
                        .overlay {
                            RoundedRectangle(cornerRadius: CornerRadius.md)
                                .strokeBorder(Color.anubisWarning.opacity(0.3), lineWidth: 1)
                        }
                }
            }
        }
        .padding(Spacing.md)
    }

    // MARK: - Response Section

    private var responseSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text("Response")
                    .font(.headline)
                Spacer()
                Text(Formatters.tokens(viewModel.tokensGenerated))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.top, Spacing.md)

            // Use TextEditor for efficient rendering of long streaming text
            // (SwiftUI Text recalculates layout on every change, causing slowdown)
            StreamingTextView(
                text: viewModel.responseText,
                placeholder: "Response will appear here..."
            )
        }
    }

    // MARK: - Metrics Cards Section

    private var metricsCardsSection: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: Spacing.sm) {
            CompactMetricsCard(
                title: "Avg Tokens/sec",
                value: viewModel.formattedTokensPerSecond,
                icon: "bolt.fill",
                color: .chartTokens,
                subtitle: viewModel.peakTokensPerSecond > 0 ? "Peak: \(viewModel.formattedPeakTokensPerSecond)" : nil,
                help: "Average tokens generated per second. Calculated from completion_tokens ÷ generation_time reported by the backend."
            )

            CompactMetricsCard(
                title: "GPU",
                value: String(format: "%.0f%%", viewModel.gpuUtilizationPercent),
                icon: "gamecontroller",
                color: .chartGPU,
                available: viewModel.hasHardwareMetrics,
                help: "GPU utilization percentage from IOReport. Shows how much of the GPU is being used for inference."
            )

            CompactMetricsCard(
                title: "CPU",
                value: String(format: "%.0f%%", viewModel.cpuUtilizationPercent),
                icon: "cpu",
                color: .chartCPU,
                help: "CPU utilization across all cores from host_processor_info. High values may indicate CPU-bound operations."
            )

            CompactMetricsCard(
                title: "Time to First Token",
                value: viewModel.timeToFirstToken.map { Formatters.milliseconds($0 * 1000) } ?? "—",
                icon: "clock.arrow.circlepath",
                color: .chartTokens,
                help: "Time from request start until the first token is generated. Includes model loading time if not already loaded."
            )

            CompactModelMemoryCard(
                total: viewModel.modelMemoryTotal,
                isOllamaBackend: viewModel.selectedBackend == .ollama
            )

            CompactMetricsCard(
                title: "Thermal",
                value: viewModel.currentMetrics?.thermalState.description ?? "—",
                icon: "thermometer.medium",
                color: thermalColor,
                help: "System thermal state from ProcessInfo. Values: Normal → Fair → Serious → Critical. Performance may be throttled at higher states."
            )
        }
    }

    private var thermalColor: Color {
        switch viewModel.currentMetrics?.thermalState {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        case .none: return .gray
        }
    }

    // MARK: - Charts Section

    private var chartsSection: some View {
        VStack(spacing: Spacing.md) {
            // Toggle header for live charts
            HStack {
                Toggle(isOn: $showLiveCharts) {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .foregroundStyle(.secondary)
                        Text("Live Charts")
                            .font(.headline)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Spacer()

                if !showLiveCharts && viewModel.isRunning {
                    Text("Data collecting...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, Spacing.sm)

            if showLiveCharts {
                // Chart views observe chartStore independently from viewModel,
                // so chart updates won't trigger text streaming re-renders and vice versa.
                LiveChartsView(
                    chartStore: viewModel.chartStore,
                    isRunning: viewModel.isRunning,
                    hasHardwareMetrics: viewModel.hasHardwareMetrics,
                    isOllama: viewModel.selectedBackend == .ollama,
                    currentMemoryBytes: (viewModel.currentMetrics?.memoryUsedBytes ?? 0) + viewModel.modelMemoryTotal,
                    totalMemoryBytes: viewModel.currentMetrics?.memoryTotalBytes ?? 1
                )
            } else {
                // Collapsed state - show placeholder
                HStack {
                    Spacer()
                    VStack(spacing: Spacing.xs) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.title2)
                            .foregroundStyle(.quaternary)
                        Text("Charts hidden during benchmark")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text("Toggle on to view collected data")
                            .font(.caption2)
                            .foregroundStyle(.quaternary)
                    }
                    .padding(.vertical, Spacing.lg)
                    Spacer()
                }
                .background {
                    RoundedRectangle(cornerRadius: CornerRadius.md)
                        .fill(Color.emptyStateBackground)
                        .overlay {
                            RoundedRectangle(cornerRadius: CornerRadius.md)
                                .strokeBorder(Color.cardBorder, lineWidth: 1)
                        }
                }
            }
        }
    }

    // MARK: - Detailed Stats Section

    private var detailedStatsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Session Details")
                .font(.headline)
                .padding(.bottom, Spacing.xs)

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: Spacing.sm) {
                // Average Token Latency
                DetailStatCell(
                    title: "Avg Token Latency",
                    value: viewModel.currentSession?.averageTokenLatencyMs.map { Formatters.milliseconds($0) } ?? "—"
                )

                // Load Duration (Ollama only)
                DetailStatCell(
                    title: "Model Load Time",
                    value: viewModel.selectedBackend == .ollama
                        ? (viewModel.currentSession?.loadDuration.map { Formatters.duration($0) } ?? "—")
                        : "N/A"
                )

                // Context Length (Ollama only)
                DetailStatCell(
                    title: "Context Length",
                    value: viewModel.selectedBackend == .ollama
                        ? (viewModel.currentSession?.contextLength.map { "\($0) tokens" } ?? "—")
                        : "N/A"
                )

                // Peak Memory (Ollama only - tracks Ollama process memory)
                DetailStatCell(
                    title: "Peak Memory (Ollama server)",
                    value: viewModel.selectedBackend == .ollama
                        ? (viewModel.currentPeakMemory > 0
                            ? Formatters.bytes(viewModel.currentPeakMemory)
                            : viewModel.currentSession?.peakMemoryBytes.map { Formatters.bytes($0) } ?? "—")
                        : "N/A"
                )

                // Prompt Tokens
                DetailStatCell(
                    title: "Prompt Tokens",
                    value: viewModel.currentSession?.promptTokens.map { "\($0)" } ?? "—"
                )

                // Completion Tokens
                DetailStatCell(
                    title: "Completion Tokens",
                    value: viewModel.currentSession?.completionTokens.map { "\($0)" }
                        ?? (viewModel.tokensGenerated > 0 ? "\(viewModel.tokensGenerated)" : "—")
                )

                // Eval Duration (Ollama only)
                DetailStatCell(
                    title: "Eval Duration",
                    value: viewModel.selectedBackend == .ollama
                        ? (viewModel.currentSession?.evalDuration.map { Formatters.duration($0) } ?? "—")
                        : "N/A"
                )

                // Connection
                DetailStatCell(
                    title: "Connection",
                    value: viewModel.connectionName
                )

                // Status
                DetailStatCell(
                    title: "Status",
                    value: viewModel.isRunning ? "Running" : (viewModel.currentSession?.status.rawValue.capitalized ?? "—")
                )
            }
        }
        .padding(Spacing.md)
        .background {
            RoundedRectangle(cornerRadius: CornerRadius.lg)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: CornerRadius.lg)
                        .strokeBorder(Color.cardBorder, lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
        }
    }
}

// MARK: - Detail Stat Cell

struct DetailStatCell: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.mono(13, weight: .medium))
                .foregroundStyle(value == "—" ? .tertiary : .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Thermal State Description

extension ThermalState {
    var description: String {
        switch self {
        case .nominal: return "Normal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        }
    }
}

// MARK: - Streaming Text View

/// Efficient text view for streaming content using NSTextView
/// SwiftUI's Text view recalculates layout on every change, causing slowdown with long text
struct StreamingTextView: NSViewRepresentable {
    let text: String
    let placeholder: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView

        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        let displayText = text.isEmpty ? placeholder : text
        let isPlaceholder = text.isEmpty

        // Only update if text changed (avoid unnecessary work)
        if textView.string != displayText {
            // Preserve scroll position if user scrolled up
            let wasAtBottom = isScrolledToBottom(scrollView)

            textView.string = displayText
            textView.textColor = isPlaceholder ? .secondaryLabelColor : .labelColor

            // Auto-scroll to bottom if was at bottom (follow streaming)
            if wasAtBottom && !isPlaceholder {
                textView.scrollToEndOfDocument(nil)
            }
        }
    }

    private func isScrolledToBottom(_ scrollView: NSScrollView) -> Bool {
        guard let textView = scrollView.documentView as? NSTextView else { return true }
        let visibleRect = scrollView.contentView.bounds
        let contentHeight = textView.bounds.height
        // Consider "at bottom" if within 50 points of the end
        return visibleRect.maxY >= contentHeight - 50
    }
}

// MARK: - Model Memory Card

/// Card showing model memory usage (unified memory on Apple Silicon)
struct ModelMemoryCard: View {
    let total: Int64
    let gpu: Int64
    let cpu: Int64
    var isOllamaBackend: Bool = true

    private let helpText = "Memory used by the loaded model in unified memory. Reported by Ollama's /api/ps endpoint (size_vram field). On Apple Silicon, GPU and CPU share the same memory pool."

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Image(systemName: "memorychip")
                    .font(.caption)
                    .foregroundStyle(Color.chartMemory)
                Text("Model Memory")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                HelpButton(text: helpText)
                if !isOllamaBackend {
                    Text("N/A")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if !isOllamaBackend {
                // Non-Ollama backends don't provide model memory info
                Text("—")
                    .font(.anubisMetricSmall)
                    .foregroundStyle(.tertiary)
            } else if total > 0 {
                // Total size - this is what matters on Apple Silicon (unified memory)
                Text(Formatters.bytes(total))
                    .font(.anubisMetricSmall)
            } else {
                Text("—")
                    .font(.anubisMetricSmall)
                    .foregroundStyle(.tertiary)
            }

            // Always show subtitle for consistent height
            Text(subtitleText)
                .font(.caption2)
                .foregroundStyle(subtitleColor)
        }
        .metricCardStyle()
    }

    private var subtitleText: String {
        if !isOllamaBackend {
            return "Ollama only"
        } else if total > 0 {
            return "Unified Memory"
        } else {
            return "Waiting for model..."
        }
    }

    private var subtitleColor: Color {
        if !isOllamaBackend || total == 0 {
            return .secondary.opacity(0.6)
        }
        return .secondary
    }
}

// MARK: - Expanded Metrics View

/// Full-screen view of the metrics dashboard
struct ExpandedMetricsView: View {
    @ObservedObject var viewModel: BenchmarkViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Benchmark Results")
                        .font(.headline)
                    if let model = viewModel.selectedModel {
                        Text(model.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if viewModel.isRunning {
                    HStack(spacing: Spacing.xs) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Running...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(Spacing.md)
            .background(.bar)

            Divider()

            // Main content
            ScrollView {
                VStack(spacing: Spacing.lg) {
                    // Metrics cards in wider layout
                    metricsCardsSection

                    // Detailed stats
                    detailedStatsSection

                    // Charts section
                    chartsSection
                }
                .padding(Spacing.lg)
            }
        }
        .frame(minWidth: 800, minHeight: 900)
    }

    // MARK: - Metrics Cards Section

    private var metricsCardsSection: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: Spacing.sm) {
            CompactMetricsCard(
                title: "Avg Tokens/sec",
                value: viewModel.formattedTokensPerSecond,
                icon: "bolt.fill",
                color: .chartTokens,
                subtitle: viewModel.peakTokensPerSecond > 0 ? "Peak: \(viewModel.formattedPeakTokensPerSecond)" : nil,
                help: "Average tokens generated per second. Calculated from completion_tokens ÷ generation_time reported by the backend."
            )

            CompactMetricsCard(
                title: "GPU",
                value: String(format: "%.0f%%", viewModel.gpuUtilizationPercent),
                icon: "gpu",
                color: .chartGPU,
                available: viewModel.hasHardwareMetrics,
                help: "GPU utilization percentage from IOReport. Shows how much of the GPU is being used for inference."
            )

            CompactMetricsCard(
                title: "CPU",
                value: String(format: "%.0f%%", viewModel.cpuUtilizationPercent),
                icon: "cpu",
                color: .chartCPU,
                help: "CPU utilization across all cores from host_processor_info. High values may indicate CPU-bound operations."
            )

            CompactMetricsCard(
                title: "Time to First Token",
                value: viewModel.timeToFirstToken.map { Formatters.milliseconds($0 * 1000) } ?? "—",
                icon: "clock.arrow.circlepath",
                color: .chartTokens,
                help: "Time from request start until the first token is generated. Includes model loading time if not already loaded."
            )

            CompactModelMemoryCard(
                total: viewModel.modelMemoryTotal,
                isOllamaBackend: viewModel.selectedBackend == .ollama
            )

            CompactMetricsCard(
                title: "Thermal",
                value: viewModel.currentMetrics?.thermalState.description ?? "—",
                icon: "thermometer.medium",
                color: thermalColor,
                help: "System thermal state from ProcessInfo. Values: Normal → Fair → Serious → Critical. Performance may be throttled at higher states."
            )
        }
    }

    private var thermalColor: Color {
        switch viewModel.currentMetrics?.thermalState {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        case .none: return .gray
        }
    }

    // MARK: - Charts Section

    private var chartsSection: some View {
        VStack(spacing: Spacing.md) {
            // Show charts in 2-column layout for expanded view
            let chartData = viewModel.chartStore.chartData
            HStack(spacing: Spacing.md) {
                TimelineChart(
                    title: "Tokens per Second",
                    data: chartData.tokensPerSecond,
                    color: .chartTokens,
                    unit: "tok/s"
                )

                TimelineChart(
                    title: "CPU Utilization",
                    data: chartData.cpuUtilization,
                    color: .chartCPU,
                    unit: "%",
                    maxValue: 100
                )
            }

            HStack(spacing: Spacing.md) {
                if viewModel.hasHardwareMetrics {
                    TimelineChart(
                        title: "GPU Utilization",
                        data: chartData.gpuUtilization,
                        color: .chartGPU,
                        unit: "%",
                        maxValue: 100
                    )
                }

                if viewModel.selectedBackend == .ollama {
                    MemoryTimelineChart(
                        title: "Ollama Memory",
                        data: chartData.memoryUtilization,
                        currentBytes: (viewModel.currentMetrics?.memoryUsedBytes ?? 0) + viewModel.modelMemoryTotal,
                        totalBytes: viewModel.currentMetrics?.memoryTotalBytes ?? 1,
                        color: .chartMemory
                    )
                }
            }
        }
    }

    // MARK: - Detailed Stats Section

    private var detailedStatsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Session Details")
                .font(.headline)
                .padding(.bottom, Spacing.xs)

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: Spacing.md) {
                DetailStatCell(
                    title: "Avg Token Latency",
                    value: viewModel.currentSession?.averageTokenLatencyMs.map { Formatters.milliseconds($0) } ?? "—"
                )

                DetailStatCell(
                    title: "Total Duration",
                    value: viewModel.elapsedTime > 0
                        ? Formatters.duration(viewModel.elapsedTime)
                        : "—"
                )

                DetailStatCell(
                    title: "Model Load Time",
                    value: viewModel.selectedBackend == .ollama
                        ? (viewModel.currentSession?.loadDuration.map { Formatters.duration($0) } ?? "—")
                        : "N/A"
                )

                DetailStatCell(
                    title: "Context Length",
                    value: viewModel.selectedBackend == .ollama
                        ? (viewModel.currentSession?.contextLength.map { "\($0) tokens" } ?? "—")
                        : "N/A"
                )

                DetailStatCell(
                    title: "Peak Memory",
                    value: viewModel.selectedBackend == .ollama
                        ? (viewModel.currentPeakMemory > 0
                            ? Formatters.bytes(viewModel.currentPeakMemory)
                            : viewModel.currentSession?.peakMemoryBytes.map { Formatters.bytes($0) } ?? "—")
                        : "N/A"
                )

                DetailStatCell(
                    title: "Prompt Tokens",
                    value: viewModel.currentSession?.promptTokens.map { "\($0)" } ?? "—"
                )

                DetailStatCell(
                    title: "Completion Tokens",
                    value: viewModel.currentSession?.completionTokens.map { "\($0)" }
                        ?? (viewModel.tokensGenerated > 0 ? "\(viewModel.tokensGenerated)" : "—")
                )

                DetailStatCell(
                    title: "Eval Duration",
                    value: viewModel.selectedBackend == .ollama
                        ? (viewModel.currentSession?.evalDuration.map { Formatters.duration($0) } ?? "—")
                        : "N/A"
                )

                DetailStatCell(
                    title: "Connection",
                    value: viewModel.connectionName
                )

                DetailStatCell(
                    title: "Status",
                    value: viewModel.isRunning ? "Running" : (viewModel.currentSession?.status.rawValue.capitalized ?? "—")
                )
            }
        }
        .padding(Spacing.md)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: CornerRadius.lg))
    }
}

// MARK: - Live Charts View

/// Isolated chart view that observes only the BenchmarkChartStore.
/// This prevents chart data updates from invalidating the text streaming view
/// and vice versa, eliminating the main cause of streaming choppiness.
private struct LiveChartsView: View {
    @ObservedObject var chartStore: BenchmarkChartStore
    let isRunning: Bool
    let hasHardwareMetrics: Bool
    let isOllama: Bool
    let currentMemoryBytes: Int64
    let totalMemoryBytes: Int64

    var body: some View {
        let data = chartStore.chartData

        TimelineChart(
            title: "Tokens per Second",
            data: data.tokensPerSecond,
            color: .chartTokens,
            unit: "tok/s"
        )

        if hasHardwareMetrics {
            TimelineChart(
                title: "GPU Utilization",
                data: data.gpuUtilization,
                color: .chartGPU,
                unit: "%",
                maxValue: 100
            )
        }

        TimelineChart(
            title: "CPU Utilization",
            data: data.cpuUtilization,
            color: .chartCPU,
            unit: "%",
            maxValue: 100
        )

        if isOllama {
            MemoryTimelineChart(
                title: "Ollama Memory",
                data: data.memoryUtilization,
                currentBytes: currentMemoryBytes,
                totalBytes: totalMemoryBytes,
                color: .chartMemory
            )
        }
    }
}
