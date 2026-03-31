`timescale 1ns / 1ps
// =============================================================================
// SPI Top Module
// =============================================================================
// ボード想定: Xilinx Artix-7 / Basys3 / Nexys A7 (100 MHz 外部クロック)
//
// 機能概要:
//   - スイッチ SW[7:0]  : 送信データ (tx_data)
//   - スイッチ SW[8]    : CPOL 設定
//   - スイッチ SW[9]    : CPHA 設定
//   - ボタン  BTN_START : 転送開始 (チャタリング除去付き)
//   - ボタン  BTN_RST   : リセット  (チャタリング除去付き)
//   - LED[7:0]          : 受信データ表示 (rx_data)
//   - LED[8]            : busy 表示
//   - LED[9]            : done ストローブ (32ms 延長表示)
//
// パラメータ:
//   SYS_CLK_HZ  : システムクロック周波数 (デフォルト 100 MHz)
//   SPI_CLK_HZ  : SCK 周波数            (デフォルト 1 MHz)
//   DATA_WIDTH  : 転送ビット幅           (デフォルト 8 bit)
// =============================================================================

module spi_top #(
    parameter SYS_CLK_HZ = 100_000_000,
    parameter SPI_CLK_HZ =   1_000_000,
    parameter DATA_WIDTH = 8
)(
    // ---------- ボードピン ----------
    input  wire        clk,          // 100 MHz 外部クロック
    input  wire        btn_rst,      // リセットボタン  (押下=High 想定)
    input  wire        btn_start,    // 転送開始ボタン  (押下=High 想定)
    input  wire [9:0]  sw,           // スライドスイッチ
    output wire [9:0]  led,          // LED

    // ---------- SPI ピン ----------
    output wire        spi_sck,      // SCK
    output wire        spi_mosi,     // MOSI
    input  wire        spi_miso,     // MISO
    output wire        spi_cs_n      // CS_N
);

    // =========================================================================
    // パラメータ計算
    // =========================================================================
    localparam CLK_DIV = SYS_CLK_HZ / (SPI_CLK_HZ * 2);

    // =========================================================================
    // 内部信号
    // =========================================================================
    wire rst_n;
    wire cpol;
    wire cpha;
    wire [DATA_WIDTH-1:0] tx_data;
    wire [DATA_WIDTH-1:0] rx_data;
    wire                  spi_done;
    wire                  spi_busy;
    wire                  start_pulse;

    // =========================================================================
    // スイッチ割り当て
    // =========================================================================
    assign tx_data = sw[DATA_WIDTH-1:0];   // SW[7:0] → 送信データ
    assign cpol    = sw[8];                // SW[8]   → CPOL
    assign cpha    = sw[9];                // SW[9]   → CPHA

    // =========================================================================
    // LED 割り当て
    // =========================================================================
    reg  done_stretch;    // done を視認できる時間だけ延長
    assign led[DATA_WIDTH-1:0] = rx_data;
    assign led[8]              = spi_busy;
    assign led[9]              = done_stretch;

    // =========================================================================
    // チャタリング除去 / ボタン同期化
    // =========================================================================
    // リセットボタン → rst_n (負論理)
    debounce u_deb_rst (
        .clk     (clk),
        .btn_in  (btn_rst),
        .btn_out (rst_raw)
    );
    assign rst_n = ~rst_raw;

    // 転送開始ボタン → 1クロック幅パルス
    debounce u_deb_start (
        .clk     (clk),
        .btn_out (start_clean),
        .btn_in  (btn_start)
    );

    rising_edge_det u_start_edge (
        .clk    (clk),
        .rst_n  (rst_n),
        .sig_in (start_clean),
        .pulse  (start_pulse)
    );

    wire rst_raw;
    wire start_clean;

    // =========================================================================
    // done ストローブ延長  (約 32 ms @ 100 MHz = 3,200,000 clk)
    // =========================================================================
    localparam DONE_HOLD_CNT = SYS_CLK_HZ / 32;  // ~31 ms

    reg [$clog2(DONE_HOLD_CNT)-1:0] done_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done_stretch <= 1'b0;
            done_cnt     <= 0;
        end else if (spi_done) begin
            done_stretch <= 1'b1;
            done_cnt     <= DONE_HOLD_CNT - 1;
        end else if (done_stretch) begin
            if (done_cnt == 0)
                done_stretch <= 1'b0;
            else
                done_cnt <= done_cnt - 1;
        end
    end

    // =========================================================================
    // SPI Master インスタンス
    // =========================================================================
    spi_master #(
        .CLK_DIV   (CLK_DIV),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_spi_master (
        .clk     (clk),
        .rst_n   (rst_n),
        .cpol    (cpol),
        .cpha    (cpha),
        .start   (start_pulse),
        .done    (spi_done),
        .busy    (spi_busy),
        .tx_data (tx_data),
        .rx_data (rx_data),
        .sck     (spi_sck),
        .mosi    (spi_mosi),
        .miso    (spi_miso),
        .cs_n    (spi_cs_n)
    );

endmodule


// =============================================================================
// サブモジュール: チャタリング除去
//   - 2段フリップフロップ同期化 + カウンタでデバウンス
//   - STABLE_CNT クロック間変化がなければ出力を更新
// =============================================================================
module debounce #(
    parameter SYS_CLK_HZ  = 100_000_000,
    parameter DEBOUNCE_MS = 20
)(
    input  wire clk,
    input  wire btn_in,
    output reg  btn_out
);
    localparam STABLE_CNT = SYS_CLK_HZ / 1000 * DEBOUNCE_MS;

    // 2段同期化
    reg sync0, sync1;
    always @(posedge clk) begin
        sync0 <= btn_in;
        sync1 <= sync0;
    end

    reg [$clog2(STABLE_CNT)-1:0] cnt;

    always @(posedge clk) begin
        if (sync1 == btn_out) begin
            cnt <= 0;
        end else begin
            cnt <= cnt + 1;
            if (cnt == STABLE_CNT - 1) begin
                btn_out <= sync1;
                cnt     <= 0;
            end
        end
    end

endmodule


// =============================================================================
// サブモジュール: 立ち上がりエッジ検出 → 1クロック幅パルス
// =============================================================================
module rising_edge_det (
    input  wire clk,
    input  wire rst_n,
    input  wire sig_in,
    output wire pulse
);
    reg sig_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) sig_d <= 1'b0;
        else        sig_d <= sig_in;
    end
    assign pulse = sig_in & ~sig_d;
endmodule
