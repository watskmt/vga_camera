`timescale 1ns / 1ps
// =============================================================================
// vga_mono.v  -  VGA 640x480 @ 60 Hz  1-bit モノクロ出力
// =============================================================================
// タイミング (640x480 @ 60 Hz, ピクセルクロック 25 MHz):
//
//   水平 (1 line = 800 clocks):
//     Active    : 640
//     Front porch:  16
//     Sync pulse :  96  (負論理)
//     Back porch :  48
//
//   垂直 (1 frame = 525 lines):
//     Active    : 480
//     Front porch:  10
//     Sync pulse :   2  (負論理)
//     Back porch :  33
//
// 使い方:
//   - pclk に 25 MHz を入力する
//   - active が High の期間に hpos/vpos で座標を取得し pixel_in を駆動する
//   - vga_r/g/b は各 1 bit (モノクロなので同値)
// =============================================================================

module vga_mono (
    input  wire        pclk,       // 25 MHz ピクセルクロック
    input  wire        rst_n,      // 非同期リセット (負論理)
    input  wire        pixel_in,   // 1 bit ピクセルデータ (active 期間に有効)
    output wire [9:0]  hpos,       // 水平座標 0-639 (active 領域)
    output wire [9:0]  vpos,       // 垂直座標 0-479 (active 領域)
    output wire        active,     // 表示有効期間
    output reg         hsync,      // 水平同期 (負論理)
    output reg         vsync,      // 垂直同期 (負論理)
    output wire        vga_r,      // 赤 (1 bit)
    output wire        vga_g,      // 緑 (1 bit)
    output wire        vga_b       // 青 (1 bit)
);

    // -------------------------------------------------------------------------
    // タイミングパラメータ
    // -------------------------------------------------------------------------
    // 水平
    localparam H_ACTIVE = 640;
    localparam H_FP     =  16;  // front porch
    localparam H_SYNC   =  96;  // sync pulse width
    localparam H_BP     =  48;  // back porch
    localparam H_TOTAL  = H_ACTIVE + H_FP + H_SYNC + H_BP;  // 800

    // sync pulse 開始・終了カウント値
    localparam H_SYNC_START = H_ACTIVE + H_FP;           // 656
    localparam H_SYNC_END   = H_ACTIVE + H_FP + H_SYNC;  // 752

    // 垂直
    localparam V_ACTIVE = 480;
    localparam V_FP     =  10;
    localparam V_SYNC   =   2;
    localparam V_BP     =  33;
    localparam V_TOTAL  = V_ACTIVE + V_FP + V_SYNC + V_BP;  // 525

    localparam V_SYNC_START = V_ACTIVE + V_FP;           // 490
    localparam V_SYNC_END   = V_ACTIVE + V_FP + V_SYNC;  // 492

    // -------------------------------------------------------------------------
    // カウンタ
    // -------------------------------------------------------------------------
    reg [9:0] h_cnt;  // 0 .. H_TOTAL-1 (0..799)
    reg [9:0] v_cnt;  // 0 .. V_TOTAL-1 (0..524)

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            h_cnt <= 0;
            v_cnt <= 0;
        end else begin
            if (h_cnt == H_TOTAL - 1) begin
                h_cnt <= 0;
                v_cnt <= (v_cnt == V_TOTAL - 1) ? 0 : v_cnt + 1;
            end else begin
                h_cnt <= h_cnt + 1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // 同期信号 (負論理)
    // -------------------------------------------------------------------------
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            hsync <= 1'b1;
            vsync <= 1'b1;
        end else begin
            hsync <= ~(h_cnt >= H_SYNC_START && h_cnt < H_SYNC_END);
            vsync <= ~(v_cnt >= V_SYNC_START && v_cnt < V_SYNC_END);
        end
    end

    // -------------------------------------------------------------------------
    // 座標・有効フラグ出力
    // -------------------------------------------------------------------------
    assign active = (h_cnt < H_ACTIVE) && (v_cnt < V_ACTIVE);
    assign hpos   = h_cnt[9:0];
    assign vpos   = v_cnt[9:0];

    // -------------------------------------------------------------------------
    // ピクセル出力 (active 外はブランキング = 0)
    // -------------------------------------------------------------------------
    wire pixel_out = active & pixel_in;
    assign vga_r = pixel_out;
    assign vga_g = pixel_out;
    assign vga_b = pixel_out;

endmodule
