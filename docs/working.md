# Working Log

## Changelog

### 2026-10-04

- 立项：调研三条路线（TSDF 体素融合 / 点云配准 / 非刚性），选型为「ARKit 采集 + Mac Open3D TSDF 融合」两段式，理由见 `docs/rfc.md`。
- 冻结契约（`docs/rfc.md` 第 3 节）并实现 `src/facescan/contract.py`。
- 实现 iPhone 采集 App（`ios/`，xcodegen，ARFaceTracking + world tracking），编译通过并装到真机（iPhone 16 Pro Max）。
- 实现 Mac 融合管线（`src/facescan/reconstruct.py` + `cli.py`），Open3D 0.19 跑通。
- 实现 agent 脚本入口（`scripts/`：setup/build_ios/scan/pull/fuse/crosscheck_outliers）。
- 真机全链路跑通：deep link 启停 → 容器拉取 → 融合出可辨认的头肩网格。
- 诊断并修复两个真机 bug：世界追踪被误降级（深度 15Hz vs 相机 60Hz 的正常稀疏被当成故障）、outlier 帧毁掉融合（新增位置一致性剔除）。
- 给 App 增加 `face_pose` / `world_tracking_enabled` 字段落盘，便于 Mac 侧诊断。
- 单测 4 passed（含位姿约定判别力测试 + outlier 剔除测试）。
- 发现并规避 Open3D 0.20.0 的 TSDF 回归（空网格），锁 `<0.20`。
- 关键帧判据从相机运动改为 **face anchor 运动**，修复"头转、相机不动"拍法被丢弃的问题（曾把 69° 的头部转动砍成 2 帧）。
- 新增**参考系选择** `--frame auto|world|face`：头转时用脸坐标系融合，粗糙度从 1.53mm 降到 0.87mm。
- 关键帧阈值降低 4 倍（12mm/6° → 3mm/1.5°），单次扫描可到 186 帧。
- 新增 **reprojection 质量过滤** `--max-reproj-error`（独立于位姿启发式；在早期 probe02 上抓到 500mm 哨兵值坏帧）与**均匀重采样** `--max-frames`。
- 重组与 check-in 准备：加 README + 示例图 `docs/assets/example_scan.jpg`，清理 `tmp/iphone_face_scan` 草稿与本地 out/scans/build 产物。
- 全文档转中文（README 走 AGY 起草后主 agent 审核；skill frontmatter 与正文更新为当前拍法与 flags）。
- Readiness review 通过：pytest 4 passed、shellcheck 干净、bash -n 通过、隐私扫描零命中、gitignore 生效（.local/build/out/scans 未入库）、CI 依赖确认（open3d 0.19 有 manylinux cp312 wheel，测试不依赖 GUI）。
- 建公开仓库 https://github.com/grapeot/facescan（master，保护规则 0 reviewers + enforce admins）。
- 确立最优采集方法（实测）：**手机固定在三脚架上、人小碎步转体、来回慢扫**。粗糙度从一次转到底的 0.9–1.4mm 降到 0.38mm（81 帧干净扫描，reprojection 误差 1.5–2.7mm）。
- 确认前摄物理上限约 ±90°（数据表现为"转到 90° 后回落"），侧后方/后脑不可得。
- 更新 README（hero 图换成 0.38mm 版、采集指引重写）与 skill（采集方法 + 前摄上限 + 弃用 min-valid-ratio）。

## Lessons Learned

- **`capturedDepthData` 在多数相机帧为 nil 是正常的**：TrueDepth 深度约 15Hz，相机约 60Hz，所以约 76% 的 `didUpdate` 帧没有深度。把这种稀疏误判为"故障"并降级 world tracking 会毁掉位姿（只剩旋转、没有平移），融合成一团。降级判据必须是"连续多秒零深度"，不是"多数帧缺深度"。
- **融合 smearing 的首要嫌疑是少数坏帧，不是整体精度**：实测 51 帧里仅 1 帧（首帧）位姿尖峰，就足以拖出明显"翅膀"。先做 outlier 剔除，再谈精度。
- **位姿门限不能级联**：用"与上一保留帧比较"的门限时，首帧坏位姿会让 prev 卡在坏帧，级联剔除所有后续帧。改为与中位数比较的位置一致性门限。
- **ICP 对近静止的人脸是退化的**：用 ICP 去"验证"ARKit 位姿时，会得到比 ARKit 大 2–3 倍的旋转——那是 ICP 在低运动下找伪解，不是 ARKit 错。ARKit 在稳定帧上的重投影误差只有 0.2–1cm，是可用的主信号。
- **头转 vs 机转，决定融合参考系**：相机绕静止的脸转 → 用世界坐标系；头转、相机不动 → 必须用 face anchor 坐标系，否则脸在世界里移动会把点撒开。判据也要相应改为 face anchor 运动，否则头转的帧会被相机静止判据全部丢弃。
- **帧多不等于质量好**：同一段 186 帧扫描取 12/24/48/96 帧融合，表面粗糙度差异很小（1.28–1.48mm），冗余帧已被 TSDF 平均掉。关键帧数够覆盖角度即可，`--max-frames` 用于去冗余。
- **Open3D 0.20.0 会让 TSDF 静默产出空网格**：它对已是米制 float32 的深度又套了一次 `depth_scale=1000`，voxel 无法激活。依赖锁 `open3d>=0.17,<0.20`。上游 issue isl-org/Open3D#7592。
- **契约变更必须三处同步**：`docs/rfc.md`、`src/facescan/contract.py`、iOS 侧 Codable 类型。iOS 与 Mac 各自独立实现同一契约，容易漂移。
- **位姿约定是最高危的单点**：ARKit 是 camera→world 的 GL 约定（相机看 -Z），Open3D 要 world→camera 的 CV 约定（看 +Z），转换需 `diag(1,-1,-1,1) @ inv(pose)`。写错的后果是点云整体翻转但代码不报错，只能靠非平行双视角的融合测试发现。
- **深度 bin 必须去 rowBytes padding**：`CVPixelBuffer` 行距常大于 `width*4`，直接 memcpy 整块会把 padding 混进数据，Mac 侧 reshape 时错位。
- **内参要按 depth 分辨率缩放**：`intrinsicMatrixReferenceDimensions` 是参考分辨率，不缩放会导致反投影系统偏移（社区反复踩）。
- **devicectl 控制面优于 App 内 HTTP**：devicectl 无需网络权限弹窗、离线可用、已被 iOS skill 验证；缺点是每条命令 1–2s，适合离散操作。
