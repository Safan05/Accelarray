`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module: control_unit
// Description: Main FSM Controller for the Convolution Accelerator
//              Manages system states: IDLE, LOAD_WEIGHTS, LOAD_INPUT, COMPUTE, DRAIN, DONE
//              Coordinates AGU, Memory, and Systolic Array operations
//////////////////////////////////////////////////////////////////////////////////

module control_unit #(
    parameter DATA_WIDTH = 8,
    parameter MAX_N = 64,           // Maximum input matrix dimension
    parameter MAX_K = 16,           // Maximum kernel dimension
    parameter ARRAY_SIZE = 8        // Systolic array dimension (8x8)
)(
    // Global Signals
    input  wire                     clk,
    input  wire                     rst_n,          // Active-low async reset
    
    // Host Interface - Control
    input  wire                     start,          // Start pulse from host
    input  wire [6:0]               cfg_N,          // Input matrix dimension (16-64)
    input  wire [4:0]               cfg_K,          // Kernel dimension (2-16)
    output reg                      done,           // Computation complete signal
    
    // Data Stream Interface (to/from external DRAM)
    input  wire                     rx_valid,       // DRAM has valid data
    output reg                      rx_ready,       // Ready to accept data
    input  wire                     tx_ready,       // DRAM ready to accept results
    output reg                      tx_valid,       // Valid result available
    
    // AGU Control Interface
    output reg                      agu_enable,     // Enable AGU
    output reg  [2:0]               agu_mode,       // AGU operation mode
    output reg                      agu_start,      // Start AGU operation
    input  wire                     agu_done,       // AGU operation complete
    
    // Memory Control Interface
    output reg                      mem_write_en,   // Memory write enable
    output reg                      mem_read_en,    // Memory read enable
    output reg                      bank_sel,       // Ping-pong bank select (0 or 1)
    output reg                      weight_bank_sel,// Weight bank select
    
    // Systolic Array Control Interface
    output reg                      sa_enable,      // Enable systolic array
    output reg                      sa_clear,       // Clear accumulators
    output reg                      sa_load_weight, // Load weights into PEs
    output reg                      sa_mem_read_en, // SA SRAM read enable (SA direct access)
    output reg                      sa_mem_write_en,// SA SRAM write enable (write results)
    output reg                      tile_start,     // Pulse: start processing a kernel tile
    output reg                      last_tile,      // Flag: this is the final tile
    input  wire                     tile_done,      // Current tile complete
    input  wire                     sa_done,        // ALL tiles complete (final results ready)
    
    // Configuration Outputs (latched values)
    output reg  [6:0]               latched_N,      // Latched N value
    output reg  [4:0]               latched_K,      // Latched K value
    
    // Status/Debug
    output reg  [2:0]               current_state,  // Current FSM state
    output reg  [15:0]              cycle_count     // Cycle counter for profiling
);

    //==========================================================================
    // Local Parameters - State Encoding
    //==========================================================================
    localparam [2:0] STATE_IDLE         = 3'b000;
    localparam [2:0] STATE_LOAD_WEIGHTS = 3'b001;
    localparam [2:0] STATE_LOAD_INPUT   = 3'b010;
    localparam [2:0] STATE_COMPUTE      = 3'b011;
    localparam [2:0] STATE_DRAIN        = 3'b100;
    localparam [2:0] STATE_DONE         = 3'b101;
    
    // AGU Mode Encoding
    localparam [2:0] AGU_MODE_IDLE          = 3'b000;
    localparam [2:0] AGU_MODE_LOAD_WEIGHT   = 3'b001;
    localparam [2:0] AGU_MODE_LOAD_INPUT    = 3'b010;
    localparam [2:0] AGU_MODE_SLIDING_WIN   = 3'b011;
    localparam [2:0] AGU_MODE_UNLOAD        = 3'b100;

    //==========================================================================
    // Internal Registers
    //==========================================================================
    reg [2:0]  state, next_state,prev_state;
    reg [15:0] weight_count;            // Counter for weight elements (K*K)
    reg [15:0] input_count;             // Counter for input tile elements
    reg [15:0] output_count;            // Counter for output elements
    reg [15:0] total_weights;           // K * K
    reg [15:0] total_inputs;            // N * N
    reg [11:0] total_outputs;           // (N-K+1) * (N-K+1)
    reg [7:0]  tile_row, tile_col;      // Current tile position
    reg [7:0]  num_tiles_x, num_tiles_y;// Number of tiles in each dimension
    reg        weight_load_done;        // Weights fully loaded flag
    reg        input_tile_done;         // Current input tile loaded
    reg        compute_done;            // Current computation done
    reg        drain_done;              // Drain operation done
    reg        first_tile;              // First tile flag (no ping-pong swap)
    reg        state_entry;             // Flag to detect state entry (for pulse signals)
    
    //==========================================================================
    // Combinational: Calculate output dimensions
    //==========================================================================
    wire [6:0] output_dim;  // N - K + 1
    assign output_dim = latched_N - latched_K + 1;
    
    //==========================================================================
    // State Register (Sequential)
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= STATE_IDLE;
            prev_state <= STATE_IDLE;
        end else begin
            prev_state <= state;
            state      <= next_state;
        end
    end
    
    // Detect state entry (rising edge of state change)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_entry <= 1'b0;
        end else begin
            state_entry <= (state != prev_state);
        end
    end
    
    // Export current state for debugging
    always @(*) begin
        current_state = state;
    end

    //==========================================================================
    // Next State Logic (Combinational)
    //==========================================================================
    always @(*) begin
        next_state = state;  // Default: stay in current state
        
        case (state)
            STATE_IDLE: begin
                if (start) begin
                    next_state = STATE_LOAD_WEIGHTS;
                end
            end
            
            STATE_LOAD_WEIGHTS: begin
                if (weight_load_done) begin
                    next_state = STATE_LOAD_INPUT;
                end
            end
            
            STATE_LOAD_INPUT: begin
                if (input_tile_done) begin
                    next_state = STATE_COMPUTE;
                end
            end
            
            STATE_COMPUTE: begin
                // Transition when tile completes (tile_done) or entire array done (sa_done)
                if (tile_done || compute_done || sa_done) begin
                    next_state = STATE_DRAIN;
                end
            end
            
            STATE_DRAIN: begin
                if (drain_done) begin
                    // Check if more tiles to process
                    if (output_count >= total_outputs) begin
                        next_state = STATE_DONE;
                    end else begin
                        // More tiles: go back to load next input tile
                        next_state = STATE_LOAD_INPUT;
                    end
                end
            end
            
            STATE_DONE: begin
                // Auto-return to IDLE after done
                next_state = STATE_IDLE;
            end
            
            default: begin
                next_state = STATE_IDLE;
            end
        endcase
    end

    //==========================================================================
    // Configuration Latching (Sequential)
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            latched_N     <= 7'd0;
            latched_K     <= 5'd0;
            total_weights <= 16'd0;
            total_inputs  <= 16'd0;
            total_outputs <= 12'd0;
        end else if (state == STATE_IDLE && start) begin
            // Latch configuration on start
            latched_N     <= cfg_N;
            latched_K     <= cfg_K;
            total_weights <= cfg_K * cfg_K;
            total_inputs  <= cfg_N * cfg_N;
            total_outputs <= (cfg_N - cfg_K + 1) * (cfg_N - cfg_K + 1);
        end
    end

    //==========================================================================
    // Counter Logic (Sequential)
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            weight_count     <= 16'd0;
            input_count      <= 16'd0;
            output_count     <= 16'd0;
            weight_load_done <= 1'b0;
            input_tile_done  <= 1'b0;
            compute_done     <= 1'b0;
            drain_done       <= 1'b0;
            first_tile       <= 1'b1;
            tile_row         <= 8'd0;
            tile_col         <= 8'd0;
        end else begin
            case (state)
                STATE_IDLE: begin
                    weight_count     <= 16'd0;
                    input_count      <= 16'd0;
                    output_count     <= 16'd0;
                    weight_load_done <= 1'b0;
                    input_tile_done  <= 1'b0;
                    compute_done     <= 1'b0;
                    drain_done       <= 1'b0;
                    first_tile       <= 1'b1;
                    tile_row         <= 8'd0;
                    tile_col         <= 8'd0;
                end
                
                STATE_LOAD_WEIGHTS: begin
                    if (rx_valid && rx_ready) begin
                        weight_count <= weight_count + 1;
                        if (weight_count >= total_weights - 1) begin
                            weight_load_done <= 1'b1;
                        end
                    end
                end
                
                STATE_LOAD_INPUT: begin
                    weight_load_done <= 1'b0;  // Clear flag
                    if (rx_valid && rx_ready) begin
                        input_count <= input_count + 1;
                        // Check if we've loaded enough for current tile
                        // For tiling: load ARRAY_SIZE x ARRAY_SIZE + halo
                        if (input_count >= (ARRAY_SIZE * ARRAY_SIZE) - 1) begin
                            input_tile_done <= 1'b1;
                        end
                    end
                end
                
                STATE_COMPUTE: begin
                    input_tile_done <= 1'b0;  // Clear flag
                    input_count     <= 16'd0; // Reset for next tile
                    // Wait for systolic array to complete
                    if (sa_done || agu_done) begin
                        compute_done <= 1'b1;
                    end
                end
                
                STATE_DRAIN: begin
                    compute_done <= 1'b0;  // Clear flag
                    first_tile   <= 1'b0;  // No longer first tile
                    if (tx_valid && tx_ready) begin
                        output_count <= output_count + 1;
                        // Check if tile output complete
                        if (output_count[3:0] >= (ARRAY_SIZE - 1)) begin
                            drain_done <= 1'b1;
                            // Update tile position
                            if (tile_col < num_tiles_x - 1) begin
                                tile_col <= tile_col + 1;
                            end else begin
                                tile_col <= 8'd0;
                                tile_row <= tile_row + 1;
                            end
                        end
                    end
                end
                
                STATE_DONE: begin
                    drain_done <= 1'b0;
                end
            endcase
        end
    end

    //==========================================================================
    // Output Logic - Host Interface (Sequential)
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done     <= 1'b0;
            rx_ready <= 1'b0;
            tx_valid <= 1'b0;
        end else begin
            case (state)
                STATE_IDLE: begin
                    done     <= 1'b0;
                    rx_ready <= 1'b0;
                    tx_valid <= 1'b0;
                end
                
                STATE_LOAD_WEIGHTS: begin
                    rx_ready <= 1'b1;  // Ready to receive weights
                    tx_valid <= 1'b0;
                end
                
                STATE_LOAD_INPUT: begin
                    rx_ready <= 1'b1;  // Ready to receive input
                    tx_valid <= 1'b0;
                end
                
                STATE_COMPUTE: begin
                    rx_ready <= 1'b0;  // Not ready during compute
                    tx_valid <= 1'b0;
                end
                
                STATE_DRAIN: begin
                    rx_ready <= 1'b0;
                    tx_valid <= 1'b1;  // Valid output available
                end
                
                STATE_DONE: begin
                    done     <= 1'b1;  // Signal completion
                    rx_ready <= 1'b0;
                    tx_valid <= 1'b0;
                end
                
                default: begin
                    done     <= 1'b0;
                    rx_ready <= 1'b0;
                    tx_valid <= 1'b0;
                end
            endcase
        end
    end

    //==========================================================================
    // Output Logic - AGU Control (Sequential)
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            agu_enable <= 1'b0;
            agu_mode   <= AGU_MODE_IDLE;
            agu_start  <= 1'b0;
        end else begin
            agu_start <= 1'b0;  // Default: pulse signal
            
            case (state)
                STATE_IDLE: begin
                    agu_enable <= 1'b0;
                    agu_mode   <= AGU_MODE_IDLE;
                end
                
                STATE_LOAD_WEIGHTS: begin
                    agu_enable <= 1'b1;
                    agu_mode   <= AGU_MODE_LOAD_WEIGHT;
                    // Pulse agu_start only once on state entry
                    if (state_entry && prev_state != STATE_LOAD_WEIGHTS) begin
                        agu_start <= 1'b1;
                    end
                end
                
                STATE_LOAD_INPUT: begin
                    agu_enable <= 1'b1;
                    agu_mode   <= AGU_MODE_LOAD_INPUT;
                    // Pulse agu_start once on state entry
                    if (state_entry && prev_state != STATE_LOAD_INPUT) begin
                        agu_start <= 1'b1;
                    end
                end
                
                STATE_COMPUTE: begin
                    agu_enable <= 1'b1;
                    agu_mode   <= AGU_MODE_SLIDING_WIN;
                    // Pulse agu_start once on state entry
                    if (state_entry && prev_state != STATE_COMPUTE) begin
                        agu_start <= 1'b1;
                    end
                end
                
                STATE_DRAIN: begin
                    agu_enable <= 1'b1;
                    agu_mode   <= AGU_MODE_UNLOAD;
                    // Pulse agu_start once on state entry
                    if (state_entry && prev_state != STATE_DRAIN) begin
                        agu_start <= 1'b1;
                    end
                end
                
                STATE_DONE: begin
                    agu_enable <= 1'b0;
                    agu_mode   <= AGU_MODE_IDLE;
                end
                
                default: begin
                    agu_enable <= 1'b0;
                    agu_mode   <= AGU_MODE_IDLE;
                end
            endcase
        end
    end

    //==========================================================================
    // Output Logic - Memory Control (Sequential)
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_write_en    <= 1'b0;
            mem_read_en     <= 1'b0;
            bank_sel        <= 1'b0;
            weight_bank_sel <= 1'b0;
        end else begin
            case (state)
                STATE_IDLE: begin
                    mem_write_en    <= 1'b0;
                    mem_read_en     <= 1'b0;
                    bank_sel        <= 1'b0;
                    weight_bank_sel <= 1'b0;
                end
                
                STATE_LOAD_WEIGHTS: begin
                    mem_write_en    <= rx_valid;  // DL writes when valid data
                    mem_read_en     <= 1'b0;      // DL not reading
                    weight_bank_sel <= 1'b0;      // Weights to bank 0
                end
                
                STATE_LOAD_INPUT: begin
                    mem_write_en <= rx_valid;     // DL writes when valid data
                    mem_read_en  <= 1'b0;         // DL not reading
                    // Ping-pong: toggle bank_sel only on state entry
                    if (state_entry && prev_state != STATE_LOAD_INPUT) begin
                        bank_sel <= first_tile ? 1'b0 : ~bank_sel;
                    end
                end
                
                STATE_COMPUTE: begin
                    mem_write_en <= 1'b0;         // DL not writing
                    mem_read_en  <= 1'b0;         // DL not reading (SA reads directly!)
                    // SA uses sa_mem_read_en (controlled in SA control block)
                end
                
                STATE_DRAIN: begin
                    mem_write_en <= 1'b0;         // Not writing
                    mem_read_en  <= 1'b1;         // DL reads results from SRAM to send out
                end
                
                STATE_DONE: begin
                    mem_write_en <= 1'b0;
                    mem_read_en  <= 1'b0;
                end
                
                default: begin
                    mem_write_en <= 1'b0;
                    mem_read_en  <= 1'b0;
                end
            endcase
        end
    end

    //==========================================================================
    // Output Logic - Systolic Array Control (Sequential)
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sa_enable       <= 1'b0;
            sa_clear        <= 1'b0;
            sa_load_weight  <= 1'b0;
            sa_mem_read_en  <= 1'b0;
            sa_mem_write_en <= 1'b0;
            tile_start      <= 1'b0;
            last_tile       <= 1'b0;
        end else begin
            // Default: pulse signals go low
            tile_start <= 1'b0;
            
            case (state)
                STATE_IDLE: begin
                    sa_enable       <= 1'b0;
                    sa_clear        <= 1'b0;  // Don't continuously clear in IDLE
                    sa_load_weight  <= 1'b0;
                    sa_mem_read_en  <= 1'b0;
                    sa_mem_write_en <= 1'b0;
                    last_tile       <= 1'b0;
                end
                
                STATE_LOAD_WEIGHTS: begin
                    sa_enable       <= 1'b0;
                    // Pulse sa_clear once at the start of operation
                    sa_clear        <= (state_entry && prev_state == STATE_IDLE);
                    sa_load_weight  <= rx_valid;  // Load weights into PEs
                    sa_mem_read_en  <= 1'b0;
                    sa_mem_write_en <= 1'b0;
                    last_tile       <= 1'b0;
                end
                
                STATE_LOAD_INPUT: begin
                    sa_enable       <= 1'b0;
                    // Pulse sa_clear once at first tile entry only
                    sa_clear        <= (state_entry && prev_state != STATE_LOAD_INPUT && first_tile);
                    sa_load_weight  <= 1'b0;
                    sa_mem_read_en  <= 1'b0;
                    sa_mem_write_en <= 1'b0;
                end
                
                STATE_COMPUTE: begin
                    sa_enable       <= 1'b1;  // Enable MAC operations
                    sa_clear        <= 1'b0;
                    sa_load_weight  <= 1'b0;
                    sa_mem_read_en  <= 1'b1;  // SA reads input from SRAM
                    sa_mem_write_en <= 1'b0;  // NO write - results accumulate in PEs
                    
                    // Pulse tile_start once on entry to COMPUTE
                    if (state_entry && prev_state != STATE_COMPUTE) begin
                        tile_start <= 1'b1;
                    end
                    
                    // Set last_tile when this is the final computation
                    // (output_count + current tile outputs >= total_outputs)
                    last_tile <= (output_count + (ARRAY_SIZE * ARRAY_SIZE) >= total_outputs);
                end
                
                STATE_DRAIN: begin
                    sa_enable       <= 1'b0;  // SA disabled during drain
                    sa_clear        <= 1'b0;
                    sa_load_weight  <= 1'b0;
                    sa_mem_read_en  <= 1'b0;  // SA not reading
                    sa_mem_write_en <= 1'b1;  // SA writes final results to SRAM!
                end
                
                STATE_DONE: begin
                    sa_enable       <= 1'b0;
                    sa_clear        <= 1'b0;
                    sa_load_weight  <= 1'b0;
                    sa_mem_read_en  <= 1'b0;
                    sa_mem_write_en <= 1'b0;
                    last_tile       <= 1'b0;
                end
                
                default: begin
                    sa_enable       <= 1'b0;
                    sa_clear        <= 1'b0;  // Don't clear in default
                    sa_load_weight  <= 1'b0;
                    sa_mem_read_en  <= 1'b0;
                    sa_mem_write_en <= 1'b0;
                    last_tile       <= 1'b0;
                end
            endcase
        end
    end

    //==========================================================================
    // Cycle Counter (Sequential) - For Profiling/Debug
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycle_count <= 16'd0;
        end else if (state == STATE_IDLE) begin
            if (start) begin
                cycle_count <= 16'd0;  // Reset on new computation
            end
        end else if (state != STATE_DONE) begin
            cycle_count <= cycle_count + 1;  // Count active cycles
        end
    end

    //==========================================================================
    // Number of Tiles Calculation
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            num_tiles_x <= 8'd1;
            num_tiles_y <= 8'd1;
        end else if (state == STATE_IDLE && start) begin
            // Calculate number of tiles needed
            // Simple case: one tile fits entire output
            num_tiles_x <= (cfg_N - cfg_K + ARRAY_SIZE) / ARRAY_SIZE;
            num_tiles_y <= (cfg_N - cfg_K + ARRAY_SIZE) / ARRAY_SIZE;
        end
    end

endmodule
