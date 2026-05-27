# AEGIS TAK Server — 部署套件

把 TAK Server build 成單一 self-contained image,搭配外部 PostgreSQL/PostGIS,
可用 `docker-compose`(本機)或 k8s(平台)部署。完整設計見
[`../plan/README.md`](../plan/README.md)。

> 目前狀態:**Phase 2(config 模型)**。`.env.example` 已就緒;
> `docker-compose.yml` 與完整部署步驟在 Phase 3 補上。

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

## 設定(全部走 env,image 維持 stock)

複製 `.env.example` 成 `.env` 並填入 REQUIRED 值。image 是 100% stock 的 gradle
`full` flavor——entrypoint 在首次啟動時依 env 自動產 PKI、注入 CoreConfig、初始化
DB schema,**不需要修改 image 內任何檔案**。

## 外部 DB 慣例(`takdb:5432`)

stock entrypoint 對 `takdb:5432` 初始化 schema,CoreConfig 則由 `POSTGRES_URL`
指定。兩者對齊即可,**不必 patch image**:

- **docker-compose**:DB 服務命名為 `takdb`(見 Phase 3 的 `docker-compose.yml`)。
- **k8s**:建一個名為 `takdb` 的 Service(`ExternalName` 指向 managed DB host,
  或 headless Service + Endpoints 把 `takdb:5432` 對到 `<db-host>:<db-port>`)。

## 憑證持久化

entrypoint 把產生的憑證放在 `/opt/tak/data/certs`(並 symlink 回 `/opt/tak/certs`),
log 在 `/opt/tak/data/logs`。把 **`/opt/tak/data`** 對到持久儲存:

- **docker-compose**:bind-mount 或 named volume。
- **k8s**:**PVC**。⚠️ 若用「entrypoint 首次自動產憑證」策略,憑證**必須**落在
  PVC,否則 pod 重啟會重產 CA、把已 enroll 的 client 全部失效。
- 另一選項:預先產好憑證,k8s 掛成 **Secret**(read-only,GitOps 友善)。

## 存取(mTLS)

web UI(8443)與 ATAK(8089)都是 **mTLS-only**:需要 client 憑證。部署後取得
`<ADMIN_CERT_NAME>.p12`,匯入瀏覽器個人憑證存放區、重啟瀏覽器,再開
`https://<host>:8443/`。(8446 是 enrollment 連接埠,`clientAuth="false"` 是
官方刻意設定,勿改。)

## 目錄

- `overlay/` — 疊加在 gradle `full` 產物上的 AEGIS 檔案(`.env.example`、
  `docker-compose.yml`、patch 過的 entrypoint)。
- `../k8s/` — k8s manifests(平台目標)。
- `../scripts/` — `build.sh`、`package.sh`。
- `../dist/` — build 產出(git-ignored)。
