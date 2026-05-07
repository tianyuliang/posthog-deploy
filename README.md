# PostHog 私有化部署包

PostHog 私有化部署，镜像版本固定（详见文末 [镜像版本](#镜像版本) 一节）。

## 目录结构

```
posthog-deploy/
├── docker-compose.yaml         # 主编排文件（所有服务定义、镜像版本锁）
├── .env.example                # 环境变量模板
├── services.env                # 服务间内部连接配置（不要改）
├── scripts/
│   └── init-volumes.sh         # 一键创建 ${DATA_ROOT}/<volume> 子目录
├── config/                     # 配置文件
│   ├── clickhouse/             # ClickHouse XML 配置
│   ├── idl/                    # Kafka topic schema (JSON)
│   ├── postgres-init-scripts/  # Postgres 初始化脚本（创建多 DB）
│   ├── products/               # 产品 DB 路由配置
│   ├── temporal/               # Temporal 动态配置
│   ├── livestream/             # Livestream 配置
│   └── user_scripts/           # ClickHouse UDF 二进制（漏斗等聚合函数）
└── share/                      # 运行时共享数据（GeoIP 数据库）
    └── GeoLite2-City.mmdb      # 部署前需下载
```

> 注：`${DATA_ROOT}`（默认 `./data`）下会再生成 13 个数据卷子目录，由 `scripts/init-volumes.sh` 自动创建，详见下文 [数据卷](#数据卷)。

## 系统要求

- Docker + docker-compose v2.x
- 至少 8GB 内存（强烈建议 16GB+）
- 至少 50GB 可用磁盘
- 可访问 `docker.io` / `ghcr.io` / `mmdbcdn.posthog.net`（首次部署）
- 域名 + DNS A 记录指向本机
- 80/443 端口对外开放（TLS）

## 部署步骤

### 1. 下载 GeoIP 数据库（一次性）

```bash
# 需要 brotli 工具
curl -L 'https://mmdbcdn.posthog.net/' --http1.1 \
    | brotli --decompress > share/GeoLite2-City.mmdb
```

如果系统没装 brotli：
- Ubuntu/Debian: `sudo apt install brotli`
- macOS: `brew install brotli`
- CentOS/RHEL: `sudo yum install brotli`

### 2. 配置环境变量

```bash
cp .env.example .env
vim .env
```

**必填项**：
- `DOMAIN` — 你的域名（如 `posthog.example.com`）
- `POSTHOG_SECRET` — `openssl rand -hex 28` 生成
- `ENCRYPTION_SALT_KEYS` — `openssl rand -hex 16` 生成

**可选项**：
- `DATA_ROOT` — 持久化数据卷宿主机根目录，默认 `./data`。生产建议指向独立磁盘挂载点（如 `/mnt/posthog-data`）便于备份。

### 3. 初始化数据卷目录

```bash
bash scripts/init-volumes.sh
```

会按 `.env` 里的 `DATA_ROOT`（默认 `./data`）创建 13 个子目录。**首次启动前必须执行一次** —— 因 compose 用 bind mount 把每个命名卷指向具体路径，路径不存在 `docker-compose up` 会失败。

### 4. macOS 本地开发（仅 Mac 用户需要执行）

**Linux 部署可跳过此步**。

ClickHouse 在 macOS Docker Desktop 的 osxfs/VirtioFS bind mount 上跑 `CREATE OR REPLACE VIEW` 会触发 atomic rename bug（`Code: 57 UUID collision` 或 `Code: 1001 filesystem error: in rename`），导致迁移失败。需要把 ClickHouse 数据卷切换为 Docker named volume：

```bash
cp docker-compose.override.yaml.example docker-compose.override.yaml
```

`docker compose up` 会自动 merge override 文件，把 `clickhouse-data` 改为 named volume（数据存于 Docker 内部 ext4，不经过 macOS 文件系统）。该文件已在 `.gitignore` 中。

### 5. 启动

```bash
docker-compose up -d
```

首次启动会拉镜像 + 跑迁移，大约需要 **5–10 分钟**（国内网络下 GHCR 镜像可能需更久，详见 [镜像版本](#镜像版本)）。

### 6. 验证

```bash
# 看所有服务状态
docker-compose ps

# 看 web 健康状态（应返回 200）
curl http://localhost/_health

# 实时日志
docker-compose logs -f web worker
```

浏览器访问 `https://${DOMAIN}` 即可创建第一个账户。

## 常用运维命令

```bash
# 停止
docker-compose stop

# 重启某个服务
docker-compose restart web worker

# 升级到新 commit（先备份数据库！）
# 1. 修改 docker-compose.yaml 里的镜像 tag
# 2. docker-compose pull
# 3. docker-compose up -d

# 查看资源占用
docker stats

# 完全清空（危险！会丢数据）
docker-compose down -v
```

## 数据卷

所有数据通过 Docker 命名卷 + bind mount 持久化到宿主机 `${DATA_ROOT}/<volume-name>`（默认 `${DATA_ROOT}=./data`）。生产部署只需在 `.env` 修改 `DATA_ROOT` 即可整体迁移到独立磁盘 / SSD / RAID 挂载点。

| 卷名（compose） | 宿主机路径 | 用途 |
|---|---|---|
| `postgres-data` | `${DATA_ROOT}/postgres-data` | Postgres 主数据 |
| `clickhouse-data` | `${DATA_ROOT}/clickhouse-data` | ClickHouse 事件存储（**最大**，建议放高速磁盘）|
| `redis7-data` | `${DATA_ROOT}/redis7-data` | Redis 缓存 |
| `kafka-data` | `${DATA_ROOT}/kafka-data` | Kafka 消息日志 |
| `redpanda-data` | `${DATA_ROOT}/redpanda-data` | Redpanda 数据（备用消息队列）|
| `objectstorage` | `${DATA_ROOT}/objectstorage` | MinIO 对象存储 |
| `seaweedfs` | `${DATA_ROOT}/seaweedfs` | 会话录制存储 |
| `elasticsearch-data` | `${DATA_ROOT}/elasticsearch-data` | Elasticsearch（Temporal 用）|
| `caddy-data` | `${DATA_ROOT}/caddy-data` | Caddy TLS 证书与 ACME 状态 |
| `caddy-config` | `${DATA_ROOT}/caddy-config` | Caddy 运行时配置 |
| `zookeeper-data` | `${DATA_ROOT}/zookeeper-data` | Zookeeper 元数据 |
| `zookeeper-datalog` | `${DATA_ROOT}/zookeeper-datalog` | Zookeeper 事务日志 |
| `zookeeper-logs` | `${DATA_ROOT}/zookeeper-logs` | Zookeeper 日志 |

### 切换到独立磁盘

```bash
# 1. 准备好挂载点（已挂载好独立盘 / RAID）
mkdir -p /mnt/posthog-data

# 2. 修改 .env
DATA_ROOT=/mnt/posthog-data

# 3. 创建子目录
bash scripts/init-volumes.sh

# 4. 启动
docker-compose up -d
```

### 备份

每个卷在宿主机就是一个目录，直接 `tar` / `rsync` 即可：

```bash
# 停服后冷备（数据一致）
docker-compose stop
tar -czf posthog-backup-$(date +%F).tar.gz -C "${DATA_ROOT:-./data}" .
docker-compose start

# 或单独备份某个数据库
docker-compose exec db pg_dumpall -U posthog > pg-$(date +%F).sql
```

## 故障排查

### web 启动失败

```bash
docker-compose logs web | tail -100
```

常见原因：
- 数据库迁移失败 → 看 `db` 和 `clickhouse` 是否健康
- 内存不足 → `free -h` 检查
- 域名不可解析 → 确认 DNS

### 漏斗查询报错 "executable not found"

ClickHouse UDF 没找到二进制。检查：
- `config/user_scripts/` 目录存在
- 容器内 `docker-compose exec clickhouse ls /var/lib/clickhouse/user_scripts/` 能看到 `aggregate_funnel`

### TLS 证书签发失败

- 确认 80/443 端口对外可访问
- DNS 已生效（`dig ${DOMAIN}` 能解析到本机）
- 测试时可在 `.env` 设置 staging CA 避免 Let's Encrypt 速率限制：
  ```
  TLS_BLOCK=acme_ca https://acme-staging-v02.api.letsencrypt.org/directory
  ```

## 镜像版本

PostHog 自有镜像采用以下固定版本（不同来源 commit 不完全同步，原因见下方说明）：

| 镜像 | 引用方式 | 说明 |
|---|---|---|
| `posthog/posthog` | `:16db3d19d9b1025a227c9d6c8a947d7053a95637` | Docker Hub，完整 commit SHA tag |
| `posthog/posthog-node` | `@sha256:863e76e040ad41aef79f605c33ec71f1529bddf94cfd88941c935da9bde97235` | Docker Hub，digest 固化（不可变）|
| `ghcr.io/posthog/posthog/{capture,property-defs-rs,feature-flags,personhog-replica,personhog-router,hypercache-server,cyclotron-janitor,livestream,cymbal}` | `:sha-d8b12b0` | GHCR，9 个仓库共同存在的最新短 SHA tag |

**为什么三类镜像 commit 不同？**

- `posthog/posthog` 在 Docker Hub 按完整 40 位 commit SHA 打 tag，每次提交都有
- `posthog/posthog-node` 在 Docker Hub 构建频率低，commit `16db3d19` 没构建产物，因此用 `master` 当时指向的 digest 固化
- 各 Rust 微服务发布在 GHCR 上，使用 `sha-<7位短SHA>` 命名，需要在 9 个仓库的 tag 列表里取交集，挑最新的共同 commit（当前为 `d8b12b0`）

**升级流程**

1. 选定目标 commit，先验证三处镜像源都能拉到对应 tag
2. 修改 `docker-compose.yaml` 里 21 处镜像引用
3. `docker-compose pull` 验证
4. `docker-compose up -d` 滚动更新

**国内网络注意：**

- `ghcr.io` 在国内访问通常很慢（几十 KB/s），首次拉取建议挂代理或用公益 GHCR 镜像（如 `ghcr.nju.edu.cn`）
- Docker Hub 可在 `~/.docker/daemon.json` 中配置 `registry-mirrors`（如 `https://docker.m.daocloud.io`）加速
