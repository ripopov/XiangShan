# Chapter 7. Why Processors Need an Instruction Cache

Chapter 6 explained how the Fetch Target Queue (FTQ) predicts and buffers the sequence of addresses the processor should execute. But addresses are not instructions. The processor must actually read the instruction bytes from memory before it can decode and execute them.

This creates an immediate physical problem: the "Memory Wall."

### ASCII Mental Model (Read This First)

```text
Without ICache:                              With ICache:

 Processor (3 GHz)                            Processor (3 GHz)
 ┌─────────┐                                  ┌──────────────┐
 │ FTQ req │───┐                              │ FTQ req      │───┐
 └─────────┘   │                              └──────────────┘   │
               │ wait 200 cycles                             wait 1 cycle
               ▼                                                 ▼
 ┌───────────────────────────┐                ┌──────────────┐   │
 │ Main Memory (DRAM)        │                │ L1 ICache    │◄──┘
 │ 100 ns latency            │                │ 64KB, SRAM   │
 │ Huge capacity (GBs)       │                │ 1 ns latency │
 └───────────────────────────┘                └──────────────┘
                                                     ▲
                                                     │ wait 200 cycles (only on miss)
                                                     ▼
                                              ┌───────────────────────────┐
                                              │ Main Memory (DRAM)        │
                                              └───────────────────────────┘
```

**The Instruction Cache (ICache) sits between the fast processor and slow main memory. It stores small chunks of recently used code so that most fetch requests can be answered in a single cycle, keeping the processor fed with instructions.**

---

## 7.1 The Bandwidth and Latency Problem

### 7.1.1 What Goes Wrong Without an ICache

A modern superscalar processor like XiangShan attempts to decode and execute 6 to 8 instructions every clock cycle. At a clock frequency of 3 GHz, the processor needs a new block of instructions every 0.33 nanoseconds.

Main memory (DRAM) takes roughly 100 nanoseconds to respond to a read request. That is 300 processor clock cycles.

If the processor fetched instructions directly from main memory:
1. The FTQ predicts the next fetch address.
2. The processor sends a read request to DRAM.
3. The entire pipeline sits idle for 300 cycles waiting for the bytes to arrive.
4. The bytes arrive, the processor decodes 8 instructions (taking 1 cycle), and then immediately stalls for another 300 cycles to fetch the next sequential block.

The processor would spend 99.6% of its time waiting for memory. Its effective speed would drop from 3 GHz to 10 MHz.

### 7.1.2 The Principle of Locality

Why can we solve this problem? Because computer programs do not access memory randomly. They exhibit **locality**:

- **Temporal Locality**: If an instruction is executed, it is likely to be executed again soon (e.g., instructions inside a `for` or `while` loop).
- **Spatial Locality**: If an instruction at address $A$ is executed, the instruction at address $A+4$ is likely to be executed soon (e.g., sequential execution within a basic block).

The Instruction Cache exploits both types of locality. It uses fast, on-chip SRAM to store copies of the instructions that were recently fetched from main memory. Because SRAM is physically close to the processor core and built with fast transistors, it can respond in a single clock cycle.

---

## 7.2 Design It Yourself: From Naive to Real

Given the latency gap, how do we design the memory structure that sits next to the core? Let us build it up layer by layer.

### Layer 1: The Single-Entry Cache (The Bookmark)

The simplest possible cache holds exactly one fixed-size chunk of memory, called a **cache line** or **cache block** (typically 64 bytes).

Every time the FTQ requests an address, we check our single entry:
1. Does the requested address fall within the 64-byte chunk we are currently holding?
2. If yes (**Cache Hit**): Return the bytes immediately.
3. If no (**Cache Miss**): Pause the processor, fetch the new 64-byte chunk from main memory, overwrite our single entry, and then return the bytes.

**What breaks:** This exploits spatial locality beautifully (fetching 64 bytes at once covers 16 sequential 32-bit instructions). But it has terrible temporal locality. If a loop spans two consecutive 64-byte blocks, the cache will thrash back and forth, missing on every single fetch.

### Layer 2: Direct-Mapped Structure (The Filing Cabinet)

To hold more than one cache line, we need a way to organize them so we can find them quickly. We divide our SRAM into an array of $N$ slots (e.g., 256 slots).

How do we decide which memory address goes into which slot? We use the middle bits of the address as an **Index**.

```text
Address (e.g., 39 bits):
  ┌───────────────────────┬───────────┬──────────────┐
  │ Tag (27 bits)         │ Index (6) │ Offset (6)   │
  └───────────────────────┴───────────┴──────────────┘
                               │             │
                    Selects 1 of 64 slots    │
                                             └── Selects byte within the 64B cache line
```

When a fetch request arrives:
1. Extract the Index bits to find the correct slot in the SRAM.
2. Compare the upper Tag bits of the requested address with the Tag stored in that slot.
3. If the Tags match and the slot is valid, it is a hit. Extract the data using the Offset bits.

**What breaks:** This is a **Direct-Mapped Cache**. Every memory address can only live in exactly one specific slot in the cache. If a program frequently jumps between two different memory addresses that happen to have the *same Index* but different Tags, they will constantly overwrite each other in that single slot. This is called a **conflict miss**. Even if the rest of the 255 slots are completely empty, the cache will thrash.

### Layer 3: Set-Associative Structure (The Multi-Drawer Cabinet)

To fix conflict misses, we change the rule: instead of each Index points to a single slot, an Index points to a **Set** of slots (called **Ways**).

In a **4-Way Set-Associative Cache**:
1. The Index selects a Set.
2. The Set contains 4 parallel slots (Ways).
3. We read all 4 Ways simultaneously and check all 4 Tags in parallel.
4. If any of the 4 Tags match, we have a hit and we mux out the data from that specific Way.

If a new cache line needs to be loaded and all 4 Ways are full, a **Replacement Policy** (like Least Recently Used, LRU) decides which of the 4 ways to evict.

**What breaks:** This solves conflict misses, but it introduces a timing problem for modern OS environments. The CPU generates **Virtual Addresses**, but main memory uses **Physical Addresses**. To do the Tag comparison, we first have to translate the Virtual Address to a Physical Address using the Translation Lookaside Buffer (TLB). Doing TLB translation *and then* waiting for the SRAM read *and then* doing the Tag compare takes too long for a 1-cycle latency requirement.

### Layer 4: VIPT Caching (Virtual Index, Physical Tag)

To hide the TLB translation latency, we overlap the SRAM array read with the TLB lookup.

We size the cache such that the Index bits come entirely from the page offset (the bits of the address that do not change during virtual-to-physical translation, usually the bottom 12 bits for 4KB pages).

```text
Cycle 1 Start:
  Virtual Address provided by FTQ.

Parallel Operations:
  [Path A] Use bottom 12 bits (Virtual Index) to start reading the SRAM Data and Tag arrays.
  [Path B] Send upper bits (Virtual Page Number) to TLB for translation.

Cycle 1 End:
  [Path A] returns 4 Tags and 4 Data blocks.
  [Path B] returns 1 Physical Page Number.
  Combine: Compare the returned Physical Page Number against the 4 SRAM Tags.
  If match: Hit!
```

This is called **Virtual Index, Physical Tag (VIPT)**. It gives us the speed of virtual addressing with the correctness (no aliasing) of physical addressing.

**What breaks:** The CPU now fetches quickly, but what happens on a miss? If the cache misses, it sends a request to main memory. In a basic pipeline, the entire processor front-end stalls until memory replies. If the FTQ knows we need to fetch blocks A, B, and C, and block A misses in the cache, the cache stalls. It cannot even begin looking up block B or C until A returns 300 cycles later.

### Layer 5: Non-Blocking Misses (Miss Status Holding Registers)

To prevent the entire fetch engine from locking up on a single miss, the cache must be **non-blocking**.

When a miss occurs, the cache allocates an entry in a structure called a **Miss Status Holding Register (MSHR)**. The MSHR tracks:
- The missing physical address.
- That a request has been sent to the memory subsystem.

Because the miss is recorded in the MSHR, the cache is free to accept the *next* fetch request from the FTQ in the very next cycle. If the next request is a hit, the cache returns data immediately while the first miss is still being serviced in the background.

If the cache receives a request for an address that is *already missing* (e.g., the FTQ requested the same instruction again due to a loop rewinding), the cache checks the MSHR, sees the request is already in flight, and merges the new request into the existing MSHR entry rather than sending a duplicate request to memory.

### Layer 6: Hardware Prefetching

Even with MSHRs, an initial miss still means the CPU must wait 300 cycles before it can execute those specific instructions.

The final layer is **Prefetching**. If the ICache notices the FTQ requesting block $X$, it can guess that the FTQ will soon ask for block $X+1$. The ICache can autonomously allocate an MSHR and send a memory request for $X+1$ *before* the FTQ ever asks for it.

By the time the FTQ actually needs $X+1$, the data has already arrived from main memory and is waiting in the SRAM array. The latency is entirely hidden.

---

## 7.3 The "Baggage Tag" Analogy: Decoupling Metadata from Data

A high-performance ICache looks up tags, checks permissions (PMP), checks translations (ITLB), and reads raw data bytes. Doing all of this tightly coupled in a single stage creates severe timing pressure at high clock speeds.

To solve this, advanced designs decouple the **Metadata** (Tags, TLB, Permissions) from the **Data** (the actual instruction bytes).

Think of checking in luggage at an airport:
1. **The Metadata Check (Check-in counter):** The agent checks your passport (TLB/Permissions), weighs your bag, and attaches a routing tag (the Way ID). This takes time.
2. **The Data Path (The conveyor belt):** The baggage handlers don't need to check your passport again. They just look at the routing tag and throw the bag on the right plane. This is very fast.

In a decoupled ICache:
- A **Prefetch/Metadata Pipeline** runs ahead. It talks to the TLB, reads the Tag SRAM, confirms permissions, and determines exactly which Way in the Data SRAM holds the instructions. It writes this "baggage tag" (the Way ID and Physical Tag) into a small decoupling queue.
- The **Main Data Pipeline** comes behind it. It pops the "baggage tag" from the queue, uses the pre-computed Way ID to read the Data SRAM directly, and returns the bytes to the processor.

This allows the Main Pipeline—which feeds the processor—to be extremely short and fast, while the complex translation and permission checks are hidden in the decoupled metadata pipeline.

---

## 7.4 Conceptual Worked Examples

### Example 1: A Successful Single-Line Hit

**Scenario:** The FTQ requests an instruction at a newly predicted target. The instruction is fully contained within a single 64-byte cache line. The data was recently executed and is in the cache.

1. **Request:** The FTQ provides the Virtual Address to the ICache.
2. **Metadata Lookup:** The ICache uses the Virtual Index to read its Tag arrays. Simultaneously, the TLB translates the Virtual Page Number into a Physical Page Number.
3. **Compare & Way Selection:** The Physical Page Number from the TLB is compared against the Tags read from the 4 ways of the cache set. Way 2 matches. Permissions are verified.
4. **Data Read:** The ICache knows the data is in Way 2. It reads the data SRAM for Way 2 using the instruction's Offset.
5. **Response:** The 64-byte block (or the specific requested fraction of it) is sent to the Instruction Fetch Unit (IFU) for decoding.

### Example 2: Miss, MSHR Allocation, and Refill

**Scenario:** The FTQ requests code that hasn't been executed in a long time. It is not in the cache.

1. **Request & Lookup:** The FTQ requests the address. The TLB translates it, but none of the 4 Tags in the selected set match.
2. **Miss Detection:** A cache miss is declared.
3. **MSHR Allocation:** The ICache allocates an idle MSHR to track this request. The MSHR sends a read request (via the memory bus, e.g., TileLink) to the L2 Cache / Main Memory.
4. *(Time Passes)*: For many cycles, the ICache cannot return this data. It may serve other FTQ requests if they hit, or stall the IFU if the FTQ demands this specific instruction next.
5. **Data Arrival (Refill):** The memory bus returns the 64-byte block.
6. **Cache Update:** The ICache writes the new data into the Data SRAM and updates the Tag SRAM with the new Physical Tag (evicting an old block if necessary using LRU).
7. **Response:** The MSHR is freed, and the newly arrived data is forwarded to the IFU.

### Example 3: The Cross-Boundary Fetch

**Scenario:** The processor's architecture supports fetching wide blocks of data (e.g., 32 bytes) per cycle to boost throughput. The FTQ requests a 32-byte window starting at byte offset 48 of a 64-byte cache line.

1. **The Boundary Problem:** The 32-byte request spans from byte 48 to byte 80. Bytes 48-63 live in Cache Line $A$. Bytes 64-80 live in the next sequential Cache Line, $B$.
2. **Dual-Bank Lookup:** A high-bandwidth ICache organizes its SRAM arrays into multiple independent banks. It simultaneously looks up Cache Line $A$ (in Bank 0) and Cache Line $B$ (in Bank 1).
3. **Partial Miss:** Line $A$ hits in the cache, but Line $B$ misses.
4. **Resolution:** The ICache cannot return the full 32 bytes requested. It allocates an MSHR to fetch Line $B$ from memory. It must wait until Line $B$ arrives before it can stitch the bytes from $A$ and $B$ together and fulfill the single wide request to the IFU.

---

## 7.5 Design Trade-offs

| Design Choice | Benefit | Cost / Drawback |
| :--- | :--- | :--- |
| **VIPT (Virtual Index, Physical Tag) vs. PIPT** | Faster hit latency. TLB translation and SRAM read happen in parallel. | The cache capacity is limited by the page size. If you want a cache larger than PageSize * Ways, you risk "aliasing" (the same physical address mapping to multiple cache sets). |
| **Unified vs. Decoupled Lookups** | Unified is conceptually simpler and has fewer queueing structures. | Decoupled isolates the critical data-read path from the complex translation/permission path, allowing for higher core clock frequencies. |
| **More MSHRs** | Better tolerance of memory latency. The cache can track more simultaneous missing lines before stalling. | Increased area and power. Complex arbitration logic to manage multiple in-flight memory responses and dependency wakeups. |
| **Dedicated Prefetch MSHRs vs. Unified Pool** | Prevents aggressive hardware prefetching from consuming all MSHRs and starving actual demand fetches. | May underutilize resources if the workload has few prefetches but high demand-miss parallelization requirements. |

---

## 7.6 Checkpoint Questions

1. **Basic:** Why must an Instruction Cache use Physical Tags (VIPT) instead of purely Virtual Tags (VIVT)? What operating system event makes VIVT caches difficult to manage?
2. **Intermediate:** Explain the difference between a Conflict Miss and a Capacity Miss. How does increasing set-associativity address one but not the other?
3. **Intermediate:** Why is a non-blocking cache (using MSHRs) essential for a superscalar out-of-order processor, even if the instructions themselves must eventually execute in order?
4. **Advanced:** Assume a VIPT cache with a 4KB page size, 64-byte lines, and 4 ways. What is the maximum size (in KB) this cache can be before it requires complex aliasing-detection logic? Show your math.

---

## 7.7 Key Takeaways

- The Instruction Cache bridges the orders-of-magnitude latency gap between the processor core and main memory by exploiting spatial and temporal locality.
- Structurally, it relies on Set-Associativity to avoid conflict misses and VIPT (Virtual Index, Physical Tag) parallel lookups to achieve single-cycle hit latencies.
- MSHRs (Miss Status Holding Registers) are the key to making the cache non-blocking, allowing it to service new hits and track multiple in-flight misses simultaneously.
- High-performance designs decouple metadata lookup from data readout to ease timing pressure, and aggressively employ hardware prefetching to hide miss latency before the processor even knows it needs the data.

---

Transition to Chapter 7a:
Chapter 7a dives into how XiangShan's Kunminghu core implements these theoretical concepts in concrete RTL, detailing its decoupled `MainPipe` and `PrefetchPipe`, interleaved metadata banks, and specific MSHR handling.
