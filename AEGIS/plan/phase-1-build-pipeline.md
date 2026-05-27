# Phase 1 — 可重現的單一 image build

**目標:** 從乾淨的 checkout,一行指令 build 出已驗證的 TAK Server **單一
self-contained image**(基於 gradle `full` flavor),供 compose 與 k8s 共用。

> **實作狀態(2026-05-27):** `AEGIS/scripts/build.sh` 與 GitHub Actions
> workflow `.github/workflows/aegis-build.yml` 已完成。本機是 arm64 無法實跑
> gradle build——實際 build 在 CI(x86-64 runner)進行,push 到
> **GAR `asia-east1-docker.pkg.dev/aegis-product/services/aegis-takserver`**
> (沿用 aegis frontend 的 GAR + WIF pattern)。本機已驗證:`bash -n` 語法、
> VERSION 讀取、x86-64 arch guard 正確擋下。**待 CI 首跑驗證 gradle+docker
> 全流程**(可能需補 build 工具鏈,如 node;首跑會揭露)。

## 背景

gradle task `buildFullDocker`(`src/takserver-package/build.gradle:386`,底層是
`src/takserver-package/utils/utils.gradle:169` 的 `constructFullDockerZip`)
產出 `takserver-docker-full-<ver>.zip`,內含:

- `tak/` — `takserver.war`、各 JVM 啟動 script、`certs/` 工具、`db-utils/`
  (`SchemaManager.jar`)、`docker_entrypoint.sh`、`coreConfigEnvHelper.py`、
  `CoreConfig.example.xml`、`TAKIgniteConfig.example.xml`。
- `docker/Dockerfile.takserver` — `eclipse-temurin:17-jammy`,**`COPY tak
  /opt/tak`** 把 payload 烤進 image;entrypoint 是 `docker_entrypoint.sh`。
- `docker/EDIT_ME.env`、`docker/docker-compose.yml`、`docker/full-README.md`。

關鍵:這是**單一 image**——`tak/` 在 image 內,不靠 bind-mount。DB 不在此 image
(外部)。

## 工作項目

- [ ] 撰寫 `AEGIS/scripts/build.sh`:
  - [ ] 若不是 x86-64,或 `java -version` 不是 17,就 fail fast。
  - [ ] **版本帶入(關鍵):** 本 repo 沒有 git tag,gradle 由
        `git describe` 推導版本(`src/build.gradle:32`),會推不出
        `5.7-RELEASE-14`。`build.sh` 讀 `AEGIS/VERSION` 並顯式帶入——做法待
        Phase 1 確認:① 在 build 前對 HEAD 打一個 local tag `$(cat AEGIS/VERSION)`
        (build 完可選擇刪掉),或 ② 用 `-P` 覆寫 `takversion`/`takrelease` ext
        變數。優先用 local tag(對 gradle 既有邏輯侵入最小)。
  - [ ] 執行 `(cd src && ./gradlew clean buildFullDocker)`。
  - [ ] 解析產出的 zip(glob:
        `src/takserver-package/build/distributions/takserver-docker-full-*.zip`),
        複製到 `AEGIS/dist/` 並解壓到 `AEGIS/dist/staging/`(先清空)。
  - [ ] `docker build` 單一 image:
        `docker build -f dist/staging/docker/Dockerfile.takserver
        -t takserver-aegis:<ver> dist/staging/`(context 含 `tak/`)。
  - [ ] 同時打 `:latest` 與 `:<ver>` tag,方便後續 registry push。
- [ ] 加上驗證:
  - [ ] staging tree 含 `tak/takserver.war`、`tak/docker_entrypoint.sh`、
        `tak/coreConfigEnvHelper.py`、`tak/db-utils/SchemaManager.jar`、
        `docker/Dockerfile.takserver`。
  - [ ] 從 `tak/version.txt` 擷取版本並印出。
  - [ ] image build 成功後 `docker image inspect` 確認存在;輸出 image digest。
- [ ] 在 `AEGIS/overlay/README.md` 記錄 build 流程(前置需求、首跑約 10–15 分鐘)。

## CI(GitHub Actions → GAR)

沿用 aegis frontend(`frontend/.github/workflows/docker.yml`)的 **GAR + Workload
Identity Federation** pattern:

- `.github/workflows/aegis-build.yml`:`ubuntu-latest`(x86-64)→ checkout
  (`fetch-depth: 0`)→ JDK 17 → **WIF 認證**(`google-github-actions/auth@v2`)→
  `gcloud auth configure-docker` → 跑 `build.sh`(`REGISTRY=<GAR_LOCATION>/
  <project>/<repo>`)→ `docker push` `:<ver>`、`:<ver>-<ts>-<sha>`(traceable)、
  `:latest`。
- GAR 目標:`asia-east1-docker.pkg.dev/aegis-product/services/aegis-takserver`。
- **與 frontend 的刻意差異**:TAK 僅 amd64——拿掉 multi-arch matrix 與 manifest
  merge;image 由 `build.sh`(gradle 產 Dockerfile)build,不用
  `docker/build-push-action`。
- 觸發:push 到 `AEGIS`(限 `AEGIS/**`、`src/**`、workflow 自身)或
  `workflow_dispatch`。
- ⚠️ **WIF 授權前置**:WIF provider 的 attribute condition / SA 的 IAM binding
  必須允許 `DragonflyUAS/Server` 這個 repo 來 impersonate
  `github-actions-pusher@aegis-product`(frontend repo 已授權,但本 repo 可能要
  GCP admin 補上)。否則 auth step 會失敗。

## 產出物

- `AEGIS/scripts/build.sh`(冪等、可重複執行;env 參數化 `IMAGE_NAME`/`REGISTRY`)。
- `.github/workflows/aegis-build.yml`(CI build + push GAR,WIF 認證)。
- docker image `aegis-takserver:<ver>` + `:latest`(本機 `takserver-aegis:<ver>`)/
  GAR `.../services/aegis-takserver:<ver>`(CI)。
- staging 產物 + zip 在 `AEGIS/dist/`。

## 結束 milestone(M1)

從乾淨的 tree 執行 `AEGIS/scripts/build.sh`,產出已驗證的單一 image
`takserver-aegis:<ver>`;任何預期檔案缺失或 image build 失敗就大聲報錯。

## 地雷 / 注意事項

- 用 `buildFullDocker`,**不是** `buildDocker`——後者是早期放棄的多容器方向。
- 第一次跑 gradle 會下載大量 plugin/artifact——別把漫長首跑當卡死。
- image 內已含 `tak/`;不要再設計 bind-mount(那是舊模型)。
- 不要 commit staged 產物、zip 或 image——`dist/` 已 git-ignore。
