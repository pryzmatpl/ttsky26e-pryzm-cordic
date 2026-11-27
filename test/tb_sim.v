`timescale 1ns / 1ps

/*
 * Development testbench for tt_um_pryzm_cordic.
 *
 * Reads `vectors.txt`, one operation per line:
 *     <op> <a> <b>
 * with op in 0..3 (0 SINCOS, 1 ATAN2, 2 HYPOT, 3 MUL) and a, b signed decimal
 * 16-bit operands. Drives the whole byte-serial protocol, then writes
 * `results.txt` as one line per operation:
 *     <op> <a> <b> <word0> <word1>
 *
 * This is the bench `test/sim_compare.py` uses to compare RTL against the
 * golden model. It is deliberately plain Verilog so it runs on any host with
 * iverilog — the cocotb bench is the shuttle-facing one.
 */
module tb;
  reg clk = 1'b0;
  reg rst_n = 1'b0;
  reg [7:0] ui_in = 8'd0;
  reg [7:0] uio_in = 8'd0;
  wire [7:0] uo_out, uio_out, uio_oe;

  integer fd, fo, r, i;
  integer op, a, b;
  integer w0, w1;
  integer guard;

  tt_um_pryzm_cordic dut (
      .ui_in(ui_in), .uo_out(uo_out), .uio_in(uio_in), .uio_out(uio_out),
      .uio_oe(uio_oe), .ena(1'b1), .clk(clk), .rst_n(rst_n));

  always #5 clk = ~clk;

  // ——— helpers ————————————————————————————————————————————————
  task tick;             // one rising edge
    begin
      @(posedge clk);
      #1;
    end
  endtask

  task idle_clr;
    begin
      ui_in  = 8'd0;
      uio_in = 8'd0;
      tick;
    end
  endtask

  // write one byte of an operand; `op` must already be on the bus
  task wbyte;
    input [7:0] dat;
    begin
      ui_in  = dat;
      uio_in = {3'b000, op[1:0], 1'b0, 1'b0, 1'b1};   // wr=1
      tick;
      ui_in  = 8'd0;
      uio_in = {3'b000, op[1:0], 1'b0, 1'b0, 1'b0};
      tick;
    end
  endtask

  // latch the byte currently driven by uo_out, then acknowledge it
  task rbyte;
    output [7:0] dat;
    begin
      guard = 0;
      ui_in  = 8'd0;
      uio_in = {3'b000, op[1:0], 1'b0, 1'b0, 1'b0};
      tick;
      while ((!uio_out[6]) && guard < 2048) begin
        tick;
        guard = guard + 1;
      end
      dat    = uo_out;                                // sample the presented byte
      uio_in = {3'b000, op[1:0], 1'b1, 1'b0, 1'b0};   // ack
      tick;
      uio_in = {3'b000, op[1:0], 1'b0, 1'b0, 1'b0};
      tick;
    end
  endtask

  reg [7:0] lo, hi;

  initial begin
    fd = $fopen("vectors.txt", "r");
    if (fd == 0) begin
      $display("cannot open vectors.txt");
      $finish;
    end
    fo = $fopen("results.txt", "w");

    repeat (5) tick;
    rst_n = 1'b1;
    repeat (5) tick;

    for (i = 0; i < 40000; i = i + 1) begin
      r = $fscanf(fd, "%d %d %d\n", op, a, b);
      if (r != 3) i = 40000;
      else begin
        ui_in  = 8'd0;
        uio_in = {2'b00, 1'b1, op[1:0], 1'b0, 1'b0, 1'b0};   // srst: clear the byte counter
        tick;
        uio_in = {3'b000, op[1:0], 1'b0, 1'b0, 1'b0};
        tick;

        wbyte(a[7:0]);
        wbyte(a[15:8]);
        if (op == 1 || op == 2 || op == 3) begin
          wbyte(b[7:0]);
          wbyte(b[15:8]);
        end

        // go
        ui_in  = 8'd0;
        uio_in = {3'b000, op[1:0], 1'b0, 1'b1, 1'b0};
        tick;
        uio_in = {3'b000, op[1:0], 1'b0, 1'b0, 1'b0};

        rbyte(lo);
        w0 = lo;
        rbyte(hi);
        w1 = hi;
        w0 = w0 | (w1 << 8);

        w1 = 0;
        if (op == 0) begin
          rbyte(lo);
          w1 = lo;
          rbyte(hi);
          w1 = w1 | (hi << 8);
        end

        $fwrite(fo, "%0d %0d %0d %0d %0d\n", op, a, b, w0, w1);
        idle_clr;
      end
    end

    $fclose(fo);
    $fclose(fd);
    $finish;
  end
endmodule
