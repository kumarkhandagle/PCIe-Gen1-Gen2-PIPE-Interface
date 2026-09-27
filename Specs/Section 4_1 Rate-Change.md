# PCIe LTSSM Recovery and Gen1/Gen2 Rate Change

PCI Express uses the LTSSM `Recovery` state whenever an already configured link must re-establish reliable communication before returning to `L0`. Recovery is therefore a **retraining and resynchronization mechanism**, not merely a speed-change mechanism.

This chapter covers a PCIe Gen1/Gen2, 8b/10b, single-lane (`x1`) implementation, including same-rate retraining, `L1` exit, Gen1↔Gen2 rate change, PIPE/PHY coordination, and fallback after failed higher-rate training.

For this implementation, Recovery contains four substates:

```text
RECOVERY_RCVRLOCK
RECOVERY_RCVRCFG
RECOVERY_SPEED
RECOVERY_IDLE
```

`Recovery.Equalization` is not required for the Gen1/Gen2 path, and lane-to-lane deskew is not required for the `x1` implementation.

## 1. Recovery Overview

Once initial link training has completed, the Link/Lane configuration is already known. If communication becomes unreliable, PCIe does not normally need to restart the complete:

```text
Detect → Polling → Configuration
```

sequence. Instead, Recovery preserves the established configuration and rebuilds the synchronization needed to resume normal operation.

Recovery is used for four primary cases:

1. Same-rate retraining after persistent receive-path or synchronization failure in `L0`.
2. Return from `L1` to `L0` at the existing rate.
3. Directed Gen1↔Gen2 speed change.
4. Fallback after unsuccessful training at a newly selected rate.

The key state paths are:

```text
Same-rate retraining:
L0 → RcvrLock → RcvrCfg → Idle → L0

L1 exit at the same rate:
L1 → PHY Wake → RcvrLock → RcvrCfg → Idle → L0

Speed change:
L0 @ old rate
  → RcvrLock
  → RcvrCfg
  → Speed
  → RcvrLock @ new rate
  → RcvrCfg @ new rate
  → Idle
  → L0 @ new rate
```

The two passes through `RcvrLock` and `RcvrCfg` around `Recovery.Speed` are fundamental. The first pass coordinates the rate change at the old rate. The second pass proves that communication actually works at the new rate.

## 2. Recovery.RcvrLock

`Recovery.RcvrLock` establishes that valid training sequences can be reliably received from the link partner.

For Gen1/Gen2, successful recognition of valid TS1/TS2 Ordered Sets provides protocol-level evidence that the following receive functions are operating:

```text
Analog reception
    ↓
CDR / bit synchronization
    ↓
10-bit symbol boundary recovery
    ↓
8b/10b decoding
    ↓
COM recognition
    ↓
TS1 / TS2 recognition
```

A separate raw `cdr_locked` signal is therefore not mandatory if valid decoded training already provides sufficient evidence to the LTSSM.

### 2.1 Transmit Behavior

During `Recovery.RcvrLock`, the MAC transmits TS1 Ordered Sets.

```text
LTSSM
  ↓
TS1 request
  ↓
Ordered-Set Generator
  ↓
PIPE TxData / TxDataK
  ↓
PHY
```

### 2.2 Receive Qualification

The receiver validates qualifying training sequences and checks relevant Link/Lane and rate-related training information. A counter should be used so that receiver lock is based on persistent valid training rather than one isolated observation.

```text
valid_training_os_count
        ↓
required threshold reached
        ↓
Recovery.RcvrCfg
```

### 2.3 First and Second Passes

During the first pass of a speed-change sequence, `RcvrLock` operates at the old rate and confirms that communication is still reliable while the speed-change request is propagated or observed.

After `Recovery.Speed`, `RcvrLock` operates at the target rate and verifies whether the actual serial link works at the new speed.

A critical distinction is:

```text
PhyStatus / rate_done
    = local PHY operation completed

Valid TS1 at the target rate
    = actual link communication works at the target rate
```

## 3. Recovery.RcvrCfg

`Recovery.RcvrCfg` performs the TS2-based training and configuration agreement that follows successful receive synchronization.

The distinction between the first two Recovery substates is:

```text
RcvrLock
    = establish reliable training reception

RcvrCfg
    = confirm the relevant link/training configuration
      and determine the next Recovery action
```

During `Recovery.RcvrCfg`, the transmitter sends TS2 Ordered Sets using the already established Link/Lane configuration.

### 3.1 First Pass During Speed Change

At the old rate, `RcvrCfg` determines whether the requested rate transition can proceed.

Typical implementation state includes:

```text
successful_speed_negotiation
```

The transition policy is:

```text
Recovery.RcvrCfg
        ↓
Speed change successfully negotiated?
   ┌────┴────┐
  Yes        No
   ↓          ↓
Recovery.   Recovery.
Speed       Idle
```

### 3.2 Second Pass After Speed Change

After new-rate `RcvrLock` succeeds, the LTSSM enters `RcvrCfg` again. The physical rate transition has already occurred, so the second pass performs the final TS2 training/configuration agreement before `Recovery.Idle`.

`RcvrCfg` must therefore not be treated merely as an acknowledgment of receiver lock.

## 4. Recovery.Speed and PIPE/PHY Coordination

`Recovery.Speed` is the only Recovery substate in this architecture that performs the actual physical data-rate transition.

For example:

```text
2.5 GT/s → 5.0 GT/s
```

The high-level sequence is:

```text
Recovery.RcvrCfg
        ↓
Speed change negotiated
        ↓
Recovery.Speed
        ↓
Transmit EIOS
        ↓
Assert TxElecIdle
        ↓
Establish safe old-rate idle condition
        ↓
Request RxStandby when required
        ↓
Wait for RxStandbyStatus
        ↓
Request target Rate
        ↓
PHY changes operating rate
        ↓
Wait for PhyStatus / rate_done
        ↓
Satisfy required Recovery.Speed idle timing
        ↓
Release temporary controls
        ↓
Recovery.RcvrLock @ target rate
```

### 4.1 EIOS and TxElecIdle

Before entering Electrical Idle, the MAC transmits an Electrical Idle Ordered Set (EIOS):

```text
TS2 TS2 TS2 ...
      ↓
     EIOS
      ↓
TxElecIdle = 1
      ↓
Electrical Idle
```

`TxElecIdle` is a transmitter signaling control:

```text
TxElecIdle = 0
    → active serial signaling

TxElecIdle = 1
    → transmitter in Electrical Idle
```

Its purpose during a speed transition is to stop active old-rate signaling before the PHY operating rate changes.

`TxElecIdle` is not a general PHY power-control signal.

### 4.2 RxStandby and RxStandbyStatus

`RxStandby` prepares the receiver for the rate transition. The operation is a request/confirmation handshake:

```text
RxStandby = 1
      ↓
PHY places RX in standby
      ↓
RxStandbyStatus = 1
      ↓
Rate transition may proceed
```

The controller must distinguish:

```text
RxStandby
    = request

RxStandbyStatus
    = confirmation
```

The rate request must not be issued merely because `RxStandby` has been asserted.

### 4.3 Rate Request and PHY Operation

Once the required idle and receiver conditions are satisfied, the LTSSM requests the target rate through the PIPE wrapper:

```text
LTSSM
  ↓
mac_rate = target_rate
  ↓
PIPE Wrapper
  ↓
Rate = target_rate
  ↓
PHY
```

The PHY performs implementation-specific reconfiguration that may include:

```text
TX PLL reconfiguration
serializer-frequency change
TX target-rate configuration
RX/CDR operating-range change
PCLK update
```

For an 8-bit PIPE example:

```text
Gen1: 2.5 GT/s, PCLK ≈ 250 MHz
Gen2: 5.0 GT/s, PCLK ≈ 500 MHz
```

### 4.4 PhyStatus and rate_done

The PHY reports completion of the local operation using `PhyStatus`, which may be abstracted to the LTSSM as `rate_done`.

```text
PhyStatus
   ↓
rate_done
```

This completion indication does not prove that the remote link has trained successfully at the new rate.

The required transition is:

```text
Recovery.Speed
      ↓
rate_done
      ↓
Recovery.RcvrLock @ new rate
```

A direct transition from `rate_done` to `L0` is incorrect.

### 4.5 Electrical Idle Timing

The implementation must satisfy the applicable PCIe 2.x `Recovery.Speed` Electrical Idle timing requirement before restarting active signaling. For the project reference behavior, successful Gen2-era speed negotiation includes a minimum 800 ns Electrical Idle interval.

The design must therefore not assume:

```text
rate_done = 1
    → immediately transmit TS1
```

## 5. PIPE Power-State Rules for Rate Change

Power-state transitions and rate transitions are separate operations.

For this architecture, a normal rate change is legal only from `P0` or `P1`.

```verilog
assign rate_change_allowed =
    ((PowerDown == P0) || (PowerDown == P1)) &&
    TxElecIdle &&
    ((PowerDown != P0) ||
     (RxStandby && RxStandbyStatus)) &&
    !loopback_mode;
```

This expression is a protocol/PHY safety gate.

| Current PIPE State | Rate Change Allowed? | Required Handling |
|---|---:|---|
| `P0` | Yes | Assert `TxElecIdle`, request `RxStandby`, wait for `RxStandbyStatus`, then change `Rate` |
| `P0s` | No | Return to `P0` first |
| `P1` | Yes | Maintain the required idle condition and perform the rate transition |
| `P2` | No | Wake to an appropriate synchronous operating state first |

### 5.1 P0

`P0` is fully operational, so both transmit and receive paths may still be active. Before changing rate:

```text
P0
 ↓
TxElecIdle = 1
 ↓
RxStandby = 1
 ↓
Wait for RxStandbyStatus
 ↓
Change Rate
```

### 5.2 P1

`P1` is treated as a quiescent PHY state in this implementation. The additional P0-specific receiver standby handshake is therefore not required before the rate request, provided the required idle conditions remain satisfied.

### 5.3 P0s

`P0s` remains a shallow, same-rate power state. Receiver power-management controls may be meaningful in `P0s`, but that does not make it a legal rate-change state.

If a rate change is required:

```text
P0s
 ↓
P0
 ↓
Normal P0 rate-change sequence
```

The following operations must remain distinct:

```text
P0s → P0
    = power-state transition

P0 → target rate
    = rate transition
```

### 5.4 P2

`P2` is a deeper low-power state and is not a valid starting point for the normal synchronous rate-change sequence. The PHY must first return to a state where the required control clocking and handshake behavior are available.

### 5.5 Power-State Completion vs Rate Completion

A generic PHY completion indication must always be interpreted together with the recorded outstanding operation type.

```text
Power-state transition
        ≠
Rate transition
```

A controller should therefore never treat a completion pulse as self-describing.

## 6. Recovery.Idle

`Recovery.Idle` is the final handshake before normal packet traffic resumes. It uses **Logical Idle**, not Electrical Idle.

| Characteristic | Electrical Idle | Logical Idle |
|---|---|---|
| Serial signaling | Electrically quiet | Actively signaling |
| Clocking | Transition/low-power context | Active |
| Typical Recovery use | `Recovery.Speed` | `Recovery.Idle` |
| Purpose | Quiesce the physical interface | Confirm operational readiness |

Once the required Logical Idle transmit and receive conditions are satisfied:

```text
Recovery.Idle
      ↓
L0
```

Normal TLP, DLLP, SKP, and Ordered-Set traffic may then resume.

## 7. Same-Rate Recovery and L1 Exit

Same-rate Recovery is used when the receive path must be retrained but the data rate does not change.

Persistent symptoms that may justify Recovery include:

- repeated 8b/10b decode errors;
- repeated disparity errors;
- persistent invalid receive indications;
- inability to recognize valid protocol symbols or Ordered Sets;
- PHY-specific indications that the receive path is no longer trustworthy.

Recovery should not be triggered by one isolated packet or symbol error when the Data Link Layer can handle the event normally.

A practical implementation may use a persistence threshold:

```verilog
if (rx_serious_error)
    rx_error_count <= rx_error_count + 1;
else
    rx_error_count <= 0;

if (rx_error_count >= RECOVERY_ERROR_THRESHOLD)
    recovery_request <= 1'b1;
```

For same-rate retraining:

```text
L0
 ↓
Recovery.RcvrLock
 ↓
Recovery.RcvrCfg
 ↓
Recovery.Idle
 ↓
L0
```

For `L1 → L0`, the PHY must first be restored to the active condition required for training. `TxElecIdle` does not itself power up the transmitter or receiver circuitry.

```text
L1
 ↓
Restore PHY to active condition
 ↓
Recovery.RcvrLock
 ↓
Recovery.RcvrCfg
 ↓
Recovery.Idle
 ↓
L0
```

`Recovery.Speed` is skipped in both cases.

## 8. Speed-Change Failure and Fallback

A successful local rate transition followed by unsuccessful target-rate training must be treated as a failed speed-change attempt.

The controller should retain at least:

```text
original_rate
target_rate
changed_speed_recovery
```

A representative fallback path is:

```text
Recovery.RcvrLock @ target rate
        ↓
Training timeout / failure
        ↓
Recovery.Speed
        ↓
Electrical Idle
        ↓
Rate = original_rate
        ↓
PHY returns to original rate
        ↓
Recovery.RcvrLock @ original rate
        ↓
Recovery.RcvrCfg
        ↓
Recovery.Idle
        ↓
L0
```

The architecture must never infer link success merely because the local PHY accepted the new rate or asserted `PhyStatus`.

## 9. Recommended RTL State and Partitioning

The Recovery controller should explicitly retain semantic state rather than infer protocol history from unrelated control signals.

Recommended state includes:

| Variable | Purpose |
|---|---|
| `directed_speed_change` | Indicates that a protocol-coordinated speed transition is requested |
| `successful_speed_negotiation` | Indicates that a valid common target rate has been established |
| `changed_speed_recovery` | Distinguishes pre-rate-change and post-rate-change Recovery passes |
| `original_rate` | Stores the previously working rate for fallback |
| `target_rate` | Stores the rate selected for the current transition |
| `valid_training_os_count` | Qualifies valid training reception |
| `rx_ts2_count` | Tracks required TS2 reception |
| `logical_idle_count` | Qualifies Recovery.Idle completion |

A clean implementation separates Recovery into three functional blocks.

### 9.1 LTSSM Controller

Responsible for:

```text
state transitions
training qualification
timeouts
speed-change intent
target-rate selection
fallback decisions
```

### 9.2 Ordered-Set Generator and Detector

Responsible for:

```text
TS1 generation/detection
TS2 generation/detection
EIOS generation
Logical Idle generation/detection
training-field extraction
```

### 9.3 PIPE Operation Controller

Responsible for safely sequencing:

```text
TxElecIdle
RxStandby
RxStandbyStatus
Rate
PhyStatus
rate_done
TxDeemph, where applicable
```

The LTSSM should request semantic operations and leave PHY-specific timing and sequencing details to the PIPE wrapper.

## 10. Design Invariants and Verification Essentials

The following invariants capture the essential correctness requirements of the Recovery implementation:

1. `Recovery.Speed` is entered only for a valid speed-change operation.
2. EIOS precedes transmitter Electrical Idle during a rate transition.
3. The PHY rate does not change while active old-rate signaling is still intentionally transmitted.
4. A P0 rate transition does not begin before `RxStandby && RxStandbyStatus` is true.
5. `PhyStatus` / `rate_done` indicates local PHY completion only and must not cause a direct transition to `L0`.
6. A successful speed change always performs a second `RcvrLock → RcvrCfg` pass at the target rate.
7. Same-rate Recovery and same-rate `L1` exit skip `Recovery.Speed`.
8. `Rate` does not change while `PowerDown == P0s` or `PowerDown == P2`.
9. Power-state transitions and rate transitions are tracked as different outstanding PHY operations.
10. Failed target-rate training can restore `original_rate`.
11. Electrical Idle and Logical Idle remain distinct in RTL, comments, and verification sequences.
12. `L0` is entered only after the required `Recovery.Idle` conditions are satisfied.

## 11. State Responsibility Summary

| State | LTSSM Responsibility | MAC / Ordered-Set Responsibility | PIPE / PHY Role |
|---|---|---|---|
| `RcvrLock` | Validate and count training | Generate/detect TS1 | Recover and transport valid symbols |
| `RcvrCfg` | Confirm training/configuration and select next action | Generate/detect TS2 | Maintain normal training transport |
| `Speed` | Coordinate the physical rate transition | Generate EIOS | Control Electrical Idle, standby, rate request, and completion |
| `RcvrLock` after speed change | Verify target-rate operation | TS1 at target rate | Establish target-rate receive lock |
| `RcvrCfg` after speed change | Complete target-rate training agreement | TS2 at target rate | Maintain stable target-rate operation |
| `Idle` | Confirm readiness for `L0` | Generate/detect Logical Idle | Maintain active signaling |
| `L0` | Normal operational link | TLP/DLLP/Ordered-Set traffic | Normal PIPE/serial operation |

## Summary

PCIe Recovery restores reliable communication on an already configured link. For Gen1/Gen2, the central substate responsibilities are:

```text
RcvrLock
    = establish reliable training reception

RcvrCfg
    = confirm training/configuration and determine the next action

Speed
    = safely perform the physical rate transition

Idle
    = confirm readiness to resume normal packet traffic
```

Same-rate Recovery uses:

```text
RcvrLock → RcvrCfg → Idle
```

A speed transition uses:

```text
RcvrLock
 → RcvrCfg
 → Speed
 → RcvrLock
 → RcvrCfg
 → Idle
```

The most important architectural distinction is that local PHY completion and successful link operation are not the same event. `PhyStatus` or `rate_done` proves only that the local PHY completed its requested operation. Valid target-rate TS1/TS2 training proves that the PCIe link actually works at the selected rate.

Rate transitions must also remain distinct from power-state transitions. Normal rate changes originate only from legal `P0` or `P1` contexts, while `P0s` and `P2` must first transition to an appropriate operating state. This separation keeps the LTSSM, PIPE wrapper, and PHY responsibilities clear and makes the Recovery sequence easier to implement, review, and verify.
