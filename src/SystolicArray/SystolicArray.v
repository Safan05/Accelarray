module systolic_array_8x8 (
    input wire clk,
    input wire rst_n,
    input wire enable_cycle,
    input wire load_W,          // 1 = Load Weight Mode, 0 = Compute Mode
    
    // Inputs: 8 Rows of Image Data (Unskewed inputs from AGU/SRAM)
    input wire [7:0] row_in_0, row_in_1, row_in_2, row_in_3, 
                     row_in_4, row_in_5, row_in_6, row_in_7,

    // Output: Final 32-bit Sum (Reduced from all 8 columns)
    output wire [31:0] final_result,
    output wire result_valid
);

    // ============================================================
    // 1. INPUT SKEW LOGIC (Triangle of Registers)
    // ============================================================
    // Row r needs r cycles of delay to align diagonally.
    
    reg [7:0] delay_regs [0:7][0:7]; // [Row][Depth]
    
    // *** FIX: Match the wire name used in assignments below ***
    wire [7:0] skewed_inputs [0:7];      
    
    integer i, j;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for(i=0; i<8; i=i+1)
                for(j=0; j<8; j=j+1) delay_regs[i][j] <= 8'b0;
        end else if (enable_cycle) begin
            // Stage 0 always takes the fresh input
            delay_regs[0][0] <= row_in_0;
            delay_regs[1][0] <= row_in_1;
            delay_regs[2][0] <= row_in_2;
            delay_regs[3][0] <= row_in_3;
            delay_regs[4][0] <= row_in_4;
            delay_regs[5][0] <= row_in_5;
            delay_regs[6][0] <= row_in_6;
            delay_regs[7][0] <= row_in_7;
            
            // Shift older values down the line
            for(i=0; i<8; i=i+1) begin
                for(j=1; j<8; j=j+1) begin
                    delay_regs[i][j] <= delay_regs[i][j-1];
                end
            end
        end
    end

    // Map the specific delay tap to the array input
    assign skewed_inputs[0] = row_in_0;         
    assign skewed_inputs[1] = delay_regs[1][0]; // 1 cycle delay
    assign skewed_inputs[2] = delay_regs[2][1]; // 2 cycles delay
    assign skewed_inputs[3] = delay_regs[3][2];
    assign skewed_inputs[4] = delay_regs[4][3];
    assign skewed_inputs[5] = delay_regs[5][4];
    assign skewed_inputs[6] = delay_regs[6][5];
    assign skewed_inputs[7] = delay_regs[7][6]; // 7 cycles delay

    // ============================================================
    // 2. THE 8x8 ARRAY INSTANTIATION
    // ============================================================
    
    wire [7:0]  pixel_wire [0:7][0:8]; 
    wire [31:0] psum_wire  [0:8][0:7]; 

    // Drive Left Edge (West inputs) with Skewed Data
    genvar r, c;
    generate
        for (r=0; r<8; r=r+1) assign pixel_wire[r][0] = skewed_inputs[r];
        for (c=0; c<8; c=c+1) assign psum_wire[0][c]  = 32'b0; // Top PSUMs are 0
    endgenerate

    generate
        for (r = 0; r < 8; r = r + 1) begin : ROWS
            for (c = 0; c < 8; c = c + 1) begin : COLS
                
                PE_Optimized_PortReuse pe_inst (
                    .clk(clk),
                    .rst_n(rst_n),
                    .enable_cycle(enable_cycle),
                    .load_W(load_W),
                    
                    // Unified Data Port (Acts as Weight Load or Pixel Stream)
                    .data_in(pixel_wire[r][c]),
                    .psum_in(psum_wire[r][c]),
                    
                    // Outputs
                    .data_out(pixel_wire[r][c+1]),
                    .psum_out(psum_wire[r+1][c])
                );
                
            end
        end
    endgenerate

    // ============================================================
    // 3. OUTPUT REDUCTION CHAIN (Systolic Summation)
    // ============================================================
    
    wire [31:0] col_out [0:7];
    for(c=0; c<8; c=c+1) assign col_out[c] = psum_wire[8][c];

    reg [31:0] chain_sum [0:7];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for(i=0; i<8; i=i+1) chain_sum[i] <= 32'b0;
        end else if (enable_cycle) begin
            // Pipeline Stage 0: Capture Column 0
            chain_sum[0] <= col_out[0];

            // Pipeline Stages 1-7: Add Current Col + Previous Sum
            chain_sum[1] <= col_out[1] + chain_sum[0];
            chain_sum[2] <= col_out[2] + chain_sum[1];
            chain_sum[3] <= col_out[3] + chain_sum[2];
            chain_sum[4] <= col_out[4] + chain_sum[3];
            chain_sum[5] <= col_out[5] + chain_sum[4];
            chain_sum[6] <= col_out[6] + chain_sum[5];
            chain_sum[7] <= col_out[7] + chain_sum[6];
        end
    end

    // Final Output
    assign final_result = chain_sum[7];

    // Optional Valid Signal (delayed version of load_W or start signal)
    reg [15:0] valid_sr;
    always @(posedge clk) begin
        if (enable_cycle) valid_sr <= {valid_sr[14:0], !load_W};
    end
    assign result_valid = valid_sr[15];

endmodule