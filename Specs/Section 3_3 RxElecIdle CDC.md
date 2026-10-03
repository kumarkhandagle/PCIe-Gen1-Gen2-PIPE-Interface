What could we improve in our RxElecIdle handling?**

In the previous lecture, we described filtering the PHY’s `RxElecIdle` signal first and then passing the filtered value through a two-flop synchronizer.

However, `RxElecIdle` is asynchronous to `pclk`, and our filter uses `pclk` to sample and compare it.

**Your challenge**

Identify the potential CDC problem in this arrangement. Suggest an improved order for synchronization and filtering.

Also consider: If we check a signal once, wait several cycles, and check it again, does that prove it remained stable throughout the waiting period?

**Hints**

1. Which flip-flop first receives the asynchronous signal?
2. Should comparison and counter logic use the raw signal or the synchronizer’s final output?
3. What should happen to the counter if the signal returns to its previously accepted value?
4. Could the signal change several times between the first and last checks?

**More information: The problem**

A clocked filter that directly uses asynchronous `RxElecIdle` exposes its sampling registers to metastability. A synchronizer placed afterward does not protect the filter’s earlier decisions.

Sampling an asynchronous signal is necessary at the **first synchronizer stage**. The problem is allowing ordinary filter or control logic to use it before synchronization.

There is another weakness: checking only the beginning and end of a waiting period does not establish continuous stability. The sampled sequence could be `1, 1, 0, 1`; its first and last values match despite an interruption.

**Suggested solution**

Continuously pass `RxElecIdle` through the two-flop synchronizer. Use only the second stage’s output for filtering.

On every rising `pclk` edge:

1. Compare the synchronized value with the value currently delivered to the MAC.
2. If they match, clear the counter.
3. If they differ, count consecutive samples of the new value.
4. Update the MAC output only after the configured number of consecutive samples.
5. If the synchronized value returns to the accepted value before qualification completes, clear the counter and require a fresh qualification period.
