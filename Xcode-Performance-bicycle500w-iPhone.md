# bicycle500w iPhone Performance Report

## Environment

- Device: iPhone 17 Pro Max (`iPhone18,2`)
- OS: iOS 26.5.2 (23F84)
- Build: Release, Swift whole-module optimization
- Xcode/Instruments: Xcode 26.6
- Scene: `bicycle500w`, 4,868,799 Gaussian points
- PLY size: 1,207,463,684 bytes
- Camera: reused from `bicycle120w/view.json`

## Instruments captures

- Time Profiler: 30.76 seconds
- Game Performance cold launch: 10 seconds retained window
- Game Memory: 20.76 seconds
- Activity Monitor: 15 seconds

The Game Performance capture launched the app under Instruments so Metal events were intercepted from process startup. This is required because attaching after launch did not expose Metal command-buffer events.

## Results

| Metric | Result |
|---|---:|
| Displayed frame/surface rate | 19.5 FPS average |
| Metal submission rate | 19.73 submissions/s |
| Metal submissions measured | 128 over 6.49 active seconds |
| CPU command submission average | 0.069 ms |
| CPU command submission P95 | 0.104 ms |
| CPU encoder average | 0.049 ms |
| GPU activity interval average | 8.34 ms |
| GPU activity interval P95 | 51.12 ms |
| GPU activity interval maximum | 53.61 ms |
| Physical footprint, stable average | 1.126 GiB |
| Physical footprint range | 1.122–1.190 GiB |
| Threads | 7–8 |
| CPU percentage while stable | 5.16% average |
| Scene data read | 755.6 MiB observed by Activity Monitor |
| Thermal state | Nominal throughout |
| Crash/Jetsam | None during all captures |

## CPU profile

Time Profiler captured 1,613 running samples. The application spends much of its time waiting for work/GPU completion. The most important application-side CPU work remains depth sorting:

- Swift `_merge` leaf: 170 samples, 10.5%.
- Stable-sort closure: 67 samples, 4.2%.
- `SplatSorter.performSort` appears directly and is the parent path for additional merge-sort work.

CPU-side Metal encoding is inexpensive: command submission P95 is only 0.104 ms. CPU encoding is not the frame-rate bottleneck.

## GPU and frame pacing

The observed rate is about 19.5 FPS, corresponding to a frame budget of roughly 51.3 ms. GPU activity P95 is 51.12 ms and maximum is 53.61 ms, closely matching that frame budget. This indicates the 500w scene is principally limited by GPU work and/or GPU-dependent synchronization at the current resolution.

The GPU trace contains fragment, vertex, and compute activity. Compute work includes splat processing/sorting support, while vertex and fragment work scale with the number and screen coverage of visible splats.

## Memory and stability

The stable physical footprint is approximately 1.13 GiB. The app remained alive through Time Profiler, Game Performance, Game Memory, and Activity Monitor recordings, and the device thermal state stayed Nominal. No crash, Jetsam termination, Metal command-buffer error, or thermal throttling was observed.

Although stable in this test, 1.13 GiB is a material mobile memory footprint. Background pressure from other apps can reduce the available Jetsam budget.

## Recommendations

1. Add a mobile quality mode that reduces rendered splats using distance, opacity, or projected-size culling.
2. Target 30 FPS explicitly for the 500w scene; achieving it requires bringing P95 frame time below 33.3 ms.
3. Cache depth order and avoid a full CPU sort for FOV-only pinch changes.
4. Add GPU-side radix sorting or tiled/bin-based sorting for camera rotation.
5. Stream/chunk the PLY and preserve only GPU-ready packed data after loading.
6. Add dynamic resolution or point-budget scaling when GPU frame time exceeds 30–33 ms.

## Trace locations

All raw `.trace` files and exported XML tables are in:

`dist/performance/bicycle500w-ios/`
