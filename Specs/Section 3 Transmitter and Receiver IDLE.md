# PCIe PIPE Electrical Idle: `TxElecIdle`, `RxElecIdle`, EIOS, and `Recovery.Speed`

PCI Express uses Electrical Idle as part of several physical-layer and Link Training and Status State Machine (LTSSM) operations. In a PIPE-based implementation, Electrical Idle must be understood from two independent directions: the condition commanded on the local transmitter and the condition observed on the local receiver.

The principal PIPE signals associated with these functions are `TxElecIdle` and `RxElecIdle`. Although their names are similar, they serve fundamentally different purposes. `TxElecIdle` is a MAC-to-PHY control that commands the local transmitter into Electrical Idle, whereas `RxElecIdle` is a PHY-to-MAC status indication describing the electrical condition detected on the incoming receive lane.

This distinction becomes particularly important during LTSSM operations such as `Recovery.Speed`, where both link partners intentionally stop transmission at the current signaling rate before changing to another rate.

This chapter describes these mechanisms from an implementation-oriented perspective for a Gen1/Gen2-style PIPE interface. Exact LTSSM entry conditions, exit conditions, timers, and Electrical Idle inference rules remain dependent on the applicable PCIe Base Specification and PIPE revision. 

## Full-Duplex Nature of the PCIe Link

A PCIe link is full-duplex. Each device simultaneously owns one transmit direction and one receive direction.

Consider two devices, Device A and Device B:

```text
Device A                                      Device B

TX_A  ------------------------------------->  RX_B

RX_A  <-------------------------------------  TX_B
```

The two electrical paths are independent:

```text
A -> B

B -> A
```

Device A can therefore stop transmitting toward Device B while Device B continues transmitting toward Device A.

This independence requires Device A to maintain two distinct pieces of Electrical Idle information:

```text
TxElecIdle_A
    Controls the electrical state of A's transmitter.

RxElecIdle_A
    Reports the electrical condition observed on the signal
    arriving from B.
```

For Device A:

```text
TxElecIdle_A
    controls A -> B

RxElecIdle_A
    observes B -> A
```

The same relationship exists symmetrically for Device B.

## `TxElecIdle`

### Signal Direction

`TxElecIdle` is driven from the MAC toward the PHY transmitter.

```text
MAC
 |
 | TxElecIdle
 v
PHY transmitter
 |
 v
TX+ / TX-
```

It is a control signal rather than a receive-status indication.

### Functional Meaning

When:

```text
TxElecIdle = 1
```

the MAC commands the PHY to place the local transmitter into Electrical Idle.

Conceptually:

```text
TxElecIdle = 1
    "Place the local transmitter into Electrical Idle."
```

The PHY then stops normal high-speed differential transmission and establishes the transmitter Electrical Idle condition required by the physical interface.

When:

```text
TxElecIdle = 0
```

and the PHY is in an operating condition that permits normal transmission, such as P0, the PHY can transmit the parallel data supplied by the MAC.

The essential interpretation is therefore:

```text
TxElecIdle
    = local transmitter control
```

It does not report whether the remote device has stopped transmitting.

## `RxElecIdle`

### Signal Direction

`RxElecIdle` travels in the opposite direction, from the PHY receiver toward the MAC.

```text
RX+ / RX-
   |
   v
PHY receiver
   |
   | RxElecIdle
   v
MAC
```

It is a receive-side status indication.

### Functional Meaning

When:

```text
RxElecIdle = 1
```

the PHY reports that Electrical Idle has been detected on the local receive lane.

A useful conceptual interpretation is:

```text
rx_electrical_idle_detected
```

rather than:

```text
receiver_is_idle
```

The distinction is important. `RxElecIdle` describes the incoming electrical signal. It does not state that the receiver circuitry itself has been disabled or powered down.

The receiver may remain powered and continue monitoring the receive pins while reporting:

```text
RxElecIdle = 1
```

### Electrical-Idle Detection

Conceptually, a PHY receiver may be viewed as containing both a normal receive path and an electrical-idle detection mechanism.

```text
RX+ / RX-
    |
    v
Analog receive front end
    |
    +-----------------------------+
    |                             |
    v                             v
CDR / deserializer       Electrical-idle detector
                                      |
                                      v
                                  RxElecIdle
```

When sufficient high-speed differential activity is present:

```text
RxElecIdle = 0
```

When the incoming signal satisfies the PHY's Electrical Idle detection condition:

```text
RxElecIdle = 1
```

The actual analog detection circuitry and implementation details are PHY-dependent.

## Relationship Between the Two Link Ends

The transmit Electrical Idle command at one endpoint can correspond to a receive Electrical Idle indication at the other endpoint.

For Device A transmitting toward Device B:

```text
Device A                                    Device B

MAC_A
  |
  | TxElecIdle_A
  v
PHY_TX_A
  |
  |          A -> B
  +---------------------------------------> PHY_RX_B
                                             |
                                             v
                                        RxElecIdle_B
```

If Device A asserts:

```text
TxElecIdle_A = 1
```

then Device A's transmitter enters Electrical Idle. Device B may subsequently detect that condition and report:

```text
RxElecIdle_B = 1
```

Thus:

```text
A.TxElecIdle
```

and:

```text
B.RxElecIdle
```

can represent opposite-end views of the same physical A-to-B Electrical Idle event.

By contrast:

```text
A.TxElecIdle
```

and:

```text
A.RxElecIdle
```

refer to different physical directions.

This distinction is fundamental to any PIPE wrapper or LTSSM implementation.

## Independent Electrical Idle Conditions

Because PCIe is full-duplex, transmit and receive Electrical Idle states do not need to change simultaneously.

For example, Device A may command its transmitter idle:

```text
TxElecIdle_A = 1
```

while Device B is still actively transmitting toward Device A:

```text
RxElecIdle_A = 0
```

The combined state is therefore:

```text
TxElecIdle_A = 1
RxElecIdle_A = 0
```

which means:

```text
A -> B : A has stopped transmitting.

B -> A : A still detects incoming electrical activity.
```

If Device B later also enters Electrical Idle, Device A may observe:

```text
RxElecIdle_A = 1
```

At that point, from Device A's perspective:

```text
A -> B : local transmitter is electrically idle.

B -> A : incoming signal is detected as electrically idle.
```

## `RxElecIdle` and `RxValid`

`RxElecIdle` must not be confused with `RxValid`.

The two signals answer different questions:

```text
RxElecIdle
    Is the incoming lane electrically idle?

RxValid
    Is valid receive data or symbol information available?
```

The following state is therefore possible:

```text
RxElecIdle = 0
RxValid    = 0
```

This indicates that electrical activity is present, but valid receive data is not yet available.

A simplified receive startup sequence can be represented as:

```text
Remote transmitter starts
        |
        v
Electrical activity appears
        |
        v
RxElecIdle -> 0
        |
        v
CDR and receive processing stabilize
        |
        v
RxValid -> 1
```

Consequently, deassertion of `RxElecIdle` is not equivalent to the availability of valid decoded data.

## Electrical Idle Versus Receiver Detection

Electrical Idle detection is also distinct from PCIe receiver detection.

Receiver detection asks whether a suitable receiver termination is physically present at the far end of the link. It is associated with LTSSM receiver-detection operations such as those performed during `Detect`.

A simplified PIPE interaction is:

```text
LTSSM Detect.Active
        |
        v
TxDetectRx request
        |
        v
PHY performs receiver detection
        |
        v
PhyStatus / RxStatus
        |
        v
Receiver present or absent
```

`RxElecIdle`, in contrast, reports whether the incoming receive lane is currently electrically idle.

The distinction can be summarized as follows:

| Function           | Meaning                                                               |
| ------------------ | --------------------------------------------------------------------- |
| Receiver Detection | Determines whether a receiver termination is present at the far end   |
| `RxElecIdle`       | Reports whether the incoming lane is detected as electrically idle    |
| `RxValid`          | Reports whether valid receive data or symbol information is available |
| `PowerDown`        | Requests a PHY operating or power state                               |

Receiver detection therefore concerns endpoint presence, whereas Electrical Idle detection concerns the instantaneous electrical activity of the incoming signal.

## Electrical Idle Versus PHY Power State

Electrical Idle and PHY power state are related concepts, but they are not interchangeable.

`TxElecIdle` describes the signaling condition requested from the local transmitter:

```text
TxElecIdle = 1
    local TX is commanded into Electrical Idle
```

It does not inherently mean:

```text
PowerDown = P1
```

Similarly:

```text
RxElecIdle = 1
```

does not mean that the local receiver has been powered down.

PHY operating state is controlled separately through mechanisms such as `PowerDown`, with operation completion reported through `PhyStatus` where applicable.

A conceptual power-state transition is:

```text
PowerDown = P1
        |
        v
PHY transitions to P1
        |
        v
PhyStatus indicates completion
        |
        v
MAC treats normal receiver operation as unavailable
```

A MAC implementation should therefore track receiver availability using the PHY operating state rather than interpreting `RxElecIdle` as a power-state indication.

For example:

```verilog
wire rx_receiver_active;

assign rx_receiver_active =
    (PowerDown == P0) ||
    (PowerDown == P0S);
```

Receive-status information can then be qualified using the actual PHY availability state when required by the architecture.

## Electrical Idle Ordered Set and Physical Electrical Idle

PCIe separates the protocol notification of an Electrical Idle transition from the actual physical transition of the transmitter.

These two mechanisms are:

```text
EIOS
    Electrical Idle Ordered Set

TxElecIdle
    PIPE command controlling the physical transmitter
```

They are related but perform different functions.

### EIOS

The Electrical Idle Ordered Set is transmitted over the PCIe link as protocol information.

Conceptually, it informs the remote endpoint that the current transmit direction is intentionally transitioning toward Electrical Idle.

It is sent through the normal transmit datapath:

```text
MAC / LTSSM
    |
    | EIOS through TxData / TxDataK
    v
Local PHY
    |
    | serialize
    v
PCIe lane
    |
    v
Remote receiver
```

The remote endpoint can decode the ordered set using its normal receive logic.

### `TxElecIdle`

After the required ordered-set transmission, the MAC commands the PHY transmitter to enter the actual electrical-idle condition:

```text
MAC / LTSSM
    |
    | TxElecIdle = 1
    v
Local PHY
    |
    v
TX+/TX- enter Electrical Idle
```

The fundamental sequence is therefore:

```text
Transmit EIOS
      |
      v
Protocol notification to the remote endpoint
      |
      v
Assert TxElecIdle
      |
      v
Local PHY physically enters Electrical Idle
```

The two operations have clearly separated responsibilities:

```text
LTSSM / MAC
    understands PCIe protocol
    generates EIOS
    determines when Electrical Idle is required

PHY
    implements the analog transmitter
    responds to TxElecIdle
    creates the physical Electrical Idle condition
```

The PHY therefore does not need to inspect the outgoing symbol stream and independently decide that an EIOS pattern should automatically disable its transmitter. The MAC/LTSSM supplies the ordered set through the normal transmit interface and subsequently uses `TxElecIdle` to request the physical state change.

## Why EIOS and `TxElecIdle` Are Both Needed

EIOS alone does not guarantee that the transmitter physically stops signaling.

If EIOS were transmitted without subsequently asserting `TxElecIdle`, the remote endpoint could receive the protocol notification while the local PHY continued transmitting whatever data appeared later on the transmit interface.

Conceptually:

```text
EIOS
    = protocol indication

TxElecIdle
    = physical transmitter action
```

Conversely, abruptly forcing the transmitter into Electrical Idle without the appropriate protocol indication removes the contextual information that allows the remote link partner to interpret the transition correctly.

Without the preceding protocol context, the remote receiver might observe only:

```text
normal signaling
      |
      v
electrical activity disappears
      |
      v
RxElecIdle = 1
```

The disappearance of electrical activity alone does not inherently encode why signaling stopped. Depending on operating context, possibilities could include an intentional protocol transition, signal loss, CDR disruption, reset behavior, or another physical event.

The ordered-set information therefore provides protocol context, whereas `RxElecIdle` describes the physical electrical condition.

A simplified expected sequence is:

```text
Remote receives valid PCIe symbols
        |
        v
Remote receives EIOS
        |
        v
Protocol logic recognizes an intended idle transition
        |
        v
Remote transmitter activity disappears
        |
        v
Receive Electrical Idle is detected or inferred
```

## EIOS Detection and `RxElecIdle` Are Independent Observations

Detection of Electrical Idle on the receive pins does not prove that an EIOS was successfully decoded immediately beforehand.

These are separate observations.

Ordered-set recognition occurs through the receive datapath:

```text
RxData / RxDataK
      |
      v
Ordered-set recognition
      |
      v
rx_eios_detected
```

Electrical Idle detection occurs through PHY electrical-status logic:

```text
RX electrical condition
      |
      v
RxElecIdle
      |
      v
mac_rx_elecidle
```

Thus:

```text
rx_eios_detected
```

and:

```text
mac_rx_elecidle
```

represent different types of information.

The LTSSM can interpret both observations according to the requirements of the current state. Neither should automatically be treated as a substitute for the other.

## `Recovery.Speed`

`Recovery.Speed` is a particularly important use of Electrical Idle because the link intentionally stops signaling at the current rate before changing the physical signaling rate.

A simplified Gen1-to-Gen2 transition can be represented as:

```text
Current speed = Gen1
        |
        v
Recovery.RcvrLock
        |
        | TS1
        | speed_change = 1
        | advertise supported rates
        v
Recovery.RcvrCfg
        |
        | TS2
        | speed_change = 1
        | establish common rate
        v
Recovery.Speed
        |
        | transmit required EIOS
        | assert TxElecIdle
        | establish required RX Electrical Idle condition
        v
Request PHY rate change
        |
        v
Gen1 -> Gen2
        |
        v
Recovery.RcvrLock
        |
        | TS1 at Gen2
        | speed_change = 0
        v
Recovery.RcvrCfg
        |
        | TS2 at Gen2
        | speed_change = 0
        v
Recovery.Idle
        |
        v
L0 at Gen2
```

This diagram is intentionally architectural rather than normative. Exact transition criteria, timers, ordered-set requirements, and Electrical Idle inference rules are defined by the applicable PCIe specification.

### Functional Sequence

The `Recovery.Speed` operation can be divided into several responsibilities:

```text
Recovery.Speed
      |
      v
Satisfy required protocol conditions
      |
      v
Transmit EIOS
      |
      v
Assert local TxElecIdle
      |
      v
Establish or recognize required receive-side
Electrical Idle condition
      |
      v
Request new PHY Rate
      |
      v
Wait for rate-change completion
      |
      v
Resume Recovery at the new rate
```

The purpose of entering Electrical Idle before the rate change is to stop active transmission at the old signaling rate in an orderly manner before the PHY changes operating rate.

## `Recovery.Speed` from One Endpoint

Consider Device A.

The transmit-side sequence is:

```text
Device A LTSSM
      |
      v
Transmit EIOS
      |
      v
mac_tx_elecidle = 1
      |
      v
TxElecIdle_A = 1
      |
      v
A's PHY transmitter enters Electrical Idle
```

The receive-side sequence is independent:

```text
Device B enters Electrical Idle
      |
      v
B stops normal signaling toward A
      |
      v
A's PHY detects the receive idle condition
      |
      v
RxElecIdle_A = 1
      |
      v
mac_rx_elecidle_A = 1
```

Device A therefore maintains two different facts:

```text
Transmit direction:
    A commanded its own transmitter into Electrical Idle.

Receive direction:
    A detected or inferred that the incoming direction is idle.
```

These must not be collapsed into one state variable unless the higher-level design explicitly combines them after preserving their different meanings.

## `Recovery.Speed` Across Both Endpoints

A symmetrical view of both devices is:

```text
Device A                                      Device B

send EIOS                                    send EIOS
    |                                            |
    v                                            v
TxElecIdle_A = 1                           TxElecIdle_B = 1
    |                                            |
    |          A -> B becomes idle              |
    +------------------------------------------->|
                                                 |
                                                 v
                                           RxElecIdle_B
                                           or idle inference


                                                 |
    |          B -> A becomes idle              |
    |<-------------------------------------------+
    |
    v
RxElecIdle_A
or idle inference
```

Each endpoint controls only its own transmit direction and observes the remote transmit direction through its receiver.

This is the central architectural reason that both transmit and receive Electrical Idle information exist.

## Receive Electrical Idle Synchronization

In implementations where `RxElecIdle` is asynchronous to the MAC's `pclk` domain, the signal should not be consumed directly by synchronous MAC logic.

A typical wrapper contains a two-stage synchronizer:

```text
RxElecIdle
    |
    v
rx_ei_meta
    |
    v
rx_ei_sync
    |
    v
MAC logic
```

Example:

```verilog
reg rx_ei_meta;
reg rx_ei_sync;

always @(posedge pclk or negedge reset_n) begin
    if (!reset_n) begin
        rx_ei_meta <= 1'b1;
        rx_ei_sync <= 1'b1;
    end else begin
        rx_ei_meta <= RxElecIdle;
        rx_ei_sync <= rx_ei_meta;
    end
end
```

### First Synchronizer Stage

The first stage:

```verilog
rx_ei_meta <= RxElecIdle;
```

acts as the metastability-catching stage.

Because it directly samples the asynchronous input, it should not normally be used by functional state-machine logic.

### Second Synchronizer Stage

The second stage:

```verilog
rx_ei_sync <= rx_ei_meta;
```

provides the synchronized functional value.

The intended hierarchy is therefore:

```text
asynchronous PHY indication
        |
        v
RxElecIdle
        |
        v
+-------------+
| rx_ei_meta  |  first CDC stage
+-------------+
        |
        v
+-------------+
| rx_ei_sync  |  synchronized functional value
+-------------+
        |
        v
MAC / LTSSM logic
```

Functional logic should use `rx_ei_sync`, not the asynchronous `RxElecIdle` input or the first synchronizer stage.

## Optional Receive Electrical Idle Filtering

Clock-domain synchronization and signal filtering solve different problems.

The synchronizer primarily addresses metastability associated with an asynchronous domain crossing.

An optional filter can address short excursions, chatter, or undesirable brief changes in the synchronized signal.

For example:

```text
Accepted value = 0

rx_ei_sync:

0 0 0 1 1 0 0 0
      -----
       short excursion
```

If the implementation requires three consecutive samples before accepting a new value, this two-cycle excursion can be rejected.

Conceptually:

```text
rx_ei_sync        0  1  1  0
counter            0  1  2  0
mac_rx_elecidle   0  0  0  0
```

The filter counter measures how many consecutive synchronized samples have remained different from the currently accepted `mac_rx_elecidle` value.

### Filter-Length Interpretation

A clear implementation convention is:

```text
RX_EI_FILTER_CYCLES = 0
    no additional filtering

RX_EI_FILTER_CYCLES = 1
    one synchronized observation is sufficient

RX_EI_FILTER_CYCLES = N
    require N consecutive synchronized observations
```

The filter length is an implementation parameter. It must not be interpreted as a PCIe architectural rule requiring Electrical Idle to remain asserted for an arbitrary fixed number of `pclk` cycles.

An appropriate filter value depends on factors such as:

* target PHY behavior;
* CDC architecture;
* required glitch rejection;
* LTSSM timing budget.

Excessive filtering can delay legitimate LTSSM observations, so the filter must be chosen as part of the implementation timing architecture rather than as an arbitrary robustness measure.

## Example `RxElecIdle` Synchronizer and Filter

The following implementation combines a two-stage synchronizer with an optional consecutive-sample filter:

```verilog
reg       rx_ei_meta;
reg       rx_ei_sync;
reg [7:0] rx_ei_counter;

always @(posedge pclk or negedge reset_n) begin
    if (!reset_n) begin
        rx_ei_meta      <= 1'b1;
        rx_ei_sync      <= 1'b1;
        rx_ei_counter   <= 8'd0;
        mac_rx_elecidle <= 1'b1;
    end else begin
        // Two-stage synchronization.
        rx_ei_meta <= RxElecIdle;
        rx_ei_sync <= rx_ei_meta;

        // No pending change.
        if (rx_ei_sync == mac_rx_elecidle) begin
            rx_ei_counter <= 8'd0;
        end

        // Filtering disabled.
        else if (RX_EI_FILTER_CYCLES == 0) begin
            mac_rx_elecidle <= rx_ei_sync;
            rx_ei_counter   <= 8'd0;
        end

        // New value has remained stable long enough.
        else if (
            rx_ei_counter >=
            (RX_EI_FILTER_CYCLES - 1)
        ) begin
            mac_rx_elecidle <= rx_ei_sync;
            rx_ei_counter   <= 8'd0;
        end

        // Continue counting consecutive samples.
        else begin
            rx_ei_counter <= rx_ei_counter + 8'd1;
        end
    end
end
```

The accepted status remains unchanged until the synchronized input has remained different for the configured duration.

## MAC and LTSSM Use of `RxElecIdle`

`RxElecIdle` is not packet data. It is physical-layer status used by receive-control and LTSSM logic.

A typical architectural relationship is:

```text
RxElecIdle
    |
    v
CDC synchronization
    |
    v
optional filter
    |
    v
mac_rx_elecidle
    |
    +-----------------------------+
                                  |
                                  v
                              MAC / LTSSM
                                  ^
                                  |
               +------------------+------------------+
               |                                     |
            RxValid                         ordered-set logic
               |                                     |
        RxData / RxDataK                   TS1 / TS2 / EIOS /
                                            EIEOS recognition
```

The LTSSM interprets these independent pieces of information according to the currently active PCIe state.

A robust implementation therefore separates:

```text
physical electrical status
ordered-set recognition
receive-data validity
PHY power state
PHY operation completion
```

and combines them only in the state machine where their protocol meaning is known.

## Transmit Electrical Idle Control in a PIPE Wrapper

A PIPE wrapper may need to force Electrical Idle for reasons beyond an explicit LTSSM request.

For example, transmission may need to remain suppressed while the PHY is not ready, during certain power states, or while another PHY operation is in progress.

A possible architecture is:

```verilog
wire force_tx_idle;
wire effective_tx_idle;

assign force_tx_idle =
    !phy_ready ||
    (PowerDown != P0) ||
    (state == ST_WAIT) ||
    starting_operation;

assign effective_tx_idle =
    mac_tx_elecidle ||
    force_tx_idle;
```

In this structure:

```text
mac_tx_elecidle
    = protocol-level request from the MAC/LTSSM

force_tx_idle
    = wrapper-level requirement preventing normal transmission

effective_tx_idle
    = final Electrical Idle decision sent to the PHY
```

The wrapper therefore enforces a safe final transmitter state even if the MAC has not independently requested Electrical Idle.

### Example PHY Readiness Logic

For a wrapper FSM with states such as:

```text
ST_RESET
ST_IDLE
ST_WAIT
ST_FAULT
```

PHY readiness may be defined as:

```verilog
assign phy_ready =
    (state == ST_IDLE) ||
    (state == ST_WAIT);
```

The exact meaning of readiness is architecture-dependent, but the important principle is that transmit behavior should be conditioned by the wrapper's knowledge of PHY operating state.

## Transmit Datapath Behavior During Electrical Idle

When the final Electrical Idle decision is asserted, normal transmit data is not functionally meaningful to the serial transmitter.

A wrapper may explicitly drive benign values on the transmit datapath:

```verilog
always @(posedge pclk or negedge reset_n) begin
    if (!reset_n) begin
        TxData       <= 8'h00;
        TxDataK      <= 1'b0;
        TxElecIdle   <= 1'b1;
        TxCompliance <= 1'b0;
    end else begin
        TxElecIdle <= effective_tx_idle;

        TxCompliance <=
            mac_tx_compliance &&
            (PowerDown == P0) &&
            !effective_tx_idle;

        if (effective_tx_idle) begin
            TxData  <= 8'h00;
            TxDataK <= 1'b0;
        end else begin
            TxData  <= mac_tx_data;
            TxDataK <= mac_tx_datak;
        end
    end
end
```

The key behavior is:

```text
effective_tx_idle = 1
    -> TxElecIdle asserted
    -> normal TX datapath suppressed

effective_tx_idle = 0
    -> normal MAC transmit data forwarded
```

The zero values driven on `TxData` and `TxDataK` during Electrical Idle are an implementation choice associated with keeping inactive datapath values well defined; the Electrical Idle condition itself is established through `TxElecIdle`.

## `TxCompliance` Interaction

`TxCompliance` serves a different purpose from Electrical Idle. It is associated with PCIe transmitter compliance operation rather than normal packet transmission.

A wrapper can qualify the signal so that compliance operation is allowed only when the PHY is actively transmitting in P0:

```verilog
TxCompliance <=
    mac_tx_compliance &&
    (PowerDown == P0) &&
    !effective_tx_idle;
```

This separation preserves the distinction among:

```text
normal transmission
Electrical Idle
compliance transmission
PHY power-state control
```

These modes should not be represented by a single overloaded control signal.

## Recommended Responsibility Partitioning

A clean PCIe implementation separates protocol policy from physical implementation.

```text
LTSSM
    decides when protocol transitions occur

MAC transmit logic
    generates ordered sets and normal transmit data

MAC receive logic
    recognizes received ordered sets and valid data

PIPE wrapper
    conditions MAC/PHY controls and status
    handles synchronization where required

PHY
    performs electrical transmission and reception
    performs physical rate and power operations
```

During a speed change, the architecture can therefore be viewed as:

```text
                Recovery.Speed
                     |
                     v
          protocol conditions satisfied
                     |
                     v
                 send EIOS
                     |
                     v
          assert local TxElecIdle
                     |
                     v
      determine required RX idle condition
                     |
                     v
             idle requirements met
                     |
                     v
              request new Rate
                     |
                     v
             wait for PhyStatus
                     |
                     v
         continue Recovery at new rate
```

This partitioning prevents the PHY wrapper from becoming an unintended second LTSSM and prevents the LTSSM from directly implementing analog PHY behavior.

## Important Signal Distinctions

The principal PIPE signals involved in these operations can be summarized as follows:

| Signal or Function | Direction  | Meaning                                                                                    |
| ------------------ | ---------- | ------------------------------------------------------------------------------------------ |
| `TxElecIdle`       | MAC -> PHY | Commands the local transmitter into Electrical Idle                                        |
| `RxElecIdle`       | PHY -> MAC | Reports Electrical Idle detected on the incoming receive lane                              |
| `RxValid`          | PHY -> MAC | Indicates that valid receive data or symbol information is available                       |
| `TxDetectRx`       | MAC -> PHY | Requests receiver-termination detection                                                    |
| `RxStatus`         | PHY -> MAC | Reports receive status and, where applicable, receiver-detection result                    |
| `PowerDown`        | MAC -> PHY | Requests a PHY operating or power state                                                    |
| `PhyStatus`        | PHY -> MAC | Reports completion of applicable PHY operations such as rate, power, or receiver detection |

These signals describe different dimensions of PHY behavior and should not be used interchangeably.

## Common Misunderstandings

### `TxElecIdle` Does Not Describe the Local Receiver

`TxElecIdle` applies exclusively to the local transmit direction.

For Device A:

```text
TxElecIdle_A -> A to B
```

It provides no direct information about whether B is transmitting toward A.

### `RxElecIdle` Does Not Mean the Receiver Is Powered Down

`RxElecIdle = 1` means the incoming electrical signal is detected as idle. Receiver availability is determined through PHY operating-state information.

### `RxElecIdle = 0` Does Not Mean Valid Data Is Available

Electrical activity may be present before receive synchronization, alignment, or other processing has produced valid receive data.

Thus:

```text
RxElecIdle = 0
RxValid    = 0
```

is a legitimate conceptual condition.

### `RxElecIdle` Is Not Receiver Detection

Receiver detection determines whether a receiver termination exists at the far end. `RxElecIdle` determines whether incoming differential signaling is currently electrically idle.

### `RxElecIdle = 1` Does Not Prove That EIOS Was Decoded

Ordered-set recognition and electrical-idle detection are separate mechanisms.

```text
rx_eios_detected
```

comes from protocol decoding, while:

```text
mac_rx_elecidle
```

originates from physical electrical-status information.

### EIOS Does Not Physically Shut Down the Transmitter

EIOS is transmitted as protocol information. The actual transmitter transition into Electrical Idle is controlled through `TxElecIdle`.

### `TxElecIdle` Does Not Automatically Imply a PHY Low-Power State

The transmitter can be electrically idle without the entire PHY having entered a power state such as P1.

Electrical signaling state and PHY power state must therefore remain separate architectural concepts.

## Complete Architectural Model

For one PCIe endpoint, the relationship among the LTSSM, PIPE wrapper, transmitter, receiver, and Electrical Idle indications can be represented as:

```text
                         LTSSM
                           |
               +-----------+-----------+
               |                       |
               v                       |
        mac_tx_elecidle                |
               |                       |
               v                       |
          PIPE wrapper                 |
               |                       |
               v                       |
          TxElecIdle                   |
               |                       |
               v                       |
          Local PHY TX                 |
               |                       |
===============|====== PCIe Link ======|===============
               |                       |
          Local PHY RX                 |
               |                       |
               v                       |
          RxElecIdle                   |
               |                       |
               v                       |
        CDC synchronizer               |
               |                       |
               v                       |
         optional filter               |
               |                       |
               v                       |
       mac_rx_elecidle ----------------+
```

The transmit and receive directions remain independent throughout this model.

The LTSSM uses transmit-side Electrical Idle control to determine what its own transmitter does, while receive-side Electrical Idle status provides physical information about what the opposite endpoint's transmitter is doing.

## Summary

PCIe PIPE Electrical Idle handling is built around a strict separation between local transmitter control and remote transmitter observation.

`TxElecIdle` is a MAC-to-PHY command that causes the local transmitter to enter Electrical Idle. `RxElecIdle` is a PHY-to-MAC indication that reports an Electrical Idle condition detected on the incoming receive lane. Because PCIe is full-duplex, these signals refer to independent directions and may legitimately have different values at the same endpoint.

Electrical Idle must also remain distinct from other PIPE concepts. `RxValid` describes the availability of valid receive data, receiver detection determines whether a receiver termination is present, `PowerDown` controls PHY operating state, and `PhyStatus` reports completion of applicable PHY operations.

Protocol notification and physical Electrical Idle are similarly separated. EIOS is transmitted through the normal PCIe datapath to provide protocol context for an intentional Electrical Idle transition, while `TxElecIdle` commands the PHY to perform the corresponding electrical action.

During `Recovery.Speed`, these mechanisms work together so that the link can stop old-rate transmission, establish the required Electrical Idle conditions, change PHY signaling rate, and resume Recovery at the new rate.

A well-structured implementation therefore preserves four independent categories of information:

```text
Protocol intent
    EIOS and LTSSM state

Local transmitter control
    TxElecIdle

Incoming electrical condition
    RxElecIdle

PHY operating control and completion
    PowerDown, Rate, PhyStatus
```

Maintaining these distinctions produces a cleaner PIPE wrapper, a more deterministic LTSSM implementation, and a more accurate representation of the boundary between PCIe protocol behavior and PHY electrical behavior.
