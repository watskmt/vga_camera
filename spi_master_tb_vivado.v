`timescale 1ns / 1ps
// =============================================================================
// SPI Master Testbench  (Vivado Simulator / XSim 対応)
// =============================================================================
// - `timescale 1ns/1ps
// - $display にタイムスタンプ付き
// - initial / always 分離構成 (XSim 推奨)
// - 全4 SPIモード検証
// - スレーブ・ループバックモデル内蔵
// =============================================================================

module spi_master_tb_vivado;

    // =========================================================================
    // パラメータ
    // =========================================================================
    localparam CLK_PERIOD  = 10;   // 100 MHz  (ns)
    localparam CLK_DIV     = 4;
    localparam DATA_WIDTH  = 8;

    // =========================================================================
    // DUT 接続信号
    // =========================================================================
    reg                   clk;
    reg                   rst_n;
    reg                   cpol;
    reg                   cpha;
    reg                   start;
    wire                  done;
    wire                  busy;
    reg  [DATA_WIDTH-1:0] tx_data;
    wire [DATA_WIDTH-1:0] rx_data;
    wire                  sck;
    wire                  mosi;
    reg                   miso;
    wire                  cs_n;

    // =========================================================================
    // DUT インスタンス
    // =========================================================================
    spi_master #(
        .CLK_DIV   (CLK_DIV),
        .DATA_WIDTH(DATA_WIDTH)
    ) dut (
        .clk    (clk),
        .rst_n  (rst_n),
        .cpol   (cpol),
        .cpha   (cpha),
        .start  (start),
        .done   (done),
        .busy   (busy),
        .tx_data(tx_data),
        .rx_data(rx_data),
        .sck    (sck),
        .mosi   (mosi),
        .miso   (miso),
        .cs_n   (cs_n)
    );

    // =========================================================================
    // クロック生成
    // =========================================================================
    initial clk = 1'b0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    // =========================================================================
    // スレーブモデル（ループバック）
    //   CS_N アサート時に slave_shift へ送信値をセット
    //   SCK 立ち上がりで MISO をシフト出力
    // =========================================================================
    reg [DATA_WIDTH-1:0] slave_shift;
    reg [DATA_WIDTH-1:0] slave_tx_val;  // スレーブ送信値（テストから設定）

    always @(negedge cs_n) begin
        slave_shift = slave_tx_val;
        miso        = slave_shift[DATA_WIDTH-1];
    end

    always @(posedge sck) begin
        if (!cs_n) begin
            slave_shift = {slave_shift[DATA_WIDTH-2:0], 1'b0};
            miso        = slave_shift[DATA_WIDTH-1];
        end
    end

    always @(posedge cs_n) begin
        miso = 1'b0;
    end

    // =========================================================================
    // テスト結果カウンタ
    // =========================================================================
    integer pass_cnt;
    integer fail_cnt;

    // =========================================================================
    // タスク: 1回の転送実行 + 結果チェック
    // =========================================================================
    task automatic do_transfer;
        input [DATA_WIDTH-1:0] tx_val;
        input [DATA_WIDTH-1:0] slave_val;
        input                  p_cpol;
        input                  p_cpha;
        input [127:0]          label;      // テスト名（文字列）

        reg [DATA_WIDTH-1:0] expected_rx;
        begin
            expected_rx   = slave_val;
            slave_tx_val  = slave_val;
            cpol          = p_cpol;
            cpha          = p_cpha;
            tx_data       = tx_val;

            // busy が下りているのを確認
            @(negedge clk);
            while (busy) @(negedge clk);

            // start パルス (1クロック幅)
            @(posedge clk); #1;
            start = 1'b1;
            @(posedge clk); #1;
            start = 1'b0;

            // 転送完了待ち (done パルス)
            @(posedge done);
            @(posedge clk); #1;

            // 結果表示
            if (rx_data === expected_rx) begin
                $display("[%0t ns] PASS | %0s | CPOL=%0d CPHA=%0d | TX=0x%02X  RX=0x%02X (expected 0x%02X)",
                         $time, label, p_cpol, p_cpha, tx_val, rx_data, expected_rx);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("[%0t ns] FAIL | %0s | CPOL=%0d CPHA=%0d | TX=0x%02X  RX=0x%02X (expected 0x%02X) <<<",
                         $time, label, p_cpol, p_cpha, tx_val, rx_data, expected_rx);
                fail_cnt = fail_cnt + 1;
            end

            // 転送間インターバル
            repeat (8) @(posedge clk);
        end
    endtask

    // =========================================================================
    // メインシーケンス
    // =========================================================================
    initial begin
        // --- 初期化 ---
        pass_cnt     = 0;
        fail_cnt     = 0;
        rst_n        = 1'b0;
        start        = 1'b0;
        cpol         = 1'b0;
        cpha         = 1'b0;
        tx_data      = 8'h00;
        miso         = 1'b0;
        slave_tx_val = 8'hA5;

        $display("============================================================");
        $display("  SPI Master Testbench  (Vivado / XSim)");
        $display("  CLK_DIV=%0d  DATA_WIDTH=%0d  CLK=100MHz", CLK_DIV, DATA_WIDTH);
        $display("============================================================");

        // --- リセット解除 ---
        repeat (4) @(posedge clk);
        #1 rst_n = 1'b1;
        repeat (4) @(posedge clk);

        // -----------------------------------------------------------------
        // テスト 1: 全4モード基本転送
        // -----------------------------------------------------------------
        $display("\n--- [Test 1] All SPI modes ---");
        do_transfer(8'hDE, 8'hA5, 0, 0, "Mode0");
        do_transfer(8'hAD, 8'h5A, 0, 1, "Mode1");
        do_transfer(8'hBE, 8'hC3, 1, 0, "Mode2");
        do_transfer(8'hEF, 8'h3C, 1, 1, "Mode3");

        // -----------------------------------------------------------------
        // テスト 2: 境界値 (0x00, 0xFF, 0x55, 0xAA)
        // -----------------------------------------------------------------
        $display("\n--- [Test 2] Boundary values ---");
        do_transfer(8'h00, 8'h00, 0, 0, "BND_0x00");
        do_transfer(8'hFF, 8'hFF, 0, 0, "BND_0xFF");
        do_transfer(8'h55, 8'h55, 0, 0, "BND_0x55");
        do_transfer(8'hAA, 8'hAA, 0, 0, "BND_0xAA");

        // -----------------------------------------------------------------
        // テスト 3: 連続転送（busy が下りてすぐ次を開始）
        // -----------------------------------------------------------------
        $display("\n--- [Test 3] Back-to-back transfers ---");
        do_transfer(8'h01, 8'hB1, 0, 0, "B2B_1");
        do_transfer(8'h02, 8'hB2, 0, 0, "B2B_2");
        do_transfer(8'h03, 8'hB3, 0, 0, "B2B_3");

        // -----------------------------------------------------------------
        // テスト 4: リセット後の動作確認
        // -----------------------------------------------------------------
        $display("\n--- [Test 4] Reset recovery ---");
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);
        do_transfer(8'hF0, 8'h0F, 0, 0, "PostReset");

        // -----------------------------------------------------------------
        // サマリ
        // -----------------------------------------------------------------
        $display("\n============================================================");
        $display("  Results:  PASS=%0d  FAIL=%0d  TOTAL=%0d",
                 pass_cnt, fail_cnt, pass_cnt + fail_cnt);
        if (fail_cnt == 0)
            $display("  >> All tests PASSED <<");
        else
            $display("  !! %0d test(s) FAILED !!", fail_cnt);
        $display("============================================================\n");

        $finish;
    end

    // =========================================================================
    // タイムアウトウォッチドッグ (10 us)
    // =========================================================================
    initial begin
        #100_000_000;
        $display("[ERROR] Simulation timeout!");
        $finish;
    end

endmodule
