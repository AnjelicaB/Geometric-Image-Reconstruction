`ifndef VGA_POLYGON_AXCEL
`define VGA_POLYGON_AXCEL

// BEGIN AI ADJUSTED CODE ------>
module vga_polygon_accelerator  # (
    parameter WINDOW_WIDTH = 640,
    parameter WINDOW_HEIGHT = 480
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

    // Direct M10K Memory Interface
    // output logic [18:0] m10k_rd_addr,   // 19 bits needed for 640*480 = 307,200
    output logic [31:0] local_x,
    output logic [31:0] local_y,
    input  logic [7:0]  m10k_rd_data    // Pixel data arriving 2 cycles after address
);

    localparam logic signed [31:0] X_MIN = 32'sd0;
    localparam logic signed [31:0] X_MAX = WINDOW_WIDTH - 1;

    typedef enum logic [3:0] {
        IDLE,
        FIND_BOUNDS,
        CALC_EDGES,
        ROW_START,
        SORT_HITS,
        PIXEL_PIPELINE, // Replaces PIXEL_FILL and PIXEL_WAIT
        UPDATE_EDGES,
        CALC_SCORE,
        CALC_SCORE_WAIT_1,
        CALC_SCORE_WAIT_2,
        CALC_SCORE_WAIT_3,
        DONE
    } state_t;

    state_t state;

    // Coordinates
    logic [2:0]         n_vertices;
    logic signed [31:0] current_row, max_y;

    // Pipeline tracking variables
    logic [31:0]        req_col, col_end;
    logic [31:0]        row_pixels_expected;
    logic [31:0]        row_pixels_received;
    logic [1:0]         valid_pipe; // 2-bit shift register for M10K latency

    logic signed [31:0] px [0:3];
    logic signed [31:0] py [0:3];

    // Latched weight
    logic [31:0]        W;

    // Edge tracking for scanline
    logic signed [31:0] edge_y_min [0:3];
    logic signed [31:0] edge_y_max [0:3];
    logic signed [31:0] edge_x     [0:3];
    logic [31:0]        edge_dx_abs[0:3];
    logic [31:0]        edge_dy    [0:3];
    logic signed [1:0]  edge_x_step[0:3];
    logic [31:0]        edge_err   [0:3];
    logic               edge_valid [0:3];

    // Hit sorting for scanline
    logic signed [31:0] row_hits_unsorted [0:3];
    logic signed [31:0] row_hits_sorted   [0:3];
    logic [2:0]         row_num_hits;

    logic [2:0]         upd_edge_idx;
    logic               upd_edge_busy;
    logic signed [31:0] upd_x_work;
    logic [31:0]        upd_err_work;
    logic [31:0]        upd_dy_work;
    logic signed [1:0]  upd_step_work;

    // Combinational Color logic evaluates the data directly from M10K
    logic [2:0] r1, g1, r2, g2;
    logic [1:0] b1, b2;
    logic [7:0] scaled_r1, scaled_g1, scaled_b1, scaled_r2, scaled_g2, scaled_b2;
    
    logic signed [8:0] diff_r, diff_g;
    logic signed [8:0] diff_b;
    logic [31:0] current_pixel_sse;
    logic [63:0]        sse_accum;
    logic [31:0]        pixel_count;

    // Floating-point score datapath
    logic [31:0] w_fp;
    logic [31:0] one_minus_w_fp;
    logic [31:0] sse_accum_fp;
    logic [31:0] pixel_count_fp;
    logic [31:0] sse_term_fp;
    logic [31:0] area_term_fp;
    logic [31:0] neg_area_term_fp;
    logic [31:0] score_fp;

    localparam logic [31:0] FP_ONE = 32'h3f80_0000;
    localparam logic [31:0] FP_16384 = 32'h4680_0000;
    localparam logic [31:0] SSE_STRIDE = 32'd1; // was 


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
    assign {r2, g2, b2} = m10k_rd_data;
    assign scaled_r1 = {5'b0, r1} * 8'd36;
    assign scaled_g1 = {5'b0, g1} * 8'd36;
    assign scaled_b1 = {6'b0, b1} * 8'd85;
    assign scaled_r2 = {5'b0, r2} * 8'd36;
    assign scaled_g2 = {5'b0, g2} * 8'd36;
    assign scaled_b2 = {6'b0, b2} * 8'd85;
    assign diff_r = $signed({1'b0, scaled_r1}) - $signed({1'b0, scaled_r2});
    assign diff_g = $signed({1'b0, scaled_g1}) - $signed({1'b0, scaled_g2});
    assign diff_b = $signed({1'b0, scaled_b1}) - $signed({1'b0, scaled_b2});
    assign current_pixel_sse = (diff_r * diff_r) + (diff_g * diff_g) + (diff_b * diff_b);


    logic [31:0] W_int;
    Fp2Int32 Wint (
        .iA(W),
        .oInteger(W_int)
    );

    logic [31:0] int_16384;
    Fp2Int32 int16384 (
        .iA(FP_16384),
        .oInteger(int_16384)
    );

    logic signed [31:0] area_term_int;
    Fp2Int32 intarea (
        .iA(area_term_fp),
        .oInteger(area_term_int)
    );

    logic signed [31:0] score_int;
    Fp2Int32 scoreint (
        .iA(score_fp),
        .oInteger(score_int)
    );


	 /*
    always_ff @(posedge clk) begin
        if (state == PIXEL_PIPELINE && valid_pipe[1]) begin
            // $display("localx: %0d | localy: %0d", local_x, local_y);
            $display("v: %0d %0d %0d | %0d %0d %0d", scaled_r1, scaled_g1, scaled_b1, scaled_r2, scaled_g2, scaled_b2);
            $display("v: curr pixel sse = %0d (diff = %0d %0d %0d)", current_pixel_sse, diff_r, diff_g, diff_b);
            $display("v: curr accum sse = %0d %0x (f)", sse_accum, sse_accum_fp);
        end
        if (state == IDLE && in_val && in_rdy) begin
            $display("Starting new polygon with vertices:");
            $display("(%0d, %0d)", x_0, y_0);
            $display("(%0d, %0d)", x_1, y_1);
            $display("(%0d, %0d)", x_2, y_2);
            $display("(%0d, %0d)", x_3, y_3);
            $display("and size weight: %x", size_weight);
        end
        if (state == DONE && out_ack) begin
            $display("Full SSE: %0d %0x (f), pixel_count: %0d", score_int, (score_fp), pixel_count);
        end
        if (state == CALC_SCORE)begin
            $display("CALC SCORE: %0d * %0d * %0d = %d", int_16384, W_int, pixel_count, area_term_int);
            $display("CALC_SCORE: %0d - %0d = %0d %0x", sse_accum, area_term_int, score_int, score_fp);
        end
        if (state == CALC_SCORE_WAIT_1)begin
            $display("CALC_SCORE_WAIT_1: %0d * %0d * %0d = %d", int_16384, W_int, pixel_count, area_term_int);
            $display("CALC_SCORE_WAIT_1: %0d - %0d = %0d %0x", sse_accum, area_term_int, score_int, score_fp);
        end
        if (state == CALC_SCORE_WAIT_2)begin
            $display("CALC_SCORE_WAIT_2: %0d * %0d * %0d = %d", int_16384, W_int, pixel_count, area_term_int);
            $display("CALC_SCORE_WAIT_2: %0d - %0d = %0d %0x", sse_accum, area_term_int, score_int, score_fp);
        end
        if (state == CALC_SCORE_WAIT_3)begin
            $display("CALC_SCORE_WAIT_3: %0d * %0d * %0d = %d", int_16384, W_int, pixel_count, area_term_int);
            $display("CALC_SCORE_WAIT_3: %0d - %0d = %0d %0x", sse_accum, area_term_int, score_int, score_fp);
        end
    end
	 */

    always_comb begin
        int e;
        row_num_hits = 3'd0;
        for (e = 0; e < 4; e = e + 1) begin
            row_hits_unsorted[e] = 32'sd0;
        end

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

        for (i = 0; i < 4; i = i + 1) begin
            row_hits_sorted[i] = row_hits_unsorted[i];
        end

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

    assign local_x = req_col;
    assign local_y = current_row;

    logic [31:0] wait_counter;

    // Floating-point module instantiations
    UInt32ToFp cvt_sse_accum (
        .iUnsigned(sse_accum[31:0]),
        .oA(sse_accum_fp)
    );

    UInt32ToFp cvt_pixel_count (
        .iUnsigned(pixel_count),
        .oA(pixel_count_fp)
    );

    logic [31:0] weighted_area_scale_fp;
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
        .iB({~area_term_fp[31], area_term_fp[30:0]}),  // negate area term
        .oSum(score_fp)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        int i, j;
        logic signed [31:0] min_y_local, max_y_local;
        logic signed [31:0] x_a, x_b, y_a, y_b;
        logic signed [31:0] dx_local, x_start_local, y_min_local, y_max_local;
        logic [31:0]        dy_local;

        if (!rst_n) begin
            state <= IDLE;
            in_rdy <= 1'b1;
            out_val <= 1'b0;
            // m10k_rd_addr <= 19'd0;
            sse <= 32'd0;
            sse_accum <= 64'd0;
            pixel_count <= 32'd0;
            current_row <= 32'sd0;
            max_y <= 32'sd0;
            req_col <= 32'd0;
            col_end <= 32'd0;
            row_pixels_expected <= 32'd0;
            row_pixels_received <= 32'd0;
            valid_pipe <= 2'b00;
            W <= 32'd0;
            n_vertices <= 3'd0;
            upd_edge_idx <= 3'd0;
            upd_edge_busy <= 1'b0;
            upd_x_work <= 32'sd0;
            upd_err_work <= 32'd0;
            upd_dy_work <= 32'd0;
            upd_step_work <= 2'sd0;
            wait_counter <= 3'd0;
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
                    valid_pipe <= 2'b00;
                    if (in_val && in_rdy) begin
                        in_rdy <= 1'b0;
                        px[0] <= x_0; px[1] <= x_1; px[2] <= x_2; px[3] <= x_3;
                        py[0] <= y_0; py[1] <= y_1; py[2] <= y_2; py[3] <= y_3;
                        n_vertices <= (n < 3) ? 3'd0 : ((n > 4) ? 3'd4 : n[2:0]);
                        W <= size_weight;
                        sse_accum <= 64'd0;
                        pixel_count <= 32'd0;
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

                        // // Clamp vertical span to framebuffer 
                        if (min_y_local < 32'sd0)
                            min_y_local = 32'sd0;
                        if (max_y_local > signed'(WINDOW_HEIGHT - 1))
                            max_y_local = signed'(WINDOW_HEIGHT - 1);
    
                        current_row <= min_y_local;
                        max_y <= max_y_local;
                    end
                    state <= CALC_EDGES;
                end

                CALC_EDGES: begin
                    // Initialization loops omitted for brevity (same as previous)
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

                // Loop guard
                ROW_START: begin
                    if (current_row > max_y) state <= CALC_SCORE;
                    else state <= SORT_HITS;
                end

                SORT_HITS: begin
                    if (row_num_hits < 2) begin
                        upd_edge_idx <= 3'd0; upd_edge_busy <= 1'b0;
                        state <= UPDATE_EDGES;
                    end else if ((current_row < 0) || (current_row >= WINDOW_HEIGHT)) begin
                        // Skip memory requests entirely if the row is off-screen
                        upd_edge_idx <= 3'd0; upd_edge_busy <= 1'b0;
                        state <= UPDATE_EDGES;
                    end else begin
                        // Prepare the pipeline
                        req_col <= clamp_x_to_window(row_hits_sorted[0]);

                // SORT_HITS: begin
                //     if (row_num_hits < 2) begin
                //         upd_edge_idx <= 3'd0; upd_edge_busy <= 1'b0;
                //         state <= UPDATE_EDGES;
                //     end else if ((current_row < 0) || (current_row >= WINDOW_HEIGHT)) begin
                //         // Skip memory requests entirely if the row is off-screen
                //         upd_edge_idx <= 3'd0; upd_edge_busy <= 1'b0;
                //         state <= UPDATE_EDGES;
                        
                //     // ADD THIS BLOCK: Skip segment if it is entirely off-screen horizontally
                //     end else if ((row_hits_sorted[1] < X_MIN) || (row_hits_sorted[0] > X_MAX)) begin
                //         upd_edge_idx <= 3'd0; upd_edge_busy <= 1'b0;
                //         state <= UPDATE_EDGES;
                        
                //     end else begin
                //         // Prepare the pipeline
                //         req_col <= clamp_x_to_window(row_hits_sorted[0]);
                        // ... (rest of your logic)
                        col_end <= clamp_x_to_window(row_hits_sorted[1]);
                        
                        // Calculate total pixels we expect to pull from M10K for this row
                        // row_pixels_expected <= (clamp_x_to_window(row_hits_sorted[1]) - clamp_x_to_window(row_hits_sorted[0]))/SSE_STRIDE + 32'd1;
                        row_pixels_expected <= (clamp_x_to_window(row_hits_sorted[1]) - clamp_x_to_window(row_hits_sorted[0])) + 32'd1;
                        row_pixels_received <= 32'd0;
                        valid_pipe <= 2'b00;
                        state <= PIXEL_PIPELINE;
                    end
                end

                PIXEL_PIPELINE: begin
                    // 1. Issue Reads (Address Generation)
                    if (req_col <= col_end) begin
                        // m10k_rd_addr <= (current_row * WINDOW_WIDTH) + $signed(req_col);
                        valid_pipe <= {valid_pipe[0], 1'b1}; // Push a 1 into the latency pipeline
                        req_col <= req_col + SSE_STRIDE;
                    end else begin
                        valid_pipe <= {valid_pipe[0], 1'b0}; // Push a 0, we stopped requesting
                    end

                    // 2. Accumulate Results (Data returning 2 cycles later)
                    if (valid_pipe[1]) begin
                        sse_accum <= sse_accum + current_pixel_sse;
                        pixel_count <= pixel_count + 32'd1;
                        row_pixels_received <= row_pixels_received + 32'd1;
                    end

                    // 3. Exit Condition 
                    // We transition if the number of pixels we have fully processed (plus the 
                    // one processing exactly right now) equals our expected total.
                    if ((row_pixels_received + valid_pipe[1]) == row_pixels_expected) begin
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
                    end else begin // use division
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
                    // score_fp is now ready, latch it to output
                    sse <= score_fp;
                    state <= DONE;
                    out_val <= 1'b1;
                end

                DONE: begin
                    if (out_ack) begin
                        state <= IDLE;
                        in_rdy <= 1'b1;
                        out_val <= 1'b0;
                        // m10k_rd_addr <= 19'd0;
                        sse <= 32'd0;
                        sse_accum <= 64'd0;
                        pixel_count <= 32'd0;
                        current_row <= 32'sd0;
                        max_y <= 32'sd0;
                        req_col <= 32'd0;
                        col_end <= 32'd0;
                        row_pixels_expected <= 32'd0;
                        row_pixels_received <= 32'd0;
                        valid_pipe <= 2'b00;
                        W <= 32'd0;
                        n_vertices <= 3'd0;
                        upd_edge_idx <= 3'd0;
                        upd_edge_busy <= 1'b0;
                        upd_x_work <= 32'sd0;
                        upd_err_work <= 32'd0;
                        upd_dy_work <= 32'd0;
                        upd_step_work <= 2'sd0;
                        wait_counter <= 3'd0;
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

                default: state <= IDLE;
            endcase
        end
    end

endmodule
// <------ END AI ADJUSTED CODE

`endif
