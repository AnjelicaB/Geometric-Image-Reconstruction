`ifndef M10K
`define M10K

module M10K_8bit #(
    parameter integer DEPTH = 1024,
    parameter integer ADDR_WIDTH = $clog2(DEPTH)
    )(
    output reg [7:0] q,
    input [7:0] d,
    input [ADDR_WIDTH-1:0] write_address, read_address,
    input we, clk
);

    // reg [7:0] temp;

   // force M10K ram style 8 bit x 1024
    reg [7:0] mem [DEPTH-1:0]  /* synthesis ramstyle = "no_rw_check, M10K" */;
   
    always @ (posedge clk) begin
        if (we) begin
            mem[write_address] <= d;
        end
        // temp <= mem[read_address];
        // q <= temp;
        q <= mem[read_address];
    end
endmodule

`endif
