`timescale 1ns / 1ps
// =============================================================================
// fb_test_tb.sv  -  fb_test Block Design テストベンチ
// =============================================================================
// BD 構成:
//   v_tpg_0          : Test Pattern Generator (AXI4-Lite slave @ 0x0000_0000)
//   axi_vip_0        : AXI VIP Master (AXI4-Lite, WRITE_ONLY) → TPG 設定用
//   v_tc_0           : Video Timing Controller (640×480, HAS_AXI4_LITE=false)
//   v_axi4s_vid_out_0: AXI4-Stream to Video Out
//
// VTC タイミング (480p / 25 MHz):
//   HACTIVE=640  HFRAME=800  (HFP=16 HSYNC=96 HBP=48)
//   VACTIVE=480  VFRAME=525  (VFP=10 VSYNC=2  VBP=33)
//
// TPG レジスタマップ (v_tpg 8.2 / fb_test_v_tpg_0_0_CTRL_s_axi.v):
//   0x0000 : ap_ctrl   [bit0=ap_start, bit7=auto_restart]
//   0x0010 : height    (rows)
//   0x0018 : width     (cols)
//   0x0020 : bckgndId  (背景パターン: 9=Color Sweep, 1=H-Ramp など)
//   0x0028 : ovrlayId  (オーバーレイ: 0=none)
//
// AXI VIP エージェント:
//   型    : fb_test_axi_vip_0_1_mst_t  (WRITE_ONLY, AXI4-Lite, 32b/32b)
//   IFパス: u_dut.fb_test_i.axi_vip_0.inst.IF
//
// 実行手順 (Vivado Tcl Console):
//   set_property top fb_test_tb [get_filesets sim_2]
//   set_property top_lib xil_defaultlib [get_filesets sim_2]
//   launch_simulation
// =============================================================================

import fb_test_axi_vip_0_1_pkg::*;

module fb_test_tb;

    // =========================================================================
    // 信号宣言
    // =========================================================================
    reg         PCLK;       // 25 MHz
    reg         RESET_N;

    wire        HSYNC;
    wire        VSYNC;
    wire        HSYNC_1;
    wire        VSYNC_1;
    wire [23:0] RGB;
    wire [31:0] status;

    // =========================================================================
    // DUT: fb_test_wrapper
    // =========================================================================
    fb_test_wrapper u_dut (
        .PCLK    (PCLK),
        .RESET_N (RESET_N),
        .RGB     (RGB),
        .HSYNC   (HSYNC),
        .VSYNC   (VSYNC),
        .HSYNC_1 (HSYNC_1),
        .VSYNC_1 (VSYNC_1),
        .status  (status)
    );

    // =========================================================================
    // 25 MHz クロック生成 (40 ns 周期)
    // =========================================================================
    initial PCLK = 1'b0;
    always  #20 PCLK = ~PCLK;

    // =========================================================================
    // AXI VIP マスタエージェント
    //   パッケージ : fb_test_axi_vip_0_1_pkg
    //   プロトコル : AXI4-Lite (WRITE_ONLY, 32b addr / 32b data)
    //   IFパス    : u_dut.fb_test_i.axi_vip_0.inst.IF
    // =========================================================================
    fb_test_axi_vip_0_1_mst_t axi_mst;

    // =========================================================================
    // メインシーケンス
    // =========================================================================
    initial begin
        // ── リセット ─────────────────────────────────────────────────────
        RESET_N = 1'b0;
        repeat (30) @(posedge PCLK);
        RESET_N = 1'b1;
        $display("[TB] %0t ns : Reset released", $time/1000);
        repeat (20) @(posedge PCLK);

        // ── AXI VIP エージェント初期化 ───────────────────────────────────
        // new(エージェント名, IFパス)
        axi_mst = new("axi_mst", u_dut.fb_test_i.axi_vip_0.inst.IF);

        // --- VIP 設定 ---------------------------------------------------
        // ログのプレフィックスを設定 (波形・コンソールで識別しやすくする)
        axi_mst.set_agent_tag("TPG_MST");

        // 詳細ログレベル設定
        //   0   : なし
        //   100 : FATAL のみ
        //   200 : ERROR 以上
        //   300 : WARNING 以上 (デフォルト)
        //   400 : INFO 以上 (デバッグに推奨)
        axi_mst.set_verbosity(400);

        // WRITE ドライバのトランザクションキュー深さ (デフォルト: 1)
        // 複数書き込みをパイプライン送信する場合は増やす
        axi_mst.wr_driver.set_transaction_depth(4);

        // エージェント起動 (start_master を呼ぶ前に set_* を完了させること)
        axi_mst.start_master();
        // ----------------------------------------------------------------
        repeat (10) @(posedge PCLK);

        // ── TPG レジスタ設定 ──────────────────────────────────────────────
        // レジスタマップ (fb_test_v_tpg_0_0_CTRL_s_axi.v より):
        //   0x10 : height (rows)   0x18 : width (cols)
        //   0x20 : bckgndId        0x28 : ovrlayId (背景とは別)
        //
        // ap_start は VTC の VSYNC_1 に合わせて書く。
        // v_axi4s_vid_out のロックは TPG の TUSER=1(SOF) が
        // VTC フレーム先頭と一致したときに成立する。
        // ap_start を VTC フレーム境界で書くことで最初のフレームからロックさせる。
        axi_write(32'h0010, 32'd480);   // height = 480
        axi_write(32'h0018, 32'd640);   // width  = 640
        axi_write(32'h0020, 32'd2);     // bckgndId: 2 = Vertical Ramp (ROM不要)
        axi_write(32'h0028, 32'd0);     // ovrlayId: 0 = none
        $display("[TB] %0t ns : TPG size/pattern set, waiting for VTC VBP...", $time/1000);

        // negedge VSYNC_1 = vsyncパルス終了 = VBP開始
        // VBP = 33 lines × 800 clk = 26400 clk のマージンがあり
        // HLS パイプラインが最初のピクセルを出すのに十分な時間を確保できる
        @(posedge VSYNC_1);  // vsync開始を待つ
        @(negedge VSYNC_1);  // vsync終了(=VBP開始)まで待つ
        repeat (10) @(posedge PCLK);
        axi_write(32'h0000, 32'h81);    // CTRL: ap_start=1, auto_restart=1
        $display("[TB] %0t ns : TPG ap_start at VBP start (26400 clk before active)", $time/1000);

        // ── locked 待ち (最大 5 フレーム) ───────────────────────────────
        fork
            begin : wait_lock
                wait (u_dut.fb_test_i.v_axi4s_vid_out_0.locked == 1'b1);
                $display("[TB] %0t ns : vid_out LOCKED!", $time/1000);
            end
            begin : lock_timeout
                repeat (5) @(posedge VSYNC_1);
                $display("[TB] %0t ns : WARNING - vid_out not locked after 5 VTC frames", $time/1000);
            end
        join_any
        disable fork;

        // ── VSYNC 3 フレーム待ち ──────────────────────────────────────────
        repeat (3) @(posedge VSYNC);
        $display("[TB] %0t ns : 3 frames complete. Simulation done.", $time/1000);
        $finish;
    end

    // =========================================================================
    // AXI4-Lite 書き込みタスク (WRITE_ONLY エージェント向け)
    //   - WSTRB = 4'hF (全バイトイネーブル)
    //   - wait_rsp で BRESP を確認
    // =========================================================================
    task automatic axi_write(input bit [31:0] addr, input bit [31:0] data);
        bit [1:0] bresp;

        // AXI4LITE_WRITE_BURST はエージェント組み込みタスク。
        // axi_transaction の宣言が不要で axi_vip_pkg への直接依存がない。
        // 引数: (addr, prot, data, resp_out)
        axi_mst.AXI4LITE_WRITE_BURST(addr, 3'b000, data, bresp);

        if (bresp != 2'b00)  // 2'b00 = OKAY
            $error("[TB] %0t ns : AXI write FAILED  addr=0x%08X  data=0x%08X  bresp=%0d",
                   $time/1000, addr, data, bresp);
        else
            $display("[TB] %0t ns : AXI write OK  addr=0x%08X  data=0x%08X",
                     $time/1000, addr, data);
    endtask

    // =========================================================================
    // HSYNC / VSYNC タイミング監視
    // =========================================================================
    time hs_fall_t = 0;
    time vs_fall_t = 0;
    time vs_prev_t = 0;
    int  vs_cnt    = 0;

    always @(negedge HSYNC) hs_fall_t = $time;
    always @(posedge HSYNC) begin
        if (hs_fall_t != 0)
            $display("[TB] %0t ns : HSYNC pulse = %0d ns",
                     $time/1000, ($time - hs_fall_t));
    end

    always @(negedge VSYNC) begin
        vs_prev_t = vs_fall_t;
        vs_fall_t = $time;
    end
    always @(posedge VSYNC) begin
        vs_cnt++;
        if (vs_fall_t != 0)
            $display("[TB] %0t ns : VSYNC #%0d  pulse=%0d us  period=%0d us",
                     $time/1000, vs_cnt,
                     ($time - vs_fall_t) / 1000,
                     (vs_prev_t != 0) ? (vs_fall_t - vs_prev_t) / 1000 : 0);
    end

    // =========================================================================
    // RGB 出力サンプリング (有効ピクセルを先頭 5 個だけ表示)
    // =========================================================================
    int px_sample_cnt = 0;
    always @(posedge PCLK) begin
        if (HSYNC && !VSYNC && px_sample_cnt < 5) begin
            px_sample_cnt++;
            $display("[TB] %0t ns : RGB sample #%0d = 0x%06X (R=%02X G=%02X B=%02X)",
                     $time/1000, px_sample_cnt, RGB,
                     RGB[23:16], RGB[15:8], RGB[7:0]);
        end
    end

    // =========================================================================
    // タイムアウト (200 ms — 25 MHz×640×800×525 ≈ 16.7 ms/frame)
    // =========================================================================
    initial begin
        #200_000_000;
        $display("[TB] TIMEOUT: 200 ms elapsed.");
        $finish;
    end

    // =========================================================================
    // 波形ダンプ
    // =========================================================================
    initial begin
        $dumpfile("fb_test_tb.vcd");
        $dumpvars(0, fb_test_tb);
    end

endmodule
