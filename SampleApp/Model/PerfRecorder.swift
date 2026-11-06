import Foundation
import MetalSplatter

/// Records per-frame render telemetry to CSV for performance runs.
final class PerfRecorder: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var rows: [[String]] = []
    private var lastFlushedCount = 1
    private let startTime = Date()

    init(url: URL) {
        self.url = url
        rows.append(["t_seconds", "frame",
                     "total_encode_ms", "access_wait_ms", "chunk_list_ms", "pose_update_ms",
                     "obtain_sort_buffer_ms", "uniforms_ms", "chunks_buffer_ms", "pipeline_ms",
                     "render_encoder_ms", "index_buffer_ms", "resource_residency_ms", "draw_call_ms",
                     "splat_count", "indexed_splat_count", "instance_count", "chunk_count", "is_multi_stage"])
    }

    func record(_ telemetry: SplatRenderer.RenderTelemetry) {
        let elapsed = Date().timeIntervalSince(startTime)
        let row: [String] = [
            String(format: "%.3f", elapsed),
            String(rows.count - 1),
            formatMs(telemetry.totalEncodeMs),
            formatMs(telemetry.accessWaitMs),
            formatMs(telemetry.chunkListMs),
            formatMs(telemetry.poseUpdateMs),
            formatMs(telemetry.obtainSortBufferMs),
            formatMs(telemetry.uniformsMs),
            formatMs(telemetry.chunksBufferMs),
            formatMs(telemetry.pipelineMs),
            formatMs(telemetry.renderEncoderMs),
            formatMs(telemetry.indexBufferMs),
            formatMs(telemetry.resourceResidencyMs),
            formatMs(telemetry.drawCallMs),
            String(telemetry.splatCount),
            String(telemetry.indexedSplatCount),
            String(telemetry.instanceCount),
            String(telemetry.chunkCount),
            String(telemetry.isMultiStage),
        ]
        lock.lock()
        rows.append(row)
        let needsFlush = rows.count - lastFlushedCount >= 120
        lock.unlock()
        if needsFlush {
            write()
        }
    }

    private func formatMs(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    deinit {
        write()
    }

    func write() {
        lock.lock()
        let csv = rows.map { $0.joined(separator: ",") }.joined(separator: "\n")
        lastFlushedCount = rows.count
        lock.unlock()
        try? csv.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Frames per second over the recorded window.
    static func summarize(csvURL: URL) -> String {
        guard let content = try? String(contentsOf: csvURL, encoding: .utf8) else {
            return "no data"
        }
        let lines = content.split(separator: "\n").map(String.init)
        guard lines.count > 2 else { return "insufficient data" }
        let dataLines = Array(lines.dropFirst())

        var encodeMs: [Double] = []
        var frameTimes: [Double] = []
        var lastT: Double? = nil
        var splatCount = ""
        var indexed = ""
        for line in dataLines {
            let cols = line.split(separator: ",").map(String.init)
            guard cols.count >= 19, let t = Double(cols[0]), let enc = Double(cols[2]) else { continue }
            encodeMs.append(enc)
            if let last = lastT {
                frameTimes.append(t - last)
            }
            lastT = t
            splatCount = cols[14]
            indexed = cols[15]
        }
        guard !frameTimes.isEmpty else { return "insufficient data" }

        func stats(_ values: [Double]) -> (avg: Double, p95: Double, maxV: Double) {
            let sorted = values.sorted()
            let avg = values.reduce(0, +) / Double(values.count)
            let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))]
            return (avg, p95, sorted.last ?? 0)
        }

        let f = stats(frameTimes)
        let e = stats(encodeMs)
        let fps = 1.0 / f.avg
        return String(format: """
        frames: %d
        FPS: avg %.1f (frame interval avg %.2f ms, p95 %.2f ms, max %.2f ms)
        CPU encode: avg %.3f ms, p95 %.3f ms, max %.3f ms
        splats: %@ (indexed %@)
        """, frameTimes.count, fps, f.avg * 1000, f.p95 * 1000, f.maxV * 1000,
                      e.avg, e.p95, e.maxV, splatCount, indexed)
    }
}
