---
name: facescan
description: 从命令行驱动 iPhone TrueDepth 人脸扫描并融合成三维网格。当用户想用自己的 iPhone 扫描人脸得到三维模型，或某个 agent 需要操作采集 App、等待用户扫完、拉取扫描并执行重建时使用。
---

# FaceScan — agent 操作 skill

## 这个 skill 做什么

驱动一台已配对的 TrueDepth iPhone 采集人脸关键帧，把数据拉回 Mac，用 Open3D 融合成三维网格。整条链路是 agent 可驱动的：你可以启动扫描、轮询状态、等用户扫完、搬运数据、跑重建，用户只需拿着手机扫脸。

**不做什么**：不做端侧融合（融合在 Mac）；不做表情/非刚性重建（要求中性表情）；不补头发/眼镜/瞳孔的深度空洞。

## 前置条件

- 项目根：本项目仓库根目录（含 `scripts/`、`src/`、`ios/`）。
- 已配对的 TrueDepth iPhone（iPhone X 及以后），Mac 与手机同一局域网，手机解锁、已信任。
- 首次需 `scripts/setup.sh`（建 venv）与 `scripts/build_ios.sh --install --device <NAME>`（装 App）。

## 控制面：devicectl

所有对手机的操作走 `xcrun devicectl`，无需网络权限弹窗。**所有脚本从 `.local/local.env` 读设备/bundle id，可被参数覆盖。** 不要在命令里硬编码真实 team id、设备名或 UDID。

## 工作流（agent 视角）

1. **确认环境**：`xcodegen`、`uv` 在 PATH；`xcrun devicectl list devices` 能看到目标手机（`available (paired)`）。设备不可见或 locked 时**停下问用户**，不要退回模拟器。
2. **启动扫描**：选一个 run id（`[A-Za-z0-9_-]+`，如 `20261004_213000`）。
   `scripts/scan.sh start --run-id <ID>`
   然后**告诉用户**这套实测最好的拍法：
   - **手机固定，不要手持**：用迷你三脚架/支架把手机立在固定台面上，镜头对着脸。手持会抖，明显掉质量。
   - **人动手机不动**：面对手机站好，头和上身不动，用脚小碎步带动全身慢慢转（不要转头）。
   - **来回慢扫，不要一次转到底**：从正脸开始，左转一点、右转一点，反复小幅往返（约在正面到左右各 50° 之间摆动），让每个角度都有多帧重叠。实测明显好于一次转到极限。来回扫也让屏幕一直大致对着人，按开始/停止按钮方便。
   - 距离约 20–35cm，保持中性表情。扫完说一声。
3. **等用户扫完**：用户说扫完后 `scripts/scan.sh stop`。若你没在跟用户实时交互，可轮询 `scripts/scan.sh status` 直到 `state == "stopped"` 且 `meta.json: present`。**`meta.json` 出现是"扫完了"的唯一可靠信号**（`status.json` 的 `state` 是辅助）。
4. **拉取**：`scripts/pull.sh --run-id <ID> --out scans/<ID>`。
5. **先诊断再融合**：`python -m facescan diagnose <scan_dir>` 看位姿质量。`face_center_max_dev_m` 小（<0.05m）说明位姿一致。可选 `scripts/crosscheck_outliers.py <scan_dir>` 用独立信号（相邻帧深度重投影误差）核对剔除是否合理。
6. **融合**：`scripts/fuse.sh scans/<ID> --out out/<ID>.ply`。
   - 帧多（几十到上百）时加 `--max-frames 48` 均匀重采样去冗余。
   - 加 `--max-reproj-error 0.004` 剔除与邻帧对不齐的坏帧。
   - 参考系默认 `--frame auto`（有 face pose 时用脸坐标系，头转拍法必须如此）。
   - 返回 JSON：`num_frames` 是实际参与融合的帧数，`num_skipped` 是被剔除的坏帧数。
7. **交付**：把输出网格路径给用户，并说明可见的缺口（头发/眼镜区域通常有洞，正常；后脑看不到）。

## 验收标准（判断成功）

- 拉取目录里有 `meta.json` 且 `frames` 非空；每个 `depth_*.bin` 字节数 = `depth_width * depth_height * 4`。
- `fuse.sh` 返回 JSON 里 `num_vertices > 0`、`num_triangles > 0`；输出文件存在且可打开。
- 若 `status.json` 的 `depth_missing / depth_total` 比例很高（接近 1），说明该机型 world tracking 下拿不到深度——这是已知待验证风险（`docs/rfc.md` 6.1），报告给用户，不要假装成功。

## 可用资源

- `scripts/setup.sh`、`build_ios.sh`、`scan.sh`、`pull.sh`、`fuse.sh` —— 稳定入口，参数见各自 `--help`。
- `src/facescan/contract.py` —— 契约的唯一实现（读数据用它的 `load_scan`/`load_depth`）。
- `python -m facescan reconstruct <scan_dir> --out X.ply [--voxel V] [--trunc T] [--depth-min A] [--depth-max B] [--with-color] [--frame auto|world|face] [--max-frames N] [--max-reproj-error M]` —— 底层融合 CLI。
- `python -m facescan diagnose <scan_dir>` —— 只读的位姿质量报告。
- `docs/rfc.md` —— 架构与冻结契约；`docs/test.md` —— 验证策略。

## 已知陷阱

- **深度的行 padding**：iPhone 上 `CVPixelBuffer` 行距常大于 `width*4`。App 已去 padding 落盘；若你自行读原始像素，务必按行拷贝。
- **设备不可达**：`devicectl list devices` 显示 `unavailable` 常因手机锁屏、未信任、或不在同一局域网（tailnet 不承载 Bonjour 发现）。停下让用户处理，不要 fallback。
- **Open3D 版本**：必须 `<0.20`（0.20.0 的 TSDF 回归会静默产出空网格）。用项目 venv，别用系统 Python 乱装。
- **`--terminate-existing` 会重启 App**：`scan.sh start` 用冷启动下发 deep link；若需对已在跑的进程下命令用 `openURL`。
- **契约漂移**：改 iPhone 或 Mac 任一端的数据格式，必须同步 `docs/rfc.md` + `src/facescan/contract.py` + iOS Codable 类型。
- **`capturedDepthData` 多数帧为 nil 是正常的**：TrueDepth 深度约 15Hz，相机约 60Hz，`status.json` 的 `depth_missing/depth_total` 常接近 0.75。这不是故障，别据此判定采集失败。
- **拍法决定参考系**：相机绕静止的脸转用 world 坐标系；头转/人转、相机不动必须用 face 坐标系（`--frame auto` 会自动选）。用错会把点撒开成两层皮。
- **最优拍法是"固定相机 + 人小碎步转体 + 来回慢扫"**：手持必抖、质量差；一次转到底会让每角度重叠少、更毛糙。来回小幅往返让每角度多帧重叠，TSDF 充分平均，实测表面粗糙度可到 0.4mm（一次转到底约 0.9–1.4mm）。
- **前摄物理上限约 ±90°**：脸转过正侧后前摄看不到足够皮肤、ARKit 失去跟踪，所以侧后方/后脑永远扫不到（数据表现为"转到 90° 后回落"）。要 360° 只能分两次扫再拼。
- **帧多不等于质量好**：冗余近重复帧对体积无贡献；`--max-frames` 去冗余，质量靠角度覆盖而非帧数。
- **别按有效深度占比剔帧**（`--min-valid-ratio`）：实测这类扫描的有效占比本就在 24–44% 波动，按占比会误杀大半帧。只用 reprojection 过滤（`--max-reproj-error`）。
- **隐私**：真实 team id / 设备名 / UDID / bundle id 只进 `.local/local.env`（gitignored）。提交前扫描零命中。
