`timescale 1ns / 1ps

// CONV_SYSTOLIC_8x8_WS_TB.v (Test_TB.v)
// Testbench for the 8x8 Weight Stationary Systolic Array - Adjusted Timing

module CONV_SYSTOLIC_8x8_WS_TB;

    // --- 1. TB Signals (Inputs to UUT - using packed vectors) ---
    reg clk;
    reg rst_n;
    
    // Control
    reg [7:0] W_load_PE_idx;       
    reg load_W_global;             
    reg enable_cycle;              
    reg reset_psum;                
    reg load_psum_from_mem;        

    // Inputs
    reg [63:0] pixel_row_in_vec;    // 8 rows * 8 bits
    reg [255:0] psum_col_in_vec;   // 8 cols * 32 bits
    reg [7:0] W_in_data;            
    reg [31:0] psum_mem_in_data;    

    // --- 2. TB Signals (Outputs from UUT - using packed vectors) ---
    wire [63:0] pixel_row_out_vec; 
    wire [255:0] psum_col_out_vec;  

    // Internal Verification Variables
    integer i, j;
    integer errors = 0;
    
    // Golden Output: 1 + 4 + 7 = 12 (32-bit value)
    reg [31:0] golden_output = 32'd12; 
    
    // --- 3. Instantiate Unit Under Test (UUT) ---
    CONV_SYSTOLIC_8x8_WS UUT (
        .clk(clk),
        .rst_n(rst_n),
        .W_load_PE_idx(W_load_PE_idx),
        .load_W_global(load_W_global),
        .enable_cycle(enable_cycle),
        .reset_psum(reset_psum),
        .load_psum_from_mem(load_psum_from_mem),
        .pixel_row_in_vec(pixel_row_in_vec),
        .psum_col_in_vec(psum_col_in_vec),
        .W_in_data(W_in_data),
        .psum_mem_in_data(psum_mem_in_data),
        .pixel_row_out_vec(pixel_row_out_vec),
        .psum_col_out_vec(psum_col_out_vec)
    );
    
    // --- 4. Clock Generation ---
    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 10 ns clock period (100 MHz)
    end

    // --- 5. Main Test Sequence ---
    initial begin
        $dumpfile("CONV_SYSTOLIC_8x8_WS.vcd");
        $dumpvars(0, CONV_SYSTOLIC_8x8_WS_TB);
        
        // 5a. Initial Reset and Setup
        $display("--- PHASE 1: Reset & Setup ---");
        rst_n = 0;
        load_W_global = 0;
        enable_cycle = 0;
        reset_psum = 0;
        load_psum_from_mem = 0;
        pixel_row_in_vec = 64'h0;
        psum_col_in_vec = 256'h0;
        W_in_data = 8'h00;
        
        #10;
        rst_n = 1;
        #10;

        // 5b. WEIGHT LOADING PHASE (3x3 Kernel, all weights = 1)
        $display("--- PHASE 2: Weight Loading (3x3 Kernel) ---");
        load_W_global = 1;
        W_in_data = 8'd1;
        
        // Load weights into PE(0,0) to PE(2,2) - 9 cycles
        for (j = 0; j < 3; j = j + 1) begin
            for (i = 0; i < 3; i = i + 1) begin
                W_load_PE_idx = j * 8 + i; 
                #10; 
            end
        end
        
        load_W_global = 0; // Stop loading
        W_in_data = 8'h00;
        #10;

        // 5c. COMPUTATION PHASE (Skewed 3x3 Input Tile)
        $display("--- PHASE 3: Data Computation (3x3 Input Tile) ---");
        enable_cycle = 1; 
        reset_psum = 1;   // Reset Psum register for the first cycle
        
        // Cycle 1 (T=0): Input 1 to Row 0
        pixel_row_in_vec[7:0] = 8'd1;
        #10;
        reset_psum = 0; 
        
        // Cycle 2 (T=1): Input 4 to Row 0
        pixel_row_in_vec[7:0] = 8'd4;
        #10;
        
        // Cycle 3 (T=2): Input 7 to Row 0
        pixel_row_in_vec[7:0] = 8'd7;
        #10;
        
        // Cycle 4 (T=3): End of input (Feed 0)
        pixel_row_in_vec[7:0] = 8'h00;
        #10;
        
        // **CRITICAL TIMING ADJUSTMENT**
        // Expected result at PE(7,0) output is Cycle 18 (T=17).
        // T=3 is the last computation cycle. We need to wait 14 more cycles.
        // Wait 14 cycles + 1 extra cycle for margin. (Total 15 cycles wait after T=3)
        for (i = 0; i < 15; i = i + 1) begin
             #10;
        end
        
        // 5d. RESULT CHECKING PHASE
        $display("--- PHASE 4: Result Checking ---");
        enable_cycle = 0; // Halt computation

        // Check the result from the bottom-most PE of the first column: PE(7,0)
        // This corresponds to psum_col_out_vec[255:224] (Slice 7 * 32 bits)
        if (psum_col_out_vec[255:224] == golden_output) begin
            $display("--- FINAL RESULT CHECK PASSED: PE(7,0) Path Output = %0d ---", psum_col_out_vec[255:224]);
        end else begin
            $display("!!! FATAL ERROR: Final result mismatch. Got %0d, Expected %0d.", psum_col_out_vec[255:224], golden_output);
            errors = errors + 1;
        end

        // Conclude Simulation
        #20;
        if (errors == 0) begin
            $display("--- SIMULATION SUCCESSFUL: %0d Errors ---", errors);
        end else begin
            $display("--- SIMULATION FAILED: %0d Errors Detected ---", errors);
        end
        $finish;
    end
endmodule