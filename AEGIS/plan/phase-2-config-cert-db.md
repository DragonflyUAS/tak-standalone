# Phase 2 — 設定 / 憑證 / 外部 DB 模型

**目標:** 確立單一 image 的 env 驅動設定模型、憑證 bootstrap 與持久化策略,並讓
DB 以**部署層**對接外部 endpoint——**image 維持 100% stock,完全不 patch**。

> **實作狀態(2026-05-27):** 已完成 `AEGIS/overlay/.env.example` 與
> `AEGIS/overlay/README.md`(DB 慣例 + 憑證持久化)。讀過 source 後**推翻了原本
> 「patch entrypoint」與「strip clientAuth」兩個任務**(見下方修正)。

## 背景與關鍵發現

full flavor 的 `docker_entrypoint.sh` 在容器內依序:① 若 `data/certs` 為空就 seed
憑證並 symlink;② 依 env 自動產 root CA、intermediate、server、admin 憑證
(冪等);③ 用 `coreConfigEnvHelper.py` 把 env 注入 CoreConfig;④ 跑
`SchemaManager.jar upgrade`;⑤ 啟動 4 個 JVM 並註冊 admin。

讀 source 後的三點修正:

1. **DB 不需要 patch(改用 `takdb:5432` 慣例)。** entrypoint 第 ~139 行對
   `jdbc:postgresql://takdb:5432/${POSTGRES_DB}` 初始化 schema(hardcode host
   `takdb`、port `5432`)。CoreConfig 的連線則由 `coreConfigEnvHelper.py` 讀
   `POSTGRES_URL` 注入(`CoreConfig.example.xml:79` 預設 `127.0.0.1` 會被蓋掉)。
   只要 **DB 對容器以 `takdb:5432` 可達**、且 `POSTGRES_URL=jdbc:postgresql://
   takdb:5432/cot`,兩者就對齊——**不必碰 image**。把變異性放在部署層
   (compose 服務名 / k8s Service)。
2. **clientAuth 不要動。** `CoreConfig.example.xml:37` 的
   `<connector port="8446" clientAuth="false" .../>` 是 **enrollment 連接埠的
   官方刻意設定**;8443(`CoreConfig.example.xml:30`,無 clientAuth 屬性)才是
   mTLS web UI。盲目刪除 `clientAuth="false"` 會弄壞 enrollment。**用 stock
   CoreConfig,不改。**
3. **COUNTRY hardcode。** `cert-metadata.sh` 從 env 讀 STATE/CITY/ORGANIZATION/
   ORGANIZATIONAL_UNIT,但 `COUNTRY=US` 是 hardcode(非 env)。改成 TW 需要
   overlay patch `cert-metadata.sh`;對內部用途屬 cosmetic,暫不處理。

## 工作項目

- [x] `AEGIS/overlay/.env.example`——涵蓋 entrypoint `check_env_var` 要求的全部
      必填:`POSTGRES_DB/USER/PASSWORD`、`POSTGRES_URL`(`takdb:5432`)、
      `CA_NAME/CA_PASS`、`STATE/CITY/ORGANIZATION/ORGANIZATIONAL_UNIT`、
      `TAKSERVER_CERT_PASS`、`ADMIN_CERT_NAME/ADMIN_CERT_PASS`。secret 留空標
      REQUIRED;非機密欄位給 Dragonfly 預設值。
- [x] DB 對接慣例文件化(`overlay/README.md`):compose 服務名 `takdb`、
      k8s `takdb` Service(ExternalName 或 headless+Endpoints)。
- [x] 憑證持久化策略文件化:`/opt/tak/data` → volume(compose)/ PVC(k8s);
      或預先產憑證掛 Secret。⚠️ 自動產策略下憑證必須落 PVC,否則 pod 重啟重產
      CA 會讓已 enroll client 失效。
- [x] clientAuth 釐清:用 stock config,不改。

## 產出物

- `AEGIS/overlay/.env.example`(完整 env 模板)。
- `AEGIS/overlay/README.md`(DB 慣例 + 憑證持久化 + mTLS 存取)。
- **無 entrypoint patch、無 image 改動**(這是相對原計劃的簡化)。

## 結束 milestone(M2)

同一個 stock image,設定 `POSTGRES_URL` 並讓 DB 以 `takdb:5432` 可達,即可分別接
本機 postgis 容器或外部 DB;CoreConfig 與 schema-init 指向同一 DB;憑證 bootstrap
與持久化路徑(volume/PVC 或 Secret)已確定並文件化。**真正的 end-to-end 驗證在
Phase 3(compose)與 Phase 5(k8s)。**

## 地雷 / 注意事項

- 外部 DB 必須 **PostgreSQL 15 + PostGIS 3**,且 **PostGIS extension 要 enable**
  ——managed 服務(Cloud SQL/RDS/Azure)支援但要手動開。
- `POSTGRES_URL` 在 coreConfigEnvHelper 標為「非必填」,但不設會留 `127.0.0.1`
  預設而連不到——實務上**視為必填**。
- 別把 `TAKIgniteConfig` 的 cluster 設定打開——我們是單節點,維持預設。
- entrypoint 內多個 `sleep` 是脆弱時序假設;k8s 用 readiness probe 取代
  (Phase 5),compose 可暫時容忍。
