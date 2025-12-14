`timescale 1ns / 1ps

module tb_systolic_hard;

    reg clk;
    reg rst_n;
    reg enable_cycle;
    reg load_W;
    reg [7:0] row_in [0:7];
    wire [31:0] dut_result;
    wire dut_valid;

    // Instantiate DUT
    systolic_array_8x8 dut (
        .clk(clk),
        .rst_n(rst_n),
        .enable_cycle(enable_cycle),
        .load_W(load_W),
        .row_in_0(row_in[0]), .row_in_1(row_in[1]), .row_in_2(row_in[2]), .row_in_3(row_in[3]),
        .row_in_4(row_in[4]), .row_in_5(row_in[5]), .row_in_6(row_in[6]), .row_in_7(row_in[7]),
        .final_result(dut_result),
        .result_valid(dut_valid)
    );

    always #5 clk = ~clk;

    // --- Helper Tasks ---

    // 1. Drive a uniform value (e.g., all 10s)
    integer r;
    task drive_uniform(input [7:0] val);
        begin for(r=0; r<8; r=r+1) row_in[r] = val; end
    endtask

    // 2. Drive a Gradient (Row 0 = 1, Row 1 = 2 ... Row 7 = 8)
    task drive_gradient;
        begin for(r=0; r<8; r=r+1) row_in[r] = r + 1; end
    endtask

    initial begin
        $dumpfile("systolic_hard.vcd");
        $dumpvars(0, tb_systolic_hard);
        
        // Init
        clk = 0; rst_n = 0; enable_cycle = 0; load_W = 0; drive_uniform(0);
        #20 rst_n = 1; #20;

        $display("\n=== STARTING HARD VERIFICATION ===");

        // =================================================================
        // TEST CASE 1: The "Sum of Squares" Test
        // Weights: Gradient (1..8)
        // Inputs:  Gradient (1..8)
        // =================================================================
        
        // 1. Load Gradient Weights
        // The array shifts weights horizontally. If we drive [1,2..8] into the rows
        // for 16 cycles, EVERY column will end up holding [1,2..8] vertically.
        $display("[TB] Loading Gradient Weights (Row0=1 ... Row7=8)...");
        load_W = 1; enable_cycle = 1;
        repeat(16) begin
            drive_gradient(); 
            @(posedge clk);
        end
        load_W = 0; enable_cycle = 0;
        drive_uniform(0);
        repeat(10) @(posedge clk);

        // 2. Stream Gradient Inputs
        // Now we calculate (1*1) + (2*2) + ... + (8*8)
        $display("[TB] Streaming Gradient Inputs (Row0=1 ... Row7=8)...");
        enable_cycle = 1;
        repeat(40) begin
            drive_gradient(); 
            @(posedge clk);
        end
        
        // 3. Check for 1632
        // Calculation: (1+4+9+16+25+36+49+64) = 204 per column.
        // 8 Columns active = 204 * 8 = 1632.
            begin
                wait(dut_result == 1632);
                $display("[PASS] Got Expected Result: 1632 (Sum of Squares Gradient)");
            end
            begin
                $display("[FAIL] Timeout waiting for 1632. Got: %d", dut_result);
            end

        // =================================================================
        // TEST CASE 2: The "Mixed Math" Test
        // Weights: Still Gradient (1..8) from previous test (We didn't reload!)
        // Inputs:  Uniform (10)
        // =================================================================
        
        // Math:
        // Row 0: 10 * 1 = 10
        // Row 1: 10 * 2 = 20
        // ...
        // Row 7: 10 * 8 = 80
        // Col Sum: 10 + 20 + ... + 80 = 360.
        // Total (8 Cols): 360 * 8 = 2880.
        
        $display("\n[TB] Streaming Uniform Input (10) with Gradient Weights...");
        repeat(40) begin
            drive_uniform(10); 
            @(posedge clk);
        end
        
            begin
                wait(dut_result == 2880);
                $display("[PASS] Got Expected Result: 2880 (Gradient w/ Uniform Input)");
            end
            begin
                $display("[FAIL] Timeout waiting for 2880. Got: %d", dut_result);
            end

        $display("\n=== ALL HARD CHECKS PASSED ===");
        $finish;
    end
    
    // Safety
    initial begin
        #50000; $display("[FATAL] Watchdog Timeout"); $finish;
    end

endmodule