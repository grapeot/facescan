# AGENTS.md — iPhone TrueDepth 人脸扫描重建

这个项目把 Apple 官方的 TrueDepth 深度 sample 改造成一个**可被 AI/agent 驱动**的人脸扫描重建系统：iPhone 采集关键帧，Mac 用 Open3D 融合成三维模型。

## 先读什么

想接手或使用本项目，按顺序读：

1. `docs/rfc.md` — 架构与**冻结契约**（谁依赖谁、目录/JSON schema、位姿约定、参考系选择、outlier/reprojection 过滤、为什么用 devicectl）。任何契约变更必须同步改 `docs/rfc.md` 与 `src/facescan/contract.py`。
2. `skills/facescan/SKILL.md` — 面向其他 AI 的操作入口：如何控制采集 App、如何等待用户扫完、如何拉数据与融合。
3. `docs/prd.md` / `docs/test.md` — 目标与验收标准。

## 结构

- `docs/` — prd、rfc（含冻结契约）、test、working；`docs/research_*.md` 为立项调研素材。
- `ios/` — iPhone 采集 App（xcodegen 管理，`project.yml` + `Sources/` + `Resources/`）。
- `src/facescan/` — Mac 端 Python 融合包。`contract.py` 是契约的唯一实现。
- `scripts/` — agent 与人的稳定入口：`setup.sh`、`build_ios.sh`、`scan.sh`、`pull.sh`、`fuse.sh`。
- `tests/` — 单测与验收脚本。
- `.local/`（gitignored）— 本机 team id、bundle id、设备名等私有配置，由脚本生成。

## 规则

- **契约是硬边界。** iPhone 与 Mac 只通过 `docs/rfc.md` 第 3 节的目录布局与 JSON schema 通信。改一端必须同步另一端与 `contract.py`。
- **端侧只采集，融合在 Mac。** 不要往 App 里塞融合逻辑（那是 Phase 2）。
- **版本控制**：默认分支 `master`。只有用户明确要求时才 commit/push/open PR；提交要小而聚焦。本仓库 target public GitHub，**不要提交**真实 team id、设备名、bundle id、邮箱、内部路径、凭证。私有值放 `.local/` 或 `.env`（均 gitignored）。
- **Python 环境**：用 `uv` 建 `.venv`，装依赖用 `uv pip install`。默认离线测试可跑，联网/真机的测试要显式 opt-in。
- **写完代码更新 `docs/working.md`**（Changelog + Lessons Learned）。
- **不要在公开文件里暴露 public-repo hygiene 讨论**：README 面向用户，隐私扫描/不提交 secrets 这类要求写进本文件、`.gitignore`、`.env.example`。
