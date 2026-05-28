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

## 部署(docker-compose)

```bash
cd AEGIS/overlay
cp .env.example .env          # 編輯,填入所有 REQUIRED(密碼等)
docker compose up -d          # 首次:pull image → 產憑證 → init schema → 註冊 admin
```

首次啟動約 1–2 分鐘。看 log 等到就緒:

```bash
docker compose logs -f takserver
# 看到 "ADMIN USER ADDED"(console)= messaging 層 + admin 就緒
# API(8443)完全就緒的標記在 file log(不在 console):
grep "Started TAK Server api Microservice" takdata/logs/takserver-api.log
```

取 admin 憑證(可能是 root-owned,必要時用 sudo):

```bash
cp ./takdata/certs/files/admin.p12 ~/admin.p12   # 檔名為 ${ADMIN_CERT_NAME}.p12
```

### 常用 ops 指令

```bash
docker compose ps                       # 容器狀態(takdb 應 healthy)
docker compose logs -f takserver        # 即時 log
docker compose logs takserver | grep -i error
docker compose restart takserver        # 改 .env 後重啟
docker compose down                     # 停止(保留 DB volume 與 ./takdata)
docker compose down -v                  # 停止並清空 DB volume(reset)
```

### Troubleshooting

- **`password authentication failed for user "martiuser"`(takserver exit 2、一直重啟)**:
  Postgres 只在資料 volume **首次初始化**時設密碼。改了 `POSTGRES_PASSWORD` 後,
  既有的 `takserver_db_data` volume 仍是舊密碼(`down` 與 `rm -rf ./takdata` 都不會
  動到 named volume)。修法:`docker compose down -v` 清掉 DB volume 再 `up`。
- **`openssl req: Use -help for summary`(產 CA 時)**:密碼含空格——`makeRootCa.sh`
  裸用 `pass:$VAR`。把 `.env` 的密碼改成無空格。
- **`ln: failed to create symbolic link '/opt/tak/logs/logs'`**:image 內
  `/opt/tak/logs` 是真實目錄,stock 的 `ln -s .../data/logs /opt/tak/logs` 會 nest。
  **已在 image build 時 patch 修掉**(見 `AEGIS/scripts/build.sh`);若拉到舊 image
  仍會中,`docker compose pull` 取最新版即可。
- **一直重啟、log 出現 `IgniteException: Failed to find deployed service:
  distributed-user-file-manager`**:stock entrypoint 固定 ~60s 後跑 `certmod -A`,
  server 沒起完就失敗、`set -e` 殺掉容器。**已在 image build 時 patch 成
  retry-until-ready**。若 server 始終起不來,多半是**記憶體不足**——Docker 給 8GB+。
- **web UI / API 請求卡住回 0 bytes、log 有 `UnknownHostException: tak-database`
  或 `HikariPool-1 - Connection is not available ... (total=0)`**:這是 full flavor
  的設定 bug——image 內 `/opt/tak/CoreConfig.xml` 是 `tak-database` + **空密碼**,
  而 `coreConfigEnvHelper.py` 只把 env 注入到 `/opt/tak/data/CoreConfig.xml`,JVM
  卻從 CWD 載入前者。**已在 image build 時 patch 修掉**:helper 跑完後把
  `data/CoreConfig.xml` 覆蓋到 `/opt/tak/CoreConfig.xml`,讓 JVM 載到正確的
  `takdb` + 密碼。**修好後一切走 `takdb`,不需要任何 `tak-database` 別名。**

### 改用外部 / managed DB

把 `docker-compose.yml` 的 `takdb` service 移除,並讓你的 DB 從 takserver 容器以
`takdb:5432` 可達(`.env` 的 `POSTGRES_URL` 已指向那裡)——例如用外部 DNS 或在
compose 加一個 `extra_hosts: ["takdb:<db-ip>"]`。DB 需先建好且 PostGIS extension
已 enable。

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
