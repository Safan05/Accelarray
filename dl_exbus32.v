module dataloader_agu #(
    parameter ARRAY_SIZE      = 8,    // systolic array dimension (e.g., 8)
    parameter MAX_N           = 64,
    parameter MAX_K           = 16,
    parameter DATA_WIDTH      = 8,    // pixel/weight width in bits (8)
    parameter ADDR_WIDTH      = 12    // word-address width for SRAM (addressing 32-bit words)
) (
    // Global
    input  wire                         clk,
    input  wire                         rst_n,
    
    // Control (from top-level Control Unit)
    input  wire                         agu_enable,
    input  wire [2:0]                   agu_mode,
    input  wire                         agu_start,
    input  wire [6:0]                   latched_N,
    input  wire [4:0]                   latched_K,
    // input  wire [15:0]                  output_size,   // number of bytes to unload (8-bit outputs)
    output reg                          agu_done,
    
    // Memory control signals
    input  wire                         mem_read_en,   // allows STREAM_INPUT to issue reads
    input  wire                         mem_write_en,   // allows LOAD_WEIGHT and LOAD_INPUT to issue writes
    input  wire                         bank_sel,      // selects bank (top-level interprets)
    
  
    // input  wire [7:0]                   tile_row,      // which output tile row (0..)
    // input  wire [7:0]                   tile_col,      // which output tile col (0..)
    
    // DRAM Interface (Input Stream) -- now 32-bit word per cycle
    input  wire [31:0]                  rx_data,       // full 32-bit word from DRAM
    input  wire                         rx_valid,
    output reg                          rx_ready,
    
    // DRAM Interface (Output Stream) -- 8-bit bytes streamed out
    output reg  [7:0]                   tx_data,       // one byte per cycle to DRAM (tx_ready handshake)
    output reg                          tx_valid,
    input  wire                         tx_ready,
    
    // Unified SRAM Interface (32-bit data path)
    output reg                          sram_wen,      // active high write enable
    output reg                          sram_ren,      // active high read enable
    output reg  [3:0]                   sram_wmask,    // byte-level write mask (4 bits for 32-bit word)
    output reg  [ADDR_WIDTH-1:0]        sram_addr,     // word-address
    output reg  [31:0]                  sram_din,      // write data
    input  wire [31:0]                  sram_dout      // read data (valid one cycle after read)
);

    // AGU modes
    localparam AGU_MODE_IDLE        = 3'b000;
    localparam AGU_MODE_LOAD_WEIGHT = 3'b001;
    localparam AGU_MODE_LOAD_INPUT  = 3'b010;
    localparam AGU_MODE_SLIDING_WIN = 3'b011;
    localparam AGU_MODE_UNLOAD      = 3'b100;

    // FSM states
    reg [3:0] state, next_state;
    localparam IDLE          = 4'd0;
    localparam LOAD_WEIGHT   = 4'd1;
    localparam LOAD_INPUT    = 4'd2;
    localparam STREAM_INPUT  = 4'd3;
    localparam UNLOAD_OUTPUT = 4'd4;
    localparam DONE          = 4'd5;

    // Derived constants
    localparam BYTES_PER_WORD = 32 / DATA_WIDTH; // 4 for 8-bit data
    localparam WORD_SHIFT     = 2;               // >> 2 equals /4 for bytes->words (hardcoded for 32-bit)
                                                 // If DATA_WIDTH changes, compute shift appropriately.

    // Addressing and tiling
    reg [ADDR_WIDTH-1:0] write_addr; // word address pointer used during LOAD
    reg [ADDR_WIDTH-1:0] read_addr;  // word address pointer used during STREAM/UNLOAD (word-address)
    reg [ADDR_WIDTH-1:0] base_addr;  // base word address for current region (weights/inputs/outputs)
    
    // tile math
    reg [7:0] input_tile_size;      // ARRAY_SIZE + K - 1
    reg [7:0] output_dim;           // latched_N - latched_K + 1
    reg [7:0] num_tiles_per_row;
    reg [15:0] total_input_pixels;  // bytes in input tile
    reg [15:0] total_weight_pixels; // bytes in weight tile
    reg [15:0] total_input_words;   // words = bytes / 4
    reg [15:0] total_weight_words;  // words = bytes / 4

    // counters
    reg [31:0] pixel_counter;       // counts bytes for streaming/unload; for LOAD we use write_addr (words)
    
    // sliding window state inside a tile (indices are in pixels/bytes)
    reg [7:0] window_row;
    reg [7:0] window_col;
    reg [15:0] base_row_offset;     // byte/pixel offset for tile start = tile_row * ARRAY_SIZE
    reg [15:0] base_col_offset;     // likewise for columns

    // SRAM read handling (1-cycle latency)
    reg [31:0] sram_data_latched;
    reg        data_valid;
    reg        read_issued;  // sram_ren issued previous cycle

    //--------------------------------------------------------------------------
    // Tile size and derived counts (combinational)
    //--------------------------------------------------------------------------
    always @(*) begin
        // output of conv??
        output_dim         = latched_N - latched_K + 7'd1;
        input_tile_size    = ARRAY_SIZE + latched_K - 7'd1;
        // number of tiles per row, ceil(output_dim / ARRAY_SIZE)
        num_tiles_per_row  = (output_dim + ARRAY_SIZE - 1) / ARRAY_SIZE;
        total_input_pixels = input_tile_size * input_tile_size;    // bytes
        total_weight_pixels= latched_K * latched_K;                // bytes
        // words (32-bit) needed to store each tile in SRAM
        total_input_words  = (total_input_pixels + BYTES_PER_WORD - 1) >> WORD_SHIFT; // ceil
        total_weight_words = (total_weight_pixels + BYTES_PER_WORD - 1) >> WORD_SHIFT; // ceil
    end

    //--------------------------------------------------------------------------
    // FSM registers
    //--------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= IDLE;
        else        state <= next_state;
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
                // finish when we've written all words for weight tile
                if (write_addr >= total_weight_words)
                    next_state = DONE;
            end

            LOAD_INPUT: begin
                if (write_addr >= total_input_words)
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

    //--------------------------------------------------------------------------
    // sram read latency handling (1-cycle)
    //--------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sram_data_latched <= 32'd0;
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

    //--------------------------------------------------------------------------
    // Main datapath / FSM behavior
    //--------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // outputs
            agu_done <= 1'b0;
            rx_ready <= 1'b0;
            tx_valid <= 1'b0;
            tx_data  <= 8'd0;
            // sram controls
            sram_wen  <= 1'b0;
            sram_ren  <= 1'b0;
            sram_wmask<= 4'b0000;
            sram_addr <= {ADDR_WIDTH{1'b0}};
            sram_din  <= 32'd0;
            // internal regs
            write_addr <= {ADDR_WIDTH{1'b0}};
            read_addr  <= {ADDR_WIDTH{1'b0}};
            base_addr  <= {ADDR_WIDTH{1'b0}};
            pixel_counter <= 32'd0;
            window_row <= 8'd0;
            window_col <= 8'd0;
            base_row_offset <= 16'd0;
            base_col_offset <= 16'd0;
        end else begin
            // default every cycle
            sram_wen  <= 1'b0;
            sram_ren  <= 1'b0;
            sram_wmask<= 4'b0000;
            agu_done  <= 1'b0;
            rx_ready  <= 1'b0;
            tx_valid  <= 1'b0;

            case (state)
                // ---------------------------------------------------------
                IDLE: begin
                    rx_ready <= 1'b0;
                    tx_valid <= 1'b0;

                    if (agu_enable && agu_start) begin
                        // init counters
                        write_addr    <= {ADDR_WIDTH{1'b0}};
                        read_addr     <= {ADDR_WIDTH{1'b0}};
                        pixel_counter <= 32'd0;
                        window_row    <= 8'd0;
                        window_col    <= 8'd0;

                        // default base_addr mapping (word-addressed); control unit may override by writing base_addr externally
                        // Example mapping: byte base addresses 0x200/0x400/0x600 convert to word addresses by >>2.
                        // ???
                        case (agu_mode)
                            AGU_MODE_LOAD_WEIGHT: base_addr <= 0;  // weights at word 0
                            AGU_MODE_LOAD_INPUT:  base_addr <= bank_sel ? (12'h400 >> WORD_SHIFT) : (12'h200 >> WORD_SHIFT);
                            AGU_MODE_SLIDING_WIN: base_addr <= bank_sel ? (12'h400 >> WORD_SHIFT) : (12'h200 >> WORD_SHIFT);
                            AGU_MODE_UNLOAD:      base_addr <= (12'h600 >> WORD_SHIFT);
                            default:              base_addr <= 0;
                        endcase

                        // compute tile base offsets in pixel coordinates (rows/cols)
                        // base_row_offset <= tile_row * ARRAY_SIZE;
                        // base_col_offset <= tile_col * ARRAY_SIZE;

                        // accept incoming stream for load modes
                        if (agu_mode == AGU_MODE_LOAD_WEIGHT || agu_mode == AGU_MODE_LOAD_INPUT)
                            rx_ready <= 1'b1;
                    end
                end

                // ---------------------------------------------------------
                LOAD_WEIGHT: begin
                    // Expect rx_data to be 32-bit word from DRAM; write directly into SRAM
                    rx_ready <= 1'b1;
                    if (rx_valid && rx_ready) begin
                        sram_wen   <= 1'b1;
                        sram_wmask <= 4'b1111;                    // writing full word
                        sram_addr  <= base_addr + write_addr;
                        sram_din   <= rx_data;
                        write_addr <= write_addr + 1'b1;         // advance word pointer

                        // update byte-count by 4 bytes
                        pixel_counter <= pixel_counter + BYTES_PER_WORD;

                        // stop accepting when we've written all weight words
                        if (write_addr + 1 >= total_weight_words)
                            rx_ready <= 1'b0;
                    end
                end

                // ---------------------------------------------------------
                LOAD_INPUT: begin
                    rx_ready <= 1'b1;
                    if (rx_valid && rx_ready) begin
                        sram_wen   <= 1'b1;
                        sram_wmask <= 4'b1111;
                        sram_addr  <= base_addr + write_addr;
                        sram_din   <= rx_data;
                        write_addr <= write_addr + 1'b1;
                        pixel_counter <= pixel_counter + BYTES_PER_WORD;

                        if (write_addr + 1 >= total_input_words)
                            rx_ready <= 1'b0;
                    end
                end

                // ---------------------------------------------------------
                STREAM_INPUT: begin
                    // STREAM_INPUT: AGU generates sliding-window addresses to feed systolic array.
                    // mem_read_en must be asserted by control unit to step the AGU (prevents overruns).
                    if (mem_read_en) begin
                        // linear_offset (in pixels/bytes) inside the input tile:
                        // (base_row_offset + window_row) * input_tile_size + (base_col_offset + window_col)
                        // This is an offset in pixels; convert to word address by >> WORD_SHIFT
                        // Use temporary signals via blocking-style "local" regs
                        reg [31:0] linear_offset;
                        reg [ADDR_WIDTH-1:0] word_addr_local;

                        linear_offset = ( (base_row_offset + window_row) * input_tile_size )
                                      + ( base_col_offset + window_col ); // pixel offset (byte index)

                        word_addr_local = linear_offset >> WORD_SHIFT; // word index within tile
                        read_addr <= base_addr + word_addr_local;
                        sram_ren <= 1'b1;
                        sram_addr <= base_addr + word_addr_local;

                        // advance window pointer
                        if (window_col < (input_tile_size - 1)) begin
                            window_col <= window_col + 1;
                        end else begin
                            window_col <= 8'd0;
                            if (window_row < (input_tile_size - 1)) begin
                                window_row <= window_row + 1;
                            end else begin
                                window_row <= 8'd0;
                            end
                        end

                        pixel_counter <= pixel_counter + 1; // count bytes output from the AGU generator (if desired)
                    end
                end

                // ---------------------------------------------------------
                UNLOAD_OUTPUT: begin
                    // The goal: stream output bytes (8-bit) from SRAM words to tx_data with Valid/Ready handshake.
                    // pixel_counter is byte-index into the output region (0..output_size-1).
                    reg [ADDR_WIDTH-1:0] word_addr_local;
                    reg [1:0] byte_offset;

                    word_addr_local = (pixel_counter >> WORD_SHIFT);   // which 32-bit word contains desired byte
                    byte_offset     = pixel_counter[1:0];              // which byte inside the word (0..3)

                    // issue read for that word (word-address)
                    sram_ren <= 1'b1;
                    sram_addr <= base_addr + word_addr_local;

                    // when read returns (1-cycle latency), sram_data_latched has the word and data_valid=1
                    if (data_valid) begin
                        // select proper byte
                        tx_valid <= 1'b1;
                        case (byte_offset)
                            2'd0: tx_data <= sram_data_latched[7:0];
                            2'd1: tx_data <= sram_data_latched[15:8];
                            2'd2: tx_data <= sram_data_latched[23:16];
                            2'd3: tx_data <= sram_data_latched[31:24];
                        endcase

                        if (tx_ready) begin
                            pixel_counter <= pixel_counter + 1;
                        end
                    end else begin
                        // wait for latency cycle
                        tx_valid <= 1'b0;
                    end
                end

                // ---------------------------------------------------------
                DONE: begin
                    agu_done <= 1'b1;
                    rx_ready <= 1'b0;
                    tx_valid <= 1'b0;
                end

            endcase
        end
    end

endmodule
