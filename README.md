# 匯聚洋流 The Taiwan Current

一點一滴，匯成洋流。網頁藝術遊戲，網址：https://miro2874.github.io/The-Taiwan-Current/

## 檔案
- `index.html`：遊戲本體
- `data/lines.json`：內建台詞（連不到資料庫時用）
- `data/compose.json`：「成為小水滴」的預設句與填空
- `data/filter.json`：網頁端的關鍵字過濾
- `data/melody.json`：《望春風》旋律（鄧雨賢，公共領域）
- `og.png`：分享預覽圖
- `supabase/setup.sql`：資料庫建置（只需在 Supabase SQL Editor 跑一次）

## 審核台詞（Supabase → Table Editor → `lines`）
| 想做的事 | 怎麼做 |
|---|---|
| 看待審 | 篩選 `status` = `review` |
| 公開 | 把 `status` 改成 `public` |
| 下架 | 把 `status` 改成 `hidden`（或刪掉整列） |
| 精選 | 把 `status` 改成 `curated` |
| 看幾個人說過 | `people` 欄 |

狀態說明：`curated` 精選（每場最多 80 句）、`public` 公開玩家句（每場最新 20＋隨機 20）、`review` 待審（不會出現在別人遊戲裡）、`hidden` 隱藏。

## 關鍵字（Table Editor → `filter_words`）
- `kind` = `block`：直接拒收；`review`：收下但先待審
- `is_regex` 勾起來時，`word` 會當正規表示式

## 規則
- 每句 1–20 字（資料庫強制）
- 全站每分鐘最多 30 次送出
- 同一句只存一次，`people` 記幾個人說過（忽略空白、標點、大小寫）
- 同一台設備只算一句，再送就改成新的
- 訪客只能呼叫 `submit_line` 和 `get_lines`，不能直接讀寫任何表
