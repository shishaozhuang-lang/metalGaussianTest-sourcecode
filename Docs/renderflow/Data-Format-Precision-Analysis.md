# 3DGS 数据格式与精度分析

> 附属于 [RenderFlow-Plan-Analysis.md](RenderFlow-Plan-Analysis.md)（渲染流程方案分析）。
> 本文梳理 3DGS 数据从**文件格式 → 内存结构 → CPU 排序数据 → GPU 缓冲 → shader 读取**的完整数据流，逐环节给出字节数、数值精度、量化方式与域变换。
> 代码引用基于当前 main；所有 Swift 结构与 Metal 端结构是手工保持同步的（`Keep in sync` 注释约定）。

## 1. 数据流总览

```
PLY (Float32) ──┐
SPZ (UInt8 量化) ├→ SplatPoint (域多样) → SplatChunk 编码 → MetalBuffer (Shared) ─┐
SPLAT (混合)    │        (内存中间态)      (GPU 布局, 量化定点)                     │ → GPU 顶点着色器
EGSC/MP4 (位流) ┘                                                                   │
                                    SplatSorter: ChunkedSplatIndex (UInt16+UInt32) ─┘
                                    GPUChunkInfo (设备指针表)
```

两级精度链：**文件格式层**（磁盘上，为压缩/体积优化）→ **GPU 层**（内存中，为带宽/对齐优化）。文件层的量化在读入时全部还原为 `Float`，再于 `EncodedSplatPoint` 编码步骤统一压到 `Float16`。

## 2. 文件格式层精度（SplatIO 各 Reader）

### 2.1 PLY（3DGS 训练输出标准格式）— 全精度

| 属性 | PLY 属性名 | 磁盘类型 | 读入后（SplatPoint） |
|---|---|---|---|
| 位置 | x, y, z | `float32`（也支持 `float64`/ASCII） | `SIMD3<Float>` 原值 |
| SH0 颜色 | f_dc_0/1/2 | `float32` | `Color.sphericalHarmonicFloat`（**原始 SH 系数域**，非 sRGB） |
| SH1-3 | f_rest_0..44 | `float32` × 45 | 同上（累计最多 48 组 RGB 系数） |
| 不透明度 | opacity | `float32` | **logit 域原值**（sigmoid 前的 raw 值） |
| 尺度 | scale_0/1/2 | `float32` | **log 域（exponent）原值** |
| 旋转 | rot_0..3 | `float32` | 四元数 [w,x,y,z]（SplatPLYReader 转为 simd_quatf） |

**无任何量化**：dazhongkafei 495MB ≈ 1,996,180 × ~247B/点（62 个 float32 属性）。特性：颜色/不透明度/尺度都保持**训练时的激活域**（SH 系数、logit、log），域变换推迟到编码/渲染阶段。

### 2.2 SPZ（Niantic 压缩格式）— 全字段 UInt8 量化

`PackedGaussian` 每字段独立量化（`spz-swift/PackedGaussians.swift`）：

| 属性 | 存储 | 反量化公式 | 有效精度 |
|---|---|---|---|
| 位置 | 3×UInt8（24-bit 定点，或 legacy 2×UInt8=Float16） | `fixed32 × 2^-fractionalBits`（有符号扩展；fractionalBits 由 header 给出，典型 14） | 世界坐标 ~24-bit 定点 |
| 尺度 | 3×UInt8 | `scale/16 − 10` → log 域 | log-scale 量化到 16 级/偏移 10 |
| 旋转 | 4×UInt8 | smallest-three（或 first-three）四元数重建 | 每分量 8-bit |
| 颜色(SH0) | 3×UInt8 | `(c/255 − 0.5)/colorScale`（colorScale 由 header） | SH0 域 8-bit |
| 不透明度 | 1×UInt8 | `invSigmoid(alpha/255)` → **logit 域** | 8-bit |
| SH1-3 | 15×UInt8/通道 | `(sh − 128)/128`（unquantizeSH） | 每系数 8-bit |

结构布局为**非交错平面数组**（positions[]/rotations[]/…各自连续，利于 Zstd 压缩）。体积 ~10-25× 小于 PLY。

### 2.3 SPLAT（旧版 antimatter15 格式）— 混合精度

`DotSplatEncodedPoint` 32B/点：位置 `Float32×3`、尺度 `Float32×3`（**linear 域**）、颜色 RGBA `UInt8×4`（sRGB + linear opacity 8-bit）、旋转 `UInt8×4`（`q×128+128` 偏移编码，精度 1/128）。

### 2.4 EGSC/MP4（Spatial Vivid, T/UWA 050-2026）— 位流量化

元数据驱动的量化（`EGSCSceneDecoder.swift`），`quantizationType` 三档：

| 类型 | 公式 | 用途 |
|---|---|---|
| 1 standard | `q / (2^bitdepth − 1)` → [0,1] | 归一化域 |
| 2 min/max | `q/maxQuant × (max−min) + min` | 每分量范围恢复 |
| 3 patch | 同 2，但 min/max 逐 patch 存储（`[size, min×comp, max×comp]` 连续排布） | means 双流（byteshift 0+4 累加） |

域约定（与 PLY 有差异，解码时统一回 3DGS 域）：opacity 存 **sigmoid 前 raw** → `sigmoid()` 还原；scale 保持 **log 域**；rotation 是**欧拉角 (roll,pitch,yaw)** → 解码时转四元数（QuatReduction trans=1）。位流特性：metadata float 字段从**任意 bit 位起读**（非字节对齐），位置 min/max 交错存储。SH rest 走 ASTC 纹理子流（当前解码路径 DC-only 回退，见 [[metalsplatter-repo-state]]）。

## 3. 内存中间态：SplatPoint（SplatIO）

域统一的"最大公约数"结构（所有 Reader 的汇合点）：

```swift
public struct SplatPoint {
    var position: SIMD3<Float>          // 世界坐标 Float32
    var color: Color                    // .sphericalHarmonicFloat([SIMD3<Float>]) 或 .sRGBUInt8
    var opacity: Opacity                // .logitFloat / .linearFloat / .linearUInt8 三态
    var scale: Scale                    // .exponent(log域) / .linearFloat 二态
    var rotation: simd_quatf            // Float32 四元数
}
```

每个域属性带成对的转换器（`asLogitFloat/asLinearFloat`、`asExponent/asLinearFloat`…），编码阶段按需取域。注意 `linearUInt8 → logit` 用 `(v+0.5)/256` 避开 logit(0/1) 无定义。

## 4. GPU 层布局（SplatChunk 编码）— 定点/半精度

### 4.1 EncodedSplatPoint（32B/点，Swift ↔ Metal 双端同步）

```swift
// Swift (EncodedSplatPoint.swift)          // Metal (ShaderCommon.h)
var position: MTLPackedFloat3    // 12B     packed_float3 position
var colorSH0: PackedRGBHalf4     //  8B     packed_half4 color
var covA: PackedHalf3            //  6B     packed_half3 covA
var covB: PackedHalf3            //  6B     packed_half3 covB
```

编码时的域变换与量化（`EncodedSplatPoint.init`）：

| 属性 | 变换 | 精度损失 |
|---|---|---|
| position | Float32 → Float32 原值（不压） | 无 |
| colorSH0 | SH0 Float32 → **Float16**（保持 SH 系数域） | ~10-bit 尾数（值域 ~±1 内足够） |
| opacity | `logit → sigmoid → linear` 后存 **Float16 alpha** | 1/255 粒度下无损 |
| scale+rotation | **CPU 预计算 3D 协方差** `Σ = R·S·Sᵀ·Rᵀ` 取 6 个独立分量 → Float16 | 协方差 10-bit 尾数；**几何信息从 7 DoF(3+4) 压到 6 DoF 对称矩阵** |
| covA/covB | `cov3D[0,0],[0,1],[0,2] / [1,1],[1,2],[2,2]` | 对称矩阵下确界表示 |

关键设计：**顶点着色器不再做旋转/尺度→协方差的三角化**，cov3D 预烤进 6×Float16；shader 只做投影到 2D 协方差（`calcCovariance2D`）。

### 4.2 SH 系数存储（三选一，由 `preferSHTexture` 与数据可用性决定）

| 路径 | 布局 | 每点字节 | 通道利用 |
|---|---|---|---|
| **Buffer（默认）** | 平面 `Float16[]`，`splatIndex × 45 × 3` 偏移 | SH1 18B / SH2 48B / SH3 90B | 100%（紧凑） |
| **RGBA16F 纹理** | 2DArray 8192×8192，每 texel 一个 RGB 系数 | SH3 15×8=120B | 75%（A 通道浪费） |
| **ASTC 纹理** | 4x4/6x6/8x8 LDR，自定义 `MSHASTC{4,6,8}` 头（52B: 尺寸/layers/scale/bias） | 4x4: ~15B | 有损（ASTC 压缩 + shader 端 `×scale+bias` 线性恢复） |

ASTC 路径的 scale/bias 逐分量存于自定义头（`SIMD3 scale/bias`），shader `loadSHCoefficient` 里做 `packedCoeff.rgb × scale + bias` 仿射还原——纹理化的代价是 A 通道丢弃 + 有损，收益是纹理缓存/压缩带宽。

### 4.3 排序索引 ChunkedSplatIndex（8B）

```swift
var chunkIndex: UInt16   // chunk 表下标（上限 65535 chunk）
var _padding: UInt16     // 对齐
var splatIndex: UInt32   // chunk 内 splat 下标
```

排序线程按深度序写入；顶点着色器两级解引用：`splatIndexArray[splatID] → chunks[idx.chunkIndex] → chunk.splats[idx.splatIndex]`。

### 4.4 GPUChunkInfo（24B/chunk，设备指针表）

```swift
var splatsPointer: UInt64          // MTLBuffer 设备地址（指针直传，非绑定）
var shCoefficientsPointer: UInt64  // SH buffer 地址（SH0 时 0）
var splatCount: UInt32
var shDegree: UInt8                // 运行时按交互降阶后 clamp 的有效阶
var enabled: UInt8                 // chunk 开关（不参与重排序）
var _shPadding: (UInt8, UInt8)
```

shader 用 `device const Splat*` 直接寻址（argument-buffer 风格），**增删 chunk 时重建整个表**（不可变快照，`chunkTableCaching` 复用）。

### 4.5 Uniforms（~200B/视口，256B 对齐 × maxSimultaneousRenders 轮转）

含投影/视图矩阵（Float32 4×4×2）、相机世界位置（packed Float3，SH 视向计算用）、屏幕尺寸、预投影值（focalX/Y、tanHalfFovX/Y——**投影矩阵的标量预提取**，shader 免重复推导）、splats/indexed/chunk 计数、优化 flags 位集、SH 纹理参数（宽度/texels-per-splat/ASTC 标志）。

## 5. 存储模式与内存驻留

- 所有 `MetalBuffer` = **`.storageModeShared`**（统一内存，CPU 写 → GPU 读零拷贝；Apple GPU 无离散显存所以无 private 必要；排序线程在 CPU 侧直接读 splat 位置算深度也靠它）
- dazhongkafei（199.6 万点）GPU 驻留：splats 64MB + SH3 buffer 180MB + 可见索引 12MB ≈ **256MB**；外加 3 个排序 buffer 轮转（各 12MB）
- iOS `MetalBuffer.maxCapacity` 检查 `device.maxBufferLength`（Apple Silicon 1GB 上限 → 单 chunk 最多 ~3300 万 splat，当前模型远未触顶）
- SH 纹理路径 `storageMode = .shared` + `usage = .shaderRead`

## 6. Morton 局部性重排（编码期量化）

`SplatChunk.sortByLocality()`（addChunk 时默认执行，SH 纹理路径除外）：

1. 位置归一化到包围盒 → **每轴量化 10-bit**（`UInt32`）
2. `morton3D`：三轴比特交错成 30-bit Morton 码（`bit i: x<<(3i), y<<(3i+1), z<<(3i+2)`）
3. 按 Morton 码排序 → **重写 splat buffer 与 SH buffer**（内存布局 = 空间填充曲线序）

量化只影响排序次序（10-bit 网格内的相邻关系丢失），**不改变数据本身**。收益：渲染时深度序索引指向的 splat 在 Morton 序数据上是空间聚集的……但注意 [Bottleneck-Analysis.md](../dazhongkafei/Bottleneck-Analysis.md) 实测：**深度序遍历 × Morton 序存储 = 随机访问**，局部性收益实际有限；SH 纹理路径因 `splatIndex` 兼作纹理线性索引而禁用重排（保持原序）。

## 7. 逐环节精度总结表

| 环节 | position | 颜色/SH | opacity | scale | rotation |
|---|---|---|---|---|---|
| PLY 文件 | F32 | F32（SH 域） | F32（logit） | F32（log） | F32 四元数 |
| SPZ 文件 | 24-bit 定点 | UInt8×3 + 15×UInt8/通道 | UInt8 | UInt8（log） | UInt8×4 |
| SPLAT 文件 | F32 | UInt8 sRGB | UInt8 linear | F32 linear | UInt8 偏移 |
| EGSC 位流 | patch 量化 + means 双流 | dc 量化（rest ASTC） | raw(sigmoid 前) 量化 | log 域量化 | **欧拉角量化** |
| SplatPoint | F32 | F32 数组 | 域三态 | 域二态 | F32 四元数 |
| **EncodedSplatPoint (GPU)** | **F32** | SH0 **F16** | **F16 linear** | → cov **F16**（预计算） | → cov（并入） |
| GPU SH | F16 buffer / RGBA16F / ASTC | — | — | — | — |
| 排序索引 | — | — | — | — | — |

**渲染管线中的精度关键点**：
- 位置全程 Float32（投影稳定性），其余全部 Float16/UInt8——与瓶颈分析一致：顶点带宽 130B/splat 而非 247B/splat，是精度压缩的直接收益
- 协方差预计算把 7-DoF 几何收敛为 6-DoF 对称阵 + Float16，shader 只剩 2D 投影
- shader 端 `sRGBToLinear` 用 `pow(c, 2.2)` 近似（训练用 gamma 2.2，非精确 sRGB EOTF）——颜色管线已知近似点
- Uniforms 的 `performanceOptimizationFlags` 同时控制 CPU/GPU 剔除行为——位集在两端手工同步

## 8. 与性能结论的连接

| 格式事实 | 性能含义（见 dazhongkafei 报告） |
|---|---|
| 32B splat + 90B SH3 = 130B/点顶点读 | 顶点带宽 192MB/帧 → 延迟受限（非饱和） |
| SH3→SH0 只减 90B→0 | 帧耗时仅省 2-7%（带宽非第一瓶颈） |
| Float16 cov（6B）紧凑布局 | cov3D 读取在 32B 结构内与 color 同 cacheline |
| 深度序索引 × Morton 数据 | 随机访问超线性退化（hailuo→dzk 4.2×） |
| ASTC SH 纹理 15B/点 | 理论带宽省 6×，但 A 通道浪费 25% 且有损 |
| Shared storage 零拷贝 | CPU 排序与 GPU 渲染共享同一份 splat 内存 |
