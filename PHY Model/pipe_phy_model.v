`timescale 1ns/1ps
// Simulation-only Original PIPE Gen1/Gen2, x1, 8-bit PHY BFM.
// See README.txt for the checked contract, abstractions and diagnostic codes.
// No DUT internals are inspected. All protocol checks use PIPE pins.
module pcie_pipe_phy_model #(
    parameter integer STARTUP_CYCLES = 8,
    parameter integer POWER_CYCLES = 4,
    parameter integer RATE_CYCLES = 6,
    parameter integer DETECT_CYCLES = 5,
    parameter integer STANDBY_CYCLES = 3,
    parameter realtime GEN1_PERIOD_NS = 4.0,
    parameter realtime GEN2_PERIOD_NS = 2.0,
    parameter realtime RATE_PAUSE_NS = 0.0,
    parameter integer CHECK_P1_RX_IDLE = 1,
    parameter integer CHECK_K_CODES = 1,
    parameter integer STOP_ON_ERROR = 0,
    parameter integer VERBOSE = 1
) (
    // Exact PHY-facing interface of pcie_pipe_mac_if_v3.
    input  wire       Reset_n,
    output reg        PCLK,
    input  wire [7:0] TxData,
    input  wire       TxDataK, TxElecIdle, TxCompliance, TxDetectRx,
    input  wire [1:0] PowerDown,
    input  wire       Rate, RxStandby, TxDeemph,
    input  wire [2:0] TxMargin,
    input  wire       TxSwing, RxPolarity,
    output reg  [7:0] RxData,
    output reg        RxDataK, RxValid,
    output wire       RxElecIdle,
    output reg  [2:0] RxStatus,
    output reg        RxStandbyStatus, PhyStatus,

    // Testbench/environment controls: these are NOT physical PIPE pins.
    input wire       sim_receiver_present,
    input wire [7:0] sim_rx_data,
    input wire       sim_rx_datak, sim_rx_valid, sim_rx_elecidle,
    input wire [2:0] sim_rx_status,
    // Independent environmental knowledge of a quiescent incoming link.
    // In Gen2, this must not be inferred from RxElecIdle alone.
    input wire       sim_rx_quiescent,
    input wire       sim_stall_startup, sim_stall_power, sim_stall_rate,
    input wire       sim_stall_detect, sim_stall_standby,
    input wire       sim_detect_override_en,
    input wire [2:0] sim_detect_override_status,

    // Abstract outgoing link symbols (not a serial electrical waveform).
    output reg  [7:0] sim_tx_data,
    output reg        sim_tx_datak, sim_tx_valid,
    output reg        model_ready, model_busy, model_fault,
    output reg  [1:0] confirmed_power,
    output reg        confirmed_rate, model_loopback,
    // One-cycle diagnostic event, with sticky last code/op and counters.
    output reg        diag_valid, diag_pass,
    output reg  [7:0] diag_code,
    output reg  [3:0] diag_op,
    output integer   error_count, success_count, tx_symbol_count
);
    localparam [1:0] P0=0, P0S=1, P1=2, P2=3;
    localparam [3:0] OP_NONE=0, OP_RESET=1, OP_POWER=2,
                     OP_RATE=3, OP_DETECT=4, OP_STANDBY=5,
                     OP_LOOPBACK=6, OP_DATA=7;
    localparam [7:0] E_UNKNOWN=1, E_STARTUP=2, E_P2=3,
        E_POWER_PATH=4, E_TX_IDLE=5, E_RX_ACTIVE=6,
        E_RATE_STATE=7, E_STANDBY=8, E_OVERLAP=9,
        E_CONTROL_CHANGED=10, E_DETECT_HOLD=11,
        E_DETECT_ENCODING=12, E_GEN1_DEEMPH=13,
        E_COMPLIANCE=14, E_BAD_K=15, E_STANDBY_ABORT=16;

    reg [3:0] operation;
    integer startup_left, cycles_left, standby_left;
    reg [1:0] request_power;
    reg request_rate, request_standby, request_detect;
    reg request_stall, detect_present, detect_override;
    reg [2:0] detect_status;
    reg standby_wait, standby_target, detect_needs_low;
    reg clock_rate;
    realtime pause_left, half_period;
    // Convenient for the waveform viewer / hierarchical TB inspection.
    string last_message;

    // Each complete cycle uses one period. Rate changes occur at a cycle
    // boundary, never by truncating a high pulse. A requested clock pause
    // extends only the low phase; wall-clock timeouts belong in the TB.
    initial begin
        PCLK = 0;
        clock_rate = 0;
        pause_left = 0.0;
        forever begin
            if (pause_left > 0.0) begin
                #(pause_left);
                pause_left = 0.0;
            end
            half_period = (clock_rate ? GEN2_PERIOD_NS : GEN1_PERIOD_NS)/2.0;
            #(half_period) PCLK = 1;
            #(half_period) PCLK = 0;
        end
    end

    // Rx electrical idle is deliberately asynchronous and independent of TX.
    assign RxElecIdle = !Reset_n ? 1'b1 : sim_rx_elecidle;

    function automatic bit legal_power(input [1:0] from_p, input [1:0] to_p);
        case (from_p)
            P0: legal_power = (to_p==P0S || to_p==P1);
            P0S, P1: legal_power = (to_p==P0);
            default: legal_power = 0;
        endcase
    endfunction

    // Recognizes legal 8b/10b K encodings; it does not check ordered sets.
    function automatic bit legal_k(input [7:0] d);
        legal_k = (d[4:0]==28) ||
                  ((d[7:5]==7) && (d[4:0]==23 || d[4:0]==27 ||
                                   d[4:0]==29 || d[4:0]==30));
    endfunction

    task automatic report_ok(input [3:0] op, input string message);
        begin
            diag_valid <= 1; diag_pass <= 1; diag_code <= 0; diag_op <= op;
            last_message = message;
            success_count = success_count + 1;
            if (VERBOSE) $display("[%0t] PHY PASS op=%0d: %s", $time, op, message);
        end
    endtask

    // Invalid requests have undefined real-PHY behavior. This BFM chooses
    // reset-required fault + no completion. It never invents a PIPE error ACK.
    task automatic reject(input [7:0] code, input [3:0] op, input string message);
        begin
            if (!model_fault) begin
                model_fault = 1;
                model_busy = 0;
                operation = OP_NONE;
                PhyStatus <= 0;
                RxValid <= 0; RxStatus <= 0; sim_tx_valid <= 0;
                diag_valid <= 1; diag_pass <= 0; diag_code <= code; diag_op <= op;
                error_count = error_count + 1;
                last_message = message;
                $display("[%0t] PHY FAIL code=%0d op=%0d: %s", $time, code, op, message);
                if (STOP_ON_ERROR) $fatal(1, "PHY checker failure: %s", message);
            end
        end
    endtask

    task automatic launch(input [3:0] op, input integer delay_cycles, input bit stall);
        begin
            operation = op;
            cycles_left = delay_cycles;
            model_busy = 1;
            request_power = PowerDown;
            request_rate = Rate;
            request_standby = RxStandby;
            request_detect = TxDetectRx;
            request_stall = stall;
            if (op == OP_DETECT) begin
                detect_present = sim_receiver_present;
                detect_override = sim_detect_override_en;
                detect_status = sim_detect_override_status;
            end
            if (VERBOSE) $display("[%0t] PHY START op=%0d power=%0d rate=%0d stall=%0b",
                                   $time, op, PowerDown, Rate, stall);
        end
    endtask

    // Blocking assignments below describe private BFM bookkeeping only.
    // PHY-to-DUT outputs use nonblocking assignments: a response generated
    // here is sampled by the DUT on the FOLLOWING rising edge, without a race.
    always @(posedge PCLK or negedge Reset_n) begin
        if (!Reset_n) begin
            RxData <= 0; RxDataK <= 0; RxValid <= 0; RxStatus <= 0;
            RxStandbyStatus <= 1; PhyStatus <= 1;
            sim_tx_data <= 0; sim_tx_datak <= 0; sim_tx_valid <= 0;
            model_ready = 0; model_busy = 0; model_fault = 0;
            confirmed_power = P1; confirmed_rate = 0; model_loopback = 0;
            operation = OP_NONE; startup_left = STARTUP_CYCLES;
            cycles_left = 0; standby_left = 0; standby_wait = 0;
            standby_target = 0; detect_needs_low = 0;
            request_power = P1; request_rate = 0; request_standby = 0;
            request_detect = 0; request_stall = 0;
            detect_present = 0; detect_override = 0; detect_status = 0;
            clock_rate = 0; pause_left = 0.0;
            diag_valid <= 0; diag_pass <= 0; diag_code <= 0; diag_op <= OP_NONE;
            error_count = 0; success_count = 0; tx_symbol_count = 0;
            last_message = "Reset asserted";
        end else begin
            diag_valid <= 0;
            RxValid <= 0; RxStatus <= 0; sim_tx_valid <= 0;
            if (model_fault) begin
                PhyStatus <= 0;
            end else if (!model_ready) begin
                // Reset values must remain in place throughout startup.
                if ({PowerDown,Rate,TxElecIdle,TxDetectRx,TxCompliance}
                    !== {P1,1'b0,1'b1,1'b0,1'b0})
                    reject(E_STARTUP,OP_RESET,"Operation or unsafe controls before startup completed");
                else if (!sim_stall_startup) begin
                    if (startup_left <= 1) begin
                        model_ready = 1;
                        PhyStatus <= 0;
                        report_ok(OP_RESET,"Startup complete: P1, Gen1, PCLK available");
                    end else startup_left = startup_left - 1;
                end
            end else begin
                // Global validity checks precede all operations.
                if ((^{PowerDown,Rate,TxElecIdle,TxDetectRx,RxStandby,
                       TxCompliance,TxDeemph,TxMargin,TxSwing,RxPolarity}) === 1'bx)
                    reject(E_UNKNOWN,OP_NONE,"X/Z on a required PIPE control pin");
                else if (PowerDown == P2)
                    reject(E_P2,OP_POWER,"P2 is outside this model's supported profile");
                else if (!Rate && !TxDeemph)
                    reject(E_GEN1_DEEMPH,OP_NONE,"Gen1 requires TxDeemph=1 (-3.5 dB)");
                else if (TxCompliance && (PowerDown!=P0 || TxElecIdle))
                    reject(E_COMPLIANCE,OP_DATA,"TxCompliance asserted outside active P0 transmission");

                if (!model_fault) begin
                    if (model_busy) begin
                        // Maintain the request THROUGH the edge that samples
                        // PhyStatus high. Deassertion after that edge is legal.
                        if (operation==OP_DETECT && !TxDetectRx)
                            reject(E_DETECT_HOLD,OP_DETECT,"TxDetectRx withdrawn before detection completion was sampled");
                        else if ({PowerDown,Rate,RxStandby,TxDetectRx} !==
                                 {request_power,request_rate,request_standby,request_detect})
                            reject(E_CONTROL_CHANGED,operation,"Operation controls changed before completion was sampled");
                        else if (!TxElecIdle)
                            reject(E_TX_IDLE,operation,"TxElecIdle must remain asserted throughout this operation");
                        else if (PhyStatus) begin
                            // Completion was generated last edge; DUT consumes
                            // it now. Requests cannot start on this same edge.
                            PhyStatus <= 0;
                            model_busy = 0;
                            operation = OP_NONE;
                        end else if (!request_stall) begin
                            if (operation==OP_RATE && cycles_left==3) begin
                                // At least one full new-frequency cycle before ACK.
                                clock_rate = request_rate;
                                pause_left = RATE_PAUSE_NS;
                            end
                            if (cycles_left <= 1) begin
                                PhyStatus <= 1;
                                case (operation)
                                    OP_POWER: begin
                                        confirmed_power = request_power;
                                        report_ok(OP_POWER,$sformatf("Power state confirmed: %0d",confirmed_power));
                                    end
                                    OP_RATE: begin
                                        confirmed_rate = request_rate;
                                        report_ok(OP_RATE,$sformatf("Rate confirmed: Gen%0d",confirmed_rate+1));
                                    end
                                    OP_DETECT: begin
                                        RxStatus <= detect_override ? detect_status :
                                                    (detect_present ? 3'b011 : 3'b000);
                                        detect_needs_low = 1;
                                        if (detect_override) begin
                                            // Test stimulus, not a successful protocol result.
                                            diag_valid <= 1; diag_pass <= 0;
                                            diag_code <= 8'h80; diag_op <= OP_DETECT;
                                            last_message = $sformatf("Injected detection response=%03b",detect_status);
                                            if (VERBOSE) $display("[%0t] PHY INJECT: %s",$time,last_message);
                                        end else report_ok(OP_DETECT,detect_present ?
                                            "Detection completed: receiver present" :
                                            "Detection completed: receiver absent (valid result)");
                                    end
                                endcase
                            end else cycles_left = cycles_left - 1;
                        end
                    end else begin
                        PhyStatus <= 0;
                        if (!TxDetectRx) detect_needs_low = 0;
                        if (PowerDown != confirmed_power && Rate != confirmed_rate)
                            reject(E_OVERLAP,OP_NONE,"Simultaneous rate and power changes unsupported by this profile");
                        else if (PowerDown != confirmed_power) begin
                            if (detect_needs_low || TxDetectRx || model_loopback)
                                reject(E_OVERLAP,OP_POWER,"Exit detect/loopback before changing power");
                            else if (!legal_power(confirmed_power,PowerDown))
                                reject(E_POWER_PATH,OP_POWER,"Unsupported transition; P0s and P1 must transition via P0");
                            else if (!TxElecIdle)
                                reject(E_TX_IDLE,OP_POWER,"Power transition requires TX electrical idle in this profile");
                            else if (CHECK_P1_RX_IDLE && PowerDown==P1 && sim_rx_quiescent!==1'b1)
                                reject(E_RX_ACTIVE,OP_POWER,"P1 entry requires an idle incoming link; environment reports active RX");
                            else launch(OP_POWER,POWER_CYCLES,sim_stall_power);
                        end else if (Rate != confirmed_rate) begin
                            if (detect_needs_low || TxDetectRx || model_loopback)
                                reject(E_OVERLAP,OP_RATE,"Exit detect/loopback before changing rate");
                            else if (confirmed_power!=P0 && confirmed_power!=P1)
                                reject(E_RATE_STATE,OP_RATE,"Rate change allowed only in P0 or P1");
                            else if (!TxElecIdle)
                                reject(E_TX_IDLE,OP_RATE,"Rate change requires TX electrical idle");
                            else if (confirmed_power==P0 && (!RxStandby || !RxStandbyStatus))
                                reject(E_STANDBY,OP_RATE,"P0 rate change requires RxStandby and its acknowledgement");
                            else launch(OP_RATE,RATE_CYCLES,sim_stall_rate);
                        end else if (confirmed_power!=P0 && !TxElecIdle)
                            reject(E_TX_IDLE,OP_NONE,"TX must remain electrically idle in P0s/P1");
                        else if (TxDetectRx && confirmed_power==P1) begin
                            if (!detect_needs_low) launch(OP_DETECT,DETECT_CYCLES,sim_stall_detect);
                        end else if (TxDetectRx && confirmed_power==P0) begin
                            if (TxElecIdle)
                                reject(E_DETECT_ENCODING,OP_LOOPBACK,"P0 loopback requires TxDetectRx=1 and TxElecIdle=0");
                            else if (!model_loopback) begin
                                model_loopback = 1;
                                report_ok(OP_LOOPBACK,"Loopback enabled: incoming link symbols forwarded to outgoing link");
                            end
                        end else if (TxDetectRx)
                            reject(E_DETECT_ENCODING,OP_DETECT,"TxDetectRx has no supported operation in P0s");
                        else if (model_loopback) begin
                            model_loopback = 0;
                            report_ok(OP_LOOPBACK,"Loopback disabled");
                        end
                    end
                end

                // Standby has its own acknowledgement, not PhyStatus.
                if (!model_fault && !model_busy &&
                    (confirmed_power==P0 || confirmed_power==P0S)) begin
                    if (standby_wait) begin
                        if (RxStandby != standby_target)
                            reject(E_STANDBY_ABORT,OP_STANDBY,"RxStandby changed before RxStandbyStatus acknowledged it");
                        else if (!sim_stall_standby) begin
                            if (standby_left <= 1) begin
                                RxStandbyStatus <= standby_target;
                                standby_wait = 0;
                                report_ok(OP_STANDBY,$sformatf("Receiver standby state confirmed: %0b",standby_target));
                            end else standby_left = standby_left - 1;
                        end
                    end else if (RxStandby != RxStandbyStatus) begin
                        standby_wait = 1;
                        standby_target = RxStandby;
                        standby_left = STANDBY_CYCLES;
                    end
                end else if (!model_fault && confirmed_power==P1) begin
                    // Undefined by PIPE in P1; use deterministic 1 here.
                    RxStandbyStatus <= 1;
                    standby_wait = 0;
                end

                // Symbol-level abstraction. There is no TX ready handshake:
                // each active PCLK transfers a symbol. No automatic TX->RX echo.
                if (!model_fault && !model_busy) begin
                    if ((confirmed_power==P0 || confirmed_power==P0S) &&
                        !RxStandby && !RxStandbyStatus && !sim_rx_elecidle && sim_rx_valid) begin
                        RxData <= sim_rx_data;
                        RxDataK <= sim_rx_datak;
                        RxStatus <= sim_rx_status;
                        RxValid <= 1;
                    end
                    if (confirmed_power==P0 && !TxElecIdle) begin
                        if (model_loopback) begin
                            // Decoded symbols stand in for serial RX->TX loopback.
                            // Full serial latency / EIOS drain is outside scope.
                            if (!RxStandby && !RxStandbyStatus && !sim_rx_elecidle && sim_rx_valid) begin
                                sim_tx_data <= sim_rx_data;
                                sim_tx_datak <= sim_rx_datak;
                                sim_tx_valid <= 1;
                                tx_symbol_count = tx_symbol_count + 1;
                            end
                        end else if ((^{TxData,TxDataK}) === 1'bx)
                            reject(E_UNKNOWN,OP_DATA,"X/Z on active transmit data or TxDataK");
                        else if (CHECK_K_CODES && TxDataK && !legal_k(TxData))
                            reject(E_BAD_K,OP_DATA,$sformatf("Invalid 8b/10b K character: 0x%02h",TxData));
                        else begin
                            sim_tx_data <= TxData;
                            sim_tx_datak <= TxDataK;
                            sim_tx_valid <= 1;
                            tx_symbol_count = tx_symbol_count + 1;
                        end
                    end
                end
            end
        end
    end

    initial begin
        $timeformat(-9, 3, " ns", 12);
        if (STARTUP_CYCLES<1 || POWER_CYCLES<1 || RATE_CYCLES<3 ||
            DETECT_CYCLES<1 || STANDBY_CYCLES<1 || GEN1_PERIOD_NS<=0 ||
            GEN2_PERIOD_NS<=0 || RATE_PAUSE_NS<0)
            $fatal(1,"Invalid PHY model timing parameters (RATE_CYCLES must be >=3)");
    end
endmodule
