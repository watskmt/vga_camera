`timescale 1ns / 1ps
// =============================================================================
// vga_top_tb.v  -  vga_top テストベンチ
// =============================================================================
// 構成:
//   vga_top (DUT)  +  ov7670_model (カメラモデル)
//
// 確認項目:
//   [1] PLL ロック / SCCB 初期化完了 (LED 監視)
//   [2] OV7670 → フレームバッファ書き込み → VGA 出力
//   [3] VGA HSYNC/VSYNC パルス幅・周期検証
//   [4] アクティブ期間ピクセル統計 (フレーム毎)
//
// 実行ツール: Vivado xsim (Unisim ライブラリ必須)
//   add_files -fileset sim_1 {vga_top_tb.v vga_top.v vga_mono.v fb_reader.v
//                              ov7670_if.v ov7670_model.v}
//   set_property top vga_top_tb [get_filesets sim_1]
//   launch_simulation
//
// シミュレーション時間目安:
//   SCCB 初期化 : ~11 ms  (37 トランザクション × ~270 μs + 1 ms ディレイ)
//   VGA 1 フレーム : ~16.8 ms  (800 × 525 × 40 ns)
//   OV7670 1 フレーム : ~30.2 ms  (1440 × 525 × 40 ns @ 25 MHz PCLK)
//   $finish : VGA VSYNC 3 回後 (約 50 ms)
// =============================================================================

module vga_top_tb;

    // =========================================================================
    // 信号宣言
    // =========================================================================
    reg         clk;        // 100 MHz システムクロック
    reg         btn_rst;    // リセット (High=リセット)

    // ── OV7670 接続 ──────────────────────────────────────────
    wire        cam_xclk;
    wire        cam_pclk;
    wire        cam_vsync;
    wire        cam_href;
    wire [7:0]  cam_d;
    wire        cam_sioc;
    wire        cam_siod;   // inout: sccb_master ↔ ov7670_model
    wire        cam_rst_n;
    wire        cam_pwdn;

    // ── VGA 出力 ─────────────────────────────────────────────
    wire        vga_hs;
    wire        vga_vs;
    wire [3:0]  vga_r;
    wire [3:0]  vga_g;
    wire [3:0]  vga_b;

    // ── ステータス LED ────────────────────────────────────────
    wire [3:0]  led;

    // SIOD プルアップ (4.7 kΩ 相当のウィーク High)
    pullup u_siod_pull (cam_siod);

    // =========================================================================
    // DUT: vga_top
    // =========================================================================
    vga_top u_dut (
        .clk      (clk),
        .btn_rst  (btn_rst),
        // カメラ
        .cam_xclk (cam_xclk),
        .cam_pclk (cam_pclk),
        .cam_vsync(cam_vsync),
        .cam_href (cam_href),
        .cam_d    (cam_d),
        .cam_sioc (cam_sioc),
        .cam_siod (cam_siod),
        .cam_rst_n(cam_rst_n),
        .cam_pwdn (cam_pwdn),
        // VGA
        .vga_hs   (vga_hs),
        .vga_vs   (vga_vs),
        .vga_r    (vga_r),
        .vga_g    (vga_g),
        .vga_b    (vga_b),
        // LED
        .led      (led)
    );

    // =========================================================================
    // OV7670 カメラモデル
    // =========================================================================
    ov7670_model #(
        .H_BAR_EN(1)        // 1=カラーバー / 0=グラデーション
    ) u_cam (
        .xclk (cam_xclk),   // FPGA → カメラ
        .pclk (cam_pclk),   // カメラ → FPGA  (ov7670_model が生成)
        .vsync(cam_vsync),
        .href (cam_href),
        .d    (cam_d),
        .sioc (cam_sioc),
        .siod (cam_siod),
        .rst_n(cam_rst_n),
        .pwdn (cam_pwdn)
    );

    // =========================================================================
    // 100 MHz クロック生成
    // =========================================================================
    initial clk = 1'b0;
    always  #5 clk = ~clk;     // 10 ns 周期

    // =========================================================================
    // リセットシーケンス
    // =========================================================================
    initial begin
        btn_rst = 1'b1;
        repeat (20) @(posedge clk);
        @(negedge clk);
        btn_rst = 1'b0;
        $display("[TB] %0t ns : Reset released", $time);
    end

    // =========================================================================
    // LED モニタ
    // =========================================================================
    always @(posedge led[0]) $display("[TB] %0t ns : [led0] PLL locked", $time);
    always @(posedge led[1]) $display("[TB] %0t ns : [led1] SCCB init done", $time);
    always @(posedge led[2]) $display("[TB] %0t ns : [led2] frame_start LED on", $time);

    // =========================================================================
    // VGA タイミング検証
    // =========================================================================
    // HSYNC パルス幅 / 周期
    //   期待値: パルス幅 = 96 pclk × 40 ns =  3,840 ns
    //           周期     = 800 pclk × 40 ns = 32,000 ns
    // -------------------------------------------------------------------------
    time hs_fall_t;
    time hs_prev_fall_t;
    integer hs_check_cnt;

    initial begin
        hs_fall_t      = 0;
        hs_prev_fall_t = 0;
        hs_check_cnt   = 0;
    end

    always @(negedge vga_hs) begin
        hs_prev_fall_t = hs_fall_t;
        hs_fall_t      = $time;
    end

    always @(posedge vga_hs) begin
        if (hs_check_cnt < 5 && hs_fall_t != 0) begin
            $display("[TB] %0t ns : HSYNC pulse=%0d ns (exp 3840)  period=%0d ns (exp 32000)",
                     $time,
                     $time - hs_fall_t,
                     (hs_prev_fall_t != 0) ? hs_fall_t - hs_prev_fall_t : 0);
            hs_check_cnt = hs_check_cnt + 1;
        end
    end

    // -------------------------------------------------------------------------
    // VSYNC パルス幅 / 周期
    //   期待値: パルス幅 = 2 × 800 × 40 ns =     64,000 ns
    //           周期     = 525 × 800 × 40 ns = 16,800,000 ns (16.8 ms)
    // -------------------------------------------------------------------------
    time vs_fall_t;
    time vs_prev_fall_t;

    initial begin
        vs_fall_t      = 0;
        vs_prev_fall_t = 0;
    end

    always @(negedge vga_vs) begin
        vs_prev_fall_t = vs_fall_t;
        vs_fall_t      = $time;
    end

    always @(posedge vga_vs) begin
        if (vs_fall_t != 0)
            $display("[TB] %0t ns : VSYNC pulse=%0d ns (exp 64000)  period=%0d ns (exp 16800000)",
                     $time,
                     $time - vs_fall_t,
                     (vs_prev_fall_t != 0) ? vs_fall_t - vs_prev_fall_t : 0);
    end

    // =========================================================================
    // フレームバッファ書き込み監視 (cam_pclk ドメイン)
    //   最初の書き込みだけ表示して動作確認
    // =========================================================================
    wire        fb_we_mon    = u_dut.fb_we;
    wire [15:0] fb_waddr_mon = u_dut.fb_waddr;
    wire [11:0]  fb_wdata_mon = u_dut.fb_wdata;
    wire        fb_wclk_mon  = u_dut.fb_wclk;

    integer fb_write_cnt;
    initial fb_write_cnt = 0;

    always @(posedge fb_wclk_mon) begin
        if (fb_we_mon) begin
            fb_write_cnt = fb_write_cnt + 1;
            if (fb_write_cnt <= 8)
                $display("[TB] %0t ns : FB write #%0d  addr=0x%04X  data=0x%02X",
                         $time, fb_write_cnt, fb_waddr_mon, fb_wdata_mon);
            if (fb_write_cnt == 9)
                $display("[TB] ... (subsequent FB writes suppressed)");
        end
    end

    // =========================================================================
    // ピクセル統計 (pclk ドメイン, VGA フレーム毎)
    //   カラーバー (8 色均等) + THRESHOLD=20 での期待白比率:
    //   8-bit グレースケール: 輝度の平均値を表示
    //   カラーバー (8 色均等) での期待平均輝度 ≈ 88 (luma8 スケール 0-188)
    // =========================================================================
    wire        pclk_mon   = u_dut.pclk;
    wire        active_mon = u_dut.active;
    wire [7:0]  pixel_mon  = u_dut.pixel_out;

    integer px_sum;
    integer px_total;
    integer vga_frame;

    initial begin
        px_sum    = 0;
        px_total  = 0;
        vga_frame = 0;
    end

    always @(posedge pclk_mon) begin
        if (active_mon) begin
            px_total = px_total + 1;
            px_sum   = px_sum + pixel_mon;
        end
    end

    always @(negedge vga_vs) begin
        vga_frame = vga_frame + 1;
        if (px_total > 0)
            $display("[TB] %0t ns : VGA frame %0d : avg luma = %0d / 188 (exp ~88)",
                     $time, vga_frame, px_sum / px_total);
        else
            $display("[TB] %0t ns : VGA frame %0d : no active pixels yet",
                     $time, vga_frame);
        px_sum   = 0;
        px_total = 0;

        // 第1フレーム完了 (~104ms) は VGA 約7フレーム目に相当
        // 104ms / 16.8ms per VGA frame ≈ 6.2 → 7フレーム目以降で完全なパターンを確認
        if (vga_frame >= 8) begin
            $display("[TB] Simulation complete after %0d VGA frames.", vga_frame);
            $finish;
        end
    end

    // =========================================================================
    // 波形ダンプ (Vivado xsim 以外でも使用可)
    // =========================================================================
    initial begin
        $dumpfile("vga_top_tb.vcd");
        $dumpvars(0, vga_top_tb);
    end

    // =========================================================================
    // タイムアウト (フレーム検出が行われない場合の保険)
    // =========================================================================
    initial begin
        #200_000_000;   // 200 ms
        $display("[TB] TIMEOUT: simulation stopped at 200 ms.");
        $finish;
    end

endmodule
