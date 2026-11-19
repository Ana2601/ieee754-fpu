// IEEE-754 binary32 round-and-pack stage (shared by add/sub/mul/div).
//
// Input is an exact-with-sticky magnitude  v * 2^(e-25):
//   v[25]   leading one (always set)
//   v[24:2] 23 fraction bits
//   v[1]    round bit,  v[0] sticky bit
// Handles all five RISC-V rounding modes, gradual underflow (subnormals),
// overflow, and tininess detection *after* rounding.
module fp_round (
    input  wire               sign,
    input  wire signed [11:0] e,
    input  wire        [25:0] v,
    input  wire        [2:0]  rm,
    output reg         [31:0] result,
    output reg         [4:0]  flags      // {NV, DZ, OF, UF, NX}
);
    localparam [2:0] RNE = 3'd0, RTZ = 3'd1, RDN = 3'd2, RUP = 3'd3, RMM = 3'd4;

    function automatic round_inc(input lsb, input r, input s, input sgn, input [2:0] mode);
        case (mode)
            RNE:     round_inc = r & (s | lsb);
            RTZ:     round_inc = 1'b0;
            RDN:     round_inc = sgn & (r | s);
            RUP:     round_inc = ~sgn & (r | s);
            RMM:     round_inc = r;
            default: round_inc = r & (s | lsb);
        endcase
    endfunction

    // ---- rounding with unbounded exponent (normal results, tininess check)
    wire        inc_u   = round_inc(v[2], v[1], v[0], sign, rm);
    wire [24:0] mant_u  = {1'b0, v[25:2]} + {24'd0, inc_u};
    wire        carry_u = mant_u[24];
    wire signed [11:0] e_n = e + {11'd0, carry_u};
    wire        inexact_n = v[1] | v[0];
    wire        overflow  = (e_n > 12'sd127);

    // ---- gradual underflow: denormalise so the exponent is emin, then round
    wire        is_sub = (e < -12'sd126);
    wire [11:0] sh     = -12'sd126 - e;
    wire [25:0] lost_mask = (26'd1 << sh[4:0]) - 26'd1;
    wire [25:0] vs = (sh >= 12'd26) ? 26'd1
                                    : ((v >> sh[4:0]) | {25'd0, |(v & lost_mask)});
    wire        inc_s  = round_inc(vs[2], vs[1], vs[0], sign, rm);
    wire [23:0] mant_s = vs[25:2] + {23'd0, inc_s};
    wire        inexact_s = vs[1] | vs[0];
    // Not tiny only if the unbounded rounding reaches 2^emin.
    wire        tiny = !((e == -12'sd127) && carry_u);

    wire inf_on_ovf = (rm == RNE) || (rm == RMM) || (rm == RDN && sign) || (rm == RUP && !sign);
    wire [7:0] exp_n = e_n[7:0] + 8'd127;

    always @* begin
        flags = 5'd0;
        if (is_sub) begin
            result   = {sign, 7'd0, mant_s[23], mant_s[22:0]};
            flags[0] = inexact_s;
            flags[1] = inexact_s & tiny;
        end else if (overflow) begin
            result = inf_on_ovf ? {sign, 8'hFF, 23'd0} : {sign, 8'hFE, 23'h7FFFFF};
            flags[2] = 1'b1;
            flags[0] = 1'b1;
        end else begin
            result   = {sign, exp_n, carry_u ? 23'd0 : mant_u[22:0]};
            flags[0] = inexact_n;
        end
    end
endmodule
