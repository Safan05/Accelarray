module dataloader_agu #(
    parameter ARRAY_SIZE = 8,
    parameter MAX_N = 64,
    parameter MAX_K = 16,
    parameter DATA_WIDTH = 8,
    parameter ADDR_WIDTH = 12,
    parameter DRAM_BUS_WIDTH = 8
) (
    // Global signals
    input  wire                         clk,
    input  wire                         rst_n,
    
    // Control signals from Control Unit
    input  wire                         agu_enable,
    input  wire [2:0]                   agu_mode,
    input  wire                         agu_start,
    input  wire [6:0]                   latched_N,
    input  wire [4:0]                   latched_K,
    // input  wire [11:0]                  output_size,  I will handle this in this module
    output reg                          agu_done,
    
    // Memory control from Control Unit
    // input  wire                         mem_write_en, // (used in systolic array)
    input  wire                         mem_read_en,
    input  wire                         bank_sel,
    
    // DRAM Interface (Input Stream)
    input  wire [DRAM_BUS_WIDTH-1:0]    rx_data,
    input  wire                         rx_valid,
    output reg                          rx_ready,
    
    // DRAM Interface (Output Stream)
    output reg  [DRAM_BUS_WIDTH-1:0]   tx_data,
    output reg                          tx_valid,
    input  wire                         tx_ready,
    
    // Unified SRAM Interface
    output reg                          sram_wen,      // Write enable (active high)
    output reg                          sram_ren,      // Read enable (active high)
    output reg  [3:0]                   sram_wmask,    // Byte-level write mask
    output reg  [ADDR_WIDTH-1:0]        sram_addr,     // Address bus
    output reg  [31:0]                  sram_din,      // Data input (write data)
    input  wire [31:0]                  sram_dout      // Data output (read data)
);

    // AGU Mode Definitions
    localparam AGU_MODE_IDLE        = 3'b000;
    localparam AGU_MODE_LOAD_WEIGHT = 3'b001;
    localparam AGU_MODE_LOAD_INPUT  = 3'b010;
    localparam AGU_MODE_SLIDING_WIN = 3'b011;
    localparam AGU_MODE_UNLOAD      = 3'b100;
    
    // Internal State
    reg [3:0] state, next_state;
    
    localparam IDLE             = 4'd0;
    localparam LOAD_WEIGHT      = 4'd1;
    localparam LOAD_INPUT       = 4'd2;
    localparam STREAM_INPUT     = 4'd3;
    localparam UNLOAD_OUTPUT    = 4'd4;
    localparam DONE             = 4'd5;
    
    // Address generation
    reg [ADDR_WIDTH-1:0] write_addr;
    reg [ADDR_WIDTH-1:0] read_addr;
    reg [ADDR_WIDTH-1:0] base_addr;  // Base address for current operation
    reg [7:0]            tile_row;
    reg [7:0]            tile_col;
    
    // Tile calculations
    reg [7:0] input_tile_size;
    reg [7:0] num_tiles_per_row;
    reg [7:0] output_dim;
    reg [15:0] total_input_pixels;
    reg [15:0] total_weight_pixels;
    
    // Data buffering for packing/unpacking bytes
    reg [31:0] data_buffer;
    reg [1:0]  buffer_count;
    
    // Counters
    reg [15:0] pixel_counter;
    reg [15:0] total_pixels_to_transfer;
    
    // Sliding window state
    reg [7:0] window_row;
    reg [7:0] window_col;
    reg [7:0] base_row_offset;
    reg [7:0] base_col_offset;
    
    // SRAM read data latency handling
    reg [31:0] sram_data_latched;
    reg        data_valid;
    reg        read_issued;  // Track if read was issued previous cycle
    
    //==========================================================================
    // Tile Size Calculations
    //==========================================================================
    always @(*) begin
        output_dim        = latched_N - latched_K + 7'd1;
        input_tile_size   = ARRAY_SIZE + latched_K - 7'd1;
        num_tiles_per_row = (output_dim + ARRAY_SIZE - 7'd1) >> 3; // Divide by 8
        total_input_pixels  = input_tile_size * input_tile_size;
        total_weight_pixels = latched_K * latched_K;
    end
    
    //==========================================================================
    // State Machine
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= IDLE;
        else
            state <= next_state;
    end
    
    always @(*) begin
        next_state = state;
        
        case (state)
            IDLE: begin
                if (agu_enable && agu_start) begin
                    case (agu_mode)
                        AGU_MODE_LOAD_WEIGHT: next_state = LOAD_WEIGHT;
                        AGU_MODE_LOAD_INPUT:  next_state = LOAD_INPUT;
                        AGU_MODE_SLIDING_WIN: next_state = STREAM_INPUT;
                        AGU_MODE_UNLOAD:      next_state = UNLOAD_OUTPUT;
                        default:              next_state = IDLE;
                    endcase
                end
            end
            
            LOAD_WEIGHT: begin
                if (pixel_counter >= total_weight_pixels)
                    next_state = DONE;
            end
            
            LOAD_INPUT: begin
                if (pixel_counter >= total_input_pixels)
                    next_state = DONE;
            end
            
            STREAM_INPUT: begin
                if (pixel_counter >= total_input_pixels)
                    next_state = DONE;
            end
            
            UNLOAD_OUTPUT: begin
                if (pixel_counter >= output_size)
                    next_state = DONE;
            end
            
            DONE: begin
                next_state = IDLE;
            end
            
            default: next_state = IDLE;
        endcase
    end
    
    //==========================================================================
    // SRAM Data Latching (1-cycle read latency)
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sram_data_latched <= 0;
            data_valid <= 0;
            read_issued <= 0;
        end else begin
            read_issued <= sram_ren;
            if (read_issued) begin // Read data valid one cycle after ren
                sram_data_latched <= sram_dout;
                data_valid <= 1;
            end else begin
                data_valid <= 0;
            end
        end
    end
    
    //==========================================================================
    // Main Datapath Logic
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset all outputs
            agu_done <= 0;
            rx_ready <= 0;
            tx_valid <= 0;
            tx_data <= 0;
            
            // Reset SRAM controls
            sram_wen <= 0;
            sram_ren <= 0;
            sram_wmask <= 4'b0000;
            sram_addr <= 0;
            sram_din <= 0;
            
            // Reset internal registers
            write_addr <= 0;
            read_addr <= 0;
            base_addr <= 0;
            buffer_count <= 0;
            data_buffer <= 0;
            pixel_counter <= 0;
            tile_row <= 0;
            tile_col <= 0;
            window_row <= 0;
            window_col <= 0;
            base_row_offset <= 0;
            base_col_offset <= 0;
            
        end else begin
            // Default: disable SRAM
            sram_wen <= 0;
            sram_ren <= 0;
            agu_done <= 0;
            
            case (state)
                //==============================================================
                IDLE: begin
                    rx_ready <= 0;
                    tx_valid <= 0;
                    
                    if (agu_enable && agu_start) begin
                        // Initialize for new operation
                        write_addr <= 0;
                        read_addr <= 0;
                        buffer_count <= 0;
                        pixel_counter <= 0;
                        window_row <= 0;
                        window_col <= 0;
                        
                        // Set base address based on mode and bank_sel
                        // The Sram determines memory partitioning

                        case (agu_mode)
                            AGU_MODE_LOAD_WEIGHT: base_addr <= 0;  // Weight region start
                            AGU_MODE_LOAD_INPUT:  base_addr <= bank_sel ? 12'h400 : 12'h200;  // Example: Bank 0 @ 0x200, Bank 1 @ 0x400
                            AGU_MODE_SLIDING_WIN: base_addr <= bank_sel ? 12'h400 : 12'h200;  // Read from opposite bank
                            AGU_MODE_UNLOAD:      base_addr <= 12'h600;  // Output region start
                            default:              base_addr <= 0;
                        endcase
                        
                        // Calculate base tile offset for sliding window
                        base_row_offset <= tile_row * ARRAY_SIZE;
                        base_col_offset <= tile_col * ARRAY_SIZE;
                        
                        if (agu_mode == AGU_MODE_LOAD_WEIGHT || 
                            agu_mode == AGU_MODE_LOAD_INPUT) begin
                            rx_ready <= 1;
                        end
                    end
                end
                
                //==============================================================
                LOAD_WEIGHT: begin
                    rx_ready <= 1;
                    
                    if (rx_valid && rx_ready) begin
                        // Pack bytes into 32-bit word
                        data_buffer[buffer_count*8 +: 8] <= rx_data;
                        buffer_count <= buffer_count + 1;
                        pixel_counter <= pixel_counter + 1;
                        
                        // Write when buffer is full (4 bytes)
                        if (buffer_count == 2'd3) begin
                            sram_wen <= 1;
                            sram_wmask <= 4'b1111;
                            sram_addr <= base_addr + write_addr;
                            sram_din <= {rx_data, data_buffer[23:0]};
                            write_addr <= write_addr + 1;
                            buffer_count <= 0;
                        end
                        
                        // Check if done
                        if (pixel_counter >= total_weight_pixels - 1) begin
                            rx_ready <= 0;
                        end
                    end
                end
                
                //==============================================================
                LOAD_INPUT: begin
                    rx_ready <= 1;
                    
                    if (rx_valid && rx_ready) begin
                        // Pack bytes into 32-bit word
                        data_buffer[buffer_count*8 +: 8] <= rx_data;
                        buffer_count <= buffer_count + 1;
                        pixel_counter <= pixel_counter + 1;
                        
                        // Write when buffer is full
                        if (buffer_count == 2'd3) begin
                            sram_wen <= 1;
                            sram_wmask <= 4'b1111;
                            sram_addr <= base_addr + write_addr;
                            sram_din <= {rx_data, data_buffer[23:0]};
                            write_addr <= write_addr + 1;
                            buffer_count <= 0;
                        end
                        
                        if (pixel_counter >= total_input_pixels - 1) begin
                            rx_ready <= 0;
                        end
                    end
                end
                
                //==============================================================
                STREAM_INPUT: begin
                    if (mem_read_en) begin
                        // Generate sliding window addresses
                        // Linear address = (base_row + window_row) * tile_width + (base_col + window_col)
                        // base_row=2, base_col=1, window_row=1, window_col=2, tile_width=8
                        reg [15:0] linear_offset;
                        linear_offset = window_row * input_tile_size + window_col;
                        read_addr <= linear_offset[ADDR_WIDTH-1:0] >> 2; // Word address
                        
                        // Read from SRAM
                        sram_ren <= 1;
                        sram_addr <= base_addr + read_addr;
                        
                        // Advance window position
                        if (window_col < input_tile_size - 1) begin
                            window_col <= window_col + 1;
                        end else begin
                            window_col <= 0;
                            if (window_row < input_tile_size - 1) begin
                                window_row <= window_row + 1;
                            end else begin
                                window_row <= 0;
                            end
                        end
                        
                        pixel_counter <= pixel_counter + 1;
                    end
                end
                
                //==============================================================
                UNLOAD_OUTPUT: begin
                    // Read output from SRAM
                    sram_ren <= 1;
                    // sram_addr <= base_addr + (pixel_counter >> 2); // Word address
                    
                    // Output valid data with 1-cycle latency
                    if (data_valid) begin
                        tx_valid <= 1;
                        // Extract byte from 32-bit word
                        case ((pixel_counter - 1) & 2'd3)
                            2'd0: tx_data <= sram_data_latched[7:0];
                            2'd1: tx_data <= sram_data_latched[15:8];
                            2'd2: tx_data <= sram_data_latched[23:16];
                            2'd3: tx_data <= sram_data_latched[31:24];
                        endcase
                        
                        if (tx_ready) begin
                            pixel_counter <= pixel_counter + 1;
                        end
                    end else begin
                        pixel_counter <= pixel_counter + 1;
                        tx_valid <= 0;
                    end
                    
                    if (pixel_counter >= output_size) begin
                        tx_valid <= 0;
                    end
                end
                
                //==============================================================
                DONE: begin
                    agu_done <= 1;
                    rx_ready <= 0;
                    tx_valid <= 0;
                end
                
            endcase
        end
    end

endmodule