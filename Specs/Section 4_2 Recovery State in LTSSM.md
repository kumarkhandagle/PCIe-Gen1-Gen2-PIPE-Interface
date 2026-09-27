For your Gen1/Gen2 implementation, the best reference model is the PCIe 2.x Recovery state machine. In that generation, Recovery has four relevant substates:

```text
Recovery.RcvrLock
Recovery.Speed
Recovery.RcvrCfg
Recovery.Idle
```

The important nuance is that the normal traversal is not simply the order in which the states are listed. For an ordinary recovery with no speed change:

```text
Recovery.RcvrLock
        ↓
Recovery.RcvrCfg
        ↓
Recovery.Idle
        ↓
L0
```

For a Gen1 → Gen2 speed change, the path is:

```text
                         old rate: 2.5 GT/s

Recovery.RcvrLock
        ↓
Recovery.RcvrCfg
        ↓
Recovery.Speed
        │
        │ PHY physically changes
        │ 2.5 → 5.0 GT/s
        ↓
Recovery.RcvrLock
        ↓
Recovery.RcvrCfg
        ↓
Recovery.Idle
        ↓
L0

                         new rate: 5.0 GT/s
```

That second pass through `RcvrLock` and `RcvrCfg` is critical. The first pass negotiates the change; `Recovery.Speed` performs it; the second pass proves that the link actually works at the new speed. The PCIe 2.x specification explicitly describes this speed-change loop.

## What Recovery is for

Recovery is used on an already configured link to re-establish reliable communication without starting completely from Detect/Polling/Configuration.

The specification describes Recovery as a state where the configured Link/Lane numbers are retained while the link can re-establish bit lock and Symbol lock, retrain, change operating speed, and recover from certain link problems.
<img width="1280" height="1810" alt="image" src="https://github.com/user-attachments/assets/018c8ec2-a1e6-42e8-8f25-0136c96ac9d4" />


So think of Recovery as:

```text
"The link topology is already known.

Do not renegotiate everything from scratch.

Re-establish the PHY/link synchronization,
possibly change speed,
verify both directions,
then return to L0."
```

For your x1 design this simplifies things because there is only one configured lane.

---

# 1. Recovery.RcvrLock

The primary objective of `Recovery.RcvrLock` is:

```text
Can I reliably receive training sequences from the other side?
```

At Gen1/Gen2 this means re-establishing:

```text
analog signal reception
        ↓
CDR / bit lock
        ↓
10-bit symbol boundaries
        ↓
8b/10b decoding
        ↓
COM detection
        ↓
TS1/TS2 Ordered Set recognition
```

The LTSSM itself generally does not need a raw:

```text
cdr_locked
```

signal.

Instead, valid received TS Ordered Sets are the protocol-level evidence that the receive path is working.

### What transmitter sends

In `Recovery.RcvrLock`, the transmitter sends:

```text
TS1
TS1
TS1
TS1
...
```

on every configured lane.

PCI-SIG explicitly states that TS1s are transmitted continuously in this state, except for required SKP insertion and, above 2.5 GT/s, EIEOS insertion. ([PCI-SIG](https://pcisig.com/section-4264-what-specification-condition-transmitting-ts1-ordered-sets-while-recoverrcvrlock-state?utm_source=chatgpt.com "Section 4.2.6.4 - What is the specification condition on transmitting TS1 Ordered sets while in Recover.RcvrLock state? | PCI-SIG"))

For your x1 MAC:

```text
LTSSM
   │
   │ os_type = TS1
   ▼
OS_GENERATOR
   │
   ▼
TS1 symbols
   │
   ▼
PIPE TxData/TxDataK
   │
   ▼
PHY
```

### What receiver looks for

The receive path looks for valid TS1/TS2 Ordered Sets with the expected:

```text
Link Number
Lane Number
Data Rate Identifier
Training Control information
```

For the normal transition toward `Recovery.RcvrCfg`, the receiver needs the required sequence of valid training Ordered Sets. PCI-SIG clarifies that the required count can be satisfied with TS1s, TS2s, or a qualifying combination totaling eight. ([PCI-SIG](https://pcisig.com/faq?keys=3.0\&page=1\&utm_source=chatgpt.com "FAQ | PCI-SIG"))

For a simple implementation you can think:

```text
valid_training_os_count

0
1
2
...
8
↓
receiver synchronization considered established
↓
Recovery.RcvrCfg
```

---

# `speed_change` becomes important here

Suppose Device A wants Gen2.

Device A enters Recovery with:

```text
directed_speed_change = 1
```

Therefore its TS1 carries:

```text
speed_change = 1
```

Conceptually:

```text
Device A                                Device B

Recovery.RcvrLock

TS1 speed_change=1
-------------------------------------->

TS1 speed_change=1
-------------------------------------->

TS1 speed_change=1
-------------------------------------->

                                        sees repeated request
                                        ↓
                                        directed_speed_change=1

                         TS1 speed_change=1
<--------------------------------------
```

The initiating side already knows that it wants the speed change. The responding side learns that fact from received TS Ordered Sets.

The PCIe 2.x specification describes `directed_speed_change` being propagated through TS1 during `Recovery.RcvrLock`.

So `RcvrLock` has two jobs during Gen1→Gen2:

```text
JOB 1:
prove the existing 2.5-GT/s receive path works

JOB 2:
coordinate the intention to perform a speed change
```

---

# 2. Recovery.RcvrCfg

Once receive lock/training is established, the LTSSM moves to:

```text
Recovery.RcvrCfg
```

Now the transmitter switches from:

```text
TS1
```

to:

```text
TS2
```

The specification explicitly requires TS2 transmission on configured lanes using the already-established Link/Lane numbers.

The conceptual distinction is useful:

```text
RcvrLock:
"Can we hear each other?"

RcvrCfg:
"Do we agree on the link parameters and what happens next?"
```

For our speed-change case:

```text
Device A                        Device B

TS2
speed_change = 1
supported rates = Gen1, Gen2
------------------------------>

                  TS2
                  speed_change = 1
                  supported rates = Gen1, Gen2
<------------------------------
```

Now each side can determine:

```text
My supported rates:
Gen1 + Gen2

Remote supported rates:
Gen1 + Gen2

Highest common rate:
Gen2
```

Therefore:

```text
new_rate = 5.0 GT/s
```

---

# Gen2 de-emphasis is also coordinated

For 5.0 GT/s operation, PCIe 2.x also deals with selectable de-emphasis information during Recovery.

This connects directly to your PIPE control:

```verilog
TxDeemph
```

Your wrapper already has logic such as:

```verilog
if (start_rate_operation)
    TxDeemph <= mac_rate ? mac_tx_deemph : 1'b1;
```

During `Recovery.RcvrCfg`, the protocol side determines/configures the appropriate Gen2 de-emphasis selection; `Recovery.Speed` is where that setting becomes associated with the actual 5-GT/s operation. The Gen2 spec describes the selectable de-emphasis handling in `Recovery.RcvrCfg` and `Recovery.Speed`.

---

# What decides whether RcvrCfg goes to Speed or Idle?

This is one of the most important Recovery concepts.

If:

```text
speed_change = 1
```

and both sides have successfully exchanged the required TS2s and have a common higher data rate, then:

```text
Recovery.RcvrCfg
        ↓
Recovery.Speed
```

The specification sets the equivalent concept of:

```text
successful_speed_negotiation = 1
```

and records the common rate.

But if there is no speed change:

```text
speed_change = 0
```

then RcvrCfg can proceed toward:

```text
Recovery.Idle
```

after the required TS2 handshake.

Therefore:

```text
                     Recovery.RcvrCfg
                           |
             +-------------+-------------+
             |                           |
       speed change                  no speed change
             |                           |
             v                           v
      Recovery.Speed              Recovery.Idle
```

This is why a speed change creates an extra loop through Recovery.

---

# 3. Recovery.Speed

`Recovery.Speed` is the state most directly connected to your PIPE wrapper.

Its purpose is:

> Stop serial communication safely, change the physical data rate, and then restart training.

This is where the actual:

```text
2.5 GT/s → 5.0 GT/s
```

transition occurs.

Not in `RcvrLock`.

Not in `RcvrCfg`.

It occurs in:

```text
Recovery.Speed
```

---

# First: transmit EIOS

Before entering Electrical Idle, the transmitter sends an:

```text
EIOS
Electrical Idle Ordered Set
```

Then:

```text
TX → Electrical Idle
```

The specification requires an EIOS before entering Electrical Idle during this transition.

So:

```text
TS2 TS2 TS2 ...
       ↓
     EIOS
       ↓
Electrical Idle
```

For your design:

```text
LTSSM
   │
   │ request EIOS
   ▼
OS Generator
   │
   ▼
EIOS
   │
   ▼
PHY transmits EIOS
```

Then after EIOS:

```verilog
mac_tx_elecidle = 1;
```

causes:

```verilog
TxElecIdle = 1;
```

---

# Both directions must become idle

Suppose we have:

```text
Device A                             Device B
```

A cannot arbitrarily switch to 5 GT/s while B is still sending 2.5-GT/s TS2s.

The sequence needs convergence:

```text
A sends EIOS
A enters Electrical Idle
                         B detects idle

                         B sends EIOS
                         B enters Electrical Idle
A detects idle
```

Now:

```text
A TX idle
A RX sees idle

B TX idle
B RX sees idle
```

At this point both ends know that normal old-rate signaling has stopped.

This is the safe point to change frequency.

The specification explicitly states that the frequency must not change to the new data rate until receiver lanes have entered Electrical Idle.

---

# Then your PIPE rate-change sequence occurs

Now we can directly map this to the wrapper we've been discussing.

The LTSSM is sitting in:

```text
Recovery.Speed
```

and generates:

```verilog
mac_tx_elecidle = 1;
mac_rx_standby  = 1;
```

When receiver standby is confirmed:

```text
RxStandbyStatus = 1
```

the LTSSM requests:

```verilog
mac_rate = GEN2;
```

Then your PIPE wrapper evaluates:

```verilog
rate_change_needed =
    (mac_rate != Rate);
```

and:

```verilog
start_rate_operation =
    (state == ST_IDLE) &&
    rate_change_needed &&
    rate_change_allowed;
```

then:

```verilog
Rate <= mac_rate;

active_operation <= OP_RATE;
state            <= ST_WAIT;
```

So the architectural flow is:

```text
LTSSM
Recovery.Speed
     │
     │ mac_rate = Gen2
     ▼
PIPE Wrapper
     │
     │ Rate = Gen2
     ▼
PHY
```

---

# PHY changes the actual clock

This is where the LTSSM temporarily stops being involved electrically.

The PHY performs something like:

```text
Rate = Gen2
    ↓
pause/gate PCLK if necessary
    ↓
reconfigure TX PLL
    ↓
change serializer frequency
    ↓
configure Gen2 TX characteristics
    ↓
configure RX/CDR operating range
    ↓
produce new PCLK
```

For your 8-bit PIPE:

```text
Gen1:
PCLK ≈ 250 MHz
serial = 2.5 GT/s

Gen2:
PCLK ≈ 500 MHz
serial = 5.0 GT/s
```

During the PCLK interruption:

```text
LTSSM state = Recovery.Speed
PIPE state  = ST_WAIT
```

Both simply retain their registers.

When the PHY completes the operation:

```text
PhyStatus = 1
```

Your wrapper produces:

```text
rate_done = 1
```

The LTSSM can now complete its `Recovery.Speed` operation.

---

# Recovery.Speed has deliberate idle time

The Gen2-era specification specifies a minimum Electrical Idle duration during the speed-transition process: for a successful speed negotiation, the transmitter remains in the required idle interval for at least 800 ns; the failure/fallback path uses a longer interval.

So our RTL should not interpret:

```text
rate_done
```

as necessarily meaning:

```text
immediately start TS1 this exact instant
```

The LTSSM must also satisfy the applicable `Recovery.Speed` timing/state conditions.

Conceptually:

```text
enter Recovery.Speed
        ↓
send EIOS
        ↓
Tx Electrical Idle
        ↓
wait for RX Electrical Idle
        ↓
perform rate switch
        ↓
satisfy required idle interval
        ↓
leave Recovery.Speed
```

---

# Recovery.Speed exits to RcvrLock

Once the speed-change sequence is complete:

```text
Recovery.Speed
        ↓
Recovery.RcvrLock
```

But something fundamental has changed.

Before:

```text
Recovery.RcvrLock
Rate = Gen1
2.5 GT/s
```

After:

```text
Recovery.RcvrLock
Rate = Gen2
5.0 GT/s
```

The spec explicitly describes `Recovery.Speed` returning to `Recovery.RcvrLock` after changing all configured lanes to the negotiated rate.

---

# 4. Recovery.RcvrLock — second visit

This second pass is extremely important.

The first `RcvrLock` said:

```text
"We can communicate at Gen1,
and we agree to try Gen2."
```

The second `RcvrLock` asks:

```text
"Can we actually communicate at Gen2?"
```

Now:

```text
PHY serial rate = 5 GT/s
PCLK             = 500 MHz
LTSSM             = Recovery.RcvrLock
```

The LTSSM again instructs:

```text
send TS1
```

So:

```text
Device A                              Device B

5 GT/s TS1 ------------------------->

                                       RX CDR acquisition
                                       ↓
                                       bit lock
                                       ↓
                                       symbol lock
                                       ↓
                                       8b/10b decode
                                       ↓
                                       TS1 recognized


                    <---------------- 5 GT/s TS1
```

This is the point where your earlier CDR question becomes important.

`Recovery.Speed` prepared the PHY for Gen2.

`Recovery.RcvrLock` proves that the remote 5-GT/s serial stream can actually be recovered.

---

# Why TS1 is so important here

The local TX PLL can lock internally without receiving anything.

But the receiver's CDR needs incoming transitions:

```text
Remote TX @ 5 GT/s
        ↓
our analog RX
        ↓
CDR
        ↓
recovered sampling clock
        ↓
10-bit symbols
        ↓
8b/10b decode
        ↓
TS1 detection
```

Therefore:

```text
PhyStatus
```

does not mean:

```text
remote link successfully trained
```

It only tells you:

```text
local PIPE rate-change operation completed
```

Then `Recovery.RcvrLock` validates the actual link at the new speed.

That distinction is fundamental to your architecture.

---

# What happens if Gen2 fails here?

Suppose Device B cannot lock at 5 GT/s:

```text
A → TS1 @ 5GT/s → B

B CDR fails
B never recognizes valid TS1
```

Eventually the Recovery logic detects that the new speed is not working.

The specification has a fallback mechanism using `Recovery.Speed` again.

Conceptually:

```text
Recovery.RcvrLock @ Gen2
        ↓
training fails
        ↓
Recovery.Speed
        ↓
Electrical Idle
        ↓
Rate back to old rate / Gen1
        ↓
Recovery.RcvrLock @ Gen1
```

The Gen2 spec specifically describes the case where a component cannot obtain Symbol lock after changing speed: both sides return through `Recovery.Speed` and revert to the speed used before the attempted change.

This is why a robust implementation needs something similar to:

```text
original_rate
target_rate
changed_speed_recovery
```

and not just a single `Rate` bit.

---

# 5. Recovery.RcvrCfg — second visit

Assume the Gen2 TS1 exchange succeeded.

Then:

```text
Recovery.RcvrLock @ 5GT/s
        ↓
Recovery.RcvrCfg @ 5GT/s
```

The transmitter now changes to:

```text
TS2 TS2 TS2 ...
```

at 5 GT/s.

But this time:

```text
speed_change = 0
```

because the speed change has already occurred.

So Device A and Device B are now effectively saying:

```text
"We are both operating at Gen2.
No additional speed change is requested.
Let's finish Recovery."
```

---

# RcvrCfg verifies final agreement

The receiver checks qualifying TS2 Ordered Sets with the proper:

```text
Link Number
Lane Number
Data Rate information
speed_change = 0
```

The Gen2 specification requires eight consecutive qualifying TS2s for the normal transition and also requires sufficient TS2 transmission after reception has begun; PCI-SIG's FAQ explicitly confirms the associated 16-TS2 transmission requirement for the transition to `Recovery.Idle`.

For your x1 link:

```text
rx_ts2_count

1
2
3
...
8
```

plus the transmit requirement.

Once those are satisfied:

```text
Recovery.RcvrCfg
        ↓
Recovery.Idle
```

---

# Lane-to-lane deskew also belongs here

For wider links, `Recovery.RcvrCfg` also ensures lane-to-lane deskew is complete before leaving.

The spec explicitly calls this out.

For your current:

```text
x1
```

implementation there is no lane-to-lane deskew problem.

That greatly simplifies your RTL.

---

# 6. Recovery.Idle

Now the link is essentially trained.

But PCIe does not jump directly:

```text
TS2 → L0
```

There is one last handshake.

`Recovery.Idle` sends:

```text
Logical Idle
```

This is very different from:

```text
Electrical Idle
```

Electrical Idle means:

```text
TX differential output is electrically idle
```

Logical Idle means:

```text
PHY is actively transmitting,
clock is running,
but Idle data symbols are being sent.
```

So:

```text
Recovery.Speed
        → Electrical Idle

Recovery.Idle
        → Logical Idle
```

Do not confuse these.

---

# Recovery.Idle confirms both ends are ready for normal data

Both sides transmit Idle data.

Conceptually:

```text
Device A                          Device B

Idle Idle Idle ----------------->

                    <------------ Idle Idle Idle
```

The Gen2 specification requires the expected received Idle interval and a transmit-side Idle requirement before entering `L0`. Specifically, it describes eight consecutive received Idle Symbol Times and 16 transmitted Idle symbols after reception begins.

Then:

```text
Recovery.Idle
        ↓
L0
```

Now normal:

```text
TLP
DLLP
SKP
```

traffic can resume.

---

# The entire Gen1 → Gen2 Recovery process

This is the complete flow I would use as the architectural reference for your RTL:

```text
========================================================
                  L0 @ GEN1 / 2.5 GT/s
========================================================

Normal TLP/DLLP traffic

              │
              │ directed speed change
              ▼

========================================================
                  Recovery.RcvrLock
                  OLD RATE = Gen1
========================================================

TX:
    TS1 TS1 TS1 TS1 ...

RX:
    obtain bit/CDR lock
    obtain symbol lock
    recognize TS1/TS2
    check Link/Lane number

Speed negotiation:
    speed_change = 1

Both sides agree that speed change is requested

              │
              ▼

========================================================
                  Recovery.RcvrCfg
                  OLD RATE = Gen1
========================================================

TX:
    TS2 TS2 TS2 ...

RX:
    validate TS2
    record remote supported rates

My support:
    Gen1 + Gen2

Remote support:
    Gen1 + Gen2

Highest common:
    Gen2

successful_speed_negotiation = 1

              │
              ▼

========================================================
                    Recovery.Speed
========================================================

TX:
    EIOS
      ↓
    Electrical Idle

RX:
    detect/infer Electrical Idle

Both directions idle

              │
              ▼

LTSSM:
    mac_rate = GEN2

              │
              ▼

PIPE:
    Rate = GEN2
    state = ST_WAIT

              │
              ▼

PHY:
    pause PCLK if needed
    change PLL
    change serializer
    configure Gen2 TX
    prepare Gen2 RX/CDR

              │
              ▼

PCLK:
    250 MHz → 500 MHz

              │
              ▼

PHY:
    PhyStatus

              │
              ▼

PIPE:
    rate_done

              │
              ▼

LTSSM:
    completes Recovery.Speed

              │
              ▼

========================================================
                  Recovery.RcvrLock
                  NEW RATE = Gen2
========================================================

TX:
    TS1 @ 5 GT/s

Remote PHY:
    CDR locks @ 5 GT/s

RX:
    detect valid TS1
    verify link works at Gen2

              │
              ▼

========================================================
                  Recovery.RcvrCfg
                  NEW RATE = Gen2
========================================================

TX:
    TS2 @ 5 GT/s
    speed_change = 0

RX:
    required valid TS2
    final link agreement

              │
              ▼

========================================================
                    Recovery.Idle
========================================================

TX:
    Logical Idle

RX:
    Logical Idle

Both sides ready

              │
              ▼

========================================================
                  L0 @ GEN2 / 5 GT/s
========================================================

Normal TLP/DLLP traffic resumes
```

The role division for your implementation should therefore be:

| Recovery stateLTSSM responsibilityMAC responsibilityPIPE responsibilityPHY responsibility |                                                         |                              |                                                          |                                      |
| ----------------------------------------------------------------------------------------- | ------------------------------------------------------- | ---------------------------- | -------------------------------------------------------- | ------------------------------------ |
| `RcvrLock`                                                                                | Count/validate training, manage `speed_change`          | Generate/detect TS1          | Normal symbol transport                                  | CDR, symbol recovery, SERDES         |
| `RcvrCfg`                                                                                 | Confirm remote parameters and decide Speed vs Idle      | Generate/detect TS2          | Normal symbol transport                                  | Continue physical receive/transmit   |
| `Speed`                                                                                   | Coordinate EIOS, idle, target rate, wait for completion | Generate EIOS                | `TxElecIdle`, `RxStandby`, `Rate`, `PhyStatus` handshake | Actually change PLL/PCLK/serial rate |
| `RcvrLock` second pass                                                                    | Verify new rate works                                   | TS1 at new rate              | Transport at new rate                                    | CDR locks to new-rate stream         |
| `RcvrCfg` second pass                                                                     | Final agreement                                         | TS2 at new rate              | Normal new-rate transport                                | Stable new-rate operation            |
| `Idle`                                                                                    | Confirm transition to operational state                 | Generate/detect Logical Idle | Normal datapath                                          | Continue active signaling            |
| `L0`                                                                                      | Operational link                                        | TLP/DLLP/OS traffic          | Normal PIPE transport                                    | Normal serial link                   |

The three Recovery variables are also worth implementing explicitly because they make the state machine much easier to understand:

```text
directed_speed_change

    "Do we currently want to perform a
     protocol-coordinated speed change?"


successful_speed_negotiation

    "Did both sides agree on a common
     target speed?"


changed_speed_recovery

    "Have we already physically changed speed
     during this Recovery attempt?"
```

Those three distinguish very different cases:

```text
normal Recovery
Gen1 → Gen2 attempt
successful Gen2 operation
failed Gen2 operation
fallback Gen2 → Gen1
```

And for our current Gen1/Gen2 project, you should **not implement** **`Recovery.Equalization`**. That substate appears in later PCIe generations for 8.0 GT/s and above. Modern specifications list:

```text
Recovery.RcvrLock
Recovery.Equalization
Recovery.Speed
Recovery.RcvrCfg
Recovery.Idle
```

but Gen1/Gen2 use 8b/10b operation and do not perform the Gen3-style Recovery.Equalization phases. ([Ziliaoku](https://www.ziliaoku.com/res/info_d767314ed36d4ac2ac8e6a172b6df99a.html?utm_source=chatgpt.com "PCI_Express_Base_4.0 PCIE 4.0 Specification 1.0 正式版文档.pdf-资料库"))

So for the RTL we are building, I would implement exactly these four LTSSM Recovery substates:

```verilog
RECOVERY_RCVRLOCK
RECOVERY_RCVRCFG
RECOVERY_SPEED
RECOVERY_IDLE
```

with `RECOVERY_SPEED` directly controlling the `mac_rate`, `mac_tx_elecidle`, `mac_rx_standby`, and `rate_done` handshake we already implemented in the PIPE wrapper.
