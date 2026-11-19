`timescale 1ns / 1ps
// =============================================================================
// ov7670_if.v  -  OV7670 カメラインターフェース
// =============================================================================
// モジュール構成:
//   ov7670_if      : トップレベル (XCLK生成 / SCCB初期化 / SIOテスト / キャプチャ統合)
//   ov7670_capture : PCLK/HREF/VSYNC/D[7:0] → フレームバッファ書き込み
//                    (YUV422 から輝度 Y を取り出し 8-bit モノクロで書き込む)
//   sccb_master    : SCCB (I2C互換) マスタ (書き込み + 読み出し対応)
//
// SIO テスト:
//   SCCB 初期化完了後に OV7670 PID レジスタ (0x0A) を読み出し,
//   期待値 0x76 と比較して sio_test_pass / sio_test_fail を出力する。
// =============================================================================


// =============================================================================
// トップレベル: ov7670_if
// =============================================================================
module ov7670_if #(
    parameter SYS_CLK_HZ  = 100_000_000,
    parameter XCLK_HZ     =  25_000_000,
    parameter SCCB_CLK_HZ =     100_000
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        cam_rst_i_n,

    output wire        xclk,
    input  wire        pclk,
    input  wire        vsync,
    input  wire        href,
    input  wire [7:0]  d,
    output wire        sioc,
    inout  wire        siod,
    output wire        cam_rst_o_n,
    output wire        cam_pwdn,

    output wire        fb_wclk,
    output wire        fb_we,
    output wire [16:0] fb_waddr,
    output wire [7:0]  fb_wdata,     // 8-bit 輝度 (Y)

    output wire        init_done,
    output wire        frame_start,
    output wire        sio_test_pass,  // SIO テスト合格 (PID=0x76 確認済み)
    output wire        sio_test_fail,  // SIO テスト不合格
    output wire [1:0]  dbg_pat_cnt,    // デバッグ: テストパターンカウンタ (cam_pclk)
    output wire        dbg_byte_phase, // デバッグ: バイトフェーズ (cam_pclk)
    output wire [7:0]  dbg_pat_b1,    // デバッグ: テストパターン byte1 (cam_pclk)
    output wire [7:0]  dbg_pat_b2,    // デバッグ: テストパターン byte2 (cam_pclk)

    input  wire        raw_mode,    // 1: 2 バイト目を Y とみなす (UYVY 順のとき)
    input  wire        sw3          // 1: 書き込みデータを 0x80 固定 (デバッグ)
);

    // --- XCLK 生成 ---
    localparam XCLK_DIV = SYS_CLK_HZ / XCLK_HZ / 2;
    reg [$clog2(XCLK_DIV)-1:0] xclk_cnt;
    reg xclk_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            xclk_cnt <= 0;
            xclk_r   <= 1'b0;
        end else begin
            if (xclk_cnt == XCLK_DIV - 1) begin
                xclk_cnt <= 0;
                xclk_r   <= ~xclk_r;
            end else begin
                xclk_cnt <= xclk_cnt + 1;
            end
        end
    end
    assign xclk        = xclk_r;
    assign cam_rst_o_n = rst_n;
    assign cam_pwdn    = 1'b0;

    // --- SCCB / SIO テスト信号 ---
    wire        sccb_done;
    wire [7:0]  sccb_rd_data;

    // init シーケンサからの信号
    wire        init_sccb_start;
    wire [7:0]  init_reg_addr;
    wire [7:0]  init_reg_data;

    // テストコントローラからの信号
    reg         test_sccb_start;
    reg         sio_pass_r;
    reg         sio_fail_r;
    reg         test_triggered;
    reg         test_result_done;

    assign sio_test_pass = sio_pass_r;
    assign sio_test_fail = sio_fail_r;

    // SCCB マスタ 優先順位:
    //   Phase 1: init 中         → init シーケンサ (書き込み)
    //   Phase 2: SIO テスト中    → SIO テストコントローラ (読み出し)
    //   Phase 3: 通常動作中      → SW3 カラーバーコントローラ (書き込み)
    reg  sw3_ctrl_start;
    reg  sw3_busy;
    reg  sw3_cmd;   // start 時にラッチした SW3 値
    reg  sw3_seq;   // 0: SCALING_XSC(0x70) 書き込み中, 1: SCALING_YSC(0x71) 書き込み中

    wire sccb_start_mux = !init_done        ? init_sccb_start  :
                          !test_result_done ? test_sccb_start  :
                                             sw3_ctrl_start;

    wire [7:0] raddr_mux = !init_done        ? init_reg_addr :
                           !test_result_done ? 8'h0A         :
                           (sw3_seq          ? 8'h71 : 8'h70); // SCALING_YSC / SCALING_XSC

    wire [7:0] rdata_mux = !init_done        ? init_reg_data :
                           !test_result_done ? 8'h00         :
                           (sw3_cmd          ? 8'h80 : 8'h00); // カラーバー ON/OFF (bit7)

    wire rd_mode_mux     = (!init_done || !test_result_done) ? (init_done ? 1'b1 : 1'b0)
                                                             : 1'b0;

    // --- SIO テストコントローラ ---
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            test_sccb_start  <= 1'b0;
            sio_pass_r       <= 1'b0;
            sio_fail_r       <= 1'b0;
            test_triggered   <= 1'b0;
            test_result_done <= 1'b0;
        end else begin
            test_sccb_start <= 1'b0;

            if (init_done && !test_triggered) begin
                test_triggered  <= 1'b1;
                test_sccb_start <= 1'b1;
            end

            if (sccb_done && test_triggered && !test_result_done) begin
                test_result_done <= 1'b1;
                if (sccb_rd_data == 8'h76)
                    sio_pass_r <= 1'b1;
                else
                    sio_fail_r <= 1'b1;
            end
        end
    end

    // --- SW3 カラーバーコントローラ ---
    // test_result_done 後、SW3 変化を検出して SCALING_XSC/YSC を順に SCCB 書き込み
    //   0x70=0x00, 0x71=0x00 (通常映像)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sw3_ctrl_start <= 1'b0;
            sw3_busy       <= 1'b0;
            sw3_cmd        <= 1'b0;
            sw3_seq        <= 1'b0;
        end else begin
            sw3_ctrl_start <= 1'b0;

            if (test_result_done) begin
                if (!sw3_busy) begin
                    // 1レジスタ目 (SCALING_XSC=0x70) を送信開始
                    sw3_ctrl_start <= 1'b1;
                    sw3_busy       <= 1'b1;
                    sw3_cmd        <= 1'b0;
                    sw3_seq        <= 1'b0;
                end
                if (sw3_busy && sccb_done) begin
                    if (!sw3_seq) begin
                        // 1レジスタ目完了 → 2レジスタ目 (SCALING_YSC=0x71) を送信
                        sw3_ctrl_start <= 1'b1;
                        sw3_seq        <= 1'b1;
                    end else begin
                        // 2レジスタ目完了 → 完了
                        sw3_busy <= 1'b0;
                        sw3_seq  <= 1'b0;
                    end
                end
            end
        end
    end

    // --- SCCB マスタ ---
    sccb_master #(
        .SYS_CLK_HZ (SYS_CLK_HZ),
        .SCCB_CLK_HZ(SCCB_CLK_HZ)
    ) u_sccb (
        .clk      (clk),
        .rst_n    (rst_n),
        .start    (sccb_start_mux),
        .rd_mode  (rd_mode_mux),
        .dev_addr (8'h42),
        .reg_addr (raddr_mux),
        .reg_data (rdata_mux),
        .rd_data  (sccb_rd_data),
        .done     (sccb_done),
        .sioc     (sioc),
        .siod     (siod)
    );

    // --- 初期化シーケンサ ---
    ov7670_init #(
        .SYS_CLK_HZ(SYS_CLK_HZ)
    ) u_init (
        .clk       (clk),
        .rst_n     (rst_n),
        .sccb_done (sccb_done),
        .sccb_start(init_sccb_start),
        .reg_addr  (init_reg_addr),
        .reg_data  (init_reg_data),
        .init_done (init_done)
    );

    // --- ピクセルキャプチャ ---
    ov7670_capture u_capture (
        .pclk       (pclk),
        .rst_n      (cam_rst_i_n),
        .vsync      (vsync),
        .href       (href),
        .d          (d),
        .raw_mode   (raw_mode),
        .sw3        (sw3),
        .fb_wclk    (fb_wclk),
        .fb_we      (fb_we),
        .fb_waddr   (fb_waddr),
        .fb_wdata      (fb_wdata),
        .frame_start   (frame_start),
        .dbg_pat_cnt   (dbg_pat_cnt),
        .dbg_byte_phase(dbg_byte_phase),
        .dbg_pat_b1    (dbg_pat_b1),
        .dbg_pat_b2    (dbg_pat_b2)
    );

endmodule


// =============================================================================
// ov7670_capture (変更なし)
// =============================================================================
module ov7670_capture (
    input  wire        pclk,
    input  wire        rst_n,
    input  wire        vsync,
    input  wire        href,
    input  wire [7:0]  d,
    input  wire        raw_mode,    // 0: YUYV (1 バイト目=Y) / 1: UYVY (2 バイト目=Y)
    input  wire        sw3,         // 1: 書き込みデータを 0x80 固定 (デバッグ)

    output wire        fb_wclk,
    output reg         fb_we,
    output reg  [16:0] fb_waddr,
    output reg  [7:0]  fb_wdata,     // 8-bit 輝度 (Y)

    output reg         frame_start,
    output wire [1:0]  dbg_pat_cnt,    // デバッグ: テストパターンカウンタ
    output wire        dbg_byte_phase, // デバッグ: バイトフェーズ
    output wire [7:0]  dbg_pat_b1,    // デバッグ: テストパターン byte1
    output wire [7:0]  dbg_pat_b2     // デバッグ: テストパターン byte2
);

    reg vsync_d;
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) vsync_d <= 1'b1;
        else        vsync_d <= vsync;
    end
    wire vsync_fall = vsync_d & ~vsync;

    localparam ST_WAIT_VSYNC = 2'd0;
    localparam ST_WAIT_HREF  = 2'd1;
    localparam ST_CAPTURE    = 2'd2;

    reg [1:0] state;
    reg       byte_phase;
    reg [7:0] byte1;
    reg [9:0] px_col;
    reg [8:0] px_row;
    reg [1:0] pat_cnt;   // テストパターン循環カウンタ (0→1→2→0)

    // SW3 は OV7670 SCCB 経由でカラーバー制御するため cam_d はそのまま使用
    wire [7:0] d_eff  = d;

    // YUV422 (YUYV): 1 ピクセル = 2 バイト, Y は 1 バイト目 (raw_mode=1 なら 2 バイト目)
    wire [7:0]  y8        = sw3 ? 8'h80 : (raw_mode ? d_eff : byte1);
    wire [7:0]  wr_row    = px_row[7:0];   // QVGA: 0-239 直接マッピング
    wire [8:0]  wr_col    = px_col[8:0];   // QVGA: 0-319 直接マッピング
    wire [16:0] waddr_next = ({1'b0, wr_row, 8'b0} + {3'b0, wr_row, 6'b0})
                             + {8'b0, wr_col};

    assign fb_wclk        = pclk;
    assign dbg_pat_cnt    = pat_cnt;
    assign dbg_byte_phase = byte_phase;
    assign dbg_pat_b1     = byte1;
    assign dbg_pat_b2     = d_eff;


    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= ST_WAIT_VSYNC;
            byte_phase  <= 1'b0;
            byte1       <= 8'h00;
            px_col      <= 10'd0;
            px_row      <= 9'd0;
            fb_we       <= 1'b0;
            fb_waddr    <= 17'd0;
            fb_wdata    <= 8'h00;
            frame_start <= 1'b0;
            pat_cnt     <= 2'd0;
        end else begin
            fb_we       <= 1'b0;
            frame_start <= 1'b0;

            case (state)
                ST_WAIT_VSYNC: begin
                    if (vsync_fall) begin
                        px_row      <= 9'd0;
                        px_col      <= 10'd0;
                        frame_start <= 1'b1;
                        pat_cnt     <= 2'd0;
                        state       <= ST_WAIT_HREF;
                    end
                end
                ST_WAIT_HREF: begin
                    if (vsync)     state <= ST_WAIT_VSYNC;
                    else if (href) begin
                        byte1      <= d_eff;
                        byte_phase <= 1'b1;
                        px_col     <= 10'd0;
                        state      <= ST_CAPTURE;
                    end
                end
                ST_CAPTURE: begin
                    if (!href) begin
                        px_row  <= px_row + 1;
                        pat_cnt <= 2'd0;   // 次ライン先頭で pat_cnt=0 に揃える
                        state   <= ST_WAIT_HREF;
                    end else begin
                        if (!byte_phase) begin
                            byte1      <= d_eff;
                            byte_phase <= 1'b1;
                        end else begin
                            byte_phase <= 1'b0;
                            begin
                                fb_we    <= 1'b1;
                                fb_waddr <= waddr_next;
                                fb_wdata <= y8;
                            end
                            px_col  <= px_col + 1;
                            pat_cnt <= (pat_cnt == 2'd3) ? 2'd0 : pat_cnt + 1;
                        end
                    end
                end
            endcase
        end
    end

endmodule


// =============================================================================
// ov7670_init (変更なし)
// =============================================================================
module ov7670_init #(
    parameter SYS_CLK_HZ = 100_000_000
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sccb_done,
    output reg         sccb_start,
    output reg  [7:0]  reg_addr,
    output reg  [7:0]  reg_data,
    output reg         init_done
);

    localparam REG_NUM = 10;
    reg [15:0] init_rom [0:REG_NUM-1];

    initial begin        
        init_rom[0] = 16'h1280;
        init_rom[1] = 16'hFFF0;
        init_rom[2] = 16'h1210;  // COM7  : QVGA, YUV 出力
        init_rom[3] = 16'h8c00;  // RGB444: 無効
        init_rom[4] = 16'h40C0;  // COM15 : 出力レンジ 0x00-0xFF (RGB565 無効)
        init_rom[5] = 16'h3A04;  // TSLB  : [3]=0 → YUYV 順 (COM13[0]=0 と組み合わせ)
        init_rom[6] = 16'h3D80;  // COM13 : ガンマ有効, UV スワップなし
        init_rom[7] = 16'hB084;
        init_rom[8] = 16'h141A;  // COM9  : AGC ゲイン上限 4x ([6:4]=001), 予約ビットは初期値 0x4A のまま
        init_rom[9] = 16'hFFFF;
    end

    localparam DELAY_1MS = SYS_CLK_HZ / 1000;

    reg [5:0]  rom_idx;
    reg [26:0] delay_cnt;

    localparam S_LOAD  = 2'd0;
    localparam S_SEND  = 2'd1;
    localparam S_DELAY = 2'd2;
    reg [1:0] seq_state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rom_idx    <= 6'd0;
            sccb_start <= 1'b0;
            reg_addr   <= 8'h00;
            reg_data   <= 8'h00;
            init_done  <= 1'b0;
            delay_cnt  <= 0;
            seq_state  <= S_LOAD;
        end else begin
            sccb_start <= 1'b0;

            case (seq_state)
                S_LOAD: begin
                    if (init_done) begin
                        // 完了後は何もしない
                    end else if (init_rom[rom_idx] == 16'hFFFF) begin
                        init_done <= 1'b1;
                    end else if (init_rom[rom_idx][15:8] == 8'hFF) begin
                        delay_cnt <= DELAY_1MS * init_rom[rom_idx][7:0];
                        seq_state <= S_DELAY;
                        rom_idx   <= rom_idx + 1;
                    end else begin
                        reg_addr   <= init_rom[rom_idx][15:8];
                        reg_data   <= init_rom[rom_idx][7:0];
                        sccb_start <= 1'b1;
                        seq_state  <= S_SEND;
                    end
                end
                S_SEND: begin
                    if (sccb_done) begin
                        rom_idx   <= rom_idx + 1;
                        seq_state <= S_LOAD;
                    end
                end
                S_DELAY: begin
                    if (delay_cnt == 0) seq_state <= S_LOAD;
                    else                delay_cnt <= delay_cnt - 1;
                end
                default: seq_state <= S_LOAD;
            endcase
        end
    end

endmodule


// =============================================================================
// sccb_master : SCCB マスタ (3 相書き込み + 2 相書き込み→読み出し対応)
// =============================================================================
// rd_mode=0: 従来の 3 相書き込み (dev_addr + reg_addr + reg_data, 27 bit)
// rd_mode=1: 2 相書き込み (dev_addr + reg_addr, 18 bit) の後に
//            2 相読み出し (dev_read_addr + DC + read_data + NA, 18 bit) を実行。
//            読み出しデータは rd_data に出力される。
// =============================================================================
module sccb_master #(
    parameter SYS_CLK_HZ  = 100_000_000,
    parameter SCCB_CLK_HZ =     100_000
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,
    input  wire       rd_mode,     // 0=書き込み, 1=読み出し
    input  wire [7:0] dev_addr,    // 書き込みアドレス (例: 8'h42)
    input  wire [7:0] reg_addr,
    input  wire [7:0] reg_data,
    output wire [7:0] rd_data,     // 読み出しデータ (done && rd_mode 時に有効)
    output reg        done,
    output reg        sioc,
    inout  wire       siod
);

    localparam QPERIOD = SYS_CLK_HZ / (SCCB_CLK_HZ * 4);

    reg siod_oe;
    assign siod = siod_oe ? 1'b0 : 1'bz;

    localparam ST_IDLE    = 4'd0;
    localparam ST_START1  = 4'd1;
    localparam ST_START2  = 4'd2;
    localparam ST_BITS    = 4'd3;   // 書き込みビット列
    localparam ST_STOP1   = 4'd4;   // 最終 STOP
    localparam ST_STOP2   = 4'd5;
    localparam ST_DONE    = 4'd6;
    localparam ST_STOP_W1 = 4'd7;   // 中間 STOP (rd_mode=1 の書き込み相終了後)
    localparam ST_STOP_W2 = 4'd8;
    localparam ST_RSTART1 = 4'd9;   // 読み出し RE-START
    localparam ST_RSTART2 = 4'd10;
    localparam ST_RBITS   = 4'd11;  // 読み出しビット列

    reg [3:0]  state;
    reg [15:0] timer;
    reg [1:0]  qphase;
    reg [4:0]  bit_idx;
    reg [26:0] tx_sr;
    reg        rd_mode_r;   // start 時にラッチ
    reg [8:0]  rd_addr_sr;  // 読み出しアドレス + DC (9 bit シフトレジスタ)
    reg [7:0]  rd_shift;    // 受信データシフトレジスタ

    assign rd_data = rd_shift;

    wire [26:0] tx_data_full = {dev_addr, 1'b1, reg_addr, 1'b1, reg_data, 1'b1};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= ST_IDLE;
            sioc       <= 1'b1;
            siod_oe    <= 1'b0;
            done       <= 1'b0;
            timer      <= 0;
            qphase     <= 0;
            bit_idx    <= 0;
            tx_sr      <= 0;
            rd_mode_r  <= 0;
            rd_addr_sr <= 0;
            rd_shift   <= 0;
        end else begin
            done <= 1'b0;

            if (timer != 0) begin
                timer <= timer - 1;
            end else begin
                case (state)

                    ST_IDLE: begin
                        sioc    <= 1'b1;
                        siod_oe <= 1'b0;
                        if (start) begin
                            tx_sr     <= tx_data_full;
                            rd_mode_r <= rd_mode;
                            bit_idx   <= 5'd0;
                            timer     <= QPERIOD - 1;
                            state     <= ST_START1;
                        end
                    end

                    ST_START1: begin
                        sioc    <= 1'b1;
                        siod_oe <= 1'b0;
                        timer   <= QPERIOD - 1;
                        state   <= ST_START2;
                    end
                    ST_START2: begin
                        sioc    <= 1'b1;
                        siod_oe <= 1'b1;   // SIOD = L (START)
                        timer   <= QPERIOD - 1;
                        qphase  <= 2'd0;
                        state   <= ST_BITS;
                    end

                    // ── 書き込みビット列 ──────────────────────────────────
                    // rd_mode=0: 27 bit (bit_idx 0〜26)
                    // rd_mode=1: 18 bit (bit_idx 0〜17, dev_addr+DC+reg_addr+DC のみ)
                    ST_BITS: begin
                        case (qphase)
                            2'd0: begin
                                sioc    <= 1'b0;
                                siod_oe <= ~tx_sr[26];
                                timer   <= QPERIOD - 1;
                                qphase  <= 2'd1;
                            end
                            2'd1: begin
                                sioc   <= 1'b1;
                                timer  <= QPERIOD - 1;
                                qphase <= 2'd2;
                            end
                            2'd2: begin
                                timer  <= QPERIOD - 1;
                                qphase <= 2'd3;
                            end
                            2'd3: begin
                                sioc  <= 1'b0;
                                tx_sr <= {tx_sr[25:0], 1'b0};
                                timer <= QPERIOD - 1;
                                if ((!rd_mode_r && bit_idx == 5'd26) ||
                                    ( rd_mode_r && bit_idx == 5'd17)) begin
                                    state <= rd_mode_r ? ST_STOP_W1 : ST_STOP1;
                                end else begin
                                    bit_idx <= bit_idx + 1;
                                    qphase  <= 2'd0;
                                end
                            end
                        endcase
                    end

                    // ── 中間 STOP (rd_mode=1 書き込み相終了後) ─────────────
                    ST_STOP_W1: begin
                        sioc    <= 1'b1;
                        siod_oe <= 1'b1;   // SIOD = L
                        timer   <= QPERIOD - 1;
                        state   <= ST_STOP_W2;
                    end
                    ST_STOP_W2: begin
                        sioc    <= 1'b1;
                        siod_oe <= 1'b0;   // SIOD = H (STOP)
                        timer   <= QPERIOD - 1;
                        state   <= ST_RSTART1;
                    end

                    // ── 読み出し RE-START ─────────────────────────────────
                    ST_RSTART1: begin
                        sioc    <= 1'b1;
                        siod_oe <= 1'b0;   // SIOD = H
                        timer   <= QPERIOD - 1;
                        state   <= ST_RSTART2;
                    end
                    ST_RSTART2: begin
                        sioc       <= 1'b1;
                        siod_oe    <= 1'b1;  // SIOD = L (START)
                        // 読み出しアドレス = dev_addr[7:1] | 1'b1 (R/W=1), + DC
                        rd_addr_sr <= {dev_addr[7:1], 1'b1, 1'b1};
                        rd_shift   <= 8'h00;
                        bit_idx    <= 5'd0;
                        timer      <= QPERIOD - 1;
                        qphase     <= 2'd0;
                        state      <= ST_RBITS;
                    end

                    // ── 読み出しビット列 (18 bit) ─────────────────────────
                    // bit 0-7 : dev_read_addr を MSB first で送出 (rd_addr_sr)
                    // bit 8   : DC (Hi-Z)
                    // bit 9-16: スレーブからデータ受信 (siod をサンプル)
                    // bit 17  : NA (Hi-Z, マスタは ACK しない)
                    ST_RBITS: begin
                        case (qphase)
                            2'd0: begin
                                sioc    <= 1'b0;
                                siod_oe <= (bit_idx <= 5'd8) ? ~rd_addr_sr[8] : 1'b0;
                                timer   <= QPERIOD - 1;
                                qphase  <= 2'd1;
                            end
                            2'd1: begin
                                sioc <= 1'b1;
                                // データビット (9〜16) をサンプル
                                if (bit_idx >= 5'd9 && bit_idx <= 5'd16)
                                    rd_shift <= {rd_shift[6:0], siod};
                                timer  <= QPERIOD - 1;
                                qphase <= 2'd2;
                            end
                            2'd2: begin
                                timer  <= QPERIOD - 1;
                                qphase <= 2'd3;
                            end
                            2'd3: begin
                                sioc  <= 1'b0;
                                timer <= QPERIOD - 1;
                                if (bit_idx == 5'd17) begin
                                    state <= ST_STOP1;
                                end else begin
                                    if (bit_idx < 5'd8)
                                        rd_addr_sr <= {rd_addr_sr[7:0], 1'b0};
                                    bit_idx <= bit_idx + 1;
                                    qphase  <= 2'd0;
                                end
                            end
                        endcase
                    end

                    // ── 最終 STOP ─────────────────────────────────────────
                    ST_STOP1: begin
                        sioc    <= 1'b1;
                        siod_oe <= 1'b1;   // SIOD = L
                        timer   <= QPERIOD - 1;
                        state   <= ST_STOP2;
                    end
                    ST_STOP2: begin
                        sioc    <= 1'b1;
                        siod_oe <= 1'b0;   // SIOD = H (STOP)
                        timer   <= QPERIOD - 1;
                        state   <= ST_DONE;
                    end

                    ST_DONE: begin
                        done  <= 1'b1;
                        state <= ST_IDLE;
                    end

                    default: state <= ST_IDLE;
                endcase
            end
        end
    end

endmodule
