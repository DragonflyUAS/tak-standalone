# AEGIS TAK Server 部署套件 — 計劃

一套自維護、可重現的 TAK Server 部署套件,放在 `AEGIS` branch 的 `AEGIS/`
目錄下。把 TAK Server build 成**單一 self-contained image**,搭配**外部資料庫**,
讓它能在本機 `docker-compose` 起來,也能直接當成一個元件部署到平台的 **k8s** 上。

## 定位:TAK 是 infra 組件,不是產品

Dragonfly 的真正產品是上層平台;無人機目前只用 TAK(CoT)協定把資訊打出來,所以
TAK Server 是**資料進系統的 ingestion hub**。平台會用 k8s 部署,而 TAK 只是其中
一個元件——因此**刻意不採用** TAK 的 cluster 架構(那套 Apache Ignite
StatefulSet),改用「單一 image + 外部 DB」的單節點模型,接受無 HA / 不可水平
擴展的 tradeoff。需要擴展是「撞到再說」的問題。

## 為什麼用 `full` flavor(單一 image)

gradle build 提供兩種 docker flavor:

- `./gradlew buildDocker` → `takserver-docker-<ver>.zip` — Dockerfile + `tak/`
  payload,需要 bind-mount,多容器。**(早期方向,已放棄)**
- `./gradlew buildFullDocker` → `takserver-docker-full-<ver>.zip` — **我們採用這個**。
  它的 `Dockerfile.takserver` 用 `COPY tak /opt/tak` 把 `tak/` **烤進單一 image**,
  `docker_entrypoint.sh` 在一個容器內跑 config/messaging/api/plugin-manager 全部
  JVM,並用 env 自動產 CA/憑證、注入 CoreConfig、初始化 DB schema。

這個單一 image 在 compose 和 k8s 都能用——本機 compose 配一個 postgis 容器,
k8s 配外部/managed DB,**image 完全相同**。

## 架構決策(已鎖定)

| 決策 | 選擇 | 理由 |
|---|---|---|
| Image 模型 | **單一 self-contained image**(基於 gradle `full` flavor,`COPY tak`) | compose 與 k8s 共用同一 image;最適合「TAK 當一個 k8s 元件」 |
| 服務拓樸 | 單一容器內跑全部 TAK JVM(config/messaging/api/pm) | 單節點足夠;不採 cluster |
| 資料庫 | **外部 DB**(PostgreSQL 15 + PostGIS 3);compose 用 postgis 容器、k8s 用 managed/外部 DB | DB 可抽換;k8s 不自己扛 stateful DB |
| 設定 / 憑證 | **env 驅動**(`coreConfigEnvHelper.py` + entrypoint 自動產憑證);k8s 走 ConfigMap/Secret,持久資料走 PVC | 無 bind-mount;雲原生 |
| build 關係 | **完整可重現**:AEGIS script 驅動 `./gradlew clean buildFullDocker`,build image、(選)push registry | clone → 一行指令 → 相同 image |
| 原始碼擁有方式 | AEGIS 檔案放在 `AEGIS/`(overlay / k8s / scripts);絕不 fork `src/` | 讓 upstream release merge 不衝突 |
| 目標版本 | **5.7-RELEASE-14** | 已 pin;只在刻意 merge upstream tag 時升版 |

## 目標目錄佈局

```
AEGIS/
├── plan/                      # 這個計劃資料夾
├── overlay/                   # 疊加在 full 產物上的 AEGIS 檔案
│   ├── .env.example           # 含 POSTGRES_URL(外部 DB)、CA/憑證 metadata、port
│   ├── docker-compose.yml     # 本機:單一 TAK image + postgis 容器(DB 可抽換)
│   └── README.md              # 隨包出貨的部署說明
├── k8s/                       # 平台目標:k8s manifests
│   ├── deployment.yaml        # 單一 TAK Deployment
│   ├── service.yaml
│   ├── configmap.yaml         # 非機密設定
│   ├── secret.example.yaml    # DB 密碼、憑證密碼
│   ├── schema-init-job.yaml   # 對外部 DB 跑 SchemaManager
│   └── README.md
├── scripts/
│   ├── build.sh               # ./gradlew buildFullDocker → image (+ dist/staging)
│   └── package.sh             # 產官方式 zip + (選) push image 到 registry
└── dist/                      # build 產出(git-ignored)
```

## Phase 與 milestone

| Phase | 主題 | 結束 milestone |
|---|---|---|
| [0](phase-0-scaffold.md) | Scaffold 與決策 | `AEGIS/` 骨架已 commit;決策已記錄;版本已 pin |
| [1](phase-1-build-pipeline.md) | 可重現的單一 image build | 一行指令 build 出已驗證的 TAK 單一 image(`buildFullDocker`) |
| [2](phase-2-config-cert-db.md) | 設定 / 憑證 / 外部 DB 模型 | env 驅動 CoreConfig;DB endpoint 參數化;憑證 bootstrap 與持久化策略確定 |
| [3](phase-3-compose-deploy.md) | 本機 compose 部署(官方式 turnkey) | 編 `.env` → `compose up` → mTLS 登入 web UI |
| [4](phase-4-packaging-registry.md) | 打包與 registry | 產出官方式 zip;image 打 tag 並可 push 到 registry |
| [5](phase-5-k8s-deploy.md) | k8s 部署(平台目標) | 單一 TAK pod + 外部 DB 在 k8s 上跑起來,schema-init Job 通過 |
| [6](phase-6-verification-docs.md) | 驗證與文件 | compose 與 k8s 兩路 E2E 驗證;troubleshooting/ops/整合/upstream-sync 文件完成 |

## 跨階段的約束

- **僅限 x86-64** — TAK Server 無法在 arm64(Apple Silicon)build/run。
- **JDK 17** — build 與 runtime 都需要。
- **外部 DB 需求** — PostgreSQL 15 + PostGIS 3,且 PostGIS extension 要 enable;
  schema 用 `SchemaManager.jar upgrade` 初始化(k8s 上做成 Job/init container)。
- **mTLS-only** — web UI(8443)與 ATAK(8089)都要 client 憑證;憑證 bootstrap
  要嘛由 entrypoint 首次啟動自動產(寫進 PVC),要嘛預先產好掛成 Secret。
- **Upstream-merge 安全** — 新增的東西都留在 `AEGIS/`;不動 `src/`。
- **機密紀律** — 只 commit `.env.example` / `secret.example.yaml`;真正的 `.env`、
  憑證、`dist/` 都 git-ignore。

## 未來整合接縫(平台怎麼接 TAK)

平台端建議用 **federation(9000/9001)或 CoT streaming input(8089)+ Marti REST
API** 來消費 TAK 資料,**避免走 plugin**,讓平台不被 TAK 的內部與升版節奏綁死。
這條留待平台側設計時細談;此處先把 TAK 維持成乾淨、version-pinned、可抽換的元件。

## 如何使用這份計劃

依序進行各 phase;每個 phase 的「結束 milestone」是下一個 phase 的 gate。這是一份
活的計劃——範圍變動時請更新對應的 phase 文件。
