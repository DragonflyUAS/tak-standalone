# Phase 0 — Scaffold 與決策

**目標:** 建立 `AEGIS/` 目錄結構,並鎖定後續所有工作所依賴的決策,讓接下來的
phase 有穩定的落腳處與清楚的契約。

## 背景

這是 TAK Server repo 的 AEGIS branch,會週期性 merge upstream release tag
(例如 `upstream/5.7-RELEASE-14`)。我們建立的所有東西都必須放在 `AEGIS/` 內,
並避免動到 `src/`,這樣那些 merge 才不會衝突。Phase 0 只產出結構與文件——還沒有
任何 build 邏輯。

## 工作項目

- [ ] 建立目錄骨架:`AEGIS/overlay/`、`AEGIS/k8s/`、`AEGIS/scripts/`、
      `AEGIS/dist/`(需要的地方放 `.gitkeep`)。
- [ ] 新增 `AEGIS/.gitignore`,忽略 `dist/`、真正的 `.env`、`k8s/secret.yaml`,
      以及任何產生的憑證材料(`*.p12`、`*.pem`、`*.jks`)。
- [ ] Pin 目標版本。從 `src/takserver-package` 的 gradle props / `VERSION.md`
      確認目前版本字串(預期 `5.7-RELEASE-14`),記錄在計劃 README 的決策表。
- [ ] 記錄架構決策(已在 `plan/README.md` 草擬):單一 image(`full` flavor)、
      外部 DB、env 驅動設定/憑證、k8s 為平台目標、overlay-not-fork。
- [ ] 在 `AEGIS/overlay/README.md` 雛形中記錄前置需求:x86-64 CPU、JDK 17、
      Docker、外部 PostgreSQL 15 + PostGIS 3、單 pod 約 4–8 GB RAM。

## 產出物

- 已 commit 的 `AEGIS/` 骨架。
- `AEGIS/.gitignore`。
- 在 `plan/README.md` 中定稿的決策表。

## 結束 milestone(M0)

`AEGIS/` 骨架已存在並 commit;架構決策與 pin 的版本都已寫下;`src/` 內未被修改。

## 地雷 / 注意事項

- 這裡**不要**開始寫 `docker-compose.yml`、`k8s/*.yaml` 或 entrypoint patch
  ——那些屬於後續 phase,且需要先檢視實際的 `full` 產物 tree。
- 從第一個 commit 就把 `dist/`、真正的 `.env`、`secret.yaml` 排除在 git 之外。
