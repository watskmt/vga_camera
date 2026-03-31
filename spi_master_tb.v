// =============================================================================
// SPI Master Testbench
// =============================================================================
`timescale 1ns/1ps

module spi_master_tb;

    // -------------------------------------------------------------------------
    parameter CLK_PERIOD = 10; // 100 MHz
    parameter CLK_DIV    = 4;
    parameter DATA_WIDTH = 8;

    // -------------------------------------------------------------------------
    reg                   clk;
    reg                   rst_n;
    reg                   cpol, cpha;
    reg                   start;
    wire                  done;
    wire                  busy;
    reg  [DATA_WIDTH-1:0] tx_data;
    wire [DATA_WIDTH-1:0] rx_data;
    wire                  sck;
    wire                  mosi;
    reg                   miso;
    wire                  cs_n;

    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // Clock
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // -------------------------------------------------------------------------
    // Loopback: slave echoes MOSI back on MISO (shift register model)
    reg [DATA_WIDTH-1:0] slave_rx;
    integer i;

    always @(negedge cs_n) begin
        slave_rx = 8'hA5; // slave sends this value
    end

    // Simple loopback — MISO driven from slave_rx MSB, shifted on SCK
    reg [DATA_WIDTH-1:0] slave_shift;
    always @(negedge cs_n) slave_shift = 8'hA5;

    always @(posedge sck) begin
        if (!cs_n) begin
            miso       <= slave_shift[DATA_WIDTH-1];
            slave_shift = {slave_shift[DATA_WIDTH-2:0], 1'b0};
        end
    end

    // -------------------------------------------------------------------------
    task do_transfer;
        input [DATA_WIDTH-1:0] data;
        input                  p_cpol;
        input                  p_cpha;
        begin
            cpol    = p_cpol;
            cpha    = p_cpha;
            tx_data = data;
            miso    = 0;

            @(posedge clk);
            start = 1;
            @(posedge clk);
            start = 0;

            @(posedge done);
            @(posedge clk);
            $display("Mode CPOL=%0d CPHA=%0d | TX=0x%02X RX=0x%02X %s",
                p_cpol, p_cpha, data, rx_data,
                (rx_data === 8'hA5) ? "PASS" : "FAIL");
        end
    endtask

    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("spi_master_tb.vcd");
        $dumpvars(0, spi_master_tb);

        rst_n   = 0;
        start   = 0;
        miso    = 0;
        cpol    = 0;
        cpha    = 0;
        tx_data = 0;

        repeat(4) @(posedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);

        // Test all 4 SPI modes
        do_transfer(8'hDE, 0, 0); // Mode 0
        repeat(4) @(posedge clk);
        do_transfer(8'hAD, 0, 1); // Mode 1
        repeat(4) @(posedge clk);
        do_transfer(8'hBE, 1, 0); // Mode 2
        repeat(4) @(posedge clk);
        do_transfer(8'hEF, 1, 1); // Mode 3
        repeat(4) @(posedge clk);

        $display("Simulation complete.");
        $finish;
    end

endmodule
