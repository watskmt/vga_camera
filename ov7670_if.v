`timescale 1ns / 1ps
// =============================================================================
// ov7670_if.v  -  OV7670 カメラインターフェース
// =============================================================================
// モジュール構成:
//   ov7670_if      : トップレベル (XCLK生成 / SCCB初期化 / SIOテスト / キャプチャ統合)
//   ov7670_capture : PCLK/HREF/VSYNC/D[7:0] → 画素ストリーム (VGA 640×480)
//                    (RGB565 の画素に, 行頭/行末/フレーム先頭の印を付ける)
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

    // 画素ストリーム (pix_clk = pclk ドメイン, 1 画素 = pix_we 1 パルス)
    output wire        pix_clk,
    output wire        pix_we,
    output wire        pix_sof,      // フレーム先頭画素 (0,0)
    output wire        pix_eol,      // 行末画素 (x = 639)
    output wire [15:0] pix_rgb,      // RGB565 {R[4:0], G[5:0], B[4:0]}

    output wire        init_done,
    output wire        frame_start,
    output wire        sio_test_pass,  // SIO テスト合格 (PID=0x76 確認済み)
    output wire        sio_test_fail,  // SIO テスト不合格
    output wire [1:0]  dbg_pat_cnt,    // デバッグ: テストパターンカウンタ (cam_pclk)
    output wire        dbg_byte_phase, // デバッグ: バイトフェーズ (cam_pclk)
    output wire [7:0]  dbg_pat_b1,    // デバッグ: テストパターン byte1 (cam_pclk)
    output wire [7:0]  dbg_pat_b2,    // デバッグ: テストパターン byte2 (cam_pclk)

    input  wire        sw3,         // 1: カメラ画素を試験パターン (灰色地に黒い四角) に置換 (非同期, スイッチ)
    input  wire        agc_hold     // 1: AGC/AEC を止めて今のゲイン・露光で固定 (非同期, スイッチ)
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
    //   Phase 3: 通常動作中      → 動作中コントローラ (書き込み, 必要なときだけ)
    reg        run_start;
    reg  [7:0] run_addr;
    reg  [7:0] run_data;

    wire sccb_start_mux = !init_done        ? init_sccb_start  :
                          !test_result_done ? test_sccb_start  :
                                             run_start;

    wire [7:0] raddr_mux = !init_done        ? init_reg_addr :
                           !test_result_done ? 8'h0A         :
                                               run_addr;

    wire [7:0] rdata_mux = !init_done        ? init_reg_data :
                           !test_result_done ? 8'h00         :
                                               run_data;

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

    // --- 動作中コントローラ ---
    // test_result_done 後:
    //   1. SCALING_XSC (0x70) = 0x3A, SCALING_YSC (0x71) = 0x35 を 1 回だけ書く
    //      (bit7 = 内蔵テストパターン OFF, 下位は初期値)
    //   2. 以後は agc_hold が変わったときだけ COM8 (0x13) を書く
    //        agc_hold=0: 0x8F (初期値: Fast AGC/AEC, AGC/AWB/AEC 自動)
    //        agc_hold=1: 0x8A (AGC/AEC 停止 → GAIN/AECH は止めた時点の値のまま)
    //   SCCB を常時動かすと SIOC/SIOD のトグルがセンサに乗る恐れがあるので、
    //   必要なとき以外は SCCB を止めておく。
    (* ASYNC_REG = "TRUE" *) reg [1:0] hold_sync;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) hold_sync <= 2'b00;
        else        hold_sync <= {hold_sync[0], agc_hold};

    reg [1:0] run_step;     // 0: 0x70, 1: 0x71, 2: COM8 監視
    reg       run_busy;
    reg       hold_applied; // COM8 に反映済みの agc_hold (リセット後の COM8 = 0x8F に対応して 0)
    reg       hold_pend;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            run_start    <= 1'b0;
            run_addr     <= 8'h00;
            run_data     <= 8'h00;
            run_step     <= 2'd0;
            run_busy     <= 1'b0;
            hold_applied <= 1'b0;
            hold_pend    <= 1'b0;
        end else begin
            run_start <= 1'b0;

            if (test_result_done) begin
                if (!run_busy) begin
                    if (run_step == 2'd0) begin
                        run_addr <= 8'h70; run_data <= 8'h3A;
                        run_start <= 1'b1; run_busy <= 1'b1;
                    end else if (run_step == 2'd1) begin
                        run_addr <= 8'h71; run_data <= 8'h35;
                        run_start <= 1'b1; run_busy <= 1'b1;
                    end else if (hold_sync[1] != hold_applied) begin
                        run_addr  <= 8'h13;
                        run_data  <= hold_sync[1] ? 8'h8A : 8'h8F;
                        hold_pend <= hold_sync[1];
                        run_start <= 1'b1; run_busy <= 1'b1;
                    end
                end else if (sccb_done) begin
                    run_busy <= 1'b0;
                    if (run_step != 2'd2) run_step     <= run_step + 2'd1;
                    else                  hold_applied <= hold_pend;
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
        .sw3        (sw3),
        .pix_clk    (pix_clk),
        .pix_we     (pix_we),
        .pix_sof    (pix_sof),
        .pix_eol    (pix_eol),
        .pix_rgb    (pix_rgb),
        .frame_start   (frame_start),
        .dbg_pat_cnt   (dbg_pat_cnt),
        .dbg_byte_phase(dbg_byte_phase),
        .dbg_pat_b1    (dbg_pat_b1),
        .dbg_pat_b2    (dbg_pat_b2)
    );

endmodule


// =============================================================================
// ov7670_capture  -  VGA (640×480) RGB565 の画素ストリーム
//   pix_sof : (0,0) の画素 / pix_eol : 各行の x = CAM_W-1 の画素
//   CAM_W / CAM_H を超える画素 (設定違いで行や列が長い場合) は出さない
// =============================================================================
module ov7670_capture #(
    parameter CAM_W = 640,
    parameter CAM_H = 480
)(
    input  wire        pclk,
    input  wire        rst_n,
    input  wire        vsync,
    input  wire        href,
    input  wire [7:0]  d,
    input  wire        sw3,         // 1: 試験パターン (灰色の地, 中央 240×160 が黒)

    output wire        pix_clk,
    output reg         pix_we,
    output reg         pix_sof,
    output reg         pix_eol,
    output reg  [15:0] pix_rgb,      // RGB565 {R[4:0], G[5:0], B[4:0]}

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

    wire [7:0] d_eff  = d;

    // 試験パターン (sw3=1): 灰色 (RGB565 で R=20, G=40, B=20 ≒ 0xA0) の地に, 中央 x=200〜439 / y=160〜319 の黒い四角。
    //   黒い四角を含む行と含まない行で灰色の明るさが変わるかを見て、
    //   行単位の輝度変動 (H サグ) がセンサ側か表示側 (PmodVGA / モニタ) かを切り分ける。
    //   カメラのタイミングのまま FIFO → DDR3 → VGA の全経路を通る。
    wire        pat_box   = (px_col >= 10'd200) && (px_col < 10'd440) &&
                            (px_row >=  9'd160) && (px_row <  9'd320);
    wire [15:0] pat_rgb   = pat_box ? 16'h0000 : {5'd20, 6'd40, 5'd20};

    // RGB565: 1 ピクセル = 2 バイト, 1 バイト目 = R[4:0] G[5:3], 2 バイト目 = G[2:0] B[4:0]
    wire [15:0] rgb16     = sw3 ? pat_rgb : {byte1, d_eff};
    wire        px_valid  = (px_col < CAM_W) && (px_row < CAM_H);

    assign pix_clk        = pclk;
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
            pix_we      <= 1'b0;
            pix_sof     <= 1'b0;
            pix_eol     <= 1'b0;
            pix_rgb     <= 16'h0000;
            frame_start <= 1'b0;
            pat_cnt     <= 2'd0;
        end else begin
            pix_we      <= 1'b0;
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
                        if (px_row != 9'h1FF) px_row <= px_row + 1;
                        pat_cnt <= 2'd0;   // 次ライン先頭で pat_cnt=0 に揃える
                        state   <= ST_WAIT_HREF;
                    end else begin
                        if (!byte_phase) begin
                            byte1      <= d_eff;
                            byte_phase <= 1'b1;
                        end else begin
                            byte_phase <= 1'b0;
                            pix_we  <= px_valid;
                            pix_sof <= (px_col == 10'd0) && (px_row == 9'd0);
                            pix_eol <= (px_col == CAM_W - 1);
                            pix_rgb <= rgb16;
                            if (px_col != 10'h3FF) px_col <= px_col + 1;
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

    // OmniVision / Linux ov7670 ドライバの既定値のうち, アナログ・ADC・黒レベル補正
    // (予約レジスタ) を追加している。PLL (DBLV 0x6B) と CLKRC は変えない (PCLK = XCLK のまま)。
    localparam REG_NUM = 52;
    reg [15:0] init_rom [0:REG_NUM-1];

    initial begin
        init_rom[0]  = 16'h1280;  // COM7  : ソフトリセット
        init_rom[1]  = 16'hFFF0;  //         240 ms 待ち
        init_rom[2]  = 16'h1204;  // COM7  : VGA (640×480), RGB 出力
        init_rom[3]  = 16'h8c00;  // RGB444: 無効
        init_rom[4]  = 16'h40D0;  // COM15 : RGB565, 出力レンジ 0x00-0xFF
        init_rom[5]  = 16'h3A04;  // TSLB  : 既定値 (YUV のバイト順のみに関係)
        init_rom[6]  = 16'h3DC0;  // COM13 : ガンマ有効, UV 彩度自動調整
        init_rom[7]  = 16'h141A;  // COM9  : AGC ゲイン上限 4x ([6:4]=001), 予約ビットは初期値 0x4A のまま
        init_rom[8]  = 16'h4FB3;  // MTX1  : 色変換マトリクス (RGB 出力用, Linux ov7670 ドライバの値)
        init_rom[9]  = 16'h50B3;  // MTX2
        init_rom[10] = 16'h5100;  // MTX3
        init_rom[11] = 16'h523D;  // MTX4
        init_rom[12] = 16'h53A7;  // MTX5
        init_rom[13] = 16'h54E4;  // MTX6
        init_rom[14] = 16'h589E;  // MTXS  : マトリクス符号 + 自動コントラスト中心
        // ── 出力窓 (Linux ov7670 ドライバの VGA 設定: hstart=158, hstop=14, vstart=10, vstop=490) ──
        init_rom[15] = 16'h1713;  // HSTART: 水平開始 [10:3] = 158>>3 (初期値 0x11 = 136 だと 22 画素早く始まり右寄りになる)
        init_rom[16] = 16'h1801;  // HSTOP : 水平終了 [10:3] = 14>>3 (784 で折り返し)
        init_rom[17] = 16'h32B6;  // HREF  : [7:6]=エッジオフセット 2, [5:3]=HSTOP[2:0]=6, [2:0]=HSTART[2:0]=6
        init_rom[18] = 16'h1902;  // VSTRT : 垂直開始 [9:2] = 10>>2
        init_rom[19] = 16'h1A7A;  // VSTOP : 垂直終了 [9:2] = 490>>2
        init_rom[20] = 16'h030A;  // VREF  : [3:2]=VSTOP[1:0]=2, [1:0]=VSTRT[1:0]=2
        // ── アナログ / ADC / 予約レジスタ (推奨値) ──
        init_rom[21] = 16'h0E61;  // COM5  (予約)
        init_rom[22] = 16'h0F4B;  // COM6  : 予約 + フォーマット変更時に BLC リセット
        init_rom[23] = 16'h1602;  // 予約
        init_rom[24] = 16'h1E07;  // MVFP  : ミラー/フリップなし, 下位は推奨値
        init_rom[25] = 16'h2102;  // ADCCTR1
        init_rom[26] = 16'h2291;  // ADCCTR2
        init_rom[27] = 16'h2907;  // 予約
        init_rom[28] = 16'h330B;  // CHLF  : アレイ電流制御
        init_rom[29] = 16'h350B;  // 予約
        init_rom[30] = 16'h371D;  // ADC   : ADC 制御
        init_rom[31] = 16'h3871;  // ACOM  : ADC / アナログ共通
        init_rom[32] = 16'h392A;  // OFON  : ADC オフセット
        init_rom[33] = 16'h3C78;  // COM12 : VSYNC Low 中は HREF を出さない
        init_rom[34] = 16'h4D40;  // 予約
        init_rom[35] = 16'h4E20;  // 予約
        init_rom[36] = 16'h6900;  // GFIX  : 固定ゲイン 1x
        init_rom[37] = 16'h7410;  // REG74 : デジタルゲインは VREF[7:6] で制御
        init_rom[38] = 16'h8D4F;  // 予約
        init_rom[39] = 16'h8E00;  // 予約
        init_rom[40] = 16'h8F00;  // 予約
        init_rom[41] = 16'h9000;  // 予約
        init_rom[42] = 16'h9100;  // 予約
        init_rom[43] = 16'h9600;  // 予約
        init_rom[44] = 16'h9A00;  // 予約
        init_rom[45] = 16'hB084;  // 予約
        init_rom[46] = 16'hB10C;  // ABLC1 : 自動黒レベル補正 有効
        init_rom[47] = 16'hB20E;  // 予約
        init_rom[48] = 16'hB382;  // THL_ST: ABLC 目標値
        init_rom[49] = 16'hB80A;  // 予約
        init_rom[50] = 16'hFFFF;  // 終端
        init_rom[51] = 16'hFFFF;
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
