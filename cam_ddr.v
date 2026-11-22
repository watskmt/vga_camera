`timescale 1ns / 1ps
// =============================================================================
// cam_ddr.v  -  カメラ映像を DDR3 (fb_test BD の VDMA) へ流すブリッジ
// =============================================================================
// 構成:
//
//   cam_pclk ドメイン                 SYSCLK (100 MHz) ドメイン
//   ┌──────────────┐  xpm_fifo_async  ┌─────────────┐   ┌──────────┐
//   │ ov7670_if の │ ───────────────► │ (UPSCALE=1  │──►│ cam_ddr_ │──► S_AXIS_VID
//   │ 画素ストリーム│ {sof,eol,RGB565} │  のみ 2 倍) │   │ mux      │    (VDMA S2MM)
//   └──────────────┘                  └─────────────┘   │          │
//                                     M_AXIS_TPG ──────►│ TPG/CAM  │
//                                     (v_tpg_0)         └──────────┘
//                                     cam_ddr_cfg ──► S_AXI_CFG (VDMA / TPG レジスタ設定)
//
//   - カメラ 640×480 の RGB565 を 640×480 の AXI4-Stream Video (24bit RGB888) にする
//     (UPSCALE=1 のときは 320×240 入力を 2 倍拡大: 横は画素を 2 回, 縦は行を 2 回)
//   - sel_tpg=1 で TPG (640×480 水平ランプ) に切替。切替はフレーム境界で行う
//   - DDR3 上のフレームバッファ: 0x8000_0000 から 640×480×3 byte (1 面, 3 スロット共通)
//
// AXI4-Stream Video の約束: tuser = フレーム先頭画素, tlast = 各行の最終画素
// =============================================================================
module cam_ddr #(
    parameter [31:0] VDMA_BASE = 32'h44A0_0000,
    parameter [31:0] TPG_BASE  = 32'h44A1_0000,
    parameter [31:0] FB_ADDR   = 32'h8000_0000,
    parameter        CAM_W     = 640,
    parameter        CAM_H     = 480,
    parameter        UPSCALE   = 0,              // 1: 2 倍拡大して出力 (CAM_W ≤ 320)
    parameter        CFG_WAIT  = 1000,           // 設定開始までの待ち (aclk サイクル)
    parameter        USE_TPG   = 1               // 0: v_tpg_0 なし (TPG のレジスタ設定を飛ばす)
)(
    // ── カメラ側 (cam_pclk ドメイン) ──
    input  wire        cam_clk,
    input  wire        cam_rst_n,
    input  wire        pix_we,
    input  wire        pix_sof,      // フレーム先頭画素
    input  wire        pix_eol,      // 行末画素
    input  wire [15:0] pix_rgb,      // RGB565
    // ── SYSCLK ドメイン ──
    input  wire        aclk,
    input  wire        aresetn,
    input  wire        sel_tpg,      // 非同期 (スイッチ)
    input  wire        calib_done,   // 非同期 (MIG ui_clk ドメイン)
    // TPG 入力
    input  wire [23:0] s_tpg_tdata,
    input  wire        s_tpg_tvalid,
    output wire        s_tpg_tready,
    input  wire        s_tpg_tlast,
    input  wire        s_tpg_tuser,
    // VDMA S2MM へ
    output wire [23:0] m_vid_tdata,
    output wire        m_vid_tvalid,
    input  wire        m_vid_tready,
    output wire        m_vid_tlast,
    output wire        m_vid_tuser,
    // AXI4-Lite マスタ (設定用)
    output wire [31:0] m_axi_awaddr,
    output wire        m_axi_awvalid,
    input  wire        m_axi_awready,
    output wire [31:0] m_axi_wdata,
    output wire [3:0]  m_axi_wstrb,
    output wire        m_axi_wvalid,
    input  wire        m_axi_wready,
    input  wire [1:0]  m_axi_bresp,
    input  wire        m_axi_bvalid,
    output wire        m_axi_bready,
    output wire [31:0] m_axi_araddr,
    output wire        m_axi_arvalid,
    input  wire        m_axi_arready,
    input  wire [31:0] m_axi_rdata,
    input  wire [1:0]  m_axi_rresp,
    input  wire        m_axi_rvalid,
    output wire        m_axi_rready,
    // ステータス
    output wire        cfg_done,
    output wire        cfg_error,    // BRESP != OKAY を一度でも受けた
    output wire        fifo_ovf      // カメラ FIFO あふれ (スティッキー, cam_clk ドメイン)
);

    localparam OUT_W = UPSCALE ? CAM_W * 2 : CAM_W;
    localparam OUT_H = UPSCALE ? CAM_H * 2 : CAM_H;

    // =========================================================================
    // 1. カメラ画素 {sof, eol, RGB565} (cam_clk ドメイン, ov7670_capture が付けた印)
    // =========================================================================
    wire px_in = pix_we;

    // =========================================================================
    // 2. 非同期 FIFO (cam_clk → aclk), FWFT
    // =========================================================================
    wire        fifo_wr_busy, fifo_full, fifo_empty;
    wire        fifo_rd_en;
    wire [17:0] fifo_dout;
    reg         ovf_r;

    // xpm_fifo_async の rst は wr_clk 同期・High アクティブ
    (* ASYNC_REG = "TRUE" *) reg [1:0] cam_rst_sync;
    always @(posedge cam_clk or negedge cam_rst_n)
        if (!cam_rst_n) cam_rst_sync <= 2'b11;
        else            cam_rst_sync <= {cam_rst_sync[0], 1'b0};
    wire fifo_rst = cam_rst_sync[1];

    // 書き込みはフレーム単位:
    //   - VDMA / TPG の設定完了 (cfg_done) 後のフレーム先頭 (sof) から書き始める
    //   - FIFO が満杯になったらそのフレームの残りを捨て, 次の sof から再開する
    (* ASYNC_REG = "TRUE" *) reg [1:0] run_sync;   // cfg_done (aclk) → cam_clk
    always @(posedge cam_clk or negedge cam_rst_n)
        if (!cam_rst_n) run_sync <= 2'b00;
        else            run_sync <= {run_sync[0], cfg_done};

    wire can_wr = !fifo_full && !fifo_wr_busy && !fifo_rst;
    reg  wr_on;                                     // このフレームを書いている
    wire wr_now = pix_sof ? (run_sync[1] && can_wr) : (wr_on && can_wr);
    wire fifo_wr_en = px_in && wr_now;

    always @(posedge cam_clk or negedge cam_rst_n) begin
        if (!cam_rst_n) begin
            wr_on <= 1'b0;
            ovf_r <= 1'b0;
        end else if (px_in) begin
            wr_on <= wr_now;
            // 書くべき画素を FIFO 満杯で捨てたらあふれ (スティッキー)
            if ((pix_sof ? run_sync[1] : wr_on) && !can_wr)
                ovf_r <= 1'b1;
        end
    end
    assign fifo_ovf = ovf_r;

    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE    ("block"),
        .FIFO_WRITE_DEPTH    (1024),
        .WRITE_DATA_WIDTH    (18),
        .READ_DATA_WIDTH     (18),
        .READ_MODE           ("fwft"),
        .FIFO_READ_LATENCY   (0),
        .CDC_SYNC_STAGES     (2),
        .RELATED_CLOCKS      (0),
        .USE_ADV_FEATURES    ("0000"),
        .ECC_MODE            ("no_ecc"),
        .FULL_RESET_VALUE    (1),
        .SIM_ASSERT_CHK      (0),
        .WAKEUP_TIME         (0)
    ) u_fifo (
        .rst           (fifo_rst),
        .wr_clk        (cam_clk),
        .wr_en         (fifo_wr_en),
        .din           ({pix_sof, pix_eol, pix_rgb}),
        .full          (fifo_full),
        .wr_rst_busy   (fifo_wr_busy),
        .rd_clk        (aclk),
        .rd_en         (fifo_rd_en),
        .dout          (fifo_dout),
        .empty         (fifo_empty),
        .rd_rst_busy   (),
        .sleep         (1'b0),
        .injectsbiterr (1'b0),
        .injectdbiterr (1'b0),
        .overflow      (), .prog_full (), .wr_data_count (), .almost_full (), .wr_ack (),
        .underflow     (), .prog_empty(), .rd_data_count (), .almost_empty(), .data_valid (),
        .sbiterr       (), .dbiterr   ()
    );

    // =========================================================================
    // 3. FIFO → AXI4-Stream Video (aclk ドメイン)
    //    UPSCALE=0: そのまま (FWFT の出力を直接 tdata/tlast/tuser に)
    //    UPSCALE=1: 2 倍拡大
    // =========================================================================
    // RGB565 → AXI4-Stream Video 24bit ({R, B, G} の順, 各 8bit)
    //   上位ビットを下位に繰り返して 8bit に広げる (0 → 0x00, 最大 → 0xFF)
    function [23:0] rgb565_axis;
        input [15:0] c;
        rgb565_axis = {c[15:11], c[15:13],     // R
                       c[4:0],   c[4:2],       // B
                       c[10:5],  c[10:9]};     // G
    endfunction

    wire [23:0] cam_tdata;
    wire        cam_tvalid, cam_tready, cam_tlast, cam_tuser;

    generate if (UPSCALE) begin : g_scale
        cam_ddr_scaler #(.CAM_W(CAM_W)) u_scaler (
            .aclk     (aclk),
            .aresetn  (aresetn),
            .s_valid  (!fifo_empty),
            .s_data   (fifo_dout),
            .s_pop    (fifo_rd_en),
            .m_tdata  (cam_tdata),
            .m_tvalid (cam_tvalid),
            .m_tready (cam_tready),
            .m_tlast  (cam_tlast),
            .m_tuser  (cam_tuser)
        );
    end else begin : g_pass
        assign cam_tdata  = rgb565_axis(fifo_dout[15:0]);
        assign cam_tvalid = !fifo_empty;
        assign cam_tlast  = fifo_dout[16];
        assign cam_tuser  = fifo_dout[17];
        assign fifo_rd_en = cam_tready && !fifo_empty;
    end endgenerate

    // =========================================================================
    // 4. TPG / カメラ 切替 (フレーム境界)
    // =========================================================================
    (* ASYNC_REG = "TRUE" *) reg [1:0] sel_sync;
    always @(posedge aclk) sel_sync <= {sel_sync[0], sel_tpg};

    cam_ddr_mux #(.LINES(OUT_H)) u_mux (
        .aclk     (aclk),
        .aresetn  (aresetn),
        .sel      (sel_sync[1]),
        .s0_tdata (cam_tdata),  .s0_tvalid(cam_tvalid),  .s0_tready(cam_tready),
        .s0_tlast (cam_tlast),  .s0_tuser (cam_tuser),
        .s1_tdata (s_tpg_tdata), .s1_tvalid(s_tpg_tvalid), .s1_tready(s_tpg_tready),
        .s1_tlast (s_tpg_tlast), .s1_tuser (s_tpg_tuser),
        .m_tdata  (m_vid_tdata), .m_tvalid (m_vid_tvalid), .m_tready (m_vid_tready),
        .m_tlast  (m_vid_tlast), .m_tuser  (m_vid_tuser)
    );

    // =========================================================================
    // 5. VDMA / TPG 設定 (MIG キャリブレーション完了後に 1 回)
    // =========================================================================
    (* ASYNC_REG = "TRUE" *) reg [1:0] calib_sync;
    always @(posedge aclk) calib_sync <= {calib_sync[0], calib_done};

    cam_ddr_cfg #(
        .VDMA_BASE (VDMA_BASE),
        .TPG_BASE  (TPG_BASE),
        .USE_TPG   (USE_TPG),
        .FB_ADDR   (FB_ADDR),
        .OUT_W     (OUT_W),
        .OUT_H     (OUT_H),
        .WAIT_CYC  (CFG_WAIT)
    ) u_cfg (
        .aclk      (aclk),
        .aresetn   (aresetn),
        .start     (calib_sync[1]),
        .awaddr    (m_axi_awaddr),
        .awvalid   (m_axi_awvalid),
        .awready   (m_axi_awready),
        .wdata     (m_axi_wdata),
        .wvalid    (m_axi_wvalid),
        .wready    (m_axi_wready),
        .bresp     (m_axi_bresp),
        .bvalid    (m_axi_bvalid),
        .bready    (m_axi_bready),
        .done      (cfg_done),
        .error     (cfg_error)
    );
    assign m_axi_wstrb   = 4'hF;
    assign m_axi_araddr  = 32'h0;     // 読み出しは使わない
    assign m_axi_arvalid = 1'b0;
    assign m_axi_rready  = 1'b1;

endmodule


// =============================================================================
// cam_ddr_scaler  -  {sof, eol, RGB565} の画素列を 2 倍拡大した AXI4-Stream Video に
// =============================================================================
//   1 回目 (phase 0): FIFO から画素を取り出し、同じ画素を 2 ビート出す。行バッファにも保存
//   2 回目 (phase 1): 行バッファから同じ行をもう一度 (各画素 2 ビート) 出す
//   tuser : sof 画素の 1 ビート目 / tlast : 各出力行 (640 ビート) の最終ビート
// =============================================================================
module cam_ddr_scaler #(
    parameter CAM_W = 320
)(
    input  wire        aclk,
    input  wire        aresetn,
    input  wire        s_valid,
    input  wire [17:0] s_data,       // {sof, eol, rgb565[15:0]}
    output wire        s_pop,
    output reg  [23:0] m_tdata,
    output reg         m_tvalid,
    input  wire        m_tready,
    output reg         m_tlast,
    output reg         m_tuser
);
    reg [15:0] lbuf [0:CAM_W-1];    // 行バッファ (分散 RAM, RGB565)
    reg [8:0] col;
    reg [8:0] line_len;             // phase 0 で受けた画素数 - 1
    reg       phase;                // 0: FIFO から / 1: 行バッファから
    reg       dup;                  // 0: 1 ビート目 / 1: 2 ビート目

    wire        s_sof = s_data[17];
    wire        s_eol = s_data[16];
    wire [15:0] s_y   = s_data[15:0];

    // RGB565 → AXI4-Stream Video 24bit ({R, B, G} の順, 各 8bit)
    //   上位ビットを下位に繰り返して 8bit に広げる (0 → 0x00, 最大 → 0xFF)
    function [23:0] rgb565_axis;
        input [15:0] c;
        rgb565_axis = {c[15:11], c[15:13],     // R
                       c[4:0],   c[4:2],       // B
                       c[10:5],  c[10:9]};     // G
    endfunction

    wire load = !m_tvalid || m_tready;               // 出力レジスタが空く
    // phase 0 の 2 ビート目で FIFO から 1 画素消費
    assign s_pop = load && !phase && s_valid && dup;

    wire [15:0] lb_y = lbuf[col];

    always @(posedge aclk) begin
        if (load && !phase && s_valid && !dup && (s_sof || col < CAM_W))
            lbuf[s_sof ? 9'd0 : col] <= s_y;
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            m_tvalid <= 1'b0;
            m_tdata  <= 24'h0;
            m_tlast  <= 1'b0;
            m_tuser  <= 1'b0;
            col      <= 9'd0;
            line_len <= CAM_W - 1;
            phase    <= 1'b0;
            dup      <= 1'b0;
        end else if (load) begin
            m_tvalid <= 1'b0;
            if (!phase) begin
                if (s_valid) begin
                    m_tvalid <= 1'b1;
                    m_tdata  <= rgb565_axis(s_y);
                    if (!dup) begin
                        // sof は行頭として扱う (途中で来たら行を打ち切って再同期)
                        m_tuser <= s_sof;
                        m_tlast <= 1'b0;
                        if (s_sof) col <= 9'd0;
                        dup <= 1'b1;
                    end else begin
                        m_tuser <= 1'b0;
                        m_tlast <= s_eol;
                        dup     <= 1'b0;
                        if (s_eol) begin
                            line_len <= (col < CAM_W) ? col : CAM_W - 1;
                            col      <= 9'd0;
                            phase    <= 1'b1;
                        end else
                            col <= col + 9'd1;
                    end
                end
            end else begin
                m_tvalid <= 1'b1;
                m_tdata  <= rgb565_axis(lb_y);
                m_tuser  <= 1'b0;
                if (!dup) begin
                    m_tlast <= 1'b0;
                    dup     <= 1'b1;
                end else begin
                    dup <= 1'b0;
                    if (col == line_len) begin
                        m_tlast <= 1'b1;
                        col     <= 9'd0;
                        phase   <= 1'b0;
                    end else begin
                        m_tlast <= 1'b0;
                        col     <= col + 9'd1;
                    end
                end
            end
        end
    end
endmodule


// =============================================================================
// cam_ddr_mux  -  2 つの AXI4-Stream Video をフレーム単位で切り替える
// =============================================================================
//   WAIT : 選択元 (sel) の tuser ビートを待つ。それ以外のビートは捨てる
//   PASS : 選択元をそのまま出力。LINES 行 (tlast の数) 出したら WAIT へ
//   非選択側は常に tready=1 (読み捨て) にして詰まらないようにする
// =============================================================================
module cam_ddr_mux #(
    parameter LINES = 480
)(
    input  wire        aclk,
    input  wire        aresetn,
    input  wire        sel,          // 0: s0 (カメラ) / 1: s1 (TPG), aclk 同期済み
    input  wire [23:0] s0_tdata,  input wire s0_tvalid, output wire s0_tready,
    input  wire        s0_tlast,  input wire s0_tuser,
    input  wire [23:0] s1_tdata,  input wire s1_tvalid, output wire s1_tready,
    input  wire        s1_tlast,  input wire s1_tuser,
    output wire [23:0] m_tdata,   output wire m_tvalid, input wire m_tready,
    output wire        m_tlast,   output wire m_tuser
);
    reg        pass;
    reg        cur;                  // PASS 中の選択元
    reg [9:0]  lines;

    wire src = pass ? cur : sel;
    wire        v  = src ? s1_tvalid : s0_tvalid;
    wire        tl = src ? s1_tlast  : s0_tlast;
    wire        tu = src ? s1_tuser  : s0_tuser;

    // WAIT 中は tuser ビートだけ残し (消費しない)、他は捨てる
    wire        sel_ready = pass ? m_tready : !(v && tu);

    assign s0_tready = (src == 1'b0) ? sel_ready : 1'b1;
    assign s1_tready = (src == 1'b1) ? sel_ready : 1'b1;

    assign m_tvalid = pass && v;
    assign m_tdata  = src ? s1_tdata : s0_tdata;
    assign m_tlast  = tl;
    assign m_tuser  = tu;

    always @(posedge aclk) begin
        if (!aresetn) begin
            pass  <= 1'b0;
            cur   <= 1'b0;
            lines <= 10'd0;
        end else if (!pass) begin
            if (v && tu) begin
                pass  <= 1'b1;
                cur   <= sel;
                lines <= 10'd0;
            end
        end else if (v && m_tready) begin
            if (tl) begin
                if (lines == LINES - 1 && !tu) begin
                    pass  <= 1'b0;
                    lines <= 10'd0;
                end else
                    lines <= tu ? 10'd1 : lines + 10'd1;
            end else if (tu)
                lines <= 10'd0;               // フレーム途中の tuser: 数え直し
        end
    end
endmodule


// =============================================================================
// cam_ddr_cfg  -  起動時に AXI4-Lite で VDMA と TPG のレジスタを書く
// =============================================================================
//   start (MIG キャリブ完了) が立ってから WAIT_CYC 待ち、表の順に書き込む。
//   VDMA は各チャネルで DMACR → 開始アドレス×3 → STRIDE → HSIZE → VSIZE の順
//   (VSIZE の書き込みで転送開始)。3 つのフレームスロットは同じアドレス (1 面) にする。
// =============================================================================
module cam_ddr_cfg #(
    parameter [31:0] VDMA_BASE = 32'h44A0_0000,
    parameter [31:0] TPG_BASE  = 32'h44A1_0000,
    parameter [31:0] FB_ADDR   = 32'h8000_0000,
    parameter        OUT_W     = 640,
    parameter        OUT_H     = 480,
    parameter        WAIT_CYC  = 1000,
    parameter        USE_TPG   = 1
)(
    input  wire        aclk,
    input  wire        aresetn,
    input  wire        start,
    output reg  [31:0] awaddr,
    output reg         awvalid,
    input  wire        awready,
    output reg  [31:0] wdata,
    output reg         wvalid,
    input  wire        wready,
    input  wire [1:0]  bresp,
    input  wire        bvalid,
    output wire        bready,
    output reg         done,
    output reg         error
);
    localparam [31:0] LINE_BYTES = OUT_W * 3;      // 24bit/画素
    localparam [31:0] DMACR_RUN  = 32'h0001_0003;  // IRQFrameCount=1, Circular, RS
    localparam        N_REG      = 20;

    function [63:0] rom;     // {addr, data}
        input [4:0] i;
        case (i)
            // ── TPG (v_tpg 8.x) ──
            5'd0 : rom = {TPG_BASE  + 32'h10, OUT_H};          // HEIGHT
            5'd1 : rom = {TPG_BASE  + 32'h18, OUT_W};          // WIDTH
            5'd2 : rom = {TPG_BASE  + 32'h20, 32'd1};          // BCKGNDID = 水平ランプ
            5'd3 : rom = {TPG_BASE  + 32'h28, 32'd0};          // OVRLAYID = なし
            5'd4 : rom = {TPG_BASE  + 32'h40, 32'd0};          // COLORFORMAT = RGB
            5'd5 : rom = {TPG_BASE  + 32'h00, 32'h81};         // AP_CTRL: auto_restart | ap_start
            // ── VDMA S2MM (書き込み) ──
            5'd6 : rom = {VDMA_BASE + 32'h30, DMACR_RUN};      // S2MM_VDMACR
            5'd7 : rom = {VDMA_BASE + 32'hAC, FB_ADDR};        // S2MM_START_ADDRESS1
            5'd8 : rom = {VDMA_BASE + 32'hB0, FB_ADDR};        // 2
            5'd9 : rom = {VDMA_BASE + 32'hB4, FB_ADDR};        // 3
            5'd10: rom = {VDMA_BASE + 32'hA8, LINE_BYTES};     // S2MM_FRMDLY_STRIDE
            5'd11: rom = {VDMA_BASE + 32'hA4, LINE_BYTES};     // S2MM_HSIZE
            5'd12: rom = {VDMA_BASE + 32'hA0, OUT_H};          // S2MM_VSIZE (開始)
            // ── VDMA MM2S (読み出し) ──
            5'd13: rom = {VDMA_BASE + 32'h00, DMACR_RUN};      // MM2S_VDMACR
            5'd14: rom = {VDMA_BASE + 32'h5C, FB_ADDR};        // MM2S_START_ADDRESS1
            5'd15: rom = {VDMA_BASE + 32'h60, FB_ADDR};        // 2
            5'd16: rom = {VDMA_BASE + 32'h64, FB_ADDR};        // 3
            5'd17: rom = {VDMA_BASE + 32'h58, LINE_BYTES};     // MM2S_FRMDLY_STRIDE
            5'd18: rom = {VDMA_BASE + 32'h54, LINE_BYTES};     // MM2S_HSIZE
            default: rom = {VDMA_BASE + 32'h50, OUT_H};        // 19: MM2S_VSIZE (開始)
        endcase
    endfunction

    localparam ST_IDLE = 2'd0, ST_WAIT = 2'd1, ST_WRITE = 2'd2, ST_RESP = 2'd3;
    reg [1:0]  st;
    reg [4:0]  idx;
    reg [15:0] wcnt;

    assign bready = (st == ST_RESP);

    always @(posedge aclk) begin
        if (!aresetn) begin
            st      <= ST_IDLE;
            idx     <= USE_TPG ? 5'd0 : 5'd6;      // 6 = 最初の VDMA レジスタ
            wcnt    <= 16'd0;
            awvalid <= 1'b0;
            wvalid  <= 1'b0;
            awaddr  <= 32'h0;
            wdata   <= 32'h0;
            done    <= 1'b0;
            error   <= 1'b0;
        end else begin
            case (st)
                ST_IDLE: if (start && !done) begin
                    wcnt <= 16'd0;
                    st   <= ST_WAIT;
                end
                ST_WAIT: begin
                    wcnt <= wcnt + 16'd1;
                    if (wcnt >= WAIT_CYC) begin
                        {awaddr, wdata} <= rom(idx);
                        awvalid <= 1'b1;
                        wvalid  <= 1'b1;
                        st      <= ST_WRITE;
                    end
                end
                ST_WRITE: begin
                    if (awvalid && awready) awvalid <= 1'b0;
                    if (wvalid  && wready)  wvalid  <= 1'b0;
                    if ((!awvalid || awready) && (!wvalid || wready))
                        st <= ST_RESP;
                end
                ST_RESP: if (bvalid) begin
                    if (bresp != 2'b00) error <= 1'b1;
                    if (idx == N_REG - 1) begin
                        done <= 1'b1;
                        st   <= ST_IDLE;
                    end else begin
                        idx  <= idx + 5'd1;
                        {awaddr, wdata} <= rom(idx + 5'd1);
                        awvalid <= 1'b1;
                        wvalid  <= 1'b1;
                        st      <= ST_WRITE;
                    end
                end
            endcase
        end
    end
endmodule
