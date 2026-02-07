//
//  SandParticleView.swift
//  anubis
//
//  Created on 2026-01-28.
//

import SwiftUI
import AppKit

// MARK: - Mouse Tracking (doesn't block clicks)

/// Tracks mouse position without intercepting click events
struct MouseTrackingView: NSViewRepresentable {
    @Binding var mousePosition: CGPoint?

    func makeNSView(context: Context) -> MouseTrackingNSView {
        let view = MouseTrackingNSView()
        view.onMouseMoved = { [self] point in
            DispatchQueue.main.async {
                self.mousePosition = point
            }
        }
        view.onMouseExited = { [self] in
            DispatchQueue.main.async {
                self.mousePosition = nil
            }
        }
        return view
    }

    func updateNSView(_ nsView: MouseTrackingNSView, context: Context) {}
}

class MouseTrackingNSView: NSView {
    var onMouseMoved: ((CGPoint) -> Void)?
    var onMouseExited: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let existing = trackingArea {
            removeTrackingArea(existing)
        }

        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .mouseMoved,
            .activeInActiveApp,
            .inVisibleRect
        ]

        trackingArea = NSTrackingArea(
            rect: bounds,
            options: options,
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Flip Y coordinate (NSView is flipped compared to SwiftUI)
        let flippedPoint = CGPoint(x: point.x, y: bounds.height - point.y)
        onMouseMoved?(flippedPoint)
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }

    // Don't handle mouse clicks - let them pass through
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

/// A particle in the sand simulation
private struct SandParticle: Identifiable {
    let id = UUID()
    var x: CGFloat
    var y: CGFloat
    var vx: CGFloat = 0
    var vy: CGFloat = 0
    var settled: Bool = false
    var settleTime: Date?
    let size: CGFloat
    let hue: Double  // Slight color variation
    let brightness: Double
}

/// Falling gold sand animation that fills the container during inference runs
struct SandParticleView: View {
    let isRunning: Bool
    let containerHeight: CGFloat
    let containerWidth: CGFloat

    /// Distance from bottom where particles settle (e.g., 140 = settle 140pt above bottom)
    var floorY: CGFloat = 140

    /// Binding to trigger clear (toggle to clear)
    @Binding var clearTrigger: Bool

    /// Current particle count (for display)
    @Binding var particleCount: Int

    /// External mouse position (from MouseTrackingView)
    @Binding var mousePosition: CGPoint?

    @State private var particles: [SandParticle] = []
    @State private var lastSpawnTime = Date()

    // Physics constants
    private let gravity: CGFloat = 120  // pixels per second squared
    private let spawnRate: Double = 0.03  // seconds between spawns (slightly slower)
    private let maxParticles = 1000 // increased cap
    private let particleSize: ClosedRange<CGFloat> = 5.5...12.0
    private let mouseRadius: CGFloat = 35  // radius of mouse influence
    private let mouseForce: CGFloat = 600  // gentler repulsion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1/60)) { timeline in
            Canvas { context, size in
                for particle in particles {
                    let rect = CGRect(
                        x: particle.x - particle.size / 2,
                        y: particle.y - particle.size / 2,
                        width: particle.size,
                        height: particle.size
                    )

                    // Gold color with variation
                    let color = Color(
                        hue: particle.hue,
                        saturation: 0.8,
                        brightness: particle.brightness
                    )

                    context.fill(
                        Circle().path(in: rect),
                        with: .color(color)
                    )

                    // Subtle shimmer on some particles
                    if particle.settled && Int(particle.id.hashValue) % 5 == 0 {
                        let shimmer = abs(sin(timeline.date.timeIntervalSinceReferenceDate * 3 + particle.x)) * 0.3
                        context.fill(
                            Circle().path(in: rect.insetBy(dx: 0.5, dy: 0.5)),
                            with: .color(.white.opacity(shimmer))
                        )
                    }
                }
            }
            .onChange(of: timeline.date) { oldValue, newValue in
                updateParticles(deltaTime: newValue.timeIntervalSince(oldValue), containerSize: CGSize(width: containerWidth, height: containerHeight))
            }
        }
        .onChange(of: clearTrigger) { _, _ in
            // Clear all particles when trigger is toggled
            particles.removeAll()
            particleCount = 0
        }
        .onChange(of: particles.count) { _, count in
            particleCount = count
        }
    }

    private func updateParticles(deltaTime: TimeInterval, containerSize: CGSize) {
        let dt = CGFloat(min(deltaTime, 0.05))  // Cap delta time
        // floorY is distance from bottom where particles settle
        let floorPosition = containerSize.height - floorY

        // Spawn new particles if running
        if isRunning && particles.count < maxParticles {
            let now = Date()
            if now.timeIntervalSince(lastSpawnTime) > spawnRate {
                spawnParticle(width: containerSize.width)
                lastSpawnTime = now
            }
        }

        // Build a height map for settled particles (simplified stacking)
        var heightMap = [Int: CGFloat]()  // x bucket -> highest y
        let bucketWidth: CGFloat = 4

        for particle in particles where particle.settled {
            let bucket = Int(particle.x / bucketWidth)
            let currentHeight = heightMap[bucket] ?? floorPosition
            heightMap[bucket] = min(currentHeight, particle.y)
        }

        // Update particles
        for i in particles.indices {
            var p = particles[i]

            if !p.settled {
                // Apply gravity
                p.vy += gravity * dt

                // Apply mouse repulsion
                if let mouse = mousePosition {
                    let dx = p.x - mouse.x
                    let dy = p.y - mouse.y
                    let dist = sqrt(dx * dx + dy * dy)

                    if dist < mouseRadius && dist > 0 {
                        let force = (mouseRadius - dist) / mouseRadius * mouseForce * dt
                        p.vx += (dx / dist) * force
                        p.vy += (dy / dist) * force
                    }
                }

                // Update position
                p.x += p.vx * dt
                p.y += p.vy * dt

                // Damping
                p.vx *= 0.98

                // Bounce off walls
                if p.x < p.size / 2 {
                    p.x = p.size / 2
                    p.vx = abs(p.vx) * 0.5
                }
                if p.x > containerSize.width - p.size / 2 {
                    p.x = containerSize.width - p.size / 2
                    p.vx = -abs(p.vx) * 0.5
                }

                // Check for settling
                let bucket = Int(p.x / bucketWidth)
                let settleHeight = heightMap[bucket] ?? floorPosition

                if p.y >= settleHeight - p.size / 2 {
                    p.y = settleHeight - p.size / 2
                    p.vy = 0
                    p.vx = 0
                    p.settled = false
                    p.settleTime = Date()

                    // Update height map
                    heightMap[bucket] = p.y
                }
            } else {
                // Settled particles can still be nudged by mouse - sand-like horizontal push
                if let mouse = mousePosition {
                    let dx = p.x - mouse.x
                    let dy = p.y - mouse.y
                    let dist = sqrt(dx * dx + dy * dy)

                    if dist < mouseRadius * 0.8 && dist > 0 {
                        // Nudge horizontally, minimal vertical - like pushing sand
                        let force = (mouseRadius - dist) / mouseRadius * mouseForce * 0.3 * dt
                        p.vx += (dx+dy / dist) * force
                        // Only tiny vertical nudge, mostly horizontal
                        p.vy += (dy+dx / dist) * force * 0.1
                        // Don't unsettle unless really pushed
                        if abs(p.vx) > 1 {
                            p.settled = false
                        }
                    }
                }
            }

            particles[i] = p
        }

        // Remove particles that fell off screen (shouldn't happen, but safety)
        particles.removeAll { $0.y > containerSize.height + 50 }
    }

    private func spawnParticle(width: CGFloat) {
        let particle = SandParticle(
            x: CGFloat.random(in: 10...(width - 10)),
            y: -5,
            vy: CGFloat.random(in: 20...60),
            size: CGFloat.random(in: particleSize),
            hue: Double.random(in: 0.10...0.14),  // Gold hue range
            brightness: Double.random(in: 0.7...0.95)
        )
        particles.append(particle)
    }

}

// MARK: - Preview

#Preview {
    struct PreviewWrapper: View {
        @State private var isRunning = true
        @State private var clearTrigger = false
        @State private var particleCount = 0
        @State private var mousePosition: CGPoint?

        var body: some View {
            VStack {
                HStack {
                    Toggle("Running", isOn: $isRunning)
                    Button("Clear") { clearTrigger.toggle() }
                    Text("\(particleCount)")
                        .monospacedDigit()
                }
                .padding()

                ZStack(alignment: .bottom) {
                    Color.black.opacity(0.9)

                    // Mouse tracking overlay
                    MouseTrackingView(mousePosition: $mousePosition)

                    SandParticleView(
                        isRunning: isRunning,
                        containerHeight: 500,
                        containerWidth: 200,
                        floorY: 60,  // Settle above the simulated splash
                        clearTrigger: $clearTrigger,
                        particleCount: $particleCount,
                        mousePosition: $mousePosition
                    )
                    .allowsHitTesting(false)

                    // Simulated splash area (like the real splash image)
                    Rectangle()
                        .fill(.yellow.opacity(0.3))
                        .frame(height: 50)
                }
                .frame(width: 200, height: 500)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    return PreviewWrapper()
}
