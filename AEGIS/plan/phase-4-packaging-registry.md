# Phase 4 — 打包與 registry

**目標:** 產出兩種可散布形式:① 官方式的 turnkey **zip**(給想用 compose 的人,
不需原始碼);② 把單一 **image push 到 registry**(給 k8s 拉)。

## 背景

Phase 1 產出單一 image 與 `dist/staging/`;Phase 2–3 產出 AEGIS overlay
(`.env.example`、patch 過的 entrypoint、`docker-compose.yml`、`README.md`)。
打包把它們合併成 drop-in 散布物,並把 image 推上 registry 讓 k8s(Phase 5)使用。

## 工作項目

- [ ] `AEGIS/scripts/package.sh`:
  - [ ] 依賴 `dist/staging/`(缺就先跑 `build.sh`)。
  - [ ] **zip 散布物**:複製 `dist/staging/{tak,docker}`,疊上 overlay
        (`.env.example`、patch 過的 `docker_entrypoint.sh`、`docker-compose.yml`、
        `README.md`),`chmod +x` shell script,打包成
        `AEGIS/dist/takserver-aegis-docker-<ver>.zip` + SHA-256 + `MANIFEST`
        (版本、git rev、build 時間)。
  - [ ] **registry push**(可選參數):`docker tag` 成
        `<registry>/takserver-aegis:<ver>` 與 `:latest` 並 `docker push`;
        印出 image digest 供 k8s manifest pin。
  - [ ] 防呆:絕不打包真正的 `.env`、`secret.yaml` 或任何 `certs/files/` 內容。
- [ ] 驗證 zip 佈局(top-level `docker-compose.yml`、`.env.example`、`README.md`,
      加 `tak/`、`docker/`),且解壓到別處能獨立部署。

## 產出物

- `AEGIS/scripts/package.sh`。
- `AEGIS/dist/takserver-aegis-docker-<ver>.zip` + checksum + `MANIFEST`。
- registry 上的 `takserver-aegis:<ver>`(若啟用 push)+ digest。

## 結束 milestone(M4)

官方式 zip 可在乾淨 Docker host 獨立部署;單一 image 已打 tag 並能 push 到
registry(供 k8s 拉),digest 已記錄。

## 地雷 / 注意事項

- **機密衛生:** 只出貨 `.env.example` / `secret.example.yaml`;在 `package.sh`
  加明確防呆。
- **image 多平台:** k8s 節點若混 arch 要注意——TAK 僅 x86-64,push 時鎖 amd64。
- 版本字串單一來源自 `tak/version.txt`,讓 zip 名、image tag、`MANIFEST`、
  `.env.example` 的 `TAK_VERSION` 不漂移。
- k8s 用 digest pin(`@sha256:...`)比用 `:latest` 穩,避免 rollout 抓到舊 cache。
