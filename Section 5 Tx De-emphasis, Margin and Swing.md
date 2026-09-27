# Tx De-emphasis, Margin, and Swing

PCI Express transmitters expose several controls that influence the electrical waveform presented to the link. In a Gen1/Gen2 PIPE-based design, three of the most important controls are `TxDeemph`, `TxMargin`, and `TxSwing`.

Although all three affect transmitter behavior, they operate on fundamentally different aspects of the signal:

* `TxDeemph` controls **waveform shaping** by changing the relationship between transition and repeated-bit amplitudes.
* `TxMargin` controls the **overall transmitter voltage level** and is primarily associated with electrical margin testing.
* `TxSwing` selects the broad **full-swing or low-swing operating family**.

These controls should not be treated as interchangeable amplitude settings. Correct PHY control requires understanding whether the objective is channel-loss compensation, absolute voltage adjustment, or selection of the transmitter swing family.

## Transmitter Signal-Integrity Context

A PCIe electrical channel does not attenuate all frequency components equally. PCB traces, connectors, vias, and package structures generally attenuate high-frequency components more strongly than low-frequency components. Because rapid transitions contain substantial high-frequency energy, their degradation becomes increasingly significant as signaling rate and channel loss increase. 

Consider the following bit sequence:

```text
0 0 0 0 1 1 1 1 0 0 0
        ^       ^
     transition transition
```

The `0→1` and `1→0` boundaries are particularly important because they represent rapid changes in the transmitted signal. After propagation through a lossy channel, these transitions can become less distinct. Neighboring symbols then begin to influence one another, producing inter-symbol interference, or ISI, and reducing the receiver eye opening. 

PCIe transmitters therefore provide electrical controls that modify the transmitted waveform before it enters the channel.

## Tx De-emphasis

### Purpose of De-emphasis

`TxDeemph` compensates for frequency-dependent channel loss by making transitions relatively stronger than portions of the waveform containing repeated identical bits.

Conceptually, the transmitted waveform behaves as follows:

```text
Transition occurs
       |
       v
  full amplitude
       |
       +---- repeated bit -> reduced amplitude
       +---- repeated bit -> reduced amplitude
       +---- repeated bit -> reduced amplitude
```
<img width="816" height="456" alt="image" src="https://github.com/user-attachments/assets/ed9b9883-9664-46e2-abf9-9346a464ca1e" />

The transition level remains at the full transmitted level, while succeeding identical bits are attenuated. This increases the relative prominence of transitions and helps compensate for high-frequency loss in the channel. 

It is therefore more precise to describe PCIe de-emphasis as **attenuating repeated-bit levels relative to transition levels** rather than as increasing transitions beyond the normal transmitter maximum.

### Gen1 and Gen2 De-emphasis Settings

For the Gen1/Gen2 PIPE interface described here, `TxDeemph` selects between two de-emphasis levels:

| `TxDeemph` | De-emphasis |
| ---------- | ----------: |
| `0`        |     `-6 dB` |
| `1`        |   `-3.5 dB` |

Gen1 normally uses `-3.5 dB`, whereas Gen2 can select either `-3.5 dB` or `-6 dB`. 

The negative values indicate attenuation of the de-emphasized level relative to the full-amplitude transition level. Consequently, `-6 dB` represents stronger de-emphasis than `-3.5 dB`.

### Converting De-emphasis from Decibels to Amplitude

The de-emphasis values are ratios, not absolute transmitter voltages.

For voltage amplitude, the relationship between decibels and linear amplitude is

$$
A_{\text{ratio}} = 10^{\frac{\text{dB}}{20}}
$$

For `-3.5 dB`:

$$
A_{\text{ratio}}
=
10^{-3.5/20}
\approx
0.67
$$

For `-6 dB`:

$$
A_{\text{ratio}}
=
10^{-6/20}
\approx
0.50
$$

Thus, the repeated-bit amplitude is approximately:

| De-emphasis | Repeated-bit amplitude relative to full level |
| ----------- | --------------------------------------------: |
| `0 dB`      |                                          100% |
| `-3.5 dB`   |                                           67% |
| `-6 dB`     |                                           50% |

These ratios describe the relationship between waveform levels; they do not imply particular absolute transmitter voltages. 

### Illustrative Waveform Example

Assume, only for illustration, that the full transition level corresponds to a normalized amplitude of `1.00`.

For the sequence

```text
0 0 0 1 1 1 1
      ^
   transition
```

with `-3.5 dB` de-emphasis:

```text
First 1 after transition : 1.00
Next 1                  : 0.67
Next 1                  : 0.67
Next 1                  : 0.67
```

With `-6 dB` de-emphasis:

```text
First 1 after transition : 1.00
Next 1                  : 0.50
Next 1                  : 0.50
Next 1                  : 0.50
```

The more negative setting therefore produces a greater reduction in the repeated-bit level. 

## Two-Tap Interpretation of De-emphasis

A useful mathematical model for de-emphasis is a two-tap finite-impulse-response structure consisting of a main cursor and a delayed post-cursor term:

$$
y[n] = A x[n] - B x[n-1]
$$

where:

* \(x[n]\) is the current transmitted symbol,
* \(x[n-1]\) is the previous symbol,
* \(A\) is the main-tap coefficient,
* \(B\) is the magnitude of the post-cursor coefficient.

For analysis, represent the two logic levels using bipolar values:

$$
1 \rightarrow +1
$$

$$
0 \rightarrow -1
$$

This model explains why repeated symbols have reduced magnitude while transitions receive the larger waveform level. 

### Repeated Symbols

For two consecutive logic-1 symbols,

$$
x[n] = +1
$$

and

$$
x[n-1] = +1
$$

Therefore,

$$
y[n]
=
A(+1)-B(+1)
$$

and

$$
\boxed{y[n]=A-B}
$$

The delayed tap opposes the main tap, reducing the output magnitude.

```text
Current symbol      +A -------+
                             |
Previous-symbol     -B -------+----> A - B
                                   reduced level
```

The same reduction occurs for repeated zero symbols, with opposite signal polarity.

### Rising Transition

For a `0→1` transition,

$$
x[n]=+1
$$

and

$$
x[n-1]=-1
$$

Therefore,

$$
y[n]
=
A(+1)-B(-1)
$$

which gives

$$
\boxed{y[n]=A+B}
$$

The delayed post-cursor contribution now reinforces the main tap.

```text
Current symbol           +A -------+
                                  |
Previous symbol = -1              |
Post-cursor = -B                   +----> A + B
                                  |
(-B)(-1) = +B -----------+
```

### Falling Transition

For a `1→0` transition,

$$
x[n]=-1
$$

and

$$
x[n-1]=+1
$$

giving

$$
y[n]=-A-B
$$

The polarity is negative, but the magnitude is

$$
|y[n]|=A+B
$$

Thus both rising and falling transitions receive the larger magnitude. 

A representative waveform therefore has the qualitative behavior:

```text
Data:

0  0  0  1  1  1  0  0
         ^        ^
      transition transition

TX magnitude:

low low low HIGH low low HIGH low
```

### Electrical Interpretation

A physical transmitter can implement this behavior using separate current-steering driver segments corresponding to the main and post-cursor taps:

```text
                    Main driver
x[n] ---------------- x A --------+
                                  |
                                  +----> Tx+ / Tx-
                                  |
x[n-1] -------------- x -B -------+
                    Post-cursor
```

During transitions, the two contributions reinforce one another. During repeated bits, they oppose one another. In this sense, de-emphasis behaves similarly to a high-pass response: rapid changes are emphasized relative to long runs of unchanged data. 

The term **boost** should nevertheless be used carefully. The larger transition level is normally regarded as the full-amplitude level; de-emphasis reduces the repeated-bit level rather than necessarily driving transitions beyond the transmitter's normal maximum swing.

## Tx Margin

### Purpose of TxMargin

`TxMargin` performs a fundamentally different function from `TxDeemph`.

Whereas de-emphasis changes the **relative waveform levels**, `TxMargin` changes the **overall differential transmitter voltage**. Its primary purpose is voltage-margin characterization, validation, compliance testing, and related debug activities. 

A simplified comparison illustrates the distinction.

With normal `-3.5 dB` de-emphasis, assume the normalized transmitter produces:

```text
Transition level : 1.00
Repeated level   : 0.67
```

Changing `TxDeemph` to the stronger setting may produce:

```text
Transition level : 1.00
Repeated level   : 0.50
```

The relative waveform shape has changed.

By contrast, reducing transmitter margin could conceptually scale the complete waveform:

```text
Normal:
Transition level : 1.00
Repeated level   : 0.67

Reduced TxMargin:
Transition level : 0.80
Repeated level   : 0.54
```

The numerical values in this example are illustrative. The essential distinction is that both waveform levels decrease together.

### De-emphasis Versus Margin

The controls therefore operate in different dimensions:

| Control    | Primary effect                                            | Typical purpose           |
| ---------- | --------------------------------------------------------- | ------------------------- |
| `TxDeemph` | Changes transition-to-repeated-bit amplitude relationship | Channel-loss compensation |
| `TxMargin` | Changes overall differential TX voltage                   | Voltage-margin testing    |

De-emphasis addresses distortion:

```text
TxDeemph
    |
    v
Relative amplitudes
    |
    v
Waveform / frequency shaping
```

Margin controls absolute electrical strength:

```text
TxMargin
    |
    v
Overall TX amplitude
    |
    v
Voltage-margin characterization
```

For example, testing whether a receiver still functions when the transmitted amplitude is deliberately reduced requires `TxMargin`; changing `TxDeemph` would primarily alter the signal's transition-to-repeated-bit relationship instead. 

## TxMargin Encoding

`TxMargin[2:0]` is an encoded request for a transmitter voltage level. It should not be interpreted as a generation selector.

In particular, Gen1 and Gen2 do not normally require different `TxMargin` values simply because their signaling rates differ. In normal operation, both can use

```systemverilog
TxMargin = 3'b000;
```

The margin code is changed when deliberate transmitter-voltage margining is required. 

The source material describes the following approximate interpretation for full-swing operation:

| `TxMargin` | Full-swing TX level                           | Interpretation               |
| ---------- | --------------------------------------------- | ---------------------------- |
| `000`      | Normal operating range                        | Normal operation             |
| `001`      | 800–1200 mV                                   | High/normal full-swing range |
| `010`      | Vendor-defined                                | Intermediate margin level    |
| `011`      | Vendor-defined                                | Intermediate margin level    |
| `100`      | 200–400 mV if this is the last supported step | Very low margin level        |
| `101`      | Optional/vendor-defined                       | Additional margin step       |
| `110`      | Optional/vendor-defined                       | Additional margin step       |
| `111`      | Optional/vendor-defined                       | Additional margin step       |

For the corresponding low-swing family, the source identifies approximately `400–700 mV` for the relevant higher-amplitude level and `100–200 mV` for the lowest supported margin step. 

These codes must not be interpreted as eight universally fixed voltage steps such as:

```text
000 -> 1000 mV
001 ->  900 mV
010 ->  800 mV
...
```

Several intermediate values are intentionally PHY- or vendor-dependent. RTL should therefore pass `TxMargin` as an **encoded PHY request**, rather than translating every code into an assumed analog voltage. 

### Normal Gen1/Gen2 Usage

A typical normal operating configuration is:

```text
Gen1, 2.5 GT/s:
    TxMargin = 000

Gen2, 5.0 GT/s:
    TxMargin = 000
```

`TxMargin` changes only when margining, validation, compliance, or another deliberate amplitude-control operation requires a non-default setting.

The source also identifies an implementation distinction: a PCIe-only PHY supporting only 2.5 GT/s may omit the margin control, whereas it becomes relevant in a Gen2-capable PIPE implementation. 

## Voltage-Margin Characterization

The purpose of voltage margining is to determine how much reduction in transmitter amplitude a link can tolerate before receiver performance becomes unacceptable.

Conceptually, a margin sequence can progress from normal amplitude toward progressively reduced levels:

```text
TxMargin = 000
      |
      | reduce transmitter voltage
      v
TxMargin = 001
      |
      v
intermediate settings
      |
      v
lower supported margin setting
```

As the transmitted differential amplitude is reduced, the receiver eye becomes vertically smaller. Testing continues until the receiver approaches or crosses its operating limit.

The measured result characterizes the link's voltage safety margin:

```text
normal TX amplitude
        |
        v
reduce amplitude
        |
        v
smaller receiver eye
        |
        v
observe error behavior
        |
        v
determine operating margin
```

The exact intermediate voltage progression can depend on the PHY implementation. This is another reason for keeping the digital control expressed in terms of `TxMargin` encoding rather than embedding assumed analog values in MAC or wrapper RTL. 

## Tx Swing

### Full-Swing and Low-Swing Modes

`TxSwing` selects the broad transmitter voltage family.

For the Gen1/Gen2 PIPE context described in the source, it is a one-bit control:

| `TxSwing` | Meaning        | Approximate differential-voltage family |
| --------- | -------------- | --------------------------------------: |
| `0`       | Full swing     |                             800–1200 mV |
| `1`       | Low/half swing |                              400–700 mV |

Thus:

```text
TxSwing = 0
    |
    v
Full-swing family
larger transmitter amplitude
```

and

```text
TxSwing = 1
    |
    v
Low-swing family
smaller transmitter amplitude
```

The source notes that low swing is optional and that a PHY supporting only full-swing operation does not necessarily need to implement the control. It also states that this `TxSwing` control is not used at 8.0 GT/s or higher. 

### Differential Interpretation

For a differential pair, the full-swing case can be visualized approximately as

```text
TxSwing = 0

       Full swing

Tx+    +400 to +600 mV
          |
          | differential amplitude
          | approximately 800–1200 mV
          |
Tx-    -400 to -600 mV
```

A low-swing case is correspondingly smaller:

```text
TxSwing = 1

       Low / half swing

Tx+    +200 to +350 mV
          |
          | differential amplitude
          | approximately 400–700 mV
          |
Tx-    -200 to -350 mV
```

These values represent approximate voltage families rather than an assertion that every implementation drives one fixed amplitude. 

## TxSwing and TxMargin Relationship

`TxSwing` and `TxMargin` both relate to transmitter amplitude, but at different levels of abstraction.

`TxSwing` selects the broad operating family:

```text
TxSwing
   |
   +---- 0 -> Full swing
   |
   +---- 1 -> Low swing
```

`TxMargin` then requests an amplitude level within the supported behavior of that family:

```text
TxSwing
   |
   v
Select voltage family
   |
   v
TxMargin
   |
   v
Select/request voltage level
```

For example:

```text
TxSwing = 0
    |
    v
Full-swing family
    |
    +---- TxMargin = 000
    |         normal full-swing operation
    |
    +---- other supported TxMargin value
              reduced amplitude for margining
```

The same conceptual hierarchy applies to a PHY supporting low swing:

```text
TxSwing = 1
    |
    v
Low-swing family
    |
    v
TxMargin selects a supported level
```

`TxSwing` should therefore be viewed as a **mode or range selector**, whereas `TxMargin` is an **amplitude-level request within the selected operating context**. 

## Why Low Swing Exists

Low-swing operation can be useful when the channel is sufficiently short and clean that the larger full-swing amplitude is unnecessary.

A low-loss connection may permit:

```text
TX ================= RX
        low loss

TxSwing = 1
low swing
```

Reducing transmitter amplitude can reduce transmitter power.

For a longer or more lossy connection:

```text
TX ========================== RX
             more loss
```

full swing provides greater transmitted amplitude:

```text
TxSwing = 0
```

Low swing should therefore not be interpreted as the normal Gen2 mode or as a generational distinction. Both Gen1 and Gen2 can use full-swing signaling; low swing is an optional operating choice. 

## Combined View of the Three Controls

The three transmitter controls can be organized hierarchically.

### TxSwing: Select the Voltage Family

```text
TxSwing
   |
   v
Broad operating range
   |
   +---- Full swing
   |
   +---- Low swing
```

### TxMargin: Select or Reduce the Overall Voltage Level

```text
TxMargin
   |
   v
Absolute transmitter-amplitude request
   |
   v
Normal or deliberately reduced voltage
```

### TxDeemph: Shape the Waveform Within That Amplitude

```text
TxDeemph
   |
   v
Relative transition / repeated-bit relationship
   |
   +---- -3.5 dB
   |
   +---- -6 dB
```

The distinction can be summarized as follows:

| Control         |                          Width | Controls                                 | Typical role                       |
| --------------- | -----------------------------: | ---------------------------------------- | ---------------------------------- |
| `TxSwing`       |                          1 bit | Broad TX amplitude family                | Full swing versus low swing        |
| `TxMargin[2:0]` |                         3 bits | Overall TX voltage request               | Margin/compliance characterization |
| `TxDeemph`      | 1 bit in the Gen1/Gen2 context | Transition versus repeated-bit amplitude | Channel-loss compensation          |

The source material summarizes the same separation as `TxSwing` controlling full versus low voltage mode, `TxMargin` controlling overall voltage margin, and `TxDeemph` controlling transition/repeated-bit waveform shaping. 

## Signal-Processing View

These controls can also be understood as acting at different conceptual stages of the transmitter.

```text
                  Serialized data
                       |
                       v
                +--------------+
                | De-emphasis  |
                | waveform     |
                | shaping      |
                +--------------+
                       |
                       v
                +--------------+
                | Swing family |
                | selection    |
                +--------------+
                       |
                       v
                +--------------+
                | Margin / TX  |
                | amplitude    |
                +--------------+
                       |
                       v
                     Channel
                       |
                       v
                    Receiver
```

This representation is conceptual rather than an assertion about the exact physical ordering inside a particular PHY. Its purpose is to distinguish the controlled quantities:

* De-emphasis changes the **shape** of the signal.
* Swing selects the broad **amplitude family**.
* Margin changes the requested **overall voltage level**.

## Eye-Diagram Interpretation

The differences also appear naturally in an eye-diagram view.

### Effect of De-emphasis

De-emphasis attempts to compensate for channel distortion. The goal is not merely to create a larger transmitted eye at the output pins, but to improve the waveform presented to the receiver after propagation through a frequency-selective channel.

```text
TX ---- de-emphasis ---- channel ---- RX
                              |
                              v
                   improved transition quality
                   and reduced effective ISI
```

The intended effect is improved signal shape and a cleaner receiver eye.

### Effect of TxMargin

Reducing `TxMargin` intentionally reduces transmitted amplitude.

Conceptually:

```text
Normal amplitude:

       +----------+
      /            \
-----/              \-----
     \              /
      +------------+

       larger eye height
```

With reduced transmitter voltage:

```text
Reduced amplitude:

       +------+
      /        \
-----/          \-----
     \          /
      +--------+

       smaller eye height
```

The objective is not to improve the eye but to determine whether the receiver continues operating correctly as the eye height is deliberately reduced. 

## Practical Gen1/Gen2 PIPE Configuration

For a simple Gen1/Gen2 controller operating normally with full swing and without active voltage-margin testing, the source material identifies the following practical defaults:

```systemverilog
TxSwing  = 1'b0;      // Full swing
TxMargin = 3'b000;    // Normal operating voltage
```

These settings can remain the same for both Gen1 and Gen2 during normal operation. 

`TxDeemph` is controlled separately according to the required de-emphasis behavior:

```text
TxDeemph = 1 -> -3.5 dB
TxDeemph = 0 -> -6 dB
```

A simplified generation-dependent interpretation is therefore:

| Operating mode         | `TxSwing`           | `TxMargin`                    | `TxDeemph`                                 |
| ---------------------- | ------------------- | ----------------------------- | ------------------------------------------ |
| Gen1 normal operation  | `0`                 | `000`                         | normally `1` → `-3.5 dB`                   |
| Gen2 normal operation  | `0`                 | `000`                         | selected as required: `-3.5 dB` or `-6 dB` |
| Voltage-margin testing | selected swing mode | non-default value as required | independent waveform-shaping setting       |

This separation is important for RTL architecture. `TxMargin` should not be changed merely because the link switches between 2.5 GT/s and 5.0 GT/s. The generation-dependent electrical behavior discussed here is primarily associated with `TxDeemph`, while the default swing and margin controls can remain unchanged during ordinary operation. 

## Implementation Considerations

### Treat TxMargin as an Encoding

Because some intermediate `TxMargin` levels are implementation-defined, digital logic should treat the field as an encoded request to the PHY.

Avoid RTL assumptions such as:

```systemverilog
// Conceptually unsafe assumption
if (txmargin == 3'b010)
    tx_voltage_mv = 800;
```

unless the particular PHY implementation explicitly defines such a mapping.

The safer architectural model is:

```text
MAC / controller
      |
      | TxMargin[2:0]
      v
PHY-specific interpretation
      |
      v
Analog transmitter amplitude control
```

This keeps analog implementation details inside the PHY or PHY-specific integration layer.

### Keep Swing and Margin Independent from De-emphasis

The controller should also avoid combining swing and de-emphasis into a single abstract "TX amplitude" setting.

For example:

```text
TxSwing
    -> selects broad amplitude mode

TxMargin
    -> requests overall amplitude level

TxDeemph
    -> selects relative waveform shaping
```

A change to `TxDeemph` does not imply that `TxMargin` must change, and a margin test does not inherently require a different de-emphasis mode.

### Do Not Treat TxSwing as a Generation Selector

The following interpretation is incorrect:

```text
Gen1 -> full swing
Gen2 -> low swing
```

Both generations can operate with full swing. Low swing is an optional signaling mode rather than a Gen2 requirement. 

## Common Misunderstandings

### De-emphasis Does Not Specify an Absolute Voltage

`-3.5 dB` and `-6 dB` are amplitude ratios. They define how much the de-emphasized portion of the waveform is reduced relative to the full-amplitude level.

For example:

$$
-3.5\text{ dB} \approx 67\%
$$

and

$$
-6\text{ dB} \approx 50\%
$$

They do not mean that the transmitter outputs a particular fixed number of millivolts.

### Stronger De-emphasis Means a More Negative dB Value

Because the de-emphasis values represent attenuation,

```text
-3.5 dB -> approximately 67%
-6.0 dB -> approximately 50%
```

Therefore `-6 dB` is the stronger de-emphasis setting.

### De-emphasis Does Not Necessarily Boost Above Maximum Swing

The transition level should generally be viewed as the full-amplitude reference, with repeated bits attenuated below that level. The tap-filter model can mathematically produce an `A+B` term at a transition, but this does not require interpreting the physical transmitter as exceeding its specified full output swing. 

### TxMargin Is Not a Gen1/Gen2 Selector

Normal operation for both generations can use:

```systemverilog
TxMargin = 3'b000;
```

A different margin value is requested for deliberate transmitter-voltage characterization, not merely because the signaling rate changes.

### TxMargin Codes Are Not Eight Fixed Universal Voltages

Some margin encodings are implementation-defined. A controller should not assume a universally linear or fixed mapping between `TxMargin[2:0]` and millivolts.

### TxSwing and TxMargin Are Not Equivalent

`TxSwing` selects the broad voltage family. `TxMargin` controls or margins the voltage within the supported family.

A useful hierarchy is:

```text
TxSwing
    |
    v
Choose voltage family
    |
    v
TxMargin
    |
    v
Choose/request voltage level
```

### TxDeemph Is Different from Both

Neither `TxSwing` nor `TxMargin` performs the transition-versus-repeated-bit shaping associated with de-emphasis.

```text
TxSwing  -> full-swing or low-swing family

TxMargin -> overall voltage level

TxDeemph -> transition/repeated-bit amplitude ratio
```

## Summary

PCIe Gen1/Gen2 transmitter electrical control is divided among three conceptually distinct mechanisms.

`TxDeemph` compensates for frequency-dependent channel loss. It shapes the transmitted waveform so that transition symbols remain at the full level while repeated symbols are attenuated. In the Gen1/Gen2 PIPE context described here, the available settings are `-3.5 dB` and `-6 dB`, corresponding to repeated-bit amplitudes of approximately 67% and 50% of the full-amplitude level, respectively.

A simple two-tap model,

$$
y[n]=A x[n]-B x[n-1]
$$

explains the behavior. Repeated symbols produce a magnitude proportional to \(A-B\), whereas transitions produce a magnitude proportional to \(A+B\). The physical result is relative emphasis of transitions and reduced susceptibility to channel-induced ISI.

`TxMargin` controls a different property: the overall transmitter differential amplitude. It is primarily useful for validation, compliance, characterization, and voltage-margin testing. Normal Gen1 and Gen2 operation can use `TxMargin = 3'b000`; other values request alternate or reduced voltage levels, some of which may be PHY-specific.

`TxSwing` selects the broad transmitter amplitude family. `TxSwing = 0` represents full swing, while `TxSwing = 1` represents an optional low-swing mode in the Gen1/Gen2 context described by the source.

The relationship among the three controls is therefore:

```text
TxSwing
    -> choose broad TX voltage family

TxMargin
    -> choose or margin the overall voltage level

TxDeemph
    -> shape transition versus repeated-bit amplitude
```

For a straightforward Gen1/Gen2 PIPE controller operating normally, a practical baseline is:

```systemverilog
TxSwing  = 1'b0;      // Full swing
TxMargin = 3'b000;    // Normal transmitter voltage
```

with `TxDeemph` controlled independently according to the required Gen1 or Gen2 de-emphasis behavior. 
