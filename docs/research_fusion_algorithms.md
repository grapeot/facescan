# 多视角深度融合成 3D 表面：面向 iPhone 前置 TrueDepth 扫人脸

> 调研对象：把 Apple《Streaming Depth Data from the TrueDepth Camera》改造为「多角度扫描人脸、生成三维模型」的 App。
> 现有基础：前置 TrueDepth 实时 Float16 深度图（约 640×480）、同步 RGB（VGA 640×480）、每帧内参（`cameraCalibrationData.intrinsicMatrix`）。
> 缺口：多帧融合。
> 写作日期：2026-10-04。本文标注了「官方/论文来源」与「社区经验」两类证据，以及不确定项。

---

## 1. 结论（先看这一屏）

把同一张脸从不同角度拍到的多帧深度图拼成一个完整、平滑的三维表面，主流有三条路线：**体素法**（把人脸周围一小块空间切成小格子，每帧把测到的表面距离写进格子里做加权平均，格子零交叉处就是表面）、**点云配准法**（只保留关键帧的三维点，先把它们对齐，最后一次性生成曲面）、**非刚性融合**（用一个会变形的模型，一边对齐位姿一边吸收表情变化）。

对「iPhone 前置 TrueDepth 扫一张脸」这个具体场景，推荐按以下顺序：**第一，刚性 TSDF 体素融合**，配一个头部姿态跟踪把各角度对齐；表情问题用「扫描时保持中性表情」的静态约束或借 ARKit 的表情归一化绕开。**第二，关键帧点云配准 + 一次性曲面重建**，用在更看重离线质量或内存吃紧时。**第三，非刚性融合**（warp field 或 blendshape + deviation image），只在必须边说话边建模时才值得付这个复杂度。**第四，NeRF / 3D Gaussian Splatting 一类学习型方法**，目前端侧不现实，不作为候选。

关键的量级判断：人脸是「小物体」。KinectFusion 用 512³ 体素覆盖 3 米空间，是为了扫描房间；把人脸限制在约 0.3–0.4 米的小立方体里，同样的内存在 256³（甚至 128³）就能达到约 1.2–2.3 毫米的体素边长，远低于 TrueDepth 本身接近毫米级的深度精度。也就是说，**体素法对人脸不是内存问题，而是「别把体积开太大」的问题**。真正困难的是第二件事：脸会动、会有表情。

---

## 2. 场景：现有管线有什么、缺什么

现有 sample 提供三样东西：逐帧深度图、逐帧 RGB、逐帧相机内参。要把它变成一个扫描 App，本质是解决两个子问题：**把不同角度的测量对齐到同一个坐标框架（配准/跟踪）**，以及**把对齐后的测量合并成一个统一表面（融合）**。深度相机本身给出的是 2.5D 测量，单帧只有正面可见的表面，多帧融合才能补全侧面和凹陷区域。

几个必须先交代的工程事实，它们直接决定后续算法的坑：

- TrueDepth 由红外点阵投影器 + 红外相机 + RGB 相机组成，深度靠红外点阵三角测量得到 [S1]。它是结构化光，不是 ToF。
- 所有被测试设备（iPhone 11–13、多代 iPad）的深度图分辨率都是 640×480 [S2]。
- 在近距（约 200mm）下，iPhone 11 Pro 的未投影深度与标定板偏差在 **1 毫米以内或更小**；但部分 iPad 机型（11" 3gen、12.9" 5gen）出厂内参的焦距偏差达 6–7%，会让三维点严重漂移 [S2]。**不确定性**：该结论来自 ZEISS 对若干 iPad 的实测，iPhone 各代的具体精度数值本文未逐一核实。
- **深度图到 RGB 的外参（extrinsics）没有直接 API 可读**，只能假定出厂已精确标定 [S2]。这会让「把 RGB 颜色贴到精确几何上」这一步缺少可验证的基准。
- Apple 官方说明：深度图是非直线（non-rectilinear）的，做计算机视觉/三维相关任务时应先用 `cameraCalibrationData` 做校正，而不是直接拿 depth map 关联三维点 [S2][S3]。

---

## 3. 方法一：体素融合（TSDF / KinectFusion 系）

### 3.1 它到底在做什么

TSDF（Truncated Signed Distance Function，截断符号距离函数）把空间切成立方体网格（体素）。每个体素存一个数：它到最近表面的符号距离——在表面前方为正，后方为负，正好在表面上为零。真实符号距离是全局量，算起来贵；KinectFusion 用的是「投影式 TSDF」：对每个体素，沿相机射线方向查这一帧深度图，算该体素相对测量表面的距离，再截断到 ±μ 范围内 [S4]。

截断是关键设计。距离超过 μ 的地方不再区分「前方多远」，因为深度测量的不确定度本来就只有 μ 这么大。这样体素只需表达三种状态：自由空间（表面前方且在 μ 内）、不确定测量区（表面附近 ±μ）、未知区（完全没被看到）[S4]。每来一帧，体素值与权重做加权滑动平均，等价于对多帧噪声做去噪，零交叉点越来越准 [S4]。

这里有一个对「扫描」很关键的副产品：融合过程中同时维护一张隐式表面，每帧对 TSDF 做 ray casting 就能预测出上一帧的表面，下一帧据此做逐像素的最近点匹配（projective data association），从而估计相机位姿。**跟踪和融合是同一个体素场里自然配套的**，这也是 KinectFusion 系列用起来顺手的原因 [S4]。

### 3.2 分辨率、体积与内存的关系（为什么适合人脸）

内存与精度是一组直接对冲的量。体素总数 = (体积边长 / 体素边长)³。KinectFusion 原文用 512³ 体素、每分量 16 bit，覆盖约 3 米空间，并指出该操作是 **memory-bound 而非 compute-bound**（当时 GPU 可达 650 亿体素/秒，512³ 全量更新约 2ms）[S4]。PCL 的 KinFu 教程也明确：默认 3 米立方体、512 体素/轴，模型质量正比于这两个参数，而修改它们直接改变 GPU 内存占用；KinFu Large Scale 之所以要把世界模型切成小块移动，就是因为 GPU 内存限制 [S5]。

把体积从房间缩到脸，内存按线性边长三次方下降。粗略估算（**本文计算，非引用**）：

| 重建体积 | 体素网格 | 体素边长 | 内存（SDF+权重各 2B，共 4B/体素） |
|---|---|---|---|
| 3 m（房间） | 512³ | 5.9 mm | ≈ 537 MB |
| 0.4 m（头） | 512³ | 0.78 mm | ≈ 537 MB |
| 0.4 m（头） | 256³ | 1.56 mm | ≈ 67 MB |
| 0.3 m（脸） | 256³ | 1.17 mm | ≈ 67 MB |
| 0.3 m（脸） | 128³ | 2.34 mm | ≈ 8 MB |

对比 TrueDepth 本身接近毫米级的深度精度 [S2]，**128³–256³、0.3 米体积**在精度和内存之间已经是很舒服的区间：几十 MB 对现代 iPhone 的统一内存完全可承受。这是「体素法适合人脸」的核心原因——**限制体积换来了分辨率**。真正要警惕的是把体积开成房间尺度，那样要么分辨率崩塌、要么内存爆掉。

### 3.3 端侧可行性的硬证据与坑

- **正向证据（社区）**：有一个 MIT 许可的 iOS 版 KinectFusion demo（Metal GPGPU），输入正是 iPhone X TrueDepth 采集的 57 帧深度，用 Eigen 解 ICP 的 6 变量线性方程 [S6]。它的作者在 README 里直言：实时性能**不够好**，因为它只是给 iOS Metal 初学者的 demo；「在 iPhone X 上做若干优化后能达到……30 更高帧率」（原文措辞模糊，**不确定**，无法判断是 30fps 还是「提升 30」）[S6]。
- **正向证据（社区）**：andyzeng 的 TSDF-fusion 是经典开源实现，但依赖 **NVIDIA CUDA**，不能直接搬上 iPhone [S7]。它提供了 Python CPU/GPU 版本，适合先在桌面验证管线 [S7]。
- **坑一**：项目 issue 里有人反馈「no active voxel」——初始化立方体的位置/大小没设对，所有深度点都落在体积之外 [S8]。人脸扫描要把体积对准脸，不能照搬房间配置。
- **坑二**：直接拿 marching cubes 导出的网格会有大量重复顶点、内存冗余，需要额外做网格清理 [S8]。
- **坑三**：把颜色塞进 TSDF 体素不是好主意；更合理的是重建后再做纹理映射 [S8]。这与第 7 节的纹理方案一致。

---

## 4. 方法二：点云配准 + 融合（ICP / point-to-plane / 特征配准）

### 4.1 它和体素法的根本区别

点云法不在空间里铺格子，而是直接保留三维点。两帧点云对齐的过程叫配准：找对应点、解最优刚性变换、迭代。ICP 的核心矛盾是「对应关系」和「变换」互为前提，所以交替估计 [S9]。经典改进是 **point-to-plane**：不最小化点到点的欧氏距离，而最小化每个源点到对应目标点切平面的距离，需要估计法线；对平面/结构化表面收敛更快、更准 [S9]。再进一步是 Generalized-ICP，用协方差同时建模两片点云的局部平面性，对噪声和点密度变化更鲁棒 [S9]。

性能上，对应搜索用 k-d tree 加速；标准 ICP 对离群点敏感，少数错误对应就能显著带偏变换，需要 robust loss（L1/Huber）或双向（symmetric）对应来压制 [S9]。

### 4.2 与 TSDF 的取舍

- **配准**：两者都需要。TSDF 的位姿估计本质也是 ICP（点对平面）。差别在于 TSDF 可以用「上一帧 ray cast 出的预测表面」做对应源，比原始点云更干净、更密，因此更稳 [S4]。
- **融合/去噪**：TSDF 的加权平均天然把多帧噪声压下去，还免费得到封闭的隐式表面，适合 marching cubes 一次性提取网格 [S4][S7]。纯点云累计不做去噪，多帧叠加会让表面变厚、噪声累积，最后仍要跑一次曲面重建（Poisson / ball-pivoting）。
- **内存与在线性**：点云法不预设体积，理论上不受「盒子开多大」的约束，但也失去了 TSDF 对自由空间/未知区的显式表达，对遮挡与动态更难约束。
- **工程简洁度**：如果目标是「扫完一次性出模型」，关键帧点云 + 末尾 Poisson 重建的组件数更少，不需要维护体素网格和逐帧 ray casting。如果目标是「扫描过程中实时看到逐渐长出来的模型」，TSDF 更自然。

**取舍结论**：小物体（人脸）用 TSDF 更省心；点云法适合作为离线高质量重建的兜底或对照。

---

## 5. 方法三：非刚性形变（人脸会动、有表情）

### 5.1 问题

刚性 TSDF 假定世界静止。人脸在扫描中必然会动、会眨眼、会说话，刚性融合会把这些运动当作噪声平均掉，结果就是表情被糊成一团、细节丢失 [S10][S11]。**这是人脸扫描区别于扫雕塑/房间的核心难点，也是最容易被低估的地方。**

### 5.2 三类处理思路

**（A）动态融合 / warp field**：DynamicFusion 用「canonical 空间 + 逐帧体积形变场」的思路：把每一帧先反形变回一个固定的 canonical 帧，再把深度融进这个帧里，从而所有观测都能贡献到同一个刚性 TSDF [S10]。它维护稀疏的 6D 变换节点，节点间平滑插值，形变量用一个 **256³ 的形变体积**在帧率下计算 [S10]。局限（论文自述）：帧间大运动、遮挡区运动会破坏表面预测，进而导致后续数据关联失败；从闭合到开放拓扑的快速变化处理不好；高度动态时 warp field 稳定性会退化 [S10]。

**（B）运动性能捕捉（多视角/更重）**：Motion2Fusion（perceptiveIO，SIGGRAPH 2017）在 Fusion4D 基础上做非刚性融合，用机器学习估计三维对应场，前后向非刚性对齐处理拓扑变化，号称在**同一块 GPU** 上比前作快近 3 倍，且用「高端但消费级可得的图形硬件」运行 [S11]。**注意**：这套系统面向多相机性能捕捉，不是手机单目方案，端侧不可直接移植。

**（C）模板/表情先验引导（对人脸最实用）**：《Real-time Simultaneous 3D Head Modeling and Facial Motion Capture with an RGB-D camera》给出一条与人脸高度契合的路线：用 **blendshape（表情基）+ Deviation image（偏差图）** 表示头部。blendshape 系数编码表情，Deviation image 记录用户头部相对模板的细节偏差（沿混合法线方向），两者共享同一套纹理坐标 [S12]。它要求用户第一帧保持中性表情，之后可以自由移动、说话、变表情；模型用 running median 策略在线增长和细化，无需预扫描、无需训练 [S12]。这套表示**内存轻**（一张偏差图 + 一张颜色图即可增强全部表情基），对端侧非常友好 [S12]。

**（D）静态约束引导（最省事的工程近似）**：如果不追求边说话边建模，最简单的做法是**约束用户在扫描时保持近似中性表情**，或者只融合「表情接近中性」的帧。ARKit 本身提供 blendshape 系数，可用来判断当前帧表情是否足够中性，甚至把当前脸形「反算」回中性脸再融合。这是第 8 节推荐里的默认策略。

---

## 6. 方法四：基于学习的方法（NeRF / 3DGS / 隐式神经场）

**为什么现在不适合手机端做人脸重建：**

- **NeRF 的渲染算法与图形硬件错配**：NeRF 依赖体渲染/ray marching，与主流 GPU 的多边形光栅化管线不匹配。MobileNeRF 的解决之道是把 NeRF 烘成「带纹理的多边形 + 小 MLP 片段着色器」，才能在手机上交互式渲染 [S13]。但它是**每个场景单独训练/烘焙**，且官方 demo 明确：每个场景需下载 **50–500 MB** 的网格与纹理数据，旧 iPhone 甚至会因内存不足打不开某些无边界 360° 场景 [S13]。**它是「渲染」友好，不是「采集/训练」友好。**
- **3DGS 训练是工作负载级的**：原版 3DGS 假设充足算力、内存和时间，靠离线 SfM + 长时优化 [S14]。端侧训练的最新工作 PocketGS 声称是「首个完全在手机上端到端训练 3DGS」的管线，在 iPhone 15 上约 **500 次迭代、约 4 分钟**完成静态场景重建 [S14]。**不确定性**：这是 2026 年 1 月的预印本（arXiv 编号 2601），peer review 状态与结果可复现性本文未核实；且它面向**手持静态场景**，需要 GPU 原生 BA 和 MVS 生成几何先验，与「扫一张会动的脸」不是同一个问题 [S14]。
- **即便跑得动，也不解决核心问题**：NeRF/3DGS 建模的是辐射场/外观，不直接给「干净、可贴图、可导出、可做 blend shape 的网格表面」。对「生成可用的三维人脸模型」这个目标，它们要么需要额外抽网格，要么只适合做展示型资产。

**结论**：学习型方法目前端侧做 face 重建是不现实的，或至少代价远高于收益，不作为候选。可作为未来「离线高质量外观重建」的备选，不进入实时扫描管线。

---

## 7. 方法五：纹理映射（vertex color vs UV atlas）

### 7.1 两条基本路线

- **顶点色 / 逐体素色**：把颜色存在顶点或体素上，实现最简单，但颜色分辨率被几何分辨率绑定——体素越粗颜色越糊。研究和实践都指出，逐体素颜色被迫在「空间分辨率」和「实时性能」之间做取舍，且容易产生模糊伪影 [S15]。
- **UV atlas（纹理图集）**：把多帧 RGB 投影/融合到一张二维纹理图上，几何与颜色解耦，颜色分辨率可以远高于几何分辨率。传统离线做法要算纹理图集 + 非刚性 warp 校正，非常慢（有一篇报告称某 SOTA 方法对 30 张图算非刚性 warp 参数要 5–6 分钟）[S15]。为实时场景设计的 **TextureFusion** 用「纹理瓦片体素网格」把纹理瓦片嵌进 TSDF 体素结构，并**直接给隐式几何的顶点关联纹理坐标，绕过昂贵的网格参数化**，在质量与实时性之间取得较好折中 [S15]。

### 7.2 对本场景的具体建议

- **ARKit 已经内建 UV**：`ARFaceGeometry` 自带 `textureCoordinates`，而且官方示例演示了如何用 SceneKit shader modifier 把实时相机视频流按位姿映射到人脸网格上 [S16][S17]。如果走「ARKit 表情网格 + 自采深度细节」的混合路线，纹理有现成落点。
- **纯自研 TSDF 管线**：不要走逐体素上色（第 3.3 节的 issue 也建议重建后再做纹理）[S8]。更实际的是：保存若干关键帧的 RGB + 位姿，重建出网格后做一次投影式 UV 烘焙；或者对每个顶点从最优视角采样颜色。后者是工程上最省事、质量通常够用的近似。
- **坑**：PCL KinFu 的纹理后处理会因 RGB 相机自动曝光/白平衡导致不同视角颜色不一致，出现「补丁感」，官方教程明确建议先做颜色均衡 [S5]。人脸各角度光照差异会放大这个问题，需要做色彩/亮度归一。

---

## 8. 方法横向对比

| 方法 | 几何精度 | 端侧可行性（iPhone Metal/CPU） | 实现复杂度 | 内存 | 备注 |
|---|---|---|---|---|---|
| **刚性 TSDF 体素融合** | 高（毫米级，随帧去噪） | **高**（有 iOS Metal 先例；限制体积后内存可控） | 中（跟踪+融合+ray cast） | 低（0.3m/256³ 约 67MB，128³ 约 8MB） | 只对静止物有效；人脸需配表情约束 |
| **点云配准 + 曲面重建** | 高（离线质量可更高） | 中（ICP 可跑；末尾 Poisson 较重） | 中低（组件少） | 低–中（不预设体积，点数随帧增长） | 适合「扫完一次性建模」 |
| **非刚性融合（warp field）** | 很高（保留高频细节） | 低（DynamicFusion 需 GPU 且对运动敏感） | 高 | 中（另有 256³ 形变体积） | 边动边建，稳定性是难点 |
| **模板/表情先验（blendshape + deviation）** | 高且表情解耦 | 中（表示内存轻，但需拟合跟踪） | 高 | 低（一张偏差图+颜色图） | 对人脸最贴合的路线，论文级 |
| **NeRF / 3DGS 学习型** | 外观高、非干净网格 | **低**（NeRF 需烘焙+50–500MB/场景；3DGS 端侧训练 ~4 分钟且面向静态场景） | 很高 | 高 | 当前不作候选 |
| **纹理：vertex color** | — | 高 | 低 | 低 | 颜色分辨率受几何绑定 |
| **纹理：UV atlas / 纹理瓦片** | — | 中（烘焙较费） | 中高 | 中 | 颜色与几何解耦，质量更好 |

（表中「精度/可行性」为本文基于来源的综合判断；内存数字为估算，见第 3.2 节。）

---

## 9. 对「iPhone 前置 TrueDepth 扫人脸」的推荐排序

### 第一选择：刚性 TSDF 融合 + 头部姿态跟踪 + 中性表情约束

理由：人脸是小物体，把重建体积限制在约 0.3–0.4 米后，256³（约 67MB）甚至 128³（约 8MB）就能达到亚毫米到约 2 毫米的体素边长，对手机内存完全友好；TSDF 逐帧加权平均自带去噪，且跟踪与融合共用同一个隐式表面，管线自洽 [S4][S5]。已有 iOS Metal 版 KinectFusion 用 TrueDepth 数据跑通的先例，证明这条路在端侧可行 [S6]。表情问题先用最省事的静态约束：只融合表情接近中性的帧，或用 ARKit blendshape 把当前脸形归一化回中性后再融合。这是投入产出比最高的一条路。

实施注意：体积要对准脸、不要开成房间尺度 [S8]；用原始深度（未双边滤波）做融合以保留高频细节 [S4]；用 `cameraCalibrationData` 校正非直线深度 [S2][S3]；对出厂内参不可全信，必要时自标定 [S2]；监控热状态（sample 已内建）。

### 第二选择：关键帧点云配准 + 一次性曲面重建

理由：组件少、不维护体素网格，适合「扫描结束后生成一个高质量模型」而非实时预览。point-to-plane / GICP 提供比点对点更快更稳的对齐 [S9]。作为第一选择的对照实现或离线兜底。代价是缺少 TSDF 的显式去噪，多帧累点会让表面变厚，最后仍需 Poisson/ball-pivoting。

### 第三选择：非刚性融合 / 表情先验

理由：只有当产品明确要求「边说话/做表情边建模」时才值得。warp field 路线（DynamicFusion 系）在手机上过重且对运动敏感 [S10][S11]；更贴合人脸的是 blendshape + deviation image 的模板路线，内存轻、表情与细节解耦 [S12]，但拟合与跟踪的实现复杂度高。若要做，优先选模板/表情先验而非通用 warp field。

### 不推荐：NeRF / 3DGS

理由：端侧做 face 重建目前不现实或代价过高。NeRF 渲染要靠烘焙成多边形+纹理，单场景 50–500MB，旧机型直接 OOM [S13]；3DGS 端侧训练最好也就是 iPhone 15 上约 4 分钟、且面向静态场景 [S14]。它们不产出「干净可贴图可导出」的网格，不匹配本任务目标。

### 无论走哪条，纹理都建议后置

不要在融合阶段做逐体素上色 [S8]；保存关键帧 RGB + 位姿，重建后做投影式 UV 烘焙或逐顶点选优视角采样，并先做跨视角颜色/亮度均衡 [S5]。若采用 ARKit 表情网格，可直接复用其内建 UV [S16]。

---

## 10. 来源清单

### 官方 / 论文来源

- **[S3]** Apple Developer — AVCameraCalibrationData（内参、外参、镜头畸变接口）。https://developer.apple.com/documentation/avfoundation/avcameracalibrationdata
- **[S4]** Newcombe et al., *KinectFusion: Real-Time Dense Surface Mapping and Tracking*, ISMAR 2011（TSDF 定义、截断、加权平均、512³/16bit、memory-bound）。https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/ismar2011.pdf
- **[S2]** ZEISS, *On the Issues of TrueDepth Sensor Data for Computer Vision Tasks Across Different iPad Generations*, arXiv:2201.10865（640×480、近距 <1mm、外参不可得、非直线深度、部分 iPad 内参偏差 6–7%）。https://ar5iv.labs.arxiv.org/html/2201.10865
- **[S5]** Point Cloud Library — *Using KinFu Large Scale to generate a textured mesh*（默认 3m/512 体素、内存随立方体与体素数变化、GPU 内存限制、纹理后处理与颜色不均衡）。https://pointclouds.org/documentation/tutorials/using_kinfu_large_scale.html
- **[S10]** Newcombe et al., *DynamicFusion: Reconstruction and Tracking of Non-rigid Scenes in Real-Time*, CVPR 2015（canonical 空间 + warp field、256³ 形变体积、大运动/遮挡/拓扑局限）。https://rse-lab.cs.washington.edu/papers/dynamic-fusion-cvpr-2015.pdf ；项目页 https://grail.cs.washington.edu/projects/dynamicfusion/
- **[S11]** Dou et al., *Motion2Fusion: Real-time Volumetric Performance Capture*, SIGGRAPH 2017（3× 加速、需消费级 GPU、处理拓扑变化）。https://www.samehkhamis.com/publications/dou-siggraph2017.pdf
- **[S12]** *Real-time Simultaneous 3D Head Modeling and Facial Motion Capture with an RGB-D camera*, arXiv:2004.10557（blendshape + Deviation image、中性首帧、无预扫描、内存轻）。https://arxiv.org/html/2004.10557v1
- **[S13]** MobileNeRF 项目页（多边形+纹理表示、单场景 50–500MB、旧 iPhone OOM）。https://mobile-nerf.github.io/
- **[S14]** *PocketGS: High-Fidelity On-Device Training for 3D Gaussian Splatting*, arXiv:2601.17354（iPhone 15 上约 500 迭代≈4 分钟、面向静态手持场景；**预印本，peer review 状态未核实**）。https://arxiv.org/html/2601.17354v5
- **[S15]** Lee et al., *TextureFusion: High-Quality Texture Acquisition for Real-Time RGB-D Scanning*, CVPR 2020（逐体素色的分辨率/性能取舍、纹理瓦片体素网格、绕过网格参数化、离线 warp 5–6 分钟）。https://openaccess.thecvf.com/content_CVPR_2020/papers/Lee_TextureFusion_High-Quality_Texture_Acquisition_for_Real-Time_RGB-D_Scanning_CVPR_2020_paper.pdf
- **[S16]** Apple Developer — *Tracking and visualizing faces*（ARKit face mesh、相机视频纹理映射、blend shapes）。https://developer.apple.com/documentation/arkit/tracking-and-visualizing-faces
- **[S17]** Apple Developer — ARFaceGeometry（vertices / textureCoordinates / triangleIndices / blendShapes）。https://developer.apple.com/documentation/arkit/arfacegeometry
- **[S1]** Structure — *The Power of Pocket 3D Scanning: How Apple's TrueDepth Transformed Mobile Tech*（TrueDepth 三组件、结构化光三角测量、毫米级）。https://structure.io/blog/the-power-of-pocket-3d-scanning-how-apples-truedepth-transformed-mobile-tech/

### 社区经验（工程实践参考，非权威结论）

- **[S6]** KinectFusion-ios（Metal GPGPU，iPhone X TrueDepth 57 帧输入，Eigen 解 ICP；作者自述实时性不足，措辞模糊）。https://github.com/sjy234sjy234/KinectFusion-ios
- **[S7]** andyzeng/tsdf-fusion（经典开源 TSDF，依赖 NVIDIA CUDA）。https://github.com/andyzeng/tsdf-fusion
- **[S8]** KinectFusion-ios issue #2（体积初始化导致 no active voxel、marching cubes 网格冗余、不建议把颜色融合进 TSDF）。https://github.com/sjy234sjy234/KinectFusion-ios/issues/2
- **[S9]** LearnOpenCV — *Iterative Closest Point (ICP) for 3D Explained with Code*（ICP 原理、point-to-plane 收敛更快更准、GICP、离群点敏感、k-d tree）。https://learnopencv.com/iterative-closest-point-icp-explained/

### 附加参考（未在正文展开，供深入）

- Statistical Non-rigid ICP for 3D face alignment：https://ibug.doc.ic.ac.uk/media/uploads/documents/statistical_non_rigid_icp.pdf
- Oxford Echoes — iOS ARKit Face Tracking Vertices（ARKit 人脸网格 1220 顶点的标注，社区整理，随版本可能变化）：https://www.oxfordechoes.com/ios-arkit-face-tracking-vertices/
- Apple — recommendedMaxWorkingSetSize（GPU 可分配内存的经验阈值，设备相关）：https://developer.apple.com/documentation/metal/mtldevice/recommendedmaxworkingsetsize

---

<details>
<summary>附：本次调研的取舍与不确定项（审计用）</summary>

- 本文内存估算（第 3.2 节）基于「体素数³ × 4 字节」的简单模型，未计入 marching cubes 输出网格、ray-casting 缓存、纹理等额外开销，实际内存更高。
- KinectFusion-ios 的「30 higher frame rate」原文措辞有歧义（30fps vs 提升 30），已在正文标注为不确定。
- PocketGS（3DGS 端侧训练）为 2026-01 预印本，未核验同行评审与可复现性；其在 iPhone 15 上的「约 4 分钟」是论文自述值。
- ZEISS 论文主要测 iPad，iPhone 各代的具体深度精度未逐机核实；「近距 <1mm」不能外推到所有机型和距离。
- 未展开「多视角立体（MVS）」「深度补全/超分」「神经隐式表面（SDF-based，如 NeuS）」等分支，因为它们要么属于学习型范畴，要么不是本任务的多帧融合主线。
- 未实测任何方案；结论为基于来源的可行性判断，实际端侧性能需在目标机型上 benchmark。

</details>
