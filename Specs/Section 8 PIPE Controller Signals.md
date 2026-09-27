# PCIe PIPE Signal Usage

The following table summarizes the PIPE signals used in the `pcie_pipe_mac_if_v3` module.

## PIPE Signal Summary

| PIPE Signal | Direction | Usage |
|---|---|---|
| `pclk` | PHY → MAC | PIPE interface clock. Normal PIPE transfers and control operations are referenced to this clock. |
| `pipe_reset_n` | MAC → PHY | Active-low reset for the PIPE PHY interface. |
| `TxData[7:0]` | MAC → PHY | 8-bit transmit data or symbol supplied to the PHY. |
| `TxDataK` | MAC → PHY | Indicates whether `TxData` is a control character (`K-code`) or normal data. |
| `TxElecIdle` | MAC → PHY | Requests transmitter electrical idle. Used during power transitions, receiver detection, rate changes, etc. |
| `TxCompliance` | MAC → PHY | Requests PCIe transmitter compliance-pattern operation. Mainly used for compliance testing. |
| `TxDetectRx` | MAC → PHY | Dual-purpose signal. In **P1**, it requests receiver detection. In active **P0**, it requests PHY loopback. |
| `PowerDown[1:0]` | MAC → PHY | Selects PHY power state: `00=P0`, `01=P0s`, `10=P1`, `11=P2`. P2 is unsupported by this wrapper. |
| `Rate` | MAC → PHY | Selects PCIe signaling rate: `0=Gen1 (2.5 GT/s)`, `1=Gen2 (5.0 GT/s)`. |
| `RxStandby` | MAC → PHY | Requests receiver standby. Used by this wrapper when performing a rate change while in P0. |
| `TxDeemph` | MAC → PHY | Selects transmitter de-emphasis. Gen2: `0=-6 dB`, `1=-3.5 dB`. Gen1 forces this signal to `1`. |
| `TxMargin[2:0]` | MAC → PHY | Controls transmitter voltage margin level when supported by the PHY. |
| `TxSwing` | MAC → PHY | Selects transmitter voltage swing mode or level when supported by the PHY. |
| `RxPolarity` | MAC → PHY | Requests receiver polarity inversion when the LTSSM detects reversed lane polarity. |
| `RxData[7:0]` | PHY → MAC | 8-bit received data or symbol from the PHY. |
| `RxDataK` | PHY → MAC | Indicates whether `RxData` represents a control character (`K-code`). |
| `RxValid` | PHY → MAC | Indicates that `RxData` and `RxDataK` contain valid received information. |
| `RxElecIdle` | PHY → MAC | Indicates receiver electrical-idle detection. In this wrapper it is synchronized and filtered before becoming `mac_rx_elecidle`. |
| `RxStatus[2:0]` | PHY → MAC | Reports receive events such as SKP insertion/removal, receiver-detection result, decode error, elastic-buffer error, and disparity error. |
| `RxStandbyStatus` | PHY → MAC | PHY acknowledgement that the receiver entered standby. Used before a P0 rate change. |
| `PhyStatus` | PHY → MAC | Completion or acknowledgement signal for PHY operations such as power-state change, rate change, and receiver detection. |

## RxStatus Encoding

| `RxStatus` | Meaning |
|---|---|
| `3'b000` | Normal / no special receive status |
| `3'b001` | SKP added |
| `3'b010` | SKP removed |
| `3'b011` | Receiver detected during receiver detection |
| `3'b100` | 8b/10b decode error |
| `3'b101` | Elastic buffer overflow |
| `3'b110` | Elastic buffer underflow |
| `3'b111` | Receive disparity error |


<img width="1357" height="1159" alt="image" src="https://github.com/user-attachments/assets/4a0edc7b-9925-40e3-9f5f-56ec8900c9b7" />

<img width="1447" height="1087" alt="image" src="https://github.com/user-attachments/assets/5d106254-fa51-4981-89c3-1fdee3eaf1ff" />



## Main PIPE Operations

| Operation | PIPE Signals Mainly Used |
|---|---|
| Power-state change | `PowerDown` → wait for `PhyStatus` |
| Gen1 ↔ Gen2 rate change | `TxElecIdle`, `RxStandby`, `RxStandbyStatus`, `Rate` → wait for `PhyStatus` |
| Receiver detection | `PowerDown=P1`, `TxElecIdle=1`, `TxDetectRx=1` → wait for `PhyStatus` → inspect `RxStatus` |
| Loopback | In `P0`, assert `TxDetectRx` to request PHY loopback |
| Normal transmit | `TxData`, `TxDataK`, `TxElecIdle`, `TxCompliance` |
| Normal receive | `RxData`, `RxDataK`, `RxValid`, `RxStatus`, `RxElecIdle` |

## Important Notes

- `PhyStatus` is shared by multiple PHY operations.
- The MAC-side FSM must remember which operation is active when `PhyStatus` is asserted.
- `RxElecIdle` is asynchronous to `pclk` in this design and therefore must be synchronized before being used by MAC logic.
- This wrapper additionally filters `RxElecIdle` using `RX_EI_FILTER_CYCLES`.
- `TxDetectRx` has two meanings depending on the PHY power state:
  - **P1:** Receiver detection.
  - **P0:** Loopback request.
- `RxStandbyStatus` is used as acknowledgement that the PHY receiver has entered standby before performing the configured P0 rate-change sequence.
- For LTSSM operation, `RxElecIdle` provides PHY electrical-idle information and does not replace decoding the required PCIe ordered sets received through `RxData` and `RxDataK`.
