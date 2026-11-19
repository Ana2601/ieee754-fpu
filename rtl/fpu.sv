// IEEE-754 single-precision FPU: add, sub, mul, div.
//
//  * All five RISC-V rounding modes (RNE/RTZ/RDN/RUP/RMM)
//  * Full special-case handling: NaN (quiet/signalling), infinities, signed
//    zeros, subnormal operands and results (gradual underflow)
//  * Exception flags in RISC-V fflags order {NV, DZ, OF, UF, NX}
//  * valid/ready handshake; add/sub/mul take 3 cycles, div takes 30
//    (bit-serial restoring divider, one quotient bit per cycle)
module fpu (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        in_valid,
    output wire        in_ready,
    input  wire [1:0]  op,          // 0 add, 1 sub, 2 mul, 3 div
    input  wire [2:0]  rm,
    input  wire [31:0] a,
    input  wire [31:0] b,

    output reg         out_valid,
    output reg  [31:0] result,
    output reg  [4:0]  flags
);
    localparam [1:0] OP_ADD = 2'd0, OP_SUB = 2'd1, OP_MUL = 2'd2, OP_DIV = 2'd3;
    localparam [2:0] RDN = 3'd2;
    localparam [31:0] QNAN = 32'h7FC00000;
    localparam [2:0] S_IDLE = 3'd0, S_EXEC = 3'd1, S_DIV = 3'd2, S_ROUND = 3'd3;

    reg [2:0]  st;
    reg [1:0]  op_q;
    reg [2:0]  rm_q;
    reg [31:0] a_q, b_q;

    assign in_ready = (st == S_IDLE);

    // ------------------------------------------------------------ unpack
    function automatic [4:0] clz24(input [23:0] x);
        integer i;
        begin
            clz24 = 5'd24;
            for (i = 0; i < 24; i = i + 1)
                if (x[i]) clz24 = 5'd23 - i[4:0];
        end
    endfunction

    wire        sa = a_q[31];
    wire        sb_raw = b_q[31];
    wire [7:0]  efa = a_q[30:23], efb = b_q[30:23];
    wire [22:0] fa = a_q[22:0],  fb = b_q[22:0];
    wire a_zero = (efa == 8'd0) && (fa == 23'd0);
    wire b_zero = (efb == 8'd0) && (fb == 23'd0);
    wire a_inf  = (efa == 8'hFF) && (fa == 23'd0);
    wire b_inf  = (efb == 8'hFF) && (fb == 23'd0);
    wire a_nan  = (efa == 8'hFF) && (fa != 23'd0);
    wire b_nan  = (efb == 8'hFF) && (fb != 23'd0);
    wire a_snan = a_nan && !fa[22];
    wire b_snan = b_nan && !fb[22];

    // Normalise so the leading one sits at bit 23 (subnormals get a smaller exponent).
    wire [23:0] ma_raw = {efa != 8'd0, fa};
    wire [23:0] mb_raw = {efb != 8'd0, fb};
    wire [4:0]  lza = clz24(ma_raw), lzb = clz24(mb_raw);
    wire [23:0] ma = ma_raw << lza;
    wire [23:0] mb = mb_raw << lzb;
    wire signed [11:0] ea = a_zero ? -12'sd400
                          : ((efa == 8'd0) ? -12'sd126 : $signed({4'd0, efa}) - 12'sd127) - $signed({7'd0, lza});
    wire signed [11:0] eb = b_zero ? -12'sd400
                          : ((efb == 8'd0) ? -12'sd126 : $signed({4'd0, efb}) - 12'sd127) - $signed({7'd0, lzb});

    // ------------------------------------------------------------ add / sub
    wire sb = sb_raw ^ (op_q == OP_SUB);
    wire swap = (eb > ea) || ((eb == ea) && (mb > ma));
    wire        s_big = swap ? sb : sa;
    wire        s_sml = swap ? sa : sb;
    wire [23:0] m_big = swap ? mb : ma;
    wire [23:0] m_sml = swap ? ma : mb;
    wire signed [11:0] e_big = swap ? eb : ea;
    wire signed [11:0] e_sml = swap ? ea : eb;
    wire [11:0] dexp = e_big - e_sml;

    wire [26:0] big_ext = {m_big, 3'b000};
    wire [26:0] sml_ext = {m_sml, 3'b000};
    wire [26:0] sml_mask = (27'd1 << dexp[4:0]) - 27'd1;
    wire [26:0] sml_al = (dexp >= 12'd27) ? {26'd0, |m_sml}
                                          : ((sml_ext >> dexp[4:0]) | {26'd0, |(sml_ext & sml_mask)});
    wire        eff_sub = s_big ^ s_sml;
    wire [27:0] sum = eff_sub ? ({1'b0, big_ext} - {1'b0, sml_al})
                              : ({1'b0, big_ext} + {1'b0, sml_al});

    function automatic [4:0] clz27(input [26:0] x);
        integer i;
        begin
            clz27 = 5'd27;
            for (i = 0; i < 27; i = i + 1)
                if (x[i]) clz27 = 5'd26 - i[4:0];
        end
    endfunction

    wire [4:0]  lzs   = clz27(sum[26:0]);
    wire [26:0] n_add = sum[27] ? {sum[27:2], sum[1] | sum[0]} : (sum[26:0] << lzs);
    wire signed [11:0] e_add = sum[27] ? (e_big + 12'sd1) : (e_big - $signed({7'd0, lzs}));
    wire [25:0] v_add = {n_add[26:2], n_add[1] | n_add[0]};
    wire        add_zero = (sum == 28'd0);

    // ------------------------------------------------------------ mul
    wire [47:0] prod = ma * mb;
    wire [25:0] v_mul = prod[47] ? {prod[47:23], |prod[22:0]} : {prod[46:22], |prod[21:0]};
    wire signed [11:0] e_mul = ea + eb + {11'd0, prod[47]};

    // ------------------------------------------------------------ div (iterative)
    reg  [24:0] rem;
    reg  [26:0] quo;
    reg  [4:0]  dcnt;
    wire        d_ge   = (rem >= {1'b0, mb});
    wire [24:0] d_sub  = d_ge ? (rem - {1'b0, mb}) : rem;
    wire        rem_nz = (rem != 25'd0);
    wire [25:0] v_div = quo[26] ? {quo[26:2], quo[1] | quo[0] | rem_nz}
                                : {quo[25:1], quo[0] | rem_nz};
    wire signed [11:0] e_div = ea - eb - {11'd0, ~quo[26]};

    // ------------------------------------------------------------ special cases
    reg        spec;          // result is decided without the rounder
    reg [31:0] spec_res;
    reg [4:0]  spec_flags;
    wire       s_xor = sa ^ sb_raw;

    always @* begin
        spec = 1'b0; spec_res = QNAN; spec_flags = 5'd0;
        if (a_nan || b_nan) begin
            spec = 1'b1; spec_flags[4] = a_snan | b_snan;
        end else case (op_q)
            OP_ADD, OP_SUB: begin
                if (a_inf && b_inf) begin
                    spec = 1'b1;
                    if (sa != sb) spec_flags[4] = 1'b1;
                    else spec_res = {sa, 8'hFF, 23'd0};
                end else if (a_inf) begin spec = 1'b1; spec_res = {sa, 8'hFF, 23'd0};
                end else if (b_inf) begin spec = 1'b1; spec_res = {sb, 8'hFF, 23'd0};
                end else if (a_zero && b_zero) begin
                    spec = 1'b1; spec_res = {(sa == sb) ? sa : (rm_q == RDN), 31'd0};
                end else if (add_zero) begin
                    spec = 1'b1; spec_res = {(rm_q == RDN), 31'd0};   // exact cancellation
                end
            end
            OP_MUL: begin
                if ((a_inf && b_zero) || (a_zero && b_inf)) begin spec = 1'b1; spec_flags[4] = 1'b1;
                end else if (a_inf || b_inf) begin spec = 1'b1; spec_res = {s_xor, 8'hFF, 23'd0};
                end else if (a_zero || b_zero) begin spec = 1'b1; spec_res = {s_xor, 31'd0};
                end
            end
            default: begin // OP_DIV
                if ((a_inf && b_inf) || (a_zero && b_zero)) begin spec = 1'b1; spec_flags[4] = 1'b1;
                end else if (a_inf) begin spec = 1'b1; spec_res = {s_xor, 8'hFF, 23'd0};
                end else if (b_inf || a_zero) begin spec = 1'b1; spec_res = {s_xor, 31'd0};
                end else if (b_zero) begin
                    spec = 1'b1; spec_res = {s_xor, 8'hFF, 23'd0}; spec_flags[3] = 1'b1;
                end
            end
        endcase
    end

    // ------------------------------------------------------------ round stage
    reg               r_sign;
    reg signed [11:0] r_e;
    reg [25:0]        r_v;
    reg               r_spec;
    reg [31:0]        r_spec_res;
    reg [4:0]         r_spec_flags;
    wire [31:0]       rnd_res;
    wire [4:0]        rnd_flags;

    fp_round u_round (
        .sign(r_sign), .e(r_e), .v(r_v), .rm(rm_q),
        .result(rnd_res), .flags(rnd_flags)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; out_valid <= 1'b0; result <= 32'd0; flags <= 5'd0;
            op_q <= 2'd0; rm_q <= 3'd0; a_q <= 32'd0; b_q <= 32'd0;
            rem <= 25'd0; quo <= 27'd0; dcnt <= 5'd0;
            r_sign <= 1'b0; r_e <= 12'sd0; r_v <= 26'd0;
            r_spec <= 1'b0; r_spec_res <= 32'd0; r_spec_flags <= 5'd0;
        end else begin
            out_valid <= 1'b0;
            case (st)
                S_IDLE: if (in_valid) begin
                    op_q <= op; rm_q <= rm; a_q <= a; b_q <= b;
                    st <= S_EXEC;
                end

                S_EXEC: begin
                    r_spec <= spec; r_spec_res <= spec_res; r_spec_flags <= spec_flags;
                    if (op_q == OP_DIV && !spec) begin
                        rem <= {1'b0, ma}; quo <= 27'd0; dcnt <= 5'd26;
                        st  <= S_DIV;
                    end else begin
                        if (op_q == OP_MUL) begin
                            r_sign <= s_xor; r_e <= e_mul; r_v <= v_mul;
                        end else begin
                            r_sign <= s_big; r_e <= e_add; r_v <= v_add;
                        end
                        st <= S_ROUND;
                    end
                end

                S_DIV: begin
                    quo  <= {quo[25:0], d_ge};
                    rem  <= (dcnt == 5'd0) ? d_sub : {d_sub[23:0], 1'b0};
                    dcnt <= dcnt - 5'd1;
                    if (dcnt == 5'd0) st <= S_DIV + 3'd2;   // S_DIVDONE
                end

                3'd4: begin // S_DIVDONE: quotient and remainder are final
                    r_sign <= s_xor; r_e <= e_div; r_v <= v_div;
                    st <= S_ROUND;
                end

                S_ROUND: begin
                    out_valid <= 1'b1;
                    result    <= r_spec ? r_spec_res   : rnd_res;
                    flags     <= r_spec ? r_spec_flags : rnd_flags;
                    st        <= S_IDLE;
                end

                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
