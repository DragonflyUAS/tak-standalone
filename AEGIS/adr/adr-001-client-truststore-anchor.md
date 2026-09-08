# ADR-001: client truststore 的信任錨放「中繼 ＋ root」，並在 image 的 entrypoint 補上

Status: Accepted（2026-09）
來源：[AEG-467](https://visionone.atlassian.net/browse/AEG-467)（治本），
現象與暫時修法：[AEG-459](https://visionone.atlassian.net/browse/AEG-459)。
症狀、實測與死路的完整紀錄：`aegis-backend` 的 `docs/tak-server-api/README.md`〈坑〉14。

## Context

TAK server 首啟時自建兩層 CA，但**信任錨只設在上面那一層**，而裝置憑證是下面那一層簽的。

順序是問題的根源。`docker_entrypoint.sh` 依序跑四段「檔案不在才做」的條件式：

```
1. makeRootCa.sh            ca.pem = root
                            truststore-root.jks ← import ca.pem     ← 此刻只有 root
2. yes | makeCert.sh ca intermediate
                            intermediate.pem = 中繼 + root（makeCert.sh:119 把 ca.pem 接上去）
                            ca.pem ← 被 intermediate.pem 覆蓋（makeCert.sh:143，`yes |` 一律回 y）
3. makeCert.sh server takserver
4. makeCert.sh client admin
```

`truststore-root.jks` 是第 1 步用當時的 `ca.pem` 建的快照（`makeRootCa.sh:60`，`keytool -list`
實測 1 entry）。第 2 步把 `ca.pem` 換成中繼 chain，**但沒有任何一步回頭更新 truststore**。

而 CoreConfig 的 `certificateSigning` 指向 `intermediate-signing.jks` —— 裝置憑證由中繼簽發。
於是驗證一張 leaf 需要建出 `leaf → 中繼 → root` 的路徑，而 server 手上缺中繼那一環。

### 為什麼這個落差長期看不出來

缺的那一環**可以由 client 代勞**：client 若在 TLS Certificate 訊息裡主動附上中繼，路徑就補齊了。

我們自己的 Go client（`takgateway.KeyStore.TLSCertificate()`）就是這麼做的（〈坑〉10 講的正是
「對 8089 出示 client 憑證要送 leaf＋中繼」）。所以**開發、CI、整合測試全部是綠的**。

真機不附。Skydio X10 實測在 TLS Certificate 訊息只送 leaf 一張（以真的 server 憑證終結 TLS、
讀 `get_unverified_chain()` 量測）。交握死在 `SSLHandshakeException` ／
`Certificate error: peer not verified`。

**症狀完全指不到原因**：遙控器只顯示 `UNREACHABLE`，看起來就是網路不通；而封包在 TLS 層就被
擋掉，TAK 一行 log 都不會寫。「憑證被拒」與「網路不通」在現場無法區分 —— 這是排查最耗時的部分，
不是修它本身。

### 這是我們的配置異常，不是 TAK 的設計

參照組：翔隆自架那台（`60.250.96.141:8090`）沒有這個問題，因為它的錨設在中繼。從外面一次不帶
client 憑證的交握就讀得到（`CertificateRequest` 的 acceptable-CA 清單，唯讀、不需憑據）：

```
Acceptable client certificate CA names
C=US, ST=TSMC, L=TSMC, O=TSMC, OU=NA, CN=intermediate
```

同樣兩層 CA、同樣的 X10、同樣只送 leaf，唯一差別就是錨在哪一層。**本堆疊留在 stock 預設的
root 才是異類。**

## Decision 1：錨放「中繼 ＋ root」兩張，不是只放中繼

把中繼匯入 `truststore-root.jks`，保留原本的 root。

- **不放寬信任。** root 當錨時「leaf＋中繼」本來就驗得過 —— 被接受的身分集合完全沒變，差別只是
  server 不再要求對方幫它補中間那一環。這句話 review 時一定會被問，寫在這裡免得每次重新推導。
- **兩張而不是只放中繼，是保守選擇。** TAK 各 input／connector 未必用同一套 TLS 引擎：8089 的
  錯誤來自 `ReferenceCountedOpenSslEngine`（netty-tcnative），而 8443／8446 的 log 是
  `https-jsse-nio-*`（JSSE）。兩張在兩種引擎下都成立。**不是因為只放中繼不可行** —— 上面那台
  參照組就是只放中繼而且服役中。

## Decision 2：落點是 `AEGIS/scripts/build.sh` 的 build-time patch，不改 `src/`

`src/` 與 upstream 保持一字不差，修正在 build 時以 `sed` baked 進 image —— 這是這個 fork 既有的
慣例（已有三個同性質的 patch：logs symlink 冪等、certmod 重試、CoreConfig 優先序），
`AEGIS/plan/README.md` 的架構決策表也把「絕不 fork `src/`」列為鎖定項，理由是讓 upstream release
merge 不衝突。

考慮過但否決的兩個落點：

- **`makeRootCa.sh:60`** —— 它執行的當下中繼還不存在，改它沒有意義。
- **`seed-coreconfig.py`（aegis 側）** —— `tak-seed` 跑在 takserver 之前，同樣還沒有中繼可匯入。

### 為什麼一定要進 image，而不是留在 `make tak-up`

AEG-459 的暫時修法住在 `aegis-backend` 的 `tak/Makefile`（`ensure-client-truststore`）。
場域交付走 bundle ＋ `aegisctl`：

- bundle 的產出清單不含 Makefile
- 交付用的 `.ova` 沒有裝 `make`
- `aegisctl` 起服務用的是裸 `docker compose`

所以 TAK 一上場域，那個修復必然失效，而失效是靜默的 —— 症狀就是上面那個 UNREACHABLE。
進 entrypoint 之後：**首啟即正確、不必重啟、也涵蓋不經 make 的裸 `docker compose up`。**

## Decision 3：插在 `chmod -R 777` 之前，而且在四段 if/else 之外

插入點是 entrypoint 裡唯一的 `chmod -R 777 ${TR}/data/` —— 四段憑證產生都跑完、
`coreConfigEnvHelper.py` 還沒跑。選它是因為它在整個檔案裡唯一，當 `sed` 錨點不會誤中。

**不放進「產生中繼」那個 if 裡面**，即使那樣看起來更貼近事件。理由是自癒：那段有
`if [[ ! -f intermediate-signing.jks ]]` 守著，只有全新 volume 會進去。放外面 ＋ 用
`keytool -list -alias` 做冪等判斷，既有的 dev／CI volume 下次重啟就自動補上。

匯入失敗時**故意讓它炸**（`set -e` 之下不加 `|| true`）：這條路徑要是靜默失敗，就重現了本 ADR
要消滅的那個 bug，而且一樣不留痕跡。

實作細節：`intermediate.pem` 其實是「中繼＋root」兩張的 chain，但 `keytool -importcert` 只會
匯入第一張 —— 也就是中繼，正好是要的。

## 兩條踩過的死路

1. **把 `truststoreFile` 指向 `truststore-intermediate.p12`** —— 沒用。openssl 讀它有 2 張憑證，
   但 Java 讀是 `0 entries`（那些憑證沒有 Java 認得的 `trustedCertEntry` alias），對 TAK 而言
   等於一個完全無效的 truststore。
2. **寫進 `seed-coreconfig.py`** —— 沒用，見 Decision 2。

## 明確不做

- **`fed-truststore.jks`（`makeRootCa.sh:61`）有同型的缺口** —— 它是從 root-only 的
  `truststore-root.jks` 拷貝來的。AEGIS 沒有使用 federation，所以不補也不會壞；但哪天開了
  federation，會踩到一模一樣的坑。**這是知情的延後，不是遺漏。**
- **移除 aegis 側的 `ensure-client-truststore`** —— 等場域用新 image 驗過再拿掉。兩者並存不衝突：
  Makefile 那支也是冪等的，image 修好之後它就是 no-op。

## 後續維護

這個 patch 與其他三個一樣，**每次 TAK upstream 升版都要重新驗證**（`AEGIS/plan/phase-6`
的 upstream-sync）。會讓它失效的上游改動有兩類：

- `docker_entrypoint.sh` 拿掉或改寫 `chmod -R 777 ${TR}/data/` → `sed` 錨點失配，patch 靜默不套用
- upstream 自己修好了這個落差 → patch 的 `keytool -list` 判斷會命中、直接跳過，無害

第一類是危險的那個。守法是 build 之後對產出的 entrypoint 斷言 `aegis: anchor the client
truststore` 這行存在 —— 目前靠 review，值得在 CI 補一道。
