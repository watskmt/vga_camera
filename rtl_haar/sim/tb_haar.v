`timescale 1ns / 1ps
// tb_haar.v: haar_engine against the face.c model (vectors from sw/tools/haar_vectors.py)
//   runs every level listed in LEVELS: writes the image over AXI4-Lite, starts the
//   engine, pops the FIFO while it runs and compares with lvl<L>_exp.txt
module tb_haar;
    reg clk = 0, rstn = 0;
    always #5 clk = ~clk;

    reg  [15:0] awaddr;  reg awvalid; wire awready;
    reg  [31:0] wdata;   reg wvalid;  wire wready;
    wire [1:0]  bresp;   wire bvalid; reg bready;
    reg  [15:0] araddr;  reg arvalid; wire arready;
    wire [31:0] rdata;   wire [1:0] rresp; wire rvalid; reg rready;

    haar_engine dut (
        .aclk(clk), .aresetn(rstn),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready)
    );

    task axi_write(input [15:0] a, input [31:0] d);
        begin
            @(posedge clk);
            awaddr <= a; awvalid <= 1; wdata <= d; wvalid <= 1; bready <= 1;
            fork
                begin wait (awready); @(posedge clk); awvalid <= 0; end
                begin wait (wready);  @(posedge clk); wvalid  <= 0; end
            join
            wait (bvalid); @(posedge clk); bready <= 0;
        end
    endtask

    task axi_read(input [15:0] a, output [31:0] d);
        begin
            @(posedge clk);
            araddr <= a; arvalid <= 1; rready <= 1;
            wait (arready); @(posedge clk); arvalid <= 0;
            wait (rvalid); d = rdata; @(posedge clk); rready <= 0;
        end
    endtask

    reg [31:0] img [0:4799];
    integer fd, i, n, lw, lh, step, exp_win, exp_weak, ex, ey, got_n, exp_n, errors, total_err;
    reg [31:0] v;
    integer gx [0:1023], gy [0:1023];
    integer levels [0:7];
    integer nlev, li, L, running;
    reg [8*64-1:0] fname;

    initial begin
        awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
        total_err = 0;
        nlev = 2; levels[0] = 0; levels[1] = 4;
        repeat (10) @(posedge clk);
        rstn = 1;
        axi_read(16'h001C, v);
        $display("MAGIC %h  INFO %h", v, 0);
        axi_read(16'h0018, v);
        $display("INFO  stages %0d weaks %0d", v[7:0], v[23:8]);
        for (li = 0; li < nlev; li = li + 1) begin
            L = levels[li];
            $sformat(fname, "lvl%0d_img.mem", L);
            $readmemh(fname, img);
            $sformat(fname, "lvl%0d_exp.txt", L);
            fd = $fopen(fname, "r");
            n = $fscanf(fd, "%d %d %d %d %d\n", lw, lh, step, exp_win, exp_weak);
            for (i = 0; i < 4800; i = i + 1)
                axi_write(16'h8000 + i * 4, img[i]);
            axi_write(16'h0008, {15'd0, step == 2, lh[7:0], lw[7:0]});
            axi_write(16'h0000, 32'h1);
            got_n = 0;
            // pop results while running
            running = 1;
            while (running) begin
                axi_read(16'h000C, v);
                if (v[31]) begin
                    gx[got_n] = v[7:0]; gy[got_n] = v[15:8]; got_n = got_n + 1;
                end else begin
                    axi_read(16'h0004, v);
                    if (!v[0]) begin                      // finished: drain
                        axi_read(16'h000C, v);
                        while (v[31]) begin
                            gx[got_n] = v[7:0]; gy[got_n] = v[15:8]; got_n = got_n + 1;
                            axi_read(16'h000C, v);
                        end
                        running = 0;
                    end else begin
                        repeat (200) @(posedge clk);
                    end
                end
            end
            errors = 0;
            exp_n = 0;
            while (!$feof(fd)) begin
                n = $fscanf(fd, "%d %d\n", ex, ey);
                if (n == 2) begin
                    if (exp_n >= got_n || gx[exp_n] != ex || gy[exp_n] != ey) begin
                        $display("  level %0d: mismatch #%0d expected (%0d,%0d) got (%0d,%0d)",
                                 L, exp_n, ex, ey, gx[exp_n], gy[exp_n]);
                        errors = errors + 1;
                    end
                    exp_n = exp_n + 1;
                end
            end
            $fclose(fd);
            if (got_n != exp_n) begin
                $display("  level %0d: %0d results, expected %0d", L, got_n, exp_n);
                errors = errors + 1;
            end
            axi_read(16'h0010, v);
            if (v != exp_win) begin $display("  level %0d: windows %0d expected %0d", L, v, exp_win); errors = errors + 1; end
            axi_read(16'h0014, v);
            if (v != exp_weak) begin $display("  level %0d: weaks %0d expected %0d", L, v, exp_weak); errors = errors + 1; end
            $display("level %0d (%0dx%0d step %0d): %0d windows, %0d pass, %0d errors, t=%0t",
                     L, lw, lh, step, exp_win, got_n, errors, $time);
            total_err = total_err + errors;
        end
        if (total_err == 0) $display("PASS");
        else                $display("FAIL (%0d errors)", total_err);
        $finish;
    end
endmodule
