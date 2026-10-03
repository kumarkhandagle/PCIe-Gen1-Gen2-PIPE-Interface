## How to Use PHY model
EDAplayground project link : https://www.edaplayground.com/x/hcSM

Use the PHY model as a **second module beside your DUT**. The testbench applies MAC requests, the DUT generates PIPE signals, and the model supplies PHY responses.

1. **Add three files to the simulator:** the PIPE DUT, the PHY model, and this testbench. Select `tb_pipe_power_change` as the simulation top. Compile `.sv` files as SystemVerilog.

2. **Connect the DUT and model using wires.** DUT outputs such as `PowerDown` and `TxElecIdle` go to the model. Model outputs such as `PhyStatus` and `RxStatus` return to the DUT. Connect `pipe_reset_n` to the model’s reset. The model generates `pclk`, so no separate clock generator is needed.

3. **Configure the model for your test.**
   - `STARTUP_CYCLES = 3`: initialization delay.
   - `POWER_CYCLES = 3`: power-change response delay after the model samples the request.
   - `STOP_ON_ERROR = 1`: stop simulation when the model detects a violation.

   Keep the `sim_rx_*` inputs configured for an idle incoming link and all fault-injection controls disabled, as shown.

4. **Apply reset and wait for initialization.** Hold `reset_n = 0` for three clocks, release it, and wait until `phy_initialized` becomes high. Check that both DUT and model start in P1.

5. **Apply the required stimulus.** On a falling clock edge, change `mac_powerdown` to P0. Keep unrelated MAC inputs fixed.

6. **Wait for the response and check the result.** The model generates `PhyStatus` automatically. After the DUT samples it, check `power_done`, `confirmed_power`, and the error/timeout signals. Also check that completion pulses return low.

7. **Finish or time out.** Print PASS and call `$finish` when checks succeed. The independent timeout prevents an endless wait, and the VCD file lets you inspect the waveform.




## Explore the PIPE PHY model through successful and unsuccessful operations**

For each task, write a separate test scenario. Apply the stimulus, predict the result, and compare your prediction with the simulation messages and waveform.

Before starting:

- Use `STOP_ON_ERROR = 0` for expected-failure exercises so you can check the diagnostic outputs.
- Reset before each independent scenario. A model violation latches `model_fault` and prevents further operations until reset.
- Drive stimulus on falling PCLK edges and check registered outputs after rising edges.
- Keep a simulation timeout to protect every `wait`.

Use these two test arrangements:

| Arrangement | What students drive | Purpose |
|---|---|---|
| **DUT + PHY model** | MAC inputs and `sim_*` environment inputs | Check the DUT’s requests and its handling of PHY responses. |
| **PHY model alone** | PIPE inputs directly, using TB registers | Deliberately generate illegal pin combinations that the DUT normally blocks. |

Do not drive DUT-connected PIPE wires from another source. Use a separate testbench for direct model testing.

**1. Startup and initialization**

**PASS exercise:** Complete normal PHY startup.

Hint: Release reset while the model sees `PowerDown=P1`, `Rate=0`, `TxElecIdle=1`, `TxDetectRx=0`, and `TxCompliance=0`.

Expected message: `Startup complete: P1, Gen1, PCLK available`.

Check that `PhyStatus` goes LOW and the DUT subsequently asserts `phy_initialized`.

**FAIL exercise:** Apply unsafe controls before startup finishes.

Hint: In the direct-model testbench, change `PowerDown` to P0 immediately after releasing reset, before `model_ready` becomes HIGH.

Expected: **code 2**, unsafe controls before startup completed.

Repeat by individually changing the other required startup controls.

---

**2. Power-state transitions**

**PASS exercise:** Complete every supported transition:

| Transition | Hint |
|---|---|
| P1 → P0 | Start from the reset state and request P0. |
| P0 → P1 | Keep TX idle and set `sim_rx_quiescent=1`. |
| P0 → P0s | Request P0s while TX remains idle. |
| P0s → P0 | Return to P0 while TX remains idle. |

Expected message: `Power state confirmed: ...`

Check `confirmed_power`, the `PhyStatus` pulse, and the DUT’s `power_done` pulse.

**FAIL exercises:**

| Condition to trigger | Hint | Expected diagnostic |
|---|---|---|
| Unsupported P2 | Directly drive `PowerDown=P2`. | **Code 3:** unsupported model profile |
| P1 → P0s directly | Start in P1 and request P0s. | **Code 4:** unsupported transition |
| P0s → P1 directly | First enter P0s, then request P1. | **Code 4:** transition must pass through P0 |
| Power change with active TX | From confirmed P0, request P0s or P1 with `TxElecIdle=0`. | **Code 5:** power transition requires TX idle |
| Active TX in a low-power state | Keep confirmed power in P1 or P0s and lower `TxElecIdle`. | **Code 5:** TX must remain idle |

Try illegal power requests through the DUT too. If the DUT blocks them, **no PHY failure message should appear**, because the illegal request never reaches the model.

---

**3. Incoming-link condition during P1 entry**

**PASS exercise:** Enter P1 with a quiescent incoming link.

Hint: Set `sim_rx_quiescent=1`, keep TX idle, then request P0 → P1.

Expected: successful power confirmation.

**FAIL exercise:** Enter P1 while the environment reports active incoming traffic.

Hint: Set `sim_rx_quiescent=0` before requesting P1. Keep `CHECK_P1_RX_IDLE=1`.

Expected: **code 6**, P1 entry requires an idle incoming link.

Explain why local `TxElecIdle=1` alone cannot prove that the incoming link is idle.

---

**4. Receiver standby**

**PASS exercise:** Enter and leave receiver standby.

Hint: In P0, request `RxStandby=1` and wait for `RxStandbyStatus=1`. Then request `RxStandby=0` and wait for its acknowledgement.

Expected messages:

- `Receiver standby state confirmed: 1`
- `Receiver standby state confirmed: 0`

Check that this handshake uses **`RxStandbyStatus`**, rather than a `PhyStatus` completion pulse.

**FAIL exercise:** Withdraw a standby request before acknowledgement.

Hint: Start from `RxStandby=0` and `RxStandbyStatus=0`. Assert `RxStandby`, allow the model to sample it, then lower it before the standby delay finishes.

Expected: **code 16**, standby request changed before acknowledgement.

---

**5. Rate changes**

**PASS exercise:** Complete Gen1 → Gen2 and Gen2 → Gen1 in both P0 and P1.

Hints:

- Keep `TxElecIdle=1`.
- In P0, assert receiver standby and wait for its acknowledgement **before** changing the rate.
- In P1, this model does not require that standby handshake.
- When requesting Gen1, ensure `TxDeemph=1`.

Expected messages: `Rate confirmed: Gen2` and `Rate confirmed: Gen1`.

Check `confirmed_rate`, `rate_done`, and the configured PCLK period.

**FAIL exercises:**

| Condition to trigger | Hint | Expected diagnostic |
|---|---|---|
| Rate change in P0s | Enter P0s, then directly change `Rate`. | **Code 7:** rate change allowed only in P0/P1 |
| Missing standby in P0 | Change rate with `RxStandby=0` and its status LOW. | **Code 8:** standby required |
| Standby requested but not acknowledged | Assert standby and change rate before its status becomes HIGH. | **Code 8:** standby acknowledgement required |
| Active TX during rate request | Change rate from P0 with `TxElecIdle=0`. | **Code 5:** rate change requires TX idle |
| Incorrect Gen1 deemphasis | While `Rate=0`, directly drive `TxDeemph=0`. | **Code 13:** Gen1 requires `TxDeemph=1` |

Observe whether the DUT blocks or delays the corresponding illegal MAC requests.

---

**6. Receiver detection**

**PASS exercise A:** Detect a connected receiver.

Hint: Stay in P1 with TX idle, set `sim_receiver_present=1`, and request detection.

Expected: `Detection completed: receiver present`, with `RxStatus=3'b011`.

**PASS exercise B:** Detect an absent receiver.

Hint: Repeat with `sim_receiver_present=0`.

Expected: `Detection completed: receiver absent (valid result)`, with `RxStatus=3'b000`.

**An absent receiver is a valid detection result.**

Keep the detection request asserted through the edge where the DUT samples completion. Then lower it before requesting another detection.

**FAIL exercises:**

| Condition to trigger | Hint | Expected diagnostic |
|---|---|---|
| Early detection withdrawal | Directly lower `TxDetectRx` after detection starts but before completion is sampled. | **Code 11:** detection request withdrawn too soon |
| Withdrawal at the acknowledgement boundary | Lower `TxDetectRx` after `PhyStatus` rises but before the following sampling edge. | **Code 11:** request must remain held |
| Detection encoding in P0s | Directly assert `TxDetectRx` while confirmed power is P0s. | **Code 12:** unsupported operation in P0s |

Also hold the request HIGH after a successful detection. Confirm that it does not repeatedly trigger detection.

---

**7. Loopback**

**PASS exercise:** Enter loopback, transfer incoming symbols, then exit.

Hint: In active P0, use `TxDetectRx=1` and `TxElecIdle=0`. Through the DUT, use `mac_loopback=1` and `mac_tx_elecidle=0`.

Provide incoming symbols using `sim_rx_*`, with the receiver out of standby and incoming electrical idle LOW.

Expected messages:

- `Loopback enabled: incoming link symbols forwarded to outgoing link`
- `Loopback disabled`

Check that incoming symbols reach both MAC RX and the outgoing `sim_tx_*` taps. Use different local `TxData` values to confirm that loopback uses the **incoming stream**.

**FAIL exercise:** Request P0 loopback while TX is idle.

Hint: Directly drive `TxDetectRx=1` with `TxElecIdle=1` in confirmed P0.

Expected: **code 12**, P0 loopback requires active TX.

---

**8. Transmit data and control characters**

**PASS exercise:** Transmit normal bytes and a valid control character.

Hints:

- Enter active P0 with loopback disabled.
- Send normal bytes with `TxDataK=0`.
- Send `8'hBC` with `TxDataK=1` as a valid K28.5 character.

Compare the transmitted stream against `sim_tx_data`, `sim_tx_datak`, and `sim_tx_valid`.

This data path does **not** print a separate PHY PASS message for every byte; write TB checks.

**FAIL exercises:**

| Condition to trigger | Hint | Expected diagnostic |
|---|---|---|
| Invalid K character | Send `TxData=8'h00`, `TxDataK=1`, with active TX and `CHECK_K_CODES=1`. | **Code 15:** invalid K character |
| Unknown active data | Send `TxData=8'hxx` while TX is active. | **Code 1:** unknown transmit data |
| Unknown active qualifier | Drive `TxDataK=1'bx` while TX is active. | **Code 1:** unknown transmit qualifier |

Repeat unknown-data stimulus while TX is electrically idle. Confirm that unused TX data does not cause a fault.

---

**9. Compliance qualification**

**PASS exercise:** Assert `TxCompliance` during active P0 transmission.

Hint: Use `PowerDown=P0` and `TxElecIdle=0`.

Check that the model accepts this qualification without fault. This exercise does not verify an actual serial compliance pattern.

**FAIL exercise:** Assert compliance outside active P0.

Hint: Try it in P1, P0s, and P0 with `TxElecIdle=1`.

Expected: **code 14**, compliance asserted outside active P0 transmission.

---

**10. Operation stability and overlap**

**PASS exercise:** Keep an operation’s controls stable until completion is sampled.

Hint: Hold `PowerDown`, `Rate`, `RxStandby`, and `TxDetectRx` unchanged during a power, rate, or detection operation. Keep TX idle.

**FAIL exercises:**

| Condition to trigger | Hint | Expected diagnostic |
|---|---|---|
| Simultaneous power and rate requests | From P1/Gen1, directly request P0 and Gen2 on the same sampled edge. | **Code 9:** simultaneous changes unsupported |
| Power change before exiting detect/loopback | Keep `TxDetectRx` asserted and directly request a power change. | **Code 9:** exit detect/loopback first |
| Rate change before exiting detect/loopback | Keep `TxDetectRx` asserted and directly change rate. | **Code 9:** exit detect/loopback first |
| Controls changed while busy | Start a power change, then change `Rate` or another captured control before completion. | **Code 10:** operation controls changed |
| TX idle withdrawn while busy | Start an operation, keep its captured controls stable, then lower `TxElecIdle`. | **Code 5:** idle must remain asserted |

Through the DUT, request power and rate together. Check that the DUT serializes them rather than presenting simultaneous changes to the model.

---

**11. Unknown control pins**

**PASS exercise:** Keep all required PIPE controls at known values.

**FAIL exercise:** Introduce X or Z on a required control after startup.

Hint: In the direct-model testbench, try `Rate=1'bx`, then independently repeat with other checked controls such as `TxMargin` or `RxPolarity`.

Expected: **code 1**, X/Z on a required PIPE control.

Explain why this differs from unknown TX data while the transmitter is idle.

---

**12. Missing responses and injected detection results**

**PASS exercise:** Complete power, rate, and detection operations with their stall inputs LOW.

**Unsuccessful-operation exercises:**

| Stimulus | Hint | Expected observation |
|---|---|---|
| `sim_stall_power=1` | Set it before launching a legal power change. | No power acknowledgement; DUT operation timeout |
| `sim_stall_rate=1` | Set it before launching a legal rate change. | No rate acknowledgement; DUT operation timeout |
| `sim_stall_detect=1` | Set it before launching legal detection. | No detection acknowledgement; DUT operation timeout |
| `sim_stall_startup=1` | Hold it HIGH during startup. | Initialization remains pending; use the TB watchdog |
| `sim_stall_standby=1` | Request standby while its response is stalled. | Standby remains pending; investigate DUT timeout behavior |

These stalls do not themselves produce ordinary PHY FAIL diagnostics. Power/rate/detection stalls are captured when the operation starts and require reset to recover that operation.

**Injected-response exercise:** Enable `sim_detect_override_en` before detection and supply each possible three-bit `sim_detect_override_status`.

Expected: `PHY INJECT`, with **diagnostic code 128**.

Compare valid detection results `000`/`011` with the other encodings. The supplied DUT treats unexpected detection status as receiver absent; identify this limitation in your report.

The supplied DUT also lacks startup and standby-preparation timeouts, so do not assume every pending handshake asserts `phy_timeout`.

---

**13. Parameter validation and reset recovery**

**PASS exercise:** Run with valid model timing parameters.

**FAIL exercise:** Use invalid timing parameters in separate simulation runs.

Hint: Try `POWER_CYCLES=0`, `RATE_CYCLES=2`, a nonpositive clock period, or a negative `RATE_PAUSE_NS`.

Expected: immediate `$fatal` reporting invalid PHY timing parameters.

**Recovery exercise:** Trigger any ordinary model violation, restore legal pins, and observe that the fault remains latched. Apply reset and verify that the model can initialize and complete a valid operation again.

**Submission requirement:** For every scenario, provide the stimulus, predicted result, observed message or diagnostic code, and a waveform showing the relevant handshake. An expected-failure test passes when it detects the intended failure reason—not merely because some failure occurred.
