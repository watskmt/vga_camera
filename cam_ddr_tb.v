`timescale 1ns / 1ps
// =============================================================================
// cam_ddr_tb.v  -  cam_ddr (カメラ → AXI4-Stream Video, TPG 切替, VDMA/TPG 設定) の検証
// =============================================================================
// 検証内容:
//   1. cam_ddr_cfg : AXI4-Lite 書き込み 20 個が表の順・値どおりか, BRESP エラーなし
//   2. カメラ経路 : 出力フレームが CAM_W×CAM_H (UP=1 なら 2 倍) で,
//                   画素 (x,y) = カメラ (x,y) (UP=1 なら (x/2, y/2)),
//                   tuser は先頭 1 ビートのみ, tlast は各行の最終ビートのみ
//   3. 切替       : sel_tpg を途中で切り替えても, 出力される各フレームは
//                   1 つの入力元だけで完結している (途中で混ざらない)
//   ※ 高速化のため CAM_W=32, CAM_H=16 で検証する
//
// 実行 (xsim):
//   xvlog cam_ddr_tb.v cam_ddr.v glbl.v
//   xelab -L xpm -L unisims_ver cam_ddr_tb glbl -s cam_ddr_tb
//   xsim cam_ddr_tb -R
//   (2 倍拡大の検証は xvlog に -d TB_UPSCALE を付ける)
// =============================================================================
module cam_ddr_tb;
`ifdef TB_UPSCALE
    localparam UP = 1;
`else
    localparam UP = 0;
`endif
    localparam CAM_W = 32, CAM_H = 16;
    localparam OW = UP ? CAM_W * 2 : CAM_W, OH = UP ? CAM_H * 2 : CAM_H;

    reg cam_clk = 0, aclk = 0;
    always #20.8 cam_clk = ~cam_clk;   // 24 MHz
    always #5    aclk    = ~aclk;      // 100 MHz

    reg cam_rst_n = 0, aresetn = 0;
    reg sel_tpg = 0, calib_done = 0;

    integer errors = 0;

    // -------------------------------------------------------------------------
    // カメラモデル: 2 クロックに 1 画素, 行間/フレーム間にブランク
    //   画素値 = (col*5 + row*7 + frame*16) & 0xFF
    // -------------------------------------------------------------------------
    reg        pix_we = 0, pix_sof = 0, pix_eol = 0;
    reg [15:0] pix_rgb = 0;
    integer    cam_frame = 0;

    function [7:0] cam_val;
        input integer c, r, f;
        cam_val = (c * 5 + r * 7 + f * 16) & 8'hFF;
    endfunction
    // カメラの RGB565 = {1'b0, v[7:4], v[7:2], v[6:2]} (v = cam_val)
    //   R の MSB は 0 (R8 < 0x80 なので TPG の R=0xA5 と区別できる)
    // AXI4-Stream Video {R, B, G} への拡張は cam_ddr と同じ:
    //   {c[15:11], c[15:13], c[4:0], c[4:2], c[10:5], c[10:9]}
    // ※ xsim では関数の入れ子呼び出しが X になることがあるため, レジスタ経由で計算する
    reg [7:0] st_v;

    integer cr, cc, k;
    initial begin
        @(posedge cam_rst_n);
        repeat (50) @(posedge cam_clk);
        forever begin
            for (cr = 0; cr < CAM_H; cr = cr + 1) begin
                for (cc = 0; cc < CAM_W; cc = cc + 1) begin
                    @(posedge cam_clk); pix_we <= 1'b0;
                    @(posedge cam_clk);
                    pix_we   <= 1'b1;
                    pix_sof  <= (cr == 0 && cc == 0);
                    pix_eol  <= (cc == CAM_W - 1);
                    st_v      = cam_val(cc, cr, cam_frame);
                    pix_rgb  <= {1'b0, st_v[7:4], st_v[7:2], st_v[6:2]};
                end
                @(posedge cam_clk); pix_we <= 1'b0;
                repeat (40) @(posedge cam_clk);          // 水平ブランク
            end
            repeat (400) @(posedge cam_clk);             // 垂直ブランク
            cam_frame = cam_frame + 1;
        end
    end

    // -------------------------------------------------------------------------
    // TPG モデル: OW×OH, データ = {8'hA5, x, y} (カメラは R < 0x80 なので区別できる)
    // -------------------------------------------------------------------------
    reg  [23:0] tpg_tdata = 0;
    reg         tpg_tvalid = 0, tpg_tlast = 0, tpg_tuser = 0;
    wire        tpg_tready;
    integer     tx = 0, ty = 0;

    always @(posedge aclk) begin
        if (!aresetn) begin
            tpg_tvalid <= 1'b0; tx = 0; ty = 0;
        end else if (!tpg_tvalid || tpg_tready) begin
            tpg_tvalid <= 1'b1;
            tpg_tdata  <= {8'hA5, tx[7:0], ty[7:0]};
            tpg_tuser  <= (tx == 0 && ty == 0);
            tpg_tlast  <= (tx == OW - 1);
            if (tx == OW - 1) begin
                tx = 0;
                ty = (ty == OH - 1) ? 0 : ty + 1;
            end else
                tx = tx + 1;
        end
    end

    // -------------------------------------------------------------------------
    // DUT
    // -------------------------------------------------------------------------
    wire [23:0] vid_tdata;
    wire        vid_tvalid, vid_tlast, vid_tuser;
    reg         vid_tready = 0;

    wire [31:0] awaddr, wdata, araddr;
    wire        awvalid, wvalid, bready, arvalid, rready;
    wire [3:0]  wstrb;
    reg         awready = 0, wready = 0, bvalid = 0;
    wire        cfg_done, cfg_error, fifo_ovf;

    cam_ddr #(.CAM_W(CAM_W), .CAM_H(CAM_H), .UPSCALE(UP), .CFG_WAIT(20)) dut (
        .cam_clk(cam_clk), .cam_rst_n(cam_rst_n),
        .pix_we(pix_we), .pix_sof(pix_sof), .pix_eol(pix_eol), .pix_rgb(pix_rgb),
        .aclk(aclk), .aresetn(aresetn), .sel_tpg(sel_tpg), .calib_done(calib_done),
        .s_tpg_tdata(tpg_tdata), .s_tpg_tvalid(tpg_tvalid), .s_tpg_tready(tpg_tready),
        .s_tpg_tlast(tpg_tlast), .s_tpg_tuser(tpg_tuser),
        .m_vid_tdata(vid_tdata), .m_vid_tvalid(vid_tvalid), .m_vid_tready(vid_tready),
        .m_vid_tlast(vid_tlast), .m_vid_tuser(vid_tuser),
        .m_axi_awaddr(awaddr), .m_axi_awvalid(awvalid), .m_axi_awready(awready),
        .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wvalid(wvalid), .m_axi_wready(wready),
        .m_axi_bresp(2'b00), .m_axi_bvalid(bvalid), .m_axi_bready(bready),
        .m_axi_araddr(araddr), .m_axi_arvalid(arvalid), .m_axi_arready(1'b0),
        .m_axi_rdata(32'h0), .m_axi_rresp(2'b00), .m_axi_rvalid(1'b0), .m_axi_rready(rready),
        .cfg_done(cfg_done), .cfg_error(cfg_error), .fifo_ovf(fifo_ovf)
    );

    // VDMA 側はランダムに tready を落とす (約 70 %)
    always @(posedge aclk) vid_tready <= ($random & 3) != 0;

    // -------------------------------------------------------------------------
    // AXI4-Lite スレーブモデル (AW/W を独立にランダム遅延で受ける)
    // -------------------------------------------------------------------------
    reg [31:0] exp_addr [0:19];
    reg [31:0] exp_data [0:19];
    initial begin
        exp_addr[ 0]=32'h44A1_0010; exp_data[ 0]=OH;
        exp_addr[ 1]=32'h44A1_0018; exp_data[ 1]=OW;
        exp_addr[ 2]=32'h44A1_0020; exp_data[ 2]=1;
        exp_addr[ 3]=32'h44A1_0028; exp_data[ 3]=0;
        exp_addr[ 4]=32'h44A1_0040; exp_data[ 4]=0;
        exp_addr[ 5]=32'h44A1_0000; exp_data[ 5]=32'h81;
        exp_addr[ 6]=32'h44A0_0030; exp_data[ 6]=32'h0001_0003;
        exp_addr[ 7]=32'h44A0_00AC; exp_data[ 7]=32'h8000_0000;
        exp_addr[ 8]=32'h44A0_00B0; exp_data[ 8]=32'h8000_0000;
        exp_addr[ 9]=32'h44A0_00B4; exp_data[ 9]=32'h8000_0000;
        exp_addr[10]=32'h44A0_00A8; exp_data[10]=OW*3;
        exp_addr[11]=32'h44A0_00A4; exp_data[11]=OW*3;
        exp_addr[12]=32'h44A0_00A0; exp_data[12]=OH;
        exp_addr[13]=32'h44A0_0000; exp_data[13]=32'h0001_0003;
        exp_addr[14]=32'h44A0_005C; exp_data[14]=32'h8000_0000;
        exp_addr[15]=32'h44A0_0060; exp_data[15]=32'h8000_0000;
        exp_addr[16]=32'h44A0_0064; exp_data[16]=32'h8000_0000;
        exp_addr[17]=32'h44A0_0058; exp_data[17]=OW*3;
        exp_addr[18]=32'h44A0_0054; exp_data[18]=OW*3;
        exp_addr[19]=32'h44A0_0050; exp_data[19]=OH;
    end

    integer   n_wr = 0;
    reg       got_aw = 0, got_w = 0;
    reg [31:0] cap_addr, cap_data;
    always @(posedge aclk) begin
        awready <= ($random & 1);
        wready  <= ($random & 1);
        if (awvalid && awready && !got_aw) begin got_aw <= 1; cap_addr <= awaddr; end
        if (wvalid  && wready  && !got_w ) begin got_w  <= 1; cap_data <= wdata;  end
        if (got_aw && got_w && !bvalid) begin
            bvalid <= 1'b1;
            if (n_wr >= 20 || cap_addr !== exp_addr[n_wr] || cap_data !== exp_data[n_wr]) begin
                $display("[TB] NG cfg write %0d: %h <= %h (exp %h <= %h)",
                         n_wr, cap_addr, cap_data, exp_addr[n_wr], exp_data[n_wr]);
                errors = errors + 1;
            end
            n_wr = n_wr + 1;
        end
        if (bvalid && bready) begin bvalid <= 1'b0; got_aw <= 0; got_w <= 0; end
    end

    // -------------------------------------------------------------------------
    // 出力フレームのチェック
    // -------------------------------------------------------------------------
    integer ox = 0, oy = 0, in_frame = 0, src = 0;   // src: 1=カメラ 2=TPG
    integer f_cam = 0, f_tpg = 0, f_bad = 0;
    integer first_cam_frame = -1;
    reg [23:0] cy_exp;
    reg [7:0]  ck_v;
    reg [15:0] ck_c;

    always @(posedge aclk) begin
        if (vid_tvalid && vid_tready) begin
            if (vid_tuser) begin
                if (in_frame) begin
                    $display("[TB] NG frame cut at (%0d,%0d)", ox, oy);
                    errors = errors + 1; f_bad = f_bad + 1;
                end
                in_frame = 1; ox = 0; oy = 0;
                src = (vid_tdata[23:16] == 8'hA5 && vid_tdata[15:8] != 8'hA5) ? 2 : 1;
            end
            if (in_frame) begin
                // 画素内容
                if (src == 2) begin
                    if (vid_tdata !== {8'hA5, ox[7:0], oy[7:0]}) begin
                        if (errors < 20) $display("[TB] NG tpg pixel (%0d,%0d)=%h", ox, oy, vid_tdata);
                        errors = errors + 1;
                    end
                end else begin
                    // 最初のカメラフレームでフレーム番号を決め, 以降はその値と比較
                    if (ox == 0 && oy == 0)
                        for (k = 0; k < 16; k = k + 1) begin
                            ck_v = cam_val(0, 0, k);
                            ck_c = {1'b0, ck_v[7:4], ck_v[7:2], ck_v[6:2]};
                            if ({ck_c[15:11], ck_c[15:13], ck_c[4:0], ck_c[4:2], ck_c[10:5], ck_c[10:9]} == vid_tdata)
                                first_cam_frame = k;
                        end
                    ck_v   = UP ? cam_val(ox / 2, oy / 2, first_cam_frame)
                                : cam_val(ox, oy, first_cam_frame);
                    ck_c   = {1'b0, ck_v[7:4], ck_v[7:2], ck_v[6:2]};
                    cy_exp = {ck_c[15:11], ck_c[15:13], ck_c[4:0], ck_c[4:2], ck_c[10:5], ck_c[10:9]};
                    if (vid_tdata !== cy_exp) begin
                        if (errors < 20)
                            $display("[TB] NG cam pixel (%0d,%0d)=%h exp %h", ox, oy, vid_tdata, cy_exp);
                        errors = errors + 1;
                    end
                end
                // tuser / tlast の位置
                if (vid_tuser !== (ox == 0 && oy == 0)) begin
                    $display("[TB] NG tuser at (%0d,%0d)", ox, oy); errors = errors + 1;
                end
                if (vid_tlast !== (ox == OW - 1)) begin
                    if (errors < 20) $display("[TB] NG tlast at (%0d,%0d)", ox, oy);
                    errors = errors + 1;
                end
                // 座標を進める
                if (ox == OW - 1) begin
                    ox = 0; oy = oy + 1;
                    if (oy == OH) begin
                        in_frame = 0;
                        if (src == 2) f_tpg = f_tpg + 1;
                        else begin
                            f_cam = f_cam + 1;
                            first_cam_frame = -1;   // 次のカメラフレームで再判定
                        end
                    end
                end else
                    ox = ox + 1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // シーケンス
    // -------------------------------------------------------------------------
    integer cam_at_switch;
    initial begin
        repeat (10) @(posedge aclk);
        cam_rst_n = 1; aresetn = 1;
        repeat (100) @(posedge aclk);
        calib_done = 1;

        wait (cfg_done);
        $display("[TB] %0t ns : cfg done, %0d writes, error=%0d", $time, n_wr, cfg_error);
        if (n_wr != 20 || cfg_error) errors = errors + 1;

        // カメラ 3 フレーム
        wait (f_cam >= 3);
        $display("[TB] %0t ns : camera frames ok = %0d", $time, f_cam);

        // TPG へ切替 → 5 フレーム
        sel_tpg = 1;
        wait (f_tpg >= 5);
        $display("[TB] %0t ns : tpg frames ok = %0d", $time, f_tpg);

        // カメラへ戻す → 2 フレーム
        cam_at_switch = f_cam;
        sel_tpg = 0;
        wait (f_cam >= cam_at_switch + 2);
        $display("[TB] %0t ns : camera frames ok = %0d (after switch back)", $time, f_cam);

        if (fifo_ovf) begin $display("[TB] NG fifo overflow"); errors = errors + 1; end
        if (errors == 0) $display("[TB] *** PASS ***");
        else             $display("[TB] *** FAIL : %0d errors ***", errors);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("[TB] TIMEOUT (cam=%0d tpg=%0d writes=%0d)", f_cam, f_tpg, n_wr);
        $finish;
    end
endmodule
