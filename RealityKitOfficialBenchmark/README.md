# RealityKit official Gaussian-splat benchmark adapter

This directory is intentionally not part of the existing Xcode 26 target. It uses
`GaussianSplatComponent`, which requires the Xcode 27 SDK and iOS, macOS, or visionOS 27.

## Add it to a benchmark target

1. Install Xcode 27 and create a SwiftUI app target with an OS 27 deployment target.
2. Add the repository's `SplatIO` product to the target.
3. Add `RealityKitSplatBuilder.swift` and `RealityKitBenchmarkView.swift` to the target.
4. Add the PLY assets to Copy Bundle Resources, or pass a security-scoped file URL.
5. Present `RealityKitBenchmarkView` with a fixed point limit and sorting mode.

```swift
RealityKitBenchmarkView(
    modelURL: modelURL,
    configuration: .init(
        pointLimit: 1_000_000,
        maximumSHDegree: .sh3,
        sortingMode: .depth
    )
)
```

Run on a physical Apple7-family-or-newer device. Gaussian splats don't render in
the simulator. The overlay's update cadence is a sanity indicator, not a replacement
for Instruments' displayed-frame and GPU measurements.

Use a Release build and capture these Instruments templates for each fixed configuration:

- Game Performance: displayed surfaces, GPU intervals, command submissions.
- Time Profiler: loader and RealityKit/CPU costs.
- Game Memory: peak and stable physical footprint.
- Power Profiler/Energy Log: package/GPU energy, average power, thermal response.
- Points of Interest: `SplatLoad`, `RealityKitResourceBuild`, and
  `RealityKitRenderingLimited` signposts emitted by the adapter.

Keep device, resolution, view path, duration, starting thermal state, brightness,
and power source fixed. Test `.depth` and `.distance` independently. Repeat every run
at least three times and report median plus P95 frame time.
