# iPhone TrueDepth 多角度扫脸生成 3D 模型：前人做到什么程度、踩过哪些坑

调研日期：2026-10-04。所有关键点附来源 URL，不确定处显式标注。

---

## 一、结论先行：前人做到什么程度

### 一句话结论

用 iPhone 前置 TrueDepth 做「多角度扫脸生成 3D 模型」，在**静止、正面、光照良好、无遮挡**的条件下已经是一个被产品验证过的问题：临床对照金标准（3dMD 立体摄影测量）的均方根误差约 **0.86 mm**（Bellus3D FaceApp + iPhone 11 Pro，97% 标志点在 2 mm 内）[^pmc10172784]。但这条路有四个绕不开的天花板：**前置传感器的取景 UX、人头只能扫到正面约 180°、非刚性形变、以及头发/眼镜/反光造成的深度空洞**。这也是为什么当年做这批 App 的公司（Bellus3D、Heges、Scandy Pro）大多已经停售或停更。

### 产品级先例

| 产品 | 方法 | 实时 or 后处理 | 精度量级 | 现状 |
|---|---|---|---|---|
| **Bellus3D FaceApp** | TrueDepth 结构化光，多视角拼接。官方描述「10 秒内捕获 25 万+ 3D 数据点，用户缓慢转头」[^dpreview]；操作流程为转头 90° 左→中→右→中，App 再「stitch together the various perspectives」[^tmd] | 采集后 stitch（多视角后处理），非单帧 | 临床验证 RMS 0.86±0.31 mm vs 3dMD[^pmc10172784] | 已 EOL/停售[^pmc11654360][^redditb3d] |
| **Heges 3D Scanner** | TrueDepth + LiDAR，实时体素式扫描；有 0.5/0.8/1/2/3/4 mm 精度档 | 实时扫描（on-device） | 第三方评测称其 3D 分辨率达 0.5 mm（注意这是扫描分辨率而非绝对精度）[^mdpi] | 已终止销售[^pmc11654360] |
| **3d Scanner App (Laan Labs)** | TrueDepth 专用模式 + LiDAR；对单个深度帧做类似 photogrammetry 的配准融合 | on-device 处理 | 官方称「typically ~2 mm accuracy, dependent on scan condition」[^laan] | 仍在运营 |
| **Scandy Pro** | TrueDepth，两次点击采集，on-device meshing，逐顶点颜色（texture mapping 曾标注「coming soon」）；用第二台设备镜像屏幕绕过前置取景问题[^geoweek] | 实时/on-device[^scandyig] | 未给公开对照精度 | 已停售（社区可查「What happened to Scandy Pro」）[^redditscandy] |
| **Structure Sensor (Occipital)** | 独立硬件附件，红外辅助双目立体；另有单独的 TrueDepth 扫描授权 | 实时（最高 40+ fps） | Structure Sensor 3 标称 1 mm 细节、最高 1040×1200；TrueDepth 侧 640×480[^structurecompare][^myfit] | 硬件+授权商业化中 |
| **3dMD** | 多机位立体摄影测量 | 快门瞬间 | 临床金标准（对照基准）[^pmc10172784] | 商业设备 |

关键产品观察：

- **没有一家是靠单帧深度直接出模型的。** 要么多视角拼接（Bellus3D），要么多帧体素融合（Heges / 3d Scanner App），要么硬件附件（Structure）。单帧 TrueDepth 只能拿到约正面 50–60° 半侧脸的深度，背面和耳后完全缺失。
- **前置传感器的取景问题是公认痛点。** Occipital 明确说「sensor is always on the front of the phone… operator can't see the screen」，建议用 haptic/声音提示或镜子，但「mirrors may add distortion」[^structurecompare]。Scandy 用第二设备镜像屏幕[^geoweek]，MyFit 说镜子「fragile, needs to be kept clean, and can introduce instability during the scan (tracking loss)」[^myfit]。
- **Bellus3D 有相关专利**（US Patent for 3D Face Scan Technology）[^prweb]，且后来的 US12499616B2「Semantic guidance for 3D reconstruction」讲的是引导用户补扫缺失的语义部位[^patent]。说明「多角度补扫 + 语义引导」是这类产品工程化时的核心机制。
- **这波产品多数已死。** 一份 2024 年的 scoping review 列出 52 个能做脸部扫描的 App，其中只有 13 个进过科学文献，而这 13 个里 6 个已终止销售（含 123D Catch、Bellus3D Face/Dental、Heges、Trnio）[^pmc11654360]。商业上这不是一个靠 App 本身能长期赚钱的品类。

### 学术先例

- **手机 TrueDepth 精度验证**：iPhone 11 Pro + Bellus3D vs 3dMDface，29 名成人，均 RMS 0.86±0.31 mm，97% 标志点 <2 mm，精度 ICC 0.96（excellent），观察者间 0.84（good）[^pmc10172784]。作者仍提醒「需高细节时要审慎使用（分辨率不足、采集时间较长）」。
- **iPad Pro TrueDepth/LiDAR vs 工业扫描仪**：Vogt 等用乐高积木对比，TrueDepth 轮廓偏差均值 4.92 mm（Artec Space Spider 4.51 mm），且小偏差区域标准差很高[^mdpi]。注意这是「整个扫描工作流」的端到端偏差，不是传感器本身的单帧精度，和上面 0.86 mm 的差异来源于对象/流程不同。
- **评估方法论**：Heredia-Lidón 等（2025）提出用几何 + 形态计量联合评估手机扫描 vs 深度学习重建，以立体摄影测量为金标准[^arxiv2502]。
- **深度人脸重建的方法学**：Meyer & Do（CRV 2018）用低质量消费级深度相机（Kinect），做法是**离线把 3DMM（3D morphable model）拟合到一串低质量深度图**得到参考模型，运行时对齐单帧做验证；他们实测传感器误差 e≈5 mm，参考网格 53490 顶点[^crv2018]。这是「模板/参数化模型拟合」路线的代表，也是处理低质量深度 + 姿态/表情变化的经典做法。
- **非刚性融合**：Zollhöfer 等 DynamicFusion（实时非刚性 RGB-D 重建）[^dynamicfusion]、Nießner 的 3D scanning 课程非刚性变形章节[^niessner]，以及模板驱动的非刚性重建[^templateiccv]。学术上处理「扫描对象在动」的正统方法就是**非刚性形变场 + 模板先验**，而不是硬套刚体 ICP/TSDF。
- **一个直接的 TrueDepth RGB-D 人脸重建 repo**：Lzcstan/iOS3DFaceRecon（基于 Apple 官方 TrueDepthStreamer 改造，采集 RGB-D，再配 landmark detector + 3DMM 生成网格，README 里明确把「用 depth json 精修网格」列为 TODO）[^ios3drecon]。可作为起点参考，但注意它只做到「采集 + 3DMM」，深度精修未完成。

### 对「我们」的直接启示

1. **纯几何路线（多帧 TSDF/ICP 融合）在人脸上先天吃亏**，因为人脸是非刚性、且自扫时人在动。产品级前人要么让用户转头逐视角拼接，要么用模板/参数化模型兜底。**建议把「3DMM/ARKit face anchor 模板 + 深度精修」作为主干，而不是从零 TSDF。**
2. **精度目标定在 1–2 mm 是现实的**（临床已验证 0.86 mm，消费级产品自报 ~2 mm）。低于 0.5 mm 在 TrueDepth 上不现实。
3. **覆盖范围（正面 vs 全头）和遮挡（头发/眼镜）是比绝对精度更影响体验的问题**，需要专门的补扫引导。

---

## 二、关键几何问题：前置深度相机与前置 RGB 相机的视场角是否一致？

**结论：在推荐的 AVFoundation（AVCaptureSession）路径下，iPhone 上交付给你的深度图和彩色图是同一像素网格、同一视野的，不存在「RGB 比 depth 宽、纹理映射时深度图没有纹理」的系统性错位。** 具体机制与证据如下：

- Apple 文档明确：深度图「values are warped to match the lens distortion characteristics present in the YUV image pixel buffers captured at the same time」，即深度图被**几何扭曲对齐到同一时刻的彩色帧**；并且提示「depth data map is nonrectilinear… To use depth data for computer vision tasks, use the data in the cameraCalibrationData property to rectify the depth data」[^avdepthdata]。也就是说，交付前 Apple 已经做了到彩色的配准，你直接按像素对应即可；要做 CV 需要的是去畸变，而不是重新对齐视野。
- ZEISS 团队的实测研究（覆盖 iPhone 11 Pro / 12 / 12 Pro / 13 及多代 iPad）结论：**所有 iPhone 在 AVSession 下深度到 RGB 的对齐都很好**，「alignment looks reasonable in ALL tested devices in an AVSession」；深度图在边缘有噪声但整体对齐正确[^zeiss]。他们发现的错位只出现在 **某些 iPad 的 ARKit 模式**（深度图「too wide」，需按 intrinsic reference dimensions 缩放约 5.2% 修正），以及某些 iPad 的工厂内参 focal length 偏差 6–7%[^zeiss]。**iPhone 不受这两个问题影响**。
- 因此，真正的失败模式不是「深度图覆盖范围小于彩色图、纹理映射缺一块」，而是**每个像素上深度值本身可能是无效的（空洞/NaN）**。这些空洞集中在：物体边缘（depth bleeding）、帧最外缘、以及 IR 吸收/遮挡区域（见下节陷阱 5、9）。纹理映射时你遇到的是「有纹理但没深度」的孔洞，而不是「有深度但没纹理」。
- **物理层**：IR 相机与 RGB 相机是两个独立镜头，各自原始 FOV 物理上并不相同（这也是为什么 Apple 要预先 warp 对齐）。我**未找到 Apple 公开给出前置 IR 相机原始 FOV 的官方数字**（标注为不确定）。Stack Overflow 上可查到部分机型前置 RGB FOV 约 54–59°（依赖机型/格式），但那是 RGB 相机而非 IR 相机[^sofov]。**对工程而言只需记住：交付的 depth map 已对齐，直接用 `cameraCalibrationData` 去畸变并按像素对应即可。**
- 一个历史坑：**ARKit 模式下数据会绕 up 轴镜像**，ARKit 与 AVSession 的 unscaled depth intrinsics 在某些设备上差约 7.5%[^zeiss]。**建议统一走 AVFoundation 的 `AVCaptureDataOutputSynchronizer` 拿同步的 RGB+Depth，不要混用 ARKit 的 depth。** ARKit 的 `capturedDepthData` 则用于 ARKit face tracking 场景[^captureddepthdata]。

**实践建议**：在设备上对目标机型打印 `AVCameraCalibrationData` 的 `intrinsicMatrix` / `intrinsicMatrixReferenceDimensions` / `lensDistortionLookupTable`，用 charuco 板做一次自查（ZEISS 提供了开源评估代码）[^zeisseval]，确认你手上机型对齐 OK。不要把 iPad 的内参当真。

---

## 三、实操陷阱清单（现象 / 原因 / 规避）

### 1. 深度与 RGB 不同步或错位

- **现象**：点云上色错位、融合时不同视角对不齐、边缘拉花。
- **原因**：RGB 和 Depth 由两个 output 分别回调，若各用各的 delegate，两帧时间戳不一致；或混用 ARKit 与 AVSession 数据。某些 iPad 在 ARKit 下深度图偏宽约 5.2%。
- **规避**：用 `AVCaptureDataOutputSynchronizer(dataOutputs: [videoOutput, depthOutput])`，它保证同一次回调里拿到时间戳对齐的一对帧；数组第一个 output 是 master[^streaming][^zeiss]。统一走 AVFoundation。在 ARKit 场景用 `frame.capturedDepthData` + `frame.camera.intrinsics` 成对使用[^captureddepthdata]。跨设备要验证，iPad 需按 ZEISS 公式修正。

### 2. 取景困难（前置传感器，自扫 vs 他人代扫）

- **现象**：扫描时看不到屏幕、扫歪、跟丢、要扫耳后/头顶时完全没法自持。
- **原因**：TrueDepth 在正面，屏幕朝向被扫对象时操作者看不到预览；人头还要转头。
- **规避**：
  - 他人代扫 + 语音/文字提示（Bellus3D 用引导式转头流程[^tmd]）；
  - 第二设备镜像屏幕（Scandy、Heges 的屏幕共享）[^geoweek][^hegesfaq]；
  - 镜面配件 + 支架（但要接受「镜子脆弱、易脏、可能引入 tracking loss」）[^myfit][^structurecompare]；
  - 用声音/haptic 提示扫描质量与位置，让用户不看屏也能操作[^structurecompare]。
  - **产品决策**：自扫适合正面半身；全头 360° 基本必须他人代扫或镜子。

### 3. 人脸移动导致的非刚性形变 / 鬼影

- **现象**：模型出现双层皮、重影、面部被「拉长」或糊化，尤其是自扫时手持抖动 + 表情变化。
- **原因**：多帧融合假设场景刚性，但人脸在采集期间会呼吸、微动、变表情，甚至扫描者自己手持时整张脸在动。刚性 ICP/TSDF 无法吸收非刚性形变。
- **规避**：
  - 让被扫者**保持中性表情、静止**（Bellus3D 明确要求 hold neutral expression、不要笑）[^tmd]；
  - 用**模板/参数化先验**（3DMM / ARKit face anchor）约束，把深度残差拟合到模板上，而不是纯几何融合（Meyer & Do 的路线）[^crv2018]；
  - 真要做非刚性，用非刚性融合（DynamicFusion 类）[^dynamicfusion][^templateiccv]；
  - 尽量缩短采集时间、减少需要用户自我动作的时间。

### 4. 头发、眼镜、深色/IR 吸收表面的深度空洞

- **现象**：头发、眉毛、眼镜框、瞳孔、鼻翼下方等区域深度缺失或深度值异常，模型出现破洞或拉丝。
- **原因**：TrueDepth 是 IR 结构化光，**深色/吸红外材质（黑发、深色织物）反射弱**，镜面/透明（眼镜、泪液）反射方向不对，都会被 dot projector / IR 相机漏掉；Apple Face ID 本身也说明墨镜等会遮挡[^applefaceid]。
- **规避**：
  - 官方扫描引导要求**摘掉眼镜和任何遮挡物**（Bellus3D）[^tmd]；
  - 对缺失区域用邻域插值/形态学填补（Apple 官方背景替换示例就做 Gaussian filtering 去孔）[^enhancing]；
  - 开启/关闭 depth filtering 需权衡：`isFilteringEnabled`/`isDepthDataFiltered` 会填补孔洞但也会抹掉细节，官方不同 sample 分别用 true/false[^streaming][^enhancing]；用户可用自己的算法处理[^frost]。
  - 头发区域本质上无解，只能靠多视角 + 引导用户拨开或接受缺顶。

### 5. 深度边缘噪声 / 最外缘伪影

- **现象**：深度图最外缘一两列/行数据错误（portrait 下常见上边和右边），物体轮廓处 depth bleeding、拉边。
- **原因**：深度从 3D 转 2D 时帧边缘不完整；传感器在遮挡边界处的三角化不确定。
- **规避**：
  - 关掉「Smooth depth」后 buffer 边界会更清晰一致[^soartifact]；
  - 对边缘做固定比例裁剪 / 用有效性 mask 剔除[^soartifact]；
  - 处理时对无效值（NaN/0）做 mask，不要当真实深度参与融合。

### 6. 太近导致深度「翻转」成最大值

- **现象**：物体贴近相机时，深度不是接近 0 而是跳到最大距离。
- **原因**：超出 TrueDepth 最近工作距离后深度解算失败，返回上限值。
- **规避**：把有效深度范围卡死（TrueDepth 理想 ~15 cm 起，超过约 1 m 精度急剧下降[^myfit][^laan]），对超近/超远像素做有效性剔除。注意 Structure 说「accuracy falls off dramatically after 30 cm」[^structurecompare]。

### 7. 设备发热 / 降频

- **现象**：长时间实时扫描后帧率下降、深度流中断、设备烫。
- **原因**：持续跑 TrueDepth 深度推理 + RGB 是高负载，触发 thermal throttling。
- **规避**：Apple 官方 sample 专门演示监听 `ProcessInfo.thermalState` 并在 serious/critical 时告警[^truedepthstreamer]；限制连续扫描时长、采集阶段化、降低分辨率。

### 8. 跟踪丢失（纹理/对称表面）

- **现象**：扫描中途突然中断，尤其是扫对称物体（花瓶）或大面积光滑面。
- **原因**：视觉跟踪需要独特特征；对称/无纹理表面上跟踪不稳定。
- **规避**：Heges 的建议是**让场景里有多个物体/背景参照**，避免只对着一个光滑对称物体[^hegesfaq]；对人脸而言，IR 投影图案提供了额外特征，通常比纯 RGB 稳，但仍需保证有足够纹理与运动约束。

### 9. 深度图数据格式陷阱（disparity vs depth、Float16 vs Float32）

- **现象**：读出来的值单位不对、0–1 归一化值、或不是米。
- **原因**：`AVDepthData` 可能是 disparity（1/m）也可能是 depth，可能是 Float16 也可能是 Float32；`depthDataMap` 的数值受 `cameraCalibrationData` 与参考维度影响。
- **规避**：用 `converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)` 统一；按 `AVCameraCalibrationData` 的 `intrinsicMatrixReferenceDimensions` 把内参缩放到你实际用的分辨率（例如 4032→640 缩放因子 0.15873）[^nghiaho][^frost]；注意 640×480 与 4032×3024 长宽比相同（1.333）可直接缩放[^nghiaho]。

### 10. 相机内参不一致（尤其 iPad）

- **现象**：反投影出来的 3D 点系统性偏差、不同设备结果不一致。
- **原因**：某些 iPad（11" 3gen、12.9" 5gen）工厂内参 focal length 偏 6–7%，且 iOS 升级会改内参；ARKit 与 AVSession 的 unscaled depth intrinsics 差约 7.5%。
- **规避**：**优先用 iPhone，不要在 iPad 上盲信内参**；用 charuco 板自标定验证[^zeiss][^zeisseval]；不要硬编码内参，运行时读 API。

### 11. 镜面/反光面

- **现象**：额头、鼻尖高光处深度空洞或跳变。
- **原因**：结构化光在镜面/高光表面反射到相机外。
- **规避**：Occipital 明确 TrueDepth 对反光材质弱，Structure Sensor 3 才主打 HDR 处理黑白/反光[^structurediff]；扫脸时控制光照避免强反光，或对高光区域做填补。

### 12. 单帧覆盖范围不足（背面/耳后/头顶）

- **现象**：模型只有半张脸，后脑勺、耳朵后面没有。
- **原因**：TrueDepth 单帧只有几十度视场，且前置摄像头无法绕到脑后。
- **规避**：多角度采集 + 配准融合（Bellus3D 转头流程[^tmd]）；或用**语义引导补扫**：检测模型缺失的语义部位（耳朵、下巴下方）并引导用户补扫对应视角（Bellus3D 后续专利的方向）[^patent]；用模板补全不可见区域（3DMM 先验）[^crv2018]。

---

## 四、给你的落地建议（基于以上证据）

1. **几何管线**：走 AVFoundation + `AVCaptureDataOutputSynchronizer`，同步取 RGB-D；用 `cameraCalibrationData` 去畸变反投影成点云。
2. **重建主干**：优先「3DMM / ARKit face anchor 模板拟合 + 深度残差精修」，把多帧深度当约束，而不是从零做刚性 TSDF。若坚持几何融合，需引入非刚性形变模型否则一定会鬼影。
3. **采集引导**：被扫者静止、中性表情、摘眼镜；分角度补扫并在 UI 上实时显示已覆盖区域和缺失区域；对自扫场景考虑第二设备镜像或他人代扫。
4. **孔洞处理**：头发/眼镜区域接受缺失或模板补全；边缘裁剪 + 有效性 mask。
5. **设备**：iPhone 优先，iPad 需额外验证内参。
6. **预期**：正面人脸 1–2 mm 是可达的，全头 360° 和极端遮挡场景是主要难点。

---

## 来源

[^pmc10172784]: Validation of three-dimensional facial imaging captured with smartphone-based scanner (iPhone 11 Pro + Bellus3D vs 3dMDface), PMC10172784. https://pmc.ncbi.nlm.nih.gov/articles/PMC10172784/
[^pmc11654360]: Jindanil et al., "Smartphone applications for facial scanning: A technical and scoping review", Orthod Craniofac Res 2024, PMC11654360. https://pmc.ncbi.nlm.nih.gov/articles/PMC11654360/
[^mdpi]: Vogt, Rips, Emmelmann, "Comparison of iPad Pro's LiDAR and TrueDepth Capabilities with an Industrial 3D Scanning Solution", Technologies 9(2):25, 2021. https://www.mdpi.com/2227-7080/9/2/25
[^arxiv2502]: Heredia-Lidón et al., "A 3D Facial Reconstruction Evaluation Methodology…", arXiv:2502.09425. https://arxiv.org/html/2502.09425v1
[^crv2018]: Meyer & Do, "Real-time 3D Face Verification with a Consumer Depth Camera", CRV 2018. https://gregmeyer.info/files/crv2018.pdf
[^dpreview]: DPReview, "Bellus3D uses the iPhone X's TrueDepth camera to 3D scan your face" (2018). https://www.dpreview.com/news/0538420970/bellus3d-uses-the-iphone-x-s-truedepth-camera-to-3d-scan-your-face/
[^tmd]: TMD Technologies, "How to Scan a Face with Bellus3D" (FaceApp 转头流程、摘眼镜、保持中性表情). https://www.tmdtechnologies.com/bellus3d
[^laan]: Laan Labs, "TrueDepth Scanning - Accurate small scans with the iPhone Infrared Depth Sensor" (~2mm 精度、前置仅、range <3ft). https://labs.laan.com/casestudies/truedepth-3d-scanning-case-study
[^structurecompare]: Structure (Occipital), "Which Scanner is Best? TrueDepth vs LiDAR vs Structure Sensor 3". https://structure.io/blog/which-scanner-is-best-truedepth-vs-lidar-vs-structure-sensor-3-/
[^structurediff]: Structure, "Differences between the Structure Sensor 3 and Structure Sensor Pro"（HDR、TrueDepth 授权）. https://structure.io/blog/whats-the-difference-differences-between-the-structure-sensor-3-and-structure-sensor-pro/
[^hegesfaq]: Heges 3D Scanner 官方 FAQ（精度档、慢速移动、对称物体跟踪、屏幕共享）. https://hege.sh/faq
[^myfit]: MyFit Solutions, "Professional TrueDepth scanning: how reliable is it for medical 3D use?"（前置取景/镜子缺陷、15cm–1m）. https://myfit-solutions.com/en/blog/truedepth-camera/
[^geoweek]: Geo Week News, "Scandy: Apps that test the limits of iPhone 3D capture"（Scandy Pro 前置工作流、第二设备镜像）. https://www.geoweeknews.com/articles/scandy-apps-that-test-the-limits-of-iphone-3d-capture-and-a-volumetric-video-first/
[^scandyig]: Scandy Pro Instagram 描述「live on-device meshing」。 https://www.instagram.com/reel/Cp5V6sssJyB/
[^redditscandy]: Reddit r/3Dprinting, "What happened to Scandy Pro?". https://www.reddit.com/r/3Dprinting/comments/1madjtf/what_happened_to_scandy_pro_i_miss_that_app/
[^redditb3d]: Reddit r/iOSProgramming, "Bellus3D is being end-of-lifed, is there any replacement iOS Solution". https://www.reddit.com/r/iOSProgramming/comments/tgr5n6/bellus3d_is_being_endoflifed_is_there_any/
[^prweb]: PRWeb, "Bellus3D Announces Issuance of US Patent for 3D Face Scan Technology". https://www.prweb.com/releases/Bellus3D_Announces_Issuance_of_US_Patent_for_3D_Face_Scan_Technology/prweb16010433.htm
[^patent]: US12499616B2, "Semantic guidance for 3D reconstruction"（引导用户补扫缺失语义部位）. https://patents.google.com/patent/US12499616B2/en
[^avdepthdata]: Apple Developer, AVDepthData（depth map warped to match YUV lens distortion；用 cameraCalibrationData rectify）. https://developer.apple.com/documentation/avfoundation/avdepthdata
[^streaming]: Apple Developer, "Streaming depth data from the TrueDepth camera"（AVCaptureDataOutputSynchronizer、depth filtering）. https://developer.apple.com/documentation/avfoundation/streaming-depth-data-from-the-truedepth-camera
[^enhancing]: Apple Developer, "Enhancing live video by leveraging TrueDepth camera data"（去孔洞 + Gaussian filtering）. https://developer.apple.com/documentation/avfoundation/enhancing-live-video-by-leveraging-truedepth-camera-data
[^captureddepthdata]: Apple Developer, ARFrame.capturedDepthData. https://developer.apple.com/documentation/arkit/arframe/captureddepthdata
[^truedepthstreamer]: Apple Developer, TrueDepthStreamer sample（ProcessInfo.thermalState 监测发热）. https://developer.apple.com/documentation/avfoundation/cameras_and_media_capture/streaming_depth_data_from_the_truedepth_camera
[^zeiss]: Urban et al. (ZEISS), "On the Issues of TrueDepth Sensor Data for Computer Vision Tasks Across Different iPad Generations", arXiv:2201.10865. https://ar5iv.labs.arxiv.org/html/2201.10865
[^zeisseval]: ZEISS 评估代码仓库. https://github.com/ZEISS/iPad_TrueDepth_Issue_Eval
[^nghiaho]: Nghia Ho, "Using the iPhone TrueDepth Camera as a 3D scanner"（内参缩放、畸变查找表、ICP/视觉配准）. https://nghiaho.com/?p=2629
[^frost]: Frost's Blog, "Capture Rectilinear RGBD Data with iPhone"（校准数据字段、isDepthDataFiltered、depth 转换）. https://frost-lee.github.io/rgbd-iphone/
[^ios3drecon]: Lzcstan/iOS3DFaceRecon（RGB-D 采集 + 3DMM，基于 Apple sample）. https://github.com/Lzcstan/iOS3DFaceRecon
[^soartifact]: Stack Overflow, "What's the right way to handle the artifacts from TrueDepth camera buffer near the edges"（边缘伪影、关 Smooth depth）. https://stackoverflow.com/questions/63309600/
[^sofov]: Stack Overflow, "iPhone/iPad front camera FOV"（前置 RGB FOV，指向 Apple 官方 Cameras 兼容表）. https://stackoverflow.com/questions/49260945/iphone-ipad-front-camera-fov
[^applefaceid]: Apple Support, "About Face ID advanced technology". https://support.apple.com/en-us/102381
[^dynamicfusion]: Zollhöfer et al., "Real-time Non-rigid Reconstruction using an RGB-D Camera" (DynamicFusion). http://www.graphics.stanford.edu/~niessner/papers/2014/5deformables/zollhoefer2014deformable.pdf
[^niessner]: Nießner, 3D Scanning & Motion Capture, 非刚性形变章节. https://niessner.github.io/3DScanning/slides/6_Non-Rigid_Deformation.pdf
[^templateiccv]: Yu et al., "Template-Based Non-Rigid 3D Reconstruction from RGB Video", ICCV 2015. https://openaccess.thecvf.com/content_iccv_2015/papers/Yu_Direct_Dense_and_ICCV_2015_paper.pdf
