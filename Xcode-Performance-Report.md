# MetalSplatter Xcode Performance Report

## Test setup

- Build: Release, whole-module optimization (`-O`)
- Host: MacBook Pro, Apple M1 Pro, macOS 26.6.2
- Scene: `bicycle120w/point_cloud.ply` (284 MB)
- Tools: Xcode 26.6 Instruments Time Profiler and Game Performance
- CPU trace: 25 seconds, 17,880 samples
- GPU trace: 20 seconds, 7 seconds of active Metal submission data

The iPhone build and installation succeeded, but the connected phone remained locked. iOS denied process launch, so the measurements below are host measurements and must not be treated as iPhone results.

## Results

| Metric | Result |
|---|---:|
| Stable resident memory | about 1.39 GB |
| Stable CPU usage | about 200–204% (roughly two CPU cores) |
| Metal command buffers | 565 over 7.0 seconds |
| Command-buffer submission rate | 80.7/s |
| CPU command submission time, average | 0.104 ms |
| CPU command submission time, P95 | 0.147 ms |
| CPU encoder time, average | 0.069 ms |
| GPU activity interval, average | 2.35 ms |
| GPU activity interval, P95 | 5.52 ms |
| GPU activity interval, maximum | 8.86 ms |

## CPU hot paths

The dominant sampled work is splat depth sorting:

- Swift merge-sort `_merge`: 7,575 samples (42.4%).
- Collection/indexing and pointer operations used by sorting are the next largest groups.
- `SplatSorter.performSort`: appears directly as a leaf in 173 samples and is present in the parent stack of the merge-sort samples.

The renderer therefore spends substantially more CPU time sorting splats than encoding Metal command buffers. Metal encoding itself is inexpensive (P95 below 0.15 ms).

## Interpretation

- GPU execution stays below 8.86 ms in this host trace, which is compatible with a 60 Hz frame budget on the M1 Pro.
- The submission rate is about 80.7/s rather than the display's full refresh rate. The CPU sorting pipeline is the primary limiter.
- A 284 MB PLY expands to about 1.39 GB resident memory. Loading the 3k/7k/30k garden scenes concurrently should be avoided.
- Loading and sorting should remain off the main actor where possible. Re-sorting every frame when only the projection FOV changes is unnecessary; pinch zoom can reuse the current depth order until camera orientation or position changes materially.

## Recommended next optimizations

1. Cache depth order and only sort when camera rotation/translation exceeds a threshold.
2. Throttle sorting during gestures to 30–60 Hz while continuing GPU rendering at display cadence.
3. Move sorting to a GPU compute/radix-sort path for high point counts.
4. Stream or chunk PLY data and release parser-side arrays immediately after uploading Metal buffers.
5. Capture the same Time Profiler, Game Performance, and Game Memory templates on the unlocked iPhone before setting mobile quality defaults.

## Trace files

- `dist/performance/TimeProfiler.trace`
- `dist/performance/GamePerformance.trace`
- Exported XML tables are stored beside the trace files.
