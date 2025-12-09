module dataloader_agu #(
    parameter ARRAY_SIZE       = 8,
    parameter MAX_N            = 64,
    parameter MAX_K            = 16,
    parameter DATA_WIDTH       = 8,    // width of a single pixel / weight (bits)
    parameter SRAM_DATA_WIDTH  = 32,   // SRAM word width (bits) - e.g. 32
    parameter ADDR_WIDTH       = 12,   // SRAM address width (word-addressed)
    parameter DRAM_BUS_WIDTH   = 8     // width of rx/tx stream (must equal DATA_WIDTH for simple streams)
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
    input  wire [15:0]                  output_size,   // number of output bytes to unload
    output reg                          agu_done,
    
    // Memory control from Control Unit
    input  wire                         mem_read_en,
    input  wire                         bank_sel,
    
    // DRAM Interface (Input Stream)
    input  wire [DRAM_BUS_WIDTH-1:0]    rx_data,
    input  wire                         rx_valid,
    output reg                          rx_ready,
    
    // DRAM Interface (Output Stream)
    output reg  [DRAM_BUS_WIDTH-1:0]    tx_data,
    output reg                          tx_valid,
    input  wire                         tx_ready,
    
    // Unified SRAM Interface (word-addressed, data width = SRAM_DATA_WIDTH)
    output reg                          sram_wen,      // Write enable (active high)
    output reg                          sram_ren,      // Read enable (active high)
    output reg  [(SRAM_DATA_WIDTH/8)-1:0] sram_wmask,  // Byte-level write mask (width = bytes per word)
    output reg  [ADDR_WIDTH-1:0]        sram_addr,     // Word address
    output reg  [SRAM_DATA_WIDTH-1:0]   sram_din,      // Data input (write data)
    input  wire [SRAM_DATA_WIDTH-1:0]   sram_dout      // Data output (read data)
);

    // --- helper function for clog2 ---
    function integer clog2;
        input integer value;
        integer i;
        begin
            clog2 = 0;
            for (i = value - 1; i > 0; i = i >> 1)
                clog2 = clog2 + 1;
        end
    endfunction

    // Derived parameters
    localparam BYTES_PER_WORD  = SRAM_DATA_WIDTH / DATA_WIDTH;    // e.g., 32/8 = 4
    localparam ADDR_WORD_OFFSET = clog2(BYTES_PER_WORD);          // shift amount to convert byte-index -> word-index
    localparam BUFFER_COUNT_W  = (BYTES_PER_WORD == 1) ? 1 : clog2(BYTES_PER_WORD);

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
    
    // Address generation (word-addressed)
    reg [ADDR_WIDTH-1:0] write_addr;
    reg [ADDR_WIDTH-1:0] read_addr;
    reg [ADDR_WIDTH-1:0] base_addr;  // base (word) address for current operation

    reg [7:0] tile_row;
    reg [7:0] tile_col;
    
    // Tile calculations
    reg [7:0] input_tile_size;
    reg [7:0] num_tiles_per_row;
    reg [7:0] output_dim;
    reg [15:0] total_input_pixels;  // in bytes (pixels)
    reg [15:0] total_weight_pixels; // in bytes (weights)
    
    // Data buffering for packing/unpacking bytes into words
    reg [SRAM_DATA_WIDTH-1:0] data_buffer;
    reg [BUFFER_COUNT_W-1:0]  buffer_count; // counts bytes currently in buffer (0..BYTES_PER_WORD-1)
    
    // Counters (all counts are in bytes unless named word)
    reg [31:0] pixel_counter;           // counts bytes transferred/processed
    reg [31:0] total_pixels_to_transfer;
    
    // Sliding window state (indices in bytes/pixels)
    reg [15:0] window_row;
    reg [15:0] window_col;
    reg [15:0] base_row_offset;
    reg [15:0] base_col_offset;
    
    // SRAM read data latency handling (1-cycle)
    reg [SRAM_DATA_WIDTH-1:0] sram_data_latched;
    reg                      data_valid;
    reg                      read_issued;  // track if read was issued previous cycle
    
    // temp vars
    reg [31:0] linear_offset_bytes;      // linear offset in bytes (pixel indices)
    reg [ADDR_WIDTH-1:0] read_word_addr; // computed word address
    reg [BUFFER_COUNT_W-1:0] byte_offset_in_word; // which byte within word
    
    //==========================================================================
    // Tile Size Calculations (combinational)
    //==========================================================================
    always @(*) begin
        output_dim        = latched_N - latched_K + 7'd1;               // # output pixels per tile dimension
        input_tile_size   = ARRAY_SIZE + latched_K - 7'd1;             // input tile dimension (includes halo)
        num_tiles_per_row = (output_dim + ARRAY_SIZE - 7'd1) >> clog2(ARRAY_SIZE); // divide by ARRAY_SIZE
        total_input_pixels  = input_tile_size * input_tile_size;       // bytes
        total_weight_pixels = latched_K * latched_K;                   // bytes
    end
    
    //==========================================================================
    // State Machine registers
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
        end else begin
            state <= next_state;
        end
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
            sram_data_latched <= {SRAM_DATA_WIDTH{1'b0}};
            data_valid <= 1'b0;
            read_issued <= 1'b0;
        end else begin
            read_issued <= sram_ren;
            if (read_issued) begin
                sram_data_latched <= sram_dout;
                data_valid <= 1'b1;
            end else begin
                data_valid <= 1'b0;
            end
        end
    end
    
    //==========================================================================
    // Main Datapath Logic
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset outputs & controls
            agu_done <= 1'b0;
            rx_ready <= 1'b0;
            tx_valid <= 1'b0;
            tx_data <= {DRAM_BUS_WIDTH{1'b0}};
            
            sram_wen <= 1'b0;
            sram_ren <= 1'b0;
            sram_wmask <= {(SRAM_DATA_WIDTH/8){1'b0}};
            sram_addr <= {ADDR_WIDTH{1'b0}};
            sram_din <= {SRAM_DATA_WIDTH{1'b0}};
            
            write_addr <= {ADDR_WIDTH{1'b0}};
            read_addr <= {ADDR_WIDTH{1'b0}};
            base_addr <= {ADDR_WIDTH{1'b0}};
            buffer_count <= {BUFFER_COUNT_W{1'b0}};
            data_buffer <= {SRAM_DATA_WIDTH{1'b0}};
            pixel_counter <= 32'd0;
            tile_row <= 8'd0;
            tile_col <= 8'd0;
            window_row <= 16'd0;
            window_col <= 16'd0;
            base_row_offset <= 16'd0;
            base_col_offset <= 16'd0;
        end else begin
            // defaults every cycle
            sram_wen <= 1'b0;
            sram_ren <= 1'b0;
            agu_done <= 1'b0;
            rx_ready <= 1'b0;
            tx_valid <= 1'b0;
            
            case (state)
                //==============================================================
                IDLE: begin
                    rx_ready <= 1'b0;
                    tx_valid <= 1'b0;
                    if (agu_enable && agu_start) begin
                        // initialize
                        write_addr <= {ADDR_WIDTH{1'b0}};
                        read_addr <= {ADDR_WIDTH{1'b0}};
                        buffer_count <= {BUFFER_COUNT_W{1'b0}};
                        data_buffer <= {SRAM_DATA_WIDTH{1'b0}};
                        pixel_counter <= 32'd0;
                        window_row <= 16'd0;
                        window_col <= 16'd0;
                        tile_row <= tile_row; // keep current tile index unless control unit updates tile_row/tile_col externally
                        tile_col <= tile_col;
                        
                        // set base_addr (word-addressed) based on mode and bank_sel (user can pick base mapping)
                        case (agu_mode)
                            AGU_MODE_LOAD_WEIGHT: base_addr <= 0;  // Weight region start (word)
                            AGU_MODE_LOAD_INPUT:  base_addr <= bank_sel ? 12'h400 >> ADDR_WORD_OFFSET : 12'h200 >> ADDR_WORD_OFFSET;  // example mapping - convert byte addr to word addr
                            AGU_MODE_SLIDING_WIN: base_addr <= bank_sel ? 12'h400 >> ADDR_WORD_OFFSET : 12'h200 >> ADDR_WORD_OFFSET;
                            AGU_MODE_UNLOAD:      base_addr <= 12'h600 >> ADDR_WORD_OFFSET;  // output region start
                            default:              base_addr <= 0;
                        endcase
                        
                        base_row_offset <= tile_row * ARRAY_SIZE;
                        base_col_offset <= tile_col * ARRAY_SIZE;
                        
                        if (agu_mode == AGU_MODE_LOAD_WEIGHT || agu_mode == AGU_MODE_LOAD_INPUT) begin
                            rx_ready <= 1'b1; // accept incoming stream
                        end
                    end
                end
                
                //==============================================================
                LOAD_WEIGHT: begin
                    // Accept stream of DATA_WIDTH-wide items (assumes DRAM_BUS_WIDTH == DATA_WIDTH)
                    rx_ready <= 1'b1;
                    if (rx_valid && rx_ready) begin
                        // pack incoming data into data_buffer at position buffer_count
                        data_buffer[buffer_count * DATA_WIDTH +: DATA_WIDTH] <= rx_data;
                        buffer_count <= buffer_count + 1'b1;
                        pixel_counter <= pixel_counter + 1'b1; // counting bytes
                        
                        // if buffer now full (has BYTES_PER_WORD bytes), write word
                        if (buffer_count == (BYTES_PER_WORD - 1)) begin
                            sram_wen <= 1'b1;
                            sram_wmask <= { (SRAM_DATA_WIDTH/8){1'b1} }; // write all bytes in the word
                            sram_addr <= base_addr + write_addr;
                            sram_din <= data_buffer; // data_buffer already holds ordered bytes (LSB = first received)
                            write_addr <= write_addr + 1'b1;
                            buffer_count <= {BUFFER_COUNT_W{1'b0}}; // reset
                            data_buffer <= {SRAM_DATA_WIDTH{1'b0}};
                        end
                        
                        // stop accepting when finished
                        if (pixel_counter >= total_weight_pixels - 1) begin
                            rx_ready <= 1'b0;
                        end
                    end
                end
                
                //==============================================================
                LOAD_INPUT: begin
                    rx_ready <= 1'b1;
                    if (rx_valid && rx_ready) begin
                        data_buffer[buffer_count * DATA_WIDTH +: DATA_WIDTH] <= rx_data;
                        buffer_count <= buffer_count + 1'b1;
                        pixel_counter <= pixel_counter + 1'b1;
                        
                        if (buffer_count == (BYTES_PER_WORD - 1)) begin
                            sram_wen <= 1'b1;
                            sram_wmask <= { (SRAM_DATA_WIDTH/8){1'b1} };
                            sram_addr <= base_addr + write_addr;
                            sram_din <= data_buffer;
                            write_addr <= write_addr + 1'b1;
                            buffer_count <= {BUFFER_COUNT_W{1'b0}};
                            data_buffer <= {SRAM_DATA_WIDTH{1'b0}};
                        end
                        
                        if (pixel_counter >= total_input_pixels - 1) begin
                            rx_ready <= 1'b0;
                        end
                    end
                end
                
                //==============================================================
                STREAM_INPUT: begin
                    // streaming reads to feed systolic array (generates sliding-window byte addresses)
                    if (mem_read_en) begin
                        // compute linear byte offset: (base_row + window_row) * tile_width + (base_col + window_col)
                        linear_offset_bytes = ( (base_row_offset + window_row) * input_tile_size ) + (base_col_offset + window_col); // in bytes (pixels)
                        // compute word address and byte offset in word
                        read_word_addr = (linear_offset_bytes >> ADDR_WORD_OFFSET);
                        byte_offset_in_word = linear_offset_bytes[ADDR_WORD_OFFSET-1:0]; // lower bits
                        
                        read_addr <= base_addr + read_word_addr;
                        sram_ren <= 1'b1;
                        sram_addr <= base_addr + read_word_addr;
                        
                        // advance window pointer
                        if (window_col < (input_tile_size - 1)) begin
                            window_col <= window_col + 1;
                        end else begin
                            window_col <= 0;
                            if (window_row < (input_tile_size - 1)) begin
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
                    // We assume pixel_counter is the byte-index of the output stream
                    // Issue read of the word containing the desired byte
                    read_word_addr = (pixel_counter >> ADDR_WORD_OFFSET);
                    byte_offset_in_word = pixel_counter[ADDR_WORD_OFFSET-1:0];
                    
                    sram_ren <= 1'b1;
                    sram_addr <= base_addr + read_word_addr;
                    
                    // After one-cycle latency, sram_data_latched holds the word; data_valid indicates valid
                    if (data_valid) begin
                        // extract the DATA_WIDTH slice at byte_offset_in_word
                        tx_valid <= 1'b1;
                        tx_data <= sram_data_latched[byte_offset_in_word * DATA_WIDTH +: DATA_WIDTH];
                        
                        if (tx_ready) begin
                            pixel_counter <= pixel_counter + 1;
                        end
                    end else begin
                        // wait for data to become valid; do not advance pixel_counter until sending
                        tx_valid <= 1'b0;
                    end
                    
                    if (pixel_counter >= output_size) begin
                        tx_valid <= 1'b0;
                    end
                end
                
                //==============================================================
                DONE: begin
                    agu_done <= 1'b1;
                    rx_ready <= 1'b0;
                    tx_valid <= 1'b0;
                end
                
            endcase
        end
    end

endmodule
