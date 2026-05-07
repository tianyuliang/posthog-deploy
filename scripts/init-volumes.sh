#!/usr/bin/env bash
# 创建 docker-compose 所需的全部数据卷宿主机子目录。
# 读取同级 .env 中的 DATA_ROOT，未设置时默认 ./data
set -euo pipefail

cd "$(dirname "$0")/.."

if [ -f .env ]; then
    # shellcheck disable=SC1091
    set -a; source .env; set +a
fi
ROOT="${DATA_ROOT:-./data}"

VOLUMES=(
    postgres-data
    redis7-data
    clickhouse-data
    zookeeper-data
    zookeeper-datalog
    zookeeper-logs
    kafka-data
    redpanda-data
    objectstorage
    seaweedfs
    caddy-data
    caddy-config
    elasticsearch-data
)

echo "DATA_ROOT = $ROOT"
for v in "${VOLUMES[@]}"; do
    target="$ROOT/$v"
    mkdir -p "$target"
    echo "  ✓ $target"
done

echo ""
echo "完成。共创建/确认 ${#VOLUMES[@]} 个目录。"
