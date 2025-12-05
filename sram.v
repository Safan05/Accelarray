module sram_subsystem (
    // Global signals
    input wire clk,
    input wire rst_n,
    
    // ========================================================================
    // Input Tile Interface (8-bit external, 128-bit internal)
    // ========================================================================
    // Write interface (from Data Loader - 8-bit external bus)
    input wire [7:0] input_tile_wr_data,
    input wire [10:0] input_tile_wr_addr,
    input wire input_tile_wr_en,
    input wire input_tile_wr_bank_sel,
    
    // Read interface (to Systolic Array - 128-bit internal bus)
    input wire [10:0] input_tile_rd_addr,
    input wire input_tile_rd_en,         
    input wire input_tile_rd_bank_sel,   
    output reg [127:0] input_tile_rd_data,
    output reg input_tile_rd_valid,
    
    // ========================================================================
    // Output Accumulation Interface (32-bit)
    // ========================================================================
    // Write interface (from Systolic Array - 32-bit partial sums)
    input wire [31:0] output_accum_wr_data,
    input wire [10:0] output_accum_wr_addr,
    input wire output_accum_wr_en,       
    input wire output_accum_wr_bank_sel, 
    
    // Read interface (to output stream or for accumulation)
    input wire [10:0] output_accum_rd_addr,
    input wire output_accum_rd_en,       
    input wire output_accum_rd_bank_sel,
    output reg [127:0] output_accum_rd_data,
    output reg output_accum_rd_valid,
    
    // ========================================================================
    // Kernel Weight Interface (8-bit, single port)
    // ========================================================================
    input wire [7:0] kernel_wr_data,
    input wire [9:0] kernel_wr_addr,     
    input wire kernel_wr_en,             
    
    input wire [9:0] kernel_rd_addr,     
    input wire kernel_rd_en,             
    output reg [127:0] kernel_rd_data,   
    output reg kernel_rd_valid
);

    // ========================================================================
    // Memory Instance Signals
    // sram_1rw1r_32_256_8_sky130: 32-bit word, 256 depth, 8-bit address
    // Total per instance: 256 words × 4 bytes = 1KB
    // ========================================================================
    
    // Input Banks: Need 2KB each = 2 SRAM instances per bank
    // Bank 0
    wire [31:0] input_b0_sram0_dout0, input_b0_sram0_dout1;
    wire [31:0] input_b0_sram1_dout0, input_b0_sram1_dout1;
    reg [31:0] input_b0_sram0_din0, input_b0_sram1_din0;
    reg [7:0] input_b0_sram0_addr0, input_b0_sram1_addr0;
    reg [7:0] input_b0_sram0_addr1, input_b0_sram1_addr1;
    reg input_b0_sram0_csb0, input_b0_sram0_web0, input_b0_sram0_csb1;
    reg input_b0_sram1_csb0, input_b0_sram1_web0, input_b0_sram1_csb1;
    reg [3:0] input_b0_sram0_wmask0, input_b0_sram1_wmask0;
    
    // Bank 1
    wire [31:0] input_b1_sram0_dout0, input_b1_sram0_dout1;
    wire [31:0] input_b1_sram1_dout0, input_b1_sram1_dout1;
    reg [31:0] input_b1_sram0_din0, input_b1_sram1_din0;
    reg [7:0] input_b1_sram0_addr0, input_b1_sram1_addr0;
    reg [7:0] input_b1_sram0_addr1, input_b1_sram1_addr1;
    reg input_b1_sram0_csb0, input_b1_sram0_web0, input_b1_sram0_csb1;
    reg input_b1_sram1_csb0, input_b1_sram1_web0, input_b1_sram1_csb1;
    reg [3:0] input_b1_sram0_wmask0, input_b1_sram1_wmask0;
    
    // Output Banks: Need 8KB each = 8 SRAM instances per bank (for 32-bit words)
    // Bank 0 (8 instances)
    wire [31:0] output_b0_sram_dout0[0:7];
    wire [31:0] output_b0_sram_dout1[0:7];
    reg [31:0] output_b0_sram_din0[0:7];
    reg [7:0] output_b0_sram_addr0[0:7];
    reg [7:0] output_b0_sram_addr1[0:7];
    reg output_b0_sram_csb0[0:7];
    reg output_b0_sram_web0[0:7];
    reg output_b0_sram_csb1[0:7];
    reg [3:0] output_b0_sram_wmask0[0:7];
    
    // Bank 1 (8 instances)
    wire [31:0] output_b1_sram_dout0[0:7];
    wire [31:0] output_b1_sram_dout1[0:7];
    reg [31:0] output_b1_sram_din0[0:7];
    reg [7:0] output_b1_sram_addr0[0:7];
    reg [7:0] output_b1_sram_addr1[0:7];
    reg output_b1_sram_csb0[0:7];
    reg output_b1_sram_web0[0:7];
    reg output_b1_sram_csb1[0:7];
    reg [3:0] output_b1_sram_wmask0[0:7];
    
    // Kernel Memory: Need 1KB = 1 SRAM instance
    wire [31:0] kernel_sram_dout0, kernel_sram_dout1;
    reg [31:0] kernel_sram_din0;
    reg [7:0] kernel_sram_addr0, kernel_sram_addr1;
    reg kernel_sram_csb0, kernel_sram_web0, kernel_sram_csb1;
    reg [3:0] kernel_sram_wmask0;
    
    // ========================================================================
    // SRAM Instantiations
    // ========================================================================
    
    // ------------------------------------------------------------------------
    // INPUT BANK 0 (2 SRAM instances = 2KB)
    // ------------------------------------------------------------------------
    sram_1rw1r_32_256_8_sky130 input_b0_sram0_inst (
        .clk0(clk), .csb0(input_b0_sram0_csb0), .web0(input_b0_sram0_web0),
        .wmask0(input_b0_sram0_wmask0), .addr0(input_b0_sram0_addr0),
        .din0(input_b0_sram0_din0), .dout0(input_b0_sram0_dout0),
        .clk1(clk), .csb1(input_b0_sram0_csb1), .addr1(input_b0_sram0_addr1),
        .dout1(input_b0_sram0_dout1)
    );
    
    sram_1rw1r_32_256_8_sky130 input_b0_sram1_inst (
        .clk0(clk), .csb0(input_b0_sram1_csb0), .web0(input_b0_sram1_web0),
        .wmask0(input_b0_sram1_wmask0), .addr0(input_b0_sram1_addr0),
        .din0(input_b0_sram1_din0), .dout0(input_b0_sram1_dout0),
        .clk1(clk), .csb1(input_b0_sram1_csb1), .addr1(input_b0_sram1_addr1),
        .dout1(input_b0_sram1_dout1)
    );
    
    // ------------------------------------------------------------------------
    // INPUT BANK 1 (2 SRAM instances = 2KB)
    // ------------------------------------------------------------------------
    sram_1rw1r_32_256_8_sky130 input_b1_sram0_inst (
        .clk0(clk), .csb0(input_b1_sram0_csb0), .web0(input_b1_sram0_web0),
        .wmask0(input_b1_sram0_wmask0), .addr0(input_b1_sram0_addr0),
        .din0(input_b1_sram0_din0), .dout0(input_b1_sram0_dout0),
        .clk1(clk), .csb1(input_b1_sram0_csb1), .addr1(input_b1_sram0_addr1),
        .dout1(input_b1_sram0_dout1)
    );
    
    sram_1rw1r_32_256_8_sky130 input_b1_sram1_inst (
        .clk0(clk), .csb0(input_b1_sram1_csb0), .web0(input_b1_sram1_web0),
        .wmask0(input_b1_sram1_wmask0), .addr0(input_b1_sram1_addr0),
        .din0(input_b1_sram1_din0), .dout0(input_b1_sram1_dout0),
        .clk1(clk), .csb1(input_b1_sram1_csb1), .addr1(input_b1_sram1_addr1),
        .dout1(input_b1_sram1_dout1)
    );
    
    // ------------------------------------------------------------------------
    // OUTPUT BANK 0 (8 SRAM instances = 8KB)
    // ------------------------------------------------------------------------
    genvar g;
    generate
        for (g = 0; g < 8; g = g + 1) begin : output_b0_srams
            sram_1rw1r_32_256_8_sky130 output_b0_sram_inst (
                .clk0(clk), .csb0(output_b0_sram_csb0[g]), .web0(output_b0_sram_web0[g]),
                .wmask0(output_b0_sram_wmask0[g]), .addr0(output_b0_sram_addr0[g]),
                .din0(output_b0_sram_din0[g]), .dout0(output_b0_sram_dout0[g]),
                .clk1(clk), .csb1(output_b0_sram_csb1[g]), .addr1(output_b0_sram_addr1[g]),
                .dout1(output_b0_sram_dout1[g])
            );
        end
    endgenerate
    
    // ------------------------------------------------------------------------
    // OUTPUT BANK 1 (8 SRAM instances = 8KB)
    // ------------------------------------------------------------------------
    generate
        for (g = 0; g < 8; g = g + 1) begin : output_b1_srams
            sram_1rw1r_32_256_8_sky130 output_b1_sram_inst (
                .clk0(clk), .csb0(output_b1_sram_csb0[g]), .web0(output_b1_sram_web0[g]),
                .wmask0(output_b1_sram_wmask0[g]), .addr0(output_b1_sram_addr0[g]),
                .din0(output_b1_sram_din0[g]), .dout0(output_b1_sram_dout0[g]),
                .clk1(clk), .csb1(output_b1_sram_csb1[g]), .addr1(output_b1_sram_addr1[g]),
                .dout1(output_b1_sram_dout1[g])
            );
        end
    endgenerate
    
    // ------------------------------------------------------------------------
    // KERNEL MEMORY (1 SRAM instance = 1KB)
    // ------------------------------------------------------------------------
    sram_1rw1r_32_256_8_sky130 kernel_sram_inst (
        .clk0(clk), .csb0(kernel_sram_csb0), .web0(kernel_sram_web0),
        .wmask0(kernel_sram_wmask0), .addr0(kernel_sram_addr0),
        .din0(kernel_sram_din0), .dout0(kernel_sram_dout0),
        .clk1(clk), .csb1(kernel_sram_csb1), .addr1(kernel_sram_addr1),
        .dout1(kernel_sram_dout1)
    );
    
    // ========================================================================
    // INPUT BANK WRITE LOGIC
    // 8-bit writes with byte-level masking
    // ========================================================================
    wire [1:0] input_wr_byte_sel = input_tile_wr_addr[1:0];
    wire [7:0] input_wr_word_addr = input_tile_wr_addr[9:2];
    wire input_wr_sram_sel = input_tile_wr_addr[10];   
    
    always @(*) begin
  
        input_b0_sram0_csb0 = 1'b1;
        input_b0_sram1_csb0 = 1'b1;
        input_b1_sram0_csb0 = 1'b1;
        input_b1_sram1_csb0 = 1'b1;
        
        input_b0_sram0_web0 = 1'b1;
        input_b0_sram1_web0 = 1'b1;
        input_b1_sram0_web0 = 1'b1;
        input_b1_sram1_web0 = 1'b1;
        
        input_b0_sram0_wmask0 = 4'b0000;
        input_b0_sram1_wmask0 = 4'b0000;
        input_b1_sram0_wmask0 = 4'b0000;
        input_b1_sram1_wmask0 = 4'b0000;
        
        input_b0_sram0_addr0 = 8'b0;
        input_b0_sram1_addr0 = 8'b0;
        input_b1_sram0_addr0 = 8'b0;
        input_b1_sram1_addr0 = 8'b0;
        
        input_b0_sram0_din0 = 32'b0;
        input_b0_sram1_din0 = 32'b0;
        input_b1_sram0_din0 = 32'b0;
        input_b1_sram1_din0 = 32'b0;
        
        if (input_tile_wr_en) begin
            if (input_tile_wr_bank_sel == 1'b0) begin
                // Writing to Bank 0
                if (input_wr_sram_sel == 1'b0) begin
                    // SRAM 0
                    input_b0_sram0_csb0 = 1'b0;
                    input_b0_sram0_web0 = 1'b0;
                    input_b0_sram0_addr0 = input_wr_word_addr;
                    input_b0_sram0_wmask0 = (4'b0001 << input_wr_byte_sel);
                    input_b0_sram0_din0 = {input_tile_wr_data, input_tile_wr_data, input_tile_wr_data, input_tile_wr_data};
                end else begin
                    // SRAM 1
                    input_b0_sram1_csb0 = 1'b0;
                    input_b0_sram1_web0 = 1'b0;
                    input_b0_sram1_addr0 = input_wr_word_addr;
                    input_b0_sram1_wmask0 = (4'b0001 << input_wr_byte_sel);
                    input_b0_sram1_din0 = {input_tile_wr_data, input_tile_wr_data, input_tile_wr_data, input_tile_wr_data};
                end
            end else begin
                // Writing to Bank 1
                if (input_wr_sram_sel == 1'b0) begin
                    // SRAM 0
                    input_b1_sram0_csb0 = 1'b0;
                    input_b1_sram0_web0 = 1'b0;
                    input_b1_sram0_addr0 = input_wr_word_addr;
                    input_b1_sram0_wmask0 = (4'b0001 << input_wr_byte_sel);
                    input_b1_sram0_din0 = {input_tile_wr_data, input_tile_wr_data, input_tile_wr_data, input_tile_wr_data};
                end else begin
                    // SRAM 1
                    input_b1_sram1_csb0 = 1'b0;
                    input_b1_sram1_web0 = 1'b0;
                    input_b1_sram1_addr0 = input_wr_word_addr;
                    input_b1_sram1_wmask0 = (4'b0001 << input_wr_byte_sel);
                    input_b1_sram1_din0 = {input_tile_wr_data, input_tile_wr_data, input_tile_wr_data, input_tile_wr_data};
                end
            end
        end
    end
    
    // ========================================================================
    // INPUT BANK READ LOGIC
    // 128-bit reads = 4 consecutive 32-bit words (16 bytes)
    // ========================================================================
    wire [7:0] input_rd_word_addr = input_tile_rd_addr[9:2];
    wire input_rd_sram_sel = input_tile_rd_addr[10];
    
    // Port 1 read signals (read-only port)
    always @(*) begin
        // Default: disable all read ports
        input_b0_sram0_csb1 = 1'b1;
        input_b0_sram1_csb1 = 1'b1;
        input_b1_sram0_csb1 = 1'b1;
        input_b1_sram1_csb1 = 1'b1;
        
        input_b0_sram0_addr1 = 8'b0;
        input_b0_sram1_addr1 = 8'b0;
        input_b1_sram0_addr1 = 8'b0;
        input_b1_sram1_addr1 = 8'b0;
        
        if (input_tile_rd_en) begin
            if (input_tile_rd_bank_sel == 1'b0) begin
                // Reading from Bank 0
                if (input_rd_sram_sel == 1'b0) begin
                    input_b0_sram0_csb1 = 1'b0;
                    input_b0_sram0_addr1 = input_rd_word_addr;
                end else begin
                    input_b0_sram1_csb1 = 1'b0;
                    input_b0_sram1_addr1 = input_rd_word_addr;
                end
            end else begin
                // Reading from Bank 1
                if (input_rd_sram_sel == 1'b0) begin
                    input_b1_sram0_csb1 = 1'b0;
                    input_b1_sram0_addr1 = input_rd_word_addr;
                end else begin
                    input_b1_sram1_csb1 = 1'b0;
                    input_b1_sram1_addr1 = input_rd_word_addr;
                end
            end
        end
    end
    
    // Pipeline stages for 128-bit assembly
    reg input_rd_en_d1, input_rd_en_d2, input_rd_en_d3;
    reg input_rd_bank_sel_d1, input_rd_bank_sel_d2, input_rd_bank_sel_d3;
    reg input_rd_sram_sel_d1, input_rd_sram_sel_d2, input_rd_sram_sel_d3;
    reg [7:0] input_rd_word_addr_d1, input_rd_word_addr_d2, input_rd_word_addr_d3;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            input_rd_en_d1 <= 1'b0;
            input_rd_en_d2 <= 1'b0;
            input_rd_en_d3 <= 1'b0;
            input_rd_bank_sel_d1 <= 1'b0;
            input_rd_bank_sel_d2 <= 1'b0;
            input_rd_bank_sel_d3 <= 1'b0;
            input_rd_sram_sel_d1 <= 1'b0;
            input_rd_sram_sel_d2 <= 1'b0;
            input_rd_sram_sel_d3 <= 1'b0;
            input_rd_word_addr_d1 <= 8'b0;
            input_rd_word_addr_d2 <= 8'b0;
            input_rd_word_addr_d3 <= 8'b0;
        end else begin
            input_rd_en_d1 <= input_tile_rd_en;
            input_rd_en_d2 <= input_rd_en_d1;
            input_rd_en_d3 <= input_rd_en_d2;
            input_rd_bank_sel_d1 <= input_tile_rd_bank_sel;
            input_rd_bank_sel_d2 <= input_rd_bank_sel_d1;
            input_rd_bank_sel_d3 <= input_rd_bank_sel_d2;
            input_rd_sram_sel_d1 <= input_rd_sram_sel;
            input_rd_sram_sel_d2 <= input_rd_sram_sel_d1;
            input_rd_sram_sel_d3 <= input_rd_sram_sel_d2;
            input_rd_word_addr_d1 <= input_rd_word_addr;
            input_rd_word_addr_d2 <= input_rd_word_addr_d1;
            input_rd_word_addr_d3 <= input_rd_word_addr_d2;
        end
    end
    
    // Assemble 128-bit output from 4 consecutive 32-bit reads
    reg [31:0] input_read_word0, input_read_word1, input_read_word2, input_read_word3;
    reg [1:0] input_read_stage;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            input_tile_rd_data <= 128'b0;
            input_tile_rd_valid <= 1'b0; 
            input_read_stage <= 2'b0;
        end else begin
            // Multi-cycle read: 4 cycles to fetch 4 words
            if (input_tile_rd_en && input_read_stage == 2'b0) begin
                input_read_stage <= 2'b01;
                input_tile_rd_valid <= 1'b0;
            end else if (input_read_stage != 2'b0) begin
                // Capture data from appropriate bank/SRAM
                if (input_rd_bank_sel_d1 == 1'b0) begin
                    if (input_rd_sram_sel_d1 == 1'b0) begin
                        case (input_read_stage)
                            2'b01: input_read_word0 <= input_b0_sram0_dout1;
                            2'b10: input_read_word1 <= input_b0_sram0_dout1;
                            2'b11: input_read_word2 <= input_b0_sram0_dout1;
                        endcase
                    end else begin
                        case (input_read_stage)
                            2'b01: input_read_word0 <= input_b0_sram1_dout1;
                            2'b10: input_read_word1 <= input_b0_sram1_dout1;
                            2'b11: input_read_word2 <= input_b0_sram1_dout1;
                        endcase
                    end
                end else begin
                    if (input_rd_sram_sel_d1 == 1'b0) begin
                        case (input_read_stage)
                            2'b01: input_read_word0 <= input_b1_sram0_dout1;
                            2'b10: input_read_word1 <= input_b1_sram0_dout1;
                            2'b11: input_read_word2 <= input_b1_sram0_dout1;
                        endcase
                    end else begin
                        case (input_read_stage)
                            2'b01: input_read_word0 <= input_b1_sram1_dout1;
                            2'b10: input_read_word1 <= input_b1_sram1_dout1;
                            2'b11: input_read_word2 <= input_b1_sram1_dout1;
                        endcase
                    end
                end
                
                if (input_read_stage == 2'b11) begin
                    // Last word read, assemble output
                    input_tile_rd_data <= {input_read_word3, input_read_word2, input_read_word1, input_read_word0};
                    input_tile_rd_valid <= 1'b1;
                    input_read_stage <= 2'b0;
                end else begin
                    input_read_stage <= input_read_stage + 1;
                    input_tile_rd_valid <= 1'b0;
                end
            end
        end
    end
    
    // ========================================================================
    // OUTPUT BANK WRITE LOGIC
    // 32-bit writes (full word)
    // ========================================================================
    wire [2:0] output_wr_sram_sel = output_accum_wr_addr[10:8];
    wire [7:0] output_wr_word_addr = output_accum_wr_addr[7:0];
    
    integer j;
    always @(*) begin
        // Default: disable all
        for (j = 0; j < 8; j = j + 1) begin
            output_b0_sram_csb0[j] = 1'b1;
            output_b0_sram_web0[j] = 1'b1;
            output_b0_sram_wmask0[j] = 4'b1111;
            output_b0_sram_addr0[j] = 8'b0;
            output_b0_sram_din0[j] = 32'b0;
            
            output_b1_sram_csb0[j] = 1'b1;
            output_b1_sram_web0[j] = 1'b1;
            output_b1_sram_wmask0[j] = 4'b1111;
            output_b1_sram_addr0[j] = 8'b0;
            output_b1_sram_din0[j] = 32'b0;
        end
        
        if (output_accum_wr_en) begin
            if (output_accum_wr_bank_sel == 1'b0) begin
                // Writing to Bank 0
                output_b0_sram_csb0[output_wr_sram_sel] = 1'b0;
                output_b0_sram_web0[output_wr_sram_sel] = 1'b0;
                output_b0_sram_wmask0[output_wr_sram_sel] = 4'b1111;
                output_b0_sram_addr0[output_wr_sram_sel] = output_wr_word_addr;
                output_b0_sram_din0[output_wr_sram_sel] = output_accum_wr_data;
            end else begin
                // Writing to Bank 1
                output_b1_sram_csb0[output_wr_sram_sel] = 1'b0;
                output_b1_sram_web0[output_wr_sram_sel] = 1'b0;
                output_b1_sram_wmask0[output_wr_sram_sel] = 4'b1111;
                output_b1_sram_addr0[output_wr_sram_sel] = output_wr_word_addr;
                output_b1_sram_din0[output_wr_sram_sel] = output_accum_wr_data;
            end
        end
    end
    
    // ========================================================================
    // OUTPUT BANK READ LOGIC
    // 128-bit reads = 4 consecutive 32-bit words from same or adjacent SRAMs
    // ========================================================================
    wire [2:0] output_rd_sram_sel = output_rd_addr[10:8];
    wire [7:0] output_rd_word_addr = output_rd_addr[7:0];
    
    integer k;
    always @(*) begin
        for (k = 0; k < 8; k = k + 1) begin
            output_b0_sram_csb1[k] = 1'b1;
            output_b0_sram_addr1[k] = 8'b0;
            output_b1_sram_csb1[k] = 1'b1;
            output_b1_sram_addr1[k] = 8'b0;
        end
        
        if (output_rd_en) begin
            if (output_rd_bank_sel == 1'b0) begin
                // Reading from Bank 0 - enable the selected SRAM
                output_b0_sram_csb1[output_rd_sram_sel] = 1'b0;
                output_b0_sram_addr1[output_rd_sram_sel] = output_rd_word_addr;
            end else begin
                // Reading from Bank 1
                output_b1_sram_csb1[output_rd_sram_sel] = 1'b0;
                output_b1_sram_addr1[output_rd_sram_sel] = output_rd_word_addr;
            end
        end
    end
    
    // Pipeline for multi-word reads
    reg output_rd_en_d1;
    reg output_rd_bank_sel_d1;
    reg [2:0] output_rd_sram_sel_d1;
    reg [7:0] output_rd_word_addr_d1;
    reg [1:0] output_read_stage;
    reg [31:0] output_read_word0, output_read_word1, output_read_word2, output_read_word3;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            output_rd_en_d1 <= 1'b0;
            output_rd_bank_sel_d1 <= 1'b0;
            output_rd_sram_sel_d1 <= 3'b0;
            output_rd_word_addr_d1 <= 8'b0;
        end else begin
            output_rd_en_d1 <= output_rd_en;
            output_rd_bank_sel_d1 <= output_rd_bank_sel;
            output_rd_sram_sel_d1 <= output_rd_sram_sel;
            output_rd_word_addr_d1 <= output_rd_word_addr;
        end
    end
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            output_rd_data <= 128'b0;
            output_rd_valid <= 1'b0;
            output_read_stage <= 2'b0;
        end else begin
            // Multi-cycle read: 4 cycles to fetch 4 consecutive words
            if (output_rd_en && output_read_stage == 2'b0) begin
                output_read_stage <= 2'b01;
                output_rd_valid <= 1'b0;
            end else if (output_read_stage != 2'b0) begin
                // Capture word from selected bank
                if (output_rd_bank_sel_d1 == 1'b0) begin
                    case (output_read_stage)
                        2'b01: output_read_word0 <= output_b0_sram_dout1[output_rd_sram_sel_d1];
                        2'b10: output_read_word1 <= output_b0_sram_dout1[output_rd_sram_sel_d1];
                        2'b11: output_read_word2 <= output_b0_sram_dout1[output_rd_sram_sel_d1];
                    endcase
                end else begin
                    case (output_read_stage)
                        2'b01: output_read_word0 <= output_b1_sram_dout1[output_rd_sram_sel_d1];
                        2'b10: output_read_word1 <= output_b1_sram_dout1[output_rd_sram_sel_d1];
                        2'b11: output_read_word2 <= output_b1_sram_dout1[output_rd_sram_sel_d1];
                    endcase
                end
                
                if (output_read_stage == 2'b11) begin
                    // Fetch last word and assemble
                    if (output_rd_bank_sel_d1 == 1'b0)
                        output_read_word3 <= output_b0_sram_dout1[output_rd_sram_sel_d1];
                    else
                        output_read_word3 <= output_b1_sram_dout1[output_rd_sram_sel_d1];
                        
                    output_rd_data <= {output_read_word3, output_read_word2, output_read_word1, output_read_word0};
                    output_rd_valid <= 1'b1;
                    output_read_stage <= 2'b0;
                end else begin
                    output_read_stage <= output_read_stage + 1;
                    output_rd_valid <= 1'b0;
                end
            end
        end
    end
    
    // ========================================================================
    // KERNEL MEMORY WRITE LOGIC
    // 8-bit writes with byte-level masking
    // ========================================================================
    wire [1:0] kernel_wr_byte_sel = kernel_wr_addr[1:0];
    wire [7:0] kernel_wr_word_addr = kernel_wr_addr[9:2];
    
    always @(*) begin
        kernel_sram_csb0 = 1'b1;
        kernel_sram_web0 = 1'b1;
        kernel_sram_wmask0 = 4'b0000;
        kernel_sram_addr0 = 8'b0;
        kernel_sram_din0 = 32'b0;
        
        if (kernel_wr_en) begin
            kernel_sram_csb0 = 1'b0;
            kernel_sram_web0 = 1'b0;
            kernel_sram_addr0 = kernel_wr_word_addr;
            kernel_sram_wmask0 = (4'b0001 << kernel_wr_byte_sel);
            kernel_sram_din0 = {kernel_wr_data, kernel_wr_data, kernel_wr_data, kernel_wr_data};
        end
    end
    
    // ========================================================================
    // KERNEL MEMORY READ LOGIC
    // 128-bit reads = 4 consecutive 32-bit words (16 bytes)
    // ========================================================================
    wire [7:0] kernel_rd_word_addr = kernel_rd_addr[9:2];
    
    always @(*) begin
        kernel_sram_csb1 = 1'b1;
        kernel_sram_addr1 = 8'b0;
        
        if (kernel_rd_en) begin
            kernel_sram_csb1 = 1'b0;
            kernel_sram_addr1 = kernel_rd_word_addr;
        end
    end
    
    // Multi-cycle kernel read
    reg kernel_rd_en_d1;
    reg [7:0] kernel_rd_word_addr_d1;
    reg [1:0] kernel_read_stage;
    reg [31:0] kernel_read_word0, kernel_read_word1, kernel_read_word2, kernel_read_word3;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            kernel_rd_en_d1 <= 1'b0;
            kernel_rd_word_addr_d1 <= 8'b0;
        end else begin
            kernel_rd_en_d1 <= kernel_rd_en;
            kernel_rd_word_addr_d1 <= kernel_rd_word_addr;
        end
    end
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            kernel_rd_data <= 128'b0;
            kernel_rd_valid <= 1'b0;
            kernel_read_stage <= 2'b0;
        end else begin
            if (kernel_rd_en && kernel_read_stage == 2'b0) begin
                kernel_read_stage <= 2'b01;
                kernel_rd_valid <= 1'b0;
            end else if (kernel_read_stage != 2'b0) begin
                case (kernel_read_stage)
                    2'b01: kernel_read_word0 <= kernel_sram_dout1;
                    2'b10: kernel_read_word1 <= kernel_sram_dout1;
                    2'b11: kernel_read_word2 <= kernel_sram_dout1;
                endcase
                
                if (kernel_read_stage == 2'b11) begin
                    kernel_read_word3 <= kernel_sram_dout1;
                    kernel_rd_data <= {kernel_read_word3, kernel_read_word2, kernel_read_word1, kernel_read_word0};
                    kernel_rd_valid <= 1'b1;
                    kernel_read_stage <= 2'b0;
                end else begin
                    kernel_read_stage <= kernel_read_stage + 1;
                    kernel_rd_valid <= 1'b0;
                end
            end
        end
    end
    
endmodule

// ============================================================================
// Ping-Pong Controller Helper Module
// Manages bank switching for seamless operation
// ============================================================================

module pingpong_controller (
    input wire clk,
    input wire rst_n,
    
    // Control signals
    input wire swap_banks,
    input wire enable,
    
    // Bank selection outputs
    output reg write_bank,
    output reg read_bank
);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_bank <= 1'b0;
            read_bank <= 1'b1;
        end else if (enable && swap_banks) begin
            // Swap the banks
            write_bank <= ~write_bank;
            read_bank <= ~read_bank;
        end
    end

endmodule
