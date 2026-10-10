#!/usr/bin/env bash
# 端到端：依赖图自动推进 + 验收两阶段 + 回修交回原会话（真实 git / cc-fleet-land / await；Claude CLI 与 daemon 替身）
set -eu
python3 "$(dirname "$0")/test_fleet_pipeline_e2e.py"
