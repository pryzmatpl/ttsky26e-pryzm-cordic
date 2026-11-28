`timescale 1ns/1ps
// Self-test sequencer bench — the demo-board claim, tested directly.
//
// The breadboard promise is: press reset, look at the board, LED1 means pass.
// So this bench drives NOTHING but reset and then checks the two status pins,
// twice:
//
//   * the verdict must be PASS with the shipped ROM;
//   * the verdict must STAY on the LEDs long after the run finished, because a
//     human looks at the board minutes later, not microseconds later.
//
// A self-test that cannot fail is worthless, so `bringup/gen-selftest-rom.py
// --corrupt` exists to flip one expected bit; run this bench against that ROM
// and LED1 must be LOW. See test/run-selftest.sh, which runs both.

module tb_selftest;

  reg clk = 0, rst_n = 0;
  reg [7:0] ui_in = 0, uio_in = 0;
  wire [7:0] uo_out, uio_out, uio_oe;

  tt_um_pryzm_cordic dut (
      .ui_in(ui_in), .uo_out(uo_out),
      .uio_in(uio_in), .uio_out(uio_out), .uio_oe(uio_oe),
      .ena(1'b1), .clk(clk), .rst_n(rst_n)
  );

  always #12.5 clk = ~clk;

  integer g = 0;
  reg seen = 0;

  always @(posedge clk) begin
    g = g + 1;
    if (dut.st_done && !seen) begin
      seen = 1;
      $display("verdict latched at clock %0d: LED1=%b LED2=%b (vector %0d/41)",
               g, uio_out[6], uio_out[7], dut.st_v);
    end
    // Hold idle, as a human would, and require the verdict to still be there.
    if (seen && g > 3000) begin
      if (`EXPECT_PASS) begin
        if (uio_out[6] === 1'b1 && uio_out[7] === 1'b0)
          $display("PASS held after 3000 idle clocks");
        else
          $display("FAIL: verdict did not hold (LED1=%b LED2=%b)", uio_out[6], uio_out[7]);
      end else begin
        if (uio_out[6] === 1'b0 && uio_out[7] === 1'b1)
          $display("FAIL reported and held (corrupted ROM detected)");
        else
          $display("FAIL: corrupted ROM was NOT detected (LED1=%b)", uio_out[6]);
      end
      $finish;
    end
    if (g > 12000) begin
      $display("FAIL: sequencer never produced a verdict");
      $finish;
    end
  end

  initial begin #100 rst_n = 1; end

endmodule
