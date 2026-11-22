`timescale 1ns / 1ps
`default_nettype none
// =============================================================================
// vga_top.v  -  VGA カメラ トップレベル (Arty A7-35T)
// =============================================================================
// データパス (12bit カラー RGB444 出力, 640×480):
//
//   [OV7670]  VGA 640×480, RGB565, 2 byte/画素
//       │  cam_pclk ドメイン
//       ▼
//   [ov7670_if / ov7670_capture]  RGB565 + {sof, eol} の画素ストリーム
//       ▼
//   [cam_ddr]  非同期 FIFO → AXI4-Stream Video (RGB888) → TPG と切替 (SW0)
//       │  SYSCLK (100 MHz, BD) ドメイン
//       ▼
//   [fb_test BD]  VDMA S2MM → DDR3 (0x8000_0000) → VDMA MM2S → v_axi4s_vid_out (v_tc 640×480)
//       │  RGB888 / HSYNC / VSYNC
//       ▼
//   RGB888 → 各色 4×4 Bayer ディザで 4bit → 出力レジスタ (IOB) → PmodVGA (RGB444)
//
// クロックドメイン:
//   clk    (100 MHz) : システム / SCCB / XCLK 生成
//   clk100 (100 MHz) : MMCM 出力, fb_test BD の CLK 入力
//   pclk   ( 25 MHz) : VGA 出力レジスタ / ILA (MMCM 生成)
//   cam_pclk         : OV7670 ピクセルクロック
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
    output wire [3:0]  led,        // [0]=MIG calib, [1]=VDMA/TPG 設定完了, [2]=エラー, [3]=OV7670 PID OK

    // ── スイッチ ──────────────────────────────────────────
    input  wire        sw_test,    // SW0: High=TPG (水平ランプ) / Low=カメラ
    input  wire        sw_agc_hold,// SW2: High=AGC/AEC 停止 (今のゲイン・露光で固定, 横帯の切り分け用)
    input  wire        sw_pat,     // SW3: High=カメラ画素を試験パターン (灰色地に黒い四角) に置換

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
    output wire [0:0]  ddr3_odt,

    // ── Ethernet (TI DP83848J, MII 10/100) ───────────────
    output wire        eth_ref_clk,  // PHY 用 25 MHz
    output wire        eth_rstn,     // PHY リセット (負論理)
    input  wire        eth_tx_clk,
    output wire        eth_tx_en,
    output wire [3:0]  eth_txd,
    input  wire        eth_rx_clk,
    input  wire        eth_rx_dv,
    input  wire        eth_rxerr,
    input  wire [3:0]  eth_rxd,
    input  wire        eth_col,
    input  wire        eth_crs,
    output wire        eth_mdc,
    inout  wire        eth_mdio,

    // ── USB-UART (FT2232H, 115200 bps) ───────────────────
    input  wire        uart_txd_in,  // PC → FPGA
    output wire        uart_rxd_out  // FPGA → PC
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
    // =========================================================================
    wire [23:0] fbt_rgb;          // AXI4-Stream Video 順: [23:16]=R [15:8]=B [7:0]=G
    wire        fbt_hsync;        // v_axi4s_vid_out 出力 (データと位相一致, High アクティブ)
    wire        fbt_vsync;
    wire        fbt_vtc_hsync;    // v_tc 直出し (デバッグ用)
    wire        fbt_vtc_vsync;
    wire [31:0] fbt_status;
    wire        fbt_de;           // v_axi4s_vid_out vid_active_video (RGB と位相一致)
    wire        ddr3_calib_done;  // MIG init_calib_complete

    // ── BD との接続 (cam_ddr.v / cam_ddr_bd.tcl) ──
    //   SYSCLK (100 MHz, BD 内 clk_wiz_0/sysclk) ドメイン
    wire        bd_sysclk;
    wire        bd_sysrst_n;
    wire [23:0] tpg_tdata;        // v_tpg_0 出力 (BD → RTL)
    wire        tpg_tvalid, tpg_tready, tpg_tlast, tpg_tuser;
    wire [23:0] vid_tdata;        // VDMA S2MM 入力 (RTL → BD)
    wire        vid_tvalid, vid_tready, vid_tlast, vid_tuser;
    wire [31:0] cfg_awaddr, cfg_wdata, cfg_araddr, cfg_rdata;
    wire [3:0]  cfg_wstrb;
    wire [1:0]  cfg_bresp, cfg_rresp;
    wire        cfg_awvalid, cfg_awready, cfg_wvalid, cfg_wready, cfg_bvalid, cfg_bready;
    wire        cfg_arvalid, cfg_arready, cfg_rvalid, cfg_rready;

    // ── Ethernet / UART (eth_bd.tcl) ──
    wire        mdio_i, mdio_o, mdio_t;

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
        .ACTIVE_VIDEO        (fbt_de),        // cam_ddr_bd.tcl で追加
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
        .ddr3_odt            (ddr3_odt),
        // ── カメラ → DDR3 用 (cam_ddr_bd.tcl で追加) ──
        .SYSCLK              (bd_sysclk),
        .SYSRST_N            (bd_sysrst_n),
        .M_AXIS_TPG_tdata    (tpg_tdata),
        .M_AXIS_TPG_tvalid   (tpg_tvalid),
        .M_AXIS_TPG_tready   (tpg_tready),
        .M_AXIS_TPG_tlast    (tpg_tlast),
        .M_AXIS_TPG_tuser    (tpg_tuser),
        .S_AXIS_VID_tdata    (vid_tdata),
        .S_AXIS_VID_tvalid   (vid_tvalid),
        .S_AXIS_VID_tready   (vid_tready),
        .S_AXIS_VID_tlast    (vid_tlast),
        .S_AXIS_VID_tuser    (vid_tuser),
        .S_AXIS_VID_tkeep    (3'b111),        // VDMA S2MM 側から伝搬する (全バイト有効)
        .S_AXI_CFG_awaddr    (cfg_awaddr),
        .S_AXI_CFG_awprot    (3'b000),
        .S_AXI_CFG_arprot    (3'b000),
        .S_AXI_CFG_awvalid   (cfg_awvalid),
        .S_AXI_CFG_awready   (cfg_awready),
        .S_AXI_CFG_wdata     (cfg_wdata),
        .S_AXI_CFG_wstrb     (cfg_wstrb),
        .S_AXI_CFG_wvalid    (cfg_wvalid),
        .S_AXI_CFG_wready    (cfg_wready),
        .S_AXI_CFG_bresp     (cfg_bresp),
        .S_AXI_CFG_bvalid    (cfg_bvalid),
        .S_AXI_CFG_bready    (cfg_bready),
        .S_AXI_CFG_araddr    (cfg_araddr),
        .S_AXI_CFG_arvalid   (cfg_arvalid),
        .S_AXI_CFG_arready   (cfg_arready),
        .S_AXI_CFG_rdata     (cfg_rdata),
        .S_AXI_CFG_rresp     (cfg_rresp),
        .S_AXI_CFG_rvalid    (cfg_rvalid),
        .S_AXI_CFG_rready    (cfg_rready),
        // ── Ethernet (AXI EthernetLite, eth_bd.tcl で追加) ──
        .MII_col             (eth_col),
        .MII_crs             (eth_crs),
        .MII_rst_n           (eth_rstn),
        .MII_rx_clk          (eth_rx_clk),
        .MII_rx_dv           (eth_rx_dv),
        .MII_rx_er           (eth_rxerr),
        .MII_rxd             (eth_rxd),
        .MII_tx_clk          (eth_tx_clk),
        .MII_tx_en           (eth_tx_en),
        .MII_txd             (eth_txd),
        .MDIO_mdc            (eth_mdc),
        .MDIO_mdio_i         (mdio_i),
        .MDIO_mdio_o         (mdio_o),
        .MDIO_mdio_t         (mdio_t),
        // ── USB-UART (AXI UARTLite, eth_bd.tcl で追加) ──
        .UART_rxd            (uart_txd_in),
        .UART_txd            (uart_rxd_out)
    );

    // MDIO (双方向, オープンドレインではなく T で Hi-Z 制御)
    IOBUF u_mdio_iobuf (.I(mdio_o), .O(mdio_i), .T(mdio_t), .IO(eth_mdio));

    // PHY 用 25 MHz (MMCM の pclk を ODDR でピンへ出す)
    ODDR #(
        .DDR_CLK_EDGE ("OPPOSITE_EDGE"),
        .INIT         (1'b0),
        .SRTYPE       ("SYNC")
    ) u_eth_ref_oddr (
        .Q  (eth_ref_clk),
        .C  (pclk),
        .CE (1'b1),
        .D1 (1'b1),
        .D2 (1'b0),
        .R  (1'b0),
        .S  (1'b0)
    );

    // RGB888 の各色 (4bit 化は 4. のディザ)。輝度 Y = (77R + 150G + 29B) / 256 は ILA 表示用
    wire [7:0]  fbt_r8 = fbt_rgb[23:16];
    wire [7:0]  fbt_b8 = fbt_rgb[15:8];
    wire [7:0]  fbt_g8 = fbt_rgb[7:0];
    wire [15:0] fbt_ysum = fbt_r8 * 8'd77 + fbt_g8 * 8'd150 + fbt_b8 * 8'd29;
    wire [7:0]  fbt_y8   = fbt_ysum[15:8];
    // v_tc の同期は High アクティブ (GEN_H/VSYNC_POLARITY = High) → 反転して VGA の負論理に
    //   ただの ~ だと opt_design が反転を IOB 出力 FF の D ピンに押し込み、
    //   配置エラー (Place 30-1008: inverted D pin) になる。
    //   DONT_TOUCH の LUT1 で反転をファブリック側に残す。
    wire       fbt_hs, fbt_vs;
    (* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'b01)) u_hs_inv (.I0(fbt_hsync), .O(fbt_hs));
    (* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'b01)) u_vs_inv (.I0(fbt_vsync), .O(fbt_vs));

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
    wire        pix_clk;
    wire        pix_we, pix_sof, pix_eol;
    wire [15:0] pix_rgb;    // RGB565
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
        // 画素ストリーム (→ cam_ddr)
        .pix_clk    (pix_clk),
        .pix_we     (pix_we),
        .pix_sof    (pix_sof),
        .pix_eol    (pix_eol),
        .pix_rgb    (pix_rgb),
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
        .sw3        (sw_pat),   // SW3: 試験パターン (H サグの切り分け用)
        .agc_hold   (sw_agc_hold)
    );

    // =========================================================================
    // 3a. カメラ → DDR3 (fb_test の VDMA S2MM へ)
    //     640×480 の RGB565 を AXI4-Stream Video (RGB888) にする。
    //     SW0 で入力元を選ぶ: SW0=0: カメラ / SW0=1: TPG (水平ランプ)。切替はフレーム境界。
    //     VDMA / TPG のレジスタは MIG キャリブ完了後に cam_ddr_cfg が自動設定する。
    // =========================================================================
    wire cam_ddr_cfg_done, cam_ddr_cfg_err, cam_ddr_ovf;

    cam_ddr u_cam_ddr (
        .cam_clk       (pix_clk),
        .cam_rst_n     (rst_n_cam),
        .pix_we        (pix_we),
        .pix_sof       (pix_sof),
        .pix_eol       (pix_eol),
        .pix_rgb       (pix_rgb),
        .aclk          (bd_sysclk),
        .aresetn       (bd_sysrst_n),
        .sel_tpg       (sw_test),
        .calib_done    (ddr3_calib_done),
        .s_tpg_tdata   (tpg_tdata),  .s_tpg_tvalid (tpg_tvalid), .s_tpg_tready (tpg_tready),
        .s_tpg_tlast   (tpg_tlast),  .s_tpg_tuser  (tpg_tuser),
        .m_vid_tdata   (vid_tdata),  .m_vid_tvalid (vid_tvalid), .m_vid_tready (vid_tready),
        .m_vid_tlast   (vid_tlast),  .m_vid_tuser  (vid_tuser),
        .m_axi_awaddr  (cfg_awaddr), .m_axi_awvalid(cfg_awvalid), .m_axi_awready(cfg_awready),
        .m_axi_wdata   (cfg_wdata),  .m_axi_wstrb  (cfg_wstrb),   .m_axi_wvalid (cfg_wvalid),
        .m_axi_wready  (cfg_wready), .m_axi_bresp  (cfg_bresp),   .m_axi_bvalid (cfg_bvalid),
        .m_axi_bready  (cfg_bready),
        .m_axi_araddr  (cfg_araddr), .m_axi_arvalid(cfg_arvalid), .m_axi_arready(cfg_arready),
        .m_axi_rdata   (cfg_rdata),  .m_axi_rresp  (cfg_rresp),   .m_axi_rvalid (cfg_rvalid),
        .m_axi_rready  (cfg_rready),
        .cfg_done      (cam_ddr_cfg_done),
        .cfg_error     (cam_ddr_cfg_err),
        .fifo_ovf      (cam_ddr_ovf)
    );

    // =========================================================================
    // 4. VGA 出力 (RGB444 = 12bit カラー, 4×4 Bayer ディザ → 出力レジスタ IOB FF)
    //     fb_test (BD) の映像 RGB888 の各色をディザで 4bit にする (R/G/B とも同じ閾値)。
    //       c4 = c[7:4] + (c[3:0] > M[dy][dx] ? 1 : 0)  (15 で飽和)
    //     画素座標の下位 2bit (dx, dy) は ACTIVE_VIDEO から数える:
    //       dx : 有効期間中に 1 ずつ増え, 有効期間外で 0
    //       dy : 有効期間の終わり (行末) ごとに 1 増え, VSYNC 中に 0
    //     RGB・同期を同じ pclk で 1 段レジスタし、全ピンの変化タイミングを揃える。
    //
    //     有効映像期間 (fbt_de) 以外は RGB = 0 にする。
    //     v_axi4s_vid_out の vid_data はブランキング中も各行の最終画素を出し続けるため、
    //     そのままだとモニタがバックポーチの値 (= 右端の画素) を黒として行ごとにクランプし、
    //     行ごとに明るさが変わる (H サグ) 。
    // =========================================================================
    reg  [1:0] dith_x = 2'd0, dith_y = 2'd0;
    reg        de_d   = 1'b0;
    always @(posedge pclk) begin
        de_d   <= fbt_de;
        dith_x <= fbt_de ? dith_x + 2'd1 : 2'd0;
        if (fbt_vsync)               dith_y <= 2'd0;          // v_tc の VSYNC は High アクティブ
        else if (de_d && !fbt_de)    dith_y <= dith_y + 2'd1; // 行末
    end

    function [3:0] bayer4;
        input [1:0] x, y;
        case ({y, x})
            4'b00_00: bayer4 =  0;  4'b00_01: bayer4 =  8;  4'b00_10: bayer4 =  2;  4'b00_11: bayer4 = 10;
            4'b01_00: bayer4 = 12;  4'b01_01: bayer4 =  4;  4'b01_10: bayer4 = 14;  4'b01_11: bayer4 =  6;
            4'b10_00: bayer4 =  3;  4'b10_01: bayer4 = 11;  4'b10_10: bayer4 =  1;  4'b10_11: bayer4 =  9;
            4'b11_00: bayer4 = 15;  4'b11_01: bayer4 =  7;  4'b11_10: bayer4 = 13;  4'b11_11: bayer4 =  5;
        endcase
    endfunction

    function [3:0] dith4;          // 8bit → 4bit (閾値 m)
        input [7:0] c;
        input [3:0] m;
        dith4 = c[7:4] + {3'b000, (c[3:0] > m) && (c[7:4] != 4'hF)};
    endfunction

    wire [3:0] dith_m = bayer4(dith_x, dith_y);
    wire [3:0] out_r4 = fbt_de ? dith4(fbt_r8, dith_m) : 4'h0;
    wire [3:0] out_g4 = fbt_de ? dith4(fbt_g8, dith_m) : 4'h0;
    wire [3:0] out_b4 = fbt_de ? dith4(fbt_b8, dith_m) : 4'h0;
    (* IOB = "TRUE", keep = "true" *) reg [3:0] vga_r_q = 4'h0;
    (* IOB = "TRUE", keep = "true" *) reg [3:0] vga_g_q = 4'h0;
    (* IOB = "TRUE", keep = "true" *) reg [3:0] vga_b_q = 4'h0;
    (* IOB = "TRUE", keep = "true" *) reg       vga_hs_q = 1'b1;
    (* IOB = "TRUE", keep = "true" *) reg       vga_vs_q = 1'b1;
    always @(posedge pclk) begin
        vga_r_q  <= out_r4;
        vga_g_q  <= out_g4;
        vga_b_q  <= out_b4;
        vga_hs_q <= fbt_hs;
        vga_vs_q <= fbt_vs;
    end
    assign vga_r  = vga_r_q;
    assign vga_g  = vga_g_q;
    assign vga_b  = vga_b_q;
    assign vga_hs = vga_hs_q;
    assign vga_vs = vga_vs_q;

    // =========================================================================
    // 5. ILA デバッグ (合成時のみ有効 — シミュレーションでは無視)
    // =========================================================================
    // ── ila_cam : 唯一の ILA (BASIC ライセンス制限: ILA 1 個 / 5 プローブ以内) ──
    //   プローブ数を抑えるため関連信号を連結している。
    //   Hardware Manager では probe を右クリック → Bus を分割/リネームすると見やすい。
    //
    // probe0 [7:0]  : cam_d                       — カメラ生データ
    // probe1 [3:0]  : {cam_vsync, cam_href, pix_we, byte_phase}
    //                  [3]=VSYNC [2]=HREF [1]=画素出力 [0]=0:byte1/1:byte2
    // probe2 [16:0] : {pix_sof, pix_eol, cam_ddr_ovf, cam_ddr_cfg_done, cam_ddr_cfg_err, 12'b0}
    // probe3 [7:0]  : pix_rgb[15:8]               — カメラ画素 RGB565 の上位バイト (R[4:0], G[5:3])
    // probe4 [11:0] : {vga_hs, vga_vs, ddr3_calib_done, sw_test, fbt_y8[7:0]}
    //                  [11]=HS [10]=VS [9]=DDR3 キャリブ完了 [8]=SW0 [7:0]=BD 映像の輝度
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
        .probe1 ({cam_vsync, cam_href, pix_we, dbg_byte_phase}),
        .probe2 ({pix_sof, pix_eol, cam_ddr_ovf, cam_ddr_cfg_done, cam_ddr_cfg_err, 12'b0}),
        .probe3 (pix_rgb[15:8]),
        .probe4 ({vga_hs, vga_vs, ddr3_calib_done_pclk, sw_test, fbt_y8})
    );

    // =========================================================================
    // 6. ステータス LED (静的表示なので同期化しない)
    // =========================================================================
    assign led[0] = ddr3_calib_done;                               // MIG キャリブ完了
    assign led[1] = cam_ddr_cfg_done;                              // VDMA/TPG 設定完了
    assign led[2] = cam_ddr_cfg_err | cam_ddr_ovf | sio_test_fail; // 設定エラー / FIFO あふれ / OV7670 応答なし
    assign led[3] = sio_test_pass;                                 // OV7670 PID = 0x76

endmodule
`default_nettype wire
