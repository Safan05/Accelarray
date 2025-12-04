module   PE_MAC_WS_PIPELINED_CG_FINAL(
    // Global Signals
    input wire clk,
    input wire rst_n,
    
    // Control and Enable Signals
    input wire enable_cycle,        // Controls Clock Gating (Active when PE should compute)
    input wire reset_psum,          // Resets the accumulator (Start of Pass 1)
    input wire load_W,              // Triggers loading W_in into W_local_reg
    input wire load_psum_from_mem,  // Selects Psum source for K > 8 tiling
    
    // Data Flow Inputs
    input wire [7:0] W_in,          // 8-bit Weight/Kernel input
    input wire [7:0] pixel_in,
    input wire [31:0] psum_in,      // From North PE
    input wire [31:0] psum_mem_in,  // From SRAM Buffer (K>8)
    
    // Data Flow Outputs
    output reg [7:0] pixel_out,
    output reg [31:0] psum_out
);
    // Internal Registers and Wires
    reg [7:0] W_local_reg;          // Stationary Weight Register
    reg [31:0] psum_reg;            // Accumulator Register (Stage 2 Output)
    reg clk_enable;                 // Gated Clock Signal
    
    // --- PIPELINE STAGE 1: Multiplication ---
    wire [15:0] product_combinational; // Combinational multiplier output
    reg [15:0] product_reg;          // Pipelining Register (Stage 1 Output)
    
    // --- Accumulation Wires ---
    wire [31:0] base_psum;
    // Define the zero-extended product for safe addition (The ultimate fix)
    wire [31:0] product_extended = {16'b0, product_reg}; 

    // --- 1. CLOCK GATING CONTROL ---
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) clk_enable <= 1'b0;
        else clk_enable <= enable_cycle;
    end

    // --- 2. WEIGHT STATIONARY REGISTRATION ---
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) W_local_reg <= 8'd0;
        else if (load_W) W_local_reg <= W_in;
    end

    // -----------------------------------------------------------------
    // --- STAGE 1: MULTIPLICATION ---
    // -----------------------------------------------------------------

    // Combinational Multiplier
    assign product_combinational = pixel_in * W_local_reg;

    // Pipelining Register for Product (Clock Gated)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) product_reg <= 16'd0;
        else if (clk_enable) begin
            product_reg <= product_combinational;
        end
    end

    // -----------------------------------------------------------------
    // --- STAGE 2: ACCUMULATION (MAC) ---
    // -----------------------------------------------------------------
    
    // Combinational logic for Psum base selection (K>8 support)
    assign base_psum = load_psum_from_mem ? psum_mem_in : psum_in;
    
    // Accumulator Register (Sequential Logic - Clock Gated)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) psum_reg <= 32'd0;
        else if (reset_psum) psum_reg <= 32'd0;
        else if (clk_enable) begin 
            // Use the safe, explicitly zero-extended product
            psum_reg <= base_psum + product_extended;
        end
    end

    // --- DATA FLOW OUTPUTS ---
    
    // Output Pixel (Forward to East)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) pixel_out <= 8'd0;
        else if (clk_enable) pixel_out <= pixel_in;
    end
    
    // Output Partial Sum (Forward to South)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) psum_out <= 32'd0;
        else psum_out <= psum_reg; 
    end

endmodule