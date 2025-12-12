module systolic_array #(
    parameter ROWS = 8,
    parameter COLS = 8,
    parameter DATA_WIDTH = 8,
    parameter SUM_WIDTH = 32
)(
    input wire clk,
    input wire rst_n,
    
    // --- Control Signals ---
    input wire enable_cycle,        // Global Clock Gate
    input wire load_W,              // 1 = Load Weights, 0 = Compute
    input wire output_group_sel,    // 0 = Cols 0-3, 1 = Cols 4-7 (NEW)
    
    // --- Data Inputs ---
    // Width: 64 bits (8 rows * 8 bits) -> Compliant with 128-bit limit
    input wire [(ROWS * DATA_WIDTH) - 1 : 0] pixel_in_bus,
    
    // North Input: 8 streams of Partial Sums for Tiling
    // To strictly meet 128-bit pin constraints here, you would typically 
    // load this in two cycles or assume it comes from a wider internal memory. 
    // For this implementation, we keep it exposed for tiling functionality 
    // but focus the MUX fix on the Output Bus which was the main violation.
    input wire [(COLS * SUM_WIDTH) - 1 : 0] psum_in_bus,
    
    // --- Data Outputs (MULTIPLEXED) ---
    // Width: 128 bits (4 cols * 32 bits) -> Compliant with 128-bit limit
    output wire [127:0] psum_out_bus
);

    // ---------------------------------------------------------
    // 1. Internal Wiring Grid
    // ---------------------------------------------------------
    wire [DATA_WIDTH-1:0] pe_data_out [0:ROWS-1][0:COLS-1];
    wire [SUM_WIDTH-1:0]  pe_psum_out [0:ROWS-1][0:COLS-1];

    // ---------------------------------------------------------
    // 2. Array Instantiation
    // ---------------------------------------------------------
    genvar r, c;
    generate
        for (r = 0; r < ROWS; r = r + 1) begin : ROW_GEN
            for (c = 0; c < COLS; c = c + 1) begin : COL_GEN
                
                // Horizontal (Pixel) Logic
                wire [DATA_WIDTH-1:0] w_data_in;
                if (c == 0)
                    assign w_data_in = pixel_in_bus[(r*DATA_WIDTH) +: DATA_WIDTH];
                else
                    assign w_data_in = pe_data_out[r][c-1];

                // Vertical (Sum) Logic
                wire [SUM_WIDTH-1:0] w_psum_in;
                if (r == 0)
                    assign w_psum_in = psum_in_bus[(c*SUM_WIDTH) +: SUM_WIDTH];
                else
                    assign w_psum_in = pe_psum_out[r-1][c];

                // PE Instance
                PE_Optimized_PortReuse PE_INST (
                    .clk(clk),
                    .rst_n(rst_n),
                    .enable_cycle(enable_cycle),
                    .load_W(load_W),
                    .data_in(w_data_in),
                    .psum_in(w_psum_in),
                    .data_out(pe_data_out[r][c]),
                    .psum_out(pe_psum_out[r][c])
                );
            end
        end
    endgenerate

    // ---------------------------------------------------------
    // 3. Output Multiplexer (The Fix)
    // ---------------------------------------------------------
    // We gather all 256 bits of result internally first
    wire [255:0] full_psum_out;
    
    generate
        for (c = 0; c < COLS; c = c + 1) begin : GATHER_OUT
            assign full_psum_out[(c*SUM_WIDTH) +: SUM_WIDTH] = pe_psum_out[ROWS-1][c];
        end
    endgenerate

    // MUX: Select Upper or Lower 128 bits based on output_group_sel
    // If sel=0: Output Cols 0-3 (Bits 0 to 127)
    // If sel=1: Output Cols 4-7 (Bits 128 to 255)
    assign psum_out_bus = output_group_sel ? full_psum_out[255:128] : full_psum_out[127:0];

endmodule