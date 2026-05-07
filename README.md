# PostHog 私有化部署包

PostHog 单机私有化部署，所有镜像版本固定（详见 [镜像版本](#镜像版本)）。

## 目录

- [快速开始](#快速开始)
- [系统要求](#系统要求)
- [部署步骤](#部署步骤)
- [macOS 本地开发](#macos-本地开发)
- [运维](#运维)
- [数据卷](#数据卷)
- [故障排查](#故障排查)
- [镜像版本](#镜像版本)

---

## 快速开始

```bash
# 1. 下载 GeoIP 数据库
curl -L 'https://mmdbcdn.posthog.net/' --http1.1 \
    | brotli --decompress > share/GeoLite2-City.mmdb

# 2. 配置环境变量（必填 DOMAIN / POSTHOG_SECRET / ENCRYPTION_SALT_KEYS）
cp .env.example .env && vim .env

# 3. 初始化数据卷目录
bash scripts/init-volumes.sh

# 4. macOS 本地开发额外一步（Linux 跳过）
cp docker-compose.override.yaml.example docker-compose.override.yaml

# 5. 启动
docker compose up -d
```

完成后浏览器访问 `https://${DOMAIN}` （或本地 `http://localhost`）创建第一个账户。

## 系统要求

| 项目 | 最低 | 推荐（生产） |
|---|---|---|
| 内存 | 8 GB | **16 GB+**（迁移阶段需 12 GB） |
| 磁盘 | 50 GB | 200 GB+，独立 SSD |
| Docker | docker compose v2.20+ | 同 |
| 网络 | 可访问 docker.io / ghcr.io / mmdbcdn.posthog.net | 同 |
| 域名 | DNS A 记录指向本机；80/443 对外开放 | 同 |

> ⚠️ Docker Desktop 默认内存常为 7-8 GB，**首次部署前务必调到 12 GB 以上**（Settings → Resources → Memory），否则迁移进程会被 OOM kill。

## 目录结构

```
posthog-deploy/
├── docker-compose.yaml              # 主编排（所有服务定义、镜像版本锁）
├── docker-compose.override.yaml.example  # macOS 开发覆盖模板
├── .env.example                     # 环境变量模板
├── services.env                     # 服务间内部连接（不要改）
├── scripts/
│   └── init-volumes.sh              # 一键创建 ${DATA_ROOT}/<volume> 子目录
├── config/                          # 各服务配置文件
│   ├── clickhouse/                  # ClickHouse XML 配置
│   ├── idl/                         # Kafka topic schema (JSON)
│   ├── postgres-init-scripts/       # Postgres 初始化脚本（创建多 DB）
│   ├── products/                    # 产品 DB 路由配置
│   ├── temporal/                    # Temporal 动态配置
│   ├── livestream/                  # Livestream 配置
│   └── user_scripts/                # ClickHouse UDF 二进制（漏斗等聚合函数）
└── share/                           # 运行时共享数据
    └── GeoLite2-City.mmdb           # GeoIP 数据库（部署前需下载）
```

---

## 部署步骤

### 1. 下载 GeoIP 数据库（一次性）

`feature-flags` / `capture` 等服务依赖 GeoIP 做地理定位。

```bash
# 需要 brotli 工具
curl -L 'https://mmdbcdn.posthog.net/' --http1.1 \
    | brotli --decompress > share/GeoLite2-City.mmdb
```

安装 brotli：
- Ubuntu/Debian: `sudo apt install brotli`
- macOS: `brew install brotli`
- CentOS/RHEL: `sudo yum install brotli`

> ⚠️ PostHog CDN 在国内速度极慢（~10 KB/s），完整 21 MB 文件可能要十几分钟。如下载超时损坏，会导致 `feature-flags` 容器在 maxminddb 初始化时 panic。

### 2. 配置环境变量

```bash
cp .env.example .env && vim .env
```

**必填项**：

| 变量 | 生成方式 | 说明 |
|---|---|---|
| `DOMAIN` | 手填 | 生产填域名（已配 DNS）；本地填 `localhost` |
| `POSTHOG_SECRET` | `openssl rand -hex 28` | 应用主密钥 |
| `ENCRYPTION_SALT_KEYS` | `openssl rand -hex 16` | 字段加密盐，**必须正好 32 ASCII 字符** |

> ⚠️ `ENCRYPTION_SALT_KEYS` 长度不对（不是 hex 16 = 32 字符）会导致 web 启动时 Django 迁移在 Fernet 解密阶段崩溃。占位字符串如 `xinghetest` 不可用。

**可选项**：

- `DATA_ROOT` — 数据卷宿主机根目录（默认 `./data`）。生产建议指向独立磁盘挂载点。
- `TLS_BLOCK` — 留空时使用 docker-compose 默认 `auto_https off`（适合 localhost）；生产留空走 Let's Encrypt 生产证书。

### 3. 初始化数据卷目录

```bash
bash scripts/init-volumes.sh
```

按 `.env` 里的 `DATA_ROOT` 创建 13 个子目录。**首次启动前必须执行一次** —— compose 用 bind mount，路径不存在 `docker compose up` 会失败。

### 4. 启动

```bash
docker compose up -d
```

首次启动 = 拉镜像（几分钟到十几分钟，取决于网络） + 跑迁移（5-10 分钟）。期间 `http://localhost` 会返回 502，**这是正常的** —— Caddy 已通，但后端 web 容器在跑 SQL 迁移，Gunicorn 还没起。

### 5. 验证

```bash
# 看所有服务状态
docker compose ps

# 实时跟踪 web 启动进度
docker compose logs -f web | grep -E "Applying|Booting|Listening"

# 验证 web 健康
curl -I http://localhost/   # 200 / 302 = OK
```

浏览器访问 `https://${DOMAIN}`（或本地 `http://localhost`）：
- 首次进入会跳到 `/preflight` 检查页 → 选 **「Just experimenting」**（生产模式会强制 HTTPS / 邮箱验证等）
- 如果 preflight 显示 `Kafka: Error` —— **是 PostHog 代码的假报错**（self-hosted 模式下 kafka 检查永远返回 false），可以忽略，继续点 Continue
- 然后注册第一个管理员账户即可使用

---

## macOS 本地开发

> Linux 部署可跳过此节。

ClickHouse 在 macOS Docker Desktop 的 osxfs/VirtioFS bind mount 上跑 `CREATE OR REPLACE VIEW` 会触发 atomic rename bug：

```
Code: 57. Mapping for table with UUID=... already exists
Code: 1001. filesystem error: in rename: No such file or directory
```

迁移会卡死并循环重启。原因：macOS Docker Desktop 的 9P/VirtioFS 文件系统对 POSIX rename 语义支持不完整，ClickHouse atomic database 依赖 inode 行为做 OR REPLACE 会失败。

**解决方法**：把 ClickHouse 数据卷切换为 Docker named volume（数据存在 Docker VM 内的 ext4，不经过 macOS 文件系统）：

```bash
cp docker-compose.override.yaml.example docker-compose.override.yaml
```

`docker compose up` 会自动 merge override 文件。该文件已加入 `.gitignore`。

> 其他卷（postgres / kafka / redis / 等）在 macOS bind mount 上没问题，只有 ClickHouse 需要切换。

---

## 运维

```bash
# 停止
docker compose stop

# 重启某个服务
docker compose restart web worker

# 查看资源占用
docker stats

# 实时日志
docker compose logs -f web worker

# 完全清空（危险！会丢数据）
docker compose down -v
```

### 升级到新 commit

```bash
# 1. 备份（必须）
docker compose exec db pg_dumpall -U posthog > pg-$(date +%F).sql
tar -czf clickhouse-$(date +%F).tar.gz -C "${DATA_ROOT:-./data}" clickhouse-data

# 2. 修改 docker-compose.yaml 里 21 处镜像引用（详见 [镜像版本](#镜像版本)）

# 3. 拉镜像 + 滚动更新
docker compose pull
docker compose up -d
```

---

## 数据卷

所有数据通过 Docker 命名卷 + bind mount 持久化到宿主机 `${DATA_ROOT}/<volume-name>`（默认 `${DATA_ROOT}=./data`）。生产部署只需在 `.env` 修改 `DATA_ROOT` 即可整体迁移到独立磁盘 / SSD / RAID 挂载点。

| 卷名 | 宿主机路径 | 用途 |
|---|---|---|
| `postgres-data` | `${DATA_ROOT}/postgres-data` | Postgres 主数据 |
| `clickhouse-data` | `${DATA_ROOT}/clickhouse-data` | ClickHouse 事件存储（**最大**，建议 SSD）|
| `redis7-data` | `${DATA_ROOT}/redis7-data` | Redis 缓存 |
| `kafka-data` | `${DATA_ROOT}/kafka-data` | Kafka 消息日志 |
| `redpanda-data` | `${DATA_ROOT}/redpanda-data` | Redpanda 数据 |
| `objectstorage` | `${DATA_ROOT}/objectstorage` | MinIO 对象存储 |
| `seaweedfs` | `${DATA_ROOT}/seaweedfs` | 会话录制存储 |
| `elasticsearch-data` | `${DATA_ROOT}/elasticsearch-data` | Elasticsearch（Temporal 用）|
| `caddy-data` | `${DATA_ROOT}/caddy-data` | Caddy TLS 证书 / ACME 状态 |
| `caddy-config` | `${DATA_ROOT}/caddy-config` | Caddy 运行时配置 |
| `zookeeper-data` | `${DATA_ROOT}/zookeeper-data` | ZooKeeper 元数据 |
| `zookeeper-datalog` | `${DATA_ROOT}/zookeeper-datalog` | ZooKeeper 事务日志 |
| `zookeeper-logs` | `${DATA_ROOT}/zookeeper-logs` | ZooKeeper 日志 |

### 切换到独立磁盘

```bash
# 1. 准备好挂载点
mkdir -p /mnt/posthog-data

# 2. 在 .env 里改路径
DATA_ROOT=/mnt/posthog-data

# 3. 创建子目录
bash scripts/init-volumes.sh

# 4. 启动
docker compose up -d
```

### 备份

每个卷在宿主机就是一个目录，直接 `tar` / `rsync` 即可：

```bash
# 停服后冷备（数据一致）
docker compose stop
tar -czf posthog-backup-$(date +%F).tar.gz -C "${DATA_ROOT:-./data}" .
docker compose start

# 或单独备份某个数据库
docker compose exec db pg_dumpall -U posthog > pg-$(date +%F).sql
```

---

## 故障排查

### web 容器循环重启 + 502 一直不消失

```bash
docker compose logs web | grep -E "Killed|Error|FATAL" | tail -20
```

常见原因：

| 错误关键词 | 原因 | 解决方案 |
|---|---|---|
| `ValueError: Fernet key must be 32 url-safe base64-encoded bytes` | `ENCRYPTION_SALT_KEYS` 不是 32 字符 | 用 `openssl rand -hex 16`（生成 32 hex 字符）重新填，**清空所有数据**重启 |
| `./bin/migrate: line N: Killed` | 进程被 OOM kill | Docker 内存调到 16 GB+ |
| `Code: 57. Mapping for table with UUID=...` | macOS bind mount 的 ClickHouse OR REPLACE bug | 创建 `docker-compose.override.yaml`（参考 [macOS 本地开发](#macos-本地开发)）|
| `Code: 1001. filesystem error: in rename` | 同上 | 同上 |
| `database "cyclotron" does not exist` | postgres init 脚本无可执行权限 | `chmod +x config/postgres-init-scripts/*.sh` 后重启 db |

### Caddy proxy 无限重启

```bash
docker compose logs proxy | tail -20
```

如果出现 `adapting config using caddyfile: Unexpected next token after '{' on same line`，说明 Caddyfile 里有单行 `{ ... }` 块（Caddy v2 不支持）。本仓库 docker-compose.yaml 已修，自定义改动需注意。

### feature-flags 容器循环重启

```bash
docker compose logs feature-flags | tail -10
```

如果是 `maxminddb panic: index out of bounds`，说明 `share/GeoLite2-City.mmdb` 文件不完整或损坏（PostHog CDN 国内下载常断）。重新下载即可（[步骤 1](#1-下载-geoip-数据库一次性)）。

主 UI 不依赖 feature-flags 服务，可以先跳过。

### 漏斗查询报错 "executable not found"

ClickHouse UDF 二进制没找到。检查：
- `config/user_scripts/` 目录存在
- `docker compose exec clickhouse ls /var/lib/clickhouse/user_scripts/` 能看到 `aggregate_funnel`

### TLS 证书签发失败

- 确认 80/443 端口对外可访问
- DNS 已生效（`dig ${DOMAIN}` 能解析到本机）
- 测试时可在 `.env` 设置 staging CA 避免 Let's Encrypt 速率限制：
  ```
  TLS_BLOCK=acme_ca https://acme-staging-v02.api.letsencrypt.org/directory
  ```

---

## 镜像版本

PostHog 自有镜像采用以下固定版本（不同来源 commit 不完全同步，原因见下方）：

| 镜像 | 引用方式 | 说明 |
|---|---|---|
| `posthog/posthog` | `:16db3d19d9b1025a227c9d6c8a947d7053a95637` | Docker Hub，完整 commit SHA tag |
| `posthog/posthog-node` | `@sha256:863e76e040ad41aef79f605c33ec71f1529bddf94cfd88941c935da9bde97235` | Docker Hub，digest 固化（不可变）|
| `ghcr.io/posthog/posthog/{capture,property-defs-rs,feature-flags,personhog-replica,personhog-router,hypercache-server,cyclotron-janitor,livestream,cymbal}` | `:sha-d8b12b0` | GHCR，9 个仓库共同存在的最新短 SHA tag |
| `clickhouse/clickhouse-server` | `:26.3.9.8` | **PostHog 官方锁定版本**，不要随意降级 |

> ClickHouse 26.3.9.8 是 PostHog `16db3d19` 这个 commit 在 `docker-compose.base.yml` 里写明的版本，注释明确说"keep the default version in sync"。该 PostHog 版本的 ClickHouse 迁移用了 26.x 才支持的 `INDEX TYPE text(tokenizer = ngrams(3))` 等新语法，**降到 25.x / 24.x 会因 `INCORRECT_QUERY` 报错**。

### 为什么 PostHog 三类镜像 commit 不同？

- `posthog/posthog` 在 Docker Hub 按完整 40 位 commit SHA 打 tag，每次提交都有
- `posthog/posthog-node` 在 Docker Hub 构建频率低，commit `16db3d19` 没构建产物，因此用 `master` 当时指向的 digest 固化
- 各 Rust 微服务发布在 GHCR 上，使用 `sha-<7位短SHA>` 命名，需要在 9 个仓库的 tag 列表里取交集，挑最新的共同 commit（当前为 `d8b12b0`）

### 升级流程

1. 选定目标 commit，先验证三处镜像源都能拉到对应 tag
2. 修改 `docker-compose.yaml` 里 21 处镜像引用
3. `docker compose pull` 验证
4. `docker compose up -d` 滚动更新

### 国内网络

- `ghcr.io` 在国内访问通常很慢（几十 KB/s），首次拉取建议挂代理或用公益 GHCR 镜像（如 `ghcr.nju.edu.cn`）
- Docker Hub 可在 `~/.docker/daemon.json` 中配置 `registry-mirrors`（如 `https://docker.m.daocloud.io`）加速
- PostHog GeoIP CDN（`mmdbcdn.posthog.net`）国内极慢，可用代理或科学上网下载
