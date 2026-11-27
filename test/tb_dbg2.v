`timescale 1ns / 1ps
/* Byte-level protocol trace with acks. ./test/dbg.sh uses tb_dbg; this one
 * answers the "which byte did the host actually see" question.
 *   +OP +A +B +NBYTES
 */
module tb_dbg2;
  reg clk = 1'b0, rst_n = 1'b0;
  reg [7:0] ui_in = 8'd0, uio_in = 8'd0;
  wire [7:0] uo_out, uio_out, uio_oe;
  integer op, a, b, nbytes, i, got_n;

  tt_um_pryzm_cordic dut (
      .ui_in(ui_in), .uo_out(uo_out), .uio_in(uio_in), .uio_out(uio_out),
      .uio_oe(uio_oe), .ena(1'b1), .clk(clk), .rst_n(rst_n));

  always #5 clk = ~clk;
  task tick; begin @(posedge clk); #1; end endtask

  task wbyte(input [7:0] d);
    begin
      ui_in  = d;
      uio_in = {3'b000, op[1:0], 1'b0, 1'b0, 1'b1};
      tick;
      ui_in  = 8'd0;
      uio_in = {3'b000, op[1:0], 1'b0, 1'b0, 1'b0};
      tick;
    end
  endtask

  initial begin
    if (!$value$plusargs("OP=%d", op)) op = 0;
    if (!$value$plusargs("A=%d", a))   a = 0;
    if (!$value$plusargs("B=%d", b))   b = 0;
    if (!$value$plusargs("NBYTES=%d", nbytes)) nbytes = 2;

    repeat (4) tick;
    rst_n = 1'b1;
    repeat (3) tick;

    uio_in = 8'h20; tick; uio_in = 8'h00; tick;   // srst

    wbyte(a[7:0]);
    wbyte(a[15:8]);
    if (op != 0) begin
      wbyte(b[7:0]);
      wbyte(b[15:8]);
    end

    ui_in  = 8'd0;
    uio_in = {3'b000, op[1:0], 1'b0, 1'b1, 1'b0};
    tick;
    uio_in = {3'b000, op[1:0], 1'b0, 1'b0, 1'b0};

    got_n = 0;
    for (i = 0; i < 400 && got_n < nbytes; i = i + 1) begin
      tick;
      if (uio_out[6]) begin
        $display("byte[%0d] = %02x  (rcnt=%0d nres=%0d res0=%04x res1=%04x ackseen)",
                 got_n, uo_out, dut.rcnt, dut.nres, dut.res0, dut.res1);
        uio_in = {3'b000, op[1:0], 1'b1, 1'b0, 1'b0};   // ack
        tick;
        uio_in = {3'b000, op[1:0], 1'b0, 1'b0, 1'b0};
        got_n = got_n + 1;
      end
    end
    $display("done got_n=%0d", got_n);
    $finish;
  end
endmodule
