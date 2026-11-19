`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/04/03 08:25:54
// Design Name: 
// Module Name: fb_test_tb
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////
// `include "axi_vip_pkg.sv"
// `include "design_1_axi_vip_0_0_pkg.sv"  // 生成名に合わせる
`include "fb_test_axi_vip_0_1_pkg.sv"

import axi_vip_pkg::*;
import fb_test_axi_vip_0_1_pkg::*;

module fb_test_tb();
    reg pclk;
    reg reset;
    
    initial pclk = 0;
    always #40 pclk = ~pclk;

  fb_test_axi_vip_0_1  axi_mst;
    
    fb_test_wrapper dut (
        .PCLK(pclk),
        .HSYNC(hsync),
        .VSYNC(vsync),
        .RESET_N(reset),
        .VSYNC_1(vsync_1),
        .HSYNC_1(hsync_1),
        .RGB(RGB),
        .status(status)
        );
        
    initial begin
      axi_mst = new("axi_mst", dut.u_bd.axi_vip_0.inst.IF);
      axi_mst.start_master();

      // リセット待ち
      @(negedge rst_n);
      @(posedge rst_n);
      repeat(20) @(posedge clk);

      // TPG レジスタ設定 (320×240, カラーバー)
      axi_write(32'h10, 32'd320);  // cols
      axi_write(32'h18, 32'd240);  // rows
      axi_write(32'h28, 32'd9);    // pattern_id: 9 = Color bars
      axi_write(32'h00, 32'h81);   // CTRL: ap_start=1, auto_restart=1

      // ここからストリームが出始める

        reset = 0;
        #100
        reset = 1;
        
        #10000
        $display("Start");
    end
  task axi_write(input [31:0] addr, data);
      axi_transaction  wr_trans;
      wr_trans = axi_mst.wr_driver.create_transaction("wr");
      wr_trans.set_write_cmd(addr, XIL_AXI_BURST_TYPE_FIXED, 0, 0, XIL_AXI_SIZE_4BYTE);
      wr_trans.set_data_block(data, 0);
      axi_mst.wr_driver.send(wr_trans);
  endtask
endmodule
