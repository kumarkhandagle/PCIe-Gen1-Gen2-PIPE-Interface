# PCIe Gen1/Gen2 PIPE Clocking and CDC Reference

Scope: `pcie_pipe_mac_if_v3`, one lane, 8-bit original PIPE, PHY-generated `pclk`, P0/P0s/P1. This is an implementation reference, not a replacement for the PIPE specification or the target PHY datasheet.

## PIPE clocking rule

PIPE defines the interface between MAC and PHY. In original PIPE, parallel signals use PCLK unless their definitions specify an exception. The rising edge is the timing reference. [1, Sections 6 and 6.4]

| Direction | Signals in this wrapper | Timing contract |
|---|---|---|
| MAC to PHY | `TxData`, `TxDataK`, `TxElecIdle`, `TxCompliance` | PCLK synchronous |
| MAC to PHY | `PowerDown`, `Rate`, `RxStandby`, `RxPolarity`, `TxDeemph`, `TxMargin`, `TxSwing` | PCLK synchronous in normal clocked operation |
| MAC to PHY | `TxDetectRx` | PCLK synchronous for the supported P0/P1 operations |
| PHY to MAC | `RxData`, `RxDataK`, `RxValid`, `RxStatus`, `RxStandbyStatus` | PCLK synchronous; validity is operation-dependent |
| PHY to MAC | `PhyStatus` | Normally synchronous; asynchronous during specified transitions involving unavailable PCLK |
| PHY to MAC | `RxElecIdle` | Asynchronous |

`RxStandbyStatus` is undefined in PCIe P1/P2. This wrapper checks it for rate changes in P0. [1, Section 6.1]

## Synchronous interface timing

Section 8.26 specifies these interoperability limits. Inputs and outputs are described from the PHY perspective. [1]

| Characteristic | Limit |
|---|---|
| Required input setup time | At most 25% of PCLK period |
| Required input hold time | 0 ns |
| PCLK to valid output | At most 25% of PCLK period |

Use the actual PHY timing and routing delay for timing closure. A setup requirement capped at 25% does not mean the MAC should intentionally change signals 25% before the sampling edge.

Calculated examples for this 8-bit wrapper:

| Mode | PCLK | Period | 25% of period |
|---|---|---|---|
| Gen1 | 250 MHz | 4 ns | 1 ns |
| Gen2 | 500 MHz | 2 ns | 0.5 ns |

## Why RxElecIdle needs CDC

An electrical-idle detector responds to the incoming physical signal. Sharing a PHY-generated clock does not establish a timing relationship between that detector output and the clock.

In the attached RTL, both synchronizer stages run on `pclk`:

```verilog
(* ASYNC_REG = "TRUE" *) reg rx_ei_meta;
(* ASYNC_REG = "TRUE" *) reg rx_ei_sync;

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

The first stage can become metastable. The second gives it approximately one clock period to resolve before its value reaches downstream logic. This reduces propagation risk; it does not guarantee zero failures. Select synchronizer depth using the target clock rate and reliability requirement.

Vivado's `ASYNC_REG` attribute identifies the chain and assists preservation and placement. [2]

## Synchronization and filtering in the wrapper

| RTL element | Role |
|---|---|
| `rx_ei_meta` | First sampling stage; do not use for MAC decisions |
| `rx_ei_sync` | Second stage used by the filter |
| `rx_ei_counter` | Counts consecutive synchronized samples differing from the accepted output |
| `mac_rx_elecidle` | Accepted, filtered indication |

With `RX_EI_FILTER_CYCLES = 32`, the filter requires 32 consecutive differing samples before accepting a change. A sample matching the accepted output resets the count. Setting the parameter to zero bypasses filtering while retaining synchronization. The filter introduces additional latency; it is not the synchronizer.

## Integration requirements for this RTL

- Supply `mac_*` inputs from the `pclk` domain. The wrapper does not synchronize them.
- Consume completion pulses such as `power_done`, `rate_done`, and `detect_done` in `pclk`. Use an event handshake or another suitable transfer if their consumer uses a different clock.
- If the LTSSM or register interface uses another clock, transfer requests and associated configuration coherently before presenting them to this wrapper.
- Do not independently synchronize the bits of `RxData` or another coherent bus. Use a suitable FIFO or handshake if transferring them to another domain.
- Close synchronous timing against `pclk`; identify and constrain the asynchronous input crossing appropriately while preserving timing between synchronizer stages.
- Arrange reset release safely for each clock domain and follow the PHY's reset requirements.
- The timeout counter advances only on active `pclk` edges. A stopped clock also stops the counter.

At Gen2, MAC logic must infer electrical-idle entry rather than relying solely on `RxElecIdle`. Synchronization does not remove this protocol requirement. [1, RxElecIdle definition]

## References

1. [Intel PIPE Architecture Specification, Revision 7.1](https://cdrdv2-public.intel.com/643108/643108_PIPE_Arch_Spec_Rev_7_1.pdf), original PIPE rules in Sections 6, 6.4 and 8.26. This document uses those rules for the Gen1/Gen2 subset; it does not claim complete PIPE 4.x/5.x compliance.
2. [AMD Vivado Properties Reference Guide, UG912: ASYNC_REG](https://docs.amd.com/r/en-US/ug912-vivado-properties/ASYNC_REG).

RTL observations are based on the supplied `pcie_pipe_mac_if_v3` source.
