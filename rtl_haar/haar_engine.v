`timescale 1ns / 1ps
// =============================================================================
// haar_engine.v  -  Viola-Jones window classifier (first HAAR_NSTAGE stages in HW)
// =============================================================================
// Hardware part of the face detector (hw-face branch). Same integer arithmetic as
// sw/src/face.c (bit exact):
//
//   1. the CPU writes one pyramid level image (lw x lh <= 160 x 120, 8-bit gray,
//      row stride 160 bytes) into the image RAM and starts the engine
//   2. for each window row wy (step 1 or 2): build the band integral image of image
//      rows wy .. wy+19 (21 x 161, values < 2^20) and the prefix sums over x of the
//      column sums of v^2 over the inner rows wy+1 .. wy+18
//   3. for each window x: nf = sqrt(324 * sqsum - sum^2) of the inner 18x18 rect
//      (32-bit integer sqrt like face.c: sqrt(v/4)*2 when v >= 2^32), then the
//      weak classifiers of the first HAAR_NSTAGE stages:
//        f = -S0 + w1*S1 (+ w2*S2),  f <= mulh(thr, 2*nf) ? left : right
//        stage sum < stage threshold -> window rejected
//   4. windows that pass every HW stage go into a FIFO as {y, x}; the CPU runs the
//      remaining stages in software
//
// AXI4-Lite slave (32-bit, 64 KB window):
//   0x00 CTRL    W  bit0 start (level), bit1 clear (abort, empty FIFO)
//   0x04 STATUS  R  bit0 busy, [24:16] FIFO entries
//   0x08 LEVEL   RW [7:0] lw, [15:8] lh, [16] step 2 (else 1)
//   0x0C FIFO    R  pop: bit31 valid, [15:8] y, [7:0] x
//   0x10 WINDOWS R  windows evaluated since start
//   0x14 WEAKS   R  weak classifiers evaluated since start
//   0x18 INFO    R  [7:0] HW stages, [23:8] HW weak classifiers
//   0x1C MAGIC   R  0x48414152 ("HAAR")
//   0x8000-0xCAFF W image RAM (byte address = y * 160 + x, 32-bit words, wstrb)
//
// ROM files (sw/tools/gen_cascade.py): haar_weak.mem, haar_stage.mem, haar_params.vh
// =============================================================================
`include "haar_params.vh"

module haar_engine (
    input  wire        aclk,
    input  wire        aresetn,
    // AXI4-Lite slave
    input  wire [15:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output reg         s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output reg         s_axi_wready,
    output wire [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [15:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output reg         s_axi_arready,
    output reg  [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready
);
    localparam IMG_W   = 160;
    localparam II_STR  = 192;            // band integral image row stride (words)
    localparam NST     = `HAAR_NSTAGE;
    localparam NWK     = `HAAR_NWEAK;
    localparam MAGIC   = 32'h48414152;
    localparam [15:0] NWK16 = NWK;
    localparam [7:0]  NST8  = NST;

    assign s_axi_bresp = 2'b00;
    assign s_axi_rresp = 2'b00;

    // =========================================================================
    // Memories
    // =========================================================================
    // image RAM: 4800 x 32 (byte address y*160+x)
    reg  [31:0] img [0:4799];
    reg  [12:0] img_waddr;
    reg  [31:0] img_wdata;
    reg  [3:0]  img_we;
    reg  [14:0] img_raddr;               // byte address
    reg  [31:0] img_q;
    reg  [1:0]  img_bsel;
    always @(posedge aclk) begin
        if (img_we[0]) img[img_waddr][7:0]   <= img_wdata[7:0];
        if (img_we[1]) img[img_waddr][15:8]  <= img_wdata[15:8];
        if (img_we[2]) img[img_waddr][23:16] <= img_wdata[23:16];
        if (img_we[3]) img[img_waddr][31:24] <= img_wdata[31:24];
    end
    always @(posedge aclk) begin
        img_q    <= img[img_raddr[14:2]];
        img_bsel <= img_raddr[1:0];
    end
    wire [7:0] img_byte = img_bsel == 2'd0 ? img_q[7:0]   :
                          img_bsel == 2'd1 ? img_q[15:8]  :
                          img_bsel == 2'd2 ? img_q[23:16] : img_q[31:24];

    // band integral image: 21 rows x 192, 20 bit, true dual port (A read, B read/write)
    reg  [19:0] ii [0:4095];
    reg  [11:0] iia_addr, iib_addr;
    reg         iib_we;
    reg  [19:0] iib_wdata;
    reg  [19:0] iia_q, iib_q;
    always @(posedge aclk) iia_q <= ii[iia_addr];
    always @(posedge aclk) begin
        if (iib_we) ii[iib_addr] <= iib_wdata;
        iib_q <= ii[iib_addr];
    end

    // column sums of v^2 (inner rows) and their prefix sums (LUT RAM, async read)
    reg  [20:0] colsq [0:159];
    reg  [27:0] psq   [0:160];
    reg         psq_we;                  // single write port so that psq stays LUT RAM
    reg  [7:0]  psq_wa;
    reg  [27:0] psq_wd;
    always @(posedge aclk)
        if (psq_we) psq[psq_wa] <= psq_wd;

    // weak classifier ROM (sync read) and stage ROM
    reg  [127:0] wrom [0:511];
    reg  [47:0]  srom [0:15];
    initial begin
        $readmemh("haar_weak.mem", wrom);
        $readmemh("haar_stage.mem", srom);
    end
    reg  [8:0]   wrom_addr;
    reg  [127:0] wq;
    always @(posedge aclk) wq <= wrom[wrom_addr];

    // result FIFO: 256 x 16 (LUT RAM)
    reg  [15:0] fifo [0:255];
    reg  [7:0]  f_wp, f_rp;
    reg  [8:0]  f_cnt;
    wire        f_full  = (f_cnt == 9'd256);
    wire        f_empty = (f_cnt == 9'd0);
    reg         f_push, f_pop;
    reg  [15:0] f_din;

    // =========================================================================
    // Registers / AXI4-Lite
    // =========================================================================
    reg  [7:0]  lw, lh;
    reg         step2;
    reg  [31:0] cnt_win, cnt_weak;
    reg         busy;
    reg         start_p, clear_p;

    // write channel: accept address and data, then respond
    reg  [15:0] aw_addr;
    reg         aw_ok, w_ok;
    reg  [31:0] w_data;
    reg  [3:0]  w_strb;

    always @(posedge aclk) begin
        if (!aresetn) begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bvalid  <= 1'b0;
            aw_ok <= 1'b0;
            w_ok  <= 1'b0;
            img_we <= 4'b0;
            start_p <= 1'b0;
            clear_p <= 1'b0;
            lw <= 8'd160;
            lh <= 8'd120;
            step2 <= 1'b1;
        end else begin
            img_we  <= 4'b0;
            start_p <= 1'b0;
            clear_p <= 1'b0;
            s_axi_awready <= !aw_ok && !s_axi_awready && s_axi_awvalid && !s_axi_bvalid;
            s_axi_wready  <= !w_ok  && !s_axi_wready  && s_axi_wvalid  && !s_axi_bvalid;
            if (s_axi_awready && s_axi_awvalid) begin
                aw_addr <= s_axi_awaddr;
                aw_ok   <= 1'b1;
            end
            if (s_axi_wready && s_axi_wvalid) begin
                w_data <= s_axi_wdata;
                w_strb <= s_axi_wstrb;
                w_ok   <= 1'b1;
            end
            if (aw_ok && w_ok && !s_axi_bvalid) begin
                aw_ok <= 1'b0;
                w_ok  <= 1'b0;
                s_axi_bvalid <= 1'b1;
                if (aw_addr[15]) begin
                    img_waddr <= aw_addr[14:2];
                    img_wdata <= w_data;
                    img_we    <= w_strb;
                end else begin
                    case (aw_addr[4:2])
                        3'd0: begin
                            start_p <= w_data[0];
                            clear_p <= w_data[1];
                        end
                        3'd2: begin
                            lw    <= w_data[7:0];
                            lh    <= w_data[15:8];
                            step2 <= w_data[16];
                        end
                        default: ;
                    endcase
                end
            end
            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;
        end
    end

    // read channel (FIFO pop on reading 0x0C)
    always @(posedge aclk) begin
        f_pop <= 1'b0;
        if (!aresetn) begin
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rdata   <= 32'h0;
        end else begin
            s_axi_arready <= !s_axi_arready && s_axi_arvalid && !s_axi_rvalid;
            if (s_axi_arready && s_axi_arvalid) begin
                s_axi_rvalid <= 1'b1;
                case (s_axi_araddr[4:2])
                    3'd1: s_axi_rdata <= {7'd0, f_cnt, 15'd0, busy};
                    3'd2: s_axi_rdata <= {15'd0, step2, lh, lw};
                    3'd3: begin
                        s_axi_rdata <= {!f_empty, 15'd0, fifo[f_rp]};
                        f_pop <= !f_empty;
                    end
                    3'd4: s_axi_rdata <= cnt_win;
                    3'd5: s_axi_rdata <= cnt_weak;
                    3'd6: s_axi_rdata <= {8'd0, NWK16, NST8};
                    3'd7: s_axi_rdata <= MAGIC;
                    default: s_axi_rdata <= 32'h0;
                endcase
            end
            if (s_axi_rvalid && s_axi_rready)
                s_axi_rvalid <= 1'b0;
        end
    end

    // FIFO pointers
    always @(posedge aclk) begin
        if (!aresetn || clear_p) begin
            f_wp  <= 8'd0;
            f_rp  <= 8'd0;
            f_cnt <= 9'd0;
        end else begin
            if (f_push) begin
                fifo[f_wp] <= f_din;
                f_wp <= f_wp + 8'd1;
            end
            if (f_pop)
                f_rp <= f_rp + 8'd1;
            f_cnt <= f_cnt + {8'd0, f_push} - {8'd0, f_pop};
        end
    end

    // =========================================================================
    // Engine
    // =========================================================================
    localparam E_IDLE  = 5'd0,  E_ZERO  = 5'd1,  E_ROW   = 5'd2,  E_PIX   = 5'd3,
               E_PSQ   = 5'd4,  E_WIN   = 5'd5,  E_N1    = 5'd6,  E_N2    = 5'd7,
               E_N3    = 5'd8,  E_N4    = 5'd9,  E_N5    = 5'd10, E_SQRT  = 5'd11,
               E_NF    = 5'd12, E_STG   = 5'd13, E_FETCH = 5'd14, E_DEC   = 5'd15,
               E_RECT  = 5'd16, E_CMP   = 5'd17, E_SEND  = 5'd18, E_NEXT  = 5'd19;

    reg  [4:0]  es;
    reg  [7:0]  wy, wx;                  // window position
    reg  [4:0]  br;                      // band row being built (1..20)
    reg  [8:0]  bc;                      // column counter (issue side)
    // band build pipeline: 1 address -> 2 RAM read -> 3 data registered -> 4 square
    reg  [7:0]  p1c, p2c, p3c, p4c;
    reg         p1v, p2v, p3v, p4v;
    reg  [7:0]  v3;                      // image byte (registered)
    reg  [19:0] a3;                      // band row above (registered)
    reg  [15:0] sq4;                     // v^2
    reg  [19:0] rs;                      // running row sum
    reg  [27:0] pacc;
    reg  [20:0] cq;                      // colsq read (registered)
    reg         cqv;
    reg  [8:0]  pc;                      // psq index being written

    reg  [16:0] s1;                      // window inner rect sum (<= 324 * 255)
    reg  [24:0] s2;                      // inner rect squared sum (<= 324 * 65025)
    reg  [19:0] q_a, q_b;
    reg  [34:0] t324, s1sq;
    reg  signed [36:0] nf2;
    reg         big;
    reg  [31:0] sq_n, sq_r, sq_bit;
    reg  [4:0]  sq_i;
    reg  [18:0] nf2x;

    reg  [3:0]  stg;                     // stage
    reg  [15:0] scnt;                    // weak classifiers left in the stage
    reg  signed [31:0] sthr;
    reg  [8:0]  wk;                      // weak classifier index
    reg  [31:0] acc;

    // decoded weak classifier
    reg  [4:0]  rx [0:2], ry [0:2], rw [0:2], rh [0:2];
    reg         w3 [1:2];
    reg         has2;
    reg  signed [31:0] thr;
    reg  [15:0] lval, rval;
    reg  [2:0]  j;                       // corner pair being issued (0..5)
    reg  [2:0]  jd1, jd2, jd3;           // pair in read stage 1 / RAM data 2 / registered 3
    reg         jv1, jv2, jv3;
    reg  [19:0] qa3, qb3;                // corner values (registered)
    reg  signed [21:0] tmp, f;
    reg  signed [63:0] prod;
    reg  signed [31:0] tval;

    wire [7:0]  ry_j = ry[j[2:1]] + (j[0] ? rh[j[2:1]] : 5'd0);
    wire [8:0]  cx_j = wx + rx[j[2:1]];
    wire [11:0] row_off_j = ry_j * II_STR;

    // rect sum of the C/D pair arriving now: (A - B) - C + D
    wire signed [21:0] rsum_d_now = tmp - $signed({2'b0, qa3}) + $signed({2'b0, qb3});
    wire signed [21:0] rsum2_now  = rsum_d_now <<< 1;
    wire signed [21:0] rsum3_now  = (rsum_d_now <<< 1) + rsum_d_now;
    wire [2:0]  jmax = has2 ? 3'd6 : 3'd4;

    wire [8:0]  last_x = {1'b0, lw} - 9'd20;      // windows: x <= lw - 20
    wire [7:0]  stp    = step2 ? 8'd2 : 8'd1;

    always @(posedge aclk) begin
        iib_we <= 1'b0;
        f_push <= 1'b0;
        psq_we <= 1'b0;
        if (!aresetn || clear_p) begin
            es   <= E_IDLE;
            busy <= 1'b0;
        end else begin
            case (es)
            E_IDLE: if (start_p) begin
                busy     <= 1'b1;
                cnt_win  <= 32'd0;
                cnt_weak <= 32'd0;
                wy       <= 8'd0;
                bc       <= 9'd0;
                es       <= E_ZERO;
            end

            // band row 0 = zeros (once per level)
            E_ZERO: begin
                iib_addr  <= bc[7:0];
                iib_wdata <= 20'd0;
                iib_we    <= 1'b1;
                bc        <= bc + 9'd1;
                if (bc == {1'b0, lw}) begin
                    br <= 5'd1;
                    es <= E_ROW;
                end
            end

            // start of band row br: column 0 = 0
            E_ROW: begin
                iib_addr  <= br * II_STR;
                iib_wdata <= 20'd0;
                iib_we    <= 1'b1;
                rs        <= 20'd0;
                bc        <= 9'd0;
                p1v       <= 1'b0;
                p2v       <= 1'b0;
                p3v       <= 1'b0;
                p4v       <= 1'b0;
                es        <= E_PIX;
            end

            // pixels: issue (image byte, band row above) for column bc; the data of the
            // column issued 2 cycles ago (p2c) is processed: ii[br][c+1] = ii[br-1][c+1] + rowsum
            E_PIX: begin
                if (bc < {1'b0, lw}) begin
                    img_raddr <= (wy + br - 8'd1) * IMG_W + bc;
                    iia_addr  <= (br - 5'd1) * II_STR + bc + 9'd1;
                    p1c       <= bc[7:0];
                    p1v       <= 1'b1;
                    bc        <= bc + 9'd1;
                end else begin
                    p1v <= 1'b0;
                end
                p2c <= p1c;
                p2v <= p1v;
                p3c <= p2c;
                p3v <= p2v;
                v3  <= img_byte;
                a3  <= iia_q;
                p4c <= p3c;
                p4v <= p3v;
                sq4 <= v3 * v3;
                if (p3v) begin
                    rs        <= rs + v3;
                    iib_addr  <= br * II_STR + p3c + 9'd1;
                    iib_wdata <= a3 + rs + v3;
                    iib_we    <= 1'b1;
                end
                if (p4v && br >= 5'd2 && br <= 5'd19)
                    colsq[p4c] <= (br == 5'd2 ? 21'd0 : colsq[p4c]) + sq4;
                if (!p1v && !p2v && !p3v && !p4v && bc >= {1'b0, lw}) begin
                    if (br == 5'd20) begin
                        bc   <= 9'd0;
                        pacc <= 28'd0;
                        pc   <= 9'd0;
                        cqv  <= 1'b0;
                        psq_wa <= 8'd0;
                        psq_wd <= 28'd0;
                        psq_we <= 1'b1;
                        es   <= E_PSQ;
                    end else begin
                        br <= br + 5'd1;
                        es <= E_ROW;
                    end
                end
            end

            // prefix sums of the column squared sums: psq[c+1] = psq[c] + colsq[c]
            // (colsq read registered first)
            E_PSQ: begin
                if (bc < {1'b0, lw}) begin
                    cq  <= colsq[bc[7:0]];
                    cqv <= 1'b1;
                    bc  <= bc + 9'd1;
                end else begin
                    cqv <= 1'b0;
                end
                if (cqv) begin
                    psq_wa <= pc[7:0] + 8'd1;
                    psq_wd <= pacc + cq;
                    psq_we <= 1'b1;
                    pacc <= pacc + cq;
                    pc   <= pc + 9'd1;
                end
                if (!cqv && bc >= {1'b0, lw}) begin
                    wx <= 8'd0;
                    es <= E_WIN;
                end
            end

            // ── window at (wx, wy) ──
            E_WIN: begin
                if ({1'b0, wx} > last_x) begin           // next window row
                    if ({1'b0, wy} + {1'b0, stp} + 9'd20 > {1'b0, lh}) begin
                        busy <= 1'b0;
                        es   <= E_IDLE;
                    end else begin
                        wy <= wy + stp;
                        br <= 5'd1;
                        es <= E_ROW;
                    end
                end else begin
                    cnt_win  <= cnt_win + 32'd1;
                    iia_addr <= 1 * II_STR + wx + 9'd1;
                    iib_addr <= 1 * II_STR + wx + 9'd19;
                    es       <= E_N1;
                end
            end
            E_N1: begin
                iia_addr <= 19 * II_STR + wx + 9'd1;
                iib_addr <= 19 * II_STR + wx + 9'd19;
                es       <= E_N2;
            end
            E_N2: begin                                   // data of the top corners
                q_a <= iia_q;
                q_b <= iib_q;
                s2  <= psq[wx + 8'd19] - psq[wx + 8'd1];
                es  <= E_N3;
            end
            E_N3: begin                                   // bottom corners
                s1 <= q_a - q_b - iia_q + iib_q;
                es <= E_N4;
            end
            E_N4: begin
                t324 <= ({10'd0, s2} << 8) + ({10'd0, s2} << 6) + ({10'd0, s2} << 2);
                s1sq <= s1 * s1;
                es   <= E_N5;
            end
            E_N5: begin
                nf2 <= $signed({2'b0, t324}) - $signed({2'b0, s1sq});
                es  <= E_SQRT;
                sq_i <= 5'd0;
            end
            E_SQRT: begin
                if (sq_i == 5'd0) begin
                    // nf2 < 0 -> 0; >= 2^32 -> use nf2 / 4
                    if (nf2 < 0) begin
                        big  <= 1'b0;
                        sq_n <= 32'd0;
                    end else if (nf2[36:32] != 5'd0) begin
                        big  <= 1'b1;
                        sq_n <= nf2[33:2];
                    end else begin
                        big  <= 1'b0;
                        sq_n <= nf2[31:0];
                    end
                    sq_r   <= 32'd0;
                    sq_bit <= 32'h4000_0000;
                    sq_i   <= 5'd1;
                end else begin
                    if (sq_n >= sq_r + sq_bit) begin
                        sq_n <= sq_n - (sq_r + sq_bit);
                        sq_r <= (sq_r >> 1) + sq_bit;
                    end else begin
                        sq_r <= sq_r >> 1;
                    end
                    sq_bit <= sq_bit >> 2;
                    sq_i   <= sq_i + 5'd1;
                    if (sq_i == 5'd16)
                        es <= E_NF;
                end
            end
            E_NF: begin
                // nf = big ? 2r : r; 0 -> 1; nf2x = 2 nf
                if (sq_r == 32'd0)
                    nf2x <= 19'd2;
                else
                    nf2x <= big ? {sq_r[16:0], 2'b00} : {sq_r[17:0], 1'b0};
                stg <= 4'd0;
                wk  <= 9'd0;
                es  <= E_STG;
            end

            // ── stages ──
            E_STG: begin
                scnt <= srom[stg][47:32];
                sthr <= srom[stg][31:0];
                acc  <= 32'd0;
                wrom_addr <= wk;
                es   <= E_FETCH;
            end
            E_FETCH: es <= E_DEC;                         // ROM read latency
            E_DEC: begin
                rx[0] <= wq[4:0];   ry[0] <= wq[9:5];   rw[0] <= wq[14:10]; rh[0] <= wq[19:15];
                rx[1] <= wq[24:20]; ry[1] <= wq[29:25]; rw[1] <= wq[34:30]; rh[1] <= wq[39:35];
                w3[1] <= wq[40];
                rx[2] <= wq[45:41]; ry[2] <= wq[50:46]; rw[2] <= wq[55:51]; rh[2] <= wq[60:56];
                w3[2] <= wq[61];
                has2  <= wq[62];
                thr   <= wq[94:63];
                lval  <= wq[110:95];
                rval  <= wq[126:111];
                j     <= 3'd0;
                jv1   <= 1'b0;
                jv2   <= 1'b0;
                jv3   <= 1'b0;
                f     <= 22'sd0;
                es    <= E_RECT;
            end
            // issue corner pair j (A/B or C/D of rect j>>1), process the pair issued before
            E_RECT: begin
                prod <= thr * $signed({13'd0, nf2x});
                if (j < jmax) begin
                    iia_addr <= row_off_j + cx_j;
                    iib_addr <= row_off_j + cx_j + rw[j[2:1]];
                    jd1 <= j;
                    jv1 <= 1'b1;
                    j   <= j + 3'd1;
                end else begin
                    jv1 <= 1'b0;
                end
                jd2 <= jd1;
                jv2 <= jv1;
                jd3 <= jd2;
                jv3 <= jv2;
                qa3 <= iia_q;
                qb3 <= iib_q;
                if (jv3) begin
                    if (!jd3[0]) begin
                        tmp <= $signed({2'b0, qa3}) - $signed({2'b0, qb3});       // A - B
                    end else begin
                        case (jd3[2:1])
                            2'd0: f <= -rsum_d_now;
                            2'd1: f <= f + (w3[1] ? rsum3_now : rsum2_now);
                            default: f <= f + (w3[2] ? rsum3_now : rsum2_now);
                        endcase
                    end
                end
                if (!jv1 && !jv2 && !jv3 && j >= jmax)
                    es <= E_CMP;
            end
            E_CMP: begin
                tval     <= prod[63:32];
                es       <= E_NEXT;
            end
            E_NEXT: begin
                acc      <= acc + ((f <= tval) ? {16'd0, lval} : {16'd0, rval});
                cnt_weak <= cnt_weak + 32'd1;
                wk       <= wk + 9'd1;
                scnt     <= scnt - 16'd1;
                es       <= E_SEND;
            end
            E_SEND: begin
                if (scnt != 16'd0) begin
                    wrom_addr <= wk;
                    es <= E_FETCH;
                end else if ($signed(acc) < sthr) begin   // rejected
                    wx <= wx + stp;
                    es <= E_WIN;
                end else if (stg == NST - 1) begin        // passed all HW stages
                    if (!f_full) begin
                        f_din  <= {wy, wx};
                        f_push <= 1'b1;
                        wx     <= wx + stp;
                        es     <= E_WIN;
                    end
                end else begin
                    stg <= stg + 4'd1;
                    es  <= E_STG;
                end
            end
            default: es <= E_IDLE;
            endcase
        end
    end

endmodule
