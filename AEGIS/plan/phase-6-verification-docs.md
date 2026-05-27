# Phase 6 — 驗證與文件

**目標:** 在乾淨環境證明 compose 與 k8s 兩條路都端到端能動,然後把部署、
troubleshooting、ops、平台整合、upstream-sync 寫清楚,讓套件可交接、可維護。

## 背景

build 成功不等於功能正確。唯一重要的證明是:乾淨環境能部署、operator 能透過
mTLS 登入 web UI、且無人機能在 8089 把 CoT 打進來。

## 工作項目 — 驗證

- [ ] **compose 路(乾淨 host)**:`build.sh` → `package.sh` → 解壓 zip → 編
      `.env` → `compose up -d` → 兩容器 healthy → `admin.p12` 匯入瀏覽器 → mTLS
      登入 8443 → 8089 可接 TLS。
- [ ] **k8s 路**:push image → apply ConfigMap/Secret → schema-init Job 成功 →
      TAK pod Ready → 透過 Service/Ingress mTLS 登入 8443 → 8089 可達。
- [ ] **外部 DB 切換**:把 compose 的 `takdb` 拿掉、`POSTGRES_URL` 指向獨立
      PostgreSQL 15 + PostGIS 3,驗證 schema-init 與啟動都正常。
- [ ] 反向檢查:`.env` 填錯 fail fast;pod 重啟後憑證仍在(PVC);
      `compose down -v` / 刪 PVC 能乾淨重置。

## 工作項目 — 文件

- [ ] **部署指南**(`AEGIS/overlay/README.md` + `AEGIS/k8s/README.md`):
      前置需求、編 env/secret、部署、取 `admin.p12`、瀏覽器匯入、登入。
- [ ] **Troubleshooting**:容器/pod 一直重啟(記憶體);8443「credentials
      rejected」(`admin.p12` 沒匯入/錯存放區/沒重啟瀏覽器);clientAuth=false 弄壞
      API;PostGIS extension 沒開;Ingress 沒做 TLS passthrough;憑證沒落 PVC
      導致重啟失效。
- [ ] **Ops runbook**:logs、restart、`down`/刪 PVC、heap 調整、健康檢查。
- [ ] **平台整合 note**:TAK 維持 version-pinned 可抽換元件;平台端用
      federation(9000/9001)/ CoT input(8089)/ Marti REST API 消費,**避免
      plugin**(綁死升版節奏)。k8s 觸發點看平台成熟度,不看 TAK。
- [ ] **upstream-sync**:merge 新 `upstream/5.x-RELEASE-*` 後,bump
      `TAK_VERSION` → 重跑 `build.sh`/`package.sh` → 重驗;確認 overlay 仍套用
      (尤其 entrypoint patch 與 `coreConfigEnvHelper.py` 的 env 對應沒變)。

## 產出物

- compose 與 k8s 兩路皆已驗證、可重現。
- `AEGIS/overlay/README.md`、`AEGIS/k8s/README.md`(部署 + troubleshooting + ops
  + 整合 + upstream-sync)。

## 結束 milestone(M6)

compose 與 k8s 兩種部署都在乾淨環境驗證通過(mTLS 登入 + 8089 可接);所有文件
完成。套件達到可交接狀態。

## 地雷 / 注意事項

- 在**非** build 機器的環境驗證,才抓得到對原始碼樹/local 狀態的隱性依賴。
- upstream merge 後最該回歸的是 **entrypoint patch**(DB endpoint 參數化)與
  `coreConfigEnvHelper.py` 的 env 對應——這是我們 overlay 與 `src/` 的接縫。
- 記錄 smoke-test 結果(版本、日期、環境),升版後 regression 才會明顯。
