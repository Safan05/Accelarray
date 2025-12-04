// pe_tb.v
// Unit verification testbench for the 2-stage pipelined, clock-gated PE module.
// PE Module: PE_MAC_WS_PIPELINED_CG

`timescale 1ns / 1ps

module pe_tb;

    // --- 1. Testbench Signals (PE Inputs) ---
    reg clk;
    reg rst_n;
    
    reg enable_cycle;
    reg reset_psum;
    reg load_W;
    reg load_psum_from_mem;
    
    reg [7:0] W_in;
    reg [7:0] pixel_in;
    reg [31:0] psum_in;
    reg [31:0] psum_mem_in;
    
    // --- 2. PE Outputs ---
    wire [7:0] pixel_out;
    wire [31:0] psum_out;
    
    // --- 3. Instantiate the Unit Under Test (UUT) ---
    PE_MAC_WS_PIPELINED_CG UUT (
        .clk(clk),
        .rst_n(rst_n),
        .enable_cycle(enable_cycle),
        .reset_psum(reset_psum),
        .load_W(load_W),
        .load_psum_from_mem(load_psum_from_mem),
        .W_in(W_in),
        .pixel_in(pixel_in),
        .psum_in(psum_in),
        .psum_mem_in(psum_mem_in),
        .pixel_out(pixel_out),
        .psum_out(psum_out)
    );

    // --- 4. Clock Generation ---
    parameter CLK_PERIOD = 10; // 10ns clock period (100 MHz)
    initial begin
        clk = 0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    // --- 5. Main Test Sequence ---
    initial begin
        $dumpfile("pe_tb.vcd");
        $dumpvars(0, pe_tb);
        
        // Initialize control signals
        rst_n = 0;
        enable_cycle = 0;
        reset_psum = 0;
        load_W = 0;
        load_psum_from_mem = 0;
        
        // Initialize data
        W_in = 8'd0;
        pixel_in = 8'd0;
        psum_in = 32'd0;
        psum_mem_in = 32'd0;

        $display("-----------------------------------------------------");
        $display("T: %0t - START TESTBENCH", $time);
        
        // ---------------------------------------------
        // A. RESET (t=0 to t=10)
        // ---------------------------------------------
        #10 rst_n = 1; // De-assert reset
        $display("T: %0t - RESET released.", $time);
        
        // ---------------------------------------------
        // B. PHASE 1: WEIGHT LOADING (t=10 to t=30)
        // Goal: Load W=10 into W_local_reg
        // ---------------------------------------------
        load_W = 1;
        W_in = 8'd10;
        enable_cycle = 1; // Enable clock for the load operation

        #CLK_PERIOD; // t=20: Load W=10
        load_W = 0;
        enable_cycle = 0;
        $display("T: %0t - Weight Loaded (W=10).", $time);
        
        // ---------------------------------------------
        // C. PHASE 2: BASIC MAC ACCUMULATION (t=30 to t=80)
        // W_local_reg is 10. psum_in starts at 0.
        // Expected product: 5*10 = 50.
        // Expected latency is 2 cycles (Stage 1: Mul, Stage 2: Add/Reg).
        // ---------------------------------------------
        
        enable_cycle = 1; // Enable clock for computation
        
        // Cycle 1: Input A=5, P_in=0
        pixel_in = 8'd5;
        psum_in = 32'd0; 
        #CLK_PERIOD; // t=40
        $display("T: %0t - Input A=5, P_in=0. Product=50 registered.", $time);
        
        // Cycle 2: Input A=3, P_in=100 (Arbitrary), Accumulation of first term occurs
        // psum_out expected: 0 + 50 = 50. (2-cycle latency)
        pixel_in = 8'd3;
        psum_in = 32'd100;
        #CLK_PERIOD; // t=50
        $display("T: %0t - A=3. P_out=50 (Expected). New Product=30 registered.", $time);
        
        // Cycle 3: Input A=0, P_in=200 (Arbitrary), Accumulation of second term occurs
        // psum_out expected: 100 + 30 = 130. (Note: P_in is now the output from a previous PE)
        pixel_in = 8'd0;
        psum_in = 32'd200;
        #CLK_PERIOD; // t=60
        $display("T: %0t - A=0. P_out=130 (Expected). Product=0 registered.", $time);
        
        // ---------------------------------------------
        // D. TEST CLOCK GATING (t=80 to t=100)
        // Accumulator should stall at 200 (current psum_in).
        // ---------------------------------------------
        enable_cycle = 0;
        pixel_in = 8'd8; // New A=8
        psum_in = 32'd300; // New P_in=300
        
        #CLK_PERIOD; // t=70: Data is valid, but no clock edge for internal registers
        $display("T: %0t - CG Test: enable_cycle=0. Registers should stall.", $time);
        
        #CLK_PERIOD; // t=80
        $display("T: %0t - P_out should be the same (130).", $time);
        
        // ---------------------------------------------
        // E. ACCUMULATOR RESET (t=90 to t=110)
        // ---------------------------------------------
        reset_psum = 1;
        enable_cycle = 1; // Must re-enable clock for reset to take effect

        #CLK_PERIOD; // t=90: Accumulator should reset to 0
        reset_psum = 0;
        
        // Check if accumulation restarts correctly
        pixel_in = 8'd2;
        psum_in = 32'd10;

        #CLK_PERIOD; // t=100: Input A=2, P_in=10. Product=20 registered. P_out still 0 due to reset.
        $display("T: %0t - Reset executed. P_out should be 0.", $time);

        // Cycle 2 after reset:
        // P_out expected: 10 + 20 = 30.
        pixel_in = 8'd4;
        psum_in = 32'd40;
        #CLK_PERIOD; // t=110
        $display("T: %0t - Accumulation restarted. P_out=30 (Expected).", $time);
        
        // ---------------------------------------------
        // F. K > 8 TILING SUPPORT (t=120 to t=150)
        // Load the base Psum for a new accumulation pass (K>8 tiling).
        // Expected P_out should be Psum_mem_in + product.
        // ---------------------------------------------
        
        // Cycle 1: Set Psum base from memory
        load_psum_from_mem = 1;
        psum_mem_in = 32'hFFFF0000; // A large non-zero base
        pixel_in = 8'd1;
        psum_in = 32'd5; // Ignored due to load_psum_from_mem=1

        #CLK_PERIOD; // t=120: Product=10 registered.

        // Cycle 2: Accumulation uses Psum_mem_in.
        // P_out expected: FFFF0000 + 10 = FFFF000A.
        load_psum_from_mem = 0; // Back to Psum_in mode for next PE
        pixel_in = 8'd0;
        #CLK_PERIOD; // t=130
        $display("T: %0t - K>8 Tiling Test: P_out=0x%h (Expected: 0xFFFF000A).", $time, psum_out);

        #10;
        $display("T: %0t - END TESTBENCH", $time);
        $finish;
    end
    
endmodule