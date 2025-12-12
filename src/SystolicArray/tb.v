`timescale 1ns / 1ps

module systolic_array_tb_logging;

    // 1. CONFIGURATION
    parameter ROWS = 8;
    parameter COLS = 8;
    parameter DATA_WIDTH = 8;
    parameter SUM_WIDTH = 32;
    parameter CLK_PERIOD = 10; 

    // Signals
    reg clk, rst_n, enable_cycle, load_W, output_group_sel;
    reg [(ROWS * DATA_WIDTH) - 1 : 0] pixel_in_bus;
    reg [(COLS * SUM_WIDTH) - 1 : 0] psum_in_bus; 
    wire [127:0] psum_out_bus; 

    reg [DATA_WIDTH-1:0] debug_pixel_inputs [0:ROWS-1];
    reg [SUM_WIDTH-1:0]  debug_psum_inputs  [0:COLS-1];
    
    // --- Logging Variables ---
    integer test_case_num;
    integer total_checks;
    integer checks_passed;
    integer checks_failed;
    // -------------------------

    // Instantiation
    systolic_array #(
        .ROWS(ROWS), .COLS(COLS), .DATA_WIDTH(DATA_WIDTH), .SUM_WIDTH(SUM_WIDTH)
    ) UUT (
        .clk(clk), .rst_n(rst_n), 
        .enable_cycle(enable_cycle), .load_W(load_W), .output_group_sel(output_group_sel),
        .pixel_in_bus(pixel_in_bus), .psum_in_bus(psum_in_bus), .psum_out_bus(psum_out_bus)
    );

    // Packing Logic
    integer r_pack, c_pack;
    always @(*) begin
        for (r_pack = 0; r_pack < ROWS; r_pack = r_pack + 1) 
            pixel_in_bus[(r_pack*8) +: 8] = debug_pixel_inputs[r_pack];
        for (c_pack = 0; c_pack < COLS; c_pack = c_pack + 1) 
            psum_in_bus[(c_pack*32) +: 32] = debug_psum_inputs[c_pack];
    end

    // Clock
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    // Helper Task: Clear Inputs
    task clear_inputs;
        integer i;
        begin
            for (i=0; i<ROWS; i=i+1) debug_pixel_inputs[i] = 0;
            for (i=0; i<COLS; i=i+1) debug_psum_inputs[i] = 0; // Also clear psum_in
        end
    endtask
    
    // =========================================================
    // NEW TASK: Structured Result Checking
    // =========================================================
    task check_result;
        input integer col_index;
        input [SUM_WIDTH-1:0] actual_value;
        input [SUM_WIDTH-1:0] expected_value;
        input string test_name;
        input integer time_stamp;
        
        reg result;
        begin
            total_checks = total_checks + 1;
            
            if (actual_value == expected_value) begin
                checks_passed = checks_passed + 1;
                result = 1'b1;
                $display("\t[PASS] T%0d.%s (Col %0d): Got %0d (0x%h) at T=%0t", 
                         test_case_num, test_name, col_index, actual_value, actual_value, time_stamp);
            end else begin
                checks_failed = checks_failed + 1;
                result = 1'b0;
                $error("\t[FAIL] T%0d.%s (Col %0d): Expected %0d (0x%h), Got %0d (0x%h) at T=%0t", 
                        test_case_num, test_name, col_index, expected_value, expected_value, 
                        actual_value, actual_value, time_stamp);
            end
        end
    endtask

    // =========================================================
    // MAIN TEST SEQUENCE
    // =========================================================
    integer r, c, i, k;
    reg [31:0] val; 
    
    initial begin
        $dumpfile("systolic_array_log.vcd");
        $dumpvars(0, systolic_array_tb_logging);
        
        // Initialize Logging
        test_case_num = 0;
        total_checks = 0;
        checks_passed = 0;
        checks_failed = 0;

        // Init Signals
        rst_n = 0; enable_cycle = 0; load_W = 0; output_group_sel = 0;
        clear_inputs();

        $display("\n==============================================");
        $display("STARTING SYSTOLIC ARRAY TESTBENCH");
        $display("==============================================");
        #20 rst_n = 1; #5;

        // =====================================================
        // CASE 1: SMALL KERNEL (4x4)
        // W=2 for rows 0-3, W=0 for rows 4-7. A=5. Psum_in=0.
        // Expected Sum = (5 * 2) * 4 rows = 40 (0x28).
        // =====================================================
        test_case_num = 1;
        $display("\n[TEST %0d] CASE 1: SMALL KERNEL 4x4, Expected=40", test_case_num);
        
        // 1. Load Weights
        load_W = 1; enable_cycle = 1;
        for (r=0; r<ROWS; r=r+1) begin
            if (r < 4) debug_pixel_inputs[r] = 8'd2; // W=2
            else debug_pixel_inputs[r] = 8'd0; // W=0
        end
        repeat (ROWS) @(posedge clk); 
        load_W = 0; 
        clear_inputs();
        #20;

        // 2. Compute (A=5)
        enable_cycle = 1;
        
        fork
            // THREAD A: Input Driver (Adjusted for 2-cycle skew per row)
            begin
                for (i=0; i<30; i=i+1) begin // Run for 30 cycles
                    @(posedge clk); #1;
                    for (r=0; r<ROWS; r=r+1) begin
                        if (i >= (r*2) && i < ((r*2)+1)) // Stream 5 for 1 cycle per row
                            debug_pixel_inputs[r] = 8'd5;
                        else 
                            debug_pixel_inputs[r] = 8'd0;
                    end
                end
                clear_inputs();
            end

            // THREAD B: Output Monitor (Wait for Latency + COLS cycles to check all)
            begin
                // The first result should appear at cycle (ROWS + 2) + column index 
                // Let's check when COL 7 result is stable
                
                // Wait for a few cycles to allow the first result to appear (Cycle 10 is first sum)
                // We will check at Cycle 25 to be safe (Latency + 15)
                repeat (25) @(posedge clk);
                
                $display("\n\t--- Running Output Check at T=%0t ---", $time);

                // Check Lower Half (Cols 0-3)
                output_group_sel = 0; @(posedge clk); #1;
                for (k=0; k<4; k=k+1) begin
                    val = psum_out_bus[(k*32)+:32];
                    check_result(k, val, 32'd40, "4x4_Lower", $time);
                end
                
                // Check Upper Half (Cols 4-7)
                output_group_sel = 1; @(posedge clk); #1;
                for (k=0; k<4; k=k+1) begin
                    val = psum_out_bus[(k*32)+:32];
                    check_result(k+4, val, 32'd0, "4x4_Upper", $time); // Should be 0 since W=0 for cols 4-7
                end
            end
        join

        // =====================================================
        // CASE 2: LARGE KERNEL (Tiling Verification)
        // W=2 for all. A=10. Psum_in = Base.
        // Expected Sum = (Base) + (10 * 2) * 8 rows = Base + 160.
        // =====================================================
        test_case_num = 2;
        $display("\n[TEST %0d] CASE 2: TILING, All W=2, A=10", test_case_num);
        
        // 1. Reset and Load Weights (All 2)
        enable_cycle = 0; rst_n = 0; #20; rst_n = 1; #5;
        load_W = 1; enable_cycle = 1;
        for (r=0; r<ROWS; r=r+1) debug_pixel_inputs[r] = 8'd2;
        repeat (ROWS) @(posedge clk); 
        load_W = 0;
        
        // 2. Setup Tiling Base Sums (1000, 2000, ...)
        for (c=0; c<COLS; c=c+1) debug_psum_inputs[c] = (c + 1) * 1000;
        
        // 3. Compute (A=10)
        enable_cycle = 1;
        
        fork
            // THREAD A: Input Driver 
            begin
                for (i=0; i<30; i=i+1) begin
                    @(posedge clk); #1;
                    for (r=0; r<ROWS; r=r+1) begin
                        if (i >= (r*2) && i < ((r*2)+1)) 
                            debug_pixel_inputs[r] = 8'd10;
                        else 
                            debug_pixel_inputs[r] = 8'd0;
                    end
                end
                clear_inputs();
            end

            // THREAD B: Output Monitor 
            begin
                repeat (25) @(posedge clk);
                
                $display("\n\t--- Running Output Check at T=%0t ---", $time);

                // Check Lower Half (Cols 0-3)
                output_group_sel = 0; @(posedge clk); #1;
                for (k=0; k<4; k=k+1) begin
                    val = psum_out_bus[(k*32)+:32];
                    check_result(k, val, (k+1)*1000 + 160, "8x8_Tiling_Lower", $time);
                end
                
                // Check Upper Half (Cols 4-7)
                output_group_sel = 1; @(posedge clk); #1;
                for (k=0; k<4; k=k+1) begin
                    val = psum_out_bus[(k*32)+:32];
                    // k+5 maps to columns 4, 5, 6, 7
                    check_result(k+4, val, (k+5)*1000 + 160, "8x8_Tiling_Upper", $time); 
                end
            end
        join
        
        // =====================================================
        // SUMMARY
        // =====================================================
        $display("\n\n==============================================");
        $display("TEST SUMMARY");
        $display("----------------------------------------------");
        $display("Total Checks Run: %0d", total_checks);
        $display("Checks Passed: %0d", checks_passed);
        $display("Checks FAILED: %0d", checks_failed);
        $display("==============================================");
        
        if (checks_failed > 0)
            $fatal(1, "Test FAILED due to one or more mismatched outputs.");
        else
            $finish;
    end

endmodule