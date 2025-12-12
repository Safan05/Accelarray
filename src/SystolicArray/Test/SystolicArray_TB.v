`timescale 1ns / 1ps

module tb_Systolic_Tiling;

    // Signals
    reg clk, rst_n;
    reg enable_cycle, load_W, accumulate_mode, capture_en;
    reg [63:0] row_inputs;
    reg [2:0] col_sel;
    wire [31:0] sram_data_out;

    // Instantiation
    Systolic_Array_Top uut (
        .clk(clk), .rst_n(rst_n),
        .enable_cycle(enable_cycle), .load_W(load_W),
        .accumulate_mode(accumulate_mode), .capture_en(capture_en),
        .row_inputs(row_inputs), .col_sel(col_sel),
        .sram_data_out(sram_data_out)
    );

    localparam T = 10;
    always #(T/2) clk = ~clk;

    integer i, r;

    // TASK: Load Weights (Uniform Value)
    task load_weights(input [7:0] val);
        begin
            $display("--- Loading Weights: %0d ---", val);
            enable_cycle = 1; 
            load_W = 0; // Shift mode
            // Shift in 8 cols deep
            for(i=0; i<8; i=i+1) begin
                row_inputs = {8{val}}; 
                #(T);
            end
            // Latch
            load_W = 1; #(T);
            load_W = 0;
            row_inputs = 0; #(T);
        end
    endtask

    // TASK: Run Wave (Skewed Inputs)
    task run_wave(input [7:0] val);
        begin
            $display("--- Running Wave Input: %0d ---", val);
            // Run for 25 cycles to ensure wave clears 8x8 array
            for (i = 0; i < 25; i = i + 1) begin
                for (r = 0; r < 8; r = r + 1) begin
                    // Skew logic: Row R active if time >= R
                    if (i >= r && i < (r+8)) 
                        row_inputs[r*8 +: 8] = val;
                    else 
                        row_inputs[r*8 +: 8] = 0;
                end
                #(T);
            end
        end
    endtask

    initial begin
        // Init
        clk = 0; rst_n = 0;
        enable_cycle = 0; load_W = 0;
        accumulate_mode = 0; capture_en = 0;
        row_inputs = 0; col_sel = 0;

        // Reset
        #(T*2) rst_n = 1; #(T);

        // =======================================================
        // PASS 1: The "Left Tile"
        // Inputs = 2, Weights = 1.  Result should be 8 * (2*1) = 16.
        // =======================================================
        load_weights(8'd1);
        run_wave(8'd2);

        // CAPTURE (Mode 0 = Overwrite)
        accumulate_mode = 0; // First tile, clean the buffer
        capture_en = 1;
        #(T);
        capture_en = 0;
        $display("Pass 1 Complete. Buffer should hold 16.");

        // =======================================================
        // PASS 2: The "Right Tile" (Accumulation Test)
        // Inputs = 4, Weights = 1. Result should be 8 * (4*1) = 32.
        // TOTAL BUFFER should be 16 + 32 = 48.
        // =======================================================
        load_weights(8'd1); // Reload weights (simulating next tile weights)
        run_wave(8'd4);     // Stream new data

        // CAPTURE (Mode 1 = ADD)
        accumulate_mode = 1; // Add to existing!
        capture_en = 1;
        #(T);
        capture_en = 0;
        $display("Pass 2 Complete. Buffer should hold 16 + 32 = 48.");

        // =======================================================
        // VERIFY OUTPUT
        // =======================================================
        $display("--- Reading Results ---");
        for(i=0; i<8; i=i+1) begin
            col_sel = i;
            #(T);
            if(sram_data_out == 48)
                $display("Col %0d: %0d [PASS]", i, sram_data_out);
            else
                $display("Col %0d: %0d [FAIL - Exp 48]", i, sram_data_out);
        end

        $finish;
    end

endmodule