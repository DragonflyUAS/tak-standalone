# Phase 2 — 設定 / 憑證 / 外部 DB 模型

**目標:** 確立單一 image 的 env 驅動設定模型、憑證 bootstrap 與持久化策略,並把
DB endpoint 參數化,讓同一 image 能接「本機 postgis 容器」或「外部/managed DB」。

## 背景

full flavor 的 `docker_entrypoint.sh` 在容器內依序:① 若 `data/certs` 為空就 seed
憑證;② 自動產 root CA、intermediate、server cert、admin cert(全由 env 驅動,
冪等);③ 用 `coreConfigEnvHelper.py` 把 env 注入 CoreConfig;④ 跑 `SchemaManager.jar
upgrade` 初始化 DB;⑤ 啟動 4 個 JVM 並註冊 admin。

`coreConfigEnvHelper.py` 已支援的 env(`src/takserver-core/docker/full/`):

| env | 注入到 CoreConfig | 必填 |
|---|---|---|
| `POSTGRES_URL` | `repository/connection` `url` | 否 |
| `POSTGRES_USER` | `repository/connection` `username` | 否 |
| `POSTGRES_PASSWORD` | `repository/connection` `password` | 是 |
| `TAKSERVER_CERT_PASS` | `security/tls` `keystorePass` | 是 |
| `CA_PASS` | `security/tls` `truststorePass` | 是 |

→ **DB 連線本來就能用 `POSTGRES_URL` env 指定**,外部 DB 天生支援。

## 工作項目

- [ ] **DB endpoint 參數化(關鍵修正):** `docker_entrypoint.sh` 第 ~139 行的
      SchemaManager 呼叫 **hardcode 了 `jdbc:postgresql://takdb:5432/...`**。
      改成讀 `POSTGRES_URL`(或新增 `POSTGRES_HOST/PORT`),讓 schema-init 與
      CoreConfig 指向同一個外部 DB。此修改放在 AEGIS overlay,不動 `src/`
      ——做法:把 patch 過的 entrypoint 放 overlay,packaging 時覆蓋。
- [ ] `AEGIS/overlay/.env.example` 涵蓋 full 的 `EDIT_ME.env` 全部欄位 +
      外部 DB:`POSTGRES_DB/USER/PASSWORD`、`POSTGRES_URL`
      (`jdbc:postgresql://<host>:5432/cot`)、`CA_NAME/CA_PASS`、
      `STATE/CITY/ORGANIZATION/ORGANIZATIONAL_UNIT`、`TAKSERVER_CERT_PASS`、
      `ADMIN_CERT_NAME/ADMIN_CERT_PASS`、heap 變數、port、`TAK_VERSION`。
- [ ] **憑證持久化策略(兩種,文件都要寫):**
  - [ ] *自動產* — entrypoint 首次啟動產憑證寫進 `data/certs`;在 compose 對到
        volume、在 k8s 對到 **PVC**,讓憑證跨 pod 重啟存活。
  - [ ] *預先產* — 先產好 CA/server/admin 憑證,k8s 掛成 **Secret** read-only
        mount(production / GitOps 友善)。
- [ ] **clientAuth 地雷(5.5+):** 確認 `CoreConfig.example.xml` 沒有
      `clientAuth="false"`(字面 false 會讓 API 啟動失敗);只允許
      `NEED`/`WANT`/`NONE`。必要時在 overlay 修正。
- [ ] 確認 `admin.p12` 的輸出/取得方式(供瀏覽器 mTLS 匯入)與其密碼來源
      (`ADMIN_CERT_PASS`)。

## 產出物

- `AEGIS/overlay/.env.example`(含外部 DB 設定)。
- patch 過的 `docker_entrypoint.sh`(DB endpoint 參數化),放 overlay。
- 憑證持久化策略文件(自動產 vs 預先產)。

## 結束 milestone(M2)

同一個單一 image,給不同 `POSTGRES_URL` 即可分別接本機 postgis 容器或外部 DB;
schema-init 與 CoreConfig 指向同一 DB;憑證 bootstrap 與持久化路徑(volume/PVC
或 Secret)都已確定並文件化。

## 地雷 / 注意事項

- 外部 DB 必須 **PostgreSQL 15 + PostGIS 3**,且 **PostGIS extension 要 enable**
  ——managed 服務(RDS/Cloud SQL/Azure)支援但要手動開。
- 別把 `TAKIgniteConfig` 的 cluster 設定打開——我們是單節點,維持預設。
- entrypoint 內多個 `sleep` 是脆弱的時序假設;在 k8s 用 readiness probe 取代
  (見 Phase 5),compose 可暫時容忍。
