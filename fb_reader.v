`timescale 1ns / 1ps
// =============================================================================
// fb_reader.v  -  フレームバッファ読み出しモジュール (8-bit モノクロ)
// =============================================================================
// 概要:
//   320×240 @ 8-bit 輝度の BRAM フレームバッファを読み出し、
//   640×480 VGA 画面の左上に等倍で出力する。
//
// メモリレイアウト:
//   格納解像度 : 320 × 240 = 76,800 ピクセル × 8 bit
//   アドレス幅 : 17 bit
//   アドレス計算: raddr = vpos × 320 + hpos
//
// パイプライン (計 2 サイクル遅延):
//   Cycle 0: hpos/vpos/active 入力
//   Cycle 1: rdata = framebuf[raddr]  (BRAM 読み出し登録), active_d 登録
//   Cycle 2: pixel_out = active_d ? rdata : 8'h00 (登録出力)
//
// 表示領域:
//   hpos 0〜319, vpos 0〜239 → カメラ映像 (等倍)
//   それ以外                 → 黒
//
//   vga_top 側で hsync/vsync を +1 サイクル遅延させて
//   pixel_out の 2 サイクル遅延と位相を合わせること。
//
// 書き込みポート:
//   wclk  : 書き込みクロック (cam_pclk)
//   we    : 書き込みイネーブル
//   waddr : ピクセルアドレス [16:0]  (0 .. 76799)
//   wdata : 8-bit 輝度値 [7:0]
// =============================================================================

module fb_reader #(
    parameter H_ACTIVE = 640,   // VGA 水平有効画素数 (表示解像度)
    parameter V_ACTIVE = 480    // VGA 垂直有効ライン数 (表示解像度)
)(
    // --- 読み出しポート (VGA ピクセルクロック) ---
    input  wire        pclk,
    input  wire        rst_n,
    input  wire [9:0]  hpos,        // vga_mono からの水平座標 (0〜639)
    input  wire [9:0]  vpos,        // vga_mono からの垂直座標 (0〜479)
    input  wire        active,      // vga_mono からの表示有効フラグ
    output reg  [7:0]  pixel_out,   // 8-bit 輝度 (2 サイクル遅延)

    // --- 書き込みポート (cam_pclk ドメイン) ---
    input  wire        wclk,
    input  wire        we,
    input  wire [16:0] waddr,       // ピクセルアドレス (0〜76799)
    input  wire [7:0]  wdata        // 8-bit 輝度
);

    // -------------------------------------------------------------------------
    // フレームバッファ BRAM (320×240×8 bit, 17-bit アドレス)
    // -------------------------------------------------------------------------
    localparam FB_COLS  = H_ACTIVE / 2;            // 320
    localparam FB_ROWS  = V_ACTIVE / 2;            // 240
    localparam FB_DEPTH = FB_COLS * FB_ROWS;       // 76,800
    localparam ADDR_W   = 17;                      // ceil(log2(76800)) = 17

    (* ram_style = "block" *)
    reg [7:0] framebuf [0:FB_DEPTH-1];

    // 書き込みポート
    always @(posedge wclk) begin
        if (we)
            framebuf[waddr[ADDR_W-1:0]] <= wdata;
    end

    // -------------------------------------------------------------------------
    // 読み出しアドレス生成 (等倍: 左上 320×240 のみ表示)
    //   raddr = vpos × 320 + hpos
    //         = vpos × 256 + vpos × 64 + hpos
    // -------------------------------------------------------------------------
    wire in_region = (hpos < 10'd320) && (vpos < 10'd240);

    wire [7:0]  row = vpos[7:0];   // 0〜239
    wire [8:0]  col = hpos[8:0];   // 0〜319

    wire [ADDR_W-1:0] raddr =
        ({1'b0, row, 8'b0} + {3'b0, row, 6'b0}) + {8'b0, col};

    // BRAM 読み出し (1 サイクルレイテンシ)
    reg [7:0] rdata;
    always @(posedge pclk)
        rdata <= framebuf[raddr];

    // active & in_region を 1 サイクル遅延 (BRAM レイテンシに合わせる)
    // 領域外は黒出力
    reg active_d;
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n)
            active_d <= 1'b0;
        else
            active_d <= active && in_region;
    end

    // ピクセル出力 (合計 2 サイクル遅延)
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n)
            pixel_out <= 8'h00;
        else
            pixel_out <= active_d ? rdata : 8'h00;
    end

endmodule
