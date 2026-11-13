# dazhongkafei 模型 Mac + iPhone 性能测试报告

测试日期：2026-11-10/11
模型：PLYIO/dazhongkafei/point_cloud.ply — **1,996,180 splats**（495MB，hailuo 的 1.73 倍）
视角：view.json（camera_world，540×960 初始配置），渲染期间相机固定
平台：
- Mac17,2（Apple M5，10 核 GPU）Release 构建，vsync 60Hz ProMotion
- iPhone 17 Pro Max（iOS 27.2，USB 真机）Release 构建

方法：
- **离屏 benchmark**（`--benchmark-frames=300`，无 drawable 无 vsync）：满载吞吐（3-in-flight 并发）
- **vsync perf**（`--perf` + `--render-size`，60s+ 渲染，去前 5s）：呈现帧率与帧节奏
- **no-present uncapped**（`--no-present --max-fps=0`）：drawable 路径剥离 vsync 的对照
- **Instruments Metal System Trace**（20-30s）：GPU 按 command buffer 归因的单帧执行时间
- **瓶颈专项扫描**（SH 阶数 × 分辨率 × 模型规模，冷态）：见 [Bottleneck-Analysis.md](Bottleneck-Analysis.md) —— 结论：两平台均顶点阶段主导（Mac 93% / iPhone 87%），延迟受限而非带宽或算力饱和
- **30min 持续负载**（540/1080 vsync 热衰减曲线 + 热尾）：见 [Sustained-30min-Analysis.md](Sustained-30min-Analysis.md) —— 540 热稳态 25 FPS（热变慢 +60%）、1080 18 FPS（+94%）
- vsync 与离屏模式的机制差异与数字换算见专题：[Vsync-vs-Offscreen-Analysis.md](Vsync-vs-Offscreen-Analysis.md)

## 结果总表

### 帧率（稳态）

| 测试 | Mac | iPhone 17 Pro Max |
|---|---:|---:|
| 离屏 540×960 | **79.0 FPS**（12.65ms/帧） | **52.9 FPS**（18.91ms/帧） |
| 离屏 1080×1920 | **68.1 FPS**（14.69ms/帧） | **40.0 FPS**（24.98ms/帧） |
| vsync 540×960 | **60.1 FPS**（100% 1×vsync 满帧） | **44 FPS**（p50 21ms；1拍60%/2拍22%） |
| vsync 1080×1920 | **60.1 FPS**（100% 1×vsync 满帧） | **23 FPS**（p50 42ms；2拍27%/3拍36%/4拍21%） |
| no-present uncapped 540 | 79.1 FPS | 46.4 FPS |
| 绘制 splats（视角内） | 1,482,523 | 1,482,523 |
| CPU encode/帧 | 0.08ms（p50） | 0.086ms（均值） |

### GPU 单帧执行时间（Metal System Trace，按 command buffer 归因）

| 测量 | Mac 540 | Mac 1080 | iPhone 540 | iPhone 1080 |
|---|---:|---:|---:|---:|
| 单 cb GPU 执行 p50 | **13.4ms**（avg 13.6） | **15.9ms**（avg 16.5，p95 19.9） | —（离屏 18.9ms 墙钟） | —（离屏 25.0ms 墙钟） |
| 离屏模式单 cb GPU 执行 | **avg 22.3ms**（3 并发争用+降频） | — | — | — |

（iPhone 的 per-cb GPU 归因未做：其 submissions 表导出无 SampleApp 行；以离屏墙钟帧耗时代替。）
（修正：首版报告的"Fragment avg 1.26ms"等通道均值被 WindowServer 微任务稀释，不可用——正确方法见 Vsync-vs-Offscreen-Analysis.md §4。）

### CPU 排序耗时（一次全量排序）

| 平台 | 首次排序 | 含 CPU culling 后 |
|---|---:|---:|
| Mac (M5) | 100.2ms | 68.5ms |
| iPhone 17 Pro Max | 134.6ms | 100.0ms |

排序仅发生在 pose 变化时；静态视角下 Mac 实测 613/613 帧、iPhone 同样全帧渲染、零重排序（`--frame-log` 验证，见 data/csv/mac-frame-log-static-camera.txt）。

## 关键结论

1. **Mac 满帧但不再"毫无压力"**（较首版结论修正）：单帧 GPU 执行 p50 13.4ms（540）/ 15.9ms（1080），已占 16.7ms 预算的 80-95%；1080 的 p95 19.9ms 已越界，靠多数帧追回满帧。1.48M 可见 splat 对 M5 接近单帧预算上限。离屏吞吐 79/68 FPS 由 CPU 串行编码（~5ms/帧）+ 3 并发 GPU 共同决定。

2. **iPhone 是 GPU 瓶颈**：
   - 540×960 离屏 18.9ms/帧 > 16.7ms 预算 → vsync 下 44 FPS（帧长抖动+短帧补位，高于 2 拍量化上限 30）
   - 1080×1920 离屏 25.0ms/帧 → vsync 下 23 FPS（2/3 拍边界抖动，几乎无短帧补位）
   - CPU encode 仅 0.086ms/帧，`obtain_sort_buffer_ms`≈0 —— 静态视角下 CPU 无等待，纯 GPU 顶限

3. **瓶颈定位（详见 Bottleneck-Analysis.md）**：两平台均**顶点阶段主导**（Mac 93% / iPhone 87% @540），且为延迟受限（顶点 ALU 利用 5-7%、DRAM 带宽利用 8-20%，均不饱和）；片元在 ≥1080 才显著（iPhone 1080 占 33%）。SH 降阶/纹理化收益 ≤7%。

4. **与 hailuo（1.15M splats）对比**：hailuo iPhone 540 60 FPS 满帧；dazhongkafei（2.0M splats，可见 1.48M vs 0.43M）在同位置掉到 44 FPS。可见 splat 数量 3.4 倍 → 顶点时间超线性 4.2 倍（L2 cache 失效：53MB 驻留 vs 180MB 超出）。

5. **排序成本**：Mac 68.5ms/次 vs iPhone 100ms/次。移动端拖动视角时排序后台跑（不阻塞渲染），但 1.4 倍于 hailuo 的时间意味着快速旋转时排序滞后更多（最多落后 5-6 帧）。

6. **iPhone 热节流是第二大因素**：连续满载扫描使帧耗时虚高 52%（28.97ms vs 冷态 19.11ms）；长时间交互使用会从 44 FPS 继续下滑。

7. **vsync 与离屏差异的定量解释**（详见专题文档）：离屏测满载并发吞吐（iPhone 53 FPS），vsync 测呈现节奏（44 FPS），差值来自 vsync 量化与帧长抖动；报告性能时应两者并报。

## 建议

- iPhone 上播放该模型建议 540×960（view.json 已默认 540）：44 FPS 可用；1080 仅 23 FPS 不可用。
- 优化优先级（按瓶颈定位修正，详见 Bottleneck-Analysis.md）：
  1. **降低顶点工作量**是主攻方向（87-93% 帧时）：CPU 剔除更激进（贡献度/阈值）、按 tile 分块渲染（结构性解法，顶点量可降 5-10×）、避免被剔除 splat 的顶点发射
  2. SH 纹理化/SH 降阶收益有限（≤7%），降低优先级
  3. 1080 诉求时的片元优化（填充率）排第二
  4. 注意 iPhone 热节流：任何降功耗优化有双重收益
- Mac 端 1080 贴近预算上限（p95 越界），若与其它 GPU 负载（窗口合成、视频）叠加可能出现偶发掉帧；离屏吞吐余量（68 FPS）可吸收。

## 数据文件

```
Bottleneck-Analysis.md            瓶颈专项（带宽 vs 算力判定）+ 扫描实验设计
Vsync-vs-Offscreen-Analysis.md     模式差异解析 + GPU trace 归因方法论
data/csv/   — 每帧 telemetry CSV + sweep-results.txt（扫描原始结果）
  mac-ply-540/1080.csv           Mac vsync 稳态
  mac-uncapped-540/1080.csv      Mac no-present uncapped（vsync 剥离对照）
  mac-vsync2-540/1080.csv        Mac vsync（带 GPU trace 的同次运行）
  ios-ply-540/1080.csv           iPhone vsync 稳态
  ios-uncapped-540.csv           iPhone no-present uncapped
  mac-frame-log-static-camera.txt 静态视角全帧渲染证据
  sweep-results.txt              SH/分辨率/模型规模扫描（冷态）
data/trace/ — Instruments traces + 导出 XML
  mac-vsync2-*.trace/xml         Mac vsync 模式（含 SampleApp GPU 归因）
  mac-bench-*.trace/xml          Mac 离屏 benchmark 模式
  mac-metal-*.trace              Mac Metal System Trace（首版，SampleApp 事件缺失，弃用归因）
  mac-gpu-*.trace                Mac Game Performance（RT counter 恒 0）
  ios-metal-*.trace              iPhone Metal System Trace
```
