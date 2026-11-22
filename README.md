# vga_camera — OV7670 + Digilent PmodVGA on Arty A7-35T

OV7670 カメラで撮影した VGA (640×480) 映像を RGB565 で取り込んで DDR3 (RGB888) にバッファし、Digilent PmodVGA で VGA (640×480 @ 60 Hz) モニタに 12bit カラー (RGB444) で全画面表示する Vivado プロジェクトです。
カメラ画素は `cam_ddr` で AXI4-Stream Video にしてブロックデザイン `fb_test` の VDMA へ渡し、DDR3 → VDMA → vid_out の順に表示します。SW0 でカメラと TPG (水平ランプ) を切り替えられます。

---

## ハードウェア / ツール

| 項目 | 内容 |
|------|------|
| FPGA ボード | Digilent Arty A7-35T (XC7A35T-CSG324-1) |
| カメラ | OV7670 (RGB565 出力, VGA 640×480) |
| VGA 出力 | Digilent PmodVGA (RGB444 = 12bit カラー, 各色 4×4 Bayer ディザ) |
| 外部メモリ | DDR3 (fb_test 内 MIG, 8-bit, 128 MB @ 0x8000_0000) |
| ツール | Vivado 2026.1 |
| ライセンス | BASIC (ILA は 1 個・5 プローブまで, インクリメンタルコンパイル不可) |

---

## システム構成

```
 [OV7670] VGA 640×480 RGB565
      │ cam_pclk
      ▼
 [ov7670_if]  SCCB 初期化 (VGA / RGB565 / AGC 上限 4 倍), 2 バイトを 1 画素にまとめる
      │ pix_we / pix_sof / pix_eol / pix_rgb[15:0]
      ▼
 [cam_ddr]  非同期 FIFO (cam_pclk → SYSCLK) → AXI4-Stream Video 640×480 (RGB565 → RGB888, 24bit)
      │
      ▼
 [TPG/カメラ切替: SW0] ◄── [v_tpg_0] 水平ランプ          ┐
      │ S_AXIS_VID                                       │
      ▼                                                  │ fb_test
 [axi_vdma_0 S2MM] ─► [MIG] ─► DDR3 (0x8000_0000)        │ ブロックデザイン
                                │                        │
 [axi_vdma_0 MM2S] ◄────────────┘                        │
      ▼                                                  │
 [v_axi4s_vid_out] ◄─ [v_tc] 640×480                     ┘
      │ RGB888 / HSYNC / VSYNC (BD pclk)
      ▼
 各色 4×4 Bayer ディザで 8bit → 4bit → 出力レジスタ (IOB)
      ▼
 [PmodVGA] R / G / B 各 4bit (12bit カラー), HS / VS
```

---

## クロックドメイン

### vga_top

| クロック | 周波数 | 生成元 | 用途 |
|----------|--------|--------|------|
| `clk` | 100 MHz | ボード発振器 (E3) | SCCB / XCLK 生成 / リセット同期 |
| `pclk` | 25 MHz | MMCME2 CLKOUT0 (VCO 1000 MHz ÷ 40) → BUFG | VGA 出力レジスタ / ILA |
| `clk100` | 100 MHz | MMCME2 CLKOUT1 (÷10, 整数分周) → BUFG | fb_test の CLK / dbg_hub |
| `cam_pclk_g` | 約 25 MHz | OV7670 PCLK (D4) → BUFG | キャプチャ / cam_ddr FIFO 書込み |
| `cam_xclk` | 25 MHz | `clk` をカウンタで ÷4 | OV7670 入力クロック |

`cam_pclk` は非 CCIO ピン (JD pin1 = D4) 入力のため `CLOCK_DEDICATED_ROUTE FALSE` + `BUFG` を使用。

### fb_test (BD 内 clk_wiz_0, 入力 = clk100)

| クロック | 周波数 | 用途 |
|----------|--------|------|
| sysclk | 100 MHz | MicroBlaze-V / AXI / TPG / VDMA / vid_out AXI 側 |
| pclk | 25 MHz | v_tc / vid_out 映像側 |
| sdclk | 333.333 MHz | MIG sys_clk_i |
| refclk | 200 MHz | MIG clk_ref_i (IDELAYCTRL) |
| ui_clk | MIG 出力 | smartconnect_1 aclk1 / MIG S_AXI |

clk_wiz_0 はトップの BUFG 出力を受けるため `PRIM_SOURCE = Global_buffer` にしている (既定値のままだと IBUF が挿入され配置エラー)。

### クロックドメイン間の受け渡し

| 信号 | 方向 | 方法 |
|------|------|------|
| カメラ画素 | cam_pclk_g → SYSCLK | xpm_fifo_async (cam_ddr 内) |
| init_calib_complete | MIG ui_clk → pclk / SYSCLK | 2FF (`ASYNC_REG`) + 1 段目に `set_false_path` |
| SW0 (sel_tpg) | 非同期 → SYSCLK | 2FF + 1 段目に `set_false_path` |
| cfg_done | SYSCLK → cam_pclk_g | 2FF + 1 段目に `set_false_path` (カメラ画素の書き込み開始に使う) |
| fb_test RGB/SYNC | BD pclk → pclk 出力レジスタ | 同期化なし (どちらも clk 由来の 25 MHz) |

---

## モジュール一覧

| ファイル | モジュール | 役割 |
|----------|-----------|------|
| `vga_top.v` | `vga_top` | トップ (MMCM / リセット / fb_test / cam_ddr / VGA 出力レジスタ / ILA / LED) |
| `cam_ddr.v` | `cam_ddr` | カメラ画素 → 非同期 FIFO → AXI4-Stream Video → TPG/カメラ切替 → VDMA S2MM |
| `cam_ddr.v` | `cam_ddr_scaler` | 2 倍拡大 (`UPSCALE=1` のときだけ使用, 既定は未使用) |
| `cam_ddr.v` | `cam_ddr_mux` | 2 つの AXI4-Stream Video をフレーム境界で切替 |
| `cam_ddr.v` | `cam_ddr_cfg` | 起動時に AXI4-Lite で VDMA / TPG のレジスタを設定 (ファームウェア不要) |
| `ov7670_if.v` | `ov7670_if` | カメラ IF (XCLK 生成 / SCCB 調停 / PID テスト / キャプチャ統合) |
| `ov7670_if.v` | `ov7670_init` | SCCB 初期化シーケンサ (ROM: `FFxx` = xx ms 待ち, `FFFF` = 終端) |
| `ov7670_if.v` | `sccb_master` | SCCB マスタ (100 kHz, 3 相書込み + 2 相書込み→読出し) |
| `ov7670_if.v` | `ov7670_capture` | PCLK ドメインのキャプチャ / Y 抽出 / sof・eol 付き画素ストリーム (640×480 を超える画素は捨てる) |
| `fb_test.bd` | `fb_test` | TPG / VDMA / MIG / VTC / MicroBlaze-V の BD |
| `constraints.xdc` | — | ピン配置 / タイミング制約 / dbg_hub 設定 |
| `create_ila.tcl` | — | ILA IP (ila_cam) 生成 |
| `fix_fb_test_bd.tcl` | — | fb_test の内部配線・IP 設定・アドレス割り当てを作り直す |
| `fix_fb_test_clk.tcl` | — | clk_wiz_0 の PRIM_SOURCE を Global_buffer に設定 |
| `cam_ddr_bd.tcl` | — | fb_test にカメラ用ポート (S_AXIS_VID / M_AXIS_TPG / S_AXI_CFG / SYSCLK / SYSRST_N) を追加, 廃止したソースをプロジェクトから外す |
| `eth_bd.tcl` | — | fb_test に AXI EthernetLite (MII) / Timer / INTC / UARTLite を追加し、MicroBlaze-V のキャッシュを DDR3 につなぐ (Ethernet / Web サーバー用) |
| `ov_sccb_tb.v` | `ov_sccb_tb` | ov7670_if の SCCB シーケンス (初期化 ROM / 0x70・0x71 / SW2 の COM8) のテストベンチ |
| `cam_ddr_tb.v` | `cam_ddr_tb` | cam_ddr のテストベンチ (等倍 / 2 倍拡大 / 切替 / レジスタ設定) |
| `cam_mono_tb.v` | `cam_mono_tb` | vga_top 全体 (OV7670 モデル → S_AXIS_VID, VGA 出力) のテストベンチ (fb_test / ila_cam はスタブ) |
| `ov7670_model.v` | `ov7670_model` | OV7670 ビヘイビアモデル (シミュレーション専用) |
| `fb_test_tb.sv` | `fb_test_tb` | fb_test のテストベンチ (axi_vip で TPG 設定) |

`spi_*.v` / `spi_flash_128mb.v` は別の SPI 開発で作成したもので、このデザインでは使用しない。

---

## カメラ設定 (OV7670 初期化 ROM)

| # | レジスタ | 値 | 意味 |
|---|----------|----|------|
| 0 | COM7 (0x12) | 0x80 | ソフトリセット |
| 1 | (待ち) | 0xF0 | 240 ms 待つ |
| 2 | COM7 (0x12) | 0x04 | VGA (640×480), RGB 出力 |
| 3 | RGB444 (0x8C) | 0x00 | RGB444 無効 |
| 4 | COM15 (0x40) | 0xD0 | RGB565, 出力レンジ 0x00–0xFF |
| 5 | TSLB (0x3A) | 0x04 | 既定値 (YUV のバイト順のみに関係) |
| 6 | COM13 (0x3D) | 0xC0 | ガンマ有効, UV 彩度自動調整 |
| 7 | COM9 (0x14) | 0x1A | AGC ゲイン上限 4 倍 ([6:4]=001) |
| 8–14 | MTX1–6 (0x4F–0x54), MTXS (0x58) | B3 B3 00 3D A7 E4 / 9E | RGB 出力用の色変換マトリクス (Linux ov7670 ドライバの RGB565 設定) |
| 15–20 | HSTART (0x17) / HSTOP (0x18) / HREF (0x32) / VSTRT (0x19) / VSTOP (0x1A) / VREF (0x03) | 13 / 01 / B6 / 02 / 7A / 0A | 出力窓 (Linux ov7670 ドライバの VGA 設定: 水平 158〜14 (784 で折り返し), 垂直 10〜490)。初期値 (HSTART=0x11 = 136) のままだと 22 画素早く始まり、行頭に有効画素前の暗い列が入って映像が右寄りになる |
| 21–49 | アナログ / ADC / 黒レベル補正 / 予約 | 下記 | OmniVision / Linux ov7670 ドライバの推奨値 |
| 50 | (終端) | 0xFFFF | 初期化終了 |

推奨値として追加しているレジスタ (アドレス = 値):
`0E=61 0F=4B 16=02 1E=07 21=02 22=91 29=07 33=0B 35=0B 37=1D 38=71 39=2A 3C=78 4D=40 4E=20 69=00 74=10 8D=4F 8E=00 8F=00 90=00 91=00 96=00 9A=00 B0=84 B1=0C B2=0E B3=82 B8=0A`
(0x33/0x35/0x37–0x39 はアレイ・ADC 制御、0xB1 は自動黒レベル補正 ON。PLL (DBLV 0x6B) と CLKRC は変えないので PCLK = XCLK = 25 MHz)

- COM8 (0x13) は初期値 0x8F のまま → Fast AGC/AEC, AGC / AEC / AWB (オートホワイトバランス) はすべて自動 (ゲインは 1〜4 倍), バンディングフィルタ OFF。
- 初期化後に PID (0x0A) を読み出し、0x76 なら LD3、それ以外なら LD2 を点灯。
- その後 0x70 = 0x3A / 0x71 = 0x35 (内蔵テストパターン OFF, スケール値は初期値) を 1 回だけ書く。
- 以後は SW2 を切り替えたときだけ COM8 を書く (SW2=ON: 0x8A = AGC/AEC 停止, OFF: 0x8F)。SCCB を常時動かさないことで SIOC/SIOD のトグルがセンサに乗らないようにしている。

---

## VGA 出力

- タイミングは fb_test の v_tc が生成 (640×480 @ 60 Hz, 25 MHz)。VESA DMT どおり: 水平 アクティブ 640 / FP 16 / 同期 96 / BP 48 (総 800), 垂直 アクティブ 480 / 総 525 (VSYNC は v_tc の設定で 489〜491 行)。v_tc の同期は High アクティブなので vga_top で反転して出す。
- BD の RGB888 の各色を 4×4 Bayer ディザで 4bit にして RGB444 (12bit カラー) で出す: `c4 = c[7:4] + (c[3:0] > M[dy][dx])` (15 で飽和, R/G/B 共通の閾値), 行列 `0 8 2 10 / 12 4 14 6 / 3 11 1 9 / 15 7 13 5`。画素座標の下位 2bit は ACTIVE_VIDEO から数える (dx: 有効期間中に +1, dy: 行末ごとに +1, VSYNC で 0)。
- 有効映像期間 (BD の `ACTIVE_VIDEO` = vid_out の vid_active_video) 以外は RGB = 0。vid_out の vid_data はブランキング中も各行の最終画素を出し続けるので、そのままだとモニタがバックポーチの値を黒としてクランプし、行ごとに明るさが変わる (H サグ)。
- RGB・HS・VS は pclk で 1 段レジスタ (IOB FF) してからピンに出す。

---

## fb_test ブロックデザイン

### アドレスマップ

| マスタ | スレーブ | オフセット | サイズ |
|--------|----------|-----------|--------|
| MicroBlaze-V (I/D) | LMB BRAM | 0x0000_0000 | 16 KB |
| MicroBlaze-V (D) | axi_uartlite_0 | 0x4060_0000 | 64 KB |
| MicroBlaze-V (D) | axi_ethernetlite_0 | 0x40E0_0000 | 64 KB |
| MicroBlaze-V (D) | axi_intc_0 | 0x4120_0000 | 64 KB |
| MicroBlaze-V (D) | axi_timer_0 | 0x41C0_0000 | 64 KB |
| MicroBlaze-V / axi_vip / S_AXI_CFG | axi_vdma_0 S_AXI_LITE | 0x44A0_0000 | 64 KB |
| MicroBlaze-V / axi_vip / S_AXI_CFG | v_tpg_0 s_axi_CTRL | 0x44A1_0000 | 64 KB |
| MicroBlaze-V (D) | axi_quad_spi_0 AXI_LITE (XIP 設定) | 0x44A2_0000 | 64 KB |
| MicroBlaze-V (D) | axi_quad_spi_0 AXI_FULL (XIP 読み出し = フラッシュ 0x00_0000〜) | 0x6000_0000 | 16 MB |
| MicroBlaze-V (I/D キャッシュ) | MIG (DDR3) | 0x8000_0000 | 128 MB |
| axi_vdma_0 (MM2S/S2MM) | MIG (DDR3) | 0x8000_0000 | 128 MB |

DDR3 の使い方: 0x8000_0000 + n × 1 MB (n = 0〜7) に 900 KB (640×480×3) のフレームバッファを 8 面 (ファームウェア実行時。ファームウェアなしでは 0x8000_0000 の 1 面だけ)。MicroBlaze-V のプログラム・ヒープは 0x8100_0000 以降に置く。

### 主な設定

- VDMA: S2MM / MM2S 両方有効, フレームストア 3, バースト 16, ラインバッファ 512, MM2S 幅 24 bit
- v_axi4s_vid_out: `C_HAS_ASYNC_CLK = 1` (AXI 100 MHz / 映像 25 MHz)
- v_tc の同期出力は High アクティブ → vga_top で反転して VGA へ
- AXI4-Stream Video の並びは `[23:16]=R, [15:8]=B, [7:0]=G`
- 外部ポート (`cam_ddr_bd.tcl` で追加, すべて SYSCLK = clk_wiz_0/sysclk 100 MHz 同期):
  - `M_AXIS_TPG`: v_tpg_0 の出力を RTL へ出す
  - `S_AXIS_VID`: RTL から VDMA S2MM へ (tkeep は 3'b111 固定)
  - `S_AXI_CFG`: RTL の設定ステートマシンから smartconnect_0 (S02) 経由で VDMA / TPG へ
  - `SYSCLK` / `SYSRST_N`: 上記のクロックとリセット (proc_sys_reset_0/peripheral_aresetn)
  - `ACTIVE_VIDEO`: v_axi4s_vid_out_0/vid_active_video (BD pclk, RGB と同位相)
- Ethernet / CPU まわり (`eth_bd.tcl` で追加, すべて SYSCLK 100 MHz):
  - MicroBlaze-V: 命令 / データキャッシュ 各 32 KB, ライン 8 ワード (データはライトバック, 範囲 0x8000_0000〜0x87FF_FFFF) を有効化し、M_AXI_IC / M_AXI_DC を smartconnect_1 (S02 / S03) 経由で MIG へ。乗除算命令 (RV32M) 有効。例外 (不正命令 BASIC / misaligned) も有効にする (無効だと mret が素通りされ、割り込みから戻れずに暴走する)
  - axi_ethernetlite_0: MII + MDIO, 送受信とも 2 バッファ (ping-pong)
  - axi_timer_0 (lwIP の周期処理), axi_uartlite_0 (115200 bps, 8N1)
  - axi_intc_0: intr[0] = EthernetLite, intr[1] = Timer → MicroBlaze-V INTERRUPT
  - 外部ポート `MII_*` / `MDIO_{mdc, mdio_i, mdio_o, mdio_t}` / `UART_{rxd, txd}` (MDIO の IOBUF は vga_top)
- QSPI ブート用 (`qspi_bd.tcl` で追加):
  - axi_quad_spi_0: XIP モード, 標準 SPI (x1), Micron, STARTUPE2 内蔵 (SCK = CCLK)。AXI は SYSCLK 100 MHz、ext_spi_clk = clk_wiz_0/pclk 25 MHz → SCK 12.5 MHz
  - 外部ポート `SPI_0_{io0, io1, ss}_{i, o, t}` (IOBUF は vga_top)

### cam_ddr による自動設定 (MIG キャリブ完了の約 10 µs 後に 1 回)

| 順 | レジスタ | 値 |
|----|----------|----|
| 1 | TPG HEIGHT / WIDTH / BCKGNDID / OVRLAYID / COLORFORMAT | 480 / 640 / 1 (水平ランプ) / 0 / 0 (RGB) |
| 2 | TPG AP_CTRL | 0x81 (auto_restart + ap_start) |
| 3 | VDMA S2MM: DMACR → START_ADDRESS×3 → STRIDE → HSIZE → VSIZE | 0x0001_0003 → 0x8000_0000 ×3 → 1920 → 1920 → 480 |
| 4 | VDMA MM2S: 同上 (0x00, 0x5C–0x64, 0x58, 0x54, 0x50) | 同上 |

- フレームバッファは DDR3 の 0x8000_0000 から 640×480×3 byte の 1 面 (3 スロットとも同じアドレス, genlock なし)。書き込み中のフレームを読むのでテアリングは出る。ファームウェアを動かすと起動時に VDMA を設定し直し、3 面 + genlock になる (下のファームウェアの項)
- カメラ画素は設定完了後のフレーム先頭から FIFO に書き始める。FIFO が満杯になったらそのフレームの残りを捨て、次のフレーム先頭から再開する (LD2 が点灯)
- VDMA / TPG の設定は cam_ddr が行うので、映像表示に MicroBlaze-V のファームウェアは要らない (ファームウェアは Ethernet / Web サーバーとテアリング対策用)

---

## ピン配置

### スライドスイッチ

| SW | ポート | FPGA ピン | 機能 (High=ON) |
|----|--------|-----------|----------------|
| SW0 | `sw_test` | A8 | DDR3 に書く映像の入力元 (ON=TPG 水平ランプ / OFF=カメラ)。切替はフレーム境界 |
| SW1 | — | C11 | 未使用 |
| SW2 | `sw_agc_hold` | C10 | AGC/AEC を止めて、その時点のゲイン・露光で固定 (横帯の切り分け用) |
| SW3 | `sw_pat` | A10 | カメラ画素を試験パターン (灰色 0xA0 の地, 中央 x=200〜439 / y=160〜319 が黒) に置換。カメラのタイミングで全経路 (FIFO → DDR3 → VGA) を通る |

### ステータス LED / ボタン

| 部品 | ピン | 意味 |
|------|------|------|
| LD0 | H5 | MIG キャリブ完了 |
| LD1 | J5 | VDMA / TPG の自動設定完了 |
| LD2 | T9 | エラー (設定の BRESP エラー / カメラ FIFO あふれ / OV7670 PID 不一致) |
| LD3 | T10 | OV7670 PID = 0x76 (SCCB 通信 OK) |
| BTN0 | D9 | リセット (High) |

### OV7670 接続 (Pmod JC / JD)

| OV7670 | 方向 | Pmod | ピン | FPGA | 備考 |
|--------|:----:|------|:---:|------|------|
| PCLK  | →  | JD | 1  | D4  | 非 CCIO / CLOCK_DEDICATED_ROUTE FALSE |
| D1    | →  | JD | 2  | D3  | |
| D2    | →  | JD | 3  | F4  | |
| D3    | →  | JD | 4  | F3  | |
| D4    | →  | JD | 7  | E2  | |
| D5    | →  | JD | 8  | D2  | |
| D6    | →  | JD | 9  | H2  | |
| D7    | →  | JD | 10 | G2  | |
| XCLK  | ←  | JC | 1  | U12 | 25 MHz 出力 |
| D0    | →  | JC | 2  | V12 | |
| HREF  | →  | JC | 3  | V10 | |
| VSYNC | →  | JC | 4  | V11 | |
| SIOC  | ←  | JC | 7  | U14 | SCCB クロック |
| SIOD  | ↔  | JC | 8  | V14 | **4.7 kΩ → 3.3V プルアップ必須** |
| RESET | ←  | JC | 9  | T13 | High = 動作 |
| PWDN  | ←  | JC | 10 | U13 | Low = 動作 |

### Digilent PmodVGA 接続 (Pmod JA / JB)

PmodVGA を JA + JB の隣接 2 スロットに差し込む。

| 信号 | Pmod | ピン | FPGA |
|------|------|:---:|------|
| R[0] | JA | 1 | G13 |
| R[1] | JA | 2 | B11 |
| R[2] | JA | 3 | A11 |
| R[3] | JA | 4 | D12 |
| B[0] | JA | 7 | D13 |
| B[1] | JA | 8 | B18 |
| B[2] | JA | 9 | A18 |
| B[3] | JA | 10 | K16 |
| G[0] | JB | 1 | E15 |
| G[1] | JB | 2 | E16 |
| G[2] | JB | 3 | D15 |
| G[3] | JB | 4 | C15 |
| HS   | JB | 7 | J17 |
| VS   | JB | 8 | J18 |

> **注意:** JA pin7-10 は物理的に VGA Blue チャンネルに接続されているため、制約ファイルで G/B を入れ替えています (PmodVGA の仕様: J1 = R/B, J2 = G/HS/VS)。

DDR3 のピン配置と IOSTANDARD は MIG IP の XDC が付与する。

### Ethernet PHY (TI DP83848J, MII) / USB-UART

| 信号 | FPGA | 信号 | FPGA |
|------|------|------|------|
| eth_ref_clk (25 MHz 出力) | G18 | eth_rx_clk | F15 |
| eth_rstn | C16 | eth_rx_dv | G16 |
| eth_tx_clk | H16 | eth_rxerr | C17 |
| eth_tx_en | H15 | eth_rxd[3:0] | G17, E18, E17, D18 |
| eth_txd[3:0] | H17, J13, J14, H14 | eth_col / eth_crs | D17 / G14 |
| eth_mdc / eth_mdio | F16 / K13 | uart_txd_in (PC→FPGA) / uart_rxd_out (FPGA→PC) | A9 / D10 |

| qspi_cs | L13 | qspi_dq[3:0] | M14, L14, K18, K17 |

- eth_ref_clk は vga_top の MMCM の 25 MHz (pclk) を ODDR でピンに出す
- QSPI フラッシュ (Micron MT25QL128, 16 MB): SCK は CCLK (E9) で STARTUPE2 経由。標準 SPI (x1) で使うので DQ2 (WP#) / DQ3 (HOLD#) は vga_top から常に 1 を出す
- PHY の MDIO アドレスは 1 (Arty の既定)

---

## タイミング制約

| 制約 | 内容 |
|------|------|
| `create_clock sys_clk` | 10 ns (E3) |
| `create_clock cam_pclk` | 40 ns (D4) |
| `create_clock eth_rx_clk / eth_tx_clk` | 40 ns (F15 / H16, PHY が出す MII クロック) |
| `set_clock_groups -asynchronous` | sys_clk 系 (MMCM 生成含む) / cam_pclk 系 / eth_rx_clk / eth_tx_clk |
| `set_false_path` | `ddr3_calib_sync_reg[0]`, `u_cam_ddr/calib_sync_reg[0]`, `u_cam_ddr/sel_sync_reg[0]`, `u_cam_ddr/run_sync_reg[0]` へのパス |
| dbg_hub | 入力 100 MHz, 分周なし, `connect_debug_port dbg_hub/clk [get_nets clk100]` |

Ethernet 追加後の実装 (2026-11-21, プロジェクトのコピーで確認): WNS -0.081 ns / WHS +0.015 ns。違反は MIG 内部 (u_ddr_phy_init, clk_pll_i 6 ns) の 1 パスだけで、以前から出ているもの (前回 -0.190 ns)。SYSCLK +0.98 ns, eth_rx_clk / eth_tx_clk は余裕あり。MIG のクロック設定見直しは今後の課題。

QSPI (axi_quad_spi_0) 追加後の実装 (2026-11-22): WNS -0.010 ns / WHS +0.023 ns、SYSCLK +0.011 ns。違反は MIG 内部 (u_ddr_phy_init) の 1 パスだけ。

キャッシュを各 32 KB / ライン 8 ワードにした後の実装 (2026-11-22): 既定の strategy では SYSCLK が -0.265 ns (MicroBlaze-V 内部の 22 パス) で満たせなかったため、impl_1 の strategy を **Performance_ExplorePostRoutePhysOpt** に変更。WNS -0.063 ns / WHS +0.020 ns、SYSCLK +0.095 ns。違反は上と同じ MIG 内部 (u_ddr_phy_init) の 1 パスだけ。BRAM 32.5 / 50 タイル。

---

## BRAM 使用量

BRAM のフレームバッファは廃止した (モノクロの 640×480×8bit でも約 2.4 Mbit で XC7A35T の BRAM 1.8 Mbit に載らないため)。
BRAM 経路があった前回の実装で 35 / 50 タイル。Ethernet 追加後の実装で 20.5 / 50 タイル (RAMB36 ×15, RAMB18 ×11)。
ロジックは LUT 17,549 / 20,800 (84 %), FF 20,205 / 41,600 (49 %) で、LUT の残りは少ない。

---

## ILA デバッグ

Vivado の BASIC ライセンスでは **ILA 1 個 / 5 プローブ以内** に制限されるため、
`ila_cam` 1 個に関連信号を連結して割り当てている。
サンプリングクロックは MMCM の `pclk` (25 MHz)。cam_pclk ドメインの信号は非同期サンプルになる。

### ila_cam

| probe | 幅 | 内容 |
|-------|----|------|
| 0 | 8 | `cam_d` カメラ生データ |
| 1 | 4 | `{cam_vsync, cam_href, pix_we, byte_phase}` |
| 2 | 17 | `{pix_sof, pix_eol, cam_ddr_ovf, cam_ddr_cfg_done, cam_ddr_cfg_err, 12'b0}` |
| 3 | 8 | `pix_rgb[15:8]` カメラ画素 RGB565 の上位バイト (R[4:0], G[5:3]) |
| 4 | 12 | `{vga_hs, vga_vs, ddr3_calib_done, sw_test, fbt_y8[7:0]}` (BD 映像の輝度 (77R+150G+29B)/256, ILA 表示用) |

- debug hub は `clk100` に接続 (JTAG クロック 15 MHz の 2.5 倍以上が必要。pclk のままだと "ILA waveform corrupted" になる)。
- Hardware Manager では probe を右クリックして Bus を分割・リネームすると見やすい。

---

## シミュレーション

vga_top 全体 (カメラ → DDR3 書き込みストリーム) は `cam_mono_tb` で検証する。

```
xvlog cam_mono_tb.v vga_top.v cam_ddr.v ov7670_if.v ov7670_model.v glbl.v
xelab -L xpm -L unisims_ver cam_mono_tb glbl -s cam_mono_tb
xsim cam_mono_tb -R
```

- 検査内容: VDMA/TPG 設定 20 回 / S_AXIS_VID のフレームが 640×480 で各画素 = モデルの RGB565 を RGB888 に広げた値 / tuser・tlast の位置 / VGA 出力 (ブランキング中 0 / スタブ RGB (0xC8, 0xFF, 0x30) → R は 12・13 が 2:2, G=15, B=3) / SW3 試験パターンの 1 フレーム / FIFO あふれなし / LED
- 初期化時間短縮のため TB がモデルの COM7 を 0x04 (VGA/RGB565) に保持する
- AGC 設定は未検証

SCCB の書き込みシーケンスは `ov_sccb_tb` で検証する (SYS_CLK_HZ = 4 MHz に下げて 240 ms 待ちも含めて実行)。

```
xvlog ov_sccb_tb.v ov7670_if.v ov7670_model.v
xelab ov_sccb_tb -s ov_sccb_tb
xsim ov_sccb_tb -R
```

- 検査内容: 初期化 ROM の値がモデルのレジスタに入る / CLKRC・DBLV は書かない / 0x70・0x71 を 1 回だけ書く / その後 SCCB が止まる / SW2 (agc_hold) の切替ごとに COM8 を 1 回だけ書く
- モデルは SCCB 読み出し非対応のため PID テストは fail になる (想定どおり)

cam_ddr 単体は `cam_ddr_tb` で検証する。高速化のため 32×16 で実行する。

```
xvlog cam_ddr_tb.v cam_ddr.v glbl.v
xelab -L xpm -L unisims_ver cam_ddr_tb glbl -s cam_ddr_tb
xsim cam_ddr_tb -R
```

- 検査内容: レジスタ書き込み 20 個の順序と値 / 出力画素 = カメラ (x, y) / tuser・tlast の位置 / TPG ⇔ カメラ切替でフレームが途中で混ざらない / FIFO あふれなし
- `xvlog -d TB_UPSCALE ...` で 2 倍拡大 (`UPSCALE=1`) を検証する
- VDMA・MIG・DDR3 は含まない (実機で確認が必要)。`fb_test_tb.sv` も DDR3 モデルがないため DDR3 経路は確認できない

---

## ビルド手順

ソースからフラッシュ書き込みまでの通しの手順は [BUILD.md](BUILD.md) にまとめた。

1. Vivado で `vga_camera.xpr` を開く
2. インクリメンタルコンパイルを無効化 (BASIC ライセンスでは 12-29181 エラーになるため。初回のみ):
   ```tcl
   set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs synth_1]
   set_property INCREMENTAL_CHECKPOINT {} [get_runs synth_1]
   set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs impl_1]
   set_property INCREMENTAL_CHECKPOINT {} [get_runs impl_1]
   ```
3. ILA IP を生成 (初回またはプローブ変更時。何度実行してもよい):
   ```tcl
   source {D:/xlinix/vga_camera/create_ila.tcl}
   ```
4. 合成 → 実装 → ビットストリーム:
   ```tcl
   reset_run synth_1
   launch_runs impl_1 -to_step write_bitstream -jobs 6
   ```
5. Hardware Manager でボードに書き込み (USB-JTAG。リモートの場合はボード側 PC で hw_server を起動し `<ホスト名>:3121` に接続)

合成の前に一度 `source {D:/xlinix/vga_camera/cam_ddr_bd.tcl}` を実行し、続けて `source {D:/xlinix/vga_camera/eth_bd.tcl}` (Ethernet / UART / キャッシュの追加)、`source {D:/xlinix/vga_camera/qspi_bd.tcl}` (QSPI ブート用の AXI Quad SPI) を実行する (どれも何度実行してもよい)。fb_test にカメラ用ポートを追加し、cam_ddr.v を追加、廃止した fb_reader.v / vga_mono.v をプロジェクトから外す (何度実行してもよい)。
fb_test の配線を作り直す場合は `source {D:/xlinix/vga_camera/fix_fb_test_bd.tcl}` を実行し、その後 `cam_ddr_bd.tcl` をもう一度実行する。

### ファームウェア (MicroBlaze-V, Vitis 2026.1)

`sw/` に置いた。Vitis ワークスペース `firmware/` は生成物 (git 管理外) で、毎回スクリプトから作り直す。

| ファイル | 内容 |
|------|------|
| `sw/export_xsa.tcl` | 実装結果 (ビットストリーム込み) を `firmware/vga_top.xsa` に出力 |
| `sw/build_fw.py` | プラットフォーム `vga_plat` (standalone + lwip220 RAW API, DHCP) とアプリ `vga_web` を作成してビルド。アプリは lwip_echo_server テンプレート (プラットフォーム / lwIP 初期化) を土台に `sw/src` で上書きし、テンプレートの echo.c は `sw/src` の main.c / platform.c 以外の .c (http_server.c, frame.c) に差し替える。lwIP は送信バッファ 64 KB、コピーなし送信用の pbuf 1024 個 |
| `sw/src/main.c` | テンプレートの main.c を置き換え。xemac_add の前に MDIO で PHY (ID / BMSR) を読み、リンクを最大 10 秒待って UART に表示 (lwIP のドライバはオートネゴ完了を無期限に待つため、リンクが無いと無言で止まる)。待ち時間は axi_timer_0 のカウンタで測る (`usleep()` は使えない。下の QSPI ブートのメモ) |
| `sw/src/platform.c` | テンプレートの platform.c を置き換え。SDT 構成ではタイマー割り込みが xemac_add より前から動くため、xemac_add 完了 (`EthNetifReady`) まで `eth_link_detect` を呼ばない (未初期化の netif->state を参照して暴走するのを防ぐ)。時間計測用に 50 ms ごとの割り込み回数 (`PlatformTicks`) を数える |
| `sw/src/frame.c` | VDMA の設定し直し (3 面 + genlock) とスナップショット。下の「テアリング対策」を参照 |
| `sw/src/face.c`, `face_cascade.h` | 顔検出 (Viola-Jones)。下の「顔検出」を参照。face_cascade.h は OpenCV のカスケードから生成した表 |
| `sw/tools/gen_cascade.py` | OpenCV の Haar カスケード (XML) → face_cascade.h |
| `sw/tools/face_ref.py` | face.c と同じ計算の Python モデル (OpenCV との比較用) |
| `sw/src/http_server.c` | Web サーバー (ポート 80, HTTP/1.0)。`/` は画像を連続で読み込み直す HTML 1 ページ、`/frame.bmp` は最新のカメラフレームのスナップショットを 24 bit BMP (640×480, 上から下の行順) にして返す。画素はコピーせず、フレームバッファを直接 lwIP に渡す (tcp_write の COPY なし)。Nagle は無効 |
| `sw/run_fw.tcl` | xsdb で FPGA 書き込み → ELF を DDR3 にロードして実行 (開発用。電源を切ると消える) |
| `sw/boot/` | BRAM ブートローダ (start.S, boot.c, boot.ld)。下の「QSPI ブート」を参照 |
| `sw/flash.tcl` | ブートローダのビルド → ビットストリームへの埋め込み → フラッシュイメージ作成 → QSPI フラッシュ書き込み → フラッシュから起動し直す |

手順 (PowerShell, リポジトリ直下):

1. Vivado で実装後、Tcl Console で `source {D:/xlinix/vga_camera/sw/export_xsa.tcl}`
2. `cmd /c "chcp 65001 >nul && C:\AMDDesignTools\2026.1\Vitis\bin\vitis.bat -s sw\build_fw.py"`
3. Vivado の Hardware Manager を閉じてから `C:\AMDDesignTools\2026.1\Vitis\bin\xsdb.bat sw\run_fw.tcl`
4. USB-UART (115200 bps, 8N1) に IP アドレスが表示される (DHCP が取れない場合は 192.168.1.10 固定)
5. ブラウザで `http://<IP>/` を開くとカメラ画像が表示され、読み込みが終わるたびに次のフレームを取りに行く。顔が見つかると緑の枠が重なる

メモ:

- プログラムは DDR3 の 0x8100_0000〜 に置く (0x8000_0000〜 はフレームバッファ)。`-mcmodel=medany` でビルド
- 実機確認済み: DHCP で IP 取得、ping 応答 (約 1 ms)、`/` と `/frame.bmp` (921,654 バイト) の取得、それ以外は 404
- 1 フレーム (921,654 バイト) の取得は約 0.78 秒 (約 1.2 MB/s)。3 クライアント同時でも全員取得できる (約 1.9〜2.1 秒)
- 速度はメモリの遅さで決まっている。DDR3 のキャッシュミス 1 回が約 2.3 µs かかり、プログラムも DDR3 で動く。キャッシュ各 8 KB / ライン 4 ワードでは 1 フレーム約 1.4 秒 (段階 3 は 1.9 秒) だったのを、各 32 KB / ライン 8 ワードにして約 0.78 秒にした
- MAC アドレスはテンプレート既定の 00:0a:35:00:01:02
- 日本語ロケールの Windows では vitis.bat が UTF-8 デコードエラーで失敗するので `chcp 65001` を付ける
- Vitis 2026.1 同梱の `lwip220_v1_4/data/lwip220.yaml` は先頭に BOM があり、lwip220 がライブラリとして認識されない。`build_fw.py` が BOM を除いたコピーを `firmware/sw_repo` に作ってローカルリポジトリとして登録する
- スクリプト終了後も vitis-server (java.exe) が残ってワークスペースを掴むことがある。次の実行で "already in use" になったら終了させる

#### テアリング対策 (frame.c)

- 起動時に VDMA をリセットして設定し直す。3 スロットに別々のバッファを入れ、S2MM (カメラ) は 3 面を順に書く。MM2S (VGA) は S2MM の dynamic genlock スレーブにして、書き終わった直前のフレームだけを読む → VGA でもテアリングしない
- S2MM 側にも GenlockEn (dynamic master) を付けると、実機ではフレーム 0 のまま VDMAIntErr で止まった。S2MM は genlock なしで回す
- カメラのフレームの途中で S2MM を起動すると、VDMAIntErr / SOFLateErr で止まることがある。エラーをクリアして VSIZE を書き直すと動き出すので、起動時に書き込みスロットが動くまで繰り返す (UART に `[vdma] N restarts, camera 31 frames/s ...`)
- スナップショットはコピーしない (900 KB を読むだけで 1 フレーム時間 33 ms を大きく超えるため)。代わりに、表示中の (= 最新の書き終わった) フレームのバッファを空きバッファと入れ替えて VDMA の巡回から外す:
  1. 表示中のスロット r のバッファ P を選ぶ
  2. S2MM のスロット r のアドレスを空きバッファに変える (次のカメラフレームから有効。r が次に書かれるのは 2 フレーム後)
  3. 表示がスロット r を離れるのを待ってから、MM2S のスロット r も同じ空きバッファに変える
  4. P はどのスロットにも無いので VDMA は触らない。送信中ずっとこの状態を保つ
- 送る直前の部分だけ、P の中でバイト順を G,B,R → B,G,R に直す (直した直後に lwIP がチェックサムを計算するので、まだキャッシュに乗っている)。送信が終わったら D キャッシュを書き戻して空きバッファに戻す
- 50 ms 以内に来たリクエストは同じスナップショットを共有する。それ以外はリクエストごとに新しいフレームを確保する (空きバッファが無いときは最新のものを共有)

### QSPI ブート (段階 5)

電源投入 (または PROG ボタン) で、FPGA がフラッシュからコンフィグされ、Web サーバーまで自動で起動する。ボードのジャンパ JP1 は SPI (QSPI ブート) にしておく。

フラッシュ (MT25QL128, 16 MB) の配置:

| アドレス | 内容 |
|------|------|
| 0x00_0000 | ビットストリーム (圧縮, SPI x4, 33 MHz)。BRAM にブートローダ入り (`firmware/boot.bit`) |
| 0x80_0000 | ファームウェアイメージ: ヘッダ 32 バイト (magic `VAGW`, ロード先, サイズ, エントリ, データのチェックサム, ヘッダのチェックサム) + vga_web.elf の LOAD セグメント (約 163 KB) |

起動の流れ:

1. FPGA がフラッシュからコンフィグされ、MicroBlaze-V がリセットベクタ 0x0 (LMB BRAM) からブートローダを実行
2. ブートローダ (`sw/boot`, 約 1 KB, BSP なし) が XIP 窓 0x6080_0000 のヘッダを確かめ、データを DDR3 0x8100_0000 にコピーしてチェックサムを照合
3. D キャッシュを書き戻し (BSP と同じ cbo.flush のインデックス指定) → I キャッシュ無効化 → エントリ 0x8100_0000 へジャンプ
4. UART に `[boot] ...` が出たあと、いつものファームウェアの表示が続く

更新手順 (ビットストリームかファームウェアを作り直したとき。PowerShell, リポジトリ直下, Vivado の Hardware Manager は閉じておく):

```powershell
C:\AMDDesignTools\2026.1\Vivado\bin\vivado.bat -mode batch -nojournal -nolog -source sw\flash.tcl
```

`-tclargs noprog` を付けると `firmware/flash.mcs` を作るだけで書き込まない。`firmware/vga_top.mmi` (BRAM の配置情報) は impl_1 から自動で書き出す。

メモ:

- フラッシュからのコンフィグ直後は、最初の XIP 読み出しが 0xFFFFFFFF になる (STARTUPE2 は USRCCLKO の最初の 3 クロックを無視するため、最初の SPI 転送が壊れる)。ブートローダはヘッダの magic が読めるまで空読みする (実機では 1 回)
- xiltimer の sleep 用タイマーは CPU のサイクルカウンタだが、この MicroBlaze-V にはカウンタが無い (C_USE_COUNTERS = 0) ので `usleep()` は戻ってこない。JTAG 実行ではリンクが上がったままで `usleep()` を通らず気づかなかった。フラッシュ起動では PHY のリンクに約 2 秒かかり、ここで止まっていた
- `sw/run_fw.tcl` (JTAG) は今までどおり使える (impl_1 のビットストリームはブートローダなしで、BRAM は `j 0` のまま)
- 実機確認 (2026-11-22): `boot_hw_device` (PROG と同じ) でフラッシュから起動し、ブートローダ → ファームウェア → DHCP → `/frame.bmp` 取得まで確認

### 顔検出 (face.c, 段階 6)

MicroBlaze-V のソフトウェアで、カメラ画像から正面の顔を見つける (誰の顔かは判別しない)。Viola-Jones 法 (Haar 特徴のカスケード) で、検出器は OpenCV 同梱の `haarcascade_frontalface_alt.xml` (20×20 窓, 22 段, 弱分類器 2135 個, Intel License Agreement = BSD 系)。

- `GET /faces` が最新の結果を JSON で返す: `{"seq":N,"ms":検出時間,"windows":窓数,"faces":[[x,y,w],...]}` (640×480 座標, 正方形)。ビューアページは画像を読み込むたびに `/faces` を取りに行き、緑の枠を重ねる (枠は 1〜数枚前のフレームのもの)
- UART に `[face] #N: k face(s) in T ms ...` (顔があったときと 10 回に 1 回) と処理時間の内訳 `[face] time: ...` を出す

処理の流れ (浮動小数点なし, 整数のみ):

1. スナップショット (frame.c) を B,G,R に直し、白黒 160×120 に縮小 (4×4 画素の平均, (77R + 150G + 29B) の和 + 2048 を 12 ビット右シフト)
2. 1.2 倍刻みの画像ピラミッド (バイリニア縮小) の各段で、20×20 の窓をずらしながら判定 (拡大率 2 倍までは 2 画素おき、それ以上は 1 画素おき)
3. 窓ごとに内側 18×18 の標準偏差 nf = sqrt(A·Σv² − (Σv)²) を求め、弱分類器は Σ(重み × 矩形和) ≤ floor(しきい値 × nf) なら左の値。段の合計がしきい値未満なら打ち切り
4. 近くに重なった検出をまとめる (OpenCV の groupRectangles 相当, eps 0.2, 4 個以上)
5. 最小の顔は 160×120 で 20 画素 = 640×480 で 80 画素 (画面の幅の 1/8)

処理時間 (実機, 顔なしの場面, 13,339 窓, 弱分類器の評価 約 60 万回):

| | 時間 |
|------|------|
| 白黒 160×120 への縮小 | 約 245 ms |
| ピラミッド各段の準備 | 約 90 ms |
| 窓の判定 | 約 800 ms |
| 合計 (画像を送っていないとき) | 約 1.2 秒 |
| 合計 (ブラウザで画像を連続取得中) | 約 3.6 秒 (そのとき画像の取得は 1 枚 1.0〜1.7 秒) |

メインループから `face_poll()` を呼び、少しずつ進める (画像を送っていないときは 1 回 10 ms、送信中は 1 ms 検出 → 2 ms ネットワークだけ)。

速くするための工夫 (最初の実装は 1 回 3.4 秒、弱分類器 1 回 4.3 µs):

- **この MicroBlaze-V のシフト命令は遅い**: バレルシフタが AREA 実装 (C_USE_BARREL = 2) で、シフト量 1 ビットにつき約 1 クロックかかる (実測。加算・乗算は 1〜3 クロック)。内側のループからシフトをなくした:
  - 弱分類器の比較は 64 ビットシフトをやめ、しきい値を Q31 で持って `mulh(thr, 2·nf)` (= floor(thr·nf)) と比べる
  - 積分画像のオフセットは最初から 4 倍したバイト単位で持つ (`index << 2` をなくす)
  - 白黒化は 16 画素ぶん足してから 1 回だけシフト。frame.c の G,B,R → B,G,R 変換もワードのシフトからバイト単位の入れ替えにした (BMP 送信も速くなる)
- **キャッシュに収める**: 画像全体の積分画像 (78 KB × 2) をやめ、窓 1 行ぶん (21 行) の帯の積分画像と、窓の内側の二乗和用の列ごとの累積和 (161 個) にした。最初の 10 段 (弱分類器 384 個, ほとんどの窓がここで打ち切られる) の表と合わせて 26 KB の 1 ブロックに置き、32 KB の D キャッシュの中で互いに追い出し合わないようにした

確認:

- `sw/tools/face_ref.py` は face.c と同じ整数演算の Python モデル。matplotlib 同梱のサンプル写真 (grace_hopper.jpg) で、OpenCV の `detectMultiScale` と同じ位置・大きさの顔を検出 (顔のないカメラ画像では両方 0 個)
- 実機: 同じ写真の 160×120 白黒画像を JTAG で face.c の作業領域に書き込んで判定させ、モデルと同じ結果 (640×480 で (232,80) 大きさ 188, 14 ヒット) を確認
- カスケードを変えるときは `python sw/tools/gen_cascade.py <xml> sw/src/face_cascade.h` (OpenCV の XML から整数の表を作る。作った face_cascade.h はリポジトリに入れてあるので、ビルドに OpenCV は要らない)

### 顔検出のハードウェア処理 (hw-face ブランチ)

顔検出の重い部分 (窓の判定) を FPGA のロジックで行う検証用の構成。リソースを空けるため、ほかの条件は緩めている (main ブランチとの違い):

| 項目 | main | hw-face |
|------|------|---------|
| 顔検出の最初の 10 段 | ソフトウェア | `rtl_haar/haar_engine.v` (ハードウェア) |
| v_tpg_0 (SW0 のテストパターン) | あり | 削除 (SW0 は使えない。ON にするとカメラ映像が止まる) |
| ILA (ila_cam) / dbg_hub | あり | 外した (`USE_ILA` 未定義、dbg_hub の制約はコメントアウト) |
| MicroBlaze-V のキャッシュ | 各 32 KB / 8 ワード | 各 8 KB / 4 ワード |
| LUT / BRAM / DSP | 18,436 (89%) / 33 / 5 | 17,174 (83%) / 32 / 10 |
| タイミング (WNS) | -0.010 ns (MIG 内部) | +0.013 ns (SYSCLK +0.123 ns) |
| 顔検出 1 回 (画像を送っていないとき) | 約 1.2 秒 | 約 0.56 秒 (うち窓の判定 約 50 ms, ソフトだけだと約 900 ms) |
| Web の画像取得 | 約 0.78 秒 | 約 2.3 秒 (キャッシュが小さいため) |

エンジン (`rtl_haar/haar_engine.v`, LUT 1,460 / BRAM36 12 / DSP 5, SYSCLK 100 MHz):

- AXI4-Lite スレーブ。BD の外部ポート `M_AXI_HAAR` (smartconnect_0 の TPG が使っていた口) から MicroBlaze-V で 0x44A3_0000
- CPU がピラミッドの 1 段 (最大 160×120, 8 bit) を内蔵 RAM に書いて起動すると、窓 1 行ごとに帯の積分画像 (21 行 × 161, 20 bit) と二乗和の累積を作り、全部の窓について標準偏差 (16 クロックの整数平方根) と最初の 10 段 (弱分類器 384 個, ROM) を判定する
- 10 段を通った窓の座標を FIFO (256 個) に積む。CPU はそれを読み、その窓だけ 21×21 の積分画像を作り直して残り 12 段をソフトで判定する (1 フレームで 25〜50 窓程度)
- 計算は face.c と同じ整数演算でビット単位まで一致する。弱分類器 1 個あたり 7〜9 クロック、窓 1 個あたり約 400 クロック
- レジスタ: 0x00 CTRL (bit0 start, bit1 clear) / 0x04 STATUS (bit0 busy, [24:16] FIFO 数) / 0x08 LEVEL (lw, lh, step) / 0x0C FIFO (読むと取り出し, bit31 有効, y, x) / 0x10 窓数 / 0x14 弱分類器数 / 0x18 INFO / 0x1C MAGIC "HAAR" / 0x8000〜 画像 (y × 160 + x)
- ファームウェアは起動時に MAGIC を読み、エンジンがあれば使う (無ければ main と同じソフトウェア処理)。UART に `[face] HW engine: 10 stages, 384 weak classifiers`

作り方 (main の手順に追加):

1. `source {D:/xlinix/vga_camera/hw_bd.tcl}` (BD 変更 + RTL / ROM ファイルをプロジェクトに追加。eth_bd.tcl / qspi_bd.tcl の後)
2. 合成 → 実装 → XSA 出力 → ファームウェアのビルドは main と同じ
3. ROM を作り直すとき: `python sw/tools/gen_cascade.py <haarcascade_frontalface_alt.xml> sw/src/face_cascade.h rtl_haar 10` (最後の数字がハードウェアで行う段数)

確認:

- シミュレーション: `rtl_haar\sim\run_sim.bat` (xsim)。テスト写真のピラミッド 2 段 (160×120 の 2 画素おき / 77×58 の 1 画素おき) で、10 段を通る窓の座標・窓数・弱分類器数が Python モデルと一致 (PASS)。テストベクタは `python sw/tools/haar_vectors.py <画像> rtl_haar/sim 10 0 4`
- 実機: テスト写真を JTAG で注入し、ソフトウェア版と同じ結果 ((232,80) 大きさ 188, 14 ヒット)
- 作業中の注意: Vivado の GUI でプロジェクトを開いたままバッチで BD を変えると、GUI が run をリセットしたりプロジェクトファイルを上書きしたりする。バッチで作るときは GUI を閉じる

---

## 動作確認

1. LD3 点灯 → OV7670 初期化 & PID 読み出し成功 (0x76)。LD2 が点灯したら SIOD プルアップ / 配線を確認
2. LD0 点灯 → MIG キャリブ完了
3. LD1 点灯 → VDMA / TPG の自動設定完了
4. VGA モニタに 640×480 全画面でカラーのカメラ映像が表示される (色味がおかしい場合は下の既知の制約を参照)
5. SW0 ON → TPG の水平ランプに切り替わる
6. 横方向の帯状の輝度変化が出る場合は SW2 を ON (AGC/AEC 固定)。帯が消えれば AGC/AEC による明るさ変化 (ファームウェアなしなら + 1 面バッファのテアリング) が原因
7. 行ごとに明るさが変わる (暗い部分を含む行のほかの部分が明るくなる, H サグ) 場合は SW3 を ON。
   黒い四角の左右の灰色が上下の灰色より明るく見えれば表示側 (PmodVGA / ケーブル / モニタのアナログ) が原因。
   同じ明るさならセンサ側 (ILA の probe0 `cam_d` / probe3 でカメラ生データも確認できる)

---

## 既知の制約 / 今後の課題

- VGA 化後の合成・実機確認が未実施 (タイミングと BRAM 使用量を要確認)
- DDR3 経路 (cam_ddr + VDMA) は実機未確認。MIG は -1 品種向けのクロック設定 (4:1 / 325 MHz など) への見直しが必要
- RGB565 出力は実機未確認。色が入れ替わる (赤と青など) 場合は `ov7670_capture` の `rgb16` (バイト順) や `cam_ddr` の `rgb565_axis` を見直す。色味・彩度は色変換マトリクス (0x4F–0x58) と AWB の調整が必要な場合がある
- カメラ (約 30 fps) と表示 (60 Hz) は非同期で、同じフレームを 2 回読む
- ファームウェアなしではフレームバッファが 1 面のため、速い動きでテアリングが出る (ファームウェアが 3 面 + genlock に設定し直す)
- 顔検出は 1 回 1.2〜3.6 秒 (ソフトウェア処理)。MicroBlaze-V のバレルシフタを PERFORMANCE (C_USE_BARREL = 1) にすればシフトが 1 クロックになり、検出も lwIP のチェックサムなども速くなるはずだが、ビットストリームの作り直しが要り、LUT (89%) と SYSCLK のタイミングに余裕がない
- Web の画像取得は 1 フレーム約 0.78 秒 (顔検出が動いている間は 1.0〜1.7 秒)。SYSCLK (100 MHz) は MicroBlaze-V のキャッシュ拡大で余裕が小さく (QSPI 追加後 +0.011 ns)、Performance_ExplorePostRoutePhysOpt でやっと満たしている。BD を変えたらタイミングを確認すること
