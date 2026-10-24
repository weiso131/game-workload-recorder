# game-workload-recorder

錄製一段從**啟動遊戲**開始的鍵盤／滑鼠操作，連同當下的存檔快照，供自動化實驗重播。
重播時遊戲照常執行、負載由遊戲本身產生，這個工具只負責「同一個起點 + 同一串輸入」。

## 需求

```sh
sudo dnf install python3-libevdev
```

Steam 要先開著；錄製和重播都需要 `sudo`（讀 `/dev/input`、建 uinput 裝置）。

## 錄製

```sh
./record.sh <game> <name> <minutes>
# 例：./record.sh eldenring boss1 30
```

1. 檢查遊戲沒在執行（存檔可能還在寫）
2. 把整個存檔目錄快照到 `recordings/<game>/<name>/save/`
3. 錄製器開始後立刻 `steam -applaunch`，錄製時間軸的 0 點就是啟動遊戲的瞬間
4. `<minutes>` 分鐘後自動停止；Ctrl+C 可提早停
5. 錄完填 `notes.md`

輸出（`recordings/` 不進 git，位置可用 `RECORDINGS=...` 改）：

```
recordings/<game>/<name>/
  save/            # 錄製前的存檔快照
  devices.json     # 錄到的輸入裝置描述（重播時照這個建 uinput 裝置）
  events.tsv.gz    # monotonic_ns  dev  type  code  value
  meta.json        # 啟動時間、kernel、當下的 sched_ext 狀態
  notes.md         # 起點、操作內容、主觀卡頓時間點
```

### 錄製注意事項

- **Steam Cloud 關掉**（遊戲內容 → 一般）：`record.sh` 會讀 Steam 的 `sharedconfig.vdf` 檢查，沒關就拒絕錄製。雲端同步會在啟動時換掉存檔，跟快照對不上
- **線上要素關掉**：Elden Ring 用離線模式啟動，不然入侵／留言／幻影每輪不同
- **啟動到開始操作這段要留足緩衝**：重播按「距啟動的時間」送輸入，啟動／載入時間每次不同。
  錄製時如果剛好很順，重播那次載入慢一點，輸入就會落在載入畫面裡被吃掉，之後全部對不上。
  標題畫面出現後、讀檔載入完成後，都**多等幾秒再按**
- **輸入法切到英文**（錄製和重播都是）：中文輸入法會攔下按鍵，遊戲收不到任何鍵盤操作
- **標題畫面到進入遊戲只用鍵盤**（E、Enter 這類）：游標位置每次不同，用滑鼠點選單重播時會點歪
- 錄製期間不要打密碼或私人內容，所有按鍵都會進檔案
- `notes.md` 的卡頓時間點是分析時最重要的線索，有感覺就記

### 重播的限制

重播是開環的（只送輸入不看畫面）。地圖、路線這類固定的東西重現得好；
有隨機性的戰鬥（boss AI）幾秒到幾十秒內就會跟錄製時分歧，之後的輸入對不上畫面。
所以探索路線適合當主力 workload，戰鬥類只能當「同類型但每輪不同」的負載。

## 為什麼不用 libinput record/replay

`libinput replay` 以錄製中**第一個事件**為時間 0，「啟動遊戲 → 第一次按鍵」之間的空白會被丟掉，
標題畫面的按鍵就會太早送出。`evrec.py` 保留每個事件的 `CLOCK_MONOTONIC` 時間戳，
重播時對齊到該次啟動遊戲的時間點。

## 新增遊戲

在 `games.sh` 的 `game_config` 加一段：

| 變數 | 意義 |
|---|---|
| `APPID` | Steam app id |
| `SAVE_REL` | 存檔目錄，相對 Proton prefix 的 `drive_c/users/steamuser/` |
| `PROC` | 遊戲執行中時 `pgrep -f` 會匹配的名稱 |

Steam library 的位置會從 `libraryfolders.vdf` 自動找。目前有：

| game | appid | 存檔目錄 |
|---|---|---|
| `eldenring` | 1245620 | `AppData/Roaming/EldenRing`（含 `ER0000.sl2` + `.bak`） |
| `2077` | 1091500 | `Saved Games/CD Projekt Red/Cyberpunk 2077` |

## 重播

```sh
./replay.sh <game> <name>
```

1. 同錄製的前置檢查（Steam 開著、遊戲沒在跑、Steam Cloud 關閉）
2. 把你目前的存檔備份到 `recordings/<game>/.live-save/`
3. 用錄製的快照蓋掉存檔目錄
4. 建好 uinput 虛擬裝置後啟動遊戲，事件依「距啟動的時間」送出
5. 跑滿錄製長度後關遊戲，**把你原本的存檔還原回去**；Ctrl+C 中途中止也一樣會還原

重播中遊戲寫進存檔的進度會被丟掉，這是刻意的：每輪都要從同一個快照開始。

`.live-save.pending` 從備份開始存在到還原完成。如果上一輪沒有正常結束（例如斷電），
它會留著，`replay.sh` 會拒絕執行，避免拿錄製快照蓋掉你唯一一份真正的存檔。
這時候先手動把 `.live-save/` 複製回存檔目錄，再刪掉 `.pending`。

重播時不要碰實體鍵盤滑鼠。

[English](README.md)
