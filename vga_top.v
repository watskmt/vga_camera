`timescale 1ns / 1ps
// =============================================================================
// vga_top.v  -  VGA カメラ トップレベル (Arty A7-35T)
// =============================================================================
// ピクセルデータパス:
//
//   [OV7670]
//     cam_d[7:0] (RGB565, 2byte/pixel)
//       │  cam_pclk ドメイン
//       ▼
//   [ov7670_if / ov7670_capture]
//     RGB565 → 輝度計算 → 1-bit 変換 → 8pixel/byte パック
//       │  fb_wclk(=cam_pclk), fb_we, fb_waddr, fb_wdata
//       ▼
//   [fb_reader]  ← BRAM デュアルポート (38,400 byte)
//       │  pclk ドメイン: hpos/vpos/active (vga_mono から)
//       │  アドレス = vpos×80 + hpos[9:3], bit_sel = hpos[2:0]
//       │  レイテンシ 2 サイクル
//       ▼
//   pixel_out (1-bit)
//       │
//       ▼
//   vga_r/g/b [3:0] ← 4ビット複製
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
    input  wire        sw3         // SW3: High=cam_d にテストパターン挿入
);

    // =========================================================================
    // 1. クロック生成 (MMCM: 100 MHz → 25 MHz)
    // =========================================================================
    wire pclk;          // 25 MHz ピクセルクロック
    wire pll_locked;
    wire clkfb;
    wire pclk_mmcm;

    MMCME2_BASE #(
        .BANDWIDTH        ("OPTIMIZED"),
        .CLKFBOUT_MULT_F  (10.000),   // VCO = 100 × 10 = 1000 MHz
        .CLKFBOUT_PHASE   (0.0),
        .CLKIN1_PERIOD    (10.0),     // 100 MHz = 10 ns
        .CLKOUT0_DIVIDE_F (40.000),   // 1000 / 40 = 25 MHz
        .CLKOUT0_DUTY_CYCLE(0.5),
        .CLKOUT0_PHASE    (0.0),
        .DIVCLK_DIVIDE    (1),
        .REF_JITTER1      (0.010),
        .STARTUP_WAIT     ("FALSE")
    ) u_mmcm (
        .CLKOUT0  (pclk_mmcm),
        .CLKFBOUT (clkfb),
        .CLKIN1   (clk),
        .PWRDWN   (1'b0),
        .RST      (btn_rst),
        .CLKFBIN  (clkfb),
        .LOCKED   (pll_locked)
    );

    BUFG u_pclk_bufg (.I(pclk_mmcm), .O(pclk));

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
    wire [11:0] fb_wdata;
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
        .sw3        (sw3)
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
    wire [11:0] pixel_out;  // BRAM 読み出し RGB444 (2 サイクル遅延) [11:8]=R [7:4]=G [3:0]=B

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
        .wdata    (fb_wdata)    // ← ov7670_if (12-bit RGB444)
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

    assign vga_hs = hsync_d;
    assign vga_vs = vsync_d;

    // =========================================================================
    // 6a. テストパターン生成
    // ── RGB カラーバー (sw_mono=0): hpos[8:6] で 64px×8本 (EBU 順) ──────────
    //    stripe: 0=白 1=黄 2=シアン 3=緑 4=マゼンタ 5=赤 6=青 7=黒
    // ── モノクロ階調バー (sw_mono=1): 8段グレースケール (各64px) ──────────────
    //    hpos[8:6] → 輝度 0,2,4,6,8,10,12,14 (4-bit)
    // =========================================================================
    wire [2:0] stripe = hpos[8:6];

    // RGB カラーバー
    wire [2:0] bar_rgb =
        (stripe == 3'd0) ? 3'b111 :  // 白
        (stripe == 3'd1) ? 3'b110 :  // 黄
        (stripe == 3'd2) ? 3'b011 :  // シアン
        (stripe == 3'd3) ? 3'b010 :  // 緑
        (stripe == 3'd4) ? 3'b101 :  // マゼンタ
        (stripe == 3'd5) ? 3'b100 :  // 赤
        (stripe == 3'd6) ? 3'b001 :  // 青
                           3'b000;   // 黒
    wire [3:0] color_r = (active & bar_rgb[2]) ? 4'hF : 4'h0;
    wire [3:0] color_g = (active & bar_rgb[1]) ? 4'hF : 4'h0;
    wire [3:0] color_b = (active & bar_rgb[0]) ? 4'hF : 4'h0;

    // RGB グラデーションパターン (sw_mono=1)
    //   垂直 3 分割: 上160px=R, 中160px=G, 下160px=B
    //   各帯で hpos[7:4] (0→15) の水平グラデーション
    wire [1:0] rgb_band = (vpos <= 10'd159) ? 2'd0 :
                          (vpos <= 10'd319) ? 2'd1 : 2'd2;
    wire [3:0] h_ramp   = hpos[7:4];  // 0→15, 40px 周期で 640px に 2.5 往復
    wire [3:0] grad_r   = (active && rgb_band == 2'd0) ? h_ramp : 4'h0;
    wire [3:0] grad_g   = (active && rgb_band == 2'd1) ? h_ramp : 4'h0;
    wire [3:0] grad_b   = (active && rgb_band == 2'd2) ? h_ramp : 4'h0;

    // sw_mono で選択 (OFF=カラーバー / ON=RGB グラデーション)
    wire [3:0] test_r = sw_mono ? grad_r : color_r;
    wire [3:0] test_g = sw_mono ? grad_g : color_g;
    wire [3:0] test_b = sw_mono ? grad_b : color_b;

    // =========================================================================
    // 6b. RGB444 → VGA 出力
    //     pixel_out[11:8]=R, [7:4]=G, [3:0]=B (fb_reader が active_d でゲート済み)
    //     sw_raw=1 時は ov7670_capture が {byte1[7:4]×3} をグレースケールで書き込む
    // =========================================================================

    // ── 出力 MUX ─────────────────────────────────────────────────────────
    // sw_test=1: テストパターン (sw_mono で種別選択)
    // sw_test=0: カメラ映像 (RGB444 / sw_raw 時はグレースケール)
    assign vga_r = sw_test ? test_r : pixel_out[11:8];
    assign vga_g = sw_test ? test_g : pixel_out[7:4];
    assign vga_b = sw_test ? test_b : pixel_out[3:0];

    // =========================================================================
    // 7. ILA デバッグ (合成時のみ有効 — シミュレーションでは無視)
    // =========================================================================
    // ── ila_cam : カメラキャプチャ監視 (cam_pclk ドメイン) ─────────────────
    // probe0 : cam_href    (1b)  — 水平参照 High=有効ライン
    // probe1 : cam_vsync   (1b)  — 垂直同期
    // probe2 : cam_d       (8b)  — カメラ生データ
    // probe3 : fb_we       (1b)  — BRAM 書き込みイネーブル
    // probe4 : fb_waddr   (17b)  — BRAM 書き込みアドレス (0〜76799)
    // probe5 : fb_wdata   (12b)  — BRAM 書き込みデータ (12-bit RGB444)
    // probe6 : pat_cnt     (2b)  — テストパターンカウンタ (0〜2)
    // probe7 : byte_phase  (1b)  — 0=byte1受信中, 1=byte2受信中
    ila_cam u_ila_cam (
        .clk    (pclk),          // MMCM 25 MHz — debug hub が確実に認識できる安定クロック
        .probe0 (cam_href),
        .probe1 (cam_vsync),
        .probe2 (cam_d),
        .probe3 (fb_we),
        .probe4 (fb_waddr),
        .probe5 (fb_wdata),
        .probe6 (dbg_pat_cnt),
        .probe7 (dbg_byte_phase),
        .probe8 (dbg_pat_b1),
        .probe9 (dbg_pat_b2)
    );

    // ── ila_vga : VGA 出力監視 (pclk ドメイン) ─────────────────────────────
    // probe0 : vga_r      (4b)  — 赤チャンネル出力
    // probe1 : vga_g      (4b)  — 緑チャンネル出力
    // probe2 : vga_b      (4b)  — 青チャンネル出力
    // probe3 : vga_hs     (1b)  — 水平同期
    // probe4 : vga_vs     (1b)  — 垂直同期
    // probe5 : pixel_out (12b)  — BRAM 読み出し RGB444 (MUX前)
    ila_vga u_ila_vga (
        .clk    (pclk),
        .probe0 (vga_r),
        .probe1 (vga_g),
        .probe2 (vga_b),
        .probe3 (vga_hs),
        .probe4 (vga_vs),
        .probe5 (pixel_out)
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
