# PCIe PIPE Receiver Detection 

## 1. Introduction

Receiver Detection is one of the first important operations performed during PCIe link initialization.

The responsibility is divided between three major blocks:

```text
PCIe LTSSM
    ↓
MAC / PIPE Control Logic
    ↓
PHY
```

The basic responsibilities are:

```text
LTSSM
    → decides WHEN receiver detection is required

PIPE Wrapper
    → generates the PIPE control signals required
      to request receiver detection

PHY
    → performs the actual electrical receiver-detection operation

PIPE Wrapper
    → receives the result from the PHY and
      converts it into simpler MAC-side signals

LTSSM
    → decides what state to enter next
```

Therefore:

```text
LTSSM decides.

PIPE wrapper controls.

PHY detects.

PIPE wrapper reports.

LTSSM reacts.
```

---

# 2. Relationship Between LTSSM and Receiver Detection

The LTSSM decides **when receiver detection must happen**, while the PIPE/PHY performs the actual electrical receiver-detection operation.

A simplified LTSSM sequence is:

```text
Detect.Quiet
    ↓
Detect.Active
    ↓
Perform Receiver Detection
    ↓
Receiver found?
    ├── Yes → Polling
    └── No  → Detect.Quiet
```

A more accurate interpretation is:

```text
Detect.Quiet
    ↓
Detect.Active
        |
        | Perform Receiver Detection
        |
        +---- Receiver found ----> Polling
        |
        +---- No receiver -------> Detect.Quiet
```

Receiver Detection is therefore an **operation performed while the LTSSM is in `Detect.Active`**, rather than a separate LTSSM state.

When the LTSSM enters `Detect.Active`, it requests the PHY to determine whether a valid receiver is connected to the PCIe lane.

The LTSSM itself does not perform the analog receiver-detection operation.

Instead:

```text
LTSSM
    ↓
MAC / PIPE Control Logic
    ↓
PHY
    ↓
Electrical Receiver Detection
```

---

# 3. LTSSM to PIPE Relationship

In a PIPE-based implementation, the relationship is approximately:

```text
        PCIe MAC / LTSSM
               |
               | Detect.Active
               |
               | Receiver detection required
               v
        PIPE Control Logic
               |
               | PowerDown  = P1
               | TxElecIdle = 1
               | TxDetectRx = 1
               v
              PHY
               |
               | Performs electrical
               | receiver detection
               v
        PhyStatus + RxStatus
               |
               v
        PIPE Control Logic
               |
               | detect_done
               | detect_rx_present
               v
             LTSSM
```

The LTSSM does not normally need to understand the detailed `RxStatus` encoding.

The wrapper translates:

```text
PhyStatus + RxStatus
```

into:

```text
detect_done
detect_rx_present
```

which are easier for the LTSSM to consume.

---

# 4. `Detect.Active` and `P1` Are Different Concepts

An important distinction is:

```text
Detect.Active
    = PCIe LTSSM state

P1
    = PIPE PHY power state
```

These belong to different architectural layers.

Do not interpret:

```text
Detect.Active == P1
```

Instead:

```text
LTSSM enters Detect.Active
        ↓
LTSSM determines receiver detection is required
        ↓
MAC / PIPE wrapper prepares the PHY
        ↓
PHY enters appropriate PIPE condition such as P1
        ↓
receiver detection is requested
```

Therefore:

```text
Detect.Active
    → protocol-level state

P1
    → PHY/interface-level power condition
```

---

# 5. What Receiver Detection Actually Does

Receiver Detection is not looking for:

```text
TS1
TS2
DLLP
TLP
```

at this stage.

Instead, the PHY performs an electrical test to determine whether an appropriate PCIe receiver termination exists at the far end of the lane.

Conceptually:

```text
Local PHY TX ------------------------- Remote PHY RX
                                            |
                                      RX termination
```

The local PHY effectively asks:

```text
"Is a valid PCIe receiver electrically connected
at the other end of this lane?"
```

Normal PCIe training sequences occur later.

---

# 6. PIPE Conditions for Receiver Detection

For our simplified wrapper, Receiver Detection is performed only in:

```text
P1
```

P2 is intentionally unsupported by this implementation.

The receiver-detection qualification is:

```verilog
wire detect_allowed;

assign detect_allowed =
    (PowerDown == P1) &&
    TxElecIdle &&
    !loopback_mode;
```

The source implements these receiver-detection preconditions directly.

Therefore, before detection starts:

```text
PowerDown  = P1
TxElecIdle = 1
Loopback   = inactive
```

When the actual detection request is asserted:

```text
TxDetectRx = 1
```

the relevant PIPE combination becomes:

```text
PowerDown  = P1
TxElecIdle = 1
TxDetectRx = 1
```

which means:

```text
Perform Receiver Detection
```

---

# 7. The PHY Must Actually Reach P1 First

It is not sufficient merely to write:

```verilog
PowerDown <= P1;
```

and immediately assume the PHY is ready for receiver detection.

A power-state transition is itself a PHY operation.

Conceptually:

```text
Current state
    ↓
Request P1
    ↓
PowerDown = P1
    ↓
PHY performs transition
    ↓
PhyStatus
    ↓
P1 transition complete
    ↓
Receiver Detection may start
```

Therefore receiver detection must not overlap an unfinished power transition.

This is one reason the wrapper serializes PHY operations.

---

# 8. Receiver-Detection Request From the LTSSM

In our design, the LTSSM-side request is:

```verilog
mac_detect_req
```

This is **not a standard PIPE signal**.

It is an internal interface signal between:

```text
LTSSM / MAC
      ↓
PIPE Wrapper
```

whereas:

```verilog
TxDetectRx
```

is the actual PIPE-side PHY control.

The relationship is:

```text
LTSSM
    ↓
mac_detect_req
    ↓
PIPE wrapper
    ↓
TxDetectRx
    ↓
PHY
```

The original wrapper defines `mac_detect_req` as the receiver-detection request and documents a held-request contract.

---

# 9. Request Contract Used in Our Simplified Design

We use the following strict MAC-side contract:

```text
1. LTSSM asserts mac_detect_req.

2. LTSSM keeps mac_detect_req asserted.

3. PIPE wrapper performs receiver detection.

4. Wrapper asserts detect_done.

5. LTSSM may then deassert mac_detect_req.
```

Therefore:

```text
mac_detect_req
      __________________________
_____/                          \____
                               ^
                               |
                          detect_done
```

The request remains asserted while waiting and while the operation is active.

---

# 10. Why We Need Rising-Edge Detection

Because:

```text
mac_detect_req
```

may remain high for many clocks, we need to distinguish:

```text
"A new request just arrived"
```

from:

```text
"The same request is still being held high."
```

The wrapper uses:

```verilog
reg detect_req_delayed;

wire detect_req_rising;

assign detect_req_rising =
    mac_detect_req &&
    !detect_req_delayed;
```

and:

```verilog
detect_req_delayed <= mac_detect_req;
```

The source contains this edge-detection logic.

Example:

```text
Clock                 C1    C2    C3    C4

mac_detect_req         0     1     1     1

detect_req_delayed     0     0     1     1

detect_req_rising      0     1     0     0
                             ^
                             |
                      New request
```

Therefore:

```text
mac_detect_req
    = level-based request

detect_req_rising
    = one-cycle "new request" event
```

---

# 11. Why We Need `detect_pending`

A receiver-detection request may arrive when the PHY cannot immediately perform the operation.

For example:

```text
mac_detect_req arrives

but:

PowerDown != P1
```

or:

```text
another PHY operation is currently active
```

The wrapper must remember the request.

Therefore:

```verilog
if (detect_req_rising)
    detect_pending <= 1'b1;
```

Conceptually:

```text
detect_pending = 1
```

means:

```text
"A receiver-detection request exists
and has not yet been launched."
```

`detect_pending` is effectively a one-entry request queue.

---

# 12. Meaning of `detect_pending`

The two important values are:

```text
detect_pending = 0

    No receiver-detection request
    is waiting to start.
```

and:

```text
detect_pending = 1

    One receiver-detection request
    is waiting to start.
```

It does **not** mean that receiver detection is currently executing.

We distinguish:

```text
detect_pending = 1
    → request waiting

state = ST_WAIT
active_operation = OP_DETECT
    → detection currently executing

detect_done = 1
    → detection just completed
```

---

# 13. Updating `detect_pending`

The clean implementation is:

```verilog
if (start_detect_operation)
    detect_pending <= 1'b0;

else if (detect_req_rising)
    detect_pending <= 1'b1;
```

This implements:

```text
New request
    ↓
detect_pending = 1

        wait...

Detection launches
    ↓
detect_pending = 0
```

The ordering also establishes priority.

If the operation is being launched:

```text
start_detect_operation = 1
```

the request is considered consumed and therefore:

```text
detect_pending = 0
```

---

# 14. Why `detect_pending` Is Cleared at Launch

Suppose:

```text
detect_pending = 1
```

This means the request is waiting.

When:

```text
start_detect_operation = 1
```

the request is no longer waiting.

It has become an active operation.

Therefore:

```verilog
detect_pending <= 1'b0;

active_operation <= OP_DETECT;

state <= ST_WAIT;
```

creates this transition:

```text
Before launch:

detect_pending   = 1
active_operation = OP_NONE
state            = ST_IDLE


After launch:

detect_pending   = 0
active_operation = OP_DETECT
state            = ST_WAIT
```

This creates a clean distinction between:

```text
queued
```

and:

```text
executing
```

---

# 15. Why `mac_detect_req` Does Not Need to Be Checked Again

The original source contains:

```verilog
assign start_detect_operation =
    (state == ST_IDLE) &&
    !start_rate_operation &&
    !start_power_operation &&
    detect_pending &&
    mac_detect_req &&
    detect_allowed;
```

The original implementation allowed a queued request to be withdrawn before launch.

However, for our simplified strict contract:

```text
Once mac_detect_req is asserted,
it remains asserted until detect_done.
```

Therefore:

```text
detect_pending = 1
```

already tells us that a valid outstanding request exists.

The extra:

```verilog
&& mac_detect_req
```

is redundant under this contract.

Therefore we use:

```verilog
assign start_detect_operation =
    (state == ST_IDLE) &&
    !start_rate_operation &&
    !start_power_operation &&
    detect_pending &&
    detect_allowed;
```

---

# 16. Launch Conditions

The complete launch condition in our simplified implementation is:

```verilog
assign start_detect_operation =
    (state == ST_IDLE) &&
    !start_rate_operation &&
    !start_power_operation &&
    detect_pending &&
    detect_allowed;
```

where:

```verilog
assign detect_allowed =
    (PowerDown == P1) &&
    TxElecIdle &&
    !loopback_mode;
```

Therefore receiver detection starts only when:

```text
PIPE controller is idle
AND
no rate operation is starting
AND
no power operation is starting
AND
a receiver-detection request is pending
AND
PowerDown = P1
AND
TxElecIdle = 1
AND
loopback is inactive
```

---

# 17. Why the Controller Must Be Idle

The condition:

```verilog
state == ST_IDLE
```

means:

```text
"No previous PIPE operation is currently waiting
for completion."
```

Receiver detection should not be launched if the controller is already waiting for:

```text
power transition completion
```

or:

```text
rate-change completion
```

or another PHY operation.

---

# 18. Operation Priority

Our wrapper uses this priority:

```text
1. Rate change
2. Power-state change
3. Receiver detection
```

The original source explicitly documents this arbitration order.

Therefore:

```verilog
!start_rate_operation
```

means:

```text
"Do not start detection if a rate-change operation
is starting."
```

and:

```verilog
!start_power_operation
```

means:

```text
"Do not start detection if a power-state change
is starting."
```

The specific priority is a wrapper implementation decision.

The important architectural rule is that conflicting PHY operations should not overlap.

---

# 19. Starting Receiver Detection

When:

```text
start_detect_operation = 1
```

the wrapper performs:

```verilog
TxDetectRx <= 1'b1;

active_operation <= OP_DETECT;
state            <= ST_WAIT;
```

At this point:

```text
PowerDown  = P1
TxElecIdle = 1
TxDetectRx = 1
```

and the PHY interprets this as:

```text
Perform Receiver Detection
```

The source performs this operation in its receiver-detection launch block.

---

# 20. Meaning of `TxDetectRx`

`TxDetectRx` is a dual-purpose PIPE signal.

In this wrapper:

```text
P1 + TxDetectRx
    → Receiver Detection

P0 + TxDetectRx
    → Loopback
```

The source explicitly documents this dual-purpose behavior.

Therefore the interpretation depends on the PHY operating condition.

This is why receiver detection additionally checks:

```verilog
!loopback_mode
```

---

# 21. `TxDetectRx` Must Remain Asserted

Once receiver detection starts:

```text
TxDetectRx = 1
```

it must remain asserted until the PHY reports that the operation has completed.

Conceptually:

```text
TxDetectRx
        _______________________
_______/                       \____
                              ^
                              |
                         PhyStatus
```

Do not treat:

```verilog
TxDetectRx
```

as a simple one-clock pulse.

Instead:

```text
assert TxDetectRx
      ↓
PHY performs detection
      ↓
keep TxDetectRx asserted
      ↓
PhyStatus
      ↓
deassert TxDetectRx
```

The source comments explicitly state that `TxDetectRx` remains asserted until `PhyStatus`.

---

# 22. Waiting for the PHY

After detection starts:

```verilog
active_operation <= OP_DETECT;
state            <= ST_WAIT;
```

The controller waits.

Conceptually:

```text
ST_IDLE
   ↓
start_detect_operation
   ↓
TxDetectRx = 1
   ↓
ST_WAIT
   ↓
wait...
   ↓
wait...
   ↓
PhyStatus
```

`ST_WAIT` tells the controller:

```text
"A PHY operation is currently in progress."
```

while:

```text
active_operation = OP_DETECT
```

tells it:

```text
"The current PHY operation is Receiver Detection."
```

---

# 23. PHY Completion

After performing the electrical receiver detection, the PHY asserts:

```text
PhyStatus = 1
```

This means:

```text
"The receiver-detection operation has completed."
```

It does **not** mean:

```text
"A receiver was found."
```

The result comes from:

```text
RxStatus
```

Therefore:

```text
PhyStatus
    → operation finished

RxStatus
    → operation result
```

---

# 24. Receiver-Detection Result

For the PIPE receiver-detection result used by our wrapper:

```text
RxStatus = 3'b011
    → Receiver detected

RxStatus = 3'b000
    → No receiver detected
```

The wrapper defines:

```verilog
localparam [2:0] RXST_RX_DETECTED = 3'b011;
```

The source contains this encoding.

Then:

```verilog
detect_rx_present <=
    (RxStatus == RXST_RX_DETECTED);
```

produces:

```text
RxStatus = 011
      ↓
detect_rx_present = 1
```

otherwise:

```text
detect_rx_present = 0
```

---

# 25. Completing Receiver Detection

The completion condition is:

```verilog
else if (
    (state == ST_WAIT) &&
    (active_operation == OP_DETECT) &&
    PhyStatus
) begin
```

This means:

```text
Controller is waiting
AND
the operation being waited on is Receiver Detection
AND
PHY says the operation completed
```

Then:

```verilog
detect_rx_present <=
    (RxStatus == RXST_RX_DETECTED);

detect_done <= 1'b1;

TxDetectRx <= 1'b0;

active_operation <= OP_NONE;
state            <= ST_IDLE;
```

The original source performs the same result capture and completion sequence.

---

# 26. Meaning of `detect_done`

`detect_done` tells the LTSSM:

```text
"The receiver-detection operation has completed."
```

It is implemented as a one-clock pulse.

Every normal cycle:

```verilog
detect_done <= 1'b0;
```

At completion:

```verilog
detect_done <= 1'b1;
```

Therefore:

```text
detect_done

____________________/‾\________________
```

The source defines `detect_done` as a one-PCLK completion pulse.

---

# 27. Meaning of `detect_rx_present`

Unlike `detect_done`, the result:

```verilog
detect_rx_present
```

is held.

It tells the LTSSM the result of the most recent receiver-detection operation.

Therefore:

```text
detect_done
    = completion EVENT

detect_rx_present
    = detection RESULT
```

Example:

```text
detect_done       = 1
detect_rx_present = 1
```

means:

```text
Receiver detection completed
AND
receiver was found
```

Whereas:

```text
detect_done       = 1
detect_rx_present = 0
```

means:

```text
Receiver detection completed
AND
receiver was not found
```

---

# 28. Returning the Result to the LTSSM

The wrapper translates:

```text
PhyStatus
RxStatus
```

into:

```text
detect_done
detect_rx_present
```

Therefore:

```text
LTSSM Detect.Active
        |
        v
mac_detect_req
        |
        v
PIPE Wrapper
        |
        | PowerDown  = P1
        | TxElecIdle = 1
        | TxDetectRx = 1
        v
PHY Receiver Detection
        |
        | PhyStatus
        | RxStatus
        v
PIPE Wrapper
        |
        | detect_done
        | detect_rx_present
        v
LTSSM
        |
        +---- Receiver detected ----> Polling
        |
        +---- No receiver ----------> Detect.Quiet
```

---

# 29. RxStatus Must Not Be Normally Decoded During Detection

`RxStatus` normally has meanings associated with received data and PHY conditions.

However, during Receiver Detection it is being used to report:

```text
receiver absent
```

or:

```text
receiver present
```

Therefore normal `RxStatus` decoding should not occur simultaneously.

The source implements:

```verilog
assign detect_in_progress =
    (state == ST_WAIT) &&
    (active_operation == OP_DETECT);
```

and excludes normal `RxStatus` decoding while detection is active.

Therefore:

```text
Receiver Detection active
        ↓
RxStatus interpreted as detection result
        ↓
do not interpret it as normal RX status
```

---

# 30. Reset Behavior

Relevant receiver-detection reset values include:

```verilog
PowerDown  <= P1;
TxDetectRx <= 1'b0;

detect_done       <= 1'b0;
detect_rx_present <= 1'b0;

detect_req_delayed <= 1'b0;
detect_pending     <= 1'b0;
```

The original wrapper initializes these signals as part of its safe startup behavior.

Conceptually:

```text
Reset
  ↓
No Receiver Detection request active
  ↓
TxDetectRx = 0
  ↓
request tracking cleared
```

---

# 31. Timeout Handling

The wrapper also contains defensive timeout handling.

If:

```text
PhyStatus
```

does not arrive within the configured timeout, the wrapper assumes the PHY state may be unknown.

It then performs actions such as:

```verilog
TxDetectRx <= 1'b0;

phy_timeout <= 1'b1;

active_operation <= OP_NONE;

state <= ST_FAULT;
```

The source implements this timeout/fault behavior.

The timeout itself is an implementation safety feature, rather than the basic Receiver Detection handshake.

---

# 32. Complete Request Sequence

The complete MAC-side sequence is:

```text
LTSSM determines receiver detection is needed
                  ↓
          mac_detect_req = 1
                  ↓
        detect_req_rising = 1
                  ↓
          detect_pending = 1
                  ↓
               wait...
                  ↓
     receiver-detection conditions valid
                  ↓
       start_detect_operation = 1
                  ↓
          detect_pending = 0
                  ↓
            TxDetectRx = 1
                  ↓
       active_operation = OP_DETECT
            state = ST_WAIT
                  ↓
       PHY performs Receiver Detection
                  ↓
         TxDetectRx remains 1
                  ↓
             PhyStatus = 1
                  ↓
            sample RxStatus
                  ↓
       detect_rx_present updated
                  ↓
            detect_done = 1
                  ↓
            TxDetectRx = 0
                  ↓
       active_operation = OP_NONE
            state = ST_IDLE
                  ↓
       LTSSM sees detect_done
                  ↓
       LTSSM may deassert request
```

---

# 33. Timing Example

A conceptual timing sequence is:

```text
Cycle               C1   C2   C3   C4   C5   C6

mac_detect_req       0    1    1    1    1    0

detect_req_rising    0    1    0    0    0    0

detect_pending       0    0    1    1    0    0

start_detect_op      0    0    0    1    0    0

TxDetectRx           0    0    0    1    1    0

state               IDLE IDLE IDLE WAIT WAIT IDLE

PhyStatus            0    0    0    0    1    0

detect_done          0    0    0    0    1    0
```

The important events are:

```text
C2
    New MAC request arrives.

C3
    Request is remembered as pending.

C4
    Conditions are valid.
    Receiver Detection starts.
    Pending request is consumed.

C5
    PHY completes detection.
    RxStatus is captured.
    detect_done pulses.
    TxDetectRx is removed.

C6
    MAC request may be deasserted.
```

---

# 34. Corrected Receiver-Detection RTL

The simplified receiver-detection control can be written as:

```verilog
localparam [1:0] P1               = 2'b10;
localparam [2:0] RXST_RX_DETECTED = 3'b011;

localparam [2:0] ST_IDLE = 3'd1;
localparam [2:0] ST_WAIT = 3'd2;

localparam [1:0] OP_NONE   = 2'd0;
localparam [1:0] OP_DETECT = 2'd3;


reg detect_req_delayed;
reg detect_pending;

wire detect_req_rising;
wire detect_allowed;
wire start_detect_operation;


// ------------------------------------------------------------
// Detect new receiver-detection request
// ------------------------------------------------------------

assign detect_req_rising =
    mac_detect_req &&
    !detect_req_delayed;


// ------------------------------------------------------------
// Receiver-detection preconditions
// ------------------------------------------------------------

assign detect_allowed =
    (PowerDown == P1) &&
    TxElecIdle &&
    !loopback_mode;


// ------------------------------------------------------------
// Receiver-detection launch condition
// ------------------------------------------------------------

assign start_detect_operation =
    (state == ST_IDLE) &&
    !start_rate_operation &&
    !start_power_operation &&
    detect_pending &&
    detect_allowed;


// ------------------------------------------------------------
// Receiver-detection controller
// ------------------------------------------------------------

always @(posedge pclk or negedge reset_n) begin

    if (!reset_n) begin

        TxDetectRx <= 1'b0;

        detect_done       <= 1'b0;
        detect_rx_present <= 1'b0;

        detect_req_delayed <= 1'b0;
        detect_pending     <= 1'b0;

        active_operation <= OP_NONE;
        state            <= ST_IDLE;

    end
    else begin

        // One-cycle completion pulse.
        detect_done <= 1'b0;

        // Store previous request value.
        detect_req_delayed <= mac_detect_req;


        // ----------------------------------------------------
        // Pending receiver-detection request
        // ----------------------------------------------------

        if (start_detect_operation)
            detect_pending <= 1'b0;

        else if (detect_req_rising)
            detect_pending <= 1'b1;


        // ----------------------------------------------------
        // Start receiver detection
        // ----------------------------------------------------

        if (start_detect_operation) begin

            // Start PIPE Receiver Detection.
            TxDetectRx <= 1'b1;

            active_operation <= OP_DETECT;
            state            <= ST_WAIT;

        end


        // ----------------------------------------------------
        // Complete receiver detection
        // ----------------------------------------------------

        else if (
            (state == ST_WAIT) &&
            (active_operation == OP_DETECT) &&
            PhyStatus
        ) begin

            // Capture receiver-detection result.
            detect_rx_present <=
                (RxStatus == RXST_RX_DETECTED);

            // Inform LTSSM/MAC that detection completed.
            detect_done <= 1'b1;

            // End PIPE receiver-detection request.
            TxDetectRx <= 1'b0;

            active_operation <= OP_NONE;
            state            <= ST_IDLE;

        end

    end

end
```

---

# 35. Specification Rules vs Wrapper Implementation

It is important to distinguish specification-level behavior from our RTL architecture.

| Item                                                        | Category                         |
| ----------------------------------------------------------- | -------------------------------- |
| Receiver Detection is performed electrically by the PHY     | PCIe/PHY behavior                |
| Receiver Detection is associated with PCIe Detect operation | PCIe LTSSM behavior              |
| `PowerDown = P1` for our detection implementation           | PIPE usage                       |
| `TxElecIdle = 1` during P1 detection                        | PIPE requirement                 |
| `TxDetectRx = 1` requests Receiver Detection                | PIPE interface                   |
| Hold `TxDetectRx` until `PhyStatus`                         | PIPE handshake                   |
| `PhyStatus` indicates completion                            | PIPE interface                   |
| `RxStatus = 011` means receiver present                     | PIPE encoding                    |
| `RxStatus = 000` means receiver absent                      | PIPE encoding                    |
| `mac_detect_req`                                            | Our wrapper                      |
| `detect_req_delayed`                                        | Our wrapper                      |
| `detect_req_rising`                                         | Our wrapper                      |
| `detect_pending`                                            | Our wrapper                      |
| `detect_done`                                               | Our wrapper                      |
| `detect_rx_present`                                         | Our wrapper                      |
| `ST_IDLE` / `ST_WAIT`                                       | Our controller                   |
| `OP_DETECT`                                                 | Our controller                   |
| Rate > Power > Detect priority                              | Our controller architecture      |
| Timeout / `ST_FAULT`                                        | Defensive implementation feature |

The major lesson is:

```text
Do not treat implementation signals such as

mac_detect_req
detect_pending
detect_req_rising
detect_done

as PIPE specification signals.
```

They are abstractions that make the wrapper easier to design.

---

# 36. Important Signal Meanings

## `mac_detect_req`

```text
LTSSM/MAC requests Receiver Detection.
```

Held high until completion in our interface contract.

---

## `detect_req_delayed`

```text
Previous sampled value of mac_detect_req.
```

Used only for rising-edge detection.

---

## `detect_req_rising`

```text
One-clock indication that a NEW
receiver-detection request arrived.
```

Calculated as:

```verilog
mac_detect_req && !detect_req_delayed
```

---

## `detect_pending`

```text
Receiver-detection request exists
but has not yet been launched.
```

---

## `start_detect_operation`

```text
All conditions are satisfied,
so Receiver Detection should start now.
```

---

## `TxDetectRx`

```text
Actual PIPE control used to command
the PHY to perform Receiver Detection.
```

---

## `PhyStatus`

```text
PHY operation completed.
```

---

## `RxStatus`

```text
Contains Receiver Detection result
when PhyStatus completes the operation.
```

---

## `detect_rx_present`

```text
Simplified Boolean Receiver Detection result.
```

---

## `detect_done`

```text
One-clock MAC/LTSSM completion indication.
```

---

# 37. Three Different Request States

The cleanest mental model is to separate three conditions.

### Request arrived

```text
detect_req_rising = 1
```

means:

```text
"A new request just arrived."
```

### Request waiting

```text
detect_pending = 1
```

means:

```text
"The request has arrived but has not started."
```

### Request executing

```text
state = ST_WAIT
active_operation = OP_DETECT
```

means:

```text
"The request has already started and
the PHY is currently executing it."
```

Finally:

```text
detect_done = 1
```

means:

```text
"The request completed."
```

Therefore:

```text
NEW
 ↓
PENDING
 ↓
ACTIVE
 ↓
DONE
```

---

# 38. Complete Architectural View

```text
                    PCIe LTSSM

                    Detect.Active
                         |
                         | Receiver detection required
                         v
                   mac_detect_req
                         |
                         v
                detect_req_rising
                         |
                         v
                  detect_pending
                         |
                         | wait until:
                         |
                         | state = ST_IDLE
                         | PowerDown = P1
                         | TxElecIdle = 1
                         | loopback inactive
                         | no higher-priority operation
                         v
              start_detect_operation
                         |
                         v
                   TxDetectRx = 1
                         |
                         v
                active_operation
                   = OP_DETECT
                         |
                         v
                    ST_WAIT
                         |
                         v
                       PHY
                         |
                         | Electrical
                         | Receiver Detection
                         |
                         v
                    PhyStatus
                         |
                         +
                         |
                    RxStatus
                         |
                         v
                  PIPE Wrapper
                         |
              +----------+----------+
              |                     |
              v                     v
        detect_done         detect_rx_present
              |                     |
              +----------+----------+
                         |
                         v
                      LTSSM
                         |
             +-----------+-----------+
             |                       |
             v                       v
       Receiver found          No receiver
             |                       |
             v                       v
          Polling              Detect.Quiet
```

---

# 39. Final Rules to Remember

### Rule 1

The LTSSM decides **when** Receiver Detection is required.

```text
LTSSM = decision logic
```

### Rule 2

The PIPE wrapper generates the PHY control signals.

```text
PIPE wrapper = control translation
```

### Rule 3

The PHY performs the actual electrical detection.

```text
PHY = electrical detection
```

### Rule 4

For our simplified implementation:

```text
PowerDown = P1
TxElecIdle = 1
```

must already be satisfied before starting detection.

### Rule 5

The actual Receiver Detection request is:

```text
TxDetectRx = 1
```

with:

```text
PowerDown  = P1
TxElecIdle = 1
```

### Rule 6

Keep:

```text
TxDetectRx = 1
```

until:

```text
PhyStatus = 1
```

### Rule 7

`PhyStatus` tells us:

```text
"Operation completed."
```

It does not tell us whether a receiver exists.

### Rule 8

The result comes from:

```text
RxStatus
```

with our supported encodings:

```text
000 → receiver absent
011 → receiver present
```

### Rule 9

After completion:

```text
TxDetectRx = 0
```

before beginning another PHY operation.

### Rule 10

`mac_detect_req` is not a PIPE signal.

It is our LTSSM-to-wrapper request.

### Rule 11

`detect_req_rising` identifies one new request.

```text
mac_detect_req
      ↓
detect_req_rising
```

### Rule 12

`detect_pending` remembers a request until it can start.

```text
new request
     ↓
detect_pending = 1
```

### Rule 13

Once detection launches:

```text
detect_pending = 0
```

because the request is no longer waiting.

### Rule 14

While detection executes:

```text
state            = ST_WAIT
active_operation = OP_DETECT
```

### Rule 15

When detection completes:

```text
detect_done = 1
```

for one clock.

### Rule 16

The result remains available through:

```text
detect_rx_present
```

### Rule 17

Do not confuse:

```text
Detect.Active
```

with:

```text
P1
```

because:

```text
Detect.Active
    = PCIe LTSSM state

P1
    = PIPE PHY power state
```

---

# 40. Final End-to-End Summary

The complete relationship can be remembered as:

```text
LTSSM enters Detect.Active
        ↓
Receiver Detection required
        ↓
mac_detect_req asserted
        ↓
detect_req_rising
        ↓
detect_pending = 1
        ↓
wait until PHY is ready
        ↓
PowerDown = P1
TxElecIdle = 1
        ↓
start_detect_operation
        ↓
detect_pending = 0
        ↓
TxDetectRx = 1
        ↓
PHY performs electrical Receiver Detection
        ↓
PhyStatus = 1
        ↓
sample RxStatus
        ↓
011 → Receiver present
000 → Receiver absent
        ↓
TxDetectRx = 0
        ↓
detect_done = 1
detect_rx_present = result
        ↓
LTSSM receives result
        ↓
Receiver found?
   /               \
 Yes                No
  ↓                  ↓
Polling          Detect.Quiet
```

The shortest useful summary is:

```text
LTSSM
  ↓
mac_detect_req
  ↓
detect_pending
  ↓
P1 + TxElecIdle
  ↓
TxDetectRx
  ↓
PHY Receiver Detection
  ↓
PhyStatus + RxStatus
  ↓
detect_done + detect_rx_present
  ↓
LTSSM
```

This provides a clean separation between:

```text
PCIe LTSSM behavior
        ↓
PIPE control behavior
        ↓
PHY electrical behavior
        ↓
our RTL implementation
```
