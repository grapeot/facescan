# RFC：iPhone TrueDepth 人脸扫描重建

状态：v1 设计已冻结（2026-10-04）。变更契约需同步改本文件与 `src/facescan/contract.py`。

## 1. 目标与总体结构

把一个 Apple 官方 sample（单帧 TrueDepth 深度取景器）改造成**可被 AI/agent 驱动**的人脸扫描重建系统。整条链路分成两端，通过一个**冻结的文件契约**解耦：

```text
【iPhone 端】FaceScan.app
  ARFaceTrackingConfiguration + world tracking
  → 记录关键帧（深度 .bin + 彩色 .jpg + 位姿/内参 meta.json）
  → 写入 app 容器 Documents/scan_<run_id>/
              │
              │  devicectl 控制 + 容器文件搬运
              ▼
【Mac 端】facescan (Python + Open3D)
  拉取扫描目录 → TSDF 体素融合 → marching cubes → 导出 mesh
```

关键设计取舍：**iPhone 只负责"采集 + 落盘"，不做融合**。融合放在 Mac 上，用成熟的 Open3D，参数可反复调、改一次不用重编 App。端侧实时融合留作 Phase 2。

## 2. 控制面：为什么选 devicectl 而不是 HTTP

agent 要能"启动扫描 → 等用户扫完 → 收通知 → 拉数据"，需要一个控制与状态通道。两条候选：

- **devicectl（选定）**：`process launch --payload-url` 下发命令，`device copy from` 拉数据，轮询容器里的 `status.json`/`meta.json` 得到"扫完了"的通知。无需网络权限弹窗、无需 App 内起服务、离线可用，且 iOS skill 里这条链路是**已验证**的。缺点是每条命令 1–2s 开销，且要求 Mac 与手机同一局域网、设备解锁。
- **App 内 HTTP/WebSocket 服务（暂不采用）**：可实时双向、可能走 tailnet；但会触发本地网络权限弹窗（需人工点）、要求 App 在前台、且 iOS skill 明确标注**尚未验证**。

本任务的交互本质是**离散**的（开始/停止/拉取），不是实时遥测，正好落在 devicectl 的强项区间。故 v1 只用 devicectl。HTTP 服务作为 Phase 2 备选，只有在需要实时预览点云/进度流时才值得引入。

## 3. 冻结契约（iPhone ↔ Mac）

这是并行开发的前提。iOS 端与 Python 端都只依赖本节的约定，互不感知对方实现。

### 3.1 目录布局（app 容器 Documents/）

```text
Documents/
├── status.json                     # 心跳，录制中每秒覆盖写
└── scan_<run_id>/
    ├── meta.json                   # 关键帧清单（见 3.2）
    ├── depth_0000.bin              # Float32 小端，米，行主序，尺寸见 meta
    ├── color_0000.jpg              # 纹理（可选，v1 融合不依赖）
    ├── depth_0001.bin
    ├── color_0001.jpg
    └── ...
```

`run_id` 由 agent 生成（如 `20261004_213000`），通过 deep link 下发；agent 因此**预先知道**目标目录名 `scan_<run_id>`，可轮询 `meta.json` 判断完成。

### 3.2 `meta.json`

```json
{
  "schema_version": 1,
  "run_id": "20261004_213000",
  "device_model": "iPhone17,2",
  "frames": [
    {
      "index": 0,
      "timestamp": 1234.567,
      "pose": [16 个 float，行主序，camera→world，ARKit 约定，右手系 -Z 朝前],
      "intrinsics": [9 个 float，行主序，已缩放到 depth 分辨率],
      "depth_width": 640,
      "depth_height": 480,
      "color_width": 1920,
      "color_height": 1440,
      "depth_file": "depth_0000.bin",
      "color_file": "color_0000.jpg",
      "confidence": 1.0
    }
  ]
}
```

### 3.3 `status.json`（心跳 / 通知）

```json
{
  "schema_version": 1,
  "run_id": "20261004_213000",
  "state": "recording",
  "keyframes": 12,
  "depth_missing": 0,
  "depth_total": 40,
  "updated_at": 1234.567
}
```

`state` ∈ `idle` / `recording` / `stopped`。录制结束写 `stopped` 且 `scan_<run_id>/meta.json` 出现——这是 agent 判定"扫完了"的**唯一可靠信号**。

### 3.4 深度数据约定

- 格式：裸 `Float32`，小端，**米**，行主序，无 padding（行距 = width×4）。
- 尺寸：见 `meta.json` 的 `depth_width`/`depth_height`（iPhone 上恒为 640×480）。
- 无效像素：`0` 或 `NaN`，融合前必须 mask 掉。
- 读取（numpy）：`np.fromfile(path, dtype="<f4").reshape(h, w)`。

### 3.5 位姿与内参约定

- `pose` 是 ARKit `camera.transform`，即 **camera→world**，右手系、相机看向 **-Z**（OpenGL/ARKit 约定）。
- `intrinsics` 的 `fx,fy,cx,cy` 已按 `intrinsicMatrixReferenceDimensions` 缩放到 **depth 分辨率**（不是彩色分辨率）。缺省时 fx 需自行缩放——这是社区反复踩的坑。
- Python 侧转成 Open3D 用的 world→camera extrinsic（OpenCV 约定，相机看向 +Z）：

  ```python
  extrinsic = diag([1, -1, -1, 1]) @ inverse(pose_4x4)   # GL→CV 翻转
  ```

  实现与单测见 `src/facescan/contract.py`。

## 4. 组件

### 4.1 iPhone 端 FaceScan.app（`ios/`）

- `ARFaceTrackingConfiguration`，`isWorldTrackingEnabled = true`（前提 `supportsWorldTracking`，A12+）。同一个 `ARFrame` 同时提供 `capturedDepthData`、`camera.transform`、`camera.intrinsics`、`capturedImage`。
- **关键帧抽取**：仅当相机相对上一保留帧平移 >12mm 或旋转 >6° 时保留；只在检测到被跟踪人脸时保留，保证重建停留在脸区域。
- **录制**：写 `status.json` 心跳；停止时写 `meta.json`。
- **双通道控制**：既有手动 UI（Record / Stop 大按钮），也响应 deep link `facescan://record?run_id=...` 与 `facescan://stop`。
- **降级监测**：统计 `capturedDepthData == nil` 的比例并写进 `status.json`；若 world tracking 开启后深度大量缺失，退化为不开启 world tracking。
- 复用官方 sample 的思路，但采集用 ARKit（要位姿），深度仍取原始 `capturedDepthData`（**不用** ARKit 的模板脸 `ARFaceAnchor.geometry`，那是参数化模板不是扫描几何）。

### 4.2 Mac 端 facescan（`src/facescan/`）

- `contract.py`：契约的**唯一实现**。定义 schema 常量、`load_scan()`、`arkit_pose_to_extrinsic()`、`load_depth()`。
- `reconstruct.py`：Open3D `ScalableTSDFVolume` 逐帧 `integrate` → `extract_triangle_mesh` → 写 PLY/OBJ。含 **outlier 帧剔除**（见 4.2.1）。
- `diagnose.py`：`python -m facescan diagnose <scan_dir>` 输出位姿质量证据（面中心散布、旋转/平移跨度），供 agent 判断该扫描是否可信。
- `cli.py`：`reconstruct` 与 `diagnose` 两个子命令。

#### 4.2.1 Outlier 帧剔除（已实测）

实测发现两类坏帧会毁掉融合：
1. **位姿尖峰**：ARKit 偶发单帧错误位姿（实测首帧相对邻帧跳 97°），把该帧点云甩到几十厘米外，融合后拖出一条"翅膀"。
2. **丢失主体**：某帧只有背景、没有脸。

剔除逻辑：用**每帧自身位姿**把画面中心像素反投影成世界坐标的"面中心"，取全体中位数，剔除偏离中位数 >15cm 的帧；再剔除有效深度占比 <15% 的帧。该门限已用**独立信号**（相邻帧深度重投影误差）交叉验证：被剔除帧的重投影误差是哨兵值，保留帧全部 3–10mm。交叉验证脚本 `scripts/crosscheck_outliers.py`。

#### 4.2.2 Reprojection 质量过滤 + 均匀重采样

在位置门限之外，`reconstruct` 支持两个可选过滤（`--max-reproj-error`、`--max-frames`）：

- **Reprojection 质量过滤**：对每帧计算它与相邻帧的深度重投影误差（把本帧点经相对位姿投到邻帧、比对预测深度与实测深度），取两侧最小值。这是**独立于位姿启发式**的信号，能抓到"位置看着对、但局部对不齐"的帧。实测在早期 `probe02` 扫描上一眼抓到那个 500mm 哨兵值的坏帧（97° 尖峰）。阈值按数据分布定（186 帧的干净扫描最差 4.86mm，无坏帧）。
- **均匀重采样**（`--max-frames N`）：关键帧阈值调低后一扫描可能有上百帧，近重复帧对体积无贡献还拖慢积分，按时间均匀取样到 N 帧即可。注意帧多≠质量好：同一段 186 帧扫描取 12/24/48/96 帧融合，表面粗糙度差异很小，说明冗余帧已被 TSDF 平均掉。
- 注意：**不要用基于相邻帧旋转差的门限**。实测首帧坏位姿会让"上一保留帧"卡住，级联剔除掉后续所有帧（曾把 51 帧砍到 1 帧）。位置一致性门限无此问题。

### 4.3 脚本（`scripts/`，agent 的稳定入口）

| 脚本 | 作用 |
|---|---|
| `build_ios.sh [--install] [--device NAME]` | xcodegen + xcodebuild（+ 可选安装）。解析 team、注入 bundle id，把结果写入 gitignored 的 `.local/local.env` |
| `scan.sh start --run-id ID [--device NAME]` | deep link 启动录制 |
| `scan.sh stop [--device NAME]` | deep link 停止录制 |
| `scan.sh status [--device NAME]` | 打印容器里的 `status.json` 与是否已有 `meta.json` |
| `pull.sh --run-id ID [--device NAME] [--out DIR]` | 从容器拉取 `scan_<run_id>/` |
| `fuse.sh <scan_dir> [--out FILE]` | 调 Python 融合 |
| `setup.sh` | 建 `uv` venv 并安装依赖 |

## 5. 交付物与验收

- App 能在 iPhone 16 Pro Max 上编译、签名、安装、启动并录出一段扫描。
- Mac 上 `scripts/fuse.sh` 能把该扫描融成能打开的 mesh（PLY），五官结构可见。
- **验收脚本**：`tests/test_reconstruct.py` 用合成深度（两帧不同位姿看同一平面）验证"位姿约定正确"——若约定错，两帧对不齐，融合面会变厚，测试可判别。

## 6. 已知风险（诚实标注）

1. ~~**地基假设待真机验证**：`isWorldTrackingEnabled = true` 时 `capturedDepthData` 是否持续非 nil。~~ **已实测确认**：world tracking 开启时深度持续可用。注意 `capturedDepthData` 在约 60Hz 相机帧里约 76% 为 nil 属**正常**（TrueDepth 深度约 15Hz），不是故障——曾因此误触降级逻辑、把 world tracking 关掉，已修（仅当被跟踪人脸连续 3 秒零深度才降级）。
2. **Open3D 在 macOS arm64 的 wheel 可用性**：安装时确认；不可用则回退点云配准路线。
3. **取景**：自扫时屏幕朝向自己可见（前摄与屏幕同面），但覆盖只有正面约 180°；后脑/耳后不可得。
4. **孔洞**：头发/眼镜/瞳孔/高光是 IR 硬缺口，接受缺失，不做幻想补全。
