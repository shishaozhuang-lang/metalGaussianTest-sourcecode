# vsync 与离屏（offscreen benchmark）模式差异解析

> 附属于 [REPORT.md](REPORT.md)（dazhongkafei 双平台性能测试）。
> 本文回答：同一模型、同一视角、同一台机器，为什么 `--benchmark-frames`（离屏）与 `--perf`（vsync）测出不同的帧耗时/帧率，两者各自测的是什么，数字如何互相换算与印证。

## 1. 两种模式的机制差异（代码级）

### 离屏 benchmark（`MetalKitSceneRenderer.runFrameBenchmark`，`MetalKitSceneRenderer.swift:529-571`）

```
for 0..<N:
    commandBuffer = commandQueue.makeCommandBuffer()
    inFlightSemaphore.wait()          ← 3 个许可（maxSimultaneousRenders）
    render(viewports, colorTexture: 离屏私有纹理, colorStoreAction: .dontCare, …)
    commandBuffer.commit()            ← 立即提交，不等 vsync
    (completedHandler → semaphore.signal)
```

- 渲染目标：一块 `.private` 存储、`.renderTarget` usage 的**固定离屏纹理**，永不 present
- 无 MTKView 参与循环（绕过 drawable 获取与 vsync 门限）
- 唯一的节流：`inFlightSemaphore(3)` —— 同时最多 3 个 command buffer 在 GPU 排队
- `colorStoreAction = .dontCare`：GPU 无需把 tile memory 写回纹理（省一次 store pass）
- CPU 侧循环连续提交，GPU 侧最多 **3 帧 overlap 并发执行**

### vsync perf（`draw(in:)` 主渲染路径，`MetalKitSceneRenderer.swift:573-644`）

```
MTKView 帧回调（由 preferredFramesPerSecond/显示 vsync 驱动, 60Hz）
    inFlightSemaphore.wait()
    render(…, colorTexture: fixedRenderSize ? 离屏纹理+imageScaler : drawable.texture,
           colorStoreAction: .store, …)
    commandBuffer.present(drawable)   ← 呈现到屏幕, 等待下一个 vsync
    commandBuffer.commit()
```

- 节流链多三层：MTKView 定时器（vsync 对齐）→ drawable 获取（CAMetalLayer 队列）→ present 等待
- `--render-size`（或 view.json 的 render_resolution）非 nil 时走"离屏纹理 + MPSImageBilinearScale 放大到 drawable"路径：3DGS 渲染本身离屏，但每帧末尾多一个 scale pass + present
- CPU 编码在 GPU 落后时会被 semaphore 阻塞（表现为 access_wait 上升）

### 第三模式（对照用）：`--no-present` + `--max-fps=0`

走完整 vsync 帧循环（drawable 路径、`.store`），但**跳过 present** 且定时器设 240Hz：剥离 vsync 对齐、保留 drawable/store 开销。本次实测 Mac 540：79.1 FPS ≈ 离屏 78.3 FPS —— 证明 drawable 路径本身开销可忽略，**差异几乎全部来自 vsync 对齐与 in-flight 并发度**。

## 2. 实测数字与自洽推导

### Mac（M5）

| 模式 | 540×960 | 1080×1920 |
|---|---:|---:|
| 离屏墙钟帧耗时 | 12.65ms（79 FPS） | 14.69ms（68 FPS） |
| 离屏单 command buffer GPU 执行（trace 按进程归因） | **avg 22.3ms** / p50 21.1ms | — |
| vsync 单 command buffer GPU 执行 | **avg 13.6ms / p50 13.4ms**（11-16ms 直方峰） | **avg 16.5ms / p50 15.9ms** |
| vsync 帧率 | 60.1（100% 1×vsync） | 60.1（100% 1×vsync） |
| no-present uncapped | 79.1 FPS | 67.6 FPS |

**为什么离屏 GPU 单帧 22.3ms 却能 12.65ms/帧吞吐？**
in-flight=3：GPU 同时执行 3 个 command buffer（同一个 draw 在不同 cb 里重叠），吞吐 = 3×1000/22.3 ≈ 134 FPS 的 GPU 上限；实际瓶颈回到 CPU 侧编码+提交串行（~5ms/帧）+ 信号量调度 → 12.65ms/帧。**离屏测的是"流水线稳态吞吐"，不是单帧 GPU 延迟。**

**为什么 vsync 单帧 GPU 只有 13.4ms，比离屏的 22.3ms 还快 40%？**
两个因素：(a) vsync 模式下 cb 一帧一帧串行提交（present 门限），GPU 上的 overlap 消失，每个 cb 独占 GPU 资源，无 3 路并发争用；(b) 轻载（2.76ms→13.6ms 的真实渲染 + 空闲间隙）下 GPU 拉高频率，满载离屏时降频。同帧 GPU 时间因此不同。这正说明**两种模式测的是不同东西**：
- 离屏 12.65ms/帧 = 满载降频 + 3 并发争用下的**吞吐**
- vsync 13.4ms/帧 = 独占 + 高频下的**单帧延迟**（仍 < 16.7ms 预算 → 满帧 60）

iPhone 也有对应现象：离屏 18.9ms/帧（540），而 vsync p50 帧间隔 21ms ≈ 1×GPU 帧长 + vsync 排队。

### iPhone（17 Pro Max）

| 模式 | 540×960 | 1080×1920 |
|---|---:|---:|
| 离屏墙钟帧耗时 | 18.91ms（52.9 FPS） | 24.98ms（40.0 FPS） |
| vsync 帧间隔 p50 | 21.0ms → 44 FPS | 42.0ms → 23 FPS |
| vsync 帧间隔 vsync 倍数分布 | 1拍:60% 2拍:22% 0拍:12% | 2拍:27% 3拍:36% 4拍:21% 1拍:16% |
| no-present uncapped | 46.4 FPS（p50 17ms，p95 34ms） | — |

iPhone 上 vsync 帧率（44/23）**低于**离屏吞吐（52.9/40）的直接原因是 **vsync 量化（frame pacing）**：

```
呈现帧率上限 = 1000 / (16.67ms × ceil(GPU帧长 / 16.67ms))
```

| GPU 帧长 | 占用拍数 | 量化后上限 | 实测 |
|---|---|---:|---|
| 18.91ms（540 离屏） | 2 拍 | 30 FPS | 实测 44 —— 因为不是每帧都满长（直方图显示 12% 帧落在 0-1 拍内追回了部分帧） |
| 24.98ms（1080 离屏） | 2 拍 | 30 FPS | 实测 23 —— 25ms 帧长在 2/3 拍边界抖动（2拍 27% / 3拍 36% / 4拍 21%），平均落在 3 拍 |
| 13.4ms（Mac 540 vsync） | 1 拍 | 60 FPS | 实测 60.1 ✓ |
| 16.5ms（Mac 1080 vsync） | 1 拍 | 60 FPS | 实测 60.1 ✓（贴边：p95 19.9ms 已越界，靠多数帧追回） |

注意 iPhone 540 的 44 FPS **高于** 2 拍量化上限 30 FPS：A19 Pro 的 GPU 帧长抖动大（p95 38ms vs p50 21ms），短帧（0/1 拍）能挤进下一个 vsync 窗口，呈现帧率是长短帧混合的加权结果，不是纯量化值。1080 时帧长整体后移，几乎无短帧可挤 → 掉到 23 FPS。

## 3. 两种模式各自的用途与陷阱

| | 离屏 benchmark | vsync perf |
|---|---|---|
| 测什么 | CPU 编码吞吐 + GPU 满载吞吐（3 并发、降频态） | 用户实际观感的帧节奏（呈现帧率） |
| 适合 | 对比代码改动前后纯吞吐、A/B 优化回归 | 评估"能否满帧""掉帧体感" |
| 陷阱 1 | 帧率 ≠ 用户看到的帧率（iPhone 53 vs 44） | 受后台/温控/ProMotion 调度影响 |
| 陷阱 2 | `.dontCare` 省掉 store pass，数字略乐观 | fixedRenderSize 路径含 MPS scale pass 开销 |
| 陷阱 3 | in-flight=3 并发把 GPU 单帧延迟掩盖掉 | 帧间隔含 vsync 排队，不能直接当 GPU 帧长 |

**判读规则（本次得出）**：
1. 离屏帧耗时 ≪ 16.7ms → vsync 必满帧（Mac 1080：14.7ms → 60）
2. 离屏帧耗时 ∈ (16.7, 33.4] → vsync 落在 30-60 区间抖动（iPhone 540：18.9 → 44）
3. 离屏帧耗时 > 33.4ms → vsync 掉到 30 以下（iPhone 1080：25ms 边界抖动 + 无短帧 → 23）
4. 想知道"离屏数字为什么和 vsync 不一致"，先看 GPU 帧长分布落在第几拍，再看有没有短帧补位。

## 4. GPU trace 归因方法论（本次踩坑记录）

- `metal-gpu-intervals` 表按**通道**（Vertex/Fragment/Compute）给出所有进程的 GPU 区间。直接取通道均值会被 WindowServer/loginwindow 的海量微任务稀释（Mac 上曾误读出"fragment 1.26ms"——实际 SampleApp 单 cb p50 13.4ms）。
- 正确归因：`metal-application-command-buffer-submissions` 表按 `process`（fmt 字段含进程名）筛出 SampleApp 的 command buffer id，回Join `metal-gpu-intervals` 的 `cmdbuffer-id` 列，按 cb 聚合 duration。每帧 ≈ 2.4 个 GPU interval（DrawSplats 的 vertex+fragment 多段 + postprocess）。
- xctrace XML 的字典列（process/thread）跨行用 `id`/`ref` 去重引用，解析时需维护全局 id→值缓存；process 的值常只出现在 `fmt` 属性里。
- 首次录的 vsync trace（`mac-metal-*.trace`）里 SampleApp 事件缺失（只有 WindowServer/loginwindow）——同参数重录（`mac-vsync2-*.trace`）后正常；用旧 trace 做的通道均值不可靠。

## 5. 结论

1. **两种模式测的物理量不同**：离屏 = 满载降频 + 3-in-flight 并发的吞吐上限；vsync = 单帧独占 GPU 的延迟 + 呈现节奏。数字不可互换，但可互相印证。
2. Mac 上两者自洽：vsync 单帧 GPU 13.4/16.5ms < 16.7ms 预算 → 满帧；离屏吞吐 79/68 FPS（GPU 并发上限 ~134 FPS 被 CPU 串行压到 79）。
3. iPhone 上 vsync < 离屏由 **vsync 量化 + 帧长抖动**共同决定：540 靠短帧补位得到 44；1080 帧长后移无补位掉到 23。
4. 报性能数字时应同时给出两者：离屏吞吐回答"还有多少优化空间"，vsync 帧率回答"用户体验是什么"。单报任何一个都会误导——离屏 52.9 FPS 会让人以为 540 接近满帧，实际呈现只有 44。
