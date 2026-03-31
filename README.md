# vga_camera — OV7670 + Digilent PmodVGA on Arty A7-35T

OV7670 カメラで撮影した QVGA (320×240) 映像を Digilent PmodVGA で VGA (640×480) モニタに表示する Vivado プロジェクトです。

---

## ハードウェア構成

| 部品 | 詳細 |
|------|------|
| FPGA ボード | Digilent Arty A7-35T (XC7A35T-CSG324) |
| カメラ | OV7670 (RGB444, QVGA 320×240) |
| VGA 出力 | Digilent PmodVGA (12-bit RGB444) |

---

## システム構成

```
[OV7670 Camera]
  PCLK/HREF/VSYNC/D[7:0]
        │  cam_pclk ドメイン (25 MHz)
        ▼
[ov7670_if / ov7670_capture]
  RGB444 デコード → フレームバッファ書き込み
  SCCB 初期化 (41 レジスタ) / PID 読み出しテスト
        │  fb_wclk(=cam_pclk), fb_we, fb_waddr[16:0], fb_wdata[11:0]
        ▼
[fb_reader]  ← BRAM デュアルポート (320×240 × 12-bit = 76,800 エントリ)
        │  pclk ドメイン (25 MHz, MMCM)
        │  hpos/vpos → raddr = vpos×320 + hpos (左上 320×240 等倍表示)
        │  パイプライン遅延 2 サイクル
        ▼
[vga_top 出力 MUX]
  sw_test=0: カメラ映像 (pixel_out)
  sw_test=1: テストパターン (カラーバー / RGB グラデーション)
        │
        ▼
[Digilent PmodVGA]
  vga_r[3:0] / vga_g[3:0] / vga_b[3:0] / vga_hs / vga_vs
```

---

## クロックドメイン

| ドメイン | 周波数 | 用途 |
|----------|--------|------|
| `clk` | 100 MHz | システム / SCCB / XCLK 生成 |
| `pclk` | 25 MHz | VGA 出力 / BRAM 読み出し (MMCM 生成) |
| `cam_pclk_g` | 25 MHz | OV7670 ピクセルクロック / BRAM 書き込み (BUFG 経由) |

`cam_pclk` は非 CCIO ピン (JD pin1 = D4) 入力のため `CLOCK_DEDICATED_ROUTE FALSE` + `BUFG` を使用。

---

## モジュール一覧

| ファイル | モジュール | 役割 |
|----------|-----------|------|
| `vga_top.v` | `vga_top` | トップレベル統合 |
| `ov7670_if.v` | `ov7670_if` | カメラインターフェース (XCLK 生成 / SCCB / キャプチャ統合) |
| `ov7670_if.v` | `ov7670_capture` | PCLK ドメインキャプチャ / フレームバッファ書き込み |
| `ov7670_if.v` | `ov7670_init` | SCCB 初期化シーケンサ (41 レジスタ) |
| `ov7670_if.v` | `sccb_master` | SCCB マスタ (3 相書き込み + 2 相読み出し) |
| `fb_reader.v` | `fb_reader` | BRAM フレームバッファ読み出し (320×240 等倍) |
| `vga_mono.v` | `vga_mono` | VGA タイミング生成 (640×480 @ 60 Hz) |
| `constraints.xdc` | — | ピン配置 / タイミング制約 |
| `create_ila.tcl` | — | ILA IP 生成スクリプト |

---

## ピン配置

### スライドスイッチ

| SW | FPGA ピン | 機能 (High=ON) |
|----|-----------|----------------|
| SW0 (`sw_test`) | A8 | テストパターン表示 |
| SW1 (`sw_raw`) | C11 | cam_d[7:4] グレースケール直接出力 |
| SW2 (`sw_mono`) | C10 | テストパターン種別 (ON=RGB グラデーション / OFF=カラーバー) |
| SW3 (`sw3`) | A10 | cam_d にテストパターン挿入 |

### ステータス LED

| LED | 意味 |
|-----|------|
| LD0 | PLL ロック |
| LD1 | SIO テスト合格 (OV7670 PID = 0x76 確認済み) |
| LD2 | SIO テスト不合格 |
| LD3 | リセット中 |

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

> **注意:** JA pin7-10 は物理的に VGA Blue チャンネルに接続されているため、制約ファイルで G/B を入れ替えています。

---

## BRAM 使用量

| 用途 | BRAM36 数 |
|------|-----------|
| フレームバッファ (320×240×12-bit) | ~38 |
| ILA ila_cam (10 probe, depth 1024) | ~2 |
| ILA ila_vga (6 probe, depth 1024) | ~2 |
| **合計** | **~42 / 50 (84%)** |

---

## ILA デバッグ

### ila_cam (cam_pclk_g ドメイン → pclk でキャプチャ)

| probe | 信号 | 幅 | 説明 |
|-------|------|----|------|
| 0 | cam_href | 1 | 水平参照 |
| 1 | cam_vsync | 1 | 垂直同期 |
| 2 | cam_d | 8 | カメラ生データ |
| 3 | fb_we | 1 | BRAM 書き込みイネーブル |
| 4 | fb_waddr | 17 | 書き込みアドレス (0-76799) |
| 5 | fb_wdata | 12 | 書き込みデータ (RGB444) |
| 6 | dbg_pat_cnt | 2 | テストパターンカウンタ |
| 7 | dbg_byte_phase | 1 | バイトフェーズ |
| 8 | dbg_pat_b1 | 8 | テストパターン byte1 |
| 9 | dbg_pat_b2 | 8 | テストパターン byte2 |

### ila_vga (pclk ドメイン)

| probe | 信号 | 幅 | 説明 |
|-------|------|----|------|
| 0 | vga_r | 4 | 赤チャンネル出力 |
| 1 | vga_g | 4 | 緑チャンネル出力 |
| 2 | vga_b | 4 | 青チャンネル出力 |
| 3 | vga_hs | 1 | 水平同期 |
| 4 | vga_vs | 1 | 垂直同期 |
| 5 | pixel_out | 12 | BRAM 読み出し RGB444 (MUX 前) |

### ILA IP 生成手順

```tcl
# Vivado Tcl Console で実行 (既存 IP がある場合は先に削除)
remove_files [get_files -of_objects [get_ips ila_cam] -quiet] -quiet
export_ip_user_files -of_objects [get_ips ila_cam] -no_script -reset -force -quiet
source {D:/xlinix/vga_camera/create_ila.tcl}
```

---

## ビルド手順

1. Vivado で `vga_camera.xpr` を開く
2. ILA IP を生成 (初回またはプローブ変更時):
   ```tcl
   source {D:/xlinix/vga_camera/create_ila.tcl}
   ```
3. **Flow Navigator** → Generate Bitstream
4. Hardware Manager でボードに書き込み

---

## 動作確認

1. LD0 点灯 → PLL ロック確認
2. LD1 点灯 → OV7670 初期化 & PID 読み出し成功 (0x76)
3. LD2 点灯 → OV7670 通信失敗 (SIOD プルアップ / 配線確認)
4. VGA モニタにカメラ映像が左上 320×240 で表示される
5. SW0 ON → カラーバー / グラデーション テストパターン表示
