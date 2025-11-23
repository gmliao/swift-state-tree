# 設計文件落差對照（供後續討論）

目前各設計文件間出現的舊版概念或語義落差，整理如下，方便之後逐點決策：

- **`@Sync` 政策集合不同**：`DESIGN_CORE.md:65-118` 只列 `.serverOnly / .broadcast / .perPlayer / .masked / .custom`；`APP_APPLICATION.md` 仍以概念方式提到 `.cache/.cloud/.local/.memory`（現已標示未落地）。需決定：這些 client/cache 類 policy 是否要正式納入核心 DSL？若要疊加，語義與衝突解決需另定。
- **`@Sync` 套用範圍**：核心文件示例皆為 stored property（伺服器權威樹）。`APP_APPLICATION.md` 的概念段落仍描述在 UI/計算屬性上用 `.memory`。需釐清是否允許 `@Sync` 作用於 computed/UI-only，或應限制在權威狀態欄位。
- **權威來源定位**：`DESIGN_CORE.md:14-35` 強調「伺服器唯一 StateTree、UI 計算由客戶端」。`APP_APPLICATION.md` 現已標註為「App 端裁切快取的概念草案」，仍描述本地 StateTree 思路。需決定是否分拆「伺服器版 DSL」與「客戶端同步 DSL」，或調整描述避免雙重定位。
- **服務/雲端同步語義**：`APP_APPLICATION.md` 以概念方式提 `.cloud(service:/endpoint:)` 並搭配 `ctx.services.*`（HTTP/服務呼叫）；核心通訊文件 (`DESIGN_COMMUNICATION.md`, `DESIGN_TRANSPORT.md`) 聚焦 WebSocket 推播。需確認 `.cloud` 要走 Transport 還是另開 HTTP 管道，及如何協同。
