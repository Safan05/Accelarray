// PE_MAC_WS_PIPELINED_CG.v - Corrected for Psum Synchronization
// Now implements the required 1-cycle register on the Psum input path
// to match the latency of the Multiplication stage.

module PE (
    // Global Signals
    input wire clk,
    input wire rst_n,
    
    // Control and Enable Signals
    input wire enable_cycle,         // Controls Clock Gating (Active when PE should compute)
    input wire reset_psum,           // Resets the accumulator (Start of Pass 1)
    input wire load_W,               // Triggers loading W_in into W_local_reg
    input wire load_psum_from_mem,   // Selects Psum source for K > 8 tiling
    
    // Data Flow Inputs
    input wire [7:0] W_in,           // 8-bit Weight/Kernel input
    input wire [7:0] pixel_in,       // 8-bit Input Pixel from West PE
    input wire [31:0] psum_in,       // 32-bit Partial Sum from North PE
    input wire [31:0] psum_mem_in,    // 32-bit Psum from SRAM Buffer (K>8 tiling)
    
    // Data Flow Outputs
    output reg [7:0] pixel_out,      // Pipelined Pixel to East PE
    output reg [31:0] psum_out       // Pipelined Partial Sum to South PE
);
    // Internal Registers and Wires
    reg [7:0] W_local_reg;           // Stationary Weight Register
    reg [31:0] psum_reg;             // Final Accumulator Register (Stage 2 Output)
    
    // --- PIPELINE STAGE 1: Multiplication ---
    wire [15:0] product_combinational; // Combinational multiplier output
    reg [15:0] product_reg;           // Pipelining Register (Stage 1 Output)
    
    // --- Psum Synchronization Register (NEW) ---
    // This register ensures psum_in arrives at the adder one cycle later, 
    // synchronously with product_reg.
    reg [31:0] psum_in_reg; 
    
    // --- Accumulation Wires ---
    wire [31:0] base_psum;
    
    // --- 2. WEIGHT STATIONARY REGISTRATION ---
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) 
            W_local_reg <= 8'h00;
        else if (load_W) 
            W_local_reg <= W_in;
    end

    // -----------------------------------------------------------------
    // --- STAGE 1: MULTIPLICATION & INPUT PIPELINING ---
    // -----------------------------------------------------------------

    // Combinational Multiplier
    assign product_combinational = pixel_in * W_local_reg;

    // Register Pipelining (1-Cycle Delay on both paths)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            product_reg <= 16'h0000;
            psum_in_reg <= 32'h00000000; // NEW: Synchronize psum_in
        end else if (enable_cycle) begin 
            product_reg <= product_combinational;
            psum_in_reg <= psum_in;      // NEW: Latch psum_in
        end
    end

    // -----------------------------------------------------------------
    // --- STAGE 2: ACCUMULATION (MAC) ---
    // -----------------------------------------------------------------
    
    // Combinational logic for Psum base selection (K>8 support)
    // IMPORTANT: Now uses the registered psum_in_reg for synchronization.
    assign base_psum = load_psum_from_mem ? psum_mem_in : psum_in_reg;
    
    // Accumulator Register (Sequential Logic - Clock Gated)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            psum_reg <= 32'h00000000;
        end else if (reset_psum) begin 
            psum_reg <= 32'h00000000;
        end else if (enable_cycle) begin 
            // Correct accumulation: [Buffered Psum] + [Buffered Product]
            psum_reg <= base_psum + {{16{1'b0}}, product_reg};
        end
    end

    // --- DATA FLOW OUTPUTS (Pipelining) ---
    
    // Output Pixel (Forward to East) - 1-cycle delay
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) 
            pixel_out <= 8'h00;
        else if (enable_cycle)
            pixel_out <= pixel_in;
    end
    
    // Output Partial Sum (Forward to South) - 2-cycle latency output
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) 
            psum_out <= 32'h00000000;
        else if (enable_cycle) 
            psum_out <= psum_reg; 
    end

endmodule