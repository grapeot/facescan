# iOS 多帧深度融合：位姿获取与工程资源调研

对象：把 Apple 官方 sample *Streaming Depth Data from the TrueDepth Camera*（纯 AVFoundation，`AVCaptureDepthDataOutput` 拿前置 TrueDepth 实时深度，单帧、无位姿）改造成多角度融合的人脸三维扫描 App。

调研日期：2026-10-04。所有关键点尽量附一手来源；无法从一手文档确认的标 **[待验证]**。

---

## 0. 结论先行（Bottom Line）

多帧深度融合成败的第一性问题是**每帧的相机位姿**。这个 sample 完全没有位姿能力，`AVCaptureDepthDataOutput` 只给深度图和相机的内参/外参标定，不给相机在世界中的 6DoF 轨迹。

**推荐主路径：改用 ARKit 的 `ARFaceTrackingConfiguration`，并打开 `isWorldTrackingEnabled = true`。** 这一条路能在同一个 `ARFrame` 里同时拿到：

- `frame.capturedDepthData` — 前置 TrueDepth 的原始稠密深度（`AVDepthData`，度量单位、约 640×480、DepthFloat16），就是 sample 里那份深度，未经过 ARKit 的 face mesh 加工；
- `frame.camera.transform` — 6DoF 相机位姿（`simd_float4x4`，camera→world）；
- `frame.camera.intrinsics` — 内参矩阵；
- `ARFaceAnchor.transform` — 头部（脸）位姿，可用于把融合结果锚定在脸坐标系，抑制头部微动/表情带来的几何"拖影"。

这样就绕开了最难的自研 ICP 里程计：位姿几乎免费。剩下的工作退化为"按 `(depth, intrinsics, pose)` 做 TSDF/点云融合"，是成熟的工程问题。

关键限制（都是硬约束，不是可调项）：

1. **ARKit 的 `sceneDepth` / `smoothedSceneDepth` 用不了。** 官方文档明确它们是"设备后置相机到物体"的深度，由 LiDAR 填充；前置 TrueDepth 场景拿不到。前摄可用的稠密深度只有 `capturedDepthData`。
2. **`sceneReconstruction`（AR mesh）用不了。** 官方明确要求 LiDAR 设备（第 4 代 iPad Pro 起）。人脸场景得不到 ARKit 的 scene mesh。
3. **ARKit 免费给的前摄 mesh 只有 `ARFaceAnchor.geometry`，且是"通用脸模板 + 表情系数拟合"的结果，不是扫描重建。** 它有固定拓扑（1220 顶点 / 6912 三角面，文档未公开顶点语义），无法表达个体真实几何细节，也拿不到脸以外（头发、耳朵、脖子、额头被切掉的部分）。所以仍要自己融合原始深度。

一句话权衡：**用 `ARFaceTrackingConfiguration + isWorldTrackingEnabled` 拿深度 + 真位姿，自己写 TSDF/点云融合；不要指望 ARKit 的 sceneDepth / sceneReconstruction。**

---

## 1. 核心问题：相机位姿从哪来

### 1.1 各配置能力对照

| 配置 | `capturedDepthData`（前摄原始深度） | `camera.transform`（6DoF 位姿） | `ARFaceAnchor`（脸网格/表情） | 前摄 `sceneDepth` | 备注 |
|---|---|---|---|---|---|
| **`ARFaceTrackingConfiguration`（默认）** | ✅ 有 | ⚠️ 只有相对/设备运动估计，非完整世界 6DoF | ✅ 有 | ❌ 无 | sample 对应的 ARKit 等价物，但**默认不给世界位姿** |
| **`ARFaceTrackingConfiguration` + `isWorldTrackingEnabled = true`** | ✅ 有（**推荐路径**） | ✅ 有，设备在世界坐标系中的 6DoF，需 `supportsWorldTracking` | ✅ 有 | ❌ 无 | 官方文档明确支持；WWDC19 说 6DoF 需要 A12 及以后芯片 |
| **`ARWorldTrackingConfiguration` + `userFaceTrackingEnabled = true`** | ❌ **没有**（该配置是后摄世界追踪体验，`capturedDepthData` 文档说其他配置为 nil） | ✅ 有（后摄的强世界追踪） | ✅ 有 | ✅ 有（后摄 LiDAR，仅 LiDAR 机型） | 想要真世界位姿+脸，但丢了前摄原始深度 |
| `ARWorldTrackingConfiguration`（纯） | ❌ 无 | ✅ 有 | ❌ 无 | ✅ 后摄 LiDAR | 标准室内 AR 世界追踪 |
| `ARImageTrackingConfiguration` / `ARBodyTrackingConfiguration` | ❌ 无 | 视配置 | ❌ | ❌ | 与本任务无关 |

来源：

- `ARFaceTrackingConfiguration`（含 `supportsWorldTracking` / `isWorldTrackingEnabled`）：https://developer.apple.com/documentation/arkit/arfacetrackingconfiguration
- `isWorldTrackingEnabled` 定义："instructs a session to provide the app with the device's six degrees of freedom pose during a face-tracking session"：https://developer.apple.com/documentation/arkit/arfacetrackingconfiguration/isworldtrackingenabled
- `capturedDepthData`："available only in face-based experiences (`ARFaceTrackingConfiguration`) using the device's front TrueDepth camera. This property's value is nil when running other AR configurations."：https://developer.apple.com/documentation/arkit/arframe/captureddepthdata
- `ARWorldTrackingConfiguration.userFaceTrackingEnabled` / `supportsUserFaceTracking`：https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/userfacetrackingenabled
- `ARCamera.transform`="The position and orientation of the camera in world coordinate space"，坐标系随 session 配置取向：https://developer.apple.com/documentation/arkit/arcamera/transform
- WWDC19 *Introducing ARKit 3* 逐字稿："you can create Face Tracking experiences that make use of the full device orientation and position in 6 degrees of freedom. All of this is supported on A12 devices and later."：https://developer.apple.com/videos/play/wwdc2019/604/
- 多摄像头 ARSession 的两篇实操（`ARWorldTrackingConfiguration` 里加 face、`ARFaceTrackingConfiguration` 里加 world tracking，含"global origin 是 session 起始时设备位置"）：http://www.bradgayman.com/blog/worldFace/worldFace.html 与 http://www.bradgayman.com/blog/faceWorld/index.html

### 1.2 为什么 `sceneDepth` / `smoothedSceneDepth` 在前摄不可用

官方文档对这两个属性的描述都指向**后置相机 + LiDAR**：

- `sceneDepth`："Data on the distance between a device's **rear camera** and real-world objects… populated with `ARDepthData` **captured by the LiDAR scanner**… Call `supportsFrameSemantics(_:)` to support scene depth on select devices and configurations."
- `smoothedSceneDepth`：同上，"captured by the LiDAR scanner"。

来源：https://developer.apple.com/documentation/arkit/arframe/scenedepth 、https://developer.apple.com/documentation/arkit/arframe/smoothedscenedepth

前置 TrueDepth 是结构光（投影仪 + 红外相机），不是 LiDAR，因此 `ARFaceTrackingConfiguration` 不会填充这两个字段。**前摄要稠密深度，只有 `capturedDepthData` 这一条。** 这一点被多篇社区实践反复确认（例如 facescanner-ios 的架构文档把 `frame.capturedDepthData` 作为唯一前摄深度来源）。

### 1.3 路径 (b) VIO/IMU 和 (c) 自研视觉里程计

这两条在 iOS 上都**不必要，且明显更差**：

- ARKit 的 `camera.transform` 本身就是**视觉-惯性里程计（VIO）**的输出。官方 *Understanding World Tracking* 原文：ARKit "uses a technique called visual-inertial odometry. This process combines information from the iOS device's motion sensing hardware with computer vision analysis of the scene visible to the device's camera…"（https://developer.apple.com/documentation/arkit/understanding-world-tracking）。也就是说走 ARKit 就等于自动获得 Apple 调好的 VIO，自研 VIO 是在和 Apple 的传感器融合抢同一份输入还做不过它。
- 想绕过 ARKit 直接读 IMU，只能拿到 `CoreMotion` 的加速度/陀螺（`CMMotionManager` / `CMDeviceMotion`）。它只能给出**相对姿态变化**，没有世界位置，且漂移严重，不足以支撑多帧稠密融合的位姿精度。
- 自研 VO / ICP 里程计（像 KinectFusion 那样从深度/彩色算帧间变换）在**人脸这种光滑、纹理弱、特征少的表面上尤其难收敛**——这也是为什么实际能跑通的前摄人脸扫描项目（如 StandardCyborg、facescanner-ios）都选择把配准交给 ARKit，ICP 只做可选的后处理精修，而不是主路径。

风险（真实工程陷阱）：即便走 ARKit，**脸部平滑区域 + 用户表情/头部移动**会让位姿与深度之间产生不一致，融合时出现"重影/双层壳"。缓解办法有二——(1) 采集时要求用户保持同一表情、尽量只旋转手机而非动脸；(2) 把每个关键帧的深度点云先变换到 `ARFaceAnchor` 的**脸坐标系**再做融合（facescanner-ios 采用此法），让头部轻微运动不污染世界几何。

---

## 2. ARKit 内置重建能力，以及为什么还要自己融合

### 2.1 `sceneReconstruction` 的 mesh 只属于 LiDAR 后摄

- `ARWorldTrackingConfiguration.sceneReconstruction`：开启后 ARKit 返回估计物理环境形状的多边形 mesh；先用 `supportsSceneReconstruction(_:)` 检查设备。https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/scenereconstruction
- `supportsSceneReconstruction(_:)` 文档原文："**Scene reconstruction requires a device with a LiDAR Scanner**, such as the fourth-generation iPad Pro." https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/supportsscenereconstruction(_:)
- 官方 sample *Visualizing and interacting with a reconstructed scene*（iOS 13.4+）也只针对 LiDAR 设备：https://developer.apple.com/documentation/arkit/visualizing-and-interacting-with-a-reconstructed-scene

因此 **`sceneReconstruction` 拿不到前置人脸 mesh**，无论是否 LiDAR 机型。

### 2.2 前摄能拿到的 mesh：`ARFaceAnchor.geometry`（模板拟合，不是扫描）

- `ARFaceAnchor.geometry: ARFaceGeometry` — "A coarse triangle mesh representing the topology of the detected face… conforming a **generic face model** to match the dimensions, shape, and current expression of the detected face." https://developer.apple.com/documentation/arkit/arfaceanchor/geometry
- `ARFaceGeometry` 提供 `vertices` / `triangleIndices` / `textureCoordinates`；社区实测为 **1220 顶点、6912 三角索引**，且 Apple 未公开顶点语义。https://github.com/ryanschiang/arkit-face-tracking-demo
- 它是参数化通用脸（52 个 blend shape 的线性模型），所以**细节是模板的、不是被扫描者的**；拓扑固定，无法表达皱纹、疤痕、真实鼻型/耳型；也不覆盖脸以外区域。

**为什么还要自己融合：**

1. ARKit 给的是一致化后的模板脸，不是计量几何；要做"真三维扫描"（比大小、做定制、3D 打印、医学测量），必须用原始 `capturedDepthData` 做重建。
2. 模板脸被裁掉了额头、头发、耳朵、脖子、下巴下方，而多角度融合的原始点云能覆盖到这些区域。
3. ARKit 的 `sceneReconstruction`（LiDAR 机型才有的高质量 mesh）在前摄/人脸场景根本不可用。

对照实践佐证：swift-tsdf 项目作者的原话——ARKit 免费给 scene mesh，但"a fused TSDF gives control over resolution, truncation, confidence gating, and color averaging that ARKit's black-box meshing doesn't"，且融合能避免 ARKit scene mesh 的"doubled shells and phantom triangles"。https://github.com/stevyf93II/swift-tsdf

---

## 3. 现成开源实现清单

按"能否直接借鉴/复用"排序。所有 star / 更新日期取自 2026-10-04 GitHub API。

### 3.1 最相关：前摄 TrueDepth 深度融合 / 人脸扫描

| Repo | Star | 语言 | 最近更新 | 维护 | 前摄 TrueDepth | 说明与可借鉴点 |
|---|---|---|---|---|---|---|
| [StandardCyborg/StandardCyborgCocoa](https://github.com/StandardCyborg/StandardCyborgCocoa) | 181 | C++/Swift | 2026-05-06 | 活跃（社区维护） | ✅ | **最完整的真扫描方案**。`StandardCyborgFusion` 框架用 TrueDepth 做实时 3D 重建 + mesh；含 ICP（`Algorithm/ICP.cpp`）、PBF（point-based fusion，`PBFModel`/`SurfelFusion`）。MIT（除假肢领域限制已于 2023 到期）。公司已解散，改开源维护。 |
| [StandardCyborg/StandardCyborgSDK](https://github.com/StandardCyborg/StandardCyborgSDK) | 71 | C++ | 2024-11-18 | 活跃 | ✅ | 上面框架的 C++ 核心（`scsdk`、算法、I/O），可单独读算法。 |
| [nlysiuk/facescanner-ios](https://github.com/nlysiuk/facescanner-ios) | 0 | Swift + Python | 2026-08-18 | 新 | ✅ | **与本任务架构几乎一模一样**：手机端 `ARFaceTrackingConfiguration` 抓 `(depth, color, intrinsics, pose, faceAnchor)`，dump 关键帧 → 离线 Open3D `ScalableTSDFVolume` 融合 + marching cubes → 毫米级 OBJ/PLY。含 `ScanExporter.swift`（手写 ASCII PLY、去投影公式）、`ARCHITECTURE.md`（坐标约定、坑）。虽 0 star，但代码直接可抄。 |
| [ybiehl/ba-thesis](https://github.com/ybiehl/ba-thesis) | 1 | Swift + Python | 2026-03-26 | 学术/归档 | ✅ | ETH 本科论文：iPhone TrueDepth 口腔内扫描。Swift RGB-D 采集 App + Python 重建管线（估位姿、多帧融合、抽 mesh、纹理）。学术文档详细。 |
| [davidemonnati/ARFaceDumper](https://github.com/davidemonnati/ARFaceDumper) | 1 | Swift | 2026-10-02 | 新 | ✅（ARKit face） | 用 `ARFaceTrackingConfiguration` 实时抓面部几何/表情，**导出 OBJ 与深度图**。`exportFaceAnchorToOBJ` 是最简 OBJ 写法范本（v/vt/f）。注意它导出的是 `ARFaceGeometry` 模板，不是深度融合 mesh。 |
| [burakSahinkaya/ObjectScanner](https://github.com/burakSahinkaya/ObjectScanner) | 5 | Swift | 2026-08-09 | 新 | ✅ | 一个 App 里并列 photogrammetry / turntable / TrueDepth / RoomPlan 四种模式，统一输出契约，并诚实记录每种在哪崩。适合看架构取舍。 |

> 注：`StandardCyborg/StandardCyborgCocoa` 的 star 数偏低（181），但它是本领域质量最高的可复用代码；star 低是因为公司 2020 年前后解散、项目开源后社区维护，不代表质量。

### 3.2 通用 iOS/Metal 深度融合 / TSDF（多以后摄 LiDAR 为输入，但融合核心可迁移）

| Repo | Star | 语言 | 最近更新 | 维护 | 说明 |
|---|---|---|---|---|---|
| [andyzeng/tsdf-fusion](https://github.com/andyzeng/tsdf-fusion) | 822 | CUDA/C++ | 2019-05-07 | 稳定少更 | 经典 TSDF 融合（KinectFusion 系），把多张已配准深度图融进体素网格再抽 mesh/点云。CUDA，不能直接上 iOS，但算法/数据结构是标准参考。 |
| [andyzeng/tsdf-fusion-python](https://github.com/andyzeng/tsdf-fusion-python) | 1.4k | Python | 2020-01-08 | 稳定少更 | 上面那篇的 CPU/GPU Python 版，离线融合最快验证路径。 |
| [stevyf93II/swift-tsdf](https://github.com/stevyf93II/swift-tsdf) | 0 | Swift | 2026-09-14 | 新 | **纯 Swift、无依赖的 TSDF + marching cubes + binary PLY 导出**，输入是 `depth + confidence + RGB + intrinsics + pose`（正好是 ARKit 能给的），并明确写了 ARKit 相机坐标约定与去投影公式。后摄 LiDAR 出生，但接口通用，**融合核心可直接用到前摄**。 |
| [stevyf93II/vista](https://github.com/stevyf93II/vista) | 1 | Swift | 2026-09-14 | 新 | swift-tsdf 的宿主 App（后摄 LiDAR 房间扫描），导出 GLB/PLY/USDZ，可看端到端整合。 |
| [Smuger/open3d-tsdf-ios](https://github.com/Smuger/open3d-tsdf-ios) | 1 | C++ | 2026-06-26 | 新 | 把 Open3D v0.19 的 TSDF 子系统抽出来，编成 arm64-apple-ios 静态库 + XCFramework（SwiftPM binaryTarget 消费）。想在设备上跑 Open3D TSDF 可直接用。 |
| [sjy234sjy234/KinectFusion-ios](https://github.com/sjy234sjy234/KinectFusion-ios) | 45 | Obj-C++/Metal | 2019-03-18 | 停更 | iPhoneX TrueDepth 深度帧（`depth.bin`，57 帧）跑 Metal GPGPU 版 KinectFusion demo。**明确说自己实时性能不足、只是入门 demo**；issue #2 讨论过接入实时 TrueDepth 数据流。适合看 Metal 实现，不宜直接产品化。 |
| [VladimirYugay/KinectFusion](https://github.com/VladimirYugay/KinectFusion) | 57 | C++ | 2022-02-24 | 停更 | 教科书级 KinectFusion 实现，算法参考。 |
| [TokyoYoshida/ExampleOfiOSLiDAR](https://github.com/TokyoYoshida/ExampleOfiOSLiDAR) | 552 | Swift | 2021-07-24 | 停更 | 后摄 LiDAR 各样例，含 `ARMeshAnchor` → `MDLMesh` → `.obj` 导出。**导出代码通用**。 |
| [TravisHall/RealityKit-Example-ARMeshAnchor-Geometry](https://github.com/TravisHall/RealityKit-Example-ARMeshAnchor-Geometry) | 19 | Swift | 2021-11-29 | 停更 | 从 `ARMeshAnchor` 提取几何并着色，展示 `ARGeometrySource`/`ARGeometryElement` 的正确读法。 |
| [marek-simonik/record3d](https://github.com/marek-simonik/record3d) | 492 | C++ | 2025-04-21 | 活跃 | Record3D iOS App 的伴生库：把 TrueDepth RGB-D 视频实时串流到电脑（USB/网络）。**采集/传数据链路完整，融合在电脑侧**，可作为"手机采集 + 离线融合"方案的参考。 |
| [KuoFengYuan/arkit-3dgs-scanner](https://github.com/KuoFengYuan/arkit-3dgs-scanner) | 17 | Swift | 2026-10-02 | 活跃 | ARKit 位姿 + 可选 LiDAR 融合 + 端侧 3DGS 训练，导出 COLMAP 数据集。看"ARKit 位姿组织成数据集"的写法。 |

### 3.3 只做前摄 face mesh（模板，不融合，供对照）

| Repo | Star | 语言 | 最近更新 | 说明 |
|---|---|---|---|---|
| [ryanschiang/arkit-face-tracking-demo](https://github.com/ryanschiang/arkit-face-tracking-demo) | 12 | Swift | 2024-05-18 | `ARFaceGeometry` 渲染 + 顶点挂载，1220 顶点/6912 面的事实来源。 |
| [Grosshub/AGFaceTracking](https://github.com/Grosshub/AGFaceTracking) | 4 | Swift | 2020-04-29 | 早期官方 face sample 复刻。 |
| [bgayman/worldFace](https://github.com/bgayman/worldFace) | 3 | Swift | 2019-07-19 | `ARWorldTrackingConfiguration` + face tracking 多摄 demo（配套那两篇博客）。 |
| [TravHaran/Im.Primo](https://github.com/TravHaran/Im.Primo) | 15 | Python/iOS | 2021-03-05 | TrueDepth 扫描 → 无线 3D 打印，早期项目。 |
| [project-whispr/facemesh-recorder](https://github.com/project-whispr/facemesh-recorder) | 1 | Swift | 2025-09-28 | 抓 `ARFaceAnchor` 顶点 + blendshape 成归一化点云。 |

**选型建议：** 直接用 `StandardCyborgFusion`（成熟、真三维、MIT）或抄 `swift-tsdf` + `facescanner-ios` 的组合（纯 Swift、易读、与 ARKit 数据接口完全对齐）。若想端侧实时融合，把 `swift-tsdf` 的 TSDF 核搬进 Metal compute shader（`KinectFusion-ios` 有 Metal 版参考）；若接受"手机采集 + 离线融合"，Open3D（Python）或 `open3d-tsdf-ios` 是最短路径。

---

## 4. 导出格式与可复用代码

### 4.1 格式对照

| 格式 | 类型 | 颜色/纹理 | 单位/度量 | 主要用途 | iOS 侧支持 |
|---|---|---|---|---|---|
| **PLY**（ASCII 或 binary） | 点云 + mesh | 可带 per-vertex RGB | 无内建单位（约定写注释） | 研究/可视化/中间产物；点云首选 | 需手写（极简单），或 swift-tsdf 的 `PLYBinaryExporter` |
| **OBJ** | mesh（含 vt/vn） | 支持 UV/材质（需 .mtl） | 无单位 | 通用交换、3D 打印前处理 | `ModelIO` 可写；ARFaceDumper 有手写范本 |
| **STL** | mesh（纯三角） | ❌ 无颜色 | 无单位 | 3D 打印 | `ModelIO` 可写 |
| **USDZ** | 打包场景 | ✅ 支持材质 | 米（Apple 生态） | Apple AR Quick Look / RealityKit 预览 | `ModelIO`/RealityKit 导出；`ARFaceGeometry` 官方推荐导出格式之一 |
| GLB/GLTF | 打包场景 | ✅ | 米 | 跨平台 web/引擎 | 需第三方库 |

官方依据：

- `ARFaceGeometry` 概览明确说它"appropriate for use with various rendering technologies **or for exporting 3D assets**"：https://developer.apple.com/documentation/arkit/arfacegeometry
- `MDLAsset.canExportFileExtension(_:)`："The set of supported formats includes Wavefront Object (`.obj`) and Standard Tessellation Language (`.stl`). Additional formats may be supported as well." → 导出前用它探测。https://developer.apple.com/documentation/modelio/mdlasset/canexportfileextension(_:)
- 社区确认 ModelIO 可直接 `asset.export(to: url)` 出 USDZ（注意：把 mesh 加进 `MDLAsset` 时的 buffer/vertexDescriptor 配错会抛错）：https://stackoverflow.com/questions/64037121/how-to-programmatically-export-3d-mesh-as-usdz-using-modelio
- 格式用途对比（STL 无颜色/单位、OBJ 带 UV、PLY 带点云属性）：https://www.kiriengine.app/blog/explained/3d-file-formats-what-are-they-and-which-one-to-choose 、https://poly.cam/blog/obj-vs-fbx-vs-glb-which-3d-scan-format-should-you-export

### 4.2 从"顶点 + 面片"写文件的代码来源

**OBJ（最简，手写即可）** —— 参考 ARFaceDumper 的 `exportFaceAnchorToOBJ`（`ARFaceDumper/ContentView.swift`，约 L252 起）：

```swift
// vertices
for v in geometry.vertices { objContent += "v \(v.x) \(v.y) \(v.z)\n" }
// uvs
for uv in geometry.textureCoordinates { objContent += "vt \(uv.x) \(uv.y)\n" }
// faces: geometry.triangleIndices 每 3 个一组，1-based，写成 "f a/ a/ a/"
```
来源：https://github.com/davidemonnati/ARFaceDumper （MIT-ish, BSD-3 见其 LICENSE）

**PLY（点云/带色 mesh）** —— 两个现成实现：

- ASCII PLY 手写范本：`nlysiuk/facescanner-ios` 的 `ScanExporter.writePLY`（header + `element vertex N` + `property float x/y/z`，坐标 ×1000 转毫米）。https://github.com/nlysiuk/facescanner-ios/blob/main/ios/Sources/ScanExporter.swift
- binary little-endian PLY（比 ASCII 小 3–5×）：`stevyf93II/swift-tsdf` 的 `PLYBinaryExporter`。https://github.com/stevyf93II/swift-tsdf

**OBJ / STL / USDZ 由 ModelIO 统一导出（推荐）** —— 把顶点/索引装进 `MDLMesh` + `MDLSubmesh`，加进 `MDLAsset` 后 `export(to:)`：

```swift
let allocator = MDLMeshBufferDataAllocator()
let vBuf = allocator.newBuffer(with: Data(fromArray: vertices), type: .vertex)
let iBuf = allocator.newBuffer(with: Data(fromArray: indices), type: .index)
let submesh = MDLSubmesh(indexBuffer: iBuf, indexCount: indices.count,
                         indexType: .uInt16, geometryType: .triangles,
                         material: MDLMaterial(name: "mat", scatteringFunction: ...))
// vertexDescriptor 配好 position/texcoord 属性
let mesh = MDLMesh(vertexBuffer: vBuf, vertexCount: vertices.count,
                   descriptor: vertexDescriptor, submeshes: [submesh])
let asset = MDLAsset(bufferAllocator: allocator)
asset.add(mesh)
try asset.export(to: url)   // .obj / .stl / .usdz
```
参考：https://stackoverflow.com/questions/59475201/save-arfacegeometry-to-obj-file （`ARFaceGeometry` → `MDLMesh` 完整示例）。探测可导出扩展名用 `MDLAsset.canExportFileExtension`。

**USDZ 另一条路**：RealityKit 场景用 `entity.write(to:)` 直接写 USDZ，或在 `ARQuickLookPreviewController` 里预览；但把自定义顶点数据塞进 RealityKit 需要先建 `MeshResource`/`ModelEntity`。来源：https://developer.apple.com/documentation/realitykit/loading-entities-from-a-file

---

## 5. 推荐工程方案（把结论串起来）

**Phase 1 — 采集（端侧 Swift）。**
`ARFaceTrackingConfiguration`，`isWorldTrackingEnabled = true`（先查 `ARFaceTrackingConfiguration.supportsWorldTracking`，A12+）；会话中每个 `ARFrame` 在记录态下取 `capturedDepthData`（转 `DepthFloat32`）、`camera.transform`、`camera.intrinsics`、`ARFaceAnchor.transform`。按平移 >1–2cm 或旋转 >5° 抽关键帧去重。**这是本改造相对原 sample 唯一必须换的东西**（原来 AVFoundation，现在 ARKit）。

**Phase 2 — 融合。** 三条可替换路线，按投入递增：
1. 最快出结果：端侧去投影成点云（`X=(u-cx)/fx*d, Y=(v-cy)/fy*d, Z=d`，乘 pose 得世界点），先变换到脸坐标系再叠加 → PLY。**注意内参要按深度图分辨率对 `intrinsicMatrixReferenceDimensions` 做缩放**，否则去投影错位（facescanner-ios 明确踩过这个坑）。
2. 出 mesh：TSDF（体素截断符号距离）+ marching cubes。复用 `swift-tsdf`（纯 Swift）或 `Open3D`（离线）/`open3d-tsdf-ios`（端侧）。
3. 追求成熟度：直接用 `StandardCyborgFusion`（真扫描 + mesh + 可选 ICP 精修）。

**Phase 3 — 导出。** 中间产物 PLY；交付 USDZ（Apple 生态预览）+ OBJ/STL（3D 打印）。

---

## 6. 待确认 / 风险（明确标注）

1. **[待验证] `isWorldTrackingEnabled = true` 时 `capturedDepthData` 是否仍持续非 nil。** 官方文档只说 `capturedDepthData` 在 face-based 配置下可用、其他配置为 nil；打开 world tracking 不改变配置类别，按文档推断应仍有深度。但这是本方案的地基，**必须在真机上实测**：一边移动手机一边打印 `frame.capturedDepthData == nil` 的比例。若冲突，退化方案是把"位姿"和"深度帧"分开——但那就回到要自己对齐，代价大。
   - 反向路径 `ARWorldTrackingConfiguration + userFaceTrackingEnabled` 已由文档确认**拿不到** `capturedDepthData`（属"other AR configurations"），所以不能拿它当深度来源。
2. **[待验证] A12 以下设备的降级。** 6DoF face tracking 官方限定 A12+；更老机型（如 iPhone X/XS 之前的 A11）打开 `isWorldTrackingEnabled` 会失败。需 `isSupported` + `supportsWorldTracking` 双检查并给降级提示。
3. **[待验证] 前摄 `camera.transform` 在未开 world tracking 时的语义。** 有实践项目（facescanner-ios）**没开** `isWorldTrackingEnabled` 却直接用 `frame.camera.transform` 当 camera→world；也有博客（faceWorld）说必须开才有"accurate device transformation data"。二者存在张力，**不要照抄，按方案 1 打开该开关再验证**。
4. **深度传感器固有精度**：TrueDepth 最佳距离约 15–30cm（超过约 30–40cm 精度显著下降），有效上限约 40cm；分辨率约 640×480。人脸扫描应把工作距离控制在 25–35cm。来源：https://structure.io/blog/which-scanner-is-best-truedepth-vs-lidar-vs-structure-sensor-3- 、https://labs.laan.com/casestudies/truedepth-3d-scanning-case-study
5. **深度帧率约 15Hz（face tracking 下）**，采集时需慢速平滑移动，靠 ARKit 位姿补偿。
6. **深度的颜色/几何对齐**：`capturedDepthData` 的深度图分辨率与 `capturedImage` 彩色图不同，且二者存在轻微空间未对齐（社区有实测，深度图相对 RGB 有偏移）。做彩色 mesh 时需重投影/对齐，或先在 M1/M2 只出无色的几何。来源：https://stackoverflow.com/questions/64809643/arfacetrackingconfiguration-depth-map-not-aligned
7. **ARFaceAnchor 模板脸的顶点语义未公开**（Apple 未文档化），若要用脸 landmark 需自行标定（社区靠 FaceLandmarks.com 之类工具反查）。

---

## 附：一手来源 URL 汇总

Apple 官方文档
- ARFaceTrackingConfiguration / isWorldTrackingEnabled / supportsWorldTracking：https://developer.apple.com/documentation/arkit/arfacetrackingconfiguration ，.../isworldtrackingenabled ，.../supportsworldtracking
- ARFrame.capturedDepthData：https://developer.apple.com/documentation/arkit/arframe/captureddepthdata
- ARFrame.sceneDepth / smoothedSceneDepth：https://developer.apple.com/documentation/arkit/arframe/scenedepth ，.../smoothedscenedepth
- ARWorldTrackingConfiguration.sceneReconstruction / supportsSceneReconstruction / userFaceTrackingEnabled：https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/scenereconstruction ，.../supportsscenereconstruction(_:) ，.../userfacetrackingenabled
- ARCamera.transform：https://developer.apple.com/documentation/arkit/arcamera/transform
- ARFaceAnchor / ARFaceAnchor.geometry / ARFaceGeometry：https://developer.apple.com/documentation/arkit/arfaceanchor ，.../geometry ，https://developer.apple.com/documentation/arkit/arfacegeometry
- ARMeshGeometry：https://developer.apple.com/documentation/arkit/armeshgeometry
- Understanding World Tracking：https://developer.apple.com/documentation/arkit/understanding-world-tracking
- Combining user face-tracking and world tracking：https://developer.apple.com/documentation/arkit/combining-user-face-tracking-and-world-tracking
- Visualizing and interacting with a reconstructed scene：https://developer.apple.com/documentation/arkit/visualizing-and-interacting-with-a-reconstructed-scene
- Tracking and visualizing faces：https://developer.apple.com/documentation/arkit/tracking-and-visualizing-faces
- Streaming depth data from the TrueDepth camera：https://developer.apple.com/documentation/avfoundation/streaming-depth-data-from-the-truedepth-camera
- MDLAsset.canExportFileExtension：https://developer.apple.com/documentation/modelio/mdlasset/canexportfileextension(_:)
- WWDC19 Introducing ARKit 3：https://developer.apple.com/videos/play/wwdc2019/604/
- WWDC20 Explore ARKit 4（notes）：https://wwdcnotes.com/documentation/wwdc20-10611-explore-arkit-4/

社区/第三方
- 多摄像头 ARSession 两篇：http://www.bradgayman.com/blog/worldFace/worldFace.html ，http://www.bradgayman.com/blog/faceWorld/index.html
- TrueDepth vs LiDAR 对比：https://structure.io/blog/which-scanner-is-best-truedepth-vs-lidar-vs-structure-sensor-3-
- TrueDepth 扫描案例：https://labs.laan.com/casestudies/truedepth-3d-scanning-case-study
- 深度图未对齐：https://stackoverflow.com/questions/64809643/arfacetrackingconfiguration-depth-map-not-aligned
- ARFaceGeometry→OBJ：https://stackoverflow.com/questions/59475201/save-arfacegeometry-to-obj-file
- ModelIO→USDZ：https://stackoverflow.com/questions/64037121/how-to-programmatically-export-3d-mesh-as-usdz-using-modelio
- 3D 格式对比：https://www.kiriengine.app/blog/explained/3d-file-formats-what-are-they-and-which-one-to-choose ，https://poly.cam/blog/obj-vs-fbx-vs-glb-which-3d-scan-format-should-you-export
- Open3D TSDF 集成：https://www.open3d.org/docs/latest/tutorial/t_reconstruction_system/integration.html
