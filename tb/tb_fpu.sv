`timescale 1ns/1ps
// Self-checking testbench: replays vectors from the exact rational reference
// model and compares both the result bits and all five exception flags.
module tb_fpu;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg         in_valid = 0;
    reg  [1:0]  op;
    reg  [2:0]  rm;
    reg  [31:0] a, b;
    wire        in_ready, out_valid;
    wire [31:0] result;
    wire [4:0]  flags;

    fpu dut (.clk(clk), .rst_n(rst_n), .in_valid(in_valid), .in_ready(in_ready),
             .op(op), .rm(rm), .a(a), .b(b),
             .out_valid(out_valid), .result(result), .flags(flags));

    integer fd, r, pass = 0, fail = 0, i;
    integer op_i, rm_i;
    integer per_op [0:3];
    integer flag_seen [0:4];
    reg [31:0] exp_res;
    reg [7:0]  exp_flags;
    string vec_file;

    initial begin
        for (i = 0; i < 4; i = i + 1) per_op[i] = 0;
        for (i = 0; i < 5; i = i + 1) flag_seen[i] = 0;
        if (!$value$plusargs("vectors=%s", vec_file)) vec_file = "build/vectors.txt";
        fd = $fopen(vec_file, "r");
        if (fd == 0) begin $display("cannot open %s", vec_file); $fatal; end
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        while (!$feof(fd)) begin
            r = $fscanf(fd, "%d %d %h %h %h %h", op_i, rm_i, a, b, exp_res, exp_flags);
            if (r != 6) break;
            op = op_i[1:0]; rm = rm_i[2:0];
            in_valid <= 1;
            @(posedge clk);
            while (!in_ready) @(posedge clk);
            in_valid <= 0;
            @(posedge clk);
            while (!out_valid) @(posedge clk);
            per_op[op_i] = per_op[op_i] + 1;
            for (i = 0; i < 5; i = i + 1) if (exp_flags[i]) flag_seen[i] = flag_seen[i] + 1;
            if (result === exp_res && flags === exp_flags[4:0]) pass = pass + 1;
            else begin
                fail = fail + 1;
                if (fail <= 20)
                    $display("FAIL op=%0d rm=%0d a=%h b=%h : got %h/%b exp %h/%b",
                             op_i, rm_i, a, b, result, flags, exp_res, exp_flags[4:0]);
            end
        end

        $display("FPU: %0d passed, %0d failed  (add=%0d sub=%0d mul=%0d div=%0d)",
                 pass, fail, per_op[0], per_op[1], per_op[2], per_op[3]);
        $display("flag coverage: NX=%0d UF=%0d OF=%0d DZ=%0d NV=%0d",
                 flag_seen[0], flag_seen[1], flag_seen[2], flag_seen[3], flag_seen[4]);
        if (fail != 0 || pass == 0) $fatal(1, "TEST FAILED");
        $display("TEST PASSED");
        $finish;
    end
endmodule
