# PCIe Gen1/Gen2 Loopback Reference

Scope: PCIe Gen1/Gen2, x1, 8b/10b, MAC + LTSSM + PIPE + PHY architecture. This sheet focuses on normal non-compliance Loopback behavior and the current `pcie_pipe_mac_if_v3` wrapper.

## 1. Main idea

Loopback is a PCIe Physical Layer test mode.

There are two roles:

- Loopback Master: requests Loopback, generates the test stream, receives the returned stream, and checks it.
- Loopback Slave: receives the Master's stream and retransmits the received encoded stream back toward the Master.

The important architectural rule is:

```text
Master sets TS1 Loopback bit = 1.
Slave asserts local mac_loopback = 1.
```

These are not the same control.

`TS1.Loopback = 1` is sent across the PCIe link to request that the remote device become the Loopback Slave.

`mac_loopback = 1` is a local MAC/LTSSM-to-PIPE-wrapper request that tells this device's PHY to perform loopback.

## 2. Responsibility split

```text
LTSSM
  decides Loopback role and state
  handles Loopback.Entry / Active / Exit
  decides when TS1 Loopback bit is asserted
  decides when local PHY loopback must be enabled

Ordered-Set Generator / Detector
  generates TS1 with Loopback bit
  detects received TS1 with Loopback bit
  generates/detects EIOS used for exit

PIPE MAC Wrapper
  receives mac_loopback
  checks that the local PIPE loopback command is legal
  drives TxDetectRx
  reports mac_loopback_active

PHY
  performs CDR / symbol recovery
  performs the actual receive-to-transmit loopback path
  serializes the returned stream
```

The LTSSM should not directly drive `TxDetectRx`. The LTSSM should drive `mac_loopback`; the PIPE wrapper owns `TxDetectRx`.

## 3. Important signals

### TS1 Loopback bit

Direction:

```text
Local LTSSM/OS Generator -> PCIe link -> Remote LTSSM
```

Meaning:

```text
"Remote device, enter Loopback as my Loopback Slave."
```

For a normal Loopback Master in `Loopback.Entry`:

```text
tx_os_type       = TS1
tx_loopback_bit  = 1
mac_loopback      = 0
```

The Master normally does not enable loopback in its own PHY.

### mac_loopback

Direction:

```text
LTSSM -> PIPE MAC wrapper
```

Meaning:

```text
"Enable loopback in my local PHY."
```

In the architecture used here, this is primarily asserted when the local device is the Loopback Slave.

### mac_loopback_active

Direction:

```text
PIPE MAC wrapper -> LTSSM
```

Meaning in the current wrapper:

```text
"The wrapper has established its local PIPE loopback condition and TX is active."
```

Current implementation:

```verilog
assign mac_loopback_active =
    loopback_mode &&
    !TxElecIdle;
```

This is not a separate acknowledgement from the PHY. It is wrapper-generated status.

### TxDetectRx

`TxDetectRx` is a dual-purpose PIPE signal.

```text
PowerDown = P0 -> TxDetectRx is used as Loopback control
PowerDown = P1 -> TxDetectRx is used for Receiver Detection
```

For local PHY loopback:

```text
PowerDown  = P0
TxDetectRx = 1
TxElecIdle = 0
```

The combination:

```text
PowerDown  = P0
TxDetectRx = 1
TxElecIdle = 1
```

must not be generated for this loopback command.

## 4. Current PIPE wrapper qualification

The current wrapper uses:

```verilog
assign loopback_request_valid =
    (state == ST_IDLE) &&
    !starting_operation &&
    mac_loopback &&
    (PowerDown == P0) &&
    !mac_tx_elecidle;
```

Interpretation:

```text
state == ST_IDLE
    wrapper is available

!starting_operation
    rate/power/receiver-detect operation is not launching

mac_loopback
    LTSSM requests local PHY loopback

PowerDown == P0
    required PIPE operating state for loopback

!mac_tx_elecidle
    transmitter must remain active; loopback is not requested together with Electrical Idle
```

The first two conditions are wrapper arbitration rules. They are not PCIe LTSSM state requirements.

The important PIPE-facing requirements are P0, Loopback asserted, and TX not in Electrical Idle.

When accepted:

```verilog
TxDetectRx    <= loopback_request_valid;
loopback_mode <= loopback_request_valid;
```

## 5. LTSSM Loopback substates

Use three substates:

```text
LOOPBACK_ENTRY
LOOPBACK_ACTIVE
LOOPBACK_EXIT
```

Also retain a role:

```text
LOOPBACK_MASTER
LOOPBACK_SLAVE
```

Master and Slave can both be in a Loopback substate while performing different actions.

## 6. How a Loopback Master starts

The mechanism that tells a device to become a Loopback Master is implementation-specific.

Examples of local implementation controls could be:

```text
software test register
verification/test input
internal diagnostic request
```

Do not use `mac_loopback` as the high-level request to become Master. In this design, `mac_loopback` specifically controls local PHY loopback.

Recommended separation:

```text
loopback_test_req
    -> tells LTSSM to initiate Loopback as Master

mac_loopback
    -> tells local PIPE PHY to act as Loopback Slave
```

For an already configured link, the LTSSM performs the applicable protocol transition into Loopback and the Master begins sending TS1 Ordered Sets with the Loopback bit asserted.

Conceptually:

```text
normal/configured link
        |
        | loopback_test_req
        v
protocol transition toward Loopback
        |
        v
LOOPBACK_ENTRY, role = MASTER
        |
        v
send TS1, Loopback=1 continuously
```

## 7. How a device becomes Loopback Slave

The remote device sees the Master's TS1 Ordered Sets.

Important entry indication for the Slave:

```text
receive TS1 with Loopback=1
receive another consecutive TS1 with Loopback=1
```

The device receiving the Loopback indication becomes the Loopback Slave.

Conceptually:

```text
RX TS1 Loopback=1
        |
        v
count = 1

RX next consecutive TS1 Loopback=1
        |
        v
count = 2
        |
        v
local role = LOOPBACK_SLAVE
        |
        v
LOOPBACK_ENTRY
```

For Gen1/Gen2, the Slave must establish the required receive/symbol synchronization before normal loopback operation.

## 8. Slave connection to PIPE

Once the LTSSM has determined that the local device must act as Loopback Slave:

```text
Slave LTSSM
    |
    | mac_loopback = 1
    v
PIPE wrapper
    |
    | check wrapper idle
    | check no conflicting operation
    | check PowerDown=P0
    | check TX active
    v
TxDetectRx = 1
    |
    v
local PHY loopback enabled
```

Recommended LTSSM behavior:

```verilog
if ((ltssm_state == LOOPBACK_ENTRY) &&
    (loopback_role == LOOPBACK_SLAVE)) begin

    mac_loopback = 1'b1;
end
```

The Slave does not need the MAC Ordered-Set Generator to regenerate every TS1 received from the Master. After PHY loopback is active, the PHY returns the received encoded stream.

## 9. What happens to the Master's TS1

Before Slave loopback is active:

```text
Master OS Generator
      |
      | TS1, Loopback=1
      v
Master PHY TX
      |
      +-------------------------------> Slave PHY RX
```

After Slave PHY loopback is active:

```text
Master PHY TX
      |
      | TS1, Loopback=1
      v
Slave PHY RX
      |
      | physical loopback path
      v
Slave PHY TX
      |
      | returned TS1, Loopback=1
      v
Master PHY RX
```

Therefore the Master eventually receives its Loopback TS1 back.

This confirms that the Slave successfully entered loopback.

## 10. Master behavior in LOOPBACK_ENTRY

Typical Master actions:

```text
role = MASTER
mac_loopback = 0
send TS1 continuously
tx_loopback_bit = 1
monitor returned TS1
```

The Master waits for the required returned TS1 indication showing that the Slave has entered loopback.

For the normal non-compliance case, the Master expects returned TS1 Ordered Sets matching the TS1s it is transmitting, including the Loopback bit.

If successful:

```text
LOOPBACK_ENTRY
      -> LOOPBACK_ACTIVE
```

If the Master cannot establish the required returned training indication, the specification uses an implementation-specific timeout constrained to less than 100 ms before proceeding toward `Loopback.Exit`.

## 11. Slave behavior in LOOPBACK_ENTRY

Typical Slave actions:

```text
role = SLAVE
receive Master's Loopback TS1s
obtain required symbol synchronization
assert mac_loopback
wait until local PIPE loopback condition is active
```

For the current wrapper:

```text
mac_loopback = 1
        |
        v
loopback_request_valid = 1
        |
        v
TxDetectRx = 1
loopback_mode = 1
        |
        v
mac_loopback_active = 1
```

For a simple RTL implementation, `mac_loopback_active` can be used as a local wrapper-level indication that the requested PIPE loopback control has been established.

Do not interpret it as a separate PHY completion handshake.

## 12. LOOPBACK_ACTIVE behavior

### Master

The Master generates the actual test stream.

```text
Generate valid encoded data
        |
        v
Transmit to Slave
        |
        v
Receive returned data
        |
        v
Compare/check
```

In Loopback.Active, the Master must transmit valid encoded data.

The Master must not intentionally transmit EIOS as normal test data if EIOS is being used to terminate Loopback.

The Master does not assert local `mac_loopback`:

```text
mac_loopback = 0
```

### Slave

The Slave keeps local PHY loopback enabled:

```text
mac_loopback = 1
```

The Gen1/Gen2 8b/10b Slave returns the received encoded information through the PHY loopback path rather than decoding it in the MAC and creating a new test stream.

Conceptual datapath:

```text
Master TX
    |
    v
Slave RX PHY
    |
    | loopback
    v
Slave TX PHY
    |
    v
Master RX
```

This is why the MAC wrapper should not implement:

```verilog
TxData <= RxData;
```

The actual loopback belongs in the PHY.

## 13. LOOPBACK_EXIT behavior

The Master decides when the test is complete.

Conceptually:

```text
LOOPBACK_ACTIVE
      |
      | test complete / directed exit
      v
LOOPBACK_EXIT
      |
      | EIOS / Electrical Idle sequence
      v
Detect
```

The Master uses the defined Electrical Idle termination behavior to end the loopback test.

The Slave remains in Loopback.Active until it receives the loopback-exit indication, such as EIOS or detects/infers Electrical Idle.

The Slave must return symbols received before the Electrical Idle transition, allowing the Master to observe the terminating sequence.

Then the Slave disables local loopback:

```text
mac_loopback = 0
        |
        v
TxDetectRx = 0
loopback_mode = 0
        |
        v
mac_loopback_active = 0
```

The Loopback path ultimately exits toward Detect rather than directly returning to L0.

## 14. Complete simplified Master/Slave flow

```text
MASTER                                      SLAVE
------                                      -----

loopback_test_req
      |
      v
LOOPBACK_ENTRY
role = MASTER
mac_loopback = 0
      |
      | TS1 Loopback=1
      +------------------------------------->
      |                                      receive TS1 Loopback=1
      |                                      receive TS1 Loopback=1
      |                                             |
      |                                             v
      |                                      role = SLAVE
      |                                      LOOPBACK_ENTRY
      |                                             |
      |                                      mac_loopback=1
      |                                             |
      |                                      PIPE wrapper
      |                                             |
      |                                      TxDetectRx=1
      |                                      PowerDown=P0
      |                                      TxElecIdle=0
      |                                             |
      |                                      PHY loopback ON
      |                                             |
      |<--------------------------------------------+
      |       returned TS1 Loopback=1
      |
      v
LOOPBACK_ACTIVE                              LOOPBACK_ACTIVE
      |                                             |
      | test data                                   |
      +-------------------------------------------->|
      |                                             |
      |                                      PHY loops data
      |                                             |
      |<--------------------------------------------+
      |
      | compare/check returned data
      |
      | test complete
      v
LOOPBACK_EXIT
      |
      | EIOS / Electrical Idle
      +-------------------------------------------->|
      |                                      detect exit
      |                                      finish returning prior symbols
      |                                      mac_loopback=0
      |                                             |
      v                                             v
    Detect                                        Detect
```

## 15. Recommended LTSSM outputs

Useful internal controls:

```verilog
reg        loopback_test_req;
reg        loopback_role;          // MASTER / SLAVE
reg        mac_loopback;
reg        tx_ts1_enable;
reg        tx_ts1_loopback_bit;
reg        loopback_exit_req;
```

Useful receive indications:

```verilog
wire       rx_valid_ts1;
wire       rx_ts1_loopback_bit;
wire       rx_eios;
wire       rx_or_inferred_elecidle;
```

Useful PIPE status:

```verilog
wire       mac_loopback_active;
```

For x1, the two-consecutive-TS1 recognition can be implemented with a small consecutive counter.

## 16. Recommended LTSSM output behavior

```text
State                 Role      TS1 Loopback bit   mac_loopback
----------------------------------------------------------------
LOOPBACK_ENTRY        MASTER          1                 0
LOOPBACK_ENTRY        SLAVE           -                 1
LOOPBACK_ACTIVE       MASTER     test stream            0
LOOPBACK_ACTIVE       SLAVE           -                 1
LOOPBACK_EXIT         MASTER     exit sequence          0
LOOPBACK_EXIT         SLAVE           -                 0 after exit is detected
```

`-` means the Slave PHY is returning the received serial stream, so the MAC Ordered-Set Generator is not responsible for creating that returned stream.

## 17. Suggested simplified RTL structure

```verilog
always @* begin

    mac_loopback         = 1'b0;
    tx_ts1_enable        = 1'b0;
    tx_ts1_loopback_bit  = 1'b0;

    next_state = state;

    case (state)

        LOOPBACK_ENTRY: begin

            if (loopback_role == LOOPBACK_MASTER) begin

                tx_ts1_enable       = 1'b1;
                tx_ts1_loopback_bit = 1'b1;
                mac_loopback        = 1'b0;

                if (master_loopback_entry_complete)
                    next_state = LOOPBACK_ACTIVE;

                else if (master_loopback_entry_timeout)
                    next_state = LOOPBACK_EXIT;

            end

            else begin

                mac_loopback = 1'b1;

                if (mac_loopback_active && slave_symbol_lock_ok)
                    next_state = LOOPBACK_ACTIVE;

            end

        end


        LOOPBACK_ACTIVE: begin

            if (loopback_role == LOOPBACK_MASTER) begin

                mac_loopback = 1'b0;

                if (loopback_test_complete)
                    next_state = LOOPBACK_EXIT;

            end

            else begin

                mac_loopback = 1'b1;

                if (rx_eios || rx_or_inferred_elecidle)
                    next_state = LOOPBACK_EXIT;

            end

        end


        LOOPBACK_EXIT: begin

            mac_loopback = 1'b0;

            if (loopback_exit_complete)
                next_state = DETECT;

        end

    endcase
end
```

This is architectural pseudocode, not a complete PCIe-compliant LTSSM implementation. Exact counters, timers, ordered-set contents, speed-change behavior, and exit timing must follow the PCIe revision being implemented.

## 18. Important distinction: protocol loopback vs local PHY loopback

Do not confuse:

```text
TS1 Loopback bit
```

with:

```text
mac_loopback / TxDetectRx
```

The first is a protocol message to the remote link partner.

The second is a local control path into the local PHY.

Correct relation:

```text
MASTER
LTSSM -> OS Generator -> TS1 Loopback=1 -> remote device

SLAVE
received TS1 Loopback=1 -> LTSSM -> mac_loopback=1
                              -> PIPE -> TxDetectRx=1
                              -> local PHY loopback
```

Incorrect relation:

```text
Master enters Loopback.Entry
        -> mac_loopback=1
```

That would request the Master's own PHY to become the loopback datapath, which is not the intended Master/Slave division for this architecture.

## 19. Loopback vs Recovery

```text
Recovery
    retrains or repairs an existing link
    may perform speed change
    returns toward L0

Loopback
    creates a Physical Layer test path
    Master sends test stream
    Slave returns it
    exits toward Detect
```

Both use Training Sequences and Electrical Idle behavior, but their purpose is different.

## 20. Loopback vs Receiver Detection

Both use `TxDetectRx`, but in different PIPE power states.

```text
Loopback:
    PowerDown = P0
    TxDetectRx = 1
    TxElecIdle = 0

Receiver Detection:
    PowerDown = P1
    TxDetectRx = 1
    TxElecIdle asserted as required for Detect operation
```

The wrapper uses `loopback_mode` to remember whether `TxDetectRx` is currently being used for loopback rather than receiver detection.

## 21. Operations blocked while local loopback is active

The current wrapper deliberately blocks:

```text
rate change
power-state change
receiver detection
```

while `loopback_mode` is active.

This avoids changing the interpretation of shared PIPE controls or starting another PHY operation during loopback.

The wrapper uses:

```verilog
!loopback_mode
```

inside the qualification of these operations.

## 22. Rate considerations for Gen1/Gen2

Loopback.Entry can include rate-related behavior depending on how Loopback was entered.

For the simple already-configured-link implementation discussed here, keep the LTSSM's protocol Loopback logic separate from the general Recovery.Speed / PIPE rate-change controller.

Do not change `Rate` merely because `mac_loopback` became 1.

A rate change, when required by the specific Loopback.Entry path being implemented, must use the normal legal PIPE rate-change sequencing rather than being hidden inside the loopback request.

## 23. What mac_loopback_active does not prove

`mac_loopback_active = 1` does not prove that:

```text
the remote Master received correct returned data
CDR quality is good
all loopback test comparisons passed
PCIe Loopback.Entry protocol completed successfully
```

It only reports the wrapper's local loopback condition.

Actual test success is determined at the Loopback Master by checking the returned training/test stream.

## 24. Minimum state variables recommended for RTL

```text
ltssm_state
loopback_role
loopback_test_req
rx_loopback_ts1_count
master_loopback_entry_timer
mac_loopback
loopback_test_complete
loopback_exit_detected
```

For a Gen1/Gen2 x1 design this is enough to keep the architecture understandable before adding detailed specification timers and ordered-set counters.

## 25. Key rules to remember

```text
1. Master requests remote loopback using TS1 Loopback=1.

2. Slave is the device that receives the Loopback request.

3. Two consecutive Loopback TS1s are the important Slave-entry indication.

4. Master normally keeps local mac_loopback=0.

5. Slave asserts local mac_loopback=1.

6. PIPE wrapper converts accepted mac_loopback into:
       PowerDown=P0
       TxDetectRx=1
       TxElecIdle=0

7. PHY, not the MAC datapath, performs the actual loopback.

8. Slave does not need to regenerate the Master's returned test stream in the MAC.

9. Master verifies the returned stream.

10. Slave stays in loopback until the defined exit indication is received.

11. Exit uses EIOS/Electrical Idle behavior and ultimately returns to Detect.

12. mac_loopback_active is local wrapper status, not a PHY-generated completion handshake.
```

## 26. Source basis

This reference is scoped to the current `pcie_pipe_mac_if_v3` implementation and Gen1/Gen2 PCIe Loopback behavior discussed in PCIe Base Specification 2.x-era Loopback rules and PCI-SIG Loopback FAQ material.

The current wrapper specifically defines:

```text
mac_loopback             local request for PHY loopback
mac_loopback_active      local wrapper loopback status
TxDetectRx               P0 loopback / P1 receiver-detect shared PIPE control
loopback_mode            internal ownership/status bit
loopback_request_valid   qualification before asserting TxDetectRx
```

When implementing production RTL, use the exact PCIe Base and PIPE specification revisions targeted by the design for normative ordered-set fields, timers, lane rules, Electrical Idle timing, and speed-change requirements.
