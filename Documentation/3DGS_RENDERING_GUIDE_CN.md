# MetalSplatter 3DGS 渲染结构与 RealityKit 官方接口测试指南

## 1. 两条渲染路径

本仓库现有 SampleApp 使用自研 `MetalSplatter` Metal 渲染器，不使用
RealityKit `GaussianSplatComponent`。建议性能对比保留两条互不混合的路径：

1. **MetalSplatter 路径**：相同 PLY 经 `SplatIO` 解析，应用管理排序、pipeline、
   shader、command buffer 和 drawable。
2. **RealityKit 路径**：相同 PLY 经 `SplatIO` 解析后转成 `LowLevelBuffer`，由
   `GaussianSplatResource` 和 `GaussianSplatComponent` 交给 RealityKit 渲染。

这样可以分别测量公共的解析成本、各自的资源构建成本，以及稳定渲染时的 GPU、
CPU、内存和功耗。

## 2. 本项目 shader 的位置

所有 3DGS shader 位于 `MetalSplatter/Resources`：

| 文件 | 作用 |
|---|---|
| `ShaderCommon.h` | Swift/Metal 共享布局：uniform、splat、chunk、排序索引、SH 常量和 buffer index |
| `SplatProcessing.h` | 投影、SH、vertex/fragment 公共函数声明 |
| `SplatProcessing.metal` | SH0-SH3、sRGB 转换、3D covariance 投影、2D 特征分解、quad 顶点生成和 Gaussian alpha |
| `SingleStageRenderPath.metal` | 普通 vertex + fragment 路径；颜色走固定功能 premultiplied-alpha blending |
| `MultiStageRenderPath.metal` | tile imageblock 初始化、splat 合成、alpha 加权深度和全屏后处理 |

Swift 侧的 pipeline 创建、资源绑定和 draw 位于
`MetalSplatter/Sources/SplatRenderer.swift`；点数据编码位于
`EncodedSplatPoint.swift`，排序位于 `SplatSorter.swift`。

## 3. CPU 到 GPU 的资源结构

### 3.1 输入

`AutodetectSceneReader` 根据扩展名读取 PLY、SPLAT 或 SPZ，输出 `[SplatPoint]`。
每点包含：

- `position: SIMD3<Float>`
- `scale`: 指数域或线性域
- `rotation: simd_quatf`
- `opacity`: logit、线性 float 或 UInt8
- `color`: sRGB UInt8 或 SH0-SH3 float coefficients

### 3.2 `SplatChunk`

`SplatChunk(device:from:)` 创建：

- `MetalBuffer<EncodedSplatPoint>`：位置、SH0/alpha、压缩 covariance；
- 可选 `MetalBuffer<Float16>`：SH1-SH3 的高阶系数；
- `SHDegree`：chunk 级别统一 SH 阶数。

`addChunk` 默认调用 `sortByLocality()`，以 Morton code 重排点，改善渲染缓存局部性。

### 3.3 GPU 表和排序索引

每帧创建/复用三类绑定：

| Buffer index | Metal 名称 | 内容 |
|---:|---|---|
| 0 | `BufferIndexUniforms` | 最多两个 viewport 的 projection/view/camera/screen/focal/计数 |
| 1 | `BufferIndexChunks` | `ChunkInfo[]`：splat/SH GPU pointer、点数、SH 阶数、enabled |
| 2 | `BufferIndexSplatIndex` | 后到前排序的 `(chunkIndex, splatIndex)` |

禁用 chunk 仍参与 CPU 排序和 GPU vertex 处理；需要真正降低成本时应删除高档 chunk，
而不是只把它设为 disabled。

## 4. 单阶段 pipeline

入口：

- `singleStageSplatVertexShader`
- `singleStageSplatFragmentShader`

vertex shader 根据 `vertex_id / 4` 和 instance 计算 splat ID，读取排序索引和 chunk，
执行 bounds/enabled 检查后进入 `splatVertex`：

1. 转换到 view space 并剔除相机后方点；
2. 根据相机到点的方向求 SH 颜色；
3. 将 3D covariance 用投影 Jacobian 转成 2D covariance；
4. 对 2D covariance 求特征值和特征向量；
5. 生成覆盖约 `3 sigma` 的屏幕空间 quad；
6. 把训练空间的 sRGB 近似转换到线性空间。

fragment shader 计算：

```text
alpha = exp(-0.5 * dot(relativePosition, relativePosition)) * splatOpacity
color = alpha * linearRGB
```

输出 premultiplied alpha。该路径可以写普通深度，但不能得到多个透明 splat 的连续
alpha 加权深度。

## 5. 多阶段高质量深度 pipeline

启用条件：真机、存在 depth texture、`highQualityDepth == true`。

阶段：

1. `initializeFragmentStore`：清空 tile imageblock 的 color/depth；
2. `multiStageSplatVertexShader`：与单阶段相同的 splat 投影；
3. `multiStageSplatFragmentShader`：使用 raster-order group 在 tile 内按透明度合成颜色和深度；
4. `postprocessVertexShader`：生成全屏三角形；
5. `postprocessFragmentShader`：输出颜色和 `weightedDepth / accumulatedAlpha`。

这个路径主要改善 Vision Pro frame reprojection 所需的深度连续性，代价是更多 pass、
tile memory 和 fragment 工作。功耗测试必须把 `highQualityDepth=true/false` 分开。

## 6. Pipeline 配置入口

`SplatRenderer` 初始化参数：

- `colorFormat` 必须与目标 color texture 一致；
- `depthFormat` 为 `.invalid` 时关闭深度；
- `sampleCount` 必须与 render target 一致；
- `maxViewCount` 内部限制为 2；
- `maxSimultaneousRenders` 决定 uniform ring 和 in-flight 上限；
- `highQualityDepth` 选择单阶段或 tile 多阶段深度；
- `clearColor` 写入 render-pass descriptor。

普通平台配置为 `bgra8Unorm_srgb + depth32Float + sampleCount 1 + viewCount 1`。
visionOS 使用 `LayerRenderer.configuration` 的格式、设备 view count、layered render target
和 drawable 提供的 rasterization-rate map。

渲染前检查 `isReadyToRender`。`render()` 返回 `false` 时必须丢帧，不能 present 未完成目标。
可用 `accessTimeout` 和 `sortTimeout` 控制等待 chunk 独占访问或首次有效排序的上限。

## 7. Shader/Swift 布局同步规则

修改以下类型时必须同时改 Swift 和 Metal：

- `Uniforms` / `UniformsArray`
- `EncodedSplatPoint` / `Splat`
- `ChunkedSplatIndex`
- `GPUChunkInfo` / `ChunkInfo`
- `BufferIndex`
- `SHDegree`

重点检查 packed 类型、字段顺序、指针对齐、`UInt8/UInt16/UInt32` 宽度和
`UniformsArray.alignedSize` 的 256-byte 对齐。布局不一致通常表现为随机颜色、错误点位置、
GPU fault 或仅在真机出现的崩溃。

## 8. RealityKit 官方实现路径

Apple 官方接口不暴露内部 pipeline 或 shader。应用只配置 buffer 和 resource：

```swift
let bufferResource = try GaussianSplatResource.BufferResource(
    count: count,
    position: positionDescriptor,
    scale: scaleDescriptor,
    rotation: rotationDescriptor,
    opacity: opacityDescriptor,
    sphericalHarmonics: (shDescriptor, degree)
)
let resource = GaussianSplatResource(bufferResource)
resource.scaleActivation = .identity
resource.opacityActivation = .identity
resource.sortingMode = .depth
let entity = Entity()
entity.components.set(GaussianSplatComponent(resource))
```

本仓库的实验适配器位于 `RealityKitOfficialBenchmark`。它复用 `SplatIO`，将所有输入统一成
线性 scale/opacity，因此 activation 设置为 `.identity`；SH 保留原始系数；四元数 buffer
按官方要求写为 `r,x,y,z`。对象会持有全部 `LowLevelBuffer`，避免 resource 引用悬空。

`pointLimit` 使用确定性的等间隔采样，适合创建 250K、500K、1M、2M、5M 测试档。
这是性能采样而不是质量最优 pruning；正式产品资产应离线按 opacity、贡献度或误差剪枝。

## 9. SDK 与设备限制

当前机器：Xcode 26.6，macOS/iOS SDK 26.5。现有工程部署目标为 iOS 18、visionOS 2。
`GaussianSplatComponent` 官方示例要求 Xcode 27 / OS 27，并要求 Apple7 GPU family；模拟器
不能验证 splat 渲染。因此实验目录没有加入现有 `.xcodeproj`，以免破坏当前构建。

升级后新建独立 OS 27 Benchmark target，加入 `SplatIO` 和实验目录两个 Swift 文件即可。
不要把 MetalSplatter 与 RealityKit renderer 同时放在同一次功耗测量中。

## 10. 性能与功耗测试矩阵

固定：设备、OS、Release 构建、分辨率、亮度、供电、起始 thermal state、相机路径和时长。

变量：

- renderer：MetalSplatter / RealityKit；
- 点数：250K、500K、1M、2M、完整资产；
- SH：0、1、2、3；
- sorting：depth / distance；
- MetalSplatter high-quality depth：off / on；
- 静态相机 / 恒速旋转 / 近距离高 overdraw。

每个配置至少三次，报告 median 和 P95：

- 首次加载和 resource build 时间；
- displayed FPS、frame time P50/P95/P99、掉帧；
- GPU interval、command-buffer submission；
- CPU time 和线程热点；
- 峰值/稳态 physical footprint、Metal allocation；
- 平均功率、总能量、每帧能量；
- thermal state 和是否出现 `GaussianSplatEvents.RenderingChanged` 限载事件。

使用 Game Performance、Time Profiler、Game Memory、Power Profiler/Energy Log 和 Points of
Interest。实验适配器已经写入 `SplatLoad`、`RealityKitResourceBuild` 和
`RealityKitRenderingLimited` signpost。

RealityView 的 `SceneEvents.Update` 频率只能作为运行状态指示，不应当作最终 displayed FPS；
最终帧率以 Instruments displayed surfaces 为准。

## 11. 开源和官方参考项目结论

首选基线是 Apple 的 **Gaussian splats on visionOS** WWDC26 sample。它包含 PLY、USD、
`LowLevelBuffer`、activation、RealityView 和真机限制处理，并采用允许修改和分发的宽松许可。

社区中可确认使用官方 `GaussianSplatComponent` 的项目很少；`SharpOnPhone` 展示 Core AI
SHARP 输出到 RealityKit 的链路，适合参考动态生成数据，但不应替代 Apple sample 作为
renderer 基准。`Voxelio ios-gaussian-splatting-demo` 仍使用 MetalSplatter，而且原始代码采用
PolyForm Noncommercial，不属于官方 API 性能基线。
