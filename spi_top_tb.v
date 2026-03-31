`timescale 1ns / 1ps
// =============================================================================
// spi_top テストベンチ (Vivado / XSim 対応)
// =============================================================================

module spi_top_tb;

    // =========================================================================
    localparam CLK_PERIOD = 10;   // 100 MHz

    // =========================================================================
    reg        clk;
    reg        btn_rst;
    reg        btn_start;
    reg  [9:0] sw;
    wire [9:0] led;
    wire       spi_sck;
    wire       spi_mosi;
    reg        spi_miso;
    wire       spi_cs_n;

    // =========================================================================
    spi_top #(
        .SYS_CLK_HZ(100_000_000),
        .SPI_CLK_HZ(  1_000_000),
        .DATA_WIDTH (8)
    ) dut (
        .clk      (clk),
        .btn_rst  (btn_rst),
        .btn_start(btn_start),
        .sw       (sw),
        .led      (led),
        .spi_sck  (spi_sck),
        .spi_mosi (spi_mosi),
        .spi_miso (spi_miso),
        .spi_cs_n (spi_cs_n)
    );

    // =========================================================================
    initial clk = 1'b0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    // =========================================================================
    // スレーブモデル
    // =========================================================================
    reg [7:0] slave_shift;
    reg [7:0] slave_tx_val;

    always @(negedge spi_cs_n) begin
        slave_shift = slave_tx_val;
        spi_miso    = slave_shift[7];
    end
    always @(posedge spi_sck) begin
        if (!spi_cs_n) begin
            slave_shift = {slave_shift[6:0], 1'b0};
            spi_miso    = slave_shift[7];
        end
    end
    always @(posedge spi_cs_n) spi_miso = 1'b0;

    // =========================================================================
    // タスク: ボタン押下シミュレート（チャタリングなしの理想ボタン）
    //   デバウンスカウンタを待つと数百万サイクル必要なため
    //   シミュレーションでは SYS_CLK_HZ を短縮したパラメータで使用するか、
    //   直接 u_spi_master.start を force するのが現実的。
    //   ここではボタンを長押しして debounce が安定するまで待つ。
    // =========================================================================
    localparam DEBOUNCE_CLK = 100_000_000 / 1000 * 20; // 20ms @ 100MHz = 2,000,000

    task press_start;
        begin
            btn_start = 1'b1;
            repeat (DEBOUNCE_CLK + 10) @(posedge clk);
            btn_start = 1'b0;
            repeat (DEBOUNCE_CLK + 10) @(posedge clk);
        end
    endtask

    // =========================================================================
    // メインシーケンス
    // =========================================================================
    integer pass_cnt;
    integer fail_cnt;

    initial begin
        pass_cnt  = 0;
        fail_cnt  = 0;
        btn_rst   = 1'b0;
        btn_start = 1'b0;
        sw        = 10'h000;
        spi_miso  = 1'b0;
        slave_tx_val = 8'hA5;

        $display("==========================================================");
        $display("  spi_top Testbench  (Vivado/XSim)");
        $display("==========================================================");

        // --- リセット ---
        btn_rst = 1'b1;
        repeat (DEBOUNCE_CLK + 10) @(posedge clk);
        btn_rst = 1'b0;
        repeat (DEBOUNCE_CLK + 10) @(posedge clk);
        $display("[%0t ns] Reset released", $time);

        // --- Test 1: Mode0  SW=0xDE, slave=0xA5 ---
        slave_tx_val = 8'hA5;
        sw = {2'b00, 8'hDE};          // CPOL=0 CPHA=0  tx=0xDE
        press_start;
        // done が立つまで待つ
        @(posedge led[9]);
        if (led[7:0] === 8'hA5) begin
            $display("[%0t ns] PASS | Mode0 | TX=0xDE RX=0x%02X", $time, led[7:0]);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("[%0t ns] FAIL | Mode0 | TX=0xDE RX=0x%02X (exp 0xA5)", $time, led[7:0]);
            fail_cnt = fail_cnt + 1;
        end
        repeat (10) @(posedge clk);

        // --- Test 2: Mode3  SW=0xBE, slave=0x3C ---
        slave_tx_val = 8'h3C;
        sw = {2'b11, 8'hBE};          // CPOL=1 CPHA=1  tx=0xBE
        press_start;
        @(posedge led[9]);
        if (led[7:0] === 8'h3C) begin
            $display("[%0t ns] PASS | Mode3 | TX=0xBE RX=0x%02X", $time, led[7:0]);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("[%0t ns] FAIL | Mode3 | TX=0xBE RX=0x%02X (exp 0x3C)", $time, led[7:0]);
            fail_cnt = fail_cnt + 1;
        end
        repeat (10) @(posedge clk);

        // --- サマリ ---
        $display("\n==========================================================");
        $display("  Results: PASS=%0d  FAIL=%0d", pass_cnt, fail_cnt);
        $display("==========================================================\n");
        $finish;
    end

    // タイムアウト (500 ms シミュレーション時間)
    initial begin
        #500_000_000;
        $display("[ERROR] Timeout!");
        $finish;
    end

endmodule
