`timescale 1ns / 1ps
/* Single-operation trace bench, used while debugging the FSM.
 *   +OP=<0..3> +A=<signed> +B=<signed> +N=<cycles>
 */
module tb_dbg;
  reg clk = 1'b0, rst_n = 1'b0;
  reg [7:0] ui_in = 8'd0, uio_in = 8'd0;
  wire [7:0] uo_out, uio_out, uio_oe;
  integer op, a, b, ncyc, i;

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
    if (!$value$plusargs("N=%d", ncyc)) ncyc = 60;

    repeat (4) tick;
    rst_n = 1'b1;
    repeat (3) tick;

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

    for (i = 0; i < ncyc; i = i + 1) begin
      tick;
      $display("t=%0d st=%0d it=%0d cz=%0d cx=%0d cy=%0d acc=%0d mca=%0d mcb=%0d mcnt=%0d shf=%0d res0=%0d res1=%0d val=%b busy=%b rcnt=%0d uo=%02x",
               i, dut.st, dut.iter, dut.cz, dut.cx, dut.cy,
               dut.acc, dut.mca, dut.mcb, dut.mcnt, dut.shf,
               dut.res0, dut.res1, dut.valid, dut.busy, dut.rcnt, uo_out);
    end
    $finish;
  end
endmodule
