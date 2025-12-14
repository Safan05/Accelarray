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

    // 1. Unified Loading & Pass-Through Logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            W_local_reg <= 8'b0;
            data_out    <= 8'b0;
            psum_out    <= 32'b0;
        end else if (enable_cycle) begin
            // Pass-Through: Data always moves West -> East
            data_out <= data_in; 

            if (load_W) begin
                // Load Mode: Capture Weight, Pass Psum unchanged
                W_local_reg <= data_in; 
                psum_out    <= psum_in;
            end else begin
                // Compute Mode: Single Cycle MAC
                // The result is ready at the next positive edge (1 Cycle Latency)
                psum_out <= psum_in + (data_in * W_local_reg);
            end
        end
    end

endmodule