# Phase 5 — k8s 部署(平台目標)

**目標:** 把單一 TAK image 當成平台的一個元件部署到 k8s:一個 TAK Deployment +
外部 DB,設定走 ConfigMap、機密走 Secret、憑證持久走 PVC(或預先產的 Secret)、
schema 初始化走 Job。**不採用 cluster 架構。**

## 背景

我們刻意不用 repo 內 `takserver-cluster` 那套 Ignite StatefulSet(Helm)架構——
那是 production cluster 用的。我們要的是輕量單節點:同一個 Phase 1 的 image,在
k8s 裡跑單一 pod,接外部 DB。`src/takserver-cluster/deployments/helm/templates/`
(尤其 `post-install-hook-postgres.yaml`)可當「schema-init 用 Job/hook」的參考,
但我們手寫精簡 manifests,不引入整套 chart。

## 工作項目

- [ ] `AEGIS/k8s/configmap.yaml` — 非機密設定(`POSTGRES_URL`、`POSTGRES_DB/USER`、
      `CA_NAME`、cert metadata、heap、port)。
- [ ] `AEGIS/k8s/secret.example.yaml` — `POSTGRES_PASSWORD`、`CA_PASS`、
      `TAKSERVER_CERT_PASS`、`ADMIN_CERT_PASS`(真正的 `secret.yaml` git-ignore)。
- [ ] `AEGIS/k8s/schema-init-job.yaml` — 用同一 image,override entrypoint 只跑
      `SchemaManager.jar upgrade`(指向外部 DB),作為部署前的一次性 Job;
      Deployment 可用 initContainer 等它完成,或用 Helm/argo hook 排序。
- [ ] `AEGIS/k8s/deployment.yaml` — 單一 TAK pod:
  - [ ] `image` 用 Phase 4 的 registry digest;`envFrom` ConfigMap + Secret。
  - [ ] **PVC** 掛 `/opt/tak/data`(憑證 + log 持久,跨 pod 重啟存活);
        或改掛預先產的憑證 Secret(二選一,見 Phase 2 策略)。
  - [ ] **readiness/liveness probe**:用 `tak/` 內的 `api-readiness.sh` /
        探 8443,取代 entrypoint 的固定 `sleep`。
  - [ ] resource requests/limits:多 JVM,memory 要抓夠(對齊 heap 變數)。
  - [ ] 單節點:`replicas: 1`、`strategy: Recreate`(避免兩個 pod 同寫憑證/搶
        DB lock)。
- [ ] `AEGIS/k8s/service.yaml` — 暴露 8089(ATAK)、8443(web UI)、9000/9001
      (federation);依平台需求選 ClusterIP / LoadBalancer / Ingress(8443 是
      mTLS,Ingress 要 TLS passthrough,不能在 LB 終結 TLS)。
- [ ] **DB Service 命名 `takdb`(只要一個)** 指向外部 DB(ExternalName 或
      headless+Endpoints)。⚠️ 但必須搭配下面的 CoreConfig 修正,否則 JVM 會去連
      image 內建的 `tak-database` + 空密碼(見地雷)。
- [ ] **CoreConfig 修正(compose 實測,k8s 也必須做)**:TAK JVM 從 CWD 載入
      `/opt/tak/CoreConfig.xml`,但 image 那份是 `tak-database` + 空密碼;
      `coreConfigEnvHelper.py` 只修 `data/CoreConfig.xml`。pod 的 command wrapper
      要在 helper 後把 `data/CoreConfig.xml` 覆蓋到 `/opt/tak/CoreConfig.xml`
      (同 compose 的 wrapper),JVM 才會用 `takdb` + 正確密碼。
- [ ] `AEGIS/k8s/README.md` — apply 順序、外部 DB 前置(PostGIS extension)、
      取 `admin.p12`、mTLS 存取。

## 產出物

- `AEGIS/k8s/`:`configmap.yaml`、`secret.example.yaml`、`schema-init-job.yaml`、
  `deployment.yaml`、`service.yaml`、`README.md`。

## 結束 milestone(M5)

在 k8s 上:schema-init Job 對外部 DB 成功 upgrade;單一 TAK pod 達到 Ready
(probe 通過);可透過 Service/Ingress 用 mTLS 連到 8443,且 8089 可接 client。

## 地雷 / 注意事項

- **8443 是 mTLS** — Ingress 必須 **TLS passthrough**(SSL passthrough),不能在
  Ingress/LB 終結 TLS,否則 client cert 驗證會壞。
- **單一 instance** — `replicas: 1` + `Recreate`;這是「不走 cluster」的必然
  結果,別誤開多副本。
- **憑證持久** — 若用「entrypoint 首次自動產」策略,憑證一定要落在 PVC,否則 pod
  重啟會重產、把已 enroll 的 client 全部失效。
- **外部 DB 連線** — Secret 內 DB 密碼;確認 NetworkPolicy / SG 允許 pod 連到 DB。
- **時序** — 用 probe 與 Job 排序,別依賴 entrypoint 的 `sleep`。
- **三個 stock-flavor 修正已 baked 進 image**(`AEGIS/scripts/build.sh` 在 docker
  build 前 patch):logs symlink 冪等、certmod retry-until-ready、CoreConfig 覆蓋
  (修空密碼/錯 host)。**pod 不需要 command wrapper**——pure `image + env + volume`
  manifests 即可,GitOps 友善。⚠️ TAK upstream 升版時要重驗 patch(Phase 6
  upstream-sync 已列為回歸點)。
