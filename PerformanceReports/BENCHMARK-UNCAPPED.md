# 无限制帧率（离屏吞吐）测试

vsync 解除方案：`--benchmark-frames=N` 连续渲染 N 帧到离屏纹理（无 drawable、
无 present、无 displaylink 门控），测纯渲染管线吞吐（编码 + GPU 执行）。
另有 `--max-fps=0`（240Hz 定时上限）与 `--no-present`（跳过 present）两种半开模式，
实测均被 displaylink 限在 120Hz（ProMotion vsync），故离屏方案为准。

## Mac（Apple Silicon，Release，600 帧/组）

| 模型 | 540×960 | 1080×1920 |
|---|---:|---:|
| point_cloud.ply | **306.1** FPS (3.27ms/帧) | 211.9 FPS (4.72ms/帧) |
| point_cloud_morton.ply | 305.7 FPS (3.27ms/帧) | 211.8 FPS (4.72ms/帧) |
| EGSC mp4 | 336.3 FPS (2.97ms/帧) | 220.8 FPS (4.53ms/帧) |

## iPhone 17 Pro Max（Release，300 帧/组）

| 模型 | 540×960 | 1080×1920 |
|---|---:|---:|
| point_cloud.ply | 199.4 FPS (5.02ms/帧) | 133.5 FPS (7.49ms/帧) |
| point_cloud_morton.ply | 150.9 FPS (6.63ms/帧) | 111.3 FPS (8.99ms/帧) |
| EGSC mp4 | **229.7** FPS (4.35ms/帧) | 95.1 FPS (10.51ms/帧) |

## 关键发现

- **渲染管线余量 3-5 倍**：Mac 峰值 306-336 FPS、iPhone 峰值 150-230 FPS，
  常规 60 FPS 模式的上限来自显示 vsync，不是渲染能力
- **Mac 120Hz 上限**：`--max-fps=0`/`--no-present` 均被 ProMotion displaylink 锁在
  120 FPS，离屏模式才能测出真实吞吐
- **分辨率影响**：像素 ×4 → 帧时间 +40%（3.3→4.7ms），GPU 填充率开销明显
- **EGSC mp4 最快**：双平台吞吐均为三模型最高（Mac 336 / iPhone 230 FPS），
  Morton 数据布局对 GPU 遍历友好
- **iPhone PLY vs mp4 差异大**（199 vs 230 FPS，540；133 vs 95 FPS，1080）：
  mp4 在 540 更快但 1080 反而更慢（大绘制批次下填充率主导）
