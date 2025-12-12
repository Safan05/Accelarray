// ============================================================================
// Parameterized Memory Subsystem for Convolution Accelerator
// Features: Ping-Pong Buffering, Dual Memory Regions (Input/Weight-Accum)
// ============================================================================

module sram #(
    parameter ADDR_WIDTH = 8,           // SRAM address width (256 words)
    parameter SRAM_WIDTH = 32           // SRAM word width (fixed for Sky130 macros)
)(
    // Global signals
    input wire clk,
    input wire rst_n,
    
    // Ping-Pong control - Independent bank selection
    input wire loader_bank_sel,         // Bank selector for Data Loader (0=Bank0, 1=Bank1)
    input wire array_bank_sel,          // Bank selector for Systolic Array (0=Bank0, 1=Bank1)
    
    // ========== Input Buffer Interface (Image Tiles) ==========
    // Write Port (Data Loader)
    // Note: Operates at SRAM_WIDTH granularity (32-bit words)
    input wire input_wr_en,
    input wire [ADDR_WIDTH-1:0] input_wr_addr,
    input wire [SRAM_WIDTH-1:0] input_wr_data,
    input wire [SRAM_WIDTH/8-1:0] input_wr_mask,  // 4 bits, one per byte
    
    // Read Port (Systolic Array)
    input wire input_rd_en,
    input wire [ADDR_WIDTH-1:0] input_rd_addr,
    output wire [SRAM_WIDTH-1:0] input_rd_data,
    
    // ========== Weight/Accumulation Buffer Interface ==========
    // Write Port (Weight Load or Accumulation Write-back)
    input wire weight_wr_en,
    input wire [ADDR_WIDTH-1:0] weight_wr_addr,
    input wire [SRAM_WIDTH-1:0] weight_wr_data,
    input wire [SRAM_WIDTH/8-1:0] weight_wr_mask,
    
    // Read Port (Weight Read or Accumulation Read)
    input wire weight_rd_en,
    input wire [ADDR_WIDTH-1:0] weight_rd_addr,
    output wire [SRAM_WIDTH-1:0] weight_rd_data
);
    
    // ========================================================================
    // Reset Synchronization and Control
    // ========================================================================
    
    // Registered control signals for clean reset behavior
    reg input_wr_en_r, input_rd_en_r;
    reg weight_wr_en_r, weight_rd_en_r;
    reg loader_bank_sel_r;
    reg array_bank_sel_r;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            input_wr_en_r <= 1'b0;
            input_rd_en_r <= 1'b0;
            weight_wr_en_r <= 1'b0;
            weight_rd_en_r <= 1'b0;
            loader_bank_sel_r <= 1'b0;  // Data Loader starts with Bank 0
            array_bank_sel_r <= 1'b1;   // Systolic Array starts with Bank 1
        end else begin
            input_wr_en_r <= input_wr_en;
            input_rd_en_r <= input_rd_en;
            weight_wr_en_r <= weight_wr_en;
            weight_rd_en_r <= weight_rd_en;
            loader_bank_sel_r <= loader_bank_sel;
            array_bank_sel_r <= array_bank_sel;
        end
    end
    
    // ========================================================================
    // Internal Signals for Bank Selection
    // ========================================================================
    
    // Input Buffer Bank 0 Signals
    wire input_bank0_csb0, input_bank0_web0;
    wire [ADDR_WIDTH-1:0] input_bank0_addr0;
    wire [SRAM_WIDTH-1:0] input_bank0_din0, input_bank0_dout0;
    wire [SRAM_WIDTH/8-1:0] input_bank0_wmask0;
    
    wire input_bank0_csb1;
    wire [ADDR_WIDTH-1:0] input_bank0_addr1;
    wire [SRAM_WIDTH-1:0] input_bank0_dout1;
    
    // Input Buffer Bank 1 Signals
    wire input_bank1_csb0, input_bank1_web0;
    wire [ADDR_WIDTH-1:0] input_bank1_addr0;
    wire [SRAM_WIDTH-1:0] input_bank1_din0, input_bank1_dout0;
    wire [SRAM_WIDTH/8-1:0] input_bank1_wmask0;
    
    wire input_bank1_csb1;
    wire [ADDR_WIDTH-1:0] input_bank1_addr1;
    wire [SRAM_WIDTH-1:0] input_bank1_dout1;
    
    // Weight/Accumulation Buffer Signals (Single Instance, No Ping-Pong)
    wire weight_csb0, weight_web0;
    wire [ADDR_WIDTH-1:0] weight_addr0;
    wire [SRAM_WIDTH-1:0] weight_din0, weight_dout0;
    wire [SRAM_WIDTH/8-1:0] weight_wmask0;
    
    wire weight_csb1;
    wire [ADDR_WIDTH-1:0] weight_addr1;
    wire [SRAM_WIDTH-1:0] weight_dout1;
    
    // ========================================================================
    // Bank Selection Logic for Input Buffers (Ping-Pong)
    // ========================================================================
    // Independent control allows Data Loader and Systolic Array to access different banks
    // 
    // Typical operation:
    //   loader_bank_sel=0, array_bank_sel=1: Loader writes Bank0, Array reads Bank1
    //   loader_bank_sel=1, array_bank_sel=0: Loader writes Bank1, Array reads Bank0
    
    // ========================================================================
    // Bank 0 Control
    // ========================================================================
    // Port 0: Write port - controlled by Data Loader
    assign input_bank0_csb0 = loader_bank_sel_r ? 1'b1 : ~input_wr_en_r;  // Active when loader selects Bank0
    assign input_bank0_web0 = 1'b0;  // Port 0 is always in write mode
    assign input_bank0_addr0 = loader_bank_sel_r ? {ADDR_WIDTH{1'b0}} : input_wr_addr;
    assign input_bank0_din0 = loader_bank_sel_r ? {SRAM_WIDTH{1'b0}} : input_wr_data;
    assign input_bank0_wmask0 = loader_bank_sel_r ? {(SRAM_WIDTH/8){1'b0}} : input_wr_mask;
    
    // Port 1: Read port - controlled by Systolic Array
    assign input_bank0_csb1 = array_bank_sel_r ? 1'b1 : ~input_rd_en_r;  // Active when array selects Bank0
    assign input_bank0_addr1 = array_bank_sel_r ? {ADDR_WIDTH{1'b0}} : input_rd_addr;
    
    // ========================================================================
    // Bank 1 Control
    // ========================================================================
    // Port 0: Write port - controlled by Data Loader
    assign input_bank1_csb0 = loader_bank_sel_r ? ~input_wr_en_r : 1'b1;  // Active when loader selects Bank1
    assign input_bank1_web0 = 1'b0;  // Port 0 is always in write mode
    assign input_bank1_addr0 = loader_bank_sel_r ? input_wr_addr : {ADDR_WIDTH{1'b0}};
    assign input_bank1_din0 = loader_bank_sel_r ? input_wr_data : {SRAM_WIDTH{1'b0}};
    assign input_bank1_wmask0 = loader_bank_sel_r ? input_wr_mask : {(SRAM_WIDTH/8){1'b0}};
    
    // Port 1: Read port - controlled by Systolic Array
    assign input_bank1_csb1 = array_bank_sel_r ? ~input_rd_en_r : 1'b1;  // Active when array selects Bank1
    assign input_bank1_addr1 = array_bank_sel_r ? input_rd_addr : {ADDR_WIDTH{1'b0}};
    
    // ========================================================================
    // Output Mux - Select read data based on Systolic Array's bank selection
    // ========================================================================
    assign input_rd_data = array_bank_sel_r ? input_bank1_dout1 : input_bank0_dout1;
    
    // ========================================================================
    // Weight/Accumulation Buffer Control (No Ping-Pong)
    // ========================================================================
    // Port 0: Write/Read (R/W port)
    // Port 1: Read-only (for simultaneous access if needed)
    
    assign weight_csb0 = ~(weight_wr_en_r | weight_rd_en_r);
    assign weight_web0 = weight_wr_en_r ? 1'b0 : 1'b1;  // 0=Write, 1=Read
    assign weight_addr0 = weight_wr_en_r ? weight_wr_addr : weight_rd_addr;
    assign weight_din0 = weight_wr_data;
    assign weight_wmask0 = weight_wr_mask;
    
    // Port 1 disabled by default (can be used for parallel reads)
    assign weight_csb1 = 1'b1;
    assign weight_addr1 = {ADDR_WIDTH{1'b0}};
    
    // Output assignment
    assign weight_rd_data = weight_dout0;
    
    // ========================================================================
    // SRAM Macro Instantiations (Sky130 1rw1r configuration)
    // ========================================================================
    // Note: Using 32x256 configuration (1KB per bank)
    // For larger memories, instantiate multiple banks or use 32x512/32x1024
    
    // Input Buffer Bank 0
    sram_1rw1r_32_256_8_sky130 input_bank0_inst (
        // Port 0: Write (Data Loader)
        .clk0(clk),
        .csb0(input_bank0_csb0),
        .web0(input_bank0_web0),
        .wmask0(input_bank0_wmask0),
        .addr0(input_bank0_addr0),
        .din0(input_bank0_din0),
        .dout0(input_bank0_dout0),
        
        // Port 1: Read (Systolic Array)
        .clk1(clk),
        .csb1(input_bank0_csb1),
        .addr1(input_bank0_addr1),
        .dout1(input_bank0_dout1)
    );
    
    // Input Buffer Bank 1
    sram_1rw1r_32_256_8_sky130 input_bank1_inst (
        // Port 0: Write (Data Loader)
        .clk0(clk),
        .csb0(input_bank1_csb0),
        .web0(input_bank1_web0),
        .wmask0(input_bank1_wmask0),
        .addr0(input_bank1_addr0),
        .din0(input_bank1_din0),
        .dout0(input_bank1_dout0),
        
        // Port 1: Read (Systolic Array)
        .clk1(clk),
        .csb1(input_bank1_csb1),
        .addr1(input_bank1_addr1),
        .dout1(input_bank1_dout1)
    );
    
    // Weight/Accumulation Buffer (Single Bank)
    sram_1rw1r_32_256_8_sky130 weight_accum_inst (
        // Port 0: R/W
        .clk0(clk),
        .csb0(weight_csb0),
        .web0(weight_web0),
        .wmask0(weight_wmask0),
        .addr0(weight_addr0),
        .din0(weight_din0),
        .dout0(weight_dout0),
        
        // Port 1: Read-Only (disabled)
        .clk1(clk),
        .csb1(weight_csb1),
        .addr1(weight_addr1),
        .dout1(weight_dout1)
    );

endmodule