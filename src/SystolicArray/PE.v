module PE_Optimized_PortReuse (
    input wire clk,
    input wire rst_n,
    input wire enable_cycle,
    input wire load_W,          // 1 = Load Mode, 0 = Compute Mode

    // Unified Input (Reuse for both Weight and Pixel)
    input wire [7:0] data_in,   // Connects to 'pixel_in' wire from West
    input wire [31:0] psum_in, 

    output reg [7:0] data_out,  // Connects to 'pixel_in' of East Neighbor
    output reg [31:0] psum_out
);

    // Internal Storage
    reg [7:0]  W_local_reg;
    reg [15:0] product_reg;
    reg [31:0] psum_in_reg;
    reg [31:0] psum_accum_reg;

    // 1. Unified Loading & Pass-Through Logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            W_local_reg <= 8'b0;
            data_out    <= 8'b0;
        end else if (enable_cycle) begin

            // Pass-Through: Data always moves West -> East (for Shift or Streaming)
            data_out <= data_in; 

            // Weight Latching
            if (load_W) begin
                W_local_reg <= data_in; // Capture the incoming data as Weight
            end
        end
    end

    // 2. Compute Logic (Only valid when load_W = 0)
    // Note: We multiply 'data_in' (current pixel) by 'W_local_reg' (stored weight)
    wire [15:0] product_comb = data_in * W_local_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            product_reg <= 16'b0;
            psum_in_reg <= 32'b0;
            psum_accum_reg <= 32'b0;
            psum_out <= 32'b0;
        end else if (enable_cycle) begin
            // Pipeline Stage 1
            product_reg <= product_comb;
            psum_in_reg <= psum_in;

            // Pipeline Stage 2 & Output
            if (!load_W) begin
                psum_accum_reg <= psum_in_reg + {{16{1'b0}}, product_reg};
                psum_out <= psum_accum_reg;
            end
        end
    end

endmodule