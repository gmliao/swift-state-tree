[English](ai-agent-architecture-observations.md) | [中文版](ai-agent-architecture-observations.zh-TW.md)

 # AI Agent 架構觀察

## 關於本文件

本文件為作者主導的深度研究整理，AI 僅作為研究加速與協作工具，用於文獻探索、反例發想與結構整理。所有結論、架構判斷與取捨由作者負責，本文件屬工程研究筆記，非學術證明。

 本文件整理 **個人開發觀察**，用來描述在 AI 輔助開發情境下採用 ECS-inspired system-based architecture 的經驗。內容**不是嚴謹研究結論**，僅作為傾向或假設的整理。

 ## 封裝與邊界（觀察、非結論）

 封裝與存取控制提供程式正確性邊界，對人類與 AI 都有價值。本專案也透過 handler、request-scoped context、actor 序列化等架構邊界來降低誤用風險，但這**不代表不需要封裝**；必要時仍應以型別與存取控制強化約束。

 ## 相關研究（作為背景）

 **1. 統計模式 vs 邏輯推理**

 - **"A Peek into Token Bias: Large Language Models Are Not Yet Genuine Reasoners"** (Jiang et al., 2024)
   - 指出 LLM 的「推理」可能受 token 偏見與表面模式影響
   - https://arxiv.org/abs/2406.11050

 - **"LLMs and the Logical Space of Reasons"** (Minds & Machines, 2025)
   - 從哲學視角討論 LLM 與推論規範（人類邏輯規則）的關係
   - https://link.springer.com/article/10.1007/s11023-025-09751-y

 **2. LLM 對設計模式的理解**

 - **"Do Code LLMs Understand Design Patterns?"** (2025)
   - 報告 LLM 對設計模式的理解與一致性仍有波動，並提出可觀察的限制
   - https://arxiv.org/abs/2501.04835

 **3. 代碼生成中的推理模式**

 - **"A Study on Thinking Patterns of Large Reasoning Models in Code Generation"** (Halim et al., 2025)
   - 建立推理動作分類法，討論推理風格與正確性之間的關聯
   - https://arxiv.org/abs/2509.13758

 **4. 認知負擔與代碼可讀性**

 - **"Measuring the cognitive load of software developers"** (2021)
   - 探討代碼複雜度、語言熟悉度、呈現方式對認知負擔的影響
   - https://www.sciencedirect.com/science/article/abs/pii/S095058492100046X

 - **"LLM-Based Test-Driven Interactive Code Generation"** (2024)
   - 報告測試驅動的 AI 代碼生成流程可能降低認知負擔
   - https://arxiv.org/abs/2404.10100

 ## 研究缺口

 目前**沒有論文直接研究**以下主題：

 - AI 輔助開發中，Pure Function 拆解對人類 vs AI 的認知負擔差異
 - 統計模式學習在代碼理解中對人類心智負擔的影響
 - 為 AI 優化的代碼設計（如 ECS-inspired system-based architecture）對人類可讀性的影響

 ## 我們的觀察（偏向性的描述）

 基於實際開發經驗：

 - AI 可能通過統計模式學習來**對齊**代碼架構約束
 - 函數簽名 + 代碼模式**可能**有助於對齊，但仍需封裝/測試作為防線
 - 這種設計在 AI 輔助開發場景下**可能更有效率**

 以上皆屬**觀察**，尚未有嚴謹的學術研究驗證。

 ## 為何驗證困難

 理論上可用對比實驗驗證，例如：

 - 使用同一個 LLM 模型
 - 分別使用 systems (ECS-inspired) 與傳統 OOP 設計
 - 比較開發效率（代碼生成速度、正確率、修改次數等）

 但實務上存在大量難以控制的變數：

 - **提示詞差異**：不同設計模式的提示詞難以完全等價
 - **任務複雜度**：不同任務對不同設計模式的適應性不同
 - **模型版本**：不同版本的模型表現差異很大
 - **開發者經驗**：人類開發者對不同模式的熟悉度不同
 - **代碼庫上下文**：現有代碼庫的風格會影響 AI 的生成結果
 - **測試標準**：如何客觀衡量「開發效率」和「代碼質量」

 因此，這些觀察目前**難以通過嚴謹的實驗驗證**，更多是基於實際開發中的主觀感受和經驗總結。
