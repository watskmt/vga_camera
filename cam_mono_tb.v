`timescale 1ns / 1ps
// =============================================================================
// cam_mono_tb.v  -  カメラ (VGA 640×480, RGB565) → DDR3 書き込みストリームの検証
//                   (vga_top + ov7670_model, fb_test BD はスタブ)
// =============================================================================
// 検証内容:
//   1. cam_ddr_cfg : MIG キャリブ完了後に VDMA / TPG へ 20 回書き込み, エラーなし
//   2. S_AXIS_VID  : カメラのフレームが 640×480 で, 各画素が OV7670 モデルの RGB565 を
//                    RGB888 に広げた値と一致, tuser はフレーム先頭 1 画素, tlast は各行の最終画素
//   3. VGA 出力    : BD の映像 (スタブの RGB) が色ごとにディザされて RGB444 に出る
//   4. FIFO あふれなし, LED 表示 (calib / 設定完了 / エラーなし)
//
// 前提:
//   - fb_test (BD) と ila_cam は本ファイル末尾のスタブで置き換える
//   - OV7670 モデルはリセット直後から COM7=0x04 (VGA/RGB565) で出力する
//     (実機の SCCB 初期化 約 240 ms は待たない)
//
// 実行 (xsim):
//   xvlog cam_mono_tb.v vga_top.v cam_ddr.v ov7670_if.v ov7670_model.v glbl.v
//   xelab -L xpm -L unisims_ver cam_mono_tb glbl -s cam_mono_tb
//   xsim cam_mono_tb -R
// =============================================================================

module cam_mono_tb;

    localparam W = 640, H = 480;

    reg         clk = 1'b0;
    reg         btn_rst = 1'b1;
    reg         sw_test = 1'b0, sw_agc_hold = 1'b0, sw_pat = 1'b0;

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
        .sw_test(sw_test), .sw_agc_hold(sw_agc_hold), .sw_pat(sw_pat),
        .ddr3_dq(ddr3_dq), .ddr3_dqs_p(ddr3_dqs_p), .ddr3_dqs_n(ddr3_dqs_n),
        .ddr3_addr(ddr3_addr), .ddr3_ba(ddr3_ba), .ddr3_ras_n(ddr3_ras_n), .ddr3_cas_n(ddr3_cas_n),
        .ddr3_we_n(ddr3_we_n), .ddr3_reset_n(ddr3_reset_n), .ddr3_ck_p(ddr3_ck_p), .ddr3_ck_n(ddr3_ck_n),
        .ddr3_cke(ddr3_cke), .ddr3_cs_n(ddr3_cs_n), .ddr3_dm(ddr3_dm), .ddr3_odt(ddr3_odt)
    );

    ov7670_model #(.H_BAR_EN(0)) u_cam (     // 0 = 水平グラデーション
        .xclk(cam_xclk), .pclk(cam_pclk), .vsync(cam_vsync), .href(cam_href), .d(cam_d),
        .sioc(cam_sioc), .siod(cam_siod), .rst_n(cam_rst_n), .pwdn(cam_pwdn)
    );

    // SCCB のソフトリセットで COM7 が変わっても VGA/RGB565 を維持
    always @(posedge cam_xclk)
        if (u_cam.regfile[8'h12] !== 8'h04) u_cam.regfile[8'h12] = 8'h04;


    integer errors = 0;

    // -------------------------------------------------------------------------
    // 2. S_AXIS_VID (VDMA S2MM 入力) のフレームチェック
    // -------------------------------------------------------------------------
    wire        s_clk   = u_dut.bd_sysclk;
    wire [23:0] v_data  = u_dut.vid_tdata;
    wire        v_valid = u_dut.vid_tvalid;
    wire        v_ready = u_dut.vid_tready;
    wire        v_last  = u_dut.vid_tlast;
    wire        v_user  = u_dut.vid_tuser;

    // 期待値 (RGB565): 通常はモデルのグラデーション {px[8:4], px[9:4], px[8:4]},
    //   exp_pat=1 なら SW3 の試験パターン (灰色 {20, 40, 20} の地, 中央が黒)
    //   (切替直後の混ざったフレームは pix_chk=0 にして画素値を見ない)
    // AXI4-Stream Video {R, B, G} への拡張は cam_ddr と同じ
    // ※ xsim では関数の入れ子呼び出しが X になることがあるため, レジスタ経由で計算する
    reg exp_pat = 1'b0, pix_chk = 1'b1;
    reg [9:0]  e_px;
    reg [15:0] e_c;
    reg [23:0] e_axis;

    integer ox = 0, oy = 0, in_frame = 0, n_frames = 0, n_cut = 0;
    always @(posedge s_clk) begin
        if (v_valid && v_ready) begin
            if (v_user) begin
                if (in_frame) begin
                    $display("[TB] NG frame cut at (%0d,%0d)", ox, oy);
                    errors = errors + 1; n_cut = n_cut + 1;
                end
                in_frame = 1; ox = 0; oy = 0;
            end
            if (in_frame) begin
                e_px = ox;
                if (exp_pat) e_c = (ox >= 200 && ox < 440 && oy >= 160 && oy < 320) ?
                                   16'h0000 : {5'd20, 6'd40, 5'd20};
                else         e_c = {e_px[8:4], e_px[9:4], e_px[8:4]};
                e_axis = {e_c[15:11], e_c[15:13], e_c[4:0], e_c[4:2], e_c[10:5], e_c[10:9]};
                if (pix_chk && v_data !== e_axis) begin
                    if (errors < 10)
                        $display("[TB] NG pixel (%0d,%0d) = %h, exp %h", ox, oy, v_data, e_axis);
                    errors = errors + 1;
                end
                if (v_user !== (ox == 0 && oy == 0)) begin
                    if (errors < 10) $display("[TB] NG tuser at (%0d,%0d)", ox, oy);
                    errors = errors + 1;
                end
                if (v_last !== (ox == W - 1)) begin
                    if (errors < 10) $display("[TB] NG tlast at (%0d,%0d)", ox, oy);
                    errors = errors + 1;
                end
                if (ox == W - 1) begin
                    ox = 0; oy = oy + 1;
                    if (oy == H) begin
                        in_frame = 0;
                        n_frames = n_frames + 1;
                        $display("[TB] %0t : frame %0d ok (640x480)", $time, n_frames);
                    end
                end else
                    ox = ox + 1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // シーケンス
    // -------------------------------------------------------------------------
    integer n0, n13;
    initial begin
        repeat (20) @(posedge clk);
        btn_rst = 1'b0;
        $display("[TB] reset released");

        // 1. 設定
        wait (u_dut.cam_ddr_cfg_done);
        $display("[TB] %0t : cfg done, %0d writes, error=%0d",
                 $time, u_dut.fb_test_i.n_wr, u_dut.cam_ddr_cfg_err);
        if (u_dut.fb_test_i.n_wr != 20 || u_dut.cam_ddr_cfg_err) errors = errors + 1;

        // 2. カメラ 2 フレーム (最初の不完全なフレームは mux が捨てる)
        wait (n_frames >= 2);

        // 3. VGA 出力
        //    ACTIVE_VIDEO=0 (ブランキング) なら RGB = 0
        u_dut.fb_test_i.ACTIVE_VIDEO = 1'b0;
        @(posedge u_dut.pclk); @(posedge u_dut.pclk);
        if (vga_r !== 4'd0 || vga_g !== 4'd0 || vga_b !== 4'd0) begin
            $display("[TB] NG VGA out in blanking = %h %h %h (exp 0 0 0)", vga_r, vga_g, vga_b);
            errors = errors + 1;
        end
        //    有効期間: スタブの RGB = (R, G, B) = (0xC8, 0xFF, 0x30)
        //    R: ディザで 12 / 13。横 4 画素 (Bayer の 1 行) のうち 13 は 2 画素 (閾値 < 8 が各行 2 個)
        //    G: 0xFF → 常に 15 (飽和) / B: 0x30 → 常に 3 (下位 0 は切り上げない)
        @(posedge u_dut.pclk);
        u_dut.fb_test_i.ACTIVE_VIDEO = 1'b1;
        @(posedge u_dut.pclk); #1;           // ここから出力レジスタに dx=0 の画素が入る
        n13 = 0;
        repeat (4) begin
            @(posedge u_dut.pclk); #1;
            if ((vga_r !== 4'd12 && vga_r !== 4'd13) || vga_g !== 4'd15 || vga_b !== 4'd3) begin
                $display("[TB] NG VGA out = %h %h %h (exp R=12/13 G=15 B=3)", vga_r, vga_g, vga_b);
                errors = errors + 1;
            end
            if (vga_r == 4'd13) n13 = n13 + 1;
        end
        $display("[TB] dither: R %0d / 4 pixels = 13 (exp 2), G=15 B=3", n13);
        if (n13 != 2) errors = errors + 1;

        // 4. SW3 試験パターン: 切替直後のフレームは見ず, 次の 1 フレームを検査
        pix_chk = 1'b0;
        sw_pat  = 1'b1;
        n0 = n_frames;
        wait (n_frames >= n0 + 2);
        exp_pat = 1'b1; pix_chk = 1'b1;
        wait (n_frames >= n0 + 3);
        $display("[TB] %0t : test pattern frame checked", $time);

        // 5. ステータス
        if (u_dut.cam_ddr_ovf) begin $display("[TB] NG FIFO overflow"); errors = errors + 1; end
        if (led[2:0] !== 3'b011) begin
            $display("[TB] NG led = %b (exp x011)", led); errors = errors + 1;
        end

        if (errors == 0) $display("[TB] *** PASS ***");
        else             $display("[TB] *** FAIL : %0d errors ***", errors);
        $finish;
    end

    initial begin
        #300_000_000;
        $display("[TB] TIMEOUT (frames=%0d)", n_frames);
        $finish;
    end

endmodule

// =============================================================================
// スタブ (シミュレーション専用)
//   SYSCLK / SYSRST_N を出し, S_AXI_CFG は常に OKAY で応答, S_AXIS_VID は
//   ときどき tready を落とす。init_calib_complete は少し後に 1。
// =============================================================================
module fb_test (
    input  wire CLK, input wire RESET,
    output wire [23:0] RGB, output wire HSYNC, output wire VSYNC,
    output wire HSYNC_1, output wire VSYNC_1, output wire [31:0] status,
    output reg  ACTIVE_VIDEO = 1'b1,
    output reg  init_calib_complete = 1'b0,
    inout  wire [7:0] ddr3_dq, inout wire [0:0] ddr3_dqs_p, inout wire [0:0] ddr3_dqs_n,
    output wire [13:0] ddr3_addr, output wire [2:0] ddr3_ba,
    output wire ddr3_ras_n, output wire ddr3_cas_n, output wire ddr3_we_n, output wire ddr3_reset_n,
    output wire [0:0] ddr3_ck_p, output wire [0:0] ddr3_ck_n, output wire [0:0] ddr3_cke,
    output wire [0:0] ddr3_cs_n, output wire [0:0] ddr3_dm, output wire [0:0] ddr3_odt,
    // カメラ → DDR3 用ポート (cam_ddr_bd.tcl)
    output reg  SYSCLK = 1'b0, output reg SYSRST_N = 1'b0,
    output wire [23:0] M_AXIS_TPG_tdata, output wire M_AXIS_TPG_tvalid, input wire M_AXIS_TPG_tready,
    output wire M_AXIS_TPG_tlast, output wire M_AXIS_TPG_tuser,
    input  wire [23:0] S_AXIS_VID_tdata, input wire S_AXIS_VID_tvalid, output reg S_AXIS_VID_tready = 1'b0,
    input  wire S_AXIS_VID_tlast, input wire S_AXIS_VID_tuser, input wire [2:0] S_AXIS_VID_tkeep,
    input  wire [2:0] S_AXI_CFG_awprot, input wire [2:0] S_AXI_CFG_arprot,
    input  wire [31:0] S_AXI_CFG_awaddr, input wire S_AXI_CFG_awvalid, output wire S_AXI_CFG_awready,
    input  wire [31:0] S_AXI_CFG_wdata, input wire [3:0] S_AXI_CFG_wstrb, input wire S_AXI_CFG_wvalid,
    output wire S_AXI_CFG_wready, output wire [1:0] S_AXI_CFG_bresp, output reg S_AXI_CFG_bvalid = 1'b0,
    input  wire S_AXI_CFG_bready,
    input  wire [31:0] S_AXI_CFG_araddr, input wire S_AXI_CFG_arvalid, output wire S_AXI_CFG_arready,
    output wire [31:0] S_AXI_CFG_rdata, output wire [1:0] S_AXI_CFG_rresp, output wire S_AXI_CFG_rvalid,
    input  wire S_AXI_CFG_rready
);
    assign RGB = {8'hC8, 8'h30, 8'hFF};    // AXI4-Stream Video 順 {R, B, G} assign HSYNC = 1'b0; assign VSYNC = 1'b0;
    assign HSYNC_1 = 1'b0; assign VSYNC_1 = 1'b0; assign status = 32'h0;

    always #5 SYSCLK = ~SYSCLK;
    initial begin
        #1000  SYSRST_N = 1'b1;
        #5000  init_calib_complete = 1'b1;
    end

    assign M_AXIS_TPG_tdata = 24'h0; assign M_AXIS_TPG_tvalid = 1'b0;
    assign M_AXIS_TPG_tlast = 1'b0;  assign M_AXIS_TPG_tuser  = 1'b0;

    always @(posedge SYSCLK) S_AXIS_VID_tready <= ($random & 3) != 0;   // 約 75 %

    // AXI4-Lite: AW と W が両方来たら 1 回分として BRESP=OKAY を返す
    integer n_wr = 0;
    reg got_aw = 0, got_w = 0;
    assign S_AXI_CFG_awready = !got_aw;
    assign S_AXI_CFG_wready  = !got_w;
    assign S_AXI_CFG_bresp   = 2'b00;
    always @(posedge SYSCLK) begin
        if (S_AXI_CFG_awvalid && !got_aw) got_aw <= 1'b1;
        if (S_AXI_CFG_wvalid  && !got_w ) got_w  <= 1'b1;
        if (got_aw && got_w && !S_AXI_CFG_bvalid) begin
            S_AXI_CFG_bvalid <= 1'b1;
            n_wr = n_wr + 1;
        end
        if (S_AXI_CFG_bvalid && S_AXI_CFG_bready) begin
            S_AXI_CFG_bvalid <= 1'b0; got_aw <= 1'b0; got_w <= 1'b0;
        end
    end
    assign S_AXI_CFG_arready = 1'b1; assign S_AXI_CFG_rdata = 32'h0;
    assign S_AXI_CFG_rresp = 2'b00;  assign S_AXI_CFG_rvalid = 1'b0;
endmodule

module ila_cam (
    input wire clk, input wire [7:0] probe0, input wire [3:0] probe1,
    input wire [16:0] probe2, input wire [7:0] probe3, input wire [11:0] probe4
);
endmodule
