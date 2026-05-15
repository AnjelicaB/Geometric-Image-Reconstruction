`ifndef AXCEL_TOP
`define AXCEL_TOP

module accelerator_top(
    input  logic        clk,
    input  logic        rst_n,
    input  logic [7:0]  stream_rgb,
    input  logic [31:0] stream_x,
    input  logic [31:0] stream_y,
    input  logic        stream_we,
    input  logic [31:0] x_0,
    input  logic [31:0] x_1,
    input  logic [31:0] x_2,
    input  logic [31:0] x_3,
    input  logic [31:0] y_0,
    input  logic [31:0] y_1,
    input  logic [31:0] y_2,
    input  logic [31:0] y_3,
    input  logic [31:0] n,
    input  logic [7:0]  color,
    input  logic [31:0] size_weight,
    input  logic        in_val,
    input  logic        out_ack,
    output logic        in_rdy,
    output logic        out_val,
    output logic [31:0] sse
);

    localparam int IMAGE_WIDTH = 320;
    localparam int IMAGE_HEIGHT = 480;
    localparam int VGA_WIDTH = 640;
    localparam int VGA_HEIGHT = 480;
    localparam int IMAGE_DEPTH = IMAGE_WIDTH * IMAGE_HEIGHT;

    logic [31:0] local_x;
    logic [31:0] local_y;
    logic [7:0]  m10k_rd_data;
    logic [18:0] stream_write_addr;
    logic [18:0] stream_read_addr;

    assign stream_write_addr = (stream_y * IMAGE_WIDTH) + stream_x;
    assign stream_read_addr = (local_y * IMAGE_WIDTH) + local_x - 32'd160;

    logic [7:0] muxed_color;
    // logic [1:0] counter;

    // always_ff @(posedge clk) begin
    //     if (! rst_n) counter <= '0;
    //     else if (counter >= 2'd2) begin
    //         counter <= '0;
    //     end else if (local_x < 32'd160 || local_x > 32'd479 || counter == 2'd1) begin
    //         counter <= counter + 1;
    //     end
    // end

    assign muxed_color = (local_x < 32'd160 || local_x > 32'd479) ? '0 : m10k_rd_data;

    M10K_8bit #(.DEPTH(IMAGE_DEPTH)) u_m10k (
        .q(m10k_rd_data),
        .d(stream_rgb),
        .write_address(stream_write_addr),
        .read_address(stream_read_addr),
        .we(stream_we),
        .clk(clk)
    );

    vga_polygon_accelerator u_accel (
        .clk(clk),
        .rst_n(rst_n),
        .in_val(in_val),
        .in_rdy(in_rdy),
        .out_val(out_val),
        .out_ack(out_ack),
        .x_0(x_0),
        .x_1(x_1),
        .x_2(x_2),
        .x_3(x_3),
        .y_0(y_0),
        .y_1(y_1),
        .y_2(y_2),
        .y_3(y_3),
        .n(n),
        .color(color),
        .size_weight(size_weight),
        .sse(sse),
        .local_x(local_x),
        .local_y(local_y),
        .m10k_rd_data(muxed_color)
    );

endmodule

`endif
