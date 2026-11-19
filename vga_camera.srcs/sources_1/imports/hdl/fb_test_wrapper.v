//Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
//Copyright 2022-2025 Advanced Micro Devices, Inc. All Rights Reserved.
//--------------------------------------------------------------------------------
//Tool Version: Vivado v.2025.2 (win64) Build 6299465 Fri Nov 14 19:35:11 GMT 2025
//Date        : Fri Apr  3 10:57:15 2026
//Host        : R7600 running 64-bit major release  (build 9200)
//Command     : generate_target fb_test_wrapper.bd
//Design      : fb_test_wrapper
//Purpose     : IP block netlist
//--------------------------------------------------------------------------------
`timescale 1 ps / 1 ps

module fb_test_wrapper
   (HSYNC,
    HSYNC_1,
    PCLK,
    RESET_N,
    RGB,
    VSYNC,
    VSYNC_1,
    status);
  output HSYNC;
  output HSYNC_1;
  input PCLK;
  input RESET_N;
  output [23:0]RGB;
  output VSYNC;
  output VSYNC_1;
  output status;

  wire HSYNC;
  wire HSYNC_1;
  wire PCLK;
  wire RESET_N;
  wire [23:0]RGB;
  wire VSYNC;
  wire VSYNC_1;
  wire [31:0]status;

  fb_test fb_test_i
       (.HSYNC(HSYNC),
        .HSYNC_1(HSYNC_1),
        .PCLK(PCLK),
        .RESET_N(RESET_N),
        .RGB(RGB),
        .VSYNC(VSYNC),
        .VSYNC_1(VSYNC_1),
        .status(status));
endmodule
