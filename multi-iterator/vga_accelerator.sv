`ifndef VGA_POLYGON_AXCEL
`define VGA_POLYGON_AXCEL

module vga_polygon_accelerator #(
    parameter int WINDOW_WIDTH = 640,
    parameter int WINDOW_HEIGHT = 480,
    parameter int NUM_ITERATORS = 16
) (
    input  logic        clk,
    input  logic        rst_n,

    // Handshake
    input  logic        in_val,
    output logic        in_rdy,
    output logic        out_val,
    input  logic        out_ack,

    // Polygon Inputs
    input  logic [31:0] x_0, x_1, x_2, x_3,
    input  logic [31:0] y_0, y_1, y_2, y_3,
    input  logic [31:0] n,
    input  logic [7:0]  color,
    input  logic [31:0] size_weight,

    // Output
    output logic [31:0] sse,

    // One read partition per iterator/M10K bank
    output logic [NUM_ITERATORS-1:0][31:0] local_x,
    output logic [31:0]                    local_y,
    input  logic [NUM_ITERATORS-1:0][7:0]  m10k_rd_data
);

    localparam logic signed [31:0] X_MIN = 32'sd0;
    localparam logic signed [31:0] X_MAX = WINDOW_WIDTH - 1;
    localparam logic signed [31:0] Y_MIN = 32'sd0;
    localparam logic signed [31:0] Y_MAX = WINDOW_HEIGHT - 1;

    localparam logic [31:0] FP_16384 = 32'h4680_0000;

    typedef enum logic [3:0] {
        IDLE,
        FIND_BOUNDS,
        CALC_EDGES,
        ROW_START,
        SORT_HITS,
        PIXEL_PIPELINE,
        UPDATE_EDGES,
        CALC_SCORE,
        CALC_SCORE_WAIT_1,
        CALC_SCORE_WAIT_2,
        CALC_SCORE_WAIT_3,
        DONE
    } state_t;

    state_t state;

    logic [2:0]         n_vertices;
    logic signed [31:0] current_row;
    logic signed [31:0] max_y;

    logic [31:0]        req_col [0:NUM_ITERATORS-1];
    logic [31:0]        col_end;
    logic [31:0]        row_pixels_expected;
    logic [31:0]        row_pixels_received;
    logic               valid_pipe [0:NUM_ITERATORS-1];

    logic signed [31:0] px [0:3];
    logic signed [31:0] py [0:3];
    logic [31:0]        W;

    logic signed [31:0] edge_y_min [0:3];
    logic signed [31:0] edge_y_max [0:3];
    logic signed [31:0] edge_x     [0:3];
    logic [31:0]        edge_dx_abs[0:3];
    logic [31:0]        edge_dy    [0:3];
    logic signed [1:0]  edge_x_step[0:3];
    logic [31:0]        edge_err   [0:3];
    logic               edge_valid [0:3];

    logic signed [31:0] row_hits_unsorted [0:3];
    logic signed [31:0] row_hits_sorted   [0:3];
    logic [2:0]         row_num_hits;

    logic [2:0]         upd_edge_idx;
    logic               upd_edge_busy;
    logic signed [31:0] upd_x_work;
    logic [31:0]        upd_err_work;
    logic [31:0]        upd_dy_work;
    logic signed [1:0]  upd_step_work;

    logic [2:0] r1, g1;
    logic [1:0] b1;
    logic [2:0] r2 [0:NUM_ITERATORS-1];
    logic [2:0] g2 [0:NUM_ITERATORS-1];
    logic [1:0] b2 [0:NUM_ITERATORS-1];
    logic [7:0] scaled_r1, scaled_g1, scaled_b1;
    logic [7:0] scaled_r2 [0:NUM_ITERATORS-1];
    logic [7:0] scaled_g2 [0:NUM_ITERATORS-1];
    logic [7:0] scaled_b2 [0:NUM_ITERATORS-1];
    logic signed [8:0] diff_r [0:NUM_ITERATORS-1];
    logic signed [8:0] diff_g [0:NUM_ITERATORS-1];
    logic signed [8:0] diff_b [0:NUM_ITERATORS-1];
    logic [31:0]       current_pixel_sse [0:NUM_ITERATORS-1];
    logic [63:0]       cycle_sse_sum;
    logic [31:0]       cycle_pixel_count;
    logic [63:0]       sse_accum;
    logic [31:0]       pixel_count;

    logic [31:0] sse_accum_fp;
    logic [31:0] pixel_count_fp;
    logic [31:0] weighted_area_scale_fp;
    logic [31:0] area_term_fp;
    logic [31:0] score_fp;

    // Function to clamp x coordinate to the window boundaries
    function automatic [31:0] clamp_x_to_window;
        input logic signed [31:0] x_in;
        begin
            if (x_in < X_MIN)
                clamp_x_to_window = 32'd0;
            else if (x_in > X_MAX)
                clamp_x_to_window = WINDOW_WIDTH - 1;
            else
                clamp_x_to_window = x_in[31:0];
        end
    endfunction

    assign {r1, g1, b1} = color;
    assign scaled_r1 = {5'b0, r1} * 8'd36;
    assign scaled_g1 = {5'b0, g1} * 8'd36;
    assign scaled_b1 = {6'b0, b1} * 8'd85;
    assign local_y = current_row[31:0];

    genvar partition;
    generate
        for (partition = 0; partition < NUM_ITERATORS; partition = partition + 1) begin : g_pixel_partition
            assign local_x[partition] = req_col[partition];
            assign {r2[partition], g2[partition], b2[partition]} = m10k_rd_data[partition];
            assign scaled_r2[partition] = {5'b0, r2[partition]} * 8'd36;
            assign scaled_g2[partition] = {5'b0, g2[partition]} * 8'd36;
            assign scaled_b2[partition] = {6'b0, b2[partition]} * 8'd85;
            assign diff_r[partition] = $signed({1'b0, scaled_r1}) - $signed({1'b0, scaled_r2[partition]});
            assign diff_g[partition] = $signed({1'b0, scaled_g1}) - $signed({1'b0, scaled_g2[partition]});
            assign diff_b[partition] = $signed({1'b0, scaled_b1}) - $signed({1'b0, scaled_b2[partition]});
            assign current_pixel_sse[partition] =
                (diff_r[partition] * diff_r[partition]) +
                (diff_g[partition] * diff_g[partition]) +
                (diff_b[partition] * diff_b[partition]);
        end
    endgenerate

    always_comb begin
        int e;

        row_num_hits = 3'd0;
        for (e = 0; e < 4; e = e + 1)
            row_hits_unsorted[e] = 32'sd0;

        for (e = 0; e < 4; e = e + 1) begin
            if (edge_valid[e] && (current_row >= edge_y_min[e]) && (current_row < edge_y_max[e])) begin
                row_hits_unsorted[row_num_hits] = edge_x[e];
                row_num_hits = row_num_hits + 3'd1;
            end
        end
    end

    always_comb begin
        int i, j;
        logic signed [31:0] t;

        for (i = 0; i < 4; i = i + 1)
            row_hits_sorted[i] = row_hits_unsorted[i];

        for (i = 0; i < 3; i = i + 1) begin
            for (j = i + 1; j < 4; j = j + 1) begin
                if ((j < row_num_hits) && (row_hits_sorted[j] < row_hits_sorted[i])) begin
                    t = row_hits_sorted[i];
                    row_hits_sorted[i] = row_hits_sorted[j];
                    row_hits_sorted[j] = t;
                end
            end
        end
    end

    always_comb begin
        int partition_idx;

        cycle_sse_sum = 64'd0;
        cycle_pixel_count = 32'd0;
        for (partition_idx = 0; partition_idx < NUM_ITERATORS; partition_idx = partition_idx + 1) begin
            if (valid_pipe[partition_idx]) begin
                cycle_sse_sum = cycle_sse_sum + current_pixel_sse[partition_idx];
                cycle_pixel_count = cycle_pixel_count + 32'd1;
            end
        end
    end

    UInt64ToFp cvt_sse_accum (
        .iUnsigned(sse_accum),
        .oA(sse_accum_fp)
    );

    UInt32ToFp cvt_pixel_count (
        .iUnsigned(pixel_count),
        .oA(pixel_count_fp)
    );

    FpMul mul_weighted_area_scale (
        .iA(W),
        .iB(FP_16384),
        .oProd(weighted_area_scale_fp)
    );

    FpMul mul_area_term (
        .iA(weighted_area_scale_fp),
        .iB(pixel_count_fp),
        .oProd(area_term_fp)
    );

    FpAdd sub_final_score (
        .iCLK(clk),
        .iA(sse_accum_fp),
        .iB({~area_term_fp[31], area_term_fp[30:0]}),
        .oSum(score_fp)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        int i, j, partition_idx;
        logic signed [31:0] min_y_local, max_y_local;
        logic signed [31:0] x_a, x_b, y_a, y_b;
        logic signed [31:0] dx_local, x_start_local, y_min_local, y_max_local;
        logic [31:0]        dy_local;
        logic [31:0]        col_start_local;
        logic [31:0]        col_end_local;

        if (!rst_n) begin
            state <= IDLE;
            in_rdy <= 1'b1;
            out_val <= 1'b0;
            sse <= 32'd0;
            sse_accum <= 64'd0;
            pixel_count <= 32'd0;
            current_row <= 32'sd0;
            max_y <= 32'sd0;
            col_end <= 32'd0;
            row_pixels_expected <= 32'd0;
            row_pixels_received <= 32'd0;
            W <= 32'd0;
            n_vertices <= 3'd0;
            upd_edge_idx <= 3'd0;
            upd_edge_busy <= 1'b0;
            upd_x_work <= 32'sd0;
            upd_err_work <= 32'd0;
            upd_dy_work <= 32'd0;
            upd_step_work <= 2'sd0;

            for (partition_idx = 0; partition_idx < NUM_ITERATORS; partition_idx = partition_idx + 1) begin
                req_col[partition_idx] <= 32'd0;
                valid_pipe[partition_idx] <= 1'b0;
            end

            for (i = 0; i < 4; i = i + 1) begin
                px[i] <= 32'sd0;
                py[i] <= 32'sd0;
                edge_y_min[i] <= 32'sd0;
                edge_y_max[i] <= 32'sd0;
                edge_x[i] <= 32'sd0;
                edge_dx_abs[i] <= 32'd0;
                edge_dy[i] <= 32'd0;
                edge_x_step[i] <= 2'sd0;
                edge_err[i] <= 32'd0;
                edge_valid[i] <= 1'b0;
            end
        end else begin
            case (state)
                IDLE: begin
                    out_val <= 1'b0;
                    for (partition_idx = 0; partition_idx < NUM_ITERATORS; partition_idx = partition_idx + 1)
                        valid_pipe[partition_idx] <= 1'b0;

                    if (in_val && in_rdy) begin
                        in_rdy <= 1'b0;
                        px[0] <= x_0; px[1] <= x_1; px[2] <= x_2; px[3] <= x_3;
                        py[0] <= y_0; py[1] <= y_1; py[2] <= y_2; py[3] <= y_3;
                        n_vertices <= (n < 3) ? 3'd0 : ((n > 4) ? 3'd4 : n[2:0]);
                        W <= size_weight;
                        sse_accum <= 64'd0;
                        pixel_count <= 32'd0;
                        row_pixels_received <= 32'd0;
                        upd_edge_idx <= 3'd0;
                        upd_edge_busy <= 1'b0;
                        state <= FIND_BOUNDS;
                    end
                end

                FIND_BOUNDS: begin
                    if (n_vertices < 3) begin
                        current_row <= 32'sd0;
                        max_y <= -32'sd1;
                    end else begin
                        min_y_local = py[0];
                        max_y_local = py[0];
                        for (i = 1; i < 4; i = i + 1) begin
                            if (i < n_vertices) begin
                                if (py[i] < min_y_local)
                                    min_y_local = py[i];
                                if (py[i] > max_y_local)
                                    max_y_local = py[i];
                            end
                        end

                        if (min_y_local < Y_MIN)
                            min_y_local = Y_MIN;
                        if (max_y_local > Y_MAX)
                            max_y_local = Y_MAX;

                        current_row <= min_y_local;
                        max_y <= max_y_local;
                    end
                    state <= CALC_EDGES;
                end

                CALC_EDGES: begin
                    for (i = 0; i < 4; i = i + 1) begin
                        edge_valid[i] <= 1'b0;
                        edge_y_min[i] <= 32'sd0;
                        edge_y_max[i] <= 32'sd0;
                        edge_x[i] <= 32'sd0;
                        edge_dx_abs[i] <= 32'd0;
                        edge_dy[i] <= 32'd0;
                        edge_x_step[i] <= 2'sd0;
                        edge_err[i] <= 32'd0;
                    end

                    for (i = 0; i < 4; i = i + 1) begin
                        if (i < n_vertices) begin
                            j = (i == 0) ? (n_vertices - 1) : (i - 1);

                            x_a = px[j];
                            y_a = py[j];
                            x_b = px[i];
                            y_b = py[i];

                            if (y_a < y_b) begin
                                y_min_local = y_a;
                                y_max_local = y_b;
                                x_start_local = x_a;
                                dx_local = x_b - x_a;
                                dy_local = y_b - y_a;
                            end else begin
                                y_min_local = y_b;
                                y_max_local = y_a;
                                x_start_local = x_b;
                                dx_local = x_a - x_b;
                                dy_local = y_a - y_b;
                            end

                            if (dy_local != 0) begin
                                edge_valid[i] <= 1'b1;
                                edge_y_min[i] <= y_min_local;
                                edge_y_max[i] <= y_max_local;
                                edge_x[i] <= x_start_local;
                                edge_dx_abs[i] <= dx_local[31] ? -dx_local : dx_local;
                                edge_dy[i] <= dy_local;
                                edge_x_step[i] <= (dx_local < 0) ? -2'sd1 : 2'sd1;
                                edge_err[i] <= 32'd0;
                            end
                        end
                    end

                    state <= ROW_START;
                end

                ROW_START: begin
                    if (current_row > max_y)
                        state <= CALC_SCORE;
                    else
                        state <= SORT_HITS;
                end

                SORT_HITS: begin
                    for (partition_idx = 0; partition_idx < NUM_ITERATORS; partition_idx = partition_idx + 1)
                        valid_pipe[partition_idx] <= 1'b0;

                    if (row_num_hits < 2) begin
                        upd_edge_idx <= 3'd0;
                        upd_edge_busy <= 1'b0;
                        state <= UPDATE_EDGES;
                    end else if ((current_row < Y_MIN) || (current_row > Y_MAX)) begin
                        upd_edge_idx <= 3'd0;
                        upd_edge_busy <= 1'b0;
                        state <= UPDATE_EDGES;
                    end else if ((row_hits_sorted[1] < X_MIN) || (row_hits_sorted[0] > X_MAX)) begin
                        upd_edge_idx <= 3'd0;
                        upd_edge_busy <= 1'b0;
                        state <= UPDATE_EDGES;
                    end else begin
                        col_start_local = clamp_x_to_window(row_hits_sorted[0]);
                        col_end_local = clamp_x_to_window(row_hits_sorted[1]);

                        col_end <= col_end_local;
                        row_pixels_expected <= (col_end_local - col_start_local) + 32'd1;
                        row_pixels_received <= 32'd0;

                        for (partition_idx = 0; partition_idx < NUM_ITERATORS; partition_idx = partition_idx + 1)
                            req_col[partition_idx] <= col_start_local + partition_idx;

                        state <= PIXEL_PIPELINE;
                    end
                end

                PIXEL_PIPELINE: begin
                    if (cycle_pixel_count != 32'd0) begin
                        sse_accum <= sse_accum + cycle_sse_sum;
                        pixel_count <= pixel_count + cycle_pixel_count;
                        row_pixels_received <= row_pixels_received + cycle_pixel_count;
                    end

                    for (partition_idx = 0; partition_idx < NUM_ITERATORS; partition_idx = partition_idx + 1) begin
                        if (req_col[partition_idx] <= col_end) begin
                            valid_pipe[partition_idx] <= 1'b1;
                            req_col[partition_idx] <= req_col[partition_idx] + NUM_ITERATORS;
                        end else begin
                            valid_pipe[partition_idx] <= 1'b0;
                        end
                    end

                    if ((row_pixels_received + cycle_pixel_count) == row_pixels_expected) begin
                        for (partition_idx = 0; partition_idx < NUM_ITERATORS; partition_idx = partition_idx + 1)
                            valid_pipe[partition_idx] <= 1'b0;
                        upd_edge_idx <= 3'd0;
                        upd_edge_busy <= 1'b0;
                        state <= UPDATE_EDGES;
                    end
                end

                UPDATE_EDGES: begin
                    if (!upd_edge_busy) begin
                        if (upd_edge_idx >= 4) begin
                            current_row <= current_row + 32'sd1;
                            state <= ROW_START;
                        end else if (edge_valid[upd_edge_idx] &&
                                     (current_row >= edge_y_min[upd_edge_idx]) &&
                                     ((current_row + 32'sd1) < edge_y_max[upd_edge_idx])) begin
                            upd_edge_busy <= 1'b1;
                            upd_x_work <= edge_x[upd_edge_idx];
                            upd_err_work <= edge_err[upd_edge_idx] + edge_dx_abs[upd_edge_idx];
                            upd_dy_work <= edge_dy[upd_edge_idx];
                            upd_step_work <= edge_x_step[upd_edge_idx];
                        end else begin
                            upd_edge_idx <= upd_edge_idx + 3'd1;
                        end
                    end else begin
                        if (upd_err_work >= upd_dy_work) begin
                            upd_err_work <= upd_err_work - upd_dy_work;
                            upd_x_work <= upd_x_work + upd_step_work;
                        end else begin
                            edge_x[upd_edge_idx] <= upd_x_work;
                            edge_err[upd_edge_idx] <= upd_err_work;
                            upd_edge_busy <= 1'b0;
                            upd_edge_idx <= upd_edge_idx + 3'd1;
                        end
                    end
                end

                CALC_SCORE: begin
                    state <= CALC_SCORE_WAIT_1;
                end

                CALC_SCORE_WAIT_1: begin
                    state <= CALC_SCORE_WAIT_2;
                end

                CALC_SCORE_WAIT_2: begin
                    state <= CALC_SCORE_WAIT_3;
                end

                CALC_SCORE_WAIT_3: begin
                    sse <= score_fp;
                    out_val <= 1'b1;
                    state <= DONE;
                end

                DONE: begin
                    if (out_ack) begin
                        state <= IDLE;
                        in_rdy <= 1'b1;
                        out_val <= 1'b0;
                        sse <= 32'd0;
                        sse_accum <= 64'd0;
                        pixel_count <= 32'd0;
                        current_row <= 32'sd0;
                        max_y <= 32'sd0;
                        col_end <= 32'd0;
                        row_pixels_expected <= 32'd0;
                        row_pixels_received <= 32'd0;
                        W <= 32'd0;
                        n_vertices <= 3'd0;
                        upd_edge_idx <= 3'd0;
                        upd_edge_busy <= 1'b0;
                        upd_x_work <= 32'sd0;
                        upd_err_work <= 32'd0;
                        upd_dy_work <= 32'd0;
                        upd_step_work <= 2'sd0;

                        for (partition_idx = 0; partition_idx < NUM_ITERATORS; partition_idx = partition_idx + 1) begin
                            req_col[partition_idx] <= 32'd0;
                            valid_pipe[partition_idx] <= 1'b0;
                        end

                        for (i = 0; i < 4; i = i + 1) begin
                            px[i] <= 32'sd0;
                            py[i] <= 32'sd0;
                            edge_y_min[i] <= 32'sd0;
                            edge_y_max[i] <= 32'sd0;
                            edge_x[i] <= 32'sd0;
                            edge_dx_abs[i] <= 32'd0;
                            edge_dy[i] <= 32'd0;
                            edge_x_step[i] <= 2'sd0;
                            edge_err[i] <= 32'd0;
                            edge_valid[i] <= 1'b0;
                        end
                    end
                end

                default: begin
                    state <= IDLE;
                end
            endcase
        end
    end

endmodule

`endif
