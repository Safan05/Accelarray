`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Testbench: control_unit_tb
// Description: Testbench for the Control Unit FSM
//              Tests state transitions and control signal generation
//////////////////////////////////////////////////////////////////////////////////

module control_unit_tb;

    //==========================================================================
    // Parameters
    //==========================================================================
    parameter CLK_PERIOD = 10;  // 100 MHz clock
    parameter DATA_WIDTH = 8;
    parameter MAX_N = 64;
    parameter MAX_K = 16;
    parameter ARRAY_SIZE = 8;

    //==========================================================================
    // Signals
    //==========================================================================
    // Global
    reg                     clk;
    reg                     rst_n;
    
    // Host Interface
    reg                     start;
    reg  [6:0]              cfg_N;
    reg  [4:0]              cfg_K;
    wire                    done;
    
    // Data Stream
    reg                     rx_valid;
    wire                    rx_ready;
    reg                     tx_ready;
    wire                    tx_valid;
    
    // AGU Control
    wire                    agu_enable;
    wire [2:0]              agu_mode;
    wire                    agu_start;
    reg                     agu_done;
    
    // Memory Control
    wire                    mem_write_en;
    wire                    mem_read_en;
    wire                    bank_sel;
    wire                    weight_bank_sel;
    
    // Systolic Array Control
    wire                    sa_enable;
    wire                    sa_clear;
    wire                    sa_load_weight;
    reg                     sa_done;
    
    // Configuration Outputs
    wire [6:0]              latched_N;
    wire [4:0]              latched_K;
    wire [11:0]             output_size;
    
    // Debug
    wire [2:0]              current_state;
    wire [15:0]             cycle_count;

    //==========================================================================
    // State Name Strings (for waveform debugging)
    //==========================================================================
    reg [15*8:1] state_name;
    always @(*) begin
        case (current_state)
            3'b000:  state_name = "IDLE";
            3'b001:  state_name = "LOAD_WEIGHTS";
            3'b010:  state_name = "LOAD_INPUT";
            3'b011:  state_name = "COMPUTE";
            3'b100:  state_name = "DRAIN";
            3'b101:  state_name = "DONE";
            default: state_name = "UNKNOWN";
        endcase
    end

    //==========================================================================
    // DUT Instantiation
    //==========================================================================
    control_unit #(
        .DATA_WIDTH(DATA_WIDTH),
        .MAX_N(MAX_N),
        .MAX_K(MAX_K),
        .ARRAY_SIZE(ARRAY_SIZE)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .cfg_N(cfg_N),
        .cfg_K(cfg_K),
        .done(done),
        .rx_valid(rx_valid),
        .rx_ready(rx_ready),
        .tx_ready(tx_ready),
        .tx_valid(tx_valid),
        .agu_enable(agu_enable),
        .agu_mode(agu_mode),
        .agu_start(agu_start),
        .agu_done(agu_done),
        .mem_write_en(mem_write_en),
        .mem_read_en(mem_read_en),
        .bank_sel(bank_sel),
        .weight_bank_sel(weight_bank_sel),
        .sa_enable(sa_enable),
        .sa_clear(sa_clear),
        .sa_load_weight(sa_load_weight),
        .sa_done(sa_done),
        .latched_N(latched_N),
        .latched_K(latched_K),
        .output_size(output_size),
        .current_state(current_state),
        .cycle_count(cycle_count)
    );

    //==========================================================================
    // Clock Generation
    //==========================================================================
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    //==========================================================================
    // Test Stimulus
    //==========================================================================
    initial begin
        // Initialize signals
        rst_n     = 0;
        start     = 0;
        cfg_N     = 7'd16;   // 16x16 input matrix
        cfg_K     = 5'd3;    // 3x3 kernel
        rx_valid  = 0;
        tx_ready  = 0;
        agu_done  = 0;
        sa_done   = 0;

        // Dump waveforms
        $dumpfile("control_unit_tb.vcd");
        $dumpvars(0, control_unit_tb);

        // Display header
        $display("================================================================");
        $display("           Control Unit Testbench");
        $display("================================================================");
        $display("Time\t\tState\t\t\tDescription");
        $display("----------------------------------------------------------------");

        // Apply reset
        #(CLK_PERIOD * 5);
        rst_n = 1;
        #(CLK_PERIOD * 2);
        $display("%0t\t%s\t\tReset complete, in IDLE", $time, state_name);

        //======================================================================
        // Test 1: Start computation with 16x16 input, 3x3 kernel
        //======================================================================
        $display("\n--- Test 1: Basic State Transitions ---");
        
        // Issue start command
        @(posedge clk);
        start = 1;
        cfg_N = 7'd16;
        cfg_K = 5'd3;
        @(posedge clk);
        start = 0;
        #(CLK_PERIOD);
        $display("%0t\t%s\tStart issued, N=%0d, K=%0d", $time, state_name, cfg_N, cfg_K);

        // Wait for LOAD_WEIGHTS state
        wait(current_state == 3'b001);
        $display("%0t\t%s\tLoading weights...", $time, state_name);
        
        // Simulate weight loading (K*K = 9 weights)
        repeat(9) begin
            @(posedge clk);
            rx_valid = 1;
            @(posedge clk);
            rx_valid = 0;
        end
        #(CLK_PERIOD * 2);

        // Wait for LOAD_INPUT state
        wait(current_state == 3'b010);
        $display("%0t\t%s\tLoading input tile...", $time, state_name);
        
        // Simulate input loading (8x8 = 64 elements for one tile)
        repeat(64) begin
            @(posedge clk);
            rx_valid = 1;
            @(posedge clk);
            rx_valid = 0;
        end
        #(CLK_PERIOD * 2);

        // Wait for COMPUTE state
        wait(current_state == 3'b011);
        $display("%0t\t%s\tComputing...", $time, state_name);
        
        // Simulate compute completion
        #(CLK_PERIOD * 20);
        @(posedge clk);
        sa_done = 1;
        @(posedge clk);
        sa_done = 0;
        #(CLK_PERIOD * 2);

        // Wait for DRAIN state
        wait(current_state == 3'b100);
        $display("%0t\t%s\tDraining results...", $time, state_name);
        
        // Simulate draining results
        tx_ready = 1;
        // Need to drain enough outputs to complete
        repeat(200) begin
            @(posedge clk);
        end

        // Check for DONE state
        if (current_state == 3'b101) begin
            $display("%0t\t%s\tComputation complete!", $time, state_name);
        end

        // Wait for return to IDLE
        wait(current_state == 3'b000);
        $display("%0t\t%s\tBack to IDLE", $time, state_name);

        //======================================================================
        // Test Summary
        //======================================================================
        #(CLK_PERIOD * 10);
        $display("\n================================================================");
        $display("           Test Complete");
        $display("================================================================");
        $display("Latched N: %0d", latched_N);
        $display("Latched K: %0d", latched_K);
        $display("Output Size: %0d", output_size);
        $display("Total Cycles: %0d", cycle_count);
        $display("================================================================\n");
        
        $finish;
    end

    //==========================================================================
    // Monitor for state changes
    //==========================================================================
    reg [2:0] prev_state;
    always @(posedge clk) begin
        prev_state <= current_state;
        if (prev_state != current_state) begin
            $display("%0t\tState: %s -> Control signals updated", $time, state_name);
        end
    end

    //==========================================================================
    // Timeout watchdog
    //==========================================================================
    initial begin
        #(CLK_PERIOD * 10000);
        $display("ERROR: Simulation timeout!");
        $finish;
    end

endmodule
