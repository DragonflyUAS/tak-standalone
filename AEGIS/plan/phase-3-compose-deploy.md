# Phase 3 — 本機 compose 部署(官方式 turnkey)

**目標:** 用 Phase 1 的單一 image,提供本機 `docker-compose` 部署:單一 TAK
容器 + 一個 postgis 容器(代表「外部 DB」,可抽換),達成「編 `.env` →
`compose up` → mTLS 登入 web UI」的 turnkey 體驗。這就是原本要的「像官方
tak.gov 那樣的 docker-compose 包」。

## 背景

full flavor 自帶一份 `docker/docker-compose.yml`(單一 `takserver` 服務
`build: .` + `takdb` 用 stock `postgis/postgis:15-3.3`)。我們以它為基礎做 AEGIS
版:改用已 build 好的 `takserver-aegis:<ver>` image、統一 `.env`、把 DB 設成可
輕鬆指向外部 endpoint。本機方便起見仍附一個 postgis 容器。

## 工作項目

- [ ] `AEGIS/overlay/docker-compose.yml`:
  - [ ] `takserver` 服務用 `image: takserver-aegis:<ver>`(而非 `build:`),
        `env_file: .env`,publish **8089/8443/8444/8446/9000/9001**,
        憑證/log volume,`restart: unless-stopped`。
  - [ ] `takdb` 服務用 stock `postgis/postgis:15-3.3`,`env_file: .env`,
        named volume 存 `/var/lib/postgresql/data`,`pg_isready` healthcheck。
  - [ ] `POSTGRES_URL` 預設指向 `takdb`;文件說明改成外部 DB 時把 `takdb` 服務
        拿掉、`POSTGRES_URL` 指向外部 host 即可。
  - [ ] 不要有過時的 top-level `version:` key。
- [ ] 部署流程(寫進 `AEGIS/overlay/README.md`):
  - [ ] `cp .env.example .env` → 填值。
  - [ ] `docker compose up -d`(首次 entrypoint 自動產憑證 + 初始化 schema +
        註冊 admin)。
  - [ ] 取得 `admin.p12`(從 volume 複製到 host),匯入瀏覽器 → mTLS 登入
        `https://localhost:8443/`。
- [ ] 健康檢查指令清單(`compose ps` / `logs -f` / `restart` / `down -v`)。

## 產出物

- `AEGIS/overlay/docker-compose.yml`(用單一 image + postgis 容器)。
- `AEGIS/overlay/README.md` 的部署小節。

## 結束 milestone(M3)

在本機 `docker compose up -d` 後,兩個容器 Up/healthy,entrypoint 自動完成憑證與
schema 初始化,operator 能用 `admin.p12` 透過 mTLS 登入 web UI。

## 地雷 / 注意事項

- **記憶體:** 單容器內多個 JVM + postgis,給 Docker 至少 ~8 GB,否則 OOM 重啟。
- **首次啟動較久:** entrypoint 會產憑證 + 等 DB + 初始化 schema + 啟動 4 個 JVM,
  約 1–2 分鐘;看 `logs -f` 等到 `Started TakServerApplication` 與 `ADMIN USER
  ADDED`。
- **mTLS 登入:** `admin.p12` 要匯入瀏覽器**個人**存放區、**重啟瀏覽器**、用
  `localhost` 不要用容器 IP。
- 這一步驗證的是 image 本身可用;k8s 部署在 Phase 5,共用同一 image。
