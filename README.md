# PCIe Gen1/Gen2 PIPE control: course specification and reading guide

This course builds a **single-lane, 8-bit, Gen1/Gen2 controller-side PIPE wrapper**. The MAC and LTSSM request operations; the wrapper qualifies and serializes those requests; the PHY performs the electrical work and reports status. The final exercise connects the power, electrical-idle, rate-change, receiver-detection, and loopback logic into one controller.

This README is the entry point for the chapter files listed below. It specifies the behavior to explain and test in each section. It describes the supplied `pcie_pipe_mac_if_v3` teaching implementation; it is **not** a claim that the wrapper implements every requirement of a current PIPE or PCIe Base specification. Where a protocol requirement and the supplied RTL differ, the difference is called out explicitly.

## Scope and prerequisites

| Item | Course scope |
|---|---|
| Link | One PCIe lane; Gen1 at 2.5 GT/s and Gen2 at 5.0 GT/s |
| PIPE data path | One 8-bit character plus `DataK` per PCLK on TX and RX |
| PHY power commands | P0, P0s, P1; P2 is recognized as an encoding but rejected by this RTL |
| Clock/reset | PHY-provided `pclk`; active-low `reset_n` forwarded as `pipe_reset_n` |
| Demonstrated operations | Power transitions, TX/RX electrical idle, rate changes, TX controls, receiver detection, loopback, shared completion arbitration |
| Assumed external logic | LTSSM, EIOS/TS1/TS2 generation and recognition, scrambler/descrambler, 8b/10b PHY, SerDes and analog receiver detection |
| Outside this course | Gen3+, multiple lanes, P2/beacon, dynamic width changes, complete TLP/DLLP processing, complete PCIe link compliance |

Students should know basic Verilog, synchronous state machines, and the names of the main PCIe LTSSM states. No analog PHY design is required.

## Reading order and section contracts

| Order | Chapter file | What the reader should be able to explain or build |
|---|---|---|
| 0 | `Recovery State in LTSSM.md` | Why TS1/TS2 training, electrical idle, and PHY rate completion are separate events |
| 1 | `Section 1 Position of PIPE in PCIe.md` | MAC–PIPE–PHY boundary and ownership of each operation |
| 2 | `Section 2 Power Down Mode Configuration.md` | Allowed P0/P0s/P1 transitions, launch conditions, and `PhyStatus` acknowledgment |
| 3 | `Section 3 Transmitter and Receiver IDLE.md` | `TxElecIdle` command, `RxElecIdle` indication, and their RTL treatment |
| 4A | `Section 4_1 Rate-Change.md` | Gen1/Gen2 `Rate` request, standby condition, completion, and Recovery handoff |
| 4B | `Section 4_2 Tx De-emphasis, Margin and Swing.md` | Selection and update rules for the three TX electrical controls |
| 5 | `Section 5 Receiver detection.md` | Pending request, P1 detection handshake, `RxStatus` result, cancellation |
| 6 | `Section 6 Loopback Mode.md` | LTSSM request versus local PHY loopback, and shared `TxDetectRx` ownership |
| 7 | `Section 7 PIPE pins.md` | Signal widths, directions, meanings, and integration wiring |

The order is for **reading**. Verilog clocked blocks run concurrently and sample pre-edge values; writing a section later in the source does not make it execute later in hardware.

## Common behavioral contract

The wrapper has one shared controller with `ST_RESET`, `ST_IDLE`, `ST_WAIT`, and `ST_FAULT`. Its `active_operation` distinguishes `OP_POWER`, `OP_RATE`, and `OP_DETECT` while the controller waits for the shared `PhyStatus`. `PowerDown` is a separate registered **PHY command**, not a controller state.

The arbiter launches at most one acknowledged operation. Among **eligible** requests, priority is rate change, then power change, then receiver detection. A blocked rate request does not prevent an otherwise legal power request. A launched operation holds the controller in `ST_WAIT` until `PhyStatus` or timeout. The matching `power_done`, `rate_done`, or `detect_done` pulses for one PCLK after acknowledgment. `PhyStatus` reports completion of a local PHY operation; it does not prove that TS1/TS2 link training succeeded.

The timeout counts **PCLK edges**, not elapsed wall time. If PCLK stops, the counter cannot advance. A simultaneous `PhyStatus` and timeout threshold is treated as successful acknowledgment. Timeout sets sticky `phy_timeout` and enters reset-only `ST_FAULT`. Startup in this implementation leaves `ST_RESET` on a sampled low `PhyStatus`; it has no separate startup timeout.

### Reset values in the teaching RTL

| Signal | Reset value | Meaning |
|---|---:|---|
| `PowerDown` | `2'b10` | P1 |
| `Rate` | `1'b0` | Gen1 |
| `TxElecIdle` | `1'b1` | TX electrically idle |
| `TxDetectRx` | `1'b0` | Neither detect nor loopback requested |
| `RxStandby` | `1'b0` | Standby not requested |
| `TxDeemph` | `1'b1` | Gen1 selection |
| `TxMargin`, `TxSwing` | zero | Default controls |
| `mac_rx_elecidle` | `1'b1` | RX assumed idle until qualified otherwise |

## Recovery State in LTSSM

The LTSSM chooses the link state and interprets received ordered sets. PIPE conveys commands to the PHY and returns local status. The course's rate-change example follows:

1. `Recovery.RcvrLock`: transmit TS1 and establish receive character/symbol lock.
2. `Recovery.RcvrCfg`: exchange TS2 and determine whether to change speed.
3. `Recovery.Speed`: finish the required EIOS transmission, assert `TxElecIdle`, arrange receiver standby, request the new `Rate`, and wait for local PHY completion.
4. Return to `Recovery.RcvrLock` at the new rate, exchange TS1/TS2 again, then proceed through `Recovery.Idle` to L0 when the LTSSM conditions are met.

An ordered set is data sent through `TxData/TxDataK`. `TxElecIdle` is the separate PHY command to stop electrical transmission. `RxElecIdle` is a PHY indication and does not itself replace received ordered-set qualification. `rate_done` is not an LTSSM exit condition on its own.

## Section 1 — Position of PIPE in PCIe

**Architecture:** Transaction and Data Link logic supply packets; logical MAC/Physical Layer logic selects packets and ordered sets, handles LTSSM decisions, and prepares the character stream. The controller-side PIPE wrapper forwards that stream and controls the PHY. The external PHY performs 8b/10b coding, clock recovery, serialization, electrical idle detection, and analog receiver detection for this course partition.

**TX:** `mac_tx_data[7:0]` and `mac_tx_datak` become `TxData[7:0]` and `TxDataK` when active; they are registered as zero during effective TX idle. **RX:** `RxData`, `RxDataK`, `RxValid`, and `RxStatus` are forwarded to the MAC; decoded status flags are separately qualified. The wrapper neither generates TLPs nor implements a SerDes.

**Check:** Given an LTSSM action, identify whether the LTSSM, the PIPE controller, or the PHY initiates it, performs it, and recognizes its completion.

## Section 2 — Power Down Mode Configuration

| Current | Requested | Supported by this RTL? | Preparation |
|---|---|---|---|
| P0 | P0s | Yes | Registered `TxElecIdle=1` |
| P0s | P0 | Yes | No TX-idle prerequisite in this wrapper |
| P0 | P1 | Yes | Registered `TxElecIdle=1` |
| P1 | P0 | Yes | No TX-idle prerequisite in this wrapper |
| P0s | P1 | No | Request P0 first |
| P1 | P0s | No | Request P0 first |
| Any | P2, or P2 | any | No | Outside the supplied wrapper |

The request is `mac_powerdown[1:0]`; `PowerDown[1:0]` is the command to the PHY. The wrapper starts a legal change only while idle, with loopback inactive and TX already idle when entering P0s/P1. `PowerDown` changes on the **launch** edge; `power_done` follows only after `PhyStatus`. A requested destination matching the current command needs no operation. A blocked request reports an illegal transition, loopback conflict, or TX-not-idle reason.

**LTSSM mapping:** P0 is used for active training/traffic; P0s is associated with the transmitter's L0s idle behavior; P1 is used when the relevant channels are idle, including Detect and L1.Idle use cases. P2 exists in PIPE but is not implemented because it can stop PCLK and needs a different control strategy. The chapter should distinguish link states such as L0s/L1 from the PHY's P0s/P1 commands.

**Check:** Exercise every permitted edge, both direct P0s↔P1 rejections, P2 rejection, TX-not-idle blocking, and the difference between command launch and `power_done`. Check that another operation cannot consume the shared `PhyStatus` during a power transition.

## Section 3 — Transmitter and Receiver IDLE

**TX behavior:** `effective_tx_idle = mac_tx_elecidle || !phy_initialized || (PowerDown != P0) || phy_busy`, where `phy_busy` covers operation launch and wait. The registered `TxElecIdle` drives the PHY. While effective idle is true, `TxData=0`, `TxDataK=0`, and `TxCompliance=0`. When active in P0, data and `DataK` follow the MAC stream. A transmitter sends EIOS as characters **before** asserting electrical idle for an applicable LTSSM sequence.

**RX behavior:** `RxElecIdle` comes from the PHY and is treated as asynchronous to PCLK in this RTL. Two registers synchronize it, then a consecutive-sample filter updates `mac_rx_elecidle`. The default `RX_EI_FILTER_CYCLES=32`; zero bypasses the filter but retains the two-stage synchronizer. The counter is eight bits, so the intended filter range is 0–255. `mac_rx_elecidle` is an indication, not a new command to the PHY.

**Check:** Verify the EIOS-to-idle ordering at the LTSSM boundary, forced idle during reset/transition/non-P0 states, return to data after P0, and filter response to a brief RX idle glitch versus a stable indication. Do not treat RX electrical idle alone as proof of Gen2 link state or successful training.

## Section 4_1 — Gen1/Gen2 Rate Change

`mac_rate=0` requests Gen1; `mac_rate=1` requests Gen2. A differing `mac_rate` and registered `Rate` forms a level-sensitive pending request. In the supplied wrapper, launch requires:

- `PowerDown` at P0 or P1;
- registered `TxElecIdle=1`;
- loopback inactive;
- **in P0**, registered `RxStandby=1` and PHY `RxStandbyStatus=1`.

`mac_rx_standby` is registered into `RxStandby` in idle controller cycles when no operation launches. It is not raised automatically by a rate request. At launch, `Rate` changes and the controller waits for `PhyStatus`; acknowledgment pulses `rate_done`. Keep TX idle and the relevant standby state through completion. A new rate command while waiting must not start another operation. The LTSSM then trains at the new rate; the local rate acknowledgment alone is not link recovery.

**Important spec/RTL distinction:** The archived Intel PIPE description states that `TxElecIdle` **and `RxStandby`** are asserted for a P0 **or P1** rate change. The supplied wrapper checks RX standby only in P0. Treat its P1 shortcut as an implementation assumption to review against the target PHY, not a general PIPE rule.

**Check:** P0 request blocked without standby acknowledgment, P0 request launched after it, P1 request as implemented, P0s request rejected, `Rate` launch versus `rate_done`, and a timeout. A PHY model should delay its `PhyStatus` so students can observe the wait state.

## Section 4_2 — TX de-emphasis, margin, and swing

`TxDeemph` selects the Gen2 de-emphasis setting from `mac_tx_deemph` while TX is idle. This wrapper forces `TxDeemph=1` at Gen1; at a rate-launch edge it selects using the **requested** `mac_rate`, and on other idle edges it selects using the current `Rate`. For the implementation's signal convention, `0` corresponds to −6 dB and `1` to −3.5 dB in Gen2. This is a digital PHY control, not a voltage generator in the wrapper.

`TxMargin[2:0]` and `TxSwing` follow their MAC inputs only on edges where the registered `TxElecIdle` is high. The external PHY translates them into electrical behavior. Valid combinations and analog timing come from the selected PIPE/Base specification and PHY data sheet; this RTL does not verify every electrical setting or measure the pin waveform.

**Check:** Gen1 forces the defined `TxDeemph` selection, Gen2 accepts the MAC selection, rate launch uses the requested rate, and margin/swing registers hold while TX is active.

## Section 5 — Receiver detection

Detection belongs to LTSSM `Detect.Active`; the wrapper does not move itself to P1. The LTSSM asserts `mac_detect_req` and keeps it high until `detect_done`. A rising edge arms `detect_pending`. Launch is allowed in P1 with registered `TxElecIdle=1`, loopback inactive, and no higher-priority eligible operation. A withdrawn request before launch is canceled; a one-cycle pulse while busy is not retained for later execution. Once launched, withdrawal does not cancel the PHY operation.

The shared owner asserts `TxDetectRx` and holds it until the PHY asserts `PhyStatus` or the operation times out. On acknowledgment, it samples `RxStatus`; `3'b011` means a receiver is present, and `3'b000` means absent. The supplied RTL treats every other code as a false `detect_rx_present` result rather than separately reporting an invalid detection response. `detect_done` pulses once, while `detect_rx_present` retains the last result until another completed detection or reset. `TxDetectRx` is cleared at completion.

**Check:** Present/absent results, blocked request outside P1, blocked request without TX idle, cancellation before launch, holding `TxDetectRx` through a delayed acknowledgment, and timeout. Do not decode `RxStatus=011` as ordinary RX data status during a detection operation.

## Section 6 — Loopback Mode

The LTSSM decides when loopback is requested. In the teaching flow, the initiating side transmits TS1 with the Loopback indication; the responding side recognizes it and requests local PHY loopback through `mac_loopback`. The PIPE wrapper does not parse TS1 or decide the LTSSM Loopback.Entry/Active/Exit transitions.

The local request is qualified by controller idle, no acknowledged operation launching, `mac_loopback=1`, `PowerDown=P0`, and current `mac_tx_elecidle=0`. The shared `TxDetectRx` register requests PHY loopback in **P0 with active transmission**. `loopback_mode` records its ownership; `mac_loopback_active = loopback_mode && !TxElecIdle` is a local indication, not a separately acknowledged PHY status. Loopback has no `OP_LOOPBACK`, `ST_WAIT`, `PhyStatus` completion, or `loopback_done` pulse in this RTL. Raising `mac_tx_elecidle` removes the request on the next PCLK edge.

`TxDetectRx` also requests receiver detection in P1. The two independent teaching modules cannot each drive a common integrated `TxDetectRx` wire. The integrated wrapper has **one clocked owner** that arbitrates detection and loopback; verify that P0 active loopback and P1 idle detection never overlap.

**Check:** Valid P0 entry, rejection in P1 and while TX idle, exit on MAC idle request, no false `PhyStatus` requirement, and detection/loopback ownership.

## Section 7 — PIPE pins and integration

Directions below are relative to the controller-side wrapper. Signal names match `pcie_pipe_mac_if_v3`.

### Key control combinations

| `PowerDown` | `TxDetectRx` | `TxElecIdle` | Intended action in this course |
|---|---:|---:|---|
| P0 (`00`) | 0 | 0 | Normal transmission |
| P0 (`00`) | 0 | 1 | TX electrical idle |
| P0 (`00`) | 1 | 0 | PHY loopback |
| P1 (`10`) | 0 | 1 | Low-power idle |
| P1 (`10`) | 1 | 1 | Receiver detection |
| P0s (`01`) | — | 1 | TX idle in P0s |

P0 with both `TxDetectRx` and `TxElecIdle` high is an illegal combination in the archived PIPE control decode. The wrapper's single ownership block must prevent detection and loopback from issuing conflicting commands.

### `RxStatus` encodings used by the wrapper

| Code | Meaning in the normal RX path | Detection use |
|---|---|---|
| `000` | No special status | Receiver absent at detection completion |
| `001` | SKP added | — |
| `010` | SKP removed | — |
| `011` | Reserved for detect result in this context | Receiver present at detection completion |
| `100` | 8b/10b decode error | — |
| `101` | Elastic-buffer overflow | — |
| `110` | Elastic-buffer underflow | — |
| `111` | Disparity error | — |

The wrapper qualifies normal RX error/SKP flags using initialization, `RxValid`, P0/P0s, and absence of an active detection operation. Raw `RxStatus` is still forwarded to the MAC.

| Interface | MAC/PHY signal | Direction | Course meaning |
|---|---|---|---|
| Clock/reset | `pclk`, `reset_n` | Inputs | PHY parallel clock; wrapper active-low reset |
| Reset | `pipe_reset_n` | To PHY | Forwarded PHY reset |
| Data | `mac_tx_data[7:0]`, `mac_tx_datak` | From MAC | Prepared TX byte and K indicator |
| Data | `TxData[7:0]`, `TxDataK` | To PHY | Registered TX byte and K indicator |
| Data | `RxData[7:0]`, `RxDataK`, `RxValid` | From PHY | Recovered byte, K indicator, validity |
| Data | `mac_rx_data[7:0]`, `mac_rx_datak`, `mac_rx_valid` | To MAC | RX information forwarded from PHY |
| Idle | `mac_tx_elecidle`, `TxElecIdle` | From MAC / to PHY | Requested/registered TX electrical idle |
| Idle | `RxElecIdle`, `mac_rx_elecidle` | From PHY / to MAC | Raw and filtered RX idle indications |
| Power | `mac_powerdown[1:0]`, `PowerDown[1:0]` | From MAC / to PHY | Desired and commanded PHY power state |
| Rate | `mac_rate`, `Rate` | From MAC / to PHY | Desired and commanded Gen1/Gen2 rate |
| Standby | `mac_rx_standby`, `RxStandby`, `RxStandbyStatus` | MAC / PHY / PHY | RX standby request, command, acknowledgment |
| Detect | `mac_detect_req`, `TxDetectRx` | From MAC / to PHY | Detect request and shared detect/loopback command |
| Loopback | `mac_loopback`, `mac_loopback_active` | From MAC / to MAC | Local loopback request and indication |
| TX electrical | `mac_tx_deemph`, `TxDeemph`, `mac_tx_margin[2:0]`, `TxMargin[2:0]`, `mac_tx_swing`, `TxSwing` | MAC / PHY | Selected PHY TX controls |
| Other control | `mac_tx_compliance`, `TxCompliance`, `mac_rx_polarity`, `RxPolarity` | MAC / PHY | Compliance and polarity commands |
| Status | `PhyStatus`, `RxStatus[2:0]` | From PHY | Operation completion and RX/detect status |
| Status | `power_done`, `rate_done`, `detect_done`, `detect_rx_present` | To MAC | One-cycle completions and held detect result |
| Diagnostics | `phy_busy`, `phy_initialized`, `phy_timeout`, `request_blocked`, `request_blocked_reason[2:0]` | To MAC | Controller health and blocked requests |

The integrated wrapper must keep **one operation arbiter**, **one wait-state owner of `PhyStatus`**, and **one writer of `TxDetectRx`**. The extracted power, idle, rate, detection, and loopback modules are teaching views of those responsibilities; directly tying their independent output registers together would create multiple drivers and lose arbitration. The final integration exercise should reconcile their interfaces with the shared controller in `pcie_pipe_mac_if_v3.v`.

### Suggested end-to-end checks

1. Reset in P1/Gen1, wait for initialization, then request P0 and confirm `power_done` follows `PhyStatus`.
2. Send EIOS before asserting TX idle; transition P0→P0s→P0 and P0→P1→P0.
3. In P0, request standby, wait for `RxStandbyStatus`, change Gen1→Gen2, then resume TS1/TS2 training.
4. In P1, request detection and test both present and absent results.
5. In P0 with TX active, enter/exit local loopback; ensure a detect request cannot take over `TxDetectRx`.
6. Test a delayed or missing `PhyStatus`, arbitration priority, blocked-reason reporting, and reset recovery from timeout.

## References and interpretation

- Intel, [PHY Interface for the PCI Express Architecture, archived revision 3.0 draft 0.9](https://www.intel.in/content/dam/doc/white-paper/phy-interface-pci-express-sata3-specification-v09.pdf), especially the PHY/MAC interface, power management, rate change, receiver detection, loopback, and control decode sections. It is an archived reference suitable for studying legacy Gen1/Gen2 signals, not the current normative revision.
- Intel, [PIPE specification overview](https://www.intel.com/content/www/us/en/io/pci-express/phy-interface-pci-express-sata-usb30-architectures-3-1.html). PIPE defines the MAC–PHY interface; the PCIe Base specification takes precedence where requirements conflict.
- PCI-SIG, [PCI Express Base specification overview](https://pcisig.com/specification-overview/pci-express-base), for link and LTSSM requirements.

This README was prepared from the displayed chapter filenames and the supplied `pcie_pipe_mac_if_v3` implementation. The chapter bodies themselves were not attached with the screenshot. Align their detailed prose and examples with this index before publishing the complete course package.
# PCIe Gen1/Gen2 PIPE control: course specification and reading guide

This course builds a **single-lane, 8-bit, Gen1/Gen2 controller-side PIPE wrapper**. The MAC and LTSSM request operations; the wrapper qualifies and serializes those requests; the PHY performs the electrical work and reports status. The final exercise connects the power, electrical-idle, rate-change, receiver-detection, and loopback logic into one controller.

This README is the entry point for the chapter files listed below. It specifies the behavior to explain and test in each section. It describes the supplied `pcie_pipe_mac_if_v3` teaching implementation; it is **not** a claim that the wrapper implements every requirement of a current PIPE or PCIe Base specification. Where a protocol requirement and the supplied RTL differ, the difference is called out explicitly.

## Scope and prerequisites

| Item | Course scope |
|---|---|
| Link | One PCIe lane; Gen1 at 2.5 GT/s and Gen2 at 5.0 GT/s |
| PIPE data path | One 8-bit character plus `DataK` per PCLK on TX and RX |
| PHY power commands | P0, P0s, P1; P2 is recognized as an encoding but rejected by this RTL |
| Clock/reset | PHY-provided `pclk`; active-low `reset_n` forwarded as `pipe_reset_n` |
| Demonstrated operations | Power transitions, TX/RX electrical idle, rate changes, TX controls, receiver detection, loopback, shared completion arbitration |
| Assumed external logic | LTSSM, EIOS/TS1/TS2 generation and recognition, scrambler/descrambler, 8b/10b PHY, SerDes and analog receiver detection |
| Outside this course | Gen3+, multiple lanes, P2/beacon, dynamic width changes, complete TLP/DLLP processing, complete PCIe link compliance |

Students should know basic Verilog, synchronous state machines, and the names of the main PCIe LTSSM states. No analog PHY design is required.

## Reading order and section contracts

| Order | Chapter file | What the reader should be able to explain or build |
|---|---|---|
| 0 | `Recovery State in LTSSM.md` | Why TS1/TS2 training, electrical idle, and PHY rate completion are separate events |
| 1 | `Section 1 Position of PIPE in PCIe.md` | MAC–PIPE–PHY boundary and ownership of each operation |
| 2 | `Section 2 Power Down Mode Configuration.md` | Allowed P0/P0s/P1 transitions, launch conditions, and `PhyStatus` acknowledgment |
| 3 | `Section 3 Transmitter and Receiver IDLE.md` | `TxElecIdle` command, `RxElecIdle` indication, and their RTL treatment |
| 4A | `Section 4_1 Rate-Change.md` | Gen1/Gen2 `Rate` request, standby condition, completion, and Recovery handoff |
| 4B | `Section 4_2 Tx De-emphasis, Margin and Swing.md` | Selection and update rules for the three TX electrical controls |
| 5 | `Section 5 Receiver detection.md` | Pending request, P1 detection handshake, `RxStatus` result, cancellation |
| 6 | `Section 6 Loopback Mode.md` | LTSSM request versus local PHY loopback, and shared `TxDetectRx` ownership |
| 7 | `Section 7 PIPE pins.md` | Signal widths, directions, meanings, and integration wiring |

The order is for **reading**. Verilog clocked blocks run concurrently and sample pre-edge values; writing a section later in the source does not make it execute later in hardware.

## Common behavioral contract

The wrapper has one shared controller with `ST_RESET`, `ST_IDLE`, `ST_WAIT`, and `ST_FAULT`. Its `active_operation` distinguishes `OP_POWER`, `OP_RATE`, and `OP_DETECT` while the controller waits for the shared `PhyStatus`. `PowerDown` is a separate registered **PHY command**, not a controller state.

The arbiter launches at most one acknowledged operation. Among **eligible** requests, priority is rate change, then power change, then receiver detection. A blocked rate request does not prevent an otherwise legal power request. A launched operation holds the controller in `ST_WAIT` until `PhyStatus` or timeout. The matching `power_done`, `rate_done`, or `detect_done` pulses for one PCLK after acknowledgment. `PhyStatus` reports completion of a local PHY operation; it does not prove that TS1/TS2 link training succeeded.

The timeout counts **PCLK edges**, not elapsed wall time. If PCLK stops, the counter cannot advance. A simultaneous `PhyStatus` and timeout threshold is treated as successful acknowledgment. Timeout sets sticky `phy_timeout` and enters reset-only `ST_FAULT`. Startup in this implementation leaves `ST_RESET` on a sampled low `PhyStatus`; it has no separate startup timeout.

### Reset values in the teaching RTL

| Signal | Reset value | Meaning |
|---|---:|---|
| `PowerDown` | `2'b10` | P1 |
| `Rate` | `1'b0` | Gen1 |
| `TxElecIdle` | `1'b1` | TX electrically idle |
| `TxDetectRx` | `1'b0` | Neither detect nor loopback requested |
| `RxStandby` | `1'b0` | Standby not requested |
| `TxDeemph` | `1'b1` | Gen1 selection |
| `TxMargin`, `TxSwing` | zero | Default controls |
| `mac_rx_elecidle` | `1'b1` | RX assumed idle until qualified otherwise |

## Recovery State in LTSSM

The LTSSM chooses the link state and interprets received ordered sets. PIPE conveys commands to the PHY and returns local status. The course's rate-change example follows:

1. `Recovery.RcvrLock`: transmit TS1 and establish receive character/symbol lock.
2. `Recovery.RcvrCfg`: exchange TS2 and determine whether to change speed.
3. `Recovery.Speed`: finish the required EIOS transmission, assert `TxElecIdle`, arrange receiver standby, request the new `Rate`, and wait for local PHY completion.
4. Return to `Recovery.RcvrLock` at the new rate, exchange TS1/TS2 again, then proceed through `Recovery.Idle` to L0 when the LTSSM conditions are met.

An ordered set is data sent through `TxData/TxDataK`. `TxElecIdle` is the separate PHY command to stop electrical transmission. `RxElecIdle` is a PHY indication and does not itself replace received ordered-set qualification. `rate_done` is not an LTSSM exit condition on its own.

## Section 1 — Position of PIPE in PCIe

**Architecture:** Transaction and Data Link logic supply packets; logical MAC/Physical Layer logic selects packets and ordered sets, handles LTSSM decisions, and prepares the character stream. The controller-side PIPE wrapper forwards that stream and controls the PHY. The external PHY performs 8b/10b coding, clock recovery, serialization, electrical idle detection, and analog receiver detection for this course partition.

**TX:** `mac_tx_data[7:0]` and `mac_tx_datak` become `TxData[7:0]` and `TxDataK` when active; they are registered as zero during effective TX idle. **RX:** `RxData`, `RxDataK`, `RxValid`, and `RxStatus` are forwarded to the MAC; decoded status flags are separately qualified. The wrapper neither generates TLPs nor implements a SerDes.

**Check:** Given an LTSSM action, identify whether the LTSSM, the PIPE controller, or the PHY initiates it, performs it, and recognizes its completion.

## Section 2 — Power Down Mode Configuration

| Current | Requested | Supported by this RTL? | Preparation |
|---|---|---|---|
| P0 | P0s | Yes | Registered `TxElecIdle=1` |
| P0s | P0 | Yes | No TX-idle prerequisite in this wrapper |
| P0 | P1 | Yes | Registered `TxElecIdle=1` |
| P1 | P0 | Yes | No TX-idle prerequisite in this wrapper |
| P0s | P1 | No | Request P0 first |
| P1 | P0s | No | Request P0 first |
| Any | P2, or P2 | any | No | Outside the supplied wrapper |

The request is `mac_powerdown[1:0]`; `PowerDown[1:0]` is the command to the PHY. The wrapper starts a legal change only while idle, with loopback inactive and TX already idle when entering P0s/P1. `PowerDown` changes on the **launch** edge; `power_done` follows only after `PhyStatus`. A requested destination matching the current command needs no operation. A blocked request reports an illegal transition, loopback conflict, or TX-not-idle reason.

**LTSSM mapping:** P0 is used for active training/traffic; P0s is associated with the transmitter's L0s idle behavior; P1 is used when the relevant channels are idle, including Detect and L1.Idle use cases. P2 exists in PIPE but is not implemented because it can stop PCLK and needs a different control strategy. The chapter should distinguish link states such as L0s/L1 from the PHY's P0s/P1 commands.

**Check:** Exercise every permitted edge, both direct P0s↔P1 rejections, P2 rejection, TX-not-idle blocking, and the difference between command launch and `power_done`. Check that another operation cannot consume the shared `PhyStatus` during a power transition.

## Section 3 — Transmitter and Receiver IDLE

**TX behavior:** `effective_tx_idle = mac_tx_elecidle || !phy_initialized || (PowerDown != P0) || phy_busy`, where `phy_busy` covers operation launch and wait. The registered `TxElecIdle` drives the PHY. While effective idle is true, `TxData=0`, `TxDataK=0`, and `TxCompliance=0`. When active in P0, data and `DataK` follow the MAC stream. A transmitter sends EIOS as characters **before** asserting electrical idle for an applicable LTSSM sequence.

**RX behavior:** `RxElecIdle` comes from the PHY and is treated as asynchronous to PCLK in this RTL. Two registers synchronize it, then a consecutive-sample filter updates `mac_rx_elecidle`. The default `RX_EI_FILTER_CYCLES=32`; zero bypasses the filter but retains the two-stage synchronizer. The counter is eight bits, so the intended filter range is 0–255. `mac_rx_elecidle` is an indication, not a new command to the PHY.

**Check:** Verify the EIOS-to-idle ordering at the LTSSM boundary, forced idle during reset/transition/non-P0 states, return to data after P0, and filter response to a brief RX idle glitch versus a stable indication. Do not treat RX electrical idle alone as proof of Gen2 link state or successful training.

## Section 4_1 — Gen1/Gen2 Rate Change

`mac_rate=0` requests Gen1; `mac_rate=1` requests Gen2. A differing `mac_rate` and registered `Rate` forms a level-sensitive pending request. In the supplied wrapper, launch requires:

- `PowerDown` at P0 or P1;
- registered `TxElecIdle=1`;
- loopback inactive;
- **in P0**, registered `RxStandby=1` and PHY `RxStandbyStatus=1`.

`mac_rx_standby` is registered into `RxStandby` in idle controller cycles when no operation launches. It is not raised automatically by a rate request. At launch, `Rate` changes and the controller waits for `PhyStatus`; acknowledgment pulses `rate_done`. Keep TX idle and the relevant standby state through completion. A new rate command while waiting must not start another operation. The LTSSM then trains at the new rate; the local rate acknowledgment alone is not link recovery.

**Important spec/RTL distinction:** The archived Intel PIPE description states that `TxElecIdle` **and `RxStandby`** are asserted for a P0 **or P1** rate change. The supplied wrapper checks RX standby only in P0. Treat its P1 shortcut as an implementation assumption to review against the target PHY, not a general PIPE rule.

**Check:** P0 request blocked without standby acknowledgment, P0 request launched after it, P1 request as implemented, P0s request rejected, `Rate` launch versus `rate_done`, and a timeout. A PHY model should delay its `PhyStatus` so students can observe the wait state.

## Section 4_2 — TX de-emphasis, margin, and swing

`TxDeemph` selects the Gen2 de-emphasis setting from `mac_tx_deemph` while TX is idle. This wrapper forces `TxDeemph=1` at Gen1; at a rate-launch edge it selects using the **requested** `mac_rate`, and on other idle edges it selects using the current `Rate`. For the implementation's signal convention, `0` corresponds to −6 dB and `1` to −3.5 dB in Gen2. This is a digital PHY control, not a voltage generator in the wrapper.

`TxMargin[2:0]` and `TxSwing` follow their MAC inputs only on edges where the registered `TxElecIdle` is high. The external PHY translates them into electrical behavior. Valid combinations and analog timing come from the selected PIPE/Base specification and PHY data sheet; this RTL does not verify every electrical setting or measure the pin waveform.

**Check:** Gen1 forces the defined `TxDeemph` selection, Gen2 accepts the MAC selection, rate launch uses the requested rate, and margin/swing registers hold while TX is active.

## Section 5 — Receiver detection

Detection belongs to LTSSM `Detect.Active`; the wrapper does not move itself to P1. The LTSSM asserts `mac_detect_req` and keeps it high until `detect_done`. A rising edge arms `detect_pending`. Launch is allowed in P1 with registered `TxElecIdle=1`, loopback inactive, and no higher-priority eligible operation. A withdrawn request before launch is canceled; a one-cycle pulse while busy is not retained for later execution. Once launched, withdrawal does not cancel the PHY operation.

The shared owner asserts `TxDetectRx` and holds it until the PHY asserts `PhyStatus` or the operation times out. On acknowledgment, it samples `RxStatus`; `3'b011` means a receiver is present, and `3'b000` means absent. The supplied RTL treats every other code as a false `detect_rx_present` result rather than separately reporting an invalid detection response. `detect_done` pulses once, while `detect_rx_present` retains the last result until another completed detection or reset. `TxDetectRx` is cleared at completion.

**Check:** Present/absent results, blocked request outside P1, blocked request without TX idle, cancellation before launch, holding `TxDetectRx` through a delayed acknowledgment, and timeout. Do not decode `RxStatus=011` as ordinary RX data status during a detection operation.

## Section 6 — Loopback Mode

The LTSSM decides when loopback is requested. In the teaching flow, the initiating side transmits TS1 with the Loopback indication; the responding side recognizes it and requests local PHY loopback through `mac_loopback`. The PIPE wrapper does not parse TS1 or decide the LTSSM Loopback.Entry/Active/Exit transitions.

The local request is qualified by controller idle, no acknowledged operation launching, `mac_loopback=1`, `PowerDown=P0`, and current `mac_tx_elecidle=0`. The shared `TxDetectRx` register requests PHY loopback in **P0 with active transmission**. `loopback_mode` records its ownership; `mac_loopback_active = loopback_mode && !TxElecIdle` is a local indication, not a separately acknowledged PHY status. Loopback has no `OP_LOOPBACK`, `ST_WAIT`, `PhyStatus` completion, or `loopback_done` pulse in this RTL. Raising `mac_tx_elecidle` removes the request on the next PCLK edge.

`TxDetectRx` also requests receiver detection in P1. The two independent teaching modules cannot each drive a common integrated `TxDetectRx` wire. The integrated wrapper has **one clocked owner** that arbitrates detection and loopback; verify that P0 active loopback and P1 idle detection never overlap.

**Check:** Valid P0 entry, rejection in P1 and while TX idle, exit on MAC idle request, no false `PhyStatus` requirement, and detection/loopback ownership.

## Section 7 — PIPE pins and integration

Directions below are relative to the controller-side wrapper. Signal names match `pcie_pipe_mac_if_v3`.

### Key control combinations

| `PowerDown` | `TxDetectRx` | `TxElecIdle` | Intended action in this course |
|---|---:|---:|---|
| P0 (`00`) | 0 | 0 | Normal transmission |
| P0 (`00`) | 0 | 1 | TX electrical idle |
| P0 (`00`) | 1 | 0 | PHY loopback |
| P1 (`10`) | 0 | 1 | Low-power idle |
| P1 (`10`) | 1 | 1 | Receiver detection |
| P0s (`01`) | — | 1 | TX idle in P0s |

P0 with both `TxDetectRx` and `TxElecIdle` high is an illegal combination in the archived PIPE control decode. The wrapper's single ownership block must prevent detection and loopback from issuing conflicting commands.

### `RxStatus` encodings used by the wrapper

| Code | Meaning in the normal RX path | Detection use |
|---|---|---|
| `000` | No special status | Receiver absent at detection completion |
| `001` | SKP added | — |
| `010` | SKP removed | — |
| `011` | Reserved for detect result in this context | Receiver present at detection completion |
| `100` | 8b/10b decode error | — |
| `101` | Elastic-buffer overflow | — |
| `110` | Elastic-buffer underflow | — |
| `111` | Disparity error | — |

The wrapper qualifies normal RX error/SKP flags using initialization, `RxValid`, P0/P0s, and absence of an active detection operation. Raw `RxStatus` is still forwarded to the MAC.

| Interface | MAC/PHY signal | Direction | Course meaning |
|---|---|---|---|
| Clock/reset | `pclk`, `reset_n` | Inputs | PHY parallel clock; wrapper active-low reset |
| Reset | `pipe_reset_n` | To PHY | Forwarded PHY reset |
| Data | `mac_tx_data[7:0]`, `mac_tx_datak` | From MAC | Prepared TX byte and K indicator |
| Data | `TxData[7:0]`, `TxDataK` | To PHY | Registered TX byte and K indicator |
| Data | `RxData[7:0]`, `RxDataK`, `RxValid` | From PHY | Recovered byte, K indicator, validity |
| Data | `mac_rx_data[7:0]`, `mac_rx_datak`, `mac_rx_valid` | To MAC | RX information forwarded from PHY |
| Idle | `mac_tx_elecidle`, `TxElecIdle` | From MAC / to PHY | Requested/registered TX electrical idle |
| Idle | `RxElecIdle`, `mac_rx_elecidle` | From PHY / to MAC | Raw and filtered RX idle indications |
| Power | `mac_powerdown[1:0]`, `PowerDown[1:0]` | From MAC / to PHY | Desired and commanded PHY power state |
| Rate | `mac_rate`, `Rate` | From MAC / to PHY | Desired and commanded Gen1/Gen2 rate |
| Standby | `mac_rx_standby`, `RxStandby`, `RxStandbyStatus` | MAC / PHY / PHY | RX standby request, command, acknowledgment |
| Detect | `mac_detect_req`, `TxDetectRx` | From MAC / to PHY | Detect request and shared detect/loopback command |
| Loopback | `mac_loopback`, `mac_loopback_active` | From MAC / to MAC | Local loopback request and indication |
| TX electrical | `mac_tx_deemph`, `TxDeemph`, `mac_tx_margin[2:0]`, `TxMargin[2:0]`, `mac_tx_swing`, `TxSwing` | MAC / PHY | Selected PHY TX controls |
| Other control | `mac_tx_compliance`, `TxCompliance`, `mac_rx_polarity`, `RxPolarity` | MAC / PHY | Compliance and polarity commands |
| Status | `PhyStatus`, `RxStatus[2:0]` | From PHY | Operation completion and RX/detect status |
| Status | `power_done`, `rate_done`, `detect_done`, `detect_rx_present` | To MAC | One-cycle completions and held detect result |
| Diagnostics | `phy_busy`, `phy_initialized`, `phy_timeout`, `request_blocked`, `request_blocked_reason[2:0]` | To MAC | Controller health and blocked requests |

The integrated wrapper must keep **one operation arbiter**, **one wait-state owner of `PhyStatus`**, and **one writer of `TxDetectRx`**. The extracted power, idle, rate, detection, and loopback modules are teaching views of those responsibilities; directly tying their independent output registers together would create multiple drivers and lose arbitration. The final integration exercise should reconcile their interfaces with the shared controller in `pcie_pipe_mac_if_v3.v`.

### Suggested end-to-end checks

1. Reset in P1/Gen1, wait for initialization, then request P0 and confirm `power_done` follows `PhyStatus`.
2. Send EIOS before asserting TX idle; transition P0→P0s→P0 and P0→P1→P0.
3. In P0, request standby, wait for `RxStandbyStatus`, change Gen1→Gen2, then resume TS1/TS2 training.
4. In P1, request detection and test both present and absent results.
5. In P0 with TX active, enter/exit local loopback; ensure a detect request cannot take over `TxDetectRx`.
6. Test a delayed or missing `PhyStatus`, arbitration priority, blocked-reason reporting, and reset recovery from timeout.

## References and interpretation

- Intel, [PHY Interface for the PCI Express Architecture, archived revision 3.0 draft 0.9](https://www.intel.in/content/dam/doc/white-paper/phy-interface-pci-express-sata3-specification-v09.pdf), especially the PHY/MAC interface, power management, rate change, receiver detection, loopback, and control decode sections. It is an archived reference suitable for studying legacy Gen1/Gen2 signals, not the current normative revision.
- Intel, [PIPE specification overview](https://www.intel.com/content/www/us/en/io/pci-express/phy-interface-pci-express-sata-usb30-architectures-3-1.html). PIPE defines the MAC–PHY interface; the PCIe Base specification takes precedence where requirements conflict.
- PCI-SIG, [PCI Express Base specification overview](https://pcisig.com/specification-overview/pci-express-base), for link and LTSSM requirements.

This README was prepared from the displayed chapter filenames and the supplied `pcie_pipe_mac_if_v3` implementation. The chapter bodies themselves were not attached with the screenshot. Align their detailed prose and examples with this index before publishing the complete course package.
