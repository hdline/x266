// Copyright (c) 2016-2017 Min Chen
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// 1. Redistributions of source code must retain the above copyright notice, this
// list of conditions and the following disclaimer.
//
// 2. Redistributions in binary form must reproduce the above copyright notice,
// this list of conditions and the following disclaimer in the documentation
// and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
// ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
// FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
// SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
// OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

import ConfigReg::*;
import Vector::*;
import GetPut::*;
import FIFOF::*;
import SpecialFIFOs::*;
import BUtils::*;
import Connectable::*;

interface ISatd8;
   interface Put#(Vector#(8, Bit#(9))) io_in;
   interface Get#(Bit#(19)) io_out;
endinterface

interface ISatd8x2;
   interface Put#(Vector#(16, Bit#(9))) io_in;
   interface Get#(Vector#(2, Bit#(19))) io_out;
endinterface

function Vector#(8, Bit#(na)) satd_1d(Vector#(8, Bit#(n)) x)
   provisos(
      Add#(n, 3, na)
   );
   Vector#(8, Bit#(na)) m0;
   Vector#(8, Bit#(na)) m1;
   Vector#(8, Bit#(na)) m2;

   m0[0] = sExtend(x[0]) + sExtend(x[4]);
   m0[1] = sExtend(x[1]) + sExtend(x[5]);
   m0[2] = sExtend(x[2]) + sExtend(x[6]);
   m0[3] = sExtend(x[3]) + sExtend(x[7]);
   m0[4] = sExtend(x[0]) - sExtend(x[4]);
   m0[5] = sExtend(x[1]) - sExtend(x[5]);
   m0[6] = sExtend(x[2]) - sExtend(x[6]);
   m0[7] = sExtend(x[3]) - sExtend(x[7]);

   m1[0] = m0[0] + m0[2];
   m1[1] = m0[1] + m0[3];
   m1[2] = m0[0] - m0[2];
   m1[3] = m0[1] - m0[3];
   m1[4] = m0[4] + m0[6];
   m1[5] = m0[5] + m0[7];
   m1[6] = m0[4] - m0[6];
   m1[7] = m0[5] - m0[7];

   m2[0] = m1[0] + m1[1];
   m2[1] = m1[0] - m1[1];
   m2[2] = m1[2] + m1[3];
   m2[3] = m1[2] - m1[3];
   m2[4] = m1[4] + m1[5];
   m2[5] = m1[4] - m1[5];
   m2[6] = m1[6] + m1[7];
   m2[7] = m1[6] - m1[7];

   return m2;
endfunction

(* synthesize *)
module mkSatd8(ISatd8);
   FIFOF#(Vector#(8, Bit#(9)))               fifo_inp    <- mkPipelineFIFOF;
   FIFOF#(Bit#(19))                          fifo_out    <- mkPipelineFIFOF;

   RWire#(Vector#(8, Bit#(12)))              rw_trans    <- mkRWire;
   RWire#(Bool)                              rw_oflag    <- mkRWire;

   Reg#(Bit#(8))                             flags       <- mkConfigReg(0);
   Reg#(Bool)                                dir         <- mkConfigReg(True);
   Vector#(8, Reg#(Vector#(8, Bit#(12))))    matrix      <- replicateM(mkConfigRegU);

   Reg#(Bit#(3))                             sum_cnt     <- mkReg(0);
   Reg#(Bit#(21))                            sum_satd    <- mkReg(0);

   rule shift_matrix(isValid(rw_trans.wget) || flags[7] != 0);
      let x = fromMaybe(?, rw_trans.wget);
      let y = isValid(rw_trans.wget) ? 1 : 0;
      
      if (dir) begin
         // Row shift
         for(Integer i = 0; i < 8 - 1; i = i + 1) begin
            matrix[i] <= matrix[i + 1];
         end
         matrix[8 - 1] <= x;
      end
      else begin
         // Column shift
         for(Integer i = 0; i < 8; i = i + 1) begin
            matrix[i] <= shiftInAtN(matrix[i], x[i]);
         end
      end

      let next_flags = (flags << 1) + y;
      flags <= next_flags;
      if (next_flags == 8'b1111_1111)
         dir <= !dir;
   endrule

   rule do_2d(flags[7] != 0);
      Vector#(8, Bit#(12)) tmp = ?;

      // Get 2D SATD data
      if (dir) begin
         tmp = matrix[0];
      end
      else begin
         for(Integer i = 0; i < 8; i = i + 1) begin
            tmp[i] = matrix[i][0];
         end
      end

      //$display("[COL ] %04X-%04X-%04X-%04X-%04X-%04X-%04X-%04X", tmp[0], tmp[1], tmp[2], tmp[3], tmp[4], tmp[5], tmp[6], tmp[7]);

      // 2D Transform
      let x = satd_1d(tmp);

      //$display("[TRN2] %04X-%04X-%04X-%04X-%04X-%04X-%04X-%04X", x[0], x[1], x[2], x[3], x[4], x[5], x[6], x[7]);

      // Sum of row
      Bit#(16) sum = 0;

      for(Integer i = 0; i < 8; i = i + 1) begin
         Int#(15) v = unpack(x[i]);
         sum = sum + zExtend(pack(abs(v)));
      end

      // Sum 8 rows to final value
      let next_sum_satd = sum_satd + zExtend(sum);

      if (sum_cnt == 3'b111) begin
         let y = truncate((next_sum_satd + 2) >> 2);
         fifo_out.enq(y);
         next_sum_satd = 0;
      end
      sum_satd <= next_sum_satd;
      sum_cnt <= sum_cnt + 1;
   endrule

   rule do_1d(fifo_inp.notEmpty());
      let x = fifo_inp.first;
      fifo_inp.deq;

      //$display("[INP ] %03X-%03X-%03X-%03X-%03X-%03X-%03X-%03X", x[0], x[1], x[2], x[3], x[4], x[5], x[6], x[7]);

      let y = satd_1d(x);

      //$display("[TRN1] %04X-%04X-%04X-%04X-%04X-%04X-%04X-%04X", y[0], y[1], y[2], y[3], y[4], y[5], y[6], y[7]);

      rw_trans.wset(y);
   endrule

   interface Put io_in = toPut(fifo_inp);
   interface Get io_out = toGet(fifo_out);
endmodule


(* synthesize *)
module mkSatd8x2(ISatd8x2);
   ISatd8   satd0    <- mkSatd8;
   ISatd8   satd1    <- mkSatd8;

   interface Put io_in = interface Put;
                          method Action put(Vector#(16, Bit#(9)) x);
                             Vector#(2, Vector#(8, Bit#(9))) y = unpack(pack(x));
                             satd0.io_in.put(y[0]);
                             satd1.io_in.put(y[1]);
                          endmethod
                       endinterface;
   
   interface Get io_out = interface Get;
                          method ActionValue#(Vector#(2, Bit#(19))) get();
                             let x0 <- satd0.io_out.get();
                             let x1 <- satd1.io_out.get();
                             Vector#(2, Bit#(19)) y = unpack({x0, x1});
                             return y;
                          endmethod
                       endinterface;
endmodule


`ifdef TEST_BENCH_mkSatd
import "BDPI" function Action satd8x8_genNew();
import "BDPI" function ActionValue#(Vector#(8, Bit#(16))) satd8x8_getDiff();
import "BDPI" function ActionValue#(Bit#(19)) satd8x8_getSatd();

(* synthesize *)
module mkTb(Empty);
   FIFOF#(Vector#(8, Bit#(9)))      fifo_in  <- mkPipelineFIFOF;
   ISatd8                           dut      <- mkSatd8;
   Reg#(Bit#(8))                    cnt      <- mkReg(0);
   Reg#(Bit#(4))                    state    <- mkReg(0);
   Reg#(Bit#(16))                   cycles   <- mkReg(0);

   mkConnection(toGet(fifo_in), dut.io_in);

   rule do_cycles;
      cycles <= cycles + 1;
   endrule

   rule do_init(state == 0);
      satd8x8_genNew();
      state <= 1;
   endrule
   
   rule do_data(state >= 1 && state <= 8);
      let xx <- satd8x8_getDiff();
      Vector#(8, Bit#(9)) x = map(truncate, xx);

      fifo_in.enq(x);
      state <= state + 1;
   endrule

   rule do_check(state == 9);
      let x <- satd8x8_getSatd();
      let y <- dut.io_out.get();

      if (x == y) begin
         $display("Check %d passed\n", cnt);
      end
      else begin
         $display("Check %d failed, Satd = %d -> %d\n", cnt, y, x);
         $finish;
      end

      if (cnt == 255)
          $finish;

      cnt <= cnt + 1;
      state <= 0;
   endrule

endmodule

`endif
