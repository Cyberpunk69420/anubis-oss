//
//  IOReportBridge.swift
//  anubis
//
//  Created on 2026-01-25.
//

import Foundation
import IOKit
import os

/// Bridge to hardware metrics on Apple Silicon
/// Uses documented IOKit APIs to read GPU utilization from AGXAccelerator
/// App Store compatible - uses only public APIs for read-only hardware observation
final class IOReportBridge {
    // MARK: - Singleton

    static let shared = IOReportBridge()

    // MARK: - Properties

    private var gpuServiceAvailable: Bool = false
    private var acceleratorService: io_service_t = 0

    // MARK: - Initialization

    private init() {
        gpuServiceAvailable = setupGPUService()
        let gpuAvail = gpuServiceAvailable
        Log.metrics.info("IOReportBridge initialized - GPU available: \(gpuAvail)")
    }

    deinit {
        if acceleratorService != 0 {
            IOObjectRelease(acceleratorService)
        }
    }

    private func setupGPUService() -> Bool {
        // Try to find the AGXAccelerator service (Apple GPU)
        let services = ["AGXAccelerator", "AGPM", "AppleM1GPU", "AppleM2GPU", "AppleM3GPU"]

        for serviceName in services {
            if let matching = IOServiceMatching(serviceName) {
                var iterator: io_iterator_t = 0
                let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)

                if result == KERN_SUCCESS {
                    let service = IOIteratorNext(iterator)
                    IOObjectRelease(iterator)

                    if service != 0 {
                        acceleratorService = service
                        Log.metrics.debug("Found GPU service: \(serviceName)")
                        return true
                    }
                } else {
                    IOObjectRelease(iterator)
                }
            }
        }

        Log.metrics.warning("No GPU service found via IOKit")
        return false
    }

    // MARK: - Public Interface

    /// Check if GPU metrics are available on this system
    var isAvailable: Bool {
        gpuServiceAvailable
    }

    /// Sample current GPU utilization
    /// Reads from AGXAccelerator's PerformanceStatistics using documented IOKit APIs
    func sample() -> HardwareMetrics {
        var gpuUtilization: Double = 0

        if gpuServiceAvailable && acceleratorService != 0 {
            // Re-read properties each time for updated metrics
            if let properties = getServiceProperties(acceleratorService) {
                // Read GPU utilization from PerformanceStatistics
                if let perfStats = properties["PerformanceStatistics"] as? [String: Any] {
                    // "Device Utilization %" is the main GPU utilization metric
                    if let deviceUtil = perfStats["Device Utilization %"] as? NSNumber {
                        gpuUtilization = deviceUtil.doubleValue / 100.0
                    }
                }
            }
        }

        return HardwareMetrics(
            gpuUtilization: min(1.0, max(0.0, gpuUtilization)),
            cpuUtilization: 0, // CPU is handled by MetricsService via sysctl
            isAvailable: gpuServiceAvailable
        )
    }

    private func getServiceProperties(_ service: io_service_t) -> [String: Any]? {
        var properties: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)

        if result == KERN_SUCCESS, let props = properties?.takeRetainedValue() as? [String: Any] {
            return props
        }
        return nil
    }

    /// Debug: Log all properties of the GPU service
    func logGPUServiceProperties() {
        guard acceleratorService != 0 else {
            return
        }

        if let properties = getServiceProperties(acceleratorService) {
            var output = "=== GPU Service Properties ===\n"
            for (key, value) in properties.sorted(by: { $0.key < $1.key }) {
                let valueStr = String(describing: value).prefix(300)
                output += "  \(key): \(valueStr)\n"
            }
            output += "==============================\n"

            // Write to sandbox-safe temp file for debugging
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("anubis_gpu_properties.txt")
            try? output.write(to: path, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Hardware Metrics

/// Hardware metrics from IOKit
struct HardwareMetrics: Sendable {
    let gpuUtilization: Double  // 0.0 - 1.0
    let cpuUtilization: Double  // 0.0 - 1.0 (from sysctl, not IOKit)
    let isAvailable: Bool

    static let unavailable = HardwareMetrics(
        gpuUtilization: 0,
        cpuUtilization: 0,
        isAvailable: false
    )
}
