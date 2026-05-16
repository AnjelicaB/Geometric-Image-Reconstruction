`ifndef FPUNIT
`define FPUNIT

// BEGIN AI ADJUSTED CODE ------>
module Int2Fp(
    input signed [15:0] iInteger,
    output      [31:0] oA
);
    wire       A_s;
    wire [7:0] A_e;
    wire [22:0] A_f;

    wire [15:0] abs_input;
    wire [4:0] msb_idx;
    wire [38:0] shift_buffer;

    function [4:0] find_msb16;
        input [15:0] v;
        begin
            casez (v)
                16'b1???????????????: find_msb16 = 5'd15;
                16'b01??????????????: find_msb16 = 5'd14;
                16'b001?????????????: find_msb16 = 5'd13;
                16'b0001????????????: find_msb16 = 5'd12;
                16'b00001???????????: find_msb16 = 5'd11;
                16'b000001??????????: find_msb16 = 5'd10;
                16'b0000001?????????: find_msb16 = 5'd9;
                16'b00000001????????: find_msb16 = 5'd8;
                16'b000000001???????: find_msb16 = 5'd7;
                16'b0000000001??????: find_msb16 = 5'd6;
                16'b00000000001?????: find_msb16 = 5'd5;
                16'b000000000001????: find_msb16 = 5'd4;
                16'b0000000000001???: find_msb16 = 5'd3;
                16'b00000000000001??: find_msb16 = 5'd2;
                16'b000000000000001?: find_msb16 = 5'd1;
                16'b0000000000000001: find_msb16 = 5'd0;
                default:             find_msb16 = 5'd0;
            endcase
        end
    endfunction

    assign A_s = (iInteger < 0);
    assign abs_input = (iInteger < 0) ? -iInteger : iInteger;
    assign msb_idx = find_msb16(abs_input);

    assign A_e = 8'd127 + {3'b000, msb_idx};
    assign shift_buffer = {23'b0, abs_input} << (8'd23 - {3'b000, msb_idx});
    assign A_f = shift_buffer[22:0];

    assign oA = (iInteger == 0) ? 32'b0 : {A_s, A_e, A_f};
endmodule

/**************************************************************************
 * Unsigned 32-bit Integer to Floating Point
 * Combinational, IEEE-754 single-precision field layout (no rounding)
 *************************************************************************/
module UInt32ToFp(
    input      [31:0] iUnsigned,
    output reg [31:0] oA
);
    integer i;
    reg [5:0] msb_idx;
    reg [7:0] exp;
    reg [22:0] frac;
    reg found;
    reg [31:0] sig_shifted;

    always @(*) begin
        if (iUnsigned == 32'b0) begin
            oA = 32'b0;
        end else begin
            msb_idx = 6'd0;
            found = 1'b0;

            for (i = 31; i >= 0; i = i - 1) begin
                if (!found && iUnsigned[i]) begin
                    msb_idx = i[5:0];
                    found = 1'b1;
                end
            end

            exp = 8'd127 + {2'b00, msb_idx};

            if (msb_idx >= 6'd23) begin
                sig_shifted = iUnsigned >> (msb_idx - 6'd23);
            end else begin
                sig_shifted = iUnsigned << (6'd23 - msb_idx);
            end

            frac = sig_shifted[22:0];
            oA = {1'b0, exp, frac};
        end
    end
endmodule

/**************************************************************************
 * Unsigned 64-bit Integer to Floating Point
 * Combinational, IEEE-754 single-precision field layout (no rounding)
 *************************************************************************/
module UInt64ToFp(
    input      [63:0] iUnsigned,
    output reg [31:0] oA
);
    integer i;
    reg [6:0] msb_idx;
    reg [7:0] exp;
    reg [22:0] frac;
    reg found;
    reg [63:0] sig_shifted;

    always @(*) begin
        if (iUnsigned == 64'b0) begin
            oA = 32'b0;
        end else begin
            msb_idx = 7'd0;
            found = 1'b0;

            for (i = 63; i >= 0; i = i - 1) begin
                if (!found && iUnsigned[i]) begin
                    msb_idx = i[6:0];
                    found = 1'b1;
                end
            end

            exp = 8'd127 + {1'b0, msb_idx};

            if (msb_idx >= 7'd23) begin
                sig_shifted = iUnsigned >> (msb_idx - 7'd23);
            end else begin
                sig_shifted = iUnsigned << (7'd23 - msb_idx);
            end

            frac = sig_shifted[22:0];
            oA = {1'b0, exp, frac};
        end
    end
endmodule

/**************************************************************************
 * Floating Point to 16-bit integer
 * Combinational
 * Numbers with mag > than +/-32768 get clipped to +/-32767
 *************************************************************************/
module Fp2Int(
    input      [31:0] iA,
    output reg [15:0] oInteger
);
    wire        A_s;
    wire [7:0]  A_e;
    wire [22:0] A_f;

    reg [32:0] mag33;

    assign A_s = iA[31];
    assign A_e = iA[30:23];
    assign A_f = iA[22:0];

    always @(*) begin
        mag33 = 33'b0;
        if (A_e < 8'd127) begin
            oInteger = 16'b0;
        end else if (A_e > 8'd141) begin
            oInteger = A_s ? -16'sh7fff : 16'sh7fff;
        end else begin
            if ((A_e - 8'd127) >= 8'd23) begin
                mag33 = {9'b0, 1'b1, A_f} << ((A_e - 8'd127) - 8'd23);
            end else begin
                mag33 = {9'b0, 1'b1, A_f} >> (8'd23 - (A_e - 8'd127));
            end

            if (A_s) oInteger = -mag33[15:0];
            else     oInteger = mag33[15:0];
        end
    end
endmodule

/**************************************************************************
 * Floating Point to signed 32-bit integer
 * Combinational, saturates on overflow
 *************************************************************************/
module Fp2Int32(
    input      [31:0] iA,
    output reg [31:0] oInteger
);
    wire        A_s;
    wire [7:0]  A_e;
    wire [22:0] A_f;

    reg [7:0] shift;
    reg [55:0] mag56;
    reg [31:0] mag32;

    assign A_s = iA[31];
    assign A_e = iA[30:23];
    assign A_f = iA[22:0];

    always @(*) begin
        if (A_e < 8'd127) begin
            oInteger = 32'd0;
        end else begin
            shift = A_e - 8'd127;

            if (shift >= 8'd23) begin
                mag56 = {32'b0, 1'b1, A_f} << (shift - 8'd23);
            end else begin
                mag56 = {32'b0, 1'b1, A_f} >> (8'd23 - shift);
            end

            if (mag56[55:31] != 25'b0) begin
                oInteger = A_s ? 32'h8000_0000 : 32'h7fff_ffff;
            end else begin
                mag32 = mag56[31:0];
                if (A_s) oInteger = (~mag32) + 32'd1;
                else     oInteger = mag32;
            end
        end
    end
endmodule

/**************************************************************************
 * Floating Point shift
 * Combinational
 * Positive iShift increases exponent, negative decreases exponent if
 * interpreted as two's-complement by caller.
 *************************************************************************/
module FpShift(
    input      [31:0] iA,
    input      [7:0]  iShift,
    output     [31:0] oShifted
);
    wire        A_s;
    wire [7:0]  A_e;
    wire [22:0] A_f;

    assign A_s = iA[31];
    assign A_e = iA[30:23];
    assign A_f = iA[22:0];

    assign oShifted = {A_s, A_e + iShift, A_f};
endmodule

/**************************************************************************
 * Floating Point sign negation
 * Combinational
 *************************************************************************/
module FpNegate(
    input      [31:0] iA,
    output     [31:0] oNegative
);
    wire       A_s;
    wire [7:0] A_e;
    wire [22:0] A_f;

    assign A_s = iA[31];
    assign A_e = iA[30:23];
    assign A_f = iA[22:0];

    assign oNegative = {~A_s, A_e, A_f};
endmodule

/**************************************************************************
 * Floating Point absolute
 * Combinational
 *************************************************************************/
module FpAbs(
    input      [31:0] iA,
    output     [31:0] oAbs
);
    wire [7:0]  A_e;
    wire [22:0] A_f;

    assign A_e = iA[30:23];
    assign A_f = iA[22:0];

    assign oAbs = {1'b0, A_e, A_f};
endmodule

/**************************************************************************
 * Floating Point compare
 * Combinational
 * output=1 if A>=B
 *************************************************************************/
module FpCompare(
    input      [31:0] iA,
    input      [31:0] iB,
    output reg        oA_larger
);
    wire        A_s;
    wire [7:0]  A_e;
    wire [22:0] A_f;
    wire        B_s;
    wire [7:0]  B_e;
    wire [22:0] B_f;

    wire A_mag_larger;

    assign A_s = iA[31];
    assign A_e = iA[30:23];
    assign A_f = iA[22:0];
    assign B_s = iB[31];
    assign B_e = iB[30:23];
    assign B_f = iB[22:0];

    assign A_mag_larger = (A_e > B_e) || ((A_e == B_e) && (A_f >= B_f));

    always @(*) begin
        if (A_s == 1'b0 && B_s == 1'b1) begin
            oA_larger = 1'b1;
        end else if (A_s == 1'b1 && B_s == 1'b0) begin
            oA_larger = 1'b0;
        end else if (A_s == 1'b0 && B_s == 1'b0) begin
            oA_larger = A_mag_larger;
        end else if (A_s == 1'b1 && B_s == 1'b1) begin
            oA_larger = ~A_mag_larger;
        end else begin
            oA_larger = 1'b0;
        end
    end
endmodule

/**************************************************************************
 * Floating Point Fast Inverse Square Root
 * 5-stage pipeline
 * Uses IEEE-754 single-precision bit constants.
 *************************************************************************/
module FpInvSqrt (
    input             iCLK,
    input      [31:0] iA,
    output     [31:0] oInvSqrt
);
    wire        A_s;
    wire [7:0]  A_e;
    wire [22:0] A_f;

    wire [31:0] y_1;
    wire [31:0] y_1_out;
    wire [31:0] half_iA_1;

    reg  [31:0] y_2;
    reg  [31:0] mult_2_in;
    reg  [31:0] half_iA_2;
    wire [31:0] y_2_out;

    reg  [31:0] y_3;
    reg  [31:0] add_3_in;
    wire [31:0] y_3_out;

    reg  [31:0] y_4;

    reg  [31:0] y_5;
    reg  [31:0] mult_5_in;

    assign A_s = iA[31];
    assign A_e = iA[30:23];
    assign A_f = iA[22:0];

    // Magic constant for IEEE-754 single precision fast inverse sqrt.
    assign y_1 = 32'h5f3759df - (iA >> 1);
    assign half_iA_1 = {A_s, A_e - 8'd1, A_f};

    FpMul s1_mult (.iA(y_1), .iB(y_1), .oProd(y_1_out));
    FpMul s2_mult (.iA(half_iA_2), .iB(mult_2_in), .oProd(y_2_out));
    FpAdd s3_add (
        .iCLK(iCLK),
        .iA({~add_3_in[31], add_3_in[30:0]}),
        .iB(32'h3fc00000),
        .oSum(y_3_out)
    );
    FpMul s5_mult (.iA(y_5), .iB(mult_5_in), .oProd(oInvSqrt));

    always @(posedge iCLK) begin
        y_2      <= y_1;
        mult_2_in <= y_1_out;
        half_iA_2 <= half_iA_1;

        y_3      <= y_2;
        add_3_in <= y_2_out;

        y_4 <= y_3;

        y_5      <= y_4;
        mult_5_in <= y_3_out;
    end
endmodule

/**************************************************************************
 * Floating Point Multiplier
 * Combinational
 *************************************************************************/
module FpMul (
    input      [31:0] iA,
    input      [31:0] iB,
    output     [31:0] oProd
);
    wire        A_s;
    wire [7:0]  A_e;
    wire [23:0] A_f;
    wire        B_s;
    wire [7:0]  B_e;
    wire [23:0] B_f;

    wire        oProd_s;
    wire [47:0] pre_prod_frac;
    wire [8:0]  pre_prod_exp;
    wire [7:0]  oProd_e;
    wire [8:0]  oProd_e_ext;
    wire [22:0] oProd_f;
    wire        underflow;

    assign A_s = iA[31];
    assign A_e = iA[30:23];
    assign A_f = {1'b1, iA[22:0]};

    assign B_s = iB[31];
    assign B_e = iB[30:23];
    assign B_f = {1'b1, iB[22:0]};

    assign oProd_s = A_s ^ B_s;
    assign pre_prod_frac = A_f * B_f;
    assign pre_prod_exp = A_e + B_e;

    assign oProd_e_ext = pre_prod_frac[47] ? (pre_prod_exp - 9'd126) : (pre_prod_exp - 9'd127);
    assign oProd_e = oProd_e_ext[7:0];
    assign oProd_f = pre_prod_frac[47] ? pre_prod_frac[46:24]     : pre_prod_frac[45:23];

    assign underflow = (pre_prod_exp < 9'h080);

    assign oProd = underflow     ? 32'b0 :
                   (A_e == 8'd0) ? 32'b0 :
                   (B_e == 8'd0) ? 32'b0 :
                   {oProd_s, oProd_e, oProd_f};
endmodule

/**************************************************************************
 * Floating Point Adder
 * 2-stage pipeline
 *************************************************************************/
module FpAdd (
    input             iCLK,
    input      [31:0] iA,
    input      [31:0] iB,
    output reg [31:0] oSum
);
    wire        A_s;
    wire [7:0]  A_e;
    wire [23:0] A_f;
    wire        B_s;
    wire [7:0]  B_e;
    wire [23:0] B_f;

    wire        A_larger;
    wire [7:0]  exp_diff_A;
    wire [7:0]  exp_diff_B;
    wire [7:0]  larger_exp;
    wire [47:0] A_f_shifted;
    wire [47:0] B_f_shifted;
    wire [47:0] pre_sum;

    reg  [47:0] buf_pre_sum;
    reg  [7:0]  buf_larger_exp;
    reg         buf_A_e_zero;
    reg         buf_B_e_zero;
    reg  [31:0] buf_A;
    reg  [31:0] buf_B;
    reg         buf_oSum_s;

    wire [24:0] sig_raw;
    wire [22:0] oSum_f_over;
    wire [7:0]  oSum_e_over;

    wire [23:0] sig_raw_24;
    wire [4:0]  norm_shift;
    wire [23:0] sig_norm_24;
    wire [22:0] oSum_f_norm;
    wire [8:0]  oSum_e_norm_ext;

    wire pre_sum_zero;

    function [4:0] norm_shift24;
        input [23:0] v;
        begin
            casez (v)
                24'b1???????????????????????: norm_shift24 = 5'd0;
                24'b01??????????????????????: norm_shift24 = 5'd1;
                24'b001?????????????????????: norm_shift24 = 5'd2;
                24'b0001????????????????????: norm_shift24 = 5'd3;
                24'b00001???????????????????: norm_shift24 = 5'd4;
                24'b000001??????????????????: norm_shift24 = 5'd5;
                24'b0000001?????????????????: norm_shift24 = 5'd6;
                24'b00000001????????????????: norm_shift24 = 5'd7;
                24'b000000001???????????????: norm_shift24 = 5'd8;
                24'b0000000001??????????????: norm_shift24 = 5'd9;
                24'b00000000001?????????????: norm_shift24 = 5'd10;
                24'b000000000001????????????: norm_shift24 = 5'd11;
                24'b0000000000001???????????: norm_shift24 = 5'd12;
                24'b00000000000001??????????: norm_shift24 = 5'd13;
                24'b000000000000001?????????: norm_shift24 = 5'd14;
                24'b0000000000000001????????: norm_shift24 = 5'd15;
                24'b00000000000000001???????: norm_shift24 = 5'd16;
                24'b000000000000000001??????: norm_shift24 = 5'd17;
                24'b0000000000000000001?????: norm_shift24 = 5'd18;
                24'b00000000000000000001????: norm_shift24 = 5'd19;
                24'b000000000000000000001???: norm_shift24 = 5'd20;
                24'b0000000000000000000001??: norm_shift24 = 5'd21;
                24'b00000000000000000000001?: norm_shift24 = 5'd22;
                24'b000000000000000000000001: norm_shift24 = 5'd23;
                default:                      norm_shift24 = 5'd24;
            endcase
        end
    endfunction

    assign A_s = iA[31];
    assign A_e = iA[30:23];
    assign A_f = {1'b1, iA[22:0]};

    assign B_s = iB[31];
    assign B_e = iB[30:23];
    assign B_f = {1'b1, iB[22:0]};

    assign exp_diff_A = B_e - A_e;
    assign exp_diff_B = A_e - B_e;

    assign larger_exp = (B_e > A_e) ? B_e : A_e;

    assign A_larger = (A_e > B_e) || ((A_e == B_e) && (A_f > B_f));

    assign A_f_shifted = A_larger            ? {1'b0, A_f, 23'b0} :
                         (exp_diff_A > 8'd47) ? 48'b0 :
                         ({1'b0, A_f, 23'b0} >> exp_diff_A);

    assign B_f_shifted = (~A_larger)         ? {1'b0, B_f, 23'b0} :
                         (exp_diff_B > 8'd47) ? 48'b0 :
                         ({1'b0, B_f, 23'b0} >> exp_diff_B);

    assign pre_sum = ((A_s ^ B_s) &  A_larger) ? (A_f_shifted - B_f_shifted) :
                     ((A_s ^ B_s) & ~A_larger) ? (B_f_shifted - A_f_shifted) :
                                                   (A_f_shifted + B_f_shifted);

    always @(posedge iCLK) begin
        buf_pre_sum    <= pre_sum;
        buf_larger_exp <= larger_exp;
        buf_A_e_zero   <= (A_e == 8'b0);
        buf_B_e_zero   <= (B_e == 8'b0);
        buf_A          <= iA;
        buf_B          <= iB;
        buf_oSum_s     <= A_larger ? A_s : B_s;
    end

    assign sig_raw = buf_pre_sum[47:23];
    assign pre_sum_zero = (buf_pre_sum == 48'b0);

    assign oSum_f_over = sig_raw[23:1];
    assign oSum_e_over = buf_larger_exp + 8'd1;

    assign sig_raw_24 = sig_raw[23:0];
    assign norm_shift = norm_shift24(sig_raw_24);
    assign sig_norm_24 = sig_raw_24 << norm_shift;
    assign oSum_f_norm = sig_norm_24[22:0];
    assign oSum_e_norm_ext = {1'b0, buf_larger_exp} - {4'b0000, norm_shift};

    always @(posedge iCLK) begin
        oSum <= (buf_A_e_zero && buf_B_e_zero) ? 32'b0 :
                buf_A_e_zero                   ? buf_B :
                buf_B_e_zero                   ? buf_A :
                pre_sum_zero                   ? 32'b0 :
                sig_raw[24]                    ? {buf_oSum_s, oSum_e_over, oSum_f_over} :
                (norm_shift == 5'd24)          ? 32'b0 :
                (~oSum_e_norm_ext[8])          ? {buf_oSum_s, oSum_e_norm_ext[7:0], oSum_f_norm} :
                                                 32'b0;
    end
endmodule
// <------ END AI ADJUSTED CODE

`endif
