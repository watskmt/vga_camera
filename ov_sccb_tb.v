`timescale 1ns / 1ps
// =============================================================================
// ov_sccb_tb.v  -  ov7670_if の SCCB シーケンス検証 (ov7670_model のレジスタを確認)
// =============================================================================
// 検証内容:
//   1. 初期化 ROM の値がモデルのレジスタに書かれる (VGA / アナログ推奨値など)
//   2. 初期化と PID 読み出しの後, 0x70 = 0x3A / 0x71 = 0x35 が 1 回だけ書かれる
//   3. その後 SCCB は止まる (agc_hold を変えたときだけ COM8 を 1 回書く)
//        agc_hold=1 → COM8 = 0x8A, agc_hold=0 → COM8 = 0x8F
//   ※ 高速化のため SYS_CLK_HZ = 4 MHz (SCCB 100 kHz はそのまま, 240 ms 待ちも実時間)
//
// 実行 (xsim):
//   xvlog ov_sccb_tb.v ov7670_if.v ov7670_model.v
//   xelab ov_sccb_tb -s ov_sccb_tb
//   xsim ov_sccb_tb -R
// =============================================================================
module ov_sccb_tb;
    reg clk = 0;
    always #125 clk = ~clk;          // 4 MHz
    reg rst_n = 0;
    reg agc_hold = 0;

    wire xclk, pclk, vsync, href, sioc, siod, cam_rst_n, cam_pwdn;
    wire [7:0] d;
    wire init_done, sio_pass, sio_fail;
    pullup (siod);

    ov7670_if #(.SYS_CLK_HZ(4_000_000), .XCLK_HZ(1_000_000), .SCCB_CLK_HZ(100_000)) dut (
        .clk(clk), .rst_n(rst_n), .cam_rst_i_n(rst_n),
        .xclk(xclk), .pclk(pclk), .vsync(vsync), .href(href), .d(d),
        .sioc(sioc), .siod(siod), .cam_rst_o_n(cam_rst_n), .cam_pwdn(cam_pwdn),
        .pix_clk(), .pix_we(), .pix_sof(), .pix_eol(), .pix_rgb(),
        .init_done(init_done), .frame_start(),
        .sio_test_pass(sio_pass), .sio_test_fail(sio_fail),
        .dbg_pat_cnt(), .dbg_byte_phase(), .dbg_pat_b1(), .dbg_pat_b2(),
        .sw3(1'b0), .agc_hold(agc_hold)
    );

    ov7670_model #(.H_BAR_EN(0)) u_cam (
        .xclk(xclk), .pclk(pclk), .vsync(vsync), .href(href), .d(d),
        .sioc(sioc), .siod(siod), .rst_n(cam_rst_n), .pwdn(cam_pwdn)
    );

    // SCCB トランザクション数 (sccb_master の done パルス)
    integer n_start = 0;
    always @(posedge clk) if (dut.sccb_done) n_start = n_start + 1;

    integer errors = 0;
    task chk;
        input [7:0] a, v;
        if (u_cam.regfile[a] !== v) begin
            $display("[TB] NG reg %h = %h (exp %h)", a, u_cam.regfile[a], v);
            errors = errors + 1;
        end
    endtask

    integer n0;
    initial begin
        #2000 rst_n = 1;
        wait (dut.test_result_done);
        $display("[TB] %0t : init + PID test done (pass=%0d fail=%0d), transactions=%0d",
                 $time, sio_pass, sio_fail, n_start);
        // 0x70/0x71 の 2 回分が終わるまで待つ
        wait (dut.run_step == 2'd2 && !dut.run_busy);
        #200_000;
        // 1. 初期化 ROM の値
        chk(8'h12, 8'h04); chk(8'h40, 8'hD0); chk(8'h3A, 8'h04); chk(8'h3D, 8'hC0);
        chk(8'h4F, 8'hB3); chk(8'h50, 8'hB3); chk(8'h51, 8'h00); chk(8'h52, 8'h3D);
        chk(8'h53, 8'hA7); chk(8'h54, 8'hE4); chk(8'h58, 8'h9E);
        chk(8'h17, 8'h13); chk(8'h18, 8'h01); chk(8'h32, 8'hB6);   // 出力窓
        chk(8'h19, 8'h02); chk(8'h1A, 8'h7A); chk(8'h03, 8'h0A);
        chk(8'h14, 8'h1A); chk(8'h0E, 8'h61); chk(8'h0F, 8'h4B); chk(8'h1E, 8'h07);
        chk(8'h33, 8'h0B); chk(8'h37, 8'h1D); chk(8'h38, 8'h71); chk(8'h39, 8'h2A);
        chk(8'h69, 8'h00); chk(8'h74, 8'h10); chk(8'hB1, 8'h0C); chk(8'hB3, 8'h82);
        chk(8'hB8, 8'h0A);
        chk(8'h11, 8'h00); chk(8'h6B, 8'h00);     // CLKRC / DBLV は書かない
        // 2. 0x70 / 0x71
        chk(8'h70, 8'h3A); chk(8'h71, 8'h35);

        // 3. SCCB が止まっていること (10 ms 待ってもトランザクションが増えない)
        //    ※ モデルは SCCB 読み出し非対応なので PID テストは fail になる (想定どおり)
        n0 = n_start;
        #10_000_000;
        if (n_start != n0) begin
            $display("[TB] NG SCCB still running (%0d transactions in 10 ms)", n_start - n0);
            errors = errors + 1;
        end

        // agc_hold=1 → COM8 = 0x8A を 1 回
        agc_hold = 1;
        #2_000_000;
        chk(8'h13, 8'h8A);
        if (n_start != n0 + 1) begin
            $display("[TB] NG COM8 write count = %0d (exp 1)", n_start - n0); errors = errors + 1;
        end
        // agc_hold=0 → COM8 = 0x8F を 1 回
        agc_hold = 0;
        #2_000_000;
        chk(8'h13, 8'h8F);
        if (n_start != n0 + 2) begin
            $display("[TB] NG COM8 write count = %0d (exp 2)", n_start - n0); errors = errors + 1;
        end

        if (errors == 0) $display("[TB] *** PASS ***");
        else             $display("[TB] *** FAIL : %0d errors ***", errors);
        $finish;
    end

    initial begin
        #600_000_000;
        $display("[TB] TIMEOUT");
        $finish;
    end
endmodule
