# vga_camera — OV7670 + Digilent PmodVGA on Arty A7-35T

OV7670 カメラで撮影した QVGA (320×240) 映像を 8-bit モノクロで BRAM に取り込み、Digilent PmodVGA で VGA (640×480 @ 60 Hz) モニタの左上に等倍表示する Vivado プロジェクトです。
DDR3 フレームバッファの検証用ブロックデザイン `fb_test` (TPG → VDMA → DDR3 → VDMA → vid_out) も同じ FPGA に載せており、SW3 で出力を切り替えます。

---

## ハードウェア / ツール

| 項目 | 内容 |
|------|------|
| FPGA ボード | Digilent Arty A7-35T (XC7A35T-CSG324-1) |
| カメラ | OV7670 (YUV422 出力の輝度 Y 8-bit を使用, QVGA 320×240) |
| VGA 出力 | Digilent PmodVGA (各色 4bit / 8-bit 輝度を 4×4 Bayer ディザで出力) |
| 外部メモリ | DDR3 (fb_test 内 MIG, 8-bit, 128 MB @ 0x8000_0000) |
| ツール | Vivado 2026.1 |
| ライセンス | BASIC (ILA は 1 個・5 プローブまで, インクリメンタルコンパイル不可) |

---

## システム構成

```
 カメラ経路 (vga_top 内, BRAM)                fb_test ブロックデザイン (DDR3)
 ─────────────────────────────              ─────────────────────────────
 [OV7670] QVGA YUV422 (YUYV)                 [v_tpg_0] AXI4-Stream 24bit
      │ cam_pclk                                   │
      ▼                                            ▼
 [ov7670_if]                                 [axi_vdma_0 S2MM] ─► [MIG] ─► DDR3
   SCCB 初期化 (AGC 上限 4 倍)                     │                  │
   Y (1 バイト目) を抽出                          [axi_vdma_0 MM2S] ◄──┘
      │ fb_we / fb_waddr[16:0] / fb_wdata[7:0]     │
      ▼                                            ▼
 [fb_reader] BRAM 320×240×8bit               [v_axi4s_vid_out] ◄─ [v_tc] 640×480
   読出し: vga_mono の hpos/vpos (2 cycle)         │ RGB888 / HSYNC / VSYNC (BD pclk)
      │ pixel_out[7:0]                             ▼
      ▼                                      輝度変換 Y = (77R+150G+29B)/256
 SW0 でテストパターンと選択                        │ 上位 4bit
 4×4 Bayer ディザ 8bit → 4bit                      │
      │                                            │
      └──────────────► [出力 MUX: SW3] ◄───────────┘
                              │
                              ▼
                   [PmodVGA] R = G = B (4bit), HS / VS
```

---

## クロックドメイン

### vga_top

| クロック | 周波数 | 生成元 | 用途 |
|----------|--------|--------|------|
| `clk` | 100 MHz | ボード発振器 (E3) | SCCB / XCLK 生成 / リセット同期 |
| `pclk` | 25 MHz | MMCME2 CLKOUT0 (VCO 1000 MHz ÷ 40) → BUFG | VGA タイミング / BRAM 読出し / ディザ / ILA |
| `clk100` | 100 MHz | MMCME2 CLKOUT1 (÷10, 整数分周) → BUFG | fb_test の CLK / dbg_hub |
| `cam_pclk_g` | 約 25 MHz | OV7670 PCLK (D4) → BUFG | キャプチャ / BRAM 書込み |
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
| フレームバッファ | cam_pclk_g → pclk | デュアルポート BRAM |
| init_calib_complete | MIG ui_clk → pclk | 2FF (`ASYNC_REG`) + 1 段目に `set_false_path` |
| frame_start | cam_pclk_g → pclk | 2FF + 立ち上がり検出 |
| fb_test RGB/SYNC | BD pclk → VGA ピン | 静的な SW3 MUX のみ (同期化なし) |

---

## モジュール一覧

| ファイル | モジュール | 役割 |
|----------|-----------|------|
| `vga_top.v` | `vga_top` | トップ (MMCM / リセット / テストパターン / ディザ / 出力 MUX / ILA / LED) |
| `ov7670_if.v` | `ov7670_if` | カメラ IF (XCLK 生成 / SCCB 調停 / PID テスト / キャプチャ統合) |
| `ov7670_if.v` | `ov7670_init` | SCCB 初期化シーケンサ (ROM: `FFxx` = xx ms 待ち, `FFFF` = 終端) |
| `ov7670_if.v` | `sccb_master` | SCCB マスタ (100 kHz, 3 相書込み + 2 相書込み→読出し) |
| `ov7670_if.v` | `ov7670_capture` | PCLK ドメインのキャプチャ / Y 抽出 / BRAM 書込み |
| `fb_reader.v` | `fb_reader` | BRAM フレームバッファ (320×240×8bit) と読出し (2 cycle) |
| `vga_mono.v` | `vga_mono` | VGA タイミング生成 (640×480 @ 60 Hz, タイミング専用で使用) |
| `fb_test.bd` | `fb_test` | TPG / VDMA / MIG / VTC / MicroBlaze-V の BD |
| `constraints.xdc` | — | ピン配置 / タイミング制約 / dbg_hub 設定 |
| `create_ila.tcl` | — | ILA IP (ila_cam) 生成 |
| `fix_fb_test_bd.tcl` | — | fb_test の内部配線・IP 設定・アドレス割り当てを作り直す |
| `fix_fb_test_clk.tcl` | — | clk_wiz_0 の PRIM_SOURCE を Global_buffer に設定 |
| `cam_mono_tb.v` | `cam_mono_tb` | カメラ → VGA 経路のテストベンチ (fb_test / ila_cam はスタブ) |
| `ov7670_model.v` | `ov7670_model` | OV7670 ビヘイビアモデル (シミュレーション専用) |
| `fb_test_tb.sv` | `fb_test_tb` | fb_test のテストベンチ (axi_vip で TPG 設定) |

`spi_*.v` / `spi_flash_128mb.v` は別の SPI 開発で作成したもので、このデザインでは使用しない。

---

## カメラ設定 (OV7670 初期化 ROM)

| # | レジスタ | 値 | 意味 |
|---|----------|----|------|
| 0 | COM7 (0x12) | 0x80 | ソフトリセット |
| 1 | (待ち) | 0xF0 | 240 ms 待つ |
| 2 | COM7 (0x12) | 0x10 | QVGA, YUV 出力 |
| 3 | RGB444 (0x8C) | 0x00 | RGB444 無効 |
| 4 | COM15 (0x40) | 0xC0 | 出力レンジ 0x00–0xFF |
| 5 | TSLB (0x3A) | 0x04 | bit3=0 (COM13[0]=0 と合わせて YUYV 順) |
| 6 | COM13 (0x3D) | 0x80 | ガンマ有効, UV スワップなし |
| 7 | 0xB0 | 0x84 | 予約レジスタ (一般的な推奨値) |
| 8 | COM9 (0x14) | 0x1A | AGC ゲイン上限 4 倍 ([6:4]=001) |
| 9 | (終端) | 0xFFFF | 初期化終了 |

- COM8 (0x13) は初期値 0x8F のまま → AGC / AEC / AWB はすべて自動 (ゲインは 1〜4 倍)。
- 初期化後に PID (0x0A) を読み出し、0x76 なら LD1、それ以外なら LD2 を点灯。
- その後は SCCB で 0x70 / 0x71 = 0x00 (内蔵テストパターン OFF) を書き続ける。

---

## VGA 出力

- タイミング: 水平 640 / 16 / 96 / 48 (計 800), 垂直 480 / 10 / 2 / 33 (計 525), 同期は負論理。
- fb_reader の読出しは 2 cycle 遅延。vga_mono の hsync/vsync (1 cycle) を vga_top でさらに 1 cycle 遅らせて位相を合わせる。
- 表示範囲は左上 320×240 (等倍)。それ以外は黒。
- 4×4 Bayer ディザ: `y4 = y[7:4] + (y[3:0] > M[dy][dx])` (15 で飽和), 行列 `0 8 2 10 / 12 4 14 6 / 3 11 1 9 / 15 7 13 5`。
- テストパターン (SW0=ON): SW2=OFF で 8 段階調バー (64 px 幅, 左端が白)、SW2=ON で 8-bit 水平ランプ (y ≈ hpos × 0.39)。

---

## fb_test ブロックデザイン

### アドレスマップ

| マスタ | スレーブ | オフセット | サイズ |
|--------|----------|-----------|--------|
| MicroBlaze-V (I/D) | LMB BRAM | 0x0000_0000 | 16 KB |
| MicroBlaze-V / axi_vip | axi_vdma_0 S_AXI_LITE | 0x44A0_0000 | 64 KB |
| MicroBlaze-V / axi_vip | v_tpg_0 s_axi_CTRL | 0x44A1_0000 | 64 KB |
| axi_vdma_0 (MM2S/S2MM) | MIG (DDR3) | 0x8000_0000 | 128 MB |

### 主な設定

- VDMA: S2MM / MM2S 両方有効, フレームストア 3, バースト 16, ラインバッファ 512, MM2S 幅 24 bit
- v_axi4s_vid_out: `C_HAS_ASYNC_CLK = 1` (AXI 100 MHz / 映像 25 MHz)
- v_tc の同期出力は High アクティブ → vga_top で反転して VGA へ
- AXI4-Stream Video の並びは `[23:16]=R, [15:8]=B, [7:0]=G`
- `cam_stream` ポートは未接続だと CRITICAL WARNING になるため削除済み (カメラを S2MM につなぐときに作り直す)

> **注意:** MicroBlaze-V のファームウェアは未作成のため、実機では TPG / VDMA が起動せず SW3=ON でも映像は出ない見込み。

---

## ピン配置

### スライドスイッチ

| SW | ポート | FPGA ピン | 機能 (High=ON) |
|----|--------|-----------|----------------|
| SW0 | `sw_test` | A8 | テストパターン表示 |
| SW1 | `sw_raw` | C11 | Y を 2 バイト目から取る (カメラが UYVY 順のとき ON) |
| SW2 | `sw_mono` | C10 | テストパターン種別 (ON=8-bit 水平ランプ / OFF=8 段階調バー) |
| SW3 | `sw3` | A10 | fb_test の映像を VGA に出力 (最優先) |

### ステータス LED / ボタン

| 部品 | ピン | 意味 |
|------|------|------|
| LD0 | H5 | MMCM ロック |
| LD1 | J5 | SIO テスト合格 (OV7670 PID = 0x76) |
| LD2 | T9 | SIO テスト不合格 |
| LD3 | T10 | pclk ドメインがリセット中 |
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

> **注意:** JA pin7-10 は物理的に VGA Blue チャンネルに接続されているため、制約ファイルで G/B を入れ替えています (モノクロでは R=G=B なので影響なし)。

DDR3 のピン配置と IOSTANDARD は MIG IP の XDC が付与する。

---

## タイミング制約

| 制約 | 内容 |
|------|------|
| `create_clock sys_clk` | 10 ns (E3) |
| `create_clock cam_pclk` | 40 ns (D4) |
| `set_clock_groups -asynchronous` | sys_clk 系 (MMCM 生成含む) と cam_pclk 系 |
| `set_false_path` | `ddr3_calib_sync_reg[0]` へのパス |
| dbg_hub | 入力 100 MHz, 分周なし, `connect_debug_port dbg_hub/clk [get_nets clk100]` |

8-bit 化前のコードで WNS +0.676 ns (全制約 met)。8-bit 版は未確認。

---

## BRAM 使用量 (見積もり)

| 用途 | BRAM36 数 |
|------|-----------|
| フレームバッファ (320×240×8-bit) | ~20 (要再合成で確認) |
| fb_test BD (MicroBlaze-V LMB 16KB / VDMA ラインバッファ等) | ~6 |
| ILA ila_cam (5 probe / 49 bit, depth 1024) | ~2 |
| **合計** | **~28 / 50 (要再合成で確認)** |

> 12-bit RGB444 時の合成結果は 44.5 / 50 (89%, ILA 除く)。8-bit 化で約 18 BRAM36 減る見込み。

---

## ILA デバッグ

Vivado の BASIC ライセンスでは **ILA 1 個 / 5 プローブ以内** に制限されるため、
`ila_cam` 1 個に関連信号を連結して割り当てている。
サンプリングクロックは MMCM の `pclk` (25 MHz)。cam_pclk ドメインの信号は非同期サンプルになる。

### ila_cam

| probe | 幅 | 内容 |
|-------|----|------|
| 0 | 8 | `cam_d` カメラ生データ |
| 1 | 4 | `{cam_vsync, cam_href, fb_we, byte_phase}` |
| 2 | 17 | `fb_waddr` BRAM 書き込みアドレス (0-76799) |
| 3 | 8 | `fb_wdata` BRAM 書き込みデータ (8-bit 輝度) |
| 4 | 12 | `{vga_hs, vga_vs, ddr3_calib_done, sw3, pixel_out[7:0]}` |

- debug hub は `clk100` に接続 (JTAG クロック 15 MHz の 2.5 倍以上が必要。pclk のままだと "ILA waveform corrupted" になる)。
- Hardware Manager では probe を右クリックして Bus を分割・リネームすると見やすい。

---

## シミュレーション

カメラ → VGA 経路は `cam_mono_tb` で検証済み (PASS)。

```
xvlog cam_mono_tb.v vga_top.v ov7670_if.v fb_reader.v vga_mono.v ov7670_model.v glbl.v
xelab -L unisims_ver cam_mono_tb glbl -s cam_mono_tb
xsim cam_mono_tb -R
```

```
[TB] framebuffer check: 0 / 76800 mismatches
[TB] VGA output check: 76800 pixels, avg y = 127.00, avg out*16 = 126.18
[TB] *** PASS ***
```

- 検査内容: フレームバッファ全画素 / pixel_out の座標整合 / R=G=B / ディザ範囲 / ディザ前後の平均輝度 (1 LSB 以内)
- 初期化時間短縮のため TB がモデルの COM7 を 0x10 に保持する
- テストパターン経路, SW1 (UYVY), AGC 設定は未検証
- `fb_test_tb.sv` は DDR3 モデルと VDMA 設定がないため DDR3 経路は確認できない
- `vga_top_tb.v` は古く、現在の vga_top のポートと合わない (使用不可)

---

## ビルド手順

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

fb_test の配線を作り直す場合は `source {D:/xlinix/vga_camera/fix_fb_test_bd.tcl}` を実行する。

---

## 動作確認

1. LD0 点灯 → PLL ロック確認
2. 約 0.3 秒後に LD1 点灯 → OV7670 初期化 & PID 読み出し成功 (0x76)
3. LD2 点灯 → OV7670 通信失敗 (SIOD プルアップ / 配線確認)
4. VGA モニタの左上 320×240 にモノクロのカメラ映像が表示される
5. SW0 ON → 階調バー、さらに SW2 ON → ランプでディザを確認
6. 画像が縞模様やざらつきになる場合は SW1 を ON (カメラが UYVY 順の可能性)

---

## 既知の制約 / 今後の課題

- 8-bit 版の合成・実機確認が未実施 (BRAM 使用量とタイミングを要確認)
- 実機カメラのバイト順 (YUYV / UYVY) が未確認
- フレームバッファは 1 面のみのため、速い動きでテアリングが出る
- キャプチャは行・列の上限を確認していない (QVGA 前提)
- fb_test 用の MicroBlaze-V ファームウェアが未作成
- カメラを VDMA S2MM につなぎ、DDR3 経由で表示する (cam_stream ポートを作り直す)
- `constraints.xdc` のスイッチのコメントと `vga_top_tb.v` が古いまま
