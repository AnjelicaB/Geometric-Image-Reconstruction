`ifndef AXCEL_TOP
`define AXCEL_TOP

module accelerator_top #(
    parameter int NUM_ITERATORS = 8
) (
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
    localparam int BANK_DEPTH = (IMAGE_DEPTH + NUM_ITERATORS - 1) / NUM_ITERATORS; // only works for powers of 2
    localparam int BANK_ADDR_WIDTH = $clog2(BANK_DEPTH); // find the number of bits needed to address the bank depth
    localparam int PARTITION_IDX_WIDTH = (NUM_ITERATORS <= 1) ? 1 : $clog2(NUM_ITERATORS);

    logic [NUM_ITERATORS-1:0][31:0] local_x;
    logic [31:0]                    local_y;
    logic [NUM_ITERATORS-1:0][7:0]  bank_rd_data;
    logic [NUM_ITERATORS-1:0][7:0]  partition_rd_data;

    logic [31:0] stream_flattened_addr;
    logic [31:0] stream_bank_idx;
    logic [BANK_ADDR_WIDTH-1:0] stream_bank_addr;

    logic [NUM_ITERATORS-1:0] partition_in_image;
    logic [NUM_ITERATORS-1:0][31:0] partition_flattened_addr;
    logic [NUM_ITERATORS-1:0][31:0] partition_bank_idx;
    logic [NUM_ITERATORS-1:0][BANK_ADDR_WIDTH-1:0] partition_bank_addr;

    logic [NUM_ITERATORS-1:0] bank_rd_valid;
    logic [NUM_ITERATORS-1:0] bank_rd_valid_d1;
    logic [NUM_ITERATORS-1:0][BANK_ADDR_WIDTH-1:0] bank_rd_addr;
    logic [NUM_ITERATORS-1:0][PARTITION_IDX_WIDTH-1:0] bank_partition;
    logic [NUM_ITERATORS-1:0][PARTITION_IDX_WIDTH-1:0] bank_partition_d1;

    assign stream_flattened_addr = (stream_y * IMAGE_WIDTH) + stream_x;
    assign stream_bank_idx = stream_flattened_addr % NUM_ITERATORS;
    assign stream_bank_addr = stream_flattened_addr / NUM_ITERATORS;

    genvar partition;
    generate
        for (partition = 0; partition < NUM_ITERATORS; partition = partition + 1) begin : g_partition_addr
            assign partition_in_image[partition] =
                (local_x[partition] >= 32'd160) &&
                (local_x[partition] <= 32'd479) &&
                (local_y < IMAGE_HEIGHT);

            assign partition_flattened_addr[partition] =
                partition_in_image[partition] ?
                    ((local_y * IMAGE_WIDTH) + (local_x[partition] - 32'd160)) :
                    32'd0;

            assign partition_bank_idx[partition] = partition_flattened_addr[partition] % NUM_ITERATORS; // modulo NUM_ITERATORS to find the correct bank index
            assign partition_bank_addr[partition] = partition_flattened_addr[partition] / NUM_ITERATORS;
        end
    endgenerate

    always_comb begin
        int partition_idx;
        int bank_idx;

        bank_rd_valid = '0;
        bank_rd_addr = '0;
        bank_partition = '0;

        // For each partition, if it's in the image, set the corresponding bank read valid and address signals
        for (partition_idx = 0; partition_idx < NUM_ITERATORS; partition_idx = partition_idx + 1) begin
            if (partition_in_image[partition_idx]) begin
                bank_rd_valid[partition_bank_idx[partition_idx]] = 1'b1;
                bank_rd_addr[partition_bank_idx[partition_idx]] = partition_bank_addr[partition_idx];
                bank_partition[partition_bank_idx[partition_idx]] = partition_idx;
            end
        end

        partition_rd_data = '0;
        for (bank_idx = 0; bank_idx < NUM_ITERATORS; bank_idx = bank_idx + 1) begin
            if (bank_rd_valid_d1[bank_idx])
                partition_rd_data[bank_partition_d1[bank_idx]] = bank_rd_data[bank_idx];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bank_rd_valid_d1 <= '0;
            bank_partition_d1 <= '0;
        end else begin
            bank_rd_valid_d1 <= bank_rd_valid;
            bank_partition_d1 <= bank_partition;
        end
    end

    genvar bank;
    generate
        for (bank = 0; bank < NUM_ITERATORS; bank = bank + 1) begin : g_m10k_bank
            M10K_8bit #(.DEPTH(BANK_DEPTH)) u_m10k (
                .q(bank_rd_data[bank]),
                .d(stream_rgb),
                .write_address(stream_bank_addr),
                .read_address(bank_rd_addr[bank]),
                .we(stream_we && (stream_bank_idx == bank)),
                .clk(clk)
            );
        end
    endgenerate

    vga_polygon_accelerator #(
        .WINDOW_WIDTH(VGA_WIDTH),
        .WINDOW_HEIGHT(VGA_HEIGHT),
        .NUM_ITERATORS(NUM_ITERATORS)
    ) u_accel (
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
        .m10k_rd_data(partition_rd_data)
    );

endmodule

`endif
