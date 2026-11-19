`timescale 1ns / 1ps
// =============================================================================
// ov7670_model.v  -  OV7670 カメラ ビヘイビアモデル (シミュレーション専用)
// =============================================================================
// 機能:
//   - XCLK から PCLK を生成 (CLKRC レジスタに従い分周)
//   - VGA (640×480) / QVGA (320×240, COM7[4]=1) タイミングで VSYNC / HREF を生成
//   - RGB565 (COM7[2]=1) または YUV422 YUYV (COM7[2]=0) でテストパターンを出力
//     YUV 時: Byte1 = Y (BT.601 近似), Byte2 = U/V (0x80 固定 = 無彩色)
//   - SCCB スレーブ: レジスタ書き込みに対応 (ソフトリセット含む)
//
// タイミング (VGA @ 30fps, PCLK = XCLK):
//   水平: HREF High=1280 PCLK (640pix×2byte), Blank=160 PCLK, Total=1440
//   垂直: Active=480 lines, Blank=45 lines, Total=525
//
// テストパターン (H_BAR_EN=1 でカラーバー, 0 でグラデーション):
//   カラーバー: White/Yellow/Cyan/Green/Magenta/Red/Blue/Black
//   グラデーション: 列に応じて輝度変化
// =============================================================================

module ov7670_model #(
    parameter H_BAR_EN = 1   // 1=カラーバー, 0=グラデーション
)(
    input  wire        xclk,   // FPGA からの入力クロック
    output reg         pclk,   // ピクセルクロック出力
    output reg         vsync,  // 垂直同期 (High=ブランキング)
    output reg         href,   // 水平参照 (High=有効ライン)
    output reg  [7:0]  d,      // ピクセルデータ
    input  wire        sioc,   // SCCB クロック
    inout  wire        siod,   // SCCB データ (オープンドレイン)
    input  wire        rst_n,  // リセット (負論理)
    input  wire        pwdn    // パワーダウン (High=有効)
);

    // =========================================================================
    // タイミング定数
    // =========================================================================
    localparam H_BLANK  =  160;
    localparam V_BLANK  =   45;

    // VSYNC High 期間 (フレーム先頭のブランク内)
    localparam V_SYNC_LINES = 3;

    // =========================================================================
    // レジスタファイル
    // =========================================================================
    reg [7:0] regfile [0:255];

    // 主要レジスタへの名前付きアクセス
    `define REG_CLKRC  regfile[8'h11]
    `define REG_COM7   regfile[8'h12]
    `define REG_COM15  regfile[8'h40]
    `define REG_MVFP   regfile[8'h1E]

    integer ri;
    task reset_registers;
        begin
            for (ri = 0; ri < 256; ri = ri + 1)
                regfile[ri] = 8'h00;
            `REG_CLKRC = 8'h00;   // PCLK = XCLK
            `REG_COM7  = 8'h00;   // YUV, VGA
            `REG_COM15 = 8'hC0;   // 出力レンジ 0x00〜0xFF
            `REG_MVFP  = 8'h00;   // ミラー/フリップなし
        end
    endtask

    initial reset_registers;

    // =========================================================================
    // PCLK 生成 (XCLK を CLKRC[5:0]+1 で分周)
    // =========================================================================
    // CLKRC[5:0] = 0 → 分周なし (PCLK = XCLK)
    // CLKRC[5:0] = 1 → 1/2 分周
    reg [6:0]  clk_div_cnt;
    reg        pclk_div;
    wire [6:0] clk_div_val = {1'b0, `REG_CLKRC[5:0]};  // 0〜63

    always @(posedge xclk or negedge rst_n) begin
        if (!rst_n) begin
            clk_div_cnt <= 7'd0;
            pclk_div    <= 1'b0;
        end else if (pwdn) begin
            pclk_div <= 1'b0;
        end else if (clk_div_cnt >= clk_div_val) begin
            clk_div_cnt <= 7'd0;
            pclk_div    <= ~pclk_div;
        end else begin
            clk_div_cnt <= clk_div_cnt + 1;
        end
    end

    // 分周なし (CLKRC=0) は XCLK をそのまま出す
    // (以前は posedge xclk で pclk <= xclk としていたため High 固定になっていた)
    always @* begin
        if (!rst_n || pwdn)          pclk = 1'b0;
        else if (clk_div_val == 7'd0) pclk = xclk;
        else                          pclk = pclk_div;
    end

    // =========================================================================
    // フォーマット / 解像度 (COM7)
    // =========================================================================
    wire        fmt_qvga = `REG_COM7[4];
    wire        fmt_rgb  = `REG_COM7[2];
    wire [10:0] H_ACTIVE = fmt_qvga ? 11'd640 : 11'd1280;   // ピクセル数 × 2 byte
    wire [10:0] H_TOTAL  = H_ACTIVE + H_BLANK;
    wire [9:0]  V_ACTIVE = fmt_qvga ? 10'd240 : 10'd480;
    wire [9:0]  V_TOTAL  = V_ACTIVE + V_BLANK;
    wire [9:0]  N_COLS   = fmt_qvga ? 10'd320 : 10'd640;

    // =========================================================================
    // フレームタイミング生成
    // =========================================================================
    reg [10:0] h_cnt;   // 水平カウンタ  (0 〜 H_TOTAL-1)
    reg [9:0]  v_cnt;   // 垂直カウンタ  (0 〜 V_TOTAL-1)
    reg        byte_phase; // 0=Byte1, 1=Byte2
    reg [9:0]  col;        // ピクセル列 (0〜639)

    wire h_active = (h_cnt < H_ACTIVE);
    wire v_active = (v_cnt < V_ACTIVE);

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n || pwdn) begin
            h_cnt      <= 0;
            v_cnt      <= 0;
            byte_phase <= 1'b0;
            col        <= 10'd0;
            vsync      <= 1'b1;
            href       <= 1'b0;
            d          <= 8'h00;
        end else begin
            // ── 水平カウンタ ──
            if (h_cnt == H_TOTAL - 1) begin
                h_cnt      <= 0;
                byte_phase <= 1'b0;
                col        <= 10'd0;
                if (v_cnt == V_TOTAL - 1)
                    v_cnt <= 0;
                else
                    v_cnt <= v_cnt + 1;
            end else begin
                h_cnt <= h_cnt + 1;
            end

            // ── VSYNC (ブランク期間先頭で High) ──
            vsync <= (v_cnt >= V_ACTIVE) && (v_cnt < V_ACTIVE + V_SYNC_LINES);

            // ── HREF ──
            href <= h_active && v_active;

            // ── ピクセルデータ ──
            if (h_active && v_active) begin
                if (!byte_phase) begin
                    d          <= fmt_rgb ? pixel_byte1(col, v_cnt[9:0]) : pixel_y(col);
                    byte_phase <= 1'b1;
                end else begin
                    d          <= fmt_rgb ? pixel_byte2(col, v_cnt[9:0]) : 8'h80;
                    byte_phase <= 1'b0;
                    col        <= col + 1;
                end
            end else begin
                d          <= 8'h00;
                byte_phase <= 1'b0;
            end
        end
    end

    // =========================================================================
    // テストパターン生成関数 (YUV: 輝度 Y)
    //   カラーバー  : 各バーの RGB から Y = (77R + 150G + 29B) >> 8
    //   グラデーション: 列に比例 (左端 0 → 右端 255)
    // =========================================================================
    function [7:0] pixel_y;
        input [9:0] px;
        reg   [9:0] seg;
        reg  [17:0] t;
        begin
            if (H_BAR_EN) begin
                seg = px / (N_COLS / 8);
                case (seg[2:0])
                    3'd0: pixel_y = 8'd255; // White
                    3'd1: pixel_y = 8'd226; // Yellow  (R+G)
                    3'd2: pixel_y = 8'd178; // Cyan    (G+B)
                    3'd3: pixel_y = 8'd149; // Green
                    3'd4: pixel_y = 8'd105; // Magenta (R+B)
                    3'd5: pixel_y = 8'd76;  // Red
                    3'd6: pixel_y = 8'd28;  // Blue
                    3'd7: pixel_y = 8'd0;   // Black
                endcase
            end else begin
                t       = px * 18'd255;
                pixel_y = t / (N_COLS - 1);
            end
        end
    endfunction

    // =========================================================================
    // テストパターン生成関数 (RGB565)
    // Byte1: RRRRR GGG  Byte2: GGG BBBBB
    // =========================================================================
    // カラーバー 8色 (White/Yellow/Cyan/Green/Magenta/Red/Blue/Black)
    reg [15:0] bar_color;

    function [7:0] pixel_byte1;
        input [9:0] px;   // 列
        input [9:0] py;   // 行
        reg [15:0] rgb;
        reg [9:0]  seg;
        reg [9:0]  rpx;   // ミラー時の反転座標
        begin
            if (H_BAR_EN) begin
                seg = px / 80;   // 640/8 = 80 ピクセル/バー
                case (seg[2:0])
                    3'd0: rgb = 16'hFFFF; // White
                    3'd1: rgb = 16'hFFE0; // Yellow
                    3'd2: rgb = 16'h07FF; // Cyan
                    3'd3: rgb = 16'h07E0; // Green
                    3'd4: rgb = 16'hF81F; // Magenta
                    3'd5: rgb = 16'hF800; // Red
                    3'd6: rgb = 16'h001F; // Blue
                    3'd7: rgb = 16'h0000; // Black
                endcase
            end else begin
                // グラデーション: 列で輝度変化
                rgb = {px[8:4], px[9:4], px[8:4]};
            end
            // MVFP 水平ミラー (グラデーションのみ: カラーバーは座標依存なので変化なし)
            if (`REG_MVFP[5] && !H_BAR_EN) begin
                rpx = 10'd639 - px;
                rgb = {rpx[8:4], rpx[9:4], rpx[8:4]};
            end
            pixel_byte1 = rgb[15:8];
        end
    endfunction

    function [7:0] pixel_byte2;
        input [9:0] px;
        input [9:0] py;
        reg [15:0] rgb;
        reg [9:0]  seg;
        reg [9:0]  rpx;   // ミラー時の反転座標
        begin
            if (H_BAR_EN) begin
                seg = px / 80;
                case (seg[2:0])
                    3'd0: rgb = 16'hFFFF;
                    3'd1: rgb = 16'hFFE0;
                    3'd2: rgb = 16'h07FF;
                    3'd3: rgb = 16'h07E0;
                    3'd4: rgb = 16'hF81F;
                    3'd5: rgb = 16'hF800;
                    3'd6: rgb = 16'h001F;
                    3'd7: rgb = 16'h0000;
                endcase
            end else begin
                rgb = {px[8:4], px[9:4], px[8:4]};
            end
            // MVFP 水平ミラー (pixel_byte1 と対称)
            if (`REG_MVFP[5] && !H_BAR_EN) begin
                rpx = 10'd639 - px;
                rgb = {rpx[8:4], rpx[9:4], rpx[8:4]};
            end
            pixel_byte2 = rgb[7:0];
        end
    endfunction

    // =========================================================================
    // SCCB スレーブ (書き込みのみ)
    // =========================================================================
    // プロトコル: START → 8bit(devaddr) → DC → 8bit(regaddr) → DC → 8bit(data) → DC → STOP
    // SIOD はオープンドレイン; モデルは書き込みのみ受信 (SIOD 駆動なし)
    // =========================================================================

    // START/STOP 検出 (SIOC=High 中の SIOD エッジ)
    reg sioc_d, siod_d;
    always @(posedge xclk) begin
        sioc_d <= sioc;
        siod_d <= siod;
    end

    wire sccb_start = ( sioc) & (~siod) & ( siod_d);  // SIOD 立ち下がり (SIOC=H)
    wire sccb_stop  = ( sioc) & ( siod) & (~siod_d);  // SIOD 立ち上がり (SIOC=H)

    // ビット受信 (SIOC 立ち上がりでサンプル)
    wire sioc_rise  = sioc & ~sioc_d;

    localparam SCCB_IDLE   = 3'd0;
    localparam SCCB_DEVADDR= 3'd1;
    localparam SCCB_REGADDR= 3'd2;
    localparam SCCB_DATA   = 3'd3;
    localparam SCCB_DC     = 3'd4;   // don't care bit

    reg [2:0]  sccb_state;
    reg [7:0]  sccb_shift;
    reg [3:0]  sccb_bit_cnt;  // 0〜8 (8bitデータ + 1 DC)
    reg [7:0]  sccb_regaddr;
    reg [2:0]  sccb_phase;    // 0=devaddr, 1=regaddr, 2=data

    always @(posedge xclk or negedge rst_n) begin
        if (!rst_n) begin
            sccb_state   <= SCCB_IDLE;
            sccb_bit_cnt <= 4'd0;
            sccb_shift   <= 8'h00;
            sccb_regaddr <= 8'h00;
            sccb_phase   <= 3'd0;
        end else begin
            if (sccb_stop) begin
                sccb_state <= SCCB_IDLE;
            end else if (sccb_start) begin
                sccb_state   <= SCCB_DEVADDR;
                sccb_bit_cnt <= 4'd0;
                sccb_phase   <= 3'd0;
            end else if (sioc_rise) begin
                case (sccb_state)

                    SCCB_DEVADDR, SCCB_REGADDR, SCCB_DATA: begin
                        sccb_shift   <= {sccb_shift[6:0], siod};
                        sccb_bit_cnt <= sccb_bit_cnt + 1;

                        if (sccb_bit_cnt == 4'd7) begin
                            // 8 ビット受信完了 → DC ビット待ち
                            sccb_state <= SCCB_DC;
                        end
                    end

                    SCCB_DC: begin
                        // ドントケアビット受信完了 → フェーズ処理
                        sccb_bit_cnt <= 4'd0;
                        case (sccb_phase)
                            3'd0: begin
                                // デバイスアドレス確認 (0x42 = write)
                                if (sccb_shift == 8'h42) begin
                                    sccb_phase <= 3'd1;
                                    sccb_state <= SCCB_REGADDR;
                                end else begin
                                    sccb_state <= SCCB_IDLE;
                                end
                            end
                            3'd1: begin
                                // レジスタアドレス保存
                                sccb_regaddr <= sccb_shift;
                                sccb_phase   <= 3'd2;
                                sccb_state   <= SCCB_DATA;
                            end
                            3'd2: begin
                                // レジスタ書き込み
                                if (sccb_regaddr == 8'h12 && sccb_shift[7]) begin
                                    // COM7[7]: ソフトウェアリセット
                                    reset_registers;
                                    $display("[OV7670] Software Reset");
                                end else begin
                                    regfile[sccb_regaddr] <= sccb_shift;
                                    $display("[OV7670] REG[0x%02X] <= 0x%02X",
                                             sccb_regaddr, sccb_shift);
                                end
                                sccb_phase <= 3'd0;
                                sccb_state <= SCCB_IDLE;
                            end
                        endcase
                    end

                endcase
            end
        end
    end

    // =========================================================================
    // SCCB SIOD: このモデルは書き込み専用 → 駆動しない (Hi-Z)
    // =========================================================================
    assign siod = 1'bz;

    // =========================================================================
    // デバッグ: フレーム/ライン カウント表示
    // =========================================================================
    reg [31:0] frame_cnt;
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            frame_cnt <= 0;
        end else if (h_cnt == 0 && v_cnt == 0) begin
            frame_cnt <= frame_cnt + 1;
            if (frame_cnt < 5)
                $display("[OV7670] Frame %0d start", frame_cnt);
        end
    end

endmodule
