/*
 * tt_um_pryzm_cordic — a 16-bit four-operation CORDIC engine.
 *
 * Copyright (c) 2026 Piotr Slupski / Jaisiu
 * SPDX-License-Identifier: Apache-2.0
 *
 * Generated and verified by Jaisiu / PhotonIP. The golden model this file is
 * bit-exact against is `model/cordic16.py`; `test/sim_compare.py` compares the
 * two word for word with no tolerance (7736 vectors), and `test/test.py` does
 * the same in cocotb for the shuttle's CI.
 *
 * ## Interface (byte-serial, 8-bit port)
 *
 *   uio_in[0]    wr    latch ui_in as the next operand byte
 *   uio_in[1]    go    start (all operands already written)
 *   uio_in[2]    ack   host consumed the byte on uo_out
 *   uio_in[4:3]  op    0 SINCOS, 1 ATAN2, 2 HYPOT, 3 MUL
 *   uio_in[5]    srst  clear the operand byte counter
 *   uio_out[6]   valid a result byte is on uo_out
 *   uio_out[7]   busy  the engine is working
 *
 * Operands low byte first: SINCOS `phase`; ATAN2 / HYPOT `y` then `x`;
 * MUL `a` then `b`. Results low byte first: SINCOS `sin` then `cos`; the
 * others one 16-bit word.
 *
 * ## Fixed point
 *
 *   phase          Q1.15, 1.0 == pi radians
 *   sin, cos, a, b Q1.15
 *   atan2          Q3.13 radians
 *   hypot          Q2.14, saturating at 2.0
 *   internal x, y  Q2.14, 18-bit
 *   internal z     Q3.13, 18-bit
 *
 * ## Why there is no 16x16 multiplier array
 *
 * Two of the three multiplies are by a *constant* (pi, and 1/K), so they are
 * written as literal-coefficient products and synthesise to shift-add
 * networks. The third (MUL's a*b) is a bit-serial shift-add over 16 cycles,
 * which is the same arithmetic — the partial-product sum of `a*b` truncated
 * by `>>15` is exactly `(a*b)>>15` — at a fraction of the area. Measured:
 * an 18x16 array was 13,319 um2 of a 28,412 um2 die (47 %); the shift-add
 * version leaves the whole design under one tile.
 *
 * ## Size
 *
 * One 18-bit add/sub, one 32-bit shift-add accumulator, 15 CORDIC
 * iterations, no memories, no analog pins.
 */

`default_nettype none

module tt_um_pryzm_cordic (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

  /* ───────────────────────── constants ───────────────────────────── */

  localparam signed [15:0] A0  = 16'sd6434;   // atan(2^0) in Q3.13
  localparam signed [15:0] A1  = 16'sd3798;
  localparam signed [15:0] A2  = 16'sd2007;
  localparam signed [15:0] A3  = 16'sd1019;
  localparam signed [15:0] A4  = 16'sd511;
  localparam signed [15:0] A5  = 16'sd256;
  localparam signed [15:0] A6  = 16'sd128;
  localparam signed [15:0] A7  = 16'sd64;
  localparam signed [15:0] A8  = 16'sd32;
  localparam signed [15:0] A9  = 16'sd16;
  localparam signed [15:0] A10 = 16'sd8;
  localparam signed [15:0] A11 = 16'sd4;
  localparam signed [15:0] A12 = 16'sd2;
  localparam signed [15:0] A13 = 16'sd1;
  localparam signed [15:0] A14 = 16'sd0;

  localparam signed [17:0] KQ14 = 18'sd9949;   // 1/K in Q2.14
  localparam signed [17:0] HALF = 18'sd12868;  // pi/2 in Q3.13
  localparam signed [17:0] PIZ  = 18'sd25736;  // pi   in Q3.13

  localparam signed [17:0] PI_COEF = 18'sd25736;  // pi in Q3.13, the phase coefficient
  localparam signed [17:0] KI_COEF = 18'sd9949;   // 1/K in Q2.14, the magnitude coefficient

  localparam [1:0] OP_SINCOS = 2'd0;
  localparam [1:0] OP_ATAN2  = 2'd1;
  localparam [1:0] OP_HYPOT  = 2'd2;
  localparam [1:0] OP_MUL    = 2'd3;

  localparam [3:0] S_IDLE = 4'd0,
                   S_CONV = 4'd1,   // phase -> radians, or start the product
                   S_MPY  = 4'd2,   // one shift-add step of a*b
                   S_MPYW = 4'd3,
                   S_PRE  = 4'd4,   // prescale, one left shift per visit
                   S_RUN  = 4'd5,   // 15 CORDIC iterations
                   S_MAG  = 4'd6,   // hypot magnitude
                   S_FOLD = 4'd7,   // SINCOS: fold to |z| <= pi/2
                   S_PACK = 4'd8,   // fold the results by quadrant / sign
                   S_OUT  = 4'd9;

  /* ───────────────────────── interface ───────────────────────────── */

  wire       wr   = uio_in[0];
  wire       go   = uio_in[1];
  wire       ack  = uio_in[2];
  wire [1:0] op   = uio_in[4:3];
  wire       srst = uio_in[5];

  wire _unused = &{ena, 1'b0};

  /* ───────────────────────── state ───────────────────────────────── */

  reg [15:0] opa, opb;
  reg [1:0]  wcnt;
  reg [1:0]  rcnt;
  reg [1:0]  nres;
  reg [15:0] res0, res1;
  reg        valid, busy;

  reg signed [17:0] cx, cy, cz;
  reg [3:0]  iter;
  reg [3:0]  st;

  reg        vmode;
  reg        swapped;
  reg [2:0]  shf;
  reg [2:0]  shfl;
  reg        qx, qy;
  reg        q1, qm1;
  reg [15:0] a16;

  // bit-serial multiply accumulator for MUL
  reg signed [33:0] acc;
  reg signed [33:0] mca;
  reg [15:0]        mcb;
  reg [4:0]         mcnt;

  /* ───────────────────────── arithmetic ──────────────────────────── */

  function signed [15:0] sat34;
    input signed [33:0] v;
    begin
      if (v > 34'sd32767)       sat34 = 16'sd32767;
      else if (v < -34'sd32768) sat34 = -16'sd32768;
      else                      sat34 = v[15:0];
    end
  endfunction

  // Q2.14 -> Q1.15 with saturation. The rotation gain leaves |x| at 16386,
  // i.e. 1.0001, which must read as the top Q1.15 word and not wrap negative.
  function [15:0] q15;
    input signed [17:0] v;
    reg signed [17:0] s;
    begin
      s = v <<< 1;
      if (s > 18'sd32767)       q15 = 16'sd32767;
      else if (s < -18'sd32768) q15 = -16'sd32768;
      else                      q15 = s[15:0];
    end
  endfunction

  function [15:0] q15n;
    input signed [17:0] v;
    reg signed [17:0] s;
    begin
      s = -(v <<< 1);
      if (s > 18'sd32767)       q15n = 16'sd32767;
      else if (s < -18'sd32768) q15n = -16'sd32768;
      else                      q15n = s[15:0];
    end
  endfunction

  // Constant multiplies, written as explicit shift-adds.
  //
  // `opa * 25736` asked of a synthesiser is a request it may answer with a
  // general multiplier array; the same product written out is four adders.
  // 25736 = 2^15 - 2^13 + 2^10 + 2^7 + 2^3 (CSD, `python3 synth/consts.py`).
  wire signed [33:0] ph_ext = {{18{opa[15]}}, opa};
  wire signed [33:0] phase_full =
        (ph_ext <<< 15) - (ph_ext <<< 13) + (ph_ext <<< 10)
      + (ph_ext <<< 7)  + (ph_ext <<< 3);
  wire signed [15:0] phase_rad = sat34(phase_full >>> 15);

  // 9949 = 2^13 + 2^11 - 2^8 - 2^5 - 2^2 + 2^0 (CSD, same script).
  wire signed [33:0] mg_ext = {{16{cx[17]}}, cx};
  wire signed [33:0] mag_full =
        (mg_ext <<< 13) + (mg_ext <<< 11) - (mg_ext <<< 8)
      - (mg_ext <<< 5)  - (mg_ext <<< 2)  + mg_ext;
  wire signed [15:0] mag_q14 = sat34(mag_full >>> 14);

  function signed [15:0] atan_of;
    input [3:0] i;
    begin
      case (i)
        4'd0:    atan_of = A0;
        4'd1:    atan_of = A1;
        4'd2:    atan_of = A2;
        4'd3:    atan_of = A3;
        4'd4:    atan_of = A4;
        4'd5:    atan_of = A5;
        4'd6:    atan_of = A6;
        4'd7:    atan_of = A7;
        4'd8:    atan_of = A8;
        4'd9:    atan_of = A9;
        4'd10:   atan_of = A10;
        4'd11:   atan_of = A11;
        4'd12:   atan_of = A12;
        4'd13:   atan_of = A13;
        default: atan_of = A14;
      endcase
    end
  endfunction

  wire signed [15:0] atn16 = atan_of(iter);
  wire signed [17:0] atn   = {{2{atn16[15]}}, atn16};
  wire signed [17:0] axi   = cx >>> iter;
  wire signed [17:0] ayi   = cy >>> iter;

  reg signed [17:0] sxn, syn, szn;

  always @(*) begin
    if (!vmode) begin
      if (cz >= 0) begin sxn = cx - ayi; syn = cy + axi; szn = cz - atn; end
      else         begin sxn = cx + ayi; syn = cy - axi; szn = cz + atn; end
    end else begin
      if (cy < 0)  begin sxn = cx - ayi; syn = cy + axi; szn = cz - atn; end
      else         begin sxn = cx + ayi; syn = cy - axi; szn = cz + atn; end
    end
  end

  /* ───────────────────────── magnitude helpers ───────────────────── */

  wire [15:0] absa  = opa[15] ? (~opa + 16'd1) : opa;   // |y|
  wire [15:0] absb  = opb[15] ? (~opb + 16'd1) : opb;   // |x|
  wire [15:0] ayq   = absa >> 1;
  wire [15:0] axq   = absb >> 1;
  wire [15:0] bigq  = (ayq > axq) ? ayq : axq;
  wire [15:0] bigs  = bigq << shf;
  wire        ybig  = (ayq > axq);

  // One shift-add step of the product.
  //
  // The operand is two's complement, so its top bit carries weight -2^15, not
  // +2^15: the last step (mcnt == 1, i.e. mca == a<<15) must SUBTRACT. Doing
  // it with an add yields the unsigned product, which is off by exactly
  // a<<15 whenever the operand is negative — the first defect this loop had.
  reg signed [33:0] accn;
  always @(*) begin
    if (!mcb[0])    accn = acc;
    else if (mcnt == 5'd1) accn = acc - mca;
    else            accn = acc + mca;
  end

  /* ───────────────────────── sequencing ──────────────────────────── */

  wire [2:0] nbytes = {1'b0, nres, 1'b0};

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      opa <= 16'd0; opb <= 16'd0; wcnt <= 2'd0; rcnt <= 2'd0; nres <= 2'd1;
      res0 <= 16'd0; res1 <= 16'd0; valid <= 1'b0; busy <= 1'b0;
      cx <= 18'sd0; cy <= 18'sd0; cz <= 18'sd0; iter <= 4'd0; st <= S_IDLE;
      vmode <= 1'b0; swapped <= 1'b0; shf <= 3'd0; shfl <= 3'd0;
      qx <= 1'b0; qy <= 1'b0; q1 <= 1'b0; qm1 <= 1'b0; a16 <= 16'd0;
      acc <= 34'sd0; mca <= 18'sd0; mcb <= 16'd0; mcnt <= 5'd0;
    end else begin
      case (st)

        /* ── operand intake ───────────────────────────────────────── */
        S_IDLE: begin
          valid <= 1'b0;
          busy  <= 1'b0;
          if (srst) wcnt <= 2'd0;
          if (wr) begin
            case (wcnt)
              2'd0:    begin opa[7:0]  <= ui_in; wcnt <= 2'd1; end
              2'd1:    begin opa[15:8] <= ui_in; wcnt <= 2'd2; end
              2'd2:    begin opb[7:0]  <= ui_in; wcnt <= 2'd3; end
              default: begin opb[15:8] <= ui_in; end
            endcase
          end
          if (go) begin
            wcnt  <= 2'd0;
            rcnt  <= 2'd0;
            busy  <= 1'b1;
            shf   <= 3'd0;
            qx    <= opb[15];
            qy    <= opa[15];
            nres  <= (op == OP_SINCOS) ? 2'd2 : 2'd1;
            st    <= (op == OP_ATAN2 || op == OP_HYPOT) ? S_PRE : S_CONV;
          end
        end

        /* ── phase -> radians, or set up the product ──────────────── */
        S_CONV: begin
          if (op == OP_SINCOS) begin
            cz <= {{2{phase_rad[15]}}, phase_rad};
            st <= S_FOLD;
          end else begin
            // MUL: a*b as 16 shift-add steps, truncating at the end
            acc  <= 34'sd0;
            mca  <= {{18{opa[15]}}, opa};   // sign-extended addend, 34 bits
            mcb  <= opb;                    // LSB first; see S_MPY
            mcnt <= 5'd16;
            st   <= S_MPY;
          end
        end

        /* ── bit-serial multiply ──────────────────────────────────── */
        S_MPY: begin
          // 16 steps, LSB first: add `a << i` when bit i of b is set. `mca`
          // is 34 bits wide so the shifted addend never truncates
          // (|a| <= 2^15, 15 shifts => 2^30, plus the sum => 2^31).
          acc  <= accn;
          mca  <= mca <<< 1;
          mcb  <= mcb >> 1;
          mcnt <= mcnt - 5'd1;
          if (mcnt == 5'd1) st <= S_MPYW;
        end

        S_MPYW: begin
                  // acc = a*b exactly; an arithmetic >>15 is the Q1.15 product
          res0 <= sat34(acc >>> 15);
          st   <= S_OUT;
        end

        /* ── prescale, one left shift per visit ───────────────────── */
        S_PRE: begin
          // Shift up while the Q2.14 magnitude is below 4096, capped at four
          // shifts — the same rule as `prescale` in the model.
          if (bigs < 16'd4096 && shf < 3'd4) begin
            shf <= shf + 3'd1;
          end else begin
            vmode <= 1'b1;
            shfl  <= shf;
            if (ybig) begin
              cx <= $signed({2'b00, ayq}) <<< shf;
              cy <= $signed({2'b00, axq}) <<< shf;
            end else begin
              cx <= $signed({2'b00, axq}) <<< shf;
              cy <= $signed({2'b00, ayq}) <<< shf;
            end
            swapped <= ybig;
            cz   <= 18'sd0;
            iter <= 4'd0;
            st   <= S_RUN;
          end
        end

        /* ── 15 CORDIC iterations ─────────────────────────────────── */
        S_RUN: begin
          cx <= sxn;
          cy <= syn;
          cz <= szn;
          if (iter == 4'd14) begin
            iter <= 4'd0;
            st   <= (op == OP_HYPOT) ? S_MAG : S_PACK;
          end else begin
            iter <= iter + 4'd1;
          end
        end

        /* ── hypot: divide the gain out, undo the prescale ────────── */
        S_MAG: begin
          // mag_q14 is (cx/ K) in Q2.14; undo the up-shifts, saturating.
          if (shfl == 3'd0)      res0 <= mag_q14;
          else if (shfl == 3'd1) res0 <= mag_q14 >> 1;
          else if (shfl == 3'd2) res0 <= mag_q14 >> 2;
          else if (shfl == 3'd3) res0 <= mag_q14 >> 3;
          else                   res0 <= mag_q14 >> 4;
          st <= S_OUT;
        end

        /* ── SINCOS: fold the angle, then rotate ──────────────────── */
        S_FOLD: begin
          if (cz > HALF) begin
            cz  <= cz - HALF;
            q1  <= 1'b1; qm1 <= 1'b0;
          end else if (cz < -HALF) begin
            cz  <= cz + HALF;
            q1  <= 1'b0; qm1 <= 1'b1;
          end else begin
            q1  <= 1'b0; qm1 <= 1'b0;
          end
          cx    <= KQ14;                  // 1/K: gain-compensating start
          cy    <= 18'sd0;
          vmode <= 1'b0;
          iter  <= 4'd0;
          st    <= S_RUN;
        end

        /* ── results ──────────────────────────────────────────────── */
        S_PACK: begin
          if (op == OP_SINCOS) begin
            // cx = cos(r), cy = sin(r) in Q2.14; apply the quadrant
            if (q1) begin
              res0 <= q15(cx);              // sin =  cos(r)
              res1 <= q15n(cy);             // cos = -sin(r)
            end else if (qm1) begin
              res0 <= q15n(cx);             // sin = -cos(r)
              res1 <= q15(cy);              // cos =  sin(r)
            end else begin
              res0 <= q15(cy);
              res1 <= q15(cx);
            end
          end else begin
            // ATAN2: a = atan(|y|/|x|), then the signs.
            if (swapped) a16 = 16'sd12868 - cz[15:0];
            else         a16 = cz[15:0];
            case ({qx, qy})
              2'b00:   res0 <= a16;
              2'b01:   res0 <= -a16;
              2'b10:   res0 <= 16'sd25736 - a16;
              default: res0 <= a16 - 16'sd25736;
            endcase
          end
          st <= S_OUT;
        end

        /* ── present result bytes ─────────────────────────────────── */
        S_OUT: begin
          busy  <= 1'b0;
          valid <= 1'b1;
          if (ack && valid) begin
            if ({1'b0, rcnt} + 3'd1 < nbytes) begin
              rcnt <= rcnt + 2'd1;
            end else begin
              valid <= 1'b0;
              rcnt  <= 2'd0;
              st    <= S_IDLE;
            end
          end
        end

        default: st <= S_IDLE;
      endcase
    end
  end

  /* ───────────────────────── outputs ─────────────────────────────── */

  reg [7:0] obyte;
  always @(*) begin
    case (rcnt)
      2'd0:    obyte = res0[7:0];
      2'd1:    obyte = res0[15:8];
      2'd2:    obyte = res1[7:0];
      default: obyte = res1[15:8];
    endcase
  end

  assign uo_out       = obyte;
  assign uio_out[6]   = valid;
  assign uio_out[7]   = busy;
  assign uio_out[5:0] = 6'b000000;
  assign uio_oe       = 8'b1100_0000;

endmodule
