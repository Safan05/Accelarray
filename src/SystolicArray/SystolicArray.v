module Systolic_Array_Top (
    input wire clk,
    input wire rst_n,
    
    // Control
    input wire enable_cycle,
    input wire load_W,          // 1 = Load Weights
    input wire accumulate_mode, // 0 = Overwrite (First Tile), 1 = Add (Next Tiles)
    input wire capture_en,      // 1 = Capture results into buffer

    // Data Inputs
    input wire [63:0] row_inputs, // 8 Rows packed
    
    // Data Outputs
    input wire [2:0] col_sel,     // Select column to read
    output wire [31:0] sram_data_out
);

    // Internal Wires
    wire [7:0]  w_horiz [0:7][0:8];
    wire [31:0] w_vert  [0:8][0:7];

    // =========================================================
    // 1. Instantiate 8x8 Array
    // =========================================================
    genvar r, c;
    generate
        // Drive Left Edge
        for (r = 0; r < 8; r = r + 1) begin : LEFT
            assign w_horiz[r][0] = row_inputs[(r*8)+7 : (r*8)];
        end
        // Drive Top Edge (0)
        for (c = 0; c < 8; c = c + 1) begin : TOP
            assign w_vert[0][c] = 32'b0;
        end

        // The Grid
        for (r = 0; r < 8; r = r + 1) begin : ROW
            for (c = 0; c < 8; c = c + 1) begin : COL
                PE_Optimized_PortReuse pe (
                    .clk(clk), .rst_n(rst_n),
                    .enable_cycle(enable_cycle), .load_W(load_W),
                    .data_in(w_horiz[r][c]), .data_out(w_horiz[r][c+1]),
                    .psum_in(w_vert[r][c]),  .psum_out(w_vert[r+1][c])
                );
            end
        end
    endgenerate

    // =========================================================
    // 2. The Smart Accumulator Buffer
    // =========================================================
    // Connects to the bottom wires: w_vert[8][0..7]
    
    reg [31:0] buffer [0:7];
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for(i=0; i<8; i=i+1) buffer[i] <= 32'b0;
        end else if (capture_en) begin
            if (accumulate_mode == 0) begin
                // MODE 0: NEW TILE (Overwrite)
                buffer[0] <= w_vert[8][0];
                buffer[1] <= w_vert[8][1];
                buffer[2] <= w_vert[8][2];
                buffer[3] <= w_vert[8][3];
                buffer[4] <= w_vert[8][4];
                buffer[5] <= w_vert[8][5];
                buffer[6] <= w_vert[8][6];
                buffer[7] <= w_vert[8][7];
            end else begin
                // MODE 1: TILING (Add to existing)
                buffer[0] <= buffer[0] + w_vert[8][0];
                buffer[1] <= buffer[1] + w_vert[8][1];
                buffer[2] <= buffer[2] + w_vert[8][2];
                buffer[3] <= buffer[3] + w_vert[8][3];
                buffer[4] <= buffer[4] + w_vert[8][4];
                buffer[5] <= buffer[5] + w_vert[8][5];
                buffer[6] <= buffer[6] + w_vert[8][6];
                buffer[7] <= buffer[7] + w_vert[8][7];
            end
        end
    end

    // Readout Mux
    assign sram_data_out = buffer[col_sel];

endmodule