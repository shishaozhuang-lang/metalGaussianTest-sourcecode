import Foundation
import Observation
import os
import RealityKit
import SplatIO
import SwiftUI

private let benchmarkLog = OSLog(subsystem: "MetalSplatter.Benchmark", category: .pointsOfInterest)

@MainActor
@Observable
final class RealityKitBenchmarkModel {
    private(set) var status = "Idle"
    private(set) var sourcePointCount = 0
    private(set) var renderedPointCount = 0
    private(set) var loadSeconds = 0.0
    private(set) var resourceBuildSeconds = 0.0
    private(set) var averageFPS = 0.0
    private(set) var thermalState = ProcessInfo.processInfo.thermalState

    private var asset: RealityKitSplatAsset?
    private var updateSubscription: EventSubscription?
    private var renderingSubscription: EventSubscription?
    private var firstFrameTime: ContinuousClock.Instant?
    private var lastSampleTime: ContinuousClock.Instant?
    private var framesSinceSample = 0

    func load(
        url: URL,
        configuration: RealityKitSplatConfiguration,
        into content: RealityViewContent
    ) async {
        status = "Loading"
        let loadSignpost = OSSignpostID(log: benchmarkLog)
        os_signpost(.begin, log: benchmarkLog, name: "SplatLoad", signpostID: loadSignpost)
        let loadStart = ContinuousClock.now

        do {
            let reader = try AutodetectSceneReader(url)
            let points = try await reader.readAll()
            loadSeconds = Self.seconds(from: loadStart, to: .now)
            sourcePointCount = points.count
            os_signpost(.end, log: benchmarkLog, name: "SplatLoad", signpostID: loadSignpost, "points=%d", points.count)

            let buildSignpost = OSSignpostID(log: benchmarkLog)
            os_signpost(.begin, log: benchmarkLog, name: "RealityKitResourceBuild", signpostID: buildSignpost)
            let buildStart = ContinuousClock.now
            let newAsset = try RealityKitSplatAsset(points: points, configuration: configuration)
            resourceBuildSeconds = Self.seconds(from: buildStart, to: .now)
            renderedPointCount = newAsset.splatCount
            os_signpost(.end, log: benchmarkLog, name: "RealityKitResourceBuild", signpostID: buildSignpost, "points=%d", newAsset.splatCount)

            asset?.entity.removeFromParent()
            asset = newAsset
            content.add(newAsset.entity)
            beginFrameSampling(content: content, entity: newAsset.entity)
            status = "Running"
        } catch {
            status = "Failed: \(error.localizedDescription)"
            os_signpost(.end, log: benchmarkLog, name: "SplatLoad", signpostID: loadSignpost)
        }
    }

    private func beginFrameSampling(content: RealityViewContent, entity: Entity) {
        firstFrameTime = .now
        lastSampleTime = .now
        framesSinceSample = 0
        updateSubscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            Task { @MainActor in self?.recordFrame() }
        }
        renderingSubscription = content.subscribe(to: GaussianSplatEvents.RenderingChanged.self, on: entity) { event in
            os_signpost(
                .event,
                log: benchmarkLog,
                name: "RealityKitRenderingLimited",
                "limited=%{public}d status=%{public}@",
                event.isRenderingLimited ? 1 : 0,
                String(describing: event.renderingStatus)
            )
        }
    }

    private func recordFrame() {
        framesSinceSample += 1
        let now = ContinuousClock.now
        guard let lastSampleTime else {
            self.lastSampleTime = now
            return
        }
        let elapsed = Self.seconds(from: lastSampleTime, to: now)
        guard elapsed >= 1 else { return }
        averageFPS = Double(framesSinceSample) / elapsed
        framesSinceSample = 0
        self.lastSampleTime = now
        thermalState = ProcessInfo.processInfo.thermalState
    }

    private static func seconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: end)
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

struct RealityKitBenchmarkView: View {
    let modelURL: URL
    let configuration: RealityKitSplatConfiguration
    @State private var model = RealityKitBenchmarkModel()

    var body: some View {
        RealityView { content in
            await model.load(url: modelURL, configuration: configuration, into: content)
        }
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading) {
                Text(model.status)
                Text("source: \(model.sourcePointCount)")
                Text("rendered: \(model.renderedPointCount)")
                Text(String(format: "load: %.3f s", model.loadSeconds))
                Text(String(format: "resource: %.3f s", model.resourceBuildSeconds))
                Text(String(format: "update cadence: %.1f Hz", model.averageFPS))
                Text("thermal: \(String(describing: model.thermalState))")
            }
            .font(.system(.caption, design: .monospaced))
            .padding(12)
            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(.white)
            .padding()
        }
    }
}
