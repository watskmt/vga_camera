// =============================================================================
// SPI Master Module
// =============================================================================
// Supports all 4 SPI modes (CPOL/CPHA)
// Configurable clock divider and data width
//
// Parameters:
//   CLK_DIV   - System clock divider (SCK = sys_clk / (2 * CLK_DIV))
//   DATA_WIDTH - Transfer width in bits (default: 8)
//
// Timing:
//   CPOL=0: SCK idle low,  CPOL=1: SCK idle high
//   CPHA=0: sample on 1st edge, CPHA=1: sample on 2nd edge
// =============================================================================

module spi_master #(
    parameter CLK_DIV   = 4,   // SCK = sys_clk / (2 * CLK_DIV)
    parameter DATA_WIDTH = 8
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // Control
    input  wire                  cpol,      // Clock polarity
    input  wire                  cpha,      // Clock phase
    input  wire                  start,     // Pulse high to start transfer
    output reg                   done,      // High for 1 cycle when transfer complete
    output reg                   busy,      // High while transfer in progress

    // Data
    input  wire [DATA_WIDTH-1:0] tx_data,   // Data to transmit
    output reg  [DATA_WIDTH-1:0] rx_data,   // Received data

    // SPI pins
    output reg                   sck,       // SPI clock
    output wire                  mosi,      // Master Out Slave In
    input  wire                  miso,      // Master In Slave Out
    output reg                   cs_n       // Chip Select (active low)
);

    // ---------------------------------------------------------------------------
    // Internal signals
    // ---------------------------------------------------------------------------
    localparam IDLE     = 2'd0;
    localparam CS_SETUP = 2'd1;
    localparam TRANSFER = 2'd2;
    localparam CS_HOLD  = 2'd3;

    reg [1:0]                    state;
    reg [$clog2(CLK_DIV)-1:0]    clk_cnt;
    reg [$clog2(CLK_DIV)-1:0]    cs_cnt;
    reg [$clog2(DATA_WIDTH):0]   bit_cnt;
    reg [DATA_WIDTH-1:0]         shift_reg;
    reg                          sck_en;
    reg                          sck_edge;   // toggles each half-period

    assign mosi = shift_reg[DATA_WIDTH-1];

    // ---------------------------------------------------------------------------
    // SCK generation
    // ---------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clk_cnt  <= 0;
            sck_edge <= 1'b0;
        end else if (sck_en) begin
            if (clk_cnt == CLK_DIV - 1) begin
                clk_cnt  <= 0;
                sck_edge <= ~sck_edge;
            end else begin
                clk_cnt <= clk_cnt + 1;
            end
        end else begin
            clk_cnt  <= 0;
            sck_edge <= 1'b0;
        end
    end

    // SCK output follows polarity setting when idle
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            sck <= 1'b0;
        else if (!sck_en)
            sck <= cpol;
        else
            sck <= cpol ^ sck_edge;
    end

    // Edge detect for sck_edge toggle
    reg sck_edge_d;
    wire sck_posedge_tick = ( sck_edge & ~sck_edge_d);
    wire sck_negedge_tick = (~sck_edge &  sck_edge_d);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) sck_edge_d <= 1'b0;
        else        sck_edge_d <= sck_edge;
    end

    // Determine sample/shift edges based on CPHA
    // CPHA=0: shift on leading, sample on trailing (for SCK polarity aware)
    // CPHA=1: sample on leading, shift on trailing
    wire sample_tick = (cpha == 1'b0) ? sck_negedge_tick : sck_posedge_tick;
    wire shift_tick  = (cpha == 1'b0) ? sck_posedge_tick : sck_negedge_tick;

    // ---------------------------------------------------------------------------
    // State machine
    // ---------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= IDLE;
            cs_n      <= 1'b1;
            busy      <= 1'b0;
            done      <= 1'b0;
            sck_en    <= 1'b0;
            shift_reg <= 0;
            rx_data   <= 0;
            bit_cnt   <= 0;
            cs_cnt    <= 0;
        end else begin
            done <= 1'b0; // default

            case (state)
                // -------------------------------------------------------
                IDLE: begin
                    cs_n   <= 1'b1;
                    busy   <= 1'b0;
                    sck_en <= 1'b0;
                    if (start) begin
                        shift_reg <= tx_data;
                        bit_cnt   <= 0;
                        cs_cnt    <= 0;
                        cs_n      <= 1'b0;
                        busy      <= 1'b1;
                        state     <= CS_SETUP;
                    end
                end

                // -------------------------------------------------------
                // One SCK half-period CS setup time before clock starts
                CS_SETUP: begin
                    if (cs_cnt == CLK_DIV - 1) begin
                        sck_en <= 1'b1;
                        state  <= TRANSFER;
                    end else begin
                        cs_cnt <= cs_cnt + 1;
                    end
                end

                // -------------------------------------------------------
                TRANSFER: begin
                    // Shift out on shift edge
                    if (shift_tick && bit_cnt < DATA_WIDTH) begin
                        shift_reg <= {shift_reg[DATA_WIDTH-2:0], 1'b0};
                    end

                    // Sample MISO on sample edge
                    if (sample_tick) begin
                        rx_data <= {rx_data[DATA_WIDTH-2:0], miso};
                        bit_cnt <= bit_cnt + 1;
                    end

                    if (bit_cnt == DATA_WIDTH) begin
                        sck_en <= 1'b0;
                        cs_cnt <= 0;
                        state  <= CS_HOLD;
                    end
                end

                // -------------------------------------------------------
                // One SCK half-period CS hold time after last clock edge
                CS_HOLD: begin
                    if (cs_cnt == CLK_DIV - 1) begin
                        cs_n  <= 1'b1;
                        done  <= 1'b1;
                        busy  <= 1'b0;
                        state <= IDLE;
                    end else begin
                        cs_cnt <= cs_cnt + 1;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
