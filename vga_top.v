`timescale 1ns / 1ps
`default_nettype none
// =============================================================================
// vga_top.v  -  VGA カメラ トップレベル (Arty A7-35T)
// =============================================================================
// ピクセルデータパス (8-bit モノクロ):
//
//   [OV7670]
//     cam_d[7:0] (YUV422 YUYV, 2byte/pixel, QVGA 320×240)
//       │  cam_pclk ドメイン
//       ▼
//   [ov7670_if / ov7670_capture]
//     輝度 Y (1 バイト目) を取り出し 8-bit で書き込み
//       │  fb_wclk(=cam_pclk), fb_we, fb_waddr, fb_wdata[7:0]
//       ▼
//   [fb_reader]  ← BRAM デュアルポート (320×240×8 bit = 76,800 byte)
//       │  pclk ドメイン: hpos/vpos/active (vga_mono から)
//       │  アドレス = vpos×320 + hpos (左上 320×240 等倍)
//       │  レイテンシ 2 サイクル
//       ▼
//   pixel_out[7:0]
//       │
//       ▼
//   4×4 Bayer ディザ (8bit → 4bit) → vga_r/g/b [3:0] に同値出力
//
// タイミングパス:
//   [vga_mono] → hpos/vpos/active (0 delay) → fb_reader のアドレス生成
//   [vga_mono] → hsync/vsync (1 cycle)
//              + vga_top で +1 cycle 遅延 = 計 2 cycle
//              → pixel_out のレイテンシ (2 cycle) と位相一致
//
// クロックドメイン:
//   clk (100 MHz) : システム / SCCB / XCLK 生成
//   pclk ( 25 MHz): VGA 出力 / BRAM 読み出し (MMCM 生成)
//   cam_pclk      : OV7670 ピクセルクロック / BRAM 書き込み
// =============================================================================

module vga_top (
    // ── システム ──────────────────────────────────────────
    input  wire        clk,        // 100 MHz (Arty A7-35T: E3)
    input  wire        btn_rst,    // リセットボタン (High=リセット, BTN0: D9)

    // ── OV7670 カメラ ─────────────────────────────────────
    output wire        cam_xclk,   // カメラ入力クロック  (25 MHz)
    input  wire        cam_pclk,   // ピクセルクロック    (OV7670 出力)
    input  wire        cam_vsync,  // 垂直同期            (OV7670 出力)
    input  wire        cam_href,   // 水平参照            (OV7670 出力)
    input  wire [7:0]  cam_d,      // ピクセルデータ      (OV7670 出力)
    output wire        cam_sioc,   // SCCB クロック
    inout  wire        cam_siod,   // SCCB データ (4.7kΩ プルアップ必須)
    output wire        cam_rst_n,  // カメラリセット (負論理)
    output wire        cam_pwdn,   // パワーダウン   (Low=通常動作)

    // ── VGA 出力 (Pmod VGA 4-bit/ch) ─────────────────────
    output wire        vga_hs,     // 水平同期
    output wire        vga_vs,     // 垂直同期
    output wire [3:0]  vga_r,      // 赤   (RGB444 上位ニブル)
    output wire [3:0]  vga_g,      // 緑
    output wire [3:0]  vga_b,      // 青

    // ── ステータス LED ────────────────────────────────────
    output wire [3:0]  led,        // [0]=PLL lock, [1]=init_done, [2]=frame_start, [3]=busy

    // ── テストモード ──────────────────────────────────────
    input  wire        sw_test,    // SW0: High=テストパターン表示
    input  wire        sw_raw,     // SW1: High=cam_d[7:4]直接出力
    input  wire        sw_mono,    // SW2: High=モノクロ階調 / Low=RGBカラーバー
    input  wire        sw3,        // SW3: High=fb_test (BD) の映像を VGA に出力

    // ── DDR3 (fb_test 内 MIG, 8-bit 構成) ─────────────────
    //    ピン配置 / IOSTANDARD は MIG IP の XDC が付与する (mig_b.prj)
    inout  wire [7:0]  ddr3_dq,
    inout  wire [0:0]  ddr3_dqs_p,
    inout  wire [0:0]  ddr3_dqs_n,
    output wire [13:0] ddr3_addr,
    output wire [2:0]  ddr3_ba,
    output wire        ddr3_ras_n,
    output wire        ddr3_cas_n,
    output wire        ddr3_we_n,
    output wire        ddr3_reset_n,
    output wire [0:0]  ddr3_ck_p,
    output wire [0:0]  ddr3_ck_n,
    output wire [0:0]  ddr3_cke,
    output wire [0:0]  ddr3_cs_n,
    output wire [0:0]  ddr3_dm,
    output wire [0:0]  ddr3_odt
);

    // =========================================================================
    // 1. クロック生成 (MMCM: 100 MHz → 25 MHz)
    // =========================================================================
    wire pclk;          // 25 MHz ピクセルクロック
    wire pll_locked;
    wire clkfb;
    wire pclk_mmcm;
    wire clk1;
    wire clk100;

    MMCME2_BASE #(
        .BANDWIDTH        ("OPTIMIZED"),
        .CLKFBOUT_MULT_F  (10.000),   // VCO = 100 × 10 = 1000 MHz
        .CLKFBOUT_PHASE   (0.0),
        .CLKIN1_PERIOD    (10.0),     // 100 MHz = 10 ns
        .CLKOUT0_DIVIDE_F (40.000),   // 1000 / 40 = 25 MHz
        .CLKOUT0_DUTY_CYCLE(0.5),
        .CLKOUT0_PHASE    (0.0),
        .CLKOUT1_DIVIDE   (10),       // 1000 / 10 = 100 MHz (CLKOUT1 は整数分周のみ)
        .CLKOUT1_DUTY_CYCLE(0.5),
        .CLKOUT1_PHASE    (0.0),
        .DIVCLK_DIVIDE    (1),
        .REF_JITTER1      (0.010),
        .STARTUP_WAIT     ("FALSE")
    ) u_mmcm (
        .CLKOUT0  (pclk_mmcm),
        .CLKOUT1  (clk1),
        .CLKFBOUT (clkfb),
        .CLKIN1   (clk),
        .PWRDWN   (1'b0),
        .RST      (btn_rst),
        .CLKFBIN  (clkfb),
        .LOCKED   (pll_locked)
    );

    BUFG u_pclk_bufg (.I(pclk_mmcm), .O(pclk));
    BUFG u_clk100_bufg (.I(clk1), .O(clk100));

    // =========================================================================
    // 1a. fb_test ブロックデザイン (MicroBlaze-V / VDMA / MIG / TPG / VTC)
    //     BD 内部構成は fix_fb_test_bd.tcl を参照
    //     (TPG → VDMA S2MM → DDR3 → VDMA MM2S → vid_out)
    //     CLK には MMCM の 100 MHz (BUFG 後) を入力する。
    //     ※ BD 内 clk_wiz_0 の PRIM_SOURCE は "Global_buffer" (= 入力バッファ無し)
    //       にすること。既定の "Single_ended_clock_capable_pin" のままだと
    //       BUFG 出力に IBUF が挿入され配置配線でエラーになる。
    //     出力 (RGB/HSYNC/VSYNC) は BD 内ピクセルクロックドメイン。
    //     VGA ピンへは静的な SW3 の MUX を経由するだけなので CDC は不要。
    // =========================================================================
    wire [23:0] fbt_rgb;          // AXI4-Stream Video 順: [23:16]=R [15:8]=B [7:0]=G
    wire        fbt_hsync;        // v_axi4s_vid_out 出力 (データと位相一致, High アクティブ)
    wire        fbt_vsync;
    wire        fbt_vtc_hsync;    // v_tc 直出し (デバッグ用)
    wire        fbt_vtc_vsync;
    wire [31:0] fbt_status;
    wire        ddr3_calib_done;  // MIG init_calib_complete

    fb_test fb_test_i (
        .CLK                 (clk100),
        .RESET               (btn_rst),
        // ── 映像出力 ──
        .RGB                 (fbt_rgb),
        .HSYNC               (fbt_hsync),
        .VSYNC               (fbt_vsync),
        .HSYNC_1             (fbt_vtc_hsync),
        .VSYNC_1             (fbt_vtc_vsync),
        .status              (fbt_status),
        // ── MIG (クロック/リセットは BD 内 clk_wiz_0 / proc_sys_reset_0 から供給) ──
        .init_calib_complete (ddr3_calib_done),
        // ── DDR3 ──
        .ddr3_dq             (ddr3_dq),
        .ddr3_dqs_p          (ddr3_dqs_p),
        .ddr3_dqs_n          (ddr3_dqs_n),
        .ddr3_addr           (ddr3_addr),
        .ddr3_ba             (ddr3_ba),
        .ddr3_ras_n          (ddr3_ras_n),
        .ddr3_cas_n          (ddr3_cas_n),
        .ddr3_we_n           (ddr3_we_n),
        .ddr3_reset_n        (ddr3_reset_n),
        .ddr3_ck_p           (ddr3_ck_p),
        .ddr3_ck_n           (ddr3_ck_n),
        .ddr3_cke            (ddr3_cke),
        .ddr3_cs_n           (ddr3_cs_n),
        .ddr3_dm             (ddr3_dm),
        .ddr3_odt            (ddr3_odt)
    );

    // RGB888 → 8-bit 輝度 Y = (77R + 150G + 29B) / 256 (BT.601 近似)
    //   BD 側は別クロック (BD 内 pclk) なのでディザは掛けず上位 4bit を出力
    wire [7:0]  fbt_r8 = fbt_rgb[23:16];
    wire [7:0]  fbt_b8 = fbt_rgb[15:8];
    wire [7:0]  fbt_g8 = fbt_rgb[7:0];
    wire [15:0] fbt_ysum = fbt_r8 * 8'd77 + fbt_g8 * 8'd150 + fbt_b8 * 8'd29;
    wire [3:0]  fbt_y4   = fbt_ysum[15:12];
    wire       fbt_hs = ~fbt_hsync;   // v_tc GEN_HSYNC_POLARITY = High
    wire       fbt_vs = ~fbt_vsync;   // v_tc GEN_VSYNC_POLARITY = High

    // =========================================================================
    // 2. リセット生成
    //    btn_rst High または PLL アンロック で rst アサート
    //    各クロックドメインで同期化
    // =========================================================================
    // --- システムクロックドメイン (clk) ---
    reg [3:0] rst_sys_sr;
    always @(posedge clk or posedge btn_rst) begin
        if (btn_rst)
            rst_sys_sr <= 4'hF;
        else
            rst_sys_sr <= {rst_sys_sr[2:0], ~pll_locked};
    end
    wire rst_n_sys = ~rst_sys_sr[3];

    // --- ピクセルクロックドメイン (pclk) ---
    reg [3:0] rst_pclk_sr;
    always @(posedge pclk or posedge btn_rst) begin
        if (btn_rst)
            rst_pclk_sr <= 4'hF;
        else
            rst_pclk_sr <= {rst_pclk_sr[2:0], ~pll_locked};
    end
    wire rst_n_pclk = ~rst_pclk_sr[3];

    // cam_pclk は非 CCIO ピン (D4) 入力のため BUFG でグローバルクロックに昇格
    // CLOCK_DEDICATED_ROUTE FALSE は IBUF→BUFG 間の非専用ルーティングを許可
    wire cam_pclk_g;
    BUFG u_cam_bufg (.I(cam_pclk), .O(cam_pclk_g));

    // --- カメラクロックドメイン (cam_pclk_g) ---
    reg [3:0] rst_cam_sr;
    always @(posedge cam_pclk_g or posedge btn_rst) begin
        if (btn_rst)
            rst_cam_sr <= 4'hF;
        else
            rst_cam_sr <= {rst_cam_sr[2:0], ~pll_locked};
    end
    wire rst_n_cam = ~rst_cam_sr[3];

    // =========================================================================
    // 3. OV7670 インターフェース
    // =========================================================================
    wire        fb_wclk;
    wire        fb_we;
    wire [16:0] fb_waddr;
    wire [7:0]  fb_wdata;   // 8-bit 輝度
    wire        init_done;
    wire        frame_start_cam;   // cam_pclk ドメイン
    wire        sio_test_pass;
    wire        sio_test_fail;
    wire [1:0]  dbg_pat_cnt;
    wire        dbg_byte_phase;
    wire [7:0]  dbg_pat_b1;
    wire [7:0]  dbg_pat_b2;

    ov7670_if #(
        .SYS_CLK_HZ (100_000_000),
        .XCLK_HZ    ( 25_000_000),
        .SCCB_CLK_HZ(    100_000)
    ) u_ov7670 (
        .clk        (clk),
        .rst_n      (rst_n_sys),   // clk ドメイン: SCCB/XCLK 生成用
        .cam_rst_i_n  (rst_n_cam),   // cam_pclk ドメイン: キャプチャ回路用
        // OV7670 ピン
        .xclk       (cam_xclk),
        .pclk       (cam_pclk_g),
        .vsync      (cam_vsync),
        .href       (cam_href),
        .d          (cam_d),
        .sioc       (cam_sioc),
        .siod       (cam_siod),
        .cam_rst_o_n  (cam_rst_n),
        .cam_pwdn   (cam_pwdn),
        // フレームバッファ書き込み
        .fb_wclk    (fb_wclk),
        .fb_we      (fb_we),
        .fb_waddr   (fb_waddr),
        .fb_wdata   (fb_wdata),
        // ステータス
        .init_done      (init_done),
        .frame_start    (frame_start_cam),
        .sio_test_pass  (sio_test_pass),
        .sio_test_fail  (sio_test_fail),
        .dbg_pat_cnt    (dbg_pat_cnt),
        .dbg_byte_phase (dbg_byte_phase),
        .dbg_pat_b1     (dbg_pat_b1),
        .dbg_pat_b2     (dbg_pat_b2),
        // テストモード
        .raw_mode   (sw_raw),
        .sw3        (1'b0)      // SW3 は fb_test 映像選択に転用 (キャプチャの緑塗り潰しは無効)
    );

    // =========================================================================
    // 4. VGA タイミング生成 (vga_mono はタイミング専用)
    //    pixel_in は使用しない (1'b0 固定)
    //    ピクセルデータは fb_reader から直接取得する
    // =========================================================================
    wire [9:0]  hpos;       // 現在の水平座標 (0-639)
    wire [9:0]  vpos;       // 現在の垂直座標 (0-479)
    wire        active;     // 表示有効期間
    wire        hsync_raw;  // 水平同期 (1 サイクル遅延)
    wire        vsync_raw;  // 垂直同期 (1 サイクル遅延)

    vga_mono u_vga (
        .pclk     (pclk),
        .rst_n    (rst_n_pclk),
        .pixel_in (1'b0),       // タイミング生成専用 — ピクセルは fb_reader から取得
        .hpos     (hpos),
        .vpos     (vpos),
        .active   (active),
        .hsync    (hsync_raw),
        .vsync    (vsync_raw),
        .vga_r    (),           // 未使用 (pixel_out を直接 VGA へ出力)
        .vga_g    (),
        .vga_b    ()
    );

    // =========================================================================
    // 5. フレームバッファ
    //    書き込み: ov7670_if (cam_pclk ドメイン)
    //    読み出し: vga_mono の hpos/vpos/active から 2 サイクル後に pixel_out
    // =========================================================================
    wire [7:0]  pixel_out;  // BRAM 読み出し 8-bit 輝度 (2 サイクル遅延)

    fb_reader #(
        .H_ACTIVE(640),
        .V_ACTIVE(480)
    ) u_fb (
        // ── 読み出しポート (pclk ドメイン) ──
        .pclk     (pclk),
        .rst_n    (rst_n_pclk),
        .hpos     (hpos),       // ← vga_mono
        .vpos     (vpos),       // ← vga_mono
        .active   (active),     // ← vga_mono
        .pixel_out(pixel_out),  // → VGA 出力 (2 サイクル後)
        // ── 書き込みポート (cam_pclk ドメイン) ──
        .wclk     (fb_wclk),    // = cam_pclk
        .we       (fb_we),      // ← ov7670_if
        .waddr    (fb_waddr),   // ← ov7670_if (byte addr: vpos*80 + hpos/8)
        .wdata    (fb_wdata)    // ← ov7670_if (8-bit 輝度)
    );

    // =========================================================================
    // 6. VGA 出力
    //    hsync/vsync : vga_mono (1 cycle) + ここで +1 cycle = 2 cycle 遅延
    //    pixel_out   : fb_reader 2 cycle 遅延 → 位相一致
    // =========================================================================

    // hsync/vsync を 1 サイクル追加遅延 (fb_reader の 2 サイクル遅延に合わせる)
    reg hsync_d, vsync_d;
    always @(posedge pclk or negedge rst_n_pclk) begin
        if (!rst_n_pclk) begin
            hsync_d <= 1'b1;
            vsync_d <= 1'b1;
        end else begin
            hsync_d <= hsync_raw;
            vsync_d <= vsync_raw;
        end
    end

    // SW3=1 のときは fb_test (BD) の映像・同期を出力
    //   実際のピン出力は 6c の出力レジスタ (IOB FF) 経由
    wire out_hs = sw3 ? fbt_hs : hsync_d;
    wire out_vs = sw3 ? fbt_vs : vsync_d;

    // =========================================================================
    // 6a. テストパターン生成 (8-bit モノクロ)
    // ── 階調バー (sw_mono=0): hpos[8:6] で 64px × 8 段 (白 → 黒) ─────────────
    // ── ランプ   (sw_mono=1): hpos に比例する 8-bit 水平グラデーション ─────────
    //    y ≈ hpos × 0.39 (0〜249) — ディザの効果確認用
    //  カメラ映像 (pixel_out) と同じ 2 サイクル遅延に揃えてから出力段へ
    // =========================================================================
    wire [2:0] stripe   = ~hpos[8:6];                       // 0 列目が白
    wire [7:0] bar_y    = {stripe, stripe, stripe[2:1]};    // 3bit → 8bit 拡張
    wire [9:0] ramp_sum = {2'b0, hpos[9:2]} + {3'b0, hpos[9:3]} + {6'b0, hpos[9:6]};
    wire [7:0] ramp_y   = ramp_sum[7:0];
    wire [7:0] test_y0  = active ? (sw_mono ? ramp_y : bar_y) : 8'h00;

    reg [7:0] test_y_d1, test_y_d2;
    reg [1:0] dx_d1, dx_d2, dy_d1, dy_d2;   // ディザ用座標 (下位 2bit)
    always @(posedge pclk) begin
        test_y_d1 <= test_y0;   test_y_d2 <= test_y_d1;
        dx_d1     <= hpos[1:0]; dx_d2     <= dx_d1;
        dy_d1     <= vpos[1:0]; dy_d2     <= dy_d1;
    end

    // =========================================================================
    // 6b. 8-bit 輝度 → VGA 出力 (PmodVGA は各色 4bit)
    //     4×4 Bayer 順序ディザで 8bit → 4bit に落とし、R/G/B に同じ値を出す。
    //     y4 = y[7:4] + (y[3:0] > M[dy][dx] ? 1 : 0)  (15 で飽和)
    // =========================================================================
    // ── 出力 MUX ─────────────────────────────────────────────────────────
    // sw_test=1: テストパターン (sw_mono で種別選択)
    // sw_test=0: カメラ映像 (8-bit Y)
    // sw3=1    : fb_test (BD) 映像を輝度に変換して出力 (最優先)
    wire [7:0] mono_y = sw_test ? test_y_d2 : pixel_out;

    function [3:0] bayer4;
        input [1:0] x, y;
        case ({y, x})
            4'b00_00: bayer4 =  0;  4'b00_01: bayer4 =  8;  4'b00_10: bayer4 =  2;  4'b00_11: bayer4 = 10;
            4'b01_00: bayer4 = 12;  4'b01_01: bayer4 =  4;  4'b01_10: bayer4 = 14;  4'b01_11: bayer4 =  6;
            4'b10_00: bayer4 =  3;  4'b10_01: bayer4 = 11;  4'b10_10: bayer4 =  1;  4'b10_11: bayer4 =  9;
            4'b11_00: bayer4 = 15;  4'b11_01: bayer4 =  7;  4'b11_10: bayer4 = 13;  4'b11_11: bayer4 =  5;
        endcase
    endfunction

    wire       dith_up = (mono_y[3:0] > bayer4(dx_d2, dy_d2)) && (mono_y[7:4] != 4'hF);
    wire [3:0] mono_y4 = mono_y[7:4] + {3'b000, dith_up};

    wire [3:0] out_y4 = sw3 ? fbt_y4 : mono_y4;

    // =========================================================================
    // 6c. 出力レジスタ (IOB FF)
    //     組み合わせ回路のままピンに出すと、ビットごとの遅延差 (数 ns) により
    //     画素の切り替わりでグリッチが出て、ランプ等で縦筋になる。
    //     RGB・同期を同じ pclk で 1 段レジスタし、全ピンの変化タイミングを揃える。
    //     (RGB と同期の両方を 1 サイクル遅らせるので相対位相は変わらない)
    //     R/G/B は同じ値だが、各ピンの IOB に入れるため別レジスタにする。
    // =========================================================================
    (* IOB = "TRUE", keep = "true" *) reg [3:0] vga_r_q = 4'h0;
    (* IOB = "TRUE", keep = "true" *) reg [3:0] vga_g_q = 4'h0;
    (* IOB = "TRUE", keep = "true" *) reg [3:0] vga_b_q = 4'h0;
    (* IOB = "TRUE", keep = "true" *) reg       vga_hs_q = 1'b1;
    (* IOB = "TRUE", keep = "true" *) reg       vga_vs_q = 1'b1;
    always @(posedge pclk) begin
        vga_r_q  <= out_y4;
        vga_g_q  <= out_y4;
        vga_b_q  <= out_y4;
        vga_hs_q <= out_hs;
        vga_vs_q <= out_vs;
    end
    assign vga_r  = vga_r_q;
    assign vga_g  = vga_g_q;
    assign vga_b  = vga_b_q;
    assign vga_hs = vga_hs_q;
    assign vga_vs = vga_vs_q;

    // =========================================================================
    // 7. ILA デバッグ (合成時のみ有効 — シミュレーションでは無視)
    // =========================================================================
    // ── ila_cam : 唯一の ILA (BASIC ライセンス制限: ILA 1 個 / 5 プローブ以内) ──
    //   プローブ数を抑えるため関連信号を連結している。
    //   Hardware Manager では probe を右クリック → Bus を分割/リネームすると見やすい。
    //
    // probe0 [7:0]  : cam_d                       — カメラ生データ
    // probe1 [3:0]  : {cam_vsync, cam_href, fb_we, byte_phase}
    //                  [3]=VSYNC [2]=HREF [1]=BRAM 書き込み [0]=0:byte1/1:byte2
    // probe2 [16:0] : fb_waddr                    — BRAM 書き込みアドレス (0〜76799)
    // probe3 [7:0]  : fb_wdata                    — BRAM 書き込みデータ (8-bit 輝度)
    // probe4 [11:0] : {vga_hs, vga_vs, ddr3_calib_done, sw3, pixel_out[7:0]}
    //                  [11]=HS [10]=VS [9]=DDR3 キャリブ完了 [8]=SW3 [7:0]=BRAM 読み出し
    //
    // clk は MMCM の pclk (25 MHz)。cam_pclk ドメインの信号は非同期サンプルになるが、
    // カメラ停止中でも ILA が確実に動くよう安定クロックを使う。
    // debug hub (dbg_hub) は constraints.xdc で clk100 (100 MHz) に接続している。

    // MIG ui_clk ドメインの init_calib_complete を pclk に 2FF 同期
    // (1 段目への false path は constraints.xdc)
    (* ASYNC_REG = "TRUE" *) reg [1:0] ddr3_calib_sync;
    always @(posedge pclk) ddr3_calib_sync <= {ddr3_calib_sync[0], ddr3_calib_done};
    wire ddr3_calib_done_pclk = ddr3_calib_sync[1];

    ila_cam u_ila_cam (
        .clk    (pclk),
        .probe0 (cam_d),
        .probe1 ({cam_vsync, cam_href, fb_we, dbg_byte_phase}),
        .probe2 (fb_waddr),
        .probe3 (fb_wdata),
        .probe4 ({vga_hs, vga_vs, ddr3_calib_done_pclk, sw3, pixel_out})
    );

    // =========================================================================
    // 6. ステータス LED
    // =========================================================================
    // frame_start_cam を pclk ドメインへ同期
    reg [1:0] fs_sync;
    always @(posedge pclk or negedge rst_n_pclk) begin
        if (!rst_n_pclk)
            fs_sync <= 2'b00;
        else
            fs_sync <= {fs_sync[0], frame_start_cam};
    end
    wire frame_start_pclk = fs_sync[0] & ~fs_sync[1];  // ワンショット

    // frame_start を ~250 ms 延長して LED で視認可能にする
    // 25 MHz × 2^23 ≈ 335 ms
    reg [22:0] fs_stretch_cnt;
    reg        fs_led;
    always @(posedge pclk or negedge rst_n_pclk) begin
        if (!rst_n_pclk) begin
            fs_stretch_cnt <= 0;
            fs_led         <= 1'b0;
        end else if (frame_start_pclk) begin
            fs_stretch_cnt <= 23'h7FFFFF;
            fs_led         <= 1'b1;
        end else if (fs_stretch_cnt != 0) begin
            fs_stretch_cnt <= fs_stretch_cnt - 1;
        end else begin
            fs_led <= 1'b0;
        end
    end

    assign led[0] = pll_locked;      // PLL ロック確認
    assign led[1] = sio_test_pass;   // SIO テスト合格 (OV7670 PID=0x76 確認済み)
    assign led[2] = sio_test_fail;   // SIO テスト不合格
    assign led[3] = ~rst_n_pclk;     // リセット中

endmodule
`default_nettype wire
