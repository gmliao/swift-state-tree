# 設計文件落差對照（供後續討論）

目前各設計文件間出現的舊版概念或語義落差，整理如下，方便之後逐點決策：

- **`@Sync` 政策集合不同**：`DESIGN_CORE.md:65-118` 只列出 `.serverOnly / .broadcast / .perPlayer / .masked / .custom`，且一個欄位只有單一 `@Sync`；`APP_APPLICATION.md:90-186`、`APP_APPLICATION.md:360-386` 則使用 `.cache / .cloud / .local / .memory` 並在同一欄位疊加多個 `@Sync`。需決定：這些 client/cache 類 policy 是否仍要納入核心 DSL？若要疊加，語義（執行順序、衝突解決）要另行定義。
- **`@Sync` 套用範圍**：核心文件的範例都是 stored property，側重伺服器權威樹；`APP_APPLICATION.md:169-185` 則在計算屬性與純 UI 狀態上使用 `.memory`。需釐清是否允許對 computed property / UI-only 狀態使用 `@Sync`，或應限制在權威狀態欄位。
- **權威來源定位**：`DESIGN_CORE.md:14-35` 強調伺服器持有唯一 StateTree、UI 計算交給客戶端；但 `APP_APPLICATION.md:87-205`、`APP_APPLICATION.md:408-438` 展示的是「客戶端本地 StateTree + 雲端/本地快取」模式。需決定是否要分拆「伺服器版 StateTree DSL」與「客戶端資料同步 DSL」，或更新文件避免兩種定位混用。
- **服務/雲端同步語義**：`APP_APPLICATION.md:92-134`、`APP_APPLICATION.md:156-186` 用 `.cloud(service:)` / `.cloud(endpoint:)` 描述對外服務，同時透過 `ctx.services.*` 呼叫 HTTP。核心與通信文件 (`DESIGN_COMMUNICATION.md`, `DESIGN_TRANSPORT.md`) 則以 WebSocket 同步為主。需確認：`.cloud` 是要走 Transport 推播、還是代表另一條 HTTP 資料管道？兩者是否共存、如何協調。
