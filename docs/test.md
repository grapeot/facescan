# Test 策略

## Unit / 离线测试（默认跑，不连真机）

`uv run python -m pytest tests/ -v`

覆盖：
- **契约自洽**：`tests/test_reconstruct.py` 用合成深度（两帧不同位姿看同一世界平面）跑 TSDF 融合。判别力来自"两帧视角非平行"——若 `arkit_pose_to_extrinsic` 的 GL→CV 翻转写错，两帧对不齐，融合面变厚，测试的中位 `|dz|` 阈值会失败。
- **退化场景**：空扫描目录、深度全部无效时，`reconstruct` 抛清晰异常而非静默产出空文件。

## Integration（需真机 / 需显式 opt-in）

以下不在默认 CI 中，手动或 agent 驱动时执行：

- `scripts/build_ios.sh` 编译成功（需 xcodegen + Metal 工具链）。
- `scripts/build_ios.sh --install` 装到已配对的 iPhone。
- `scripts/scan.sh start/stop/status` 的 deep link 控制与状态轮询（需设备解锁、同局域网）。
- `scripts/pull.sh` 拉回真实扫描目录。
- `scripts/fuse.sh` 对真实扫描出网格。

## 手工验证要看什么 artifact

1. 设备容器 `Documents/status.json`：`state` 从 `recording` 变 `stopped`，`depth_missing/depth_total` 比值合理（验证 RFC 6.1 的地基假设）。
2. `Documents/scan_<run_id>/meta.json` + `depth_*.bin`：`bin` 字节数严格 = `w*h*4`（`w*4` 无 padding）。
3. 融合输出 `.ply`：能打开、顶点数 > 0、五官结构可辨。

## 什么算"验证完成"

- 默认 pytest 全绿。
- 真机链路至少人工跑通一次（build → install → scan → pull → fuse）。
- 隐私扫描零命中。
