# 3DGS 渲染流程方案分析

> 本文档分析 MetalSplatter 的完整 3DGS 渲染方案：架构分层、每帧执行路径、关键数据结构、并发模型与优化机制。
> 静态视角下每帧执行情况的实测结论见 `RenderFlow-Static-Camera-Analysis.md`。
> 数据格式与精度（文件格式量化、GPU 布局、Float16/UInt8 压缩）见 [Data-Format-Precision-Analysis.md](Data-Format-Precision-Analysis.md)。

## 1. 架构分层

```
┌─────────────────────────────────────────────────────┐
│ SampleApp (应用层)                                    │
│  MetalKitSceneRenderer — MTKView 帧循环、相机控制       │
│  VisionSceneRenderer  — visionOS CompositorServices   │
├─────────────────────────────────────────────────────┤
│ MetalSplatter (渲染核心)                              │
│  SplatRenderer   — 编码每帧 GPU 命令、uniforms、管线   │
│  SplatSorter     — 后台 CPU 深度排序 + CPU 剔除        │
│  SplatChunk      — splat 数据容器(Morton 局部性排序)   │
│  MetalBuffer     — 托管+自动扩容的 MTLBuffer 封装      │
├─────────────────────────────────────────────────────┤
│ SplatIO / PLYIO (数据格式)                            │
└─────────────────────────────────────────────────────┘
```

- 生成产品: SampleApp (macOS/iOS/visionOS)。
- 渲染目标: MTKView drawable（macOS/iOS）或 CompositorServices 层纹理（visionOS）。

## 1.5 三条平台路径

| 平台 | 驱动 | 深度格式 | 管线选择 | SH 绑定 |
|---|---|---|---|---|
| macOS | MTKView 连续渲染循环 | depth32Float | **多阶段** (writeDepth && highQualityDepth) | buffer/texture |
| iOS (viewer) | MTKView 连续循环 | invalid (无深度) | **单阶段** | buffer/texture |
| visionOS | CompositorServices LayerRenderer | 依赖 CompositorServices | 多阶段 (tile memory 混合深度) | buffer/texture |

多阶段 vs 单阶段 (`SplatRenderer.swift:246-252`)：
- 单阶段: VS+FS 直接混合到颜色+深度附件。
- 多阶段: Initialize tile memory → Draw Splats(在 tile memory 上混合颜色和深度) → Postprocess(拷贝到附件)。深度混合用 alpha 加权 → 连续深度 → 适合 visionOS 重投影。

## 2. 每帧完整执行路径

```
MTKView.draw / CompositorServices frame callback
 │
 ├─ updateRotation()/updateCameraMovement()     [SampleApp 层, 可选]
 │
 └─ SplatRenderer.render(viewports, color, depth, cb)   [SplatRenderer.swift:1046]
     │
     ├─ (1) 接入控制: AccessState (Mutex)                          ~0.001ms
     │       独占访问检查 → isRendering 串行 → inFlight < maxSimultaneousRenders
     │       失败重试(1ms 轮询)直至 accessTimeout(默认0.1s) → 否则 SKIP
     │
     ├─ (2) chunk 列表: orderedChunkIDs.compactMap { chunks[$0] }   ~0.01ms
     │       chunk index = 数组下标; chunkIDToIndex 重建于增删时
     │
     ├─ (3) 相机 pose → SplatSorter.updateCameraPose               ~0.01ms
     │       ★ sortPoseCaching: pose/visibility 全等 → 直接返回(静态视角跳过排序)
     │       ★ interactionSortRateLimit: 交互中合并为 12Hz
     │
     ├─ (4) tryObtainSortedIndices() — 获取排序 buffer 引用        ~0.01ms
     │       3 buffer 轮转 + 引用计数; 排序中/无效 → 等待 sortTimeout(0.1s)
     │       排序 buffer 允许落后当前帧(不阻塞渲染, 用旧排序)
     │       addCompletedHandler: GPU 完成后 releaseSortedIndices
     │
     ├─ (5) splatCount==0 检查 → indexedSplatCount/instanceCount 计算
     │       indexed = min(splatCount, 1024 或 4096); instances = ceil(splat/indexed)
     │
     ├─ (6) switchToNextDynamicBuffer + updateUniforms             ~0.05ms
     │       maxSimultaneousRenders 个 UniformsArray 槽轮转(256B 对齐)
     │       写入: P/V 矩阵, cameraPos, screenSize, focal, tanHalfFov,
     │             chunkCount, splatCount, optimization flags, SH 纹理参数
     │
     ├─ (7) buildChunksBuffer                                        ~0.01ms
     │       ★ chunkTableCaching: 表内容不变(dirty flag) → 复用 buffer
     │       否则快照: splats GPU 指针/SH 指针/splatCount/SH degree/enabled
     │       (新分配不可变 buffer, 不改写 in-flight 共享 buffer)
     │
     ├─ (8) buildPipelineStatesIfNeeded                              首帧后 ~0
     │       ★ PSO 缓存: 首帧编译管线 (single/multi-stage), 之后跳过
     │
     ├─ (9) renderEncoder 创建 + 绑定                                ~0.03ms
     │       renderPassDescriptor: color .clear+store, depth .clear+store,
     │       tile 32×32, 可选 rasterizationRateMap / renderTargetArrayLength
     │       setViewports, 多视口 vertexAmplification
     │       (可选) MTLCounterSampleBuffer 时间戳采样(帧 1-10 + 每 30 帧)
     │
     ├─ (10) 三角形索引 buffer: 容量足够时跳过重建                    ~0.001ms
     │        每个 indexed splat: 4 顶点 → 2 三角形(6 索引), 共 instance 份
     │
     ├─ (11) useResource 声明驻留: 遍历所有 chunk 的 splats/SH buffer/纹理
     │
     ├─ (12) drawIndexedPrimitives(triangle, instanceCount × 6)     CPU ~0.001ms
     │        multiStage: 前后各一个 dispatchThreadsPerTile(Initialize)
     │                    + drawPrimitives(3 顶点, Postprocess)
     │
     └─ endEncoding → 调用方 commit + present
```

CPU 端每帧编码总耗时: 稳态 ~0.12ms（vsync 60Hz 下 CPU 占比 <1%）。

## 3. 数据结构

### 3.1 Splat 顶点数据 (EncodedSplatPoint)
GPU 每 splat 读取: position, covA/covB (协方差), colorSH0 (rgba), colorSH1...3 (视向相关颜色)。

### 3.2 GPUChunkInfo (24B/chunk) — `SplatRenderer.swift:202-209`
```c
splatsPointer (8B 设备指针) | shCoefficientsPointer (8B) | splatCount (4B)
| shDegree (1B) | enabled (1B) | padding (2B)
```
shader 用 device 指针直接寻址 chunk 数据（argument buffer 风格，非按 chunk 绑定）。

### 3.3 ChunkedSplatIndex (索引 buffer 条目)
```c
chunkIndex: UInt16 | splatIndex: UInt32
```
排序线程按深度序写入; 顶点着色器按 instanceID/indexID 反查 → chunk 表 → splat 数据。

### 3.4 Uniforms — `SplatRenderer.swift:158-180`
P/V 矩阵 + 预投影值 (focal/tanHalfFov) + 优化 flags + SH 纹理参数; 每视口一份, maxViewCount=2 (立体渲染)。

## 3.5 排序 buffer 池 — `SplatSorter.swift:83-98`
3 个 buffer 轮转, 各自引用计数 + 有效性标志。渲染持引用期间排序不能写入该 buffer。

## 4. 并发模型

```
主线程 (render 编码)              后台排序 Task.detached(.high)
    │                                    │
    │ updateCameraPose(pose,vis)         │ sortLoop: needsSort?
    │──────────── Mutex<State> ──────────│
    │ tryObtainSortedIndices() ──→ 返回   │ performSort: 读 chunks(锁 isReadingChunks)
    │    (buffer引用+1)                  │   → 深度计算+CPU剔除 → sort → 写 buffer
    │ commandBuffer.addCompletedHandler  │   → isValid=true, mostRecentValid=idx
    │    → releaseSortedIndices(引用-1)  │
```

- **双 Mutex**: AccessState (render/chunk 独占协调), State (sorter 内部状态)。
- **串行 render**: `isRendering` 标志保证同一时刻只有一个 render() 在编码。
- **inFlight 门限**: maxSimultaneousRenders (3) 限制 GPU 排队。
- **排序不阻塞渲染**: 渲染拿旧 buffer, 排序在另一个 buffer 上写, 3-buffer 轮转。
- **chunk 增删**（withChunkAccess）: 等待 inFlight=0 → 独占 → patch 现有有效 buffer（新 chunk append 未排序索引; 删除 remap）→ 触发重排。

## 5. 优化机制全景

`PerformanceOptimizationOptions` 位集 (`SplatRenderer.swift:9-64`)，四层机制：

| 层 | 选项 | 机制 | 静态视角效果 |
|---|---|---|---|
| 排序层 | sortPoseCaching | pose/visibility 相等 → 不置 needsSort | **排序完全静默** |
| 排序层 | interactionSortRateLimit | isInteracting 时 12Hz 合并 | 无影响(非交互态) |
| 排序层 | cpuOpacityCulling/cpuProjectedRadiusCulling/cpuFrustumCulling | 排序前 CPU 遍历剔除 | 随排序执行, 静态时无 |
| 渲染层 | chunkTableCaching | dirty 标志复用 chunk 表 buffer | 每帧复用(1 次构建) |
| 渲染层 | largeIndexedSplatBatches | indexed=4096 vs 1024 | 每帧生效 |
| GPU 层 | gpuOpacityCulling / gpuProjectedRadiusCulling / adaptiveGPU... | vertex shader 丢弃 | 每帧生效 |
| GPU 层 | sphericalHarmonics0/1/texture | SH 降阶/纹理化减少带宽 | 每帧生效 |
| GPU 层 | interactionSHReduction | 交互时 SH3→SH1 | 静态无影响 |
| 剔除层 | opacityThreshold2/3/25/4 | 透明度阈值选择 | 排序时生效 |

`--renderer-optimization-options` CLI 可逐项开关（`MetalKitSceneRenderer.swift:449-525`）。

## 6. 3DGS 渲染的 alpha 混合序约束

3DGS 是 alpha over 混合, 必须严格**后→前**绘制。整个流水线围绕这一点设计：

- CPU 全量深度排序（1.15M splats ~50ms）只发生在 pose 变化时；
- 渲染不等待排序完成, 使用最近有效排序(滞后 N 帧可接受, 排序滞后只造成混合误差, 不造成错误遮挡)；
- 多阶段管线的 tile memory 淡混合使深度也按 alpha 加权 (visionOS 重投影需要)；
- CPU 剔除在排序阶段顺带完成, 顶点着色器重复同样测试作为 GPU 安全网。

## 7. 方案对比（与业界其他 3DGS 渲染器）

| 方案 | MetalSplatter | A-Buffer / Per-pixel list | GPU radix sort (如 3DGS-MM) |
|---|---|---|---|
| CPU 开销 | 高(排序时~50ms/次, 仅 pose 变化时) | 低 | 低(仅 GPU 归约) |
| 混合精度 | 逐 splat back-to-front, 近似正确 | 逐像素精确排序 | 同 MetalSplatter(全局排序) |
| 3DGS 近似 | 排序滞后帧不影响遮挡正确性, 只影响半透明层间顺序 | 精确 | 精确 |
| 适合场景 | 桌面/头显观看 (帧间 pose 平滑) | 小规模/精确合成 | 大规模/高帧率 |
| 缺点 | 排序滞后可能造成轻微层间排序噪声 | 内存/带宽大 | GPU 排序管线复杂 |
| alpha 混合序 | ✓ 严格后→前 | ✓ | ✓ |

（对照表信息基于源码结构对比业界常见方案，性能数字来自本机实测。）

## 8. 关键设计取舍

1. **3-buffer 排序池 + 不阻塞渲染**: 排序滞后的代价是混合序噪声(肉眼几乎不可见), 换来渲染循环永不卡排序。
2. **PSO/chunk表/索引buffer 缓存**: 与相机无关的纯资源缓存, 是"静态视角下 GPU 全量重画"这一现状的原因之一 —— MetalSplatter 没有"帧间画面复用"机制, 所有缓存都是 CPU/GPU 资源级缓存。
3. **GPU 全量重画 vs 上一帧复用**: 当前方案每帧重画全部可见 splat。若需静态场景省 GPU, 需在应用层加"脏标记 + present 相同 drawable"或 MPS 框架的反演方案, 属于 MetalSplatter 之外的扩展。

## 9. 已知问题与改进方向

1. CPU 排序 1.15M splats ~50ms 单核 → GPU 排序(位图/bitmap sort)或分块增量排序。
2. 静态场景 GPU 每帧全量重画 429K splat → 应用层脏标记跳帧, 或 SH 纹理化后进一步降带宽。
3. 排序滞后 N 帧在快速移动时可能造成闪烁 → 可加"快速移动时强制阻塞等待最新排序"选项。
4. visionOS 重投影已有高连续深度 (多阶段管线), macOS 深度路径同样启用多阶段。
5. `interactionSortRateLimit` 12Hz + 60FPS 渲染: 交互中混合序误差最大 (排序最旧 5 帧)。

## 10. 附录

- 实测日志: `frame-log-static-camera-default.txt`, `frame-log-static-camera-no-opt.txt`
- 埧级观测工具: `--frame-log` (render/sort 决策日志), `--perf=csv` (PerfRecorder 遥测), `--benchmark-frames=N` (离屏峰值), `--no-present` (脱钩 vsync)
- 相关代码: `SplatRenderer.swift`, `SplatSorter.swift`, `MetalKitSceneRenderer.swift`, `VisionSceneRenderer.swift`
