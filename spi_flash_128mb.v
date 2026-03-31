`timescale 1ns / 1ps
// =============================================================================
// spi_flash_128mb.v  -  128 Mb (16 MB) SPI フラッシュメモリ ビヘイビアモデル
// =============================================================================
// W25Q128 互換 (JEDEC ID: EF 40 18)
//
// 対応コマンド:
//   0x06  WREN       Write Enable
//   0x04  WRDI       Write Disable
//   0x05  RDSR1      Read Status Register-1
//   0x35  RDSR2      Read Status Register-2
//   0x9F  RDID       Read JEDEC ID  → EF 40 18
//   0x03  READ       Read Data  (SPI Mode 0/3)
//   0x0B  FAST_READ  Fast Read  (1 ダミーバイト付き)
//   0x02  PP         Page Program  (256 バイト / ページ, AND write)
//   0x20  SE         Sector Erase  4 KB
//   0x52  BE32       Block Erase  32 KB
//   0xD8  BE64       Block Erase  64 KB
//   0xC7  CE         Chip Erase
//   0x60  CE2        Chip Erase (別コード)
//   0xB9  DP         Deep Power Down
//   0xAB  RDP        Release from Deep Power Down
//
// メモリ仕様:
//   容量   : 16,777,216 バイト (16 MB)
//   アドレス: 24 bit (0x000000 〜 0xFFFFFF)
//   ページ : 256 バイト (0x100 バイト境界)
//   セクタ : 4 KB (0x1000 バイト境界)
//   ブロック: 64 KB (0x10000 バイト境界)
//   消去後  : 全ビット 0xFF
//
// SPI タイミング:
//   Mode 0 (CPOL=0, CPHA=0) および Mode 3 (CPOL=1, CPHA=1) に対応
//   MOSI: SCK 立ち上がりでサンプル
//   MISO: SCK 立ち下がりで出力
// =============================================================================

module spi_flash_128mb (
    input  wire cs_n,    // Chip Select  (負論理)
    input  wire sck,     // Serial Clock
    input  wire mosi,    // Master Out Slave In
    output reg  miso,    // Master In Slave Out
    input  wire wp_n,    // Write Protect (負論理, 未使用時は 1 に固定)
    input  wire hold_n   // Hold          (負論理, 未使用時は 1 に固定)
);

    // =========================================================================
    // 定数
    // =========================================================================
    localparam MEM_SIZE    = 1 << 24;   // 16,777,216 バイト
    localparam PAGE_SIZE   = 256;
    localparam SECTOR_SIZE = 4096;
    localparam BLOCK32_SIZE= 32768;
    localparam BLOCK64_SIZE= 65536;

    // JEDEC ID
    localparam JEDEC_MFR  = 8'hEF;     // Winbond
    localparam JEDEC_TYPE = 8'h40;     // SPI NOR
    localparam JEDEC_CAP  = 8'h18;     // 128 Mb

    // コマンド
    localparam CMD_WREN      = 8'h06;
    localparam CMD_WRDI      = 8'h04;
    localparam CMD_RDSR1     = 8'h05;
    localparam CMD_RDSR2     = 8'h35;
    localparam CMD_RDID      = 8'h9F;
    localparam CMD_READ      = 8'h03;
    localparam CMD_FAST_READ = 8'h0B;
    localparam CMD_PP        = 8'h02;
    localparam CMD_SE        = 8'h20;
    localparam CMD_BE32      = 8'h52;
    localparam CMD_BE64      = 8'hD8;
    localparam CMD_CE        = 8'hC7;
    localparam CMD_CE2       = 8'h60;
    localparam CMD_DP        = 8'hB9;
    localparam CMD_RDP       = 8'hAB;

    // 状態
    localparam ST_IDLE  = 4'd0;
    localparam ST_CMD   = 4'd1;
    localparam ST_ADDR  = 4'd2;
    localparam ST_DUMMY = 4'd3;
    localparam ST_READ  = 4'd4;
    localparam ST_PP    = 4'd5;
    localparam ST_SR    = 4'd6;
    localparam ST_ID    = 4'd7;

    // =========================================================================
    // 内部レジスタ
    // =========================================================================
    reg [7:0]  mem [0:MEM_SIZE-1];          // フラッシュメモリ本体

    // 入力ステートマシン
    reg [3:0]  state;
    reg [7:0]  cmd_reg;
    reg [23:0] addr_reg;
    reg [2:0]  in_bit_cnt;                  // MOSI ビットカウンタ (7→0)
    reg [7:0]  in_byte_cnt;                 // コマンド内バイトカウンタ
    reg [7:0]  in_shift;                    // MOSI シフトレジスタ

    // 出力制御
    reg        out_active;                  // MISO 出力中フラグ
    reg [7:0]  out_shift;                   // MISO シフトレジスタ
    reg [2:0]  out_bit_cnt;                 // MISO ビットカウンタ (7→0)
    reg [23:0] out_addr;                    // 読み出しアドレス
    reg [7:0]  id_byte_cnt;                 // JEDEC ID バイト番号

    // ステータス
    reg        wel;                         // Write Enable Latch
    reg        power_down;                  // Deep Power Down フラグ

    // Page Program バッファ
    reg [7:0]  pp_buf [0:PAGE_SIZE-1];
    reg [7:0]  pp_cnt;                      // PP バッファの書き込みバイト数

    integer ii;

    // =========================================================================
    // 初期化 (全ビット 0xFF = 消去済み状態)
    // =========================================================================
    initial begin
        for (ii = 0; ii < MEM_SIZE; ii = ii + 1)
            mem[ii] = 8'hFF;
        state       = ST_IDLE;
        in_bit_cnt  = 3'd7;
        in_byte_cnt = 8'd0;
        in_shift    = 8'h00;
        out_active  = 1'b0;
        out_shift   = 8'h00;
        out_bit_cnt = 3'd7;
        out_addr    = 24'd0;
        id_byte_cnt = 8'd0;
        pp_cnt      = 8'd0;
        wel         = 1'b0;
        power_down  = 1'b0;
        miso        = 1'bz;
        cmd_reg     = 8'h00;
        addr_reg    = 24'd0;
    end

    // =========================================================================
    // CS_N 立ち下がり : トランザクション開始
    // =========================================================================
    always @(negedge cs_n) begin
        state       = ST_CMD;
        in_bit_cnt  = 3'd7;
        in_byte_cnt = 8'd0;
        in_shift    = 8'h00;
        out_active  = 1'b0;
        pp_cnt      = 8'd0;
        miso        = 1'bz;
    end

    // =========================================================================
    // CS_N 立ち上がり : トランザクション終了 / Page Program 確定
    // =========================================================================
    always @(posedge cs_n) begin
        // Page Program の書き込みをメモリに反映 (AND write = 1→0 のみ可能)
        if (state == ST_PP && wel && pp_cnt > 0) begin
            for (ii = 0; ii < pp_cnt; ii = ii + 1) begin
                mem[{addr_reg[23:8], addr_reg[7:0] + ii[7:0]}] =
                    mem[{addr_reg[23:8], addr_reg[7:0] + ii[7:0]}] & pp_buf[ii];
            end
            wel = 1'b0;
        end
        state      = ST_IDLE;
        out_active = 1'b0;
        miso       = 1'bz;
    end

    // =========================================================================
    // SCK 立ち上がり : MOSI サンプリング & 入力ステートマシン
    // =========================================================================
    always @(posedge sck) begin
        if (!cs_n && !power_down) begin
            in_shift = {in_shift[6:0], mosi};

            if (in_bit_cnt == 3'd0) begin
                process_byte(in_shift);
                in_bit_cnt  = 3'd7;
                in_byte_cnt = in_byte_cnt + 1;
            end else begin
                in_bit_cnt = in_bit_cnt - 1;
            end
        end
    end

    // =========================================================================
    // SCK 立ち下がり : MISO 出力
    // =========================================================================
    always @(negedge sck) begin
        if (!cs_n && out_active) begin
            // MSB を出力
            miso = out_shift[7];

            if (out_bit_cnt == 3'd0) begin
                // 1 バイト送出完了 → 次バイトをロード
                out_bit_cnt = 3'd7;
                case (state)
                    ST_READ: begin
                        out_addr  = out_addr + 1;
                        out_shift = mem[out_addr];      // 新アドレスのデータ
                    end
                    ST_SR: begin
                        out_shift = {6'b0, wel, 1'b0};  // ステータス再ロード
                    end
                    ST_ID: begin
                        id_byte_cnt = id_byte_cnt + 1;
                        case (id_byte_cnt)
                            8'd1:    out_shift = JEDEC_TYPE;
                            8'd2:    out_shift = JEDEC_CAP;
                            default: out_shift = 8'hFF;
                        endcase
                    end
                    default: out_shift = 8'hFF;
                endcase
            end else begin
                out_bit_cnt = out_bit_cnt - 1;
                out_shift   = {out_shift[6:0], 1'b0};  // 左シフト
            end
        end else if (!cs_n) begin
            miso = 1'bz;
        end
    end

    // =========================================================================
    // バイト処理タスク (posedge SCK で 8 bit 受信完了時に呼ばれる)
    // =========================================================================
    task process_byte;
        input [7:0] data;
        begin
            case (state)

                // ── コマンドバイト受信 ──────────────────────────
                ST_CMD: begin
                    cmd_reg     = data;
                    in_byte_cnt = 8'd0;
                    addr_reg    = 24'd0;

                    case (data)
                        CMD_WREN: begin
                            wel = 1'b1;
                            // CS_N を High にして完了
                        end

                        CMD_WRDI: begin
                            wel = 1'b0;
                        end

                        CMD_RDSR1: begin
                            out_shift   = {6'b0, wel, 1'b0};  // [WEL | BUSY=0]
                            out_bit_cnt = 3'd7;
                            out_active  = 1'b1;
                            state       = ST_SR;
                        end

                        CMD_RDSR2: begin
                            out_shift   = 8'h00;
                            out_bit_cnt = 3'd7;
                            out_active  = 1'b1;
                            state       = ST_SR;
                        end

                        CMD_RDID: begin
                            out_shift   = JEDEC_MFR;
                            out_bit_cnt = 3'd7;
                            id_byte_cnt = 8'd0;
                            out_active  = 1'b1;
                            state       = ST_ID;
                        end

                        CMD_READ, CMD_FAST_READ: begin
                            state = ST_ADDR;
                        end

                        CMD_PP: begin
                            if (wel)
                                state = ST_ADDR;
                        end

                        CMD_SE, CMD_BE32, CMD_BE64: begin
                            if (wel)
                                state = ST_ADDR;
                        end

                        CMD_CE, CMD_CE2: begin
                            if (wel) begin
                                $display("[spi_flash] Chip Erase start");
                                for (ii = 0; ii < MEM_SIZE; ii = ii + 1)
                                    mem[ii] = 8'hFF;
                                wel = 1'b0;
                                $display("[spi_flash] Chip Erase done");
                            end
                        end

                        CMD_DP: begin
                            power_down = 1'b1;
                            $display("[spi_flash] Enter Deep Power Down");
                        end

                        CMD_RDP: begin
                            power_down = 1'b0;
                            $display("[spi_flash] Release Deep Power Down");
                        end

                        default:
                            $display("[spi_flash] Unknown command: 0x%02X", data);
                    endcase
                end // ST_CMD

                // ── アドレスバイト受信 (3 バイト = 24 bit) ────────
                ST_ADDR: begin
                    case (in_byte_cnt)
                        8'd0: addr_reg[23:16] = data;
                        8'd1: addr_reg[15:8]  = data;
                        8'd2: begin
                            addr_reg[7:0] = data;
                            case (cmd_reg)
                                CMD_READ: begin
                                    out_addr    = addr_reg;
                                    out_shift   = mem[addr_reg];
                                    out_bit_cnt = 3'd7;
                                    out_active  = 1'b1;
                                    state       = ST_READ;
                                    $display("[spi_flash] READ  addr=0x%06X", addr_reg);
                                end
                                CMD_FAST_READ: begin
                                    state = ST_DUMMY;  // 1 ダミーバイト待ち
                                end
                                CMD_PP: begin
                                    pp_cnt = 8'd0;
                                    state  = ST_PP;
                                    $display("[spi_flash] PP    addr=0x%06X", addr_reg);
                                end
                                CMD_SE: begin
                                    $display("[spi_flash] SE    addr=0x%06X", addr_reg);
                                    for (ii = 0; ii < SECTOR_SIZE; ii = ii + 1)
                                        mem[{addr_reg[23:12], 12'h000} + ii] = 8'hFF;
                                    wel   = 1'b0;
                                    state = ST_IDLE;
                                end
                                CMD_BE32: begin
                                    $display("[spi_flash] BE32  addr=0x%06X", addr_reg);
                                    for (ii = 0; ii < BLOCK32_SIZE; ii = ii + 1)
                                        mem[{addr_reg[23:15], 15'h0000} + ii] = 8'hFF;
                                    wel   = 1'b0;
                                    state = ST_IDLE;
                                end
                                CMD_BE64: begin
                                    $display("[spi_flash] BE64  addr=0x%06X", addr_reg);
                                    for (ii = 0; ii < BLOCK64_SIZE; ii = ii + 1)
                                        mem[{addr_reg[23:16], 16'h0000} + ii] = 8'hFF;
                                    wel   = 1'b0;
                                    state = ST_IDLE;
                                end
                            endcase
                        end
                    endcase
                end // ST_ADDR

                // ── ダミーバイト (FAST_READ 用) ────────────────
                ST_DUMMY: begin
                    out_addr    = addr_reg;
                    out_shift   = mem[addr_reg];
                    out_bit_cnt = 3'd7;
                    out_active  = 1'b1;
                    state       = ST_READ;
                    $display("[spi_flash] FAST_READ addr=0x%06X", addr_reg);
                end

                // ── データ読み出し中 (MOSI は don't-care) ────────
                ST_READ: ;  // 出力は negedge ハンドラが管理

                // ── Page Program データ受信 ────────────────────
                ST_PP: begin
                    if (pp_cnt < PAGE_SIZE) begin
                        pp_buf[pp_cnt] = data;
                        pp_cnt         = pp_cnt + 1;
                    end
                end

                // ── ステータスレジスタ / JEDEC ID 読み出し中 ──
                ST_SR: ;   // 出力は negedge ハンドラが管理
                ST_ID: ;   // 出力は negedge ハンドラが管理

            endcase
        end
    endtask

    // =========================================================================
    // デバッグ用: メモリ初期値ロード (シミュレーションのみ)
    // =========================================================================
    task load_mem_from_file;
        input [255*8-1:0] filename;
        begin
            $readmemh(filename, mem);
            $display("[spi_flash] Loaded memory from %0s", filename);
        end
    endtask

    task dump_mem;
        input [23:0] start_addr;
        input [23:0] length;
        integer jj;
        begin
            for (jj = 0; jj < length; jj = jj + 1)
                $display("[spi_flash] mem[0x%06X] = 0x%02X",
                         start_addr + jj, mem[start_addr + jj]);
        end
    endtask

endmodule
