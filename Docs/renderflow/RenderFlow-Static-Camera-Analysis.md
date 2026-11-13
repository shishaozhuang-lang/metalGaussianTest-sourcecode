# 3DGS 渲染流程分析：视角不动时每帧是否全量执行

> 测试日期：2026-11-10 · 模型：hailuo point_cloud.ply（1,153,429 splats）· macOS Release 构建
> 原始日志：`frame-log-static-camera-default.txt`（默认配置）、`frame-log-static-camera-no-opt.txt`（禁用优化对照）

## 结论（先答问题）

**视角不动时，每帧都执行完整的 GPU 渲染流程；CPU 深度排序被跳过。**

| 流程阶段 | 视角不动时 | 说明 |
|---|---|---|
| MTKView draw() 回调 | 每帧执行 | 60 FPS 连续渲染循环，`isPaused = false` |
| render() 完整编码 | **每帧执行** | uniforms 写入 → chunk 表 → pipeline 绑定 → draw call（drawIndexedPrimitives） |
| GPU 光栅化 + 混合 | **每帧全量** | 429,240 个可见 splat × 每个实例 6 个顶点 = ~256 万顶点/帧 |
| CPU 深度排序 | **跳过** | `sortPoseCaching` 检测 pose/visibility 均未变化，直接返回，排序循环静默 |
| interaction 限频 (12Hz) | 不触发 | 仅在交互（拖拽）期间生效，静态时无影响 |

## 实测证据

### 默认配置稳态（视角完全静止，25 秒）

```
[frame 4xx] OK (full pipeline ran)        ← 每帧都是完整流水线
render OK: splats=429240 indexed=1024 instances=420 chunks=1 multiStage=true encode=0.017ms
sort SKIP: camera pose unchanged (sortPoseCaching)   ← 每帧排序请求被 pose 缓存拦截
```

- **1433/1433 帧**完整执行渲染流水线（0 帧 SKIP render；前 40 帧 SKIP 是模型加载期，非渲染跳过）
- **0 次重排序**（稳态 25 秒内 `sort START` = 0）
- 稳态 CPU 编码耗时：avg 0.119ms / 帧峰值 1.232ms
- 稳态帧率 ≈ 60.5 FPS（vsync 锁定）

### 对照组：`--disable-render-optimizations`

```
sort DONE: 1153429 visible of 1153429 total, 49.349 ms
```

- 15 秒内 **280 次完整排序**（每帧一次，~49ms/次），单核持续满载
- 关闭 pose 缓存后，排序循环每帧都触发，CPU 开销完全反弹

## 代码级依据

### 1. render() 无条件全量执行 — `MetalSplatter/Sources/SplatRenderer.swift:1102-1323`

`render()` 中不存在任何“相机静止即跳过”分支。每帧顺序执行：

```
acquireAccess → chunkList → poseUpdate(sorter) → obtainSortBuffer →
uniforms → chunksBuffer → pipeline → renderEncoder → indexBuffer →
residency(遍历所有chunk useResource) → drawIndexedPrimitives → endEncoding
```

唯一的帧间复用机制（与“相机是否移动”无关）：
- `buildSingleStagePipelineStatesIfNeeded()`：PSO 首帧编译后缓存（`SplatRenderer.swift:691-695`）
- `buildChunksBuffer` 的 `chunkTableCaching`：chunk 表内容不变时复用 buffer（`SplatRenderer.swift:929-930`）
- 三角形索引 buffer：容量足够时跳过重建（`SplatRenderer.swift:1214-1231`）

### 2. 排序跳过点 — `MetalSplatter/Sources/SplatSorter.swift:363`（含本日新增日志）

```swift
guard !performanceOptimizationOptions.contains(.sortPoseCaching)
        || pose != state.cameraPose
        || visibility != state.visibility else { return false }   // ← 视角不动时每帧走这里
```

- pose = (position, forward)；visibility = (viewProjection 矩阵 4 列 + screenSize + culling 参数)。
  两者逐分量 Equatable 比较，浮点完全一致才跳过。
- skip 分支直接 return，`needsSort` 不置位 → 排序循环 (`sortLoop`) 静默，无 CPU 消耗。
- 注意：`interactionSortRateLimit`（12Hz 合并）只挂在交互态 (`isInteracting`)，与静止场景无关。

### 3. GPU 侧无任何"复用上一帧"机制

- 每帧都重新 `drawIndexedPrimitives` 42.9 万 splat（`SplatRenderer.swift:1284-1289`）
- 多阶段管线（macOS 深度路径）每帧执行 Initialize → Draw Splats → Postprocess 三个 dispatch（`SplatRenderer.swift:1242-1303`）
- render pass 每帧 clear 重画，无 history buffer / TAA / 重投影等帧间复用
- visionOS 路径的 reprojection 是系统级的（应用外），此 macOS viewer 不涉及

### 4. 帧循环驱动 — `SampleApp/Scene/MetalKitSceneRenderer.swift:573-644`

`MTKView.isPaused = false` + `enableSetNeedsDisplay = false` → 连续渲染循环，与相机状态解耦。
`--no-present` / `--max-fps=0` 可脱钩 vsync 测峰值吞吐。

## 渲染流水线全图（每帧）

```
MTKView.draw (vsync 60Hz, main thread)
 └─ modelRenderer.render()                        [SplatRenderer.swift:1046]
     ├─ accessState: 独占/串行/inFlight 门限       (0.001ms)
     ├─ orderedChunkIDs → allChunks 列表           (字典+数组映射)
     ├─ sorter.updateCameraPose(pos, fwd, vis)     ★ pose 缓存跳过点
     ├─ sorter.tryObtainSortedIndices()            引用计数+3 buffer 轮转
     │    └─ 返回最近一次有效排序 buffer（可能落后 N 帧）
     ├─ switchToNextDynamicBuffer + updateUniforms (每帧写 P/V/焦距/阈值)
     ├─ buildChunksBuffer                          ★ chunkTableCaching 复用点
     ├─ buildPipelineStatesIfNeeded                ★ 首帧后跳过（PSO 缓存）
     ├─ renderEncoder (renderPassDescriptor: clear → draw)
     │    ├─ multiStage: Initialize tile memory dispatch
     │    │             DrawSplats (vertex: 视锥/半径/透明度 cull → 投影 2D 高斯)
     │    │             Postprocess: tile memory → color+depth
     │    └─ singleStage: 一次 draw
     │    └─ drawIndexedPrimitives(1127 instances × 6 verts)
     └─ endEncoding → (调用方) commit + present
```

★ = 仅有的三个帧间复用机制，全部与"相机移动与否"无关，是纯资源缓存。

## 随视角移动的变化（供对照理解）

| 事件 | 效果 |
|---|---|
| 移动/旋转相机 | pose 变化 → `needsSort = true` → 后台排序线程全量 CPU 排序（1.15M splats ~50ms） |
| 拖拽中 | `interactionSortRateLimit` 把排序请求合并到 12Hz；渲染仍 60FPS 全量 |
| 排序滞后 | 渲染使用旧排序 buffer 继续跑（不阻塞），下一个有效 buffer 就绪后切换 |
| 松手 | 补一次精确排序 |
| 增删 chunk | 立即 patch + 后台重排 |

## 对性能的含义

1. **静态场景 CPU 几乎零开销**（encode 0.119ms/帧），瓶颈全在 GPU。要让 GPU 也休息，需要应用层加"脏标记 + 跳帧"逻辑（MetalSplatter 库本身无此设计）。
2. **CPU 排序是动态场景的大头**：1.15M splats 全排一次 ~50ms（单核）。这是后续优化（GPU 排序/分块增量排序）的靶点。
3. **CPU culling 在排序阶段顺带执行**：hailuo 模型 1.15M → 42.9 万可见 splat（剔除 63%），cull 发生在 CPU 排序前，因此视角不动时 GPU 每帧绘制的是**上次排序时的可见集**——若屏幕上 culling 参数变化（如窗口 resize），visibility 变化会触发重排。窗口 resize 会改变 visibility → 触发重排 → 可见集更新。

## 修改记录（本日新增的日志设施）

- `SplatSorter.swift`：新增 `debugLogSorts` 开关 + 三个日志点（pose-skip / rate-limit-skip / START/DONE）
- `SplatRenderer.swift`：公开 `debugLogSorts` 转发属性（Swift 6 `nonisolated(unsafe)`，写入时机在模型加载前，稳态只读）
- `MetalKitSceneRenderer.swift`：`--frame-log` 现在同时启用 render 帧日志和 sort 决策日志
- 编译验证：Release 构建通过；两次实测运行（默认/禁用优化）日志行为符合预期
