# AEGIS TAK Server — 部署套件

把 TAK Server build 成單一 self-contained image,搭配外部 PostgreSQL/PostGIS,
可用 `docker-compose`(本機)或 k8s(平台)部署。完整設計見
[`../plan/README.md`](../plan/README.md)。

> 目前狀態:**Phase 0(scaffold)**。`docker-compose.yml`、`.env.example`、
> 部署步驟會在後續 phase 補上。

## 版本

本套件 pin 在 **`5.7-RELEASE-14`**(單一來源:[`../VERSION`](../VERSION))。
升版只在刻意 merge upstream `upstream/5.x-RELEASE-*` tag 時進行。

## 前置需求

**Build host**
- x86-64 CPU(TAK Server 不支援 arm64 / Apple Silicon)
- JDK 17(build 與 runtime 都需要,不是 11)
- Docker(build image)
- 注意:本 repo 沒有 git tag,gradle 由 `git describe` 推導版本——build 流程會
  顯式帶入版本(見 `../plan/phase-1-build-pipeline.md`)。

**Runtime**
- Docker / k8s(x86-64 節點)
- 外部 **PostgreSQL 15 + PostGIS 3**,且 PostGIS extension 已 enable
- 單一 TAK 容器內跑多個 JVM:建議給它約 **4–8 GB RAM**

## 存取(mTLS)

web UI(8443)與 ATAK(8089)都是 **mTLS-only**:需要 client 憑證。部署後取得
`admin.p12`,匯入瀏覽器個人憑證存放區、重啟瀏覽器,再開 `https://<host>:8443/`。

## 目錄

- `overlay/` — 疊加在 gradle `full` 產物上的 AEGIS 檔案(`.env.example`、
  `docker-compose.yml`、patch 過的 entrypoint)。
- `../k8s/` — k8s manifests(平台目標)。
- `../scripts/` — `build.sh`、`package.sh`。
- `../dist/` — build 產出(git-ignored)。
