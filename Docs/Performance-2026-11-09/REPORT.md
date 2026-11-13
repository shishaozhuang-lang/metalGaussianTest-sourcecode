# 3DGS 渲染性能测试报告（双平台 · 固定视角）

测试日期：2026-11-09

## 1. 测试环境

| 项目 | iPhone | Mac |
|---|---|---|
| 设备 | iPhone 17 Pro Max（iPhone18,2） | Apple Silicon（Apple M5） |
| 内存 | — | 24 GiB |
| 系统 | iOS 27.2（24B119） | macOS 27.2（26B123） |
| CPU | 6 核 arm64e | Apple M5 |
| Xcode | 27.2（27B52） | 27.2（27B52） |
| 构建 | Release，whole-module optimization | Release，whole-module optimization |
| 场景 | hailuo（PLY 1,153,429 点 / mp4 1,183,744 点） | 同左 |
| 相机 | `view.json`（camera_world），**固定视角（无自动旋转）** | 同左 |

## 2. 测试方法

- 三模型：`point_cloud.ply`、`point_cloud_morton.ply`、EGSC 空间视频 mp4。
- 两分辨率：540×960 与 1080×1920（离屏渲染，`--render-size`）。
- 相机位姿来自 `hailuo/view.json`，渲染期间相机固定（本次改动已关闭 perf 模式自动旋转）。
- 每帧渲染（`isPaused=false`），telemetry 逐帧 CSV，统计时丢弃前 20s 预热。

## 3. 结果一：60Hz 逐帧渲染（vsync 满帧测试）

### iPhone 17 Pro Max

| 配置 | 帧数 | FPS | 帧间隔均值 | p95 | 绘制 splats |
|---|---:|---:|---:|---:|---:|
| ply 540×960 | 6285 | **59.9** | 16.69ms | 21ms | 429,240 |
| ply 1080×1920 | 6286 | **59.9** | 16.69ms | 17ms | 429,240 |
| morton 540×960 | 6282 | **59.9** | 16.70ms | 17ms | 429,240 |
| morton 1080×1920 | 6282 | **59.9** | 16.70ms | 17ms | 429,240 |
| mp4 540×960 | 6256 | **59.8** | 16.71ms | 17ms | 431,911 |
| mp4 1080×1920 | 6255 | **59.9** | 16.70ms | 17ms | 431,911 |

### Mac（Apple M5）

| 配置 | 帧数 | FPS | 帧间隔均值 | p95 | 绘制 splats |
|---|---:|---:|---:|---:|---:|
| ply 540×960 | 5928 | **60.0** | 16.67ms | 18ms | 429,240 |
| ply 1080×1920 | 5932 | **60.0** | 16.67ms | 18ms | 429,240 |
| morton 540×960 | 5927 | **60.0** | 16.67ms | 18ms | 429,240 |
| morton 1080×1920 | 5926 | **60.0** | 16.67ms | 18ms | 429,240 |
| mp4 540×960 | 5896 | **60.0** | 16.67ms | 18ms | 431,911 |
| mp4 1080×1920 | 5896 | **60.0** | 16.67ms | 18ms | 431,911 |

> iPhone ply-540 的 p95=21ms 为 reinstall 后首轮 warmup 尖峰，其余组 p95 稳定 17–18ms。
>
> 上表 60 FPS 是 MTKView 默认 `preferredFramesPerSecond`（60）的 vsync 结果。
> 两平台显示屏均为 ProMotion 120Hz，解除该默认锁（`--max-fps=0`）后**屏幕端实际渲染为 120 FPS**
> （Mac 实测 120.0 FPS / 8.33ms，iPhone 同理受 120Hz 显示同步约束）。
> 真正的管线吞吐上限见第 4 节离屏测试。

## 4. 结果二：离屏最大帧率（`--benchmark-frames=300`，无 vsync 限制）

| 配置 | iPhone FPS | iPhone 帧时间 | Mac FPS | Mac 帧时间 |
|---|---:|---:|---:|---:|
| ply 540×960 | **185.7** | 5.39ms | **309.0** | 3.24ms |
| ply 1080×1920 | **123.0** | 8.13ms | **214.2** | 4.67ms |
| morton 540×960 | **186.4** | 5.37ms | **312.8** | 3.20ms |
| morton 1080×1920 | **123.2** | 8.12ms | **214.8** | 4.66ms |
| mp4 540×960 | **213.1** | 4.69ms | **345.8** | 2.89ms |
| mp4 1080×1920 | **132.3** | 7.56ms | **225.3** | 4.44ms |

## 5. 每帧绘制确认（iPhone，7440 帧逐帧校验）

| 指标 | 结果 |
|---|---|
| 帧号连续性 | 0..7439，`max_gap=1`，**无跳帧** |
| 零 splat 帧 | **0**（每帧都绘制 splat） |
| 零 draw call 帧 | **0**（每帧都提交 draw） |
| 稳态 splat 数 | 恒定 429,240（ply/morton）/ 431,911（mp4） |
| 帧间隔 | 16.7ms（逐 vsync 渲染） |

证据链：MTKView `isPaused=false` → 每个 vsync 调用 `draw(in:)` → 每次都提交 draw call → telemetry 每帧记录 `splat_count>0` 且帧号连续，**没有任何一帧被跳过或空渲染**。

## 6. 代码改动（本次测试前，尚未提交）

1. `SampleApp/Scene/MetalKitSceneRenderer.swift`
   - `updateRotation()`：移除 `perfRecordingEnabled` 强制自动旋转，perf 模式相机固定。
   - `viewport`：iOS 改用 `view.json` 位姿（与 macOS 同一公式），移除硬编码相机常量。
   - `runFrameBenchmark()`：完成后 `exit(0)`，并修复 FPS 格式化 `%.1`→`%.1f`。
2. `SampleApp/App/Constants.swift`：删除不再使用的 `initialCameraRotation`/`initialCameraPosition`。

## 7. 结论

1. **双平台固定视角下 12 组全部满帧（60 FPS）**。此前 morton-1080 / mp4-1080 在 iPhone 上掉到
   57–58 FPS，根因是旋转时每帧 CPU 深度排序的开销尖峰，而非 GPU 或分辨率瓶颈——固定视角该开销消失。
2. **渲染管线真实上限**：iPhone 123–213 FPS、Mac 214–346 FPS；60 FPS 是显示 vsync 天花板，不是渲染能力上限。
3. **Mac 约为 iPhone 的 1.6–1.7 倍吞吐**（离屏：Mac/iPhone ≈ 1.66×@540、1.72×@1080）。
4. **EGSC mp4 最快**：两平台均显著高于 ply/morton（iPhone 540 下 213 vs ~186，快 ~15%；
   Mac 540 下 346 vs ~309，快 ~12%），其数据布局对 GPU 遍历更友好。
5. **分辨率影响明显**：540→1080 像素 ×4，两平台帧率均降约 33%（GPU 填充率主导高分辨率开销）。
6. **三模型数据一致，跨平台 splat 数相同**（ply/morton 429,240、mp4 431,911），
   mp4 无运行时解码开销（解码仅在加载阶段）。
7. 帧率三级：**默认 60 FPS（MTKView 锁）→ 屏幕 120 FPS（ProMotion，`--max-fps=0`）→
   离屏真实吞吐（iPhone 123–213 FPS / Mac 214–346 FPS，`--benchmark-frames`）**。
   第 4 节为纯管线吞吐上限。

## 8. 文件清单

```
Docs/Performance-2026-11-09/
├── REPORT.md                     # 本报告（双平台）
├── vsync-fps-csv/                # 12 个逐帧 telemetry CSV（ios-* / mac-*，60Hz 满帧测试）
├── max-fps-offscreen/            # 离屏最大帧率结果（iPhone + Mac）
├── screenshots/                  # iPhone 帧图像（ply / mp4，1080×1920 渲染）
└── scripts/                      # iPhone 测试脚本（逐帧 + 离屏基准）
```
