# ビルド・書き込み手順

Arty A7-35T + OV7670 + PmodVGA + Ethernet の vga_camera を、ソースからフラッシュ (QSPI ブート) まで作る手順。
詳しい説明は [README.md](README.md) を参照。

- ツール: Vivado / Vitis 2026.1 (`C:\AMDDesignTools\2026.1`)
- コマンドはすべて PowerShell で、リポジトリ直下 (`D:\xlinix\vga_camera`) で実行する
- ボードのジャンパ JP1 は SPI (QSPI ブート) にしておく

## 全体の流れ

| # | 作業 | いつやるか |
|---|------|-----------|
| 1 | BD スクリプトの実行 | 初回、BD を作り直したとき |
| 2 | ビットストリームの作成 | HDL / BD / 制約を変えたとき |
| 3 | XSA の出力 | 2 の後 |
| 4 | ファームウェアのビルド | 3 の後、`sw/src` を変えたとき |
| 5a | JTAG で実行 (開発用) | ファームウェアを試すとき。電源を切ると消える |
| 5b | フラッシュに書き込み | 電源投入で自動起動させるとき |

ファームウェアだけ直したときは 4 → 5a (試す) → 5b (残す)。

---

## 1. BD スクリプト (初回のみ)

Vivado で `vga_camera.xpr` を開き、Tcl Console で順に実行する (どれも何度実行してもよい)。

```tcl
source {D:/xlinix/vga_camera/cam_ddr_bd.tcl}
source {D:/xlinix/vga_camera/eth_bd.tcl}
source {D:/xlinix/vga_camera/qspi_bd.tcl}
source {D:/xlinix/vga_camera/create_ila.tcl}
```

| スクリプト | 内容 |
|-----------|------|
| `cam_ddr_bd.tcl` | fb_test にカメラ → DDR3 用のポートを追加 |
| `eth_bd.tcl` | EthernetLite / Timer / INTC / UARTLite、MicroBlaze-V のキャッシュ (各 32 KB) |
| `qspi_bd.tcl` | AXI Quad SPI (XIP, フラッシュ読み出し用) |
| `create_ila.tcl` | ILA IP の生成 |

初回だけ、インクリメンタルコンパイルを無効にする (BASIC ライセンスでは 12-29181 エラーになるため):

```tcl
set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs synth_1]
set_property INCREMENTAL_CHECKPOINT {} [get_runs synth_1]
set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs impl_1]
set_property INCREMENTAL_CHECKPOINT {} [get_runs impl_1]
```

## 2. ビットストリーム

Vivado の Tcl Console で:

```tcl
reset_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
```

- 出力: `vga_camera.runs/impl_1/vga_top.bit`
- 実装の strategy は `Performance_ExplorePostRoutePhysOpt` (既定のままだと SYSCLK 100 MHz が満たせない)
- 終わったらタイミングを確認する。MIG 内部 (u_ddr_phy_init, clk_pll_i) の 1 パスの小さな違反 (約 -0.01〜-0.09 ns) は以前から出ているもの。それ以外の違反、特に SYSCLK (sysclk_fb_test_clk_wiz_0_0) が負なら要対処

## 3. XSA の出力

Vivado の Tcl Console で:

```tcl
source {D:/xlinix/vga_camera/sw/export_xsa.tcl}
```

出力: `firmware/vga_top.xsa`

## 4. ファームウェアのビルド

```powershell
cmd /c "chcp 65001 >nul && C:\AMDDesignTools\2026.1\Vitis\bin\vitis.bat -s sw\build_fw.py"
```

- 出力: `firmware/vga_web/build/vga_web.elf`
- `firmware/` は毎回作り直す生成物 (git 管理外)
- "already in use" で失敗したら、残っている vitis-server を終了してからやり直す:

```powershell
taskkill /F /IM java.exe
```

- `PermissionError: [WinError 32]` で失敗したら、`firmware/` の中をカレントディレクトリにしているシェルやエクスプローラーが無いか確認する

## 5a. JTAG で実行 (開発用)

Vivado の Hardware Manager を閉じてから:

```powershell
C:\AMDDesignTools\2026.1\Vitis\bin\xsdb.bat sw\run_fw.tcl
```

- FPGA に impl_1 のビットストリームを書き込み、ELF を DDR3 にロードして実行する
- 電源を切る、PROG を押す、FPGA を書き直すと消える (フラッシュの内容で起動し直す)

## 5b. フラッシュに書き込み (QSPI ブート)

Vivado の Hardware Manager を閉じてから:

```powershell
C:\AMDDesignTools\2026.1\Vivado\bin\vivado.bat -mode batch -nojournal -nolog -source sw\flash.tcl
```

`sw/flash.tcl` がやること:

1. BRAM ブートローダ (`sw/boot`) をビルド → `firmware/boot/boot.elf`
2. impl_1 のビットストリームの BRAM にブートローダを埋め込む (updatemem) → `firmware/boot.bit`
3. vga_web.elf からファームウェアイメージを作る → `firmware/fw_img.bin`
4. フラッシュイメージを作る → `firmware/flash.mcs`
5. フラッシュ (MT25QL128) に書き込んで照合し、フラッシュから FPGA を起動し直す

`-tclargs noprog` を付けると 4 まで (書き込みなし)。

```powershell
C:\AMDDesignTools\2026.1\Vivado\bin\vivado.bat -mode batch -nojournal -nolog -source sw\flash.tcl -tclargs noprog
```

フラッシュの配置:

| アドレス | 内容 |
|---------|------|
| 0x00_0000 | ビットストリーム (ブートローダ入り) |
| 0x80_0000 | ファームウェアイメージ (ヘッダ 32 バイト + プログラム) |

ビットストリームかファームウェアのどちらかを作り直したら、そのつど 5b をやり直す。

---

## 動作確認

1. USB-UART (COM ポート, 115200 bps, 8N1) を開いて電源を入れる (または PROG ボタン)
2. 次のように表示される:

   ```
   [boot] vga_camera QSPI bootloader
   [boot] flash ready after 0x00000001 dummy reads
   [boot] copying 0x00028B24 bytes to 0x81000000
   [boot] jump to 0x81000000

   ----- vga_camera HTTP server -----
   ...
   [phy] link up: 100M full-duplex (PHYSTS=0115)
   ...
   Board IP: 192.168.11.169
   ...
   HTTP server started @ port 80
   ```

3. ブラウザで `http://<Board IP>/` を開くとカメラ画像が表示され、更新され続ける。顔が映ると緑の枠が出る (検出は 1〜4 秒に 1 回なので枠は少し遅れる)。`http://<Board IP>/faces` で検出結果の JSON も見られる
4. VGA モニタにもカメラ映像が出る (ファームウェアなしでも出る)

## うまくいかないとき

| 症状 | 確認すること |
|------|-------------|
| UART に `[boot] no image at flash 0x00800000` | ファームウェアがフラッシュに無い。5b をやり直す |
| UART に `[boot] bad ... checksum` | フラッシュの内容が壊れている / 古い。5b をやり直す |
| UART に何も出ない | JP1 が SPI か、フラッシュのビットストリームが今のものか (5b をやり直す) |
| `[phy] waiting for link...` のまま | LAN ケーブル / スイッチ側のリンク LED |
| ブラウザで開けない | UART の Board IP を確認。DHCP が取れないと 192.168.1.10 固定になる |
| 顔に枠が出ない | 顔が正面を向いているか、画面の幅の 1/8 (80 画素) 以上の大きさで映っているか。UART の `[face] #N: k face(s)` を見る |
| JTAG 実行 (5a) の後、電源を入れ直したら古い動作に戻った | 正常。5a は DDR3 にしか入らない。残すには 5b |
