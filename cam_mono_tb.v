`timescale 1ns / 1ps
// =============================================================================
// cam_mono_tb.v  -  8-bit モノクロ カメラ経路の検証 (vga_top + ov7670_model)
// =============================================================================
// 検証内容:
//   1. フレームバッファ: 320×240 全画素が OV7670 モデルの Y と一致するか
//   2. fb_reader     : pixel_out が 2 サイクル遅延で正しい座標の画素を出すか
//   3. VGA 出力      : R=G=B, 各画素が y[7:4] または y[7:4]+1 (ディザ),
//                      カメラ領域の平均輝度がディザ前と一致するか
//
// 前提:
//   - fb_test (BD) と ila_cam は本ファイル末尾のスタブで置き換える
//   - 実機では SCCB 初期化 (約 240 ms 後) で COM7=0x10 (QVGA/YUV) になる。
//     シミュレーション時間短縮のため、TB がモデルの COM7 を直接 0x10 に保つ。
//
// 実行 (xsim):
//   xvlog cam_mono_tb.v vga_top.v ov7670_if.v fb_reader.v vga_mono.v ov7670_model.v glbl.v
//   xelab -L unisims_ver cam_mono_tb glbl -s cam_mono_tb
//   xsim cam_mono_tb -R
// =============================================================================

module cam_mono_tb;

    reg         clk = 1'b0;
    reg         btn_rst = 1'b1;
    reg         sw_test = 1'b0, sw_raw = 1'b0, sw_mono = 1'b0, sw3 = 1'b0;

    wire        cam_xclk, cam_pclk, cam_vsync, cam_href;
    wire [7:0]  cam_d;
    wire        cam_sioc, cam_siod, cam_rst_n, cam_pwdn;
    wire        vga_hs, vga_vs;
    wire [3:0]  vga_r, vga_g, vga_b;
    wire [3:0]  led;

    wire [7:0]  ddr3_dq;
    wire [0:0]  ddr3_dqs_p, ddr3_dqs_n, ddr3_ck_p, ddr3_ck_n, ddr3_cke, ddr3_cs_n, ddr3_dm, ddr3_odt;
    wire [13:0] ddr3_addr;
    wire [2:0]  ddr3_ba;
    wire        ddr3_ras_n, ddr3_cas_n, ddr3_we_n, ddr3_reset_n;

    pullup (cam_siod);

    always #5 clk = ~clk;   // 100 MHz

    vga_top u_dut (
        .clk(clk), .btn_rst(btn_rst),
        .cam_xclk(cam_xclk), .cam_pclk(cam_pclk), .cam_vsync(cam_vsync), .cam_href(cam_href),
        .cam_d(cam_d), .cam_sioc(cam_sioc), .cam_siod(cam_siod), .cam_rst_n(cam_rst_n), .cam_pwdn(cam_pwdn),
        .vga_hs(vga_hs), .vga_vs(vga_vs), .vga_r(vga_r), .vga_g(vga_g), .vga_b(vga_b),
        .led(led),
        .sw_test(sw_test), .sw_raw(sw_raw), .sw_mono(sw_mono), .sw3(sw3),
        .ddr3_dq(ddr3_dq), .ddr3_dqs_p(ddr3_dqs_p), .ddr3_dqs_n(ddr3_dqs_n),
        .ddr3_addr(ddr3_addr), .ddr3_ba(ddr3_ba), .ddr3_ras_n(ddr3_ras_n), .ddr3_cas_n(ddr3_cas_n),
        .ddr3_we_n(ddr3_we_n), .ddr3_reset_n(ddr3_reset_n), .ddr3_ck_p(ddr3_ck_p), .ddr3_ck_n(ddr3_ck_n),
        .ddr3_cke(ddr3_cke), .ddr3_cs_n(ddr3_cs_n), .ddr3_dm(ddr3_dm), .ddr3_odt(ddr3_odt)
    );

    ov7670_model #(.H_BAR_EN(0)) u_cam (     // 0 = 水平グラデーション
        .xclk(cam_xclk), .pclk(cam_pclk), .vsync(cam_vsync), .href(cam_href), .d(cam_d),
        .sioc(cam_sioc), .siod(cam_siod), .rst_n(cam_rst_n), .pwdn(cam_pwdn)
    );

    // SCCB のソフトリセットで COM7 が 0 に戻っても QVGA/YUV を維持
    always @(posedge cam_xclk)
        if (u_cam.regfile[8'h12] !== 8'h10) u_cam.regfile[8'h12] = 8'h10;

    // 期待輝度 (モデルのグラデーション式と同じ)
    function [7:0] exp_y;
        input integer c;
        exp_y = (c * 255) / 319;
    endfunction

    integer errors = 0;

    // -------------------------------------------------------------------------
    // 2. pixel_out の座標整合 (pclk ドメイン, 2 サイクル遅延)
    // -------------------------------------------------------------------------
    reg [9:0] h_d1, h_d2, v_d1, v_d2;
    reg       a_d1, a_d2;
    reg [9:0] h_d3, v_d3;               // VGA ピンは出力レジスタでさらに 1 サイクル遅れる
    reg       a_d3;
    reg [7:0] pix_d3;
    reg       chk_en = 1'b0;
    integer   px_checked = 0;
    integer   sum_y = 0, sum_out = 0, n_out = 0;

    always @(posedge u_dut.pclk) begin
        h_d1 <= u_dut.hpos;   h_d2 <= h_d1;
        v_d1 <= u_dut.vpos;   v_d2 <= v_d1;
        a_d1 <= u_dut.active; a_d2 <= a_d1;
        h_d3 <= h_d2; v_d3 <= v_d2; a_d3 <= a_d2; pix_d3 <= u_dut.pixel_out;

        if (chk_en && a_d2 && h_d2 < 320 && v_d2 < 240) begin
            // fb_reader 出力
            if (u_dut.pixel_out !== exp_y(h_d2)) begin
                if (errors < 10)
                    $display("[TB] NG pixel_out (%0d,%0d) = %0d, exp %0d",
                             h_d2, v_d2, u_dut.pixel_out, exp_y(h_d2));
                errors = errors + 1;
            end
        end
        // VGA 出力 (ディザ後, 出力レジスタ分 1 サイクル遅れ)
        if (chk_en && a_d3 && h_d3 < 320 && v_d3 < 240) begin
            if (!(vga_r === vga_g && vga_g === vga_b)) begin
                if (errors < 10) $display("[TB] NG R/G/B mismatch at (%0d,%0d)", h_d3, v_d3);
                errors = errors + 1;
            end
            if (!(vga_r == pix_d3[7:4] ||
                  (vga_r == pix_d3[7:4] + 1 && pix_d3[7:4] != 4'hF))) begin
                if (errors < 10)
                    $display("[TB] NG dither (%0d,%0d) y=%0d out=%0d", h_d3, v_d3, pix_d3, vga_r);
                errors = errors + 1;
            end
            sum_y   = sum_y + pix_d3;
            sum_out = sum_out + vga_r * 16;
            n_out   = n_out + 1;
            px_checked = px_checked + 1;
        end
    end

    // -------------------------------------------------------------------------
    // シーケンス
    // -------------------------------------------------------------------------
    integer r, c, fb_err;
    initial begin
        repeat (20) @(posedge clk);
        btn_rst = 1'b0;
        $display("[TB] reset released");

        // カメラ 3 フレーム待ち (1 フレーム目は書式切替直後の可能性があるため捨てる)
        repeat (3) @(negedge cam_vsync);
        @(posedge cam_vsync);   // 3 フレーム目の書き込み完了
        $display("[TB] %0t ns : camera frames captured", $time);

        // 1. フレームバッファ全画素チェック
        fb_err = 0;
        for (r = 0; r < 240; r = r + 1)
            for (c = 0; c < 320; c = c + 1)
                if (u_dut.u_fb.framebuf[r*320 + c] !== exp_y(c)) begin
                    if (fb_err < 5)
                        $display("[TB] NG framebuf[%0d][%0d] = %0d, exp %0d",
                                 r, c, u_dut.u_fb.framebuf[r*320 + c], exp_y(c));
                    fb_err = fb_err + 1;
                end
        $display("[TB] framebuffer check: %0d / 76800 mismatches", fb_err);
        errors = errors + fb_err;

        // 2,3. VGA 1 フレーム分の出力チェック
        @(negedge vga_vs); @(posedge vga_vs);
        chk_en = 1'b1;
        @(negedge vga_vs); @(posedge vga_vs);
        chk_en = 1'b0;
        $display("[TB] VGA output check: %0d pixels, avg y = %0d.%02d, avg out*16 = %0d.%02d",
                 px_checked, sum_y / n_out, (sum_y * 100 / n_out) % 100,
                 sum_out / n_out, (sum_out * 100 / n_out) % 100);
        // ディザ後の平均がディザ前と 1 LSB(8bit) 以内で一致すること
        if ((sum_out - sum_y) * 1 > n_out || (sum_y - sum_out) * 1 > n_out) begin
            $display("[TB] NG average mismatch");
            errors = errors + 1;
        end

        if (errors == 0) $display("[TB] *** PASS ***");
        else             $display("[TB] *** FAIL : %0d errors ***", errors);
        $finish;
    end

    initial begin
        #60_000_000;
        $display("[TB] TIMEOUT");
        $finish;
    end

endmodule

// =============================================================================
// スタブ (シミュレーション専用)
// =============================================================================
module fb_test (
    input  wire CLK, input wire RESET,
    output wire [23:0] RGB, output wire HSYNC, output wire VSYNC,
    output wire HSYNC_1, output wire VSYNC_1, output wire [31:0] status,
    output wire init_calib_complete,
    inout  wire [7:0] ddr3_dq, inout wire [0:0] ddr3_dqs_p, inout wire [0:0] ddr3_dqs_n,
    output wire [13:0] ddr3_addr, output wire [2:0] ddr3_ba,
    output wire ddr3_ras_n, output wire ddr3_cas_n, output wire ddr3_we_n, output wire ddr3_reset_n,
    output wire [0:0] ddr3_ck_p, output wire [0:0] ddr3_ck_n, output wire [0:0] ddr3_cke,
    output wire [0:0] ddr3_cs_n, output wire [0:0] ddr3_dm, output wire [0:0] ddr3_odt
);
    assign RGB = 24'h0; assign HSYNC = 1'b0; assign VSYNC = 1'b0;
    assign HSYNC_1 = 1'b0; assign VSYNC_1 = 1'b0; assign status = 32'h0;
    assign init_calib_complete = 1'b0;
endmodule

module ila_cam (
    input wire clk, input wire [7:0] probe0, input wire [3:0] probe1,
    input wire [16:0] probe2, input wire [7:0] probe3, input wire [11:0] probe4
);
endmodule
