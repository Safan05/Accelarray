// SystolicArray_TB.v
// Testbench for the 8x8 Systolic Array using a 64x64 input image and 5x5 kernel.

`timescale 1ns / 1ps

module SystolicArray_TB;

    // --- 1. Parameters and Constants ---
    parameter CLK_PERIOD = 10;          // 10ns clock period (100 MHz)
    parameter ARRAY_SIZE = 8;
    parameter KERNEL_SIZE = 5;
    parameter P_WIDTH = 32;
    
    // Calculate 12x12 Input Tile Stream Cycles (ArraySize + K - 1)
    parameter STREAM_CYCLES = ARRAY_SIZE + KERNEL_SIZE - 1; // = 12 cycles

    // --- 2. Testbench Signals (Inputs to UUT) ---
    reg clk;
    reg rst_n;
    
    // Control Signals
    reg enable_cycle;
    reg reset_psum;
    reg load_W;
    reg load_psum_from_mem; // Should remain 0 since K=5 (1 pass)
    
    // Data Interfaces (using standard verilog arrays for convenience)
    reg [7:0] I_stream_in [0:ARRAY_SIZE-1];     // 8 parallel pixel inputs
    reg [7:0] W_load_in [0:ARRAY_SIZE-1];       // 8 parallel weight load inputs
    reg [P_WIDTH-1:0] Psum_mem_in_stream [0:ARRAY_SIZE*ARRAY_SIZE-1]; // 64 Psums from memory (unused for K=5)

    // --- 3. UUT Outputs ---
    wire [P_WIDTH-1:0] Psum_out_stream [0:ARRAY_SIZE*ARRAY_SIZE-1]; // 64 final Psums

    // --- 4. Internal Data (Simulation Memory/AGU) ---
    // Memory to hold the simple 5x5 kernel and input pixels
    reg [7:0] KERNEL [0:KERNEL_SIZE-1] [0:KERNEL_SIZE-1];
    reg [7:0] INPUT_TILE [0:STREAM_CYCLES-1] [0:ARRAY_SIZE-1]; // 12x8 pixel values

    // --- 5. Instantiate the Unit Under Test (UUT) ---
    SystolicArray UUT (
        .clk(clk),
        .rst_n(rst_n),
        
        .enable_cycle(enable_cycle),
        .reset_psum(reset_psum),
        .load_W(load_W),
        .load_psum_from_mem(load_psum_from_mem),
        
        // Unpack I/O arrays to connect to module ports
        .I_stream_in({I_stream_in[7], I_stream_in[6], I_stream_in[5], I_stream_in[4], I_stream_in[3], I_stream_in[2], I_stream_in[1], I_stream_in[0]}),
        .W_load_in({W_load_in[7], W_load_in[6], W_load_in[5], W_load_in[4], W_load_in[3], W_load_in[2], W_load_in[1], W_load_in[0]}),
        .Psum_mem_in_stream({Psum_mem_in_stream[63:0]}),
        
        .Psum_out_stream({Psum_out_stream[63:0]})
    );

    // --- 6. Clock Generation ---
    initial begin
        clk = 0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    // --- 7. Task for Streaming Input Tile ---
    task stream_input_tile;
        input integer cycles;
        input reg [7:0] tile_data [0:11][0:7]; // 12x8 block of input data
        begin
            enable_cycle = 1;
            for (integer t = 0; t < cycles; t = t + 1) begin
                @(posedge clk);
                // Stream 8 pixels (1 row of the input tile) in parallel
                for (integer c = 0; c < ARRAY_SIZE; c = c + 1) begin
                    I_stream_in[c] = tile_data[t][c];
                end
            end
            enable_cycle = 0;
        end
    endtask

    // --- 8. Main Test Sequence ---
    initial begin
        $dumpfile("systolic_array.vcd");
        $dumpvars(0, SystolicArray_TB);

        // --- Initialization ---
        rst_n = 0;
        enable_cycle = 0;
        reset_psum = 0;
        load_W = 0;
        load_psum_from_mem = 0;
        
        // Define a simple 5x5 kernel (all ones for easy verification)
        for (integer kx = 0; kx < KERNEL_SIZE; kx = kx + 1) begin
            for (integer ky = 0; ky < KERNEL_SIZE; ky = ky + 1) begin
                KERNEL[kx][ky] = 8'd1; 
            end
        end
        // Define a simple 12x8 input tile (all twos for easy verification)
        for (integer r = 0; r < STREAM_CYCLES; r = r + 1) begin
            for (integer c = 0; c < ARRAY_SIZE; c = c + 1) begin
                INPUT_TILE[r][c] = 8'd2; 
            end
        end

        // --- A. Asynchronous Reset ---
        # (CLK_PERIOD / 2);
        rst_n = 1; 
        $display("T=%0t: RESET released.", $time);
        
        // --- B. Load Weights (Cycle 1: Load) ---
        // Load the 8x8 corner of the 5x5 kernel (which is all ones).
        @(posedge clk);
        load_W = 1;
        for (integer i = 0; i < ARRAY_SIZE; i = i + 1) begin
            // Since K=5, we fill W_load_in with K[i][j] data. 
            // Simplified: Load first 8 columns of KRNL[i]
            W_load_in[i] = KERNEL[i][0]; // Assuming W_in is the weight for the first PE in the row
        end
        
        @(posedge clk); // Clock cycle for the load to complete
        load_W = 0;
        $display("T=%0t: Weights Loaded (W=1).", $time);

        // --- C. Reset Accumulator (Cycle 2: Reset Psum) ---
        // Note: The PE array is reset at the start of the MAC computation.
        @(posedge clk);
        reset_psum = 1;
        @(posedge clk); // Clock cycle for the reset to complete
        reset_psum = 0;
        $display("T=%0t: Accumulators Reset.", $time);

        // --- D. COMPUTE: Stream Input Tile (K=5, 1 Pass) ---
        // Stream 12 clock cycles of 8 parallel input pixels (all 2s).
        $display("T=%0t: START Streaming Input Tile (12 cycles).", $time);
        stream_input_tile(STREAM_CYCLES, INPUT_TILE); // Runs for 12 cycles

        // --- E. DRAIN: Wait for Result Latency ---
        // Total Latency = 8 (rows) + 8 (cols) + 2 (PE latency) approx. 18 cycles.
        // We wait past the 12 stream cycles to see the results emerge.
        # (20 * CLK_PERIOD); 
        
        // Expected accumulation for PE[i][j] (K=5x5):
        // 5x5 = 25 MACs contribute to each output pixel.
        // Each MAC is W * A = 1 * 2 = 2.
        // Expected Psum = 25 * 2 = 50.
        
        $display("T=%0t: Results Draining...", $time);
        
        // Wait for one more clock edge to capture the final results.
        @(posedge clk);
        
        $display("T=%0t: Checking Output Block 1 (PE[7][7] result).", $time);
        // The result of PE[7][7] (Psum_out_stream[63]) should be 50 if the flow is correct.
        if (Psum_out_stream[63] == 32'd50) begin
            $display("--- VERIFICATION SUCCESS: Output Psum[63] = 50. ---");
        end else begin
            $display("--- VERIFICATION FAILURE: Expected 50, got %d. ---", Psum_out_stream[63]);
        end
        
        // --- End Test ---
        #100;
        $finish;
    end
    
endmodule