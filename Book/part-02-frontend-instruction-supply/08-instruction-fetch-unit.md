# Chapter 8. Why Processors Need an Instruction Fetch Unit

Chapter 5 explained how the branch predictor guesses where to fetch next. Chapter 6 showed how the
Fetch Target Queue buffers those guesses, manages speculation, and coordinates recovery. Chapter 7
described how the instruction cache stores and delivers instruction bytes. But bytes are not
instructions. The instruction cache returns a raw block of memory — 64 bytes, say — and somewhere
inside that block lie a variable number of instructions with variable lengths, some of which the
branch predictor may have gotten wrong. The backend decode stage expects a clean, ordered stream of
individual instruction entries, each with its own PC, its own validity flag, and its own
branch-prediction metadata.

Something must bridge that gap. That something is the **Instruction Fetch Unit (IFU)**.

### ASCII Mental Model (Read This First)

```text
Without IFU:                                 With IFU:

 ICache                  Decode               ICache           IFU              Decode
 ┌──────────────────┐   ┌──────────┐          ┌────────────┐  ┌────────────┐  ┌──────────┐
 │ 64 raw bytes     │──>│ ???      │          │ 64 raw     │─>│ boundary   │─>│ clean    │
 │ (mixed 16b/32b)  │   │ where do │          │ bytes      │  │ detect     │  │ instr    │
 │ (half instr at   │   │ instrs   │          │            │  │ compact    │  │ entries  │
 │  block end)      │   │ start?   │          │            │  │ align      │  │ with PCs │
 │ (wrong-path      │   │ which    │          │            │  │ verify     │  │ & valid  │
 │  bytes mixed in) │   │ are      │          │            │  │ prediction │  │ flags    │
 │                  │   │ valid?   │          │            │  │ expand RVC │  │          │
 └──────────────────┘   └──────────┘          └────────────┘  └────────────┘  └──────────┘
                                                                    │
 Result: decode confusion,                          Redirect ──────>│ FTQ
 wasted cycles, wrong-path                          (on pred fault) │
 pollution
```

**The IFU transforms raw, variable-length, speculatively fetched bytes into a precise, aligned,
verified instruction stream that the backend can consume at full bandwidth.**

---

## 8.1 The Raw-Bytes Problem

### 8.1.1 What Goes Wrong Without an IFU

Imagine connecting the instruction cache directly to the decode stage. The cache delivers a
64-byte block of raw memory. The decoder needs to know three things about each instruction:
where does it start, how long is it, and is it on the correct execution path? Without dedicated
logic to answer these questions, three problems arise immediately.

**Problem 1: Variable-length instructions.**
RISC-V with the compressed extension (RVC) mixes 16-bit and 32-bit instructions freely within
a single fetch block. A 64-byte block can contain anywhere from 16 instructions (all 32-bit) to
32 instructions (all 16-bit), or any combination in between. The decoder cannot simply slice the
block into fixed-width slots — it must determine where each instruction begins by examining the
low bits of each halfword. An instruction whose low two bits are `11` is 32 bits wide; otherwise
it is 16 bits wide. This scan is inherently serial: the start of instruction N+1 depends on the
length of instruction N.

**Problem 2: Instructions that span fetch-block boundaries.**
A 32-bit instruction can straddle two consecutive fetch blocks. The last two bytes of block A
contain the first half of the instruction, and the first two bytes of block B contain the second
half. Without state carried between fetch cycles, this instruction is lost — it will appear as
two invalid fragments, one at each block boundary.

**Problem 3: Wrong-path bytes mixed in.**
The fetch block was requested based on a branch prediction. If the predictor said "taken at byte
offset 20," then only the first 20 bytes contain useful instructions. The remaining 44 bytes are
past the predicted control-flow boundary and should not be decoded. Without a mechanism to mask
or trim the block, the decoder will attempt to process garbage, potentially raising spurious
exceptions or corrupting pipeline state.

### 8.1.2 Quantifying the Cost

Each of these problems, left unaddressed, causes measurable performance loss:

- **Boundary errors** cause the decoder to misparse an instruction, triggering an illegal-
  instruction exception or silently producing a wrong opcode. Recovery requires a pipeline flush —
  typically 10–20 cycles on a deep out-of-order machine.

- **Lost cross-block instructions** mean one instruction per boundary-crossing fetch is never
  executed. In RVC-heavy code (which is common, since compilers preferentially emit compressed
  instructions), roughly 1 in 16 fetch blocks ends with a half-instruction. At 1 GHz with one
  fetch per cycle, that is ~60 million lost instructions per second.

- **Wrong-path decode** wastes decode bandwidth and can fill downstream buffers with useless
  entries, backpressuring the frontend and delaying correct-path instructions. Studies of
  speculative processors show that wrong-path pollution can reduce effective IPC by 5–15% even
  with good branch prediction.

---

## 8.2 Design It Yourself: From Naive to Real

Given these constraints, how would you design the logic between cache and decode? Let us build up
the solution layer by layer, exposing each failure mode before adding the fix.

### Layer 1: Fixed-width slicing (naive)

The simplest approach: treat every 32 bits as one instruction.

```text
  Fetch block (64 bytes):
  ┌────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┐
  │ W0 │ W1 │ W2 │ W3 │ W4 │ W5 │ W6 │ W7 │ W8 │ W9 │W10 │W11 │W12 │W13 │W14 │W15 │
  └────┴────┴────┴────┴────┴────┴────┴────┴────┴────┴────┴────┴────┴────┴────┴────┘
  Slice into 16 fixed 32-bit slots → 16 instructions max
```

**What breaks:** With RVC, two consecutive 16-bit instructions occupy one 32-bit slot. Fixed
slicing treats them as one instruction, missing half the code. RISC-V code compiled with `-march`
including `c` (compressed) typically has 40–60% compressed instructions. Fixed-width slicing would
lose nearly half the instruction stream.

### Layer 2: Boundary detection

Scan the fetch block at 16-bit granularity. For each halfword, check bits [1:0]: if both are `1`,
the halfword is the start of a 32-bit instruction (consuming this halfword and the next); otherwise
it is a complete 16-bit instruction.

```text
  Halfword positions:     0     1     2     3     4     5     6     7     8
                       ┌───────────┬─────┬───────────┬─────┬─────┬───────────┐
  Instruction size:    │  32-bit   │ 16b │  32-bit   │ 16b │ 16b │  32-bit   │ ...
                       └───────────┴─────┴───────────┴─────┴─────┴───────────┘
  Starts vector:          1     0     1     1     0     1     1     1     0
  Ends vector:            0     1     1     0     1     1     1     0     1
```

This produces an *instruction-valid vector* (which halfword positions are instruction starts) and
an *instruction-end vector* (which positions are instruction ends). Together they define every
instruction in the block.

**What breaks:** Consider the last halfword of the block. If it is the first half of a 32-bit
instruction, the second half lives in the *next* fetch block. Boundary detection within a single
block cannot see across the boundary. It will either flag the half-instruction as invalid (losing
it) or treat it as a 16-bit instruction (misparsing it).

### Layer 3: Cross-block carry state

To handle boundary-spanning instructions, the IFU must remember state from the previous fetch
cycle. Specifically, it needs to know:

- Whether the last halfword of the previous block was the first half of a 32-bit instruction (a
  **half-instruction flag**).
- If so, the actual data of that halfword (the **half-instruction data**), which must be
  concatenated with the first halfword of the current block to form a complete 32-bit instruction.

```text
  Fetch cycle T:
  ┌──────┬──────┬──────┬──────┐
  │ ...  │ H29  │ H30  │ H31  │  <-- H31: first half of 32-bit instruction
  └──────┴──────┴──────┴──────┘

  IFU carried state: [ prevHalf = true, prevHalfData = H31 ]

  Fetch cycle T+1:
  ┌──────┬──────┬──────┬──────┐
  │  H0  │  H1  │  H2  │ ...  │  <-- H0: second half of the same instruction
  └──────┴──────┴──────┴──────┘
     │                    
     └─> Reconstruction: instr_0 = {H0, H31} (complete 32-bit instruction)
```

**What breaks:** Bandwidth utilization. The boundary detector successfully identifies instructions, but leaves them scattered at arbitrary positions within the 32-slot halfword array due to their mixed 16/32-bit sizes. Furthermore, if the branch predictor anticipates a "taken" branch in the middle of the block, all subsequent slots become invalid wrong-path bytes that must be ignored.
As a result, valid instructions are sparse and irregularly spaced, full of gaps. Feeding this "Swiss cheese" array directly to a fixed-width downstream consumer (like Decode or IBuffer) is incredibly wasteful, as many costly processing lanes would simply be carrying empty slots.

### Layer 4: Compaction and alignment

**Compaction** solves the "Swiss cheese" problem. It takes the sparse, discontinuous sequence of valid instructions and maps them into a dense, contiguous output array. If the raw block contains valid instructions at scattered positions {1, 2, 4, 5, 6, 8, 10, 11, 12}, compaction strips away their original coordinates and assigns them to tightly packed output slots {0, 1, 2, 3, 4, 5, 6, 7, 8}.

**Alignment** comes immediately after. The newly compacted stream of instructions needs to be written into the downstream buffer (IBuffer). This buffer is divided into parallel writing banks, and its write pointer is not always conveniently waiting at bank 0. If the next available bank is bank 2, the alignment logic takes the compacted array and barrel-shifts (rotates) it right by 2. This ensures that instruction 0 aligns perfectly into bank 2, instruction 1 into bank 3, and so on, keeping lane utilization at maximum efficiency across every cycle.

```text
  ┌────────────────────────────────────────────────────────┐
  │ Raw slots from detector:                               │
  │ [   ] [ I0] [ I1] [   ] [ I2] [ I3] [ I4] [   ] [ I5]  │
  └────────────────────────────────────────────────────────┘
                              ▼ Compaction (stripping gaps)
  ┌────────────────────────────────────────────────────────┐
  │ Compacted slots:                                       │
  │ [ I0] [ I1] [ I2] [ I3] [ I4] [ I5] [   ] [   ] [   ]  │
  └────────────────────────────────────────────────────────┘
                              ▼ Alignment (right shift +2)
  ┌────────────────────────────────────────────────────────┐
  │ Final IBuffer write:                                   │
  │ [ I4] [ I5] [ I0] [ I1] [ I2] [ I3] [   ] [   ] [   ]  │
  └────────────────────────────────────────────────────────┘
    Bank0 Bank1 Bank2 Bank3 Bank4 Bank5 Bank6 Bank7 Bank8
```

**What breaks:** The instruction stream is now clean and dense, but it is based entirely on the
branch predictor's claim about which instructions are on the correct path. If the predictor
predicted a taken branch at the wrong position — or predicted a branch at a non-branch instruction
— the IFU is feeding wrong-path instructions to the backend. The backend will eventually discover
the error, but by then it may have decoded and dispatched dozens of useless instructions.

### Layer 5: Early prediction verification

The final layer adds a **prediction checker** inside the IFU. After boundary detection reveals
which halfwords are instructions, a lightweight pre-decoder classifies each instruction: is it a
branch? A jump? A return? The checker then compares this classification against what the branch
predictor claimed:

- Did the predictor say "taken" at an instruction that is not a control-flow instruction?
  → **NotCFI fault**: the predictor was wrong; the correct action is to continue sequentially.
- Did the predictor say "taken" for a JAL, but the computed target does not match the predicted
  target? → **Target fault**: the predictor used a stale or aliased target.
- Did the predictor miss a taken branch entirely? → **InvalidTaken fault**: the predictor failed
  to predict a branch that pre-decode can tell is unconditionally taken (e.g., a JAL).

When the checker detects a fault, it generates a **redirect** back to the Fetch Target Queue,
correcting the fetch stream *before* the backend sees the error. This shortens the wrong-path
window from potentially dozens of cycles (backend execution latency) to just a few cycles (IFU
pipeline depth).

This is the complete IFU design: five layers, each addressing a specific failure mode of the
previous layer.

> *Chapter 8a describes how Kunminghu implements each of these layers in RTL, including the
> specific pipeline stages and submodules.*

---

## 8.3 The Quality-Control Conveyor Analogy

Think of the IFU as a quality-control conveyor belt between a warehouse (the instruction cache)
and an assembly line (the decode stage).

```text
  Warehouse             Quality-Control Conveyor                    Assembly Line
  (ICache)              (IFU)                                       (Decode/IBuffer)
  ┌──────────┐   ┌──────────────────────────────────────────┐   ┌──────────────┐
  │          │   │  ┌─────┐  ┌─────┐  ┌─────┐  ┌─────┐    │   │              │
  │ Raw      │──>│  │Sort │─>│Pack │─>│Check│─>│Label│    │──>│ Ready-to-use │
  │ crates   │   │  │     │  │     │  │     │  │     │    │   │ parts        │
  │          │   │  └─────┘  └─────┘  └─────┘  └─────┘    │   │              │
  └──────────┘   └──────────────────────────────────────────┘   └──────────────┘
                  Station 1  Station 2 Station 3 Station 4
                  (boundary  (compact  (predict  (RVC
                   detect)    +align)   check)    expand)
```

- **Station 1 (Sorting):** Inspectors examine each crate (halfword) and determine whether it is a
  whole item (16-bit instruction) or part of a larger item (first/second half of a 32-bit
  instruction). They also check if a partial item was left over from the previous shipment
  (half-instruction carry).

- **Station 2 (Packing):** Items are packed tightly into standard-sized trays (compacted lanes)
  with no gaps, then rotated so they align with the assembly line's current intake position.

- **Station 3 (Quality check):** Each item is spot-checked against the shipping manifest (branch
  prediction). If the manifest says "this is a branch target" but the item is not a branch, the
  inspector flags the error and sends a correction notice back to the shipping department (FTQ
  redirect).

- **Station 4 (Labeling):** Compressed items (RVC instructions) are expanded into their full-size
  equivalents so the assembly line handles only one instruction format.

**Where the analogy breaks down:** A real conveyor belt does not need to handle speculative
rewinding. When the IFU's quality check detects a prediction error, it does not just flag the
error — it sends a redirect signal that causes the entire frontend to rewind and restart from a
different address. This speculative recovery mechanism has no physical-world counterpart on a
simple conveyor.

---

## 8.4 Instruction Boundary Detection Under Variable-Length Encoding

### 8.4.1 The RISC-V Compressed Extension Recap

The RISC-V C extension defines 16-bit compressed instructions alongside the standard 32-bit
instructions. The encoding rule is simple: if bits [1:0] of a halfword are both `1` (i.e., the
value is `11` in binary), the instruction is 32 bits wide and consumes this halfword plus the
next. Otherwise, the instruction is 16 bits wide and consumes only this halfword.

```text
  16-bit Instruction (Compressed - RVC)
  ┌────────────────────────┬──────┐
  │     Opcode / Args      │ !=11 │ (bits [1:0] are 00, 01, or 10)
  └────────────────────────┴──────┘
  15                           1  0
  └────── 1 halfword ───────┘

  32-bit Instruction (Standard)
  ┌─────────────────────────────────────────┬──────┐
  │                 Opcode / Args           │  11  │ (bits [1:0] are strictly 11)
  └─────────────────────────────────────────┴──────┘
  31                                           1  0
  └────────────── 2 halfwords ──────────────┘
```

### 8.4.2 Scanning Algorithm

Given a fetch block with N halfwords, the boundary detection algorithm produces two bit-vectors:

- **instrValid[0..N-1]**: `1` at each halfword position that is the *start* of a valid
  instruction.
- **instrEnd[0..N-1]**: `1` at each halfword position that is the *last halfword* of a valid
  instruction.

The scan is a left-to-right walk:

```text
  pos = 0
  while pos < N:
    instrValid[pos] = 1
    if halfword[pos][1:0] == 0b11:   // 32-bit instruction
      instrEnd[pos+1] = 1
      pos += 2
    else:                              // 16-bit instruction
      instrEnd[pos] = 1
      pos += 1
```

The serial dependency (each step depends on the previous instruction's length) is a concern for
timing. In a 32-halfword block, the naive scan is a 32-step carry chain — far too slow for a
single-cycle computation at high clock rates.

### 8.4.3 Breaking the Serial Chain: Speculative Parallel Evaluation

The key insight is that the carry chain has a binary input at each step: the current halfword is
either 16-bit (carry advances by 1) or 32-bit (carry advances by 2). This means the entire
second half of the block has only two possible boundary maps, depending on whether the first half
ends cleanly (at an instruction boundary) or mid-way through a 32-bit instruction.

The hardware exploits this by **splitting the block in half and computing both halves in
parallel**:

```text
            [Fetch block: 32 halfwords]
           /                           \
    Half 0 (slots 0..15)            Half 1 (slots 16..31)
  ┌────────────────────────┐      ┌────────────────────────┐
  │ Base computation:      │      │ Speculative TWICE      │
  │ Using known carry-in   │      │ computation:           │
  │ from the previous      │      │ ├─ Branch A: carry = 0 │
  │ cycle                  │      │ └─ Branch B: carry = 1 │
  └──────────┬─────────────┘      └───────────┬────────────┘
             │                                │
      [Boundaries 0..15]                      │
             │                                │
         Carry-out ───────────────────────> Multiplexer
         (0 or 1)                             │
                                     [Boundaries 16..31]
```

The first half computes its boundary map using the known carry-in (from the previous fetch
block's half-instruction state). While this runs, the second half speculatively computes *two*
boundary maps — one assuming the first half ends cleanly, one assuming it ends mid-RVI. When the
first half's carry-out is known, a simple mux selects the correct second-half result.

This doubles the hardware (two copies of the second-half logic) but cuts the critical path nearly
in half — from a 32-step chain to a 16-step chain plus a mux. The technique generalizes: with
more splits, the chain can be shortened further at the cost of exponentially more speculative
copies. Two-way splitting is the practical sweet spot for typical fetch block sizes.

This is a classic circuit design technique called **speculative parallel evaluation** (sometimes
"conditional-sum" or "carry-select"). It appears in adders, priority encoders, and any logic with
a long carry chain. In the IFU context, it is the single most important timing optimization for
boundary detection.

> *Chapter 8a Section 8a.5.2 describes the RTL implementation of this technique in Kunminghu's
> `InstrBoundary` module, including the simulation-only assertion that verifies the optimized
> result matches a naive serial computation.*

### 8.4.4 The Half-Instruction Problem

When the last halfword of a fetch block is the first half of a 32-bit instruction, the scan
produces `instrValid[N-1] = 1` but cannot set `instrEnd[N]` because position N does not exist
in this block. The IFU must:

1. Record that a half-instruction exists at the end of this block.
2. Save the halfword data.
3. On the next fetch cycle, prepend the saved halfword to the new block's first halfword to form
   a complete 32-bit instruction.

This carry state is small (one flag + 16 bits of data) but must be managed carefully across
flushes and redirects. When a redirect invalidates the current fetch stream, the half-instruction
carry must be cleared — otherwise the next fetch block after the redirect would incorrectly try
to complete a non-existent half-instruction.

### 8.4.5 Cross-Page Exceptions and Half-Instructions

The half-instruction problem has a subtle correctness dimension beyond data assembly: **exception
handling**. A 32-bit instruction straddling a page boundary has its first two bytes on page A and
its second two bytes on page B. If page B has no valid mapping (or is marked no-execute), the
fetch of block B raises an instruction page fault.

The question is: which instruction caused the exception? RISC-V requires precise exceptions — the
faulting PC must identify the instruction that triggered the fault. In this case, the faulting
instruction starts on page A (its first half was fetched successfully), but the exception was
caused by accessing page B (where its second half lives).

The IFU must propagate this information downstream:

1. Mark the exception on the reassembled instruction (not on the first instruction of block B).
2. Tag the exception as **cross-page**: the faulting address is on the next page, but the
   instruction PC belongs to the previous page.
3. The backend uses the cross-page tag to reconstruct the correct exception reporting: the
   `mepc` (machine exception program counter) CSR is set to the instruction's start PC (on
   page A), while the faulting virtual address (`mtval`) refers to page B.

Without this mechanism, the processor would either miss the exception entirely (if it attributed
the fault to block B's first instruction, which starts at a different PC) or report the wrong
faulting instruction.

### 8.4.6 Worked Example: Boundary Detection

Consider an 8-halfword fetch block (simplified from the real 32-halfword block for readability):

```text
  Halfword Position:    0       1       2       3       4       5       6       7
                      ┌───────┬───────────────┬───────┬───────┬───────┬───────────────┐
  Data:               │ x4501 │ x0073 │ x0013 │ x8591 │ x4501 │ x4581 │ x0063 │ x0013 │
  Bits [1:0]:         │  01   │  11   │  xxx  │  01   │  01   │  01   │  11   │  xxx  │
                      ├───────┼───────────────┼───────┼───────┼───────┼───────────────┤
  Architecture:       │  16b  │      32b      │  16b  │  16b  │  16b  │      32b      │
                      └───────┴───────┴───────┴───────┴───────┴───────┴───────┴───────┘
  instrValid          │   1   │   1       0   │   1   │   1   │   1   │   1       0   │
  instrEnd            │   1   │   0       1   │   1   │   1   │   1   │   0       1   │
```

**Scan Result:**
6 instructions found (four 16-bit, two 32-bit). Positions `pos=2` and `pos=7` were consumed as the second halves of 32-bit instructions, which is why their `instrValid` vectors are `0` and `instrEnd` vectors are `1`.

If the branch predictor said "taken at position 4," only instructions at positions {0, 1, 3, 4}
are on the correct path — the IFU masks out positions 5–7.

> *Chapter 8a Section 8a.5.2 describes the RTL implementation of boundary detection in
> Kunminghu's `InstrBoundary` module.*

---

## 8.5 Compaction and Alignment: Filling the Pipeline Efficiently

### 8.5.1 Why Sparse Positions Waste Bandwidth

The boundary detection logic identifies instructions but leaves them mapped to their original memory positions inside the fetch block array. Because instructions have mixed sizes (16-bit and 32-bit), this array naturally contains "holes" — positions that are simply the trailing halves of 32-bit instructions.

The branch predictor makes this spacing even more irregular. If the predictor anticipates a branch to be taken somewhere in the middle of the block, every slot following that branch becomes invalid wrong-path garbage and must be masked out.

As a result, an incoming raw array (e.g., 32 halfwords wide) might contain only 4 or 5 genuinely valid instructions, scattered haphazardly among empty slots.

If we try to dump this "Swiss cheese" array directly into the downstream pipeline stage (like a Decoder or an Instruction Buffer) with a fixed entry width (e.g., admitting 8 instructions per cycle), we face a severe performance trap. The wide, power-hungry intake lanes of the pipeline would map to empty slots, processing "air". The processor would waste precious cycles running at 50% or 80% below its peak ingestion capacity.

### 8.5.2 Compaction

Compaction removes the gaps. It maps the sparse valid positions to a contiguous output sequence:

```text
  Input (sparse):     [I0 at pos 0] [_ at pos 1] [I1 at pos 2] [I2 at pos 3] [_ at pos 4]
  Output (compact):   [I0] [I1] [I2]
```

The mapping is computed by a priority encoder or prefix-sum circuit that counts valid positions
and assigns each one a consecutive output index.

### 8.5.3 Alignment

After compaction, the contiguous instruction sequence must be written into the downstream buffer
(the instruction buffer, or IBuffer). The IBuffer is organized as a set of write banks, and each
bank expects to receive data at its own position. If the IBuffer's write pointer currently points
to bank 2, the first compacted instruction should go to bank 2, the second to bank 3, and so on
(wrapping around).

Alignment is a rotation (barrel shift) of the compacted output by the current write pointer value.
This ensures that every bank is utilized on every cycle, regardless of how many instructions the
previous fetch block contributed.

### 8.5.4 Performance Sensitivity

The width of the compaction and alignment logic determines the maximum instruction throughput. If
the IFU can compact at most K instructions per cycle and the downstream buffer has B write banks,
throughput is limited by min(K, B). Making K larger increases area and timing pressure (wider muxes,
longer prefix chains). Making K smaller creates a throughput bottleneck when RVC-heavy code packs
many instructions into a single fetch block.

```text
  Throughput vs. compaction width:

  Instructions/cycle
       │
   B   │─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─  (IBuffer write bandwidth limit)
       │        ╱─────────────────────
       │      ╱
       │    ╱
       │  ╱
       │╱
       └─────────────────────────────
       0    B/2    B    3B/2   2B
              Compaction width (K)

  Below K = B, compaction is the bottleneck.
  Above K = B, IBuffer write bandwidth is the bottleneck.
  Increasing K beyond B adds area but no throughput.
```

> *Chapter 8a Section 8a.2 describes Kunminghu's `InstrCompact` module and the specific alignment
> shift logic.*

---

## 8.6 Per-Instruction PC Reconstruction

### 8.6.1 The Problem: Storing a Full PC per Instruction Is Expensive

Every instruction dispatched to the backend must carry its exact program counter — the backend
needs it for branch target computation, exception reporting, and debug. A naive design would store
a full virtual address (39–48 bits) for each instruction slot in the IFU pipeline. With 32+
instruction slots per fetch block, this amounts to over 1,200 bits of register state just for PCs.

### 8.6.2 The Insight: Shared High Bits

Within a single fetch block, all instructions share the same *upper* address bits. A 64-byte
fetch block spans at most 64 bytes of address space — only the lowest 6 bits vary between
instructions. Even accounting for the instruction buffer's alignment width, the varying part is
small.

The optimization is to **split the PC at a cut point**:

```text
  Full PC (e.g., 39 bits):
  ┌──────────────────────────────┬──────────────┐
  │ High bits (shared per block) │ Low bits     │
  │ stored ONCE                  │ (per instr)  │
  └──────────────────────────────┴──────────────┘
                                  ^
                               cut point
```

- **High bits** (`pcHigh`): stored once per fetch block in the pipeline register. All instructions
  in the block share this value.
- **Low bits** (`pcLower`): stored per instruction. Computed as `blockStartOffset + i * 2` (since
  instructions are at 2-byte-aligned positions).

### 8.6.3 The Carry Problem

There is one complication: the low bits can overflow past the cut point. If the cut point is at
bit 9 (covering 512 bytes of offset), and the block start is at offset 500 with an instruction at
byte 520, the low-bit addition wraps around. The instruction's PC is not `pcHigh:520` but
`(pcHigh+1):8`.

The solution is to precompute `pcHighPlus1 = pcHigh + 1` once per fetch block, then use a
single-bit overflow detector:

```text
  pcLower = startOffset + instrSlot * 2
  if pcLower overflows past cut point:
    fullPC = Cat(pcHighPlus1, pcLower[cutPoint-1:0])
  else:
    fullPC = Cat(pcHigh,      pcLower[cutPoint-1:0])
```

This replaces N full-width adders (one per instruction slot) with:
- One full-width increment (for `pcHighPlus1`, computed once per block).
- N narrow additions (for `pcLower`, only `cutPoint+1` bits wide).
- N single-bit muxes (selecting between `pcHigh` and `pcHighPlus1`).

The saving is substantial: for a 39-bit virtual address with a 9-bit cut point, each instruction
slot needs only 10 bits of storage instead of 39 — a 75% reduction in per-slot register width.

> *Chapter 8a Section 8a.3 describes Kunminghu's `PcCutPoint` parameter and the `catPC` helper
> that implements this reconstruction.*

---

## 8.7 Early Prediction Verification

### 8.7.1 Common Misconception: "Prediction Errors Are Only Caught at Execution"

> **Common Misconception**
>
> *"Branch mispredictions can only be detected when the branch instruction executes in the
> backend."*
>
> This is true for conditional branches whose direction (taken/not-taken) depends on register
> values not available until execution. But a significant class of prediction errors can be
> detected much earlier — as soon as the instructions are decoded — because they involve
> *structural* properties of the instruction encoding rather than dynamic data values.

### 8.7.2 What Pre-Decode Can Detect

After boundary detection, the IFU performs a lightweight **pre-decode** of each instruction. This
is not full decode — it extracts only the instruction type (branch, jump, return, non-CFI) and,
for direct branches and jumps, the immediate offset. This information is sufficient to detect
several classes of prediction faults:

| Fault Class | Description | Detection Logic |
| --- | --- | --- |
| **NotCFI** | Predictor said "taken" at a non-control-flow instruction | Pre-decode says the instruction is not a branch/jump/return |
| **JAL target mismatch** | Predictor's target does not match JAL's computed target (PC + immediate) | Compare predicted target against PC + decoded immediate |
| **Invalid taken** | Predictor did not mark any instruction as taken, but pre-decode finds an unconditional jump (JAL) | Pre-decode identifies unconditional CFI that the predictor missed |
| **Return mismatch** | Predictor's target for a return does not match the RAS prediction | Compare predicted return target against RAS top |

These faults are detected 100% of the time — they do not depend on runtime data. Catching them
in the IFU saves the full backend pipeline depth worth of wrong-path work.

### 8.7.3 The Two-Stage Checker

A practical prediction checker is split into two stages:

1. **Stage 1 (same cycle as enqueue):** Determines which instructions in the fetch block are
   affected by the fault. Adjusts the valid mask so that wrong-path instructions are not sent to
   the instruction buffer. This limits the damage immediately.

2. **Stage 2 (one cycle later):** Computes the precise redirect target and packages it into a
   redirect message for the FTQ. This extra cycle allows the target computation to be off the
   critical enqueue path.

The split reflects a general design principle: *act fast on the side effects you can control
locally (enqueue masking), and take an extra cycle for the global effects (redirect generation).*

### 8.7.4 Pathological Case: Adversarial Code Maximizing Checker Redirects

Consider code deliberately designed to cause maximum IFU checker activity:

```text
  0x1000:  c.nop        # 16-bit, non-CFI
  0x1002:  c.nop        # 16-bit, non-CFI
  0x1004:  c.nop        # 16-bit, non-CFI
  0x1006:  c.nop        # 16-bit, non-CFI
  ...  (32 consecutive c.nop instructions in a 64-byte block)
```

If the branch predictor (perhaps due to aliasing in its tables) predicts "taken" at every other
instruction, the IFU checker will fire a NotCFI redirect on every fetch block. Each redirect
discards the current fetch and restarts from the sequential PC. In the worst case, the frontend
processes only one fetch block per redirect penalty — typically 4–5 cycles — reducing effective
fetch throughput by a factor of 4–5x.

This pathological case is rare in practice (it requires systematic aliasing in the predictor
tables), but it illustrates why predictor accuracy matters not just for backend performance but
for frontend throughput as well.

> *Chapter 8a Section 8a.6 describes the RTL implementation of `PredChecker` and its fault
> classification logic.*

---

## 8.8 Uncached and MMIO Instruction Fetch

### 8.8.1 Why Normal Cache Access Fails for MMIO

Memory-Mapped I/O (MMIO) regions have fundamentally different semantics from normal memory:

- **Side effects**: Reading an MMIO address may trigger hardware actions (clearing an interrupt
  flag, advancing a FIFO pointer). Speculative reads — which the cache subsystem may issue ahead
  of commit — are not permitted because they could trigger side effects on the wrong path.

- **Non-cacheable**: MMIO data must not be cached, because the device's state may change between
  accesses. The instruction cache, by design, caches data.

- **Ordering**: MMIO reads must occur in program order relative to preceding committed
  instructions. The speculative, out-of-order frontend would violate this.

These constraints mean that when the physical memory protection (PMP) unit or page table attributes
mark a fetch address as uncacheable or MMIO, the IFU cannot use its normal cache path.

### 8.8.2 The Serialized Uncache Path

The solution is a dedicated side path with explicit ordering control:

```text
  Normal path:          Uncache path:
  FTQ ─> ICache ─> IFU  FTQ ─> IFU ─> Uncache FSM ─> Memory Bus
  (speculative,          (serialized, one instruction at a time,
   pipelined,             waits for commit before issuing)
   high bandwidth)
```

The uncache path processes **one instruction at a time**. It follows a state machine:

1. **Wait for ordering**: If the fetch is MMIO, wait until all preceding instructions have
   committed. This ensures no speculative side effects.
2. **Send request**: Issue a single instruction-fetch request to the memory bus.
3. **Receive response**: Get the instruction word back from the device.
4. **Inject and redirect**: Place the single instruction into the instruction buffer and redirect
   the frontend to the next sequential PC for the next fetch.

This is dramatically slower than the normal cache path — one instruction per round-trip to the
memory bus versus potentially 16+ instructions per cycle. But MMIO instruction fetches are
extremely rare (typically only during early boot or when executing from device firmware), so the
throughput cost is acceptable.

### 8.8.3 The Ordering Problem in Detail

Why must MMIO fetches wait for commit? Consider this scenario:

1. The predictor guesses that the next fetch is at MMIO address 0xF000_0000.
2. The IFU issues an MMIO read. The device returns instruction data and advances its internal
   state.
3. The backend discovers that the prediction was wrong — the fetch should have been to a
   different address.
4. The pipeline flushes, but the device state change from step 2 **cannot be undone**.

By waiting until all prior instructions have committed before issuing the MMIO fetch, the IFU
guarantees that the fetch is on the architecturally correct path. The cost is latency; the benefit
is correctness.

### 8.8.4 Cross-Page MMIO Instructions

The serialized uncache path has one additional complication: a 32-bit instruction can straddle a
page boundary, with its first two bytes on one MMIO page and its second two bytes on the next.
Since uncache fetches operate at the granularity of single bus transactions (typically aligned to
4 bytes), the first transaction returns only the first 16-bit half of the instruction — the bus
cannot cross a page boundary in a single request.

The IFU must detect this case and issue **two** bus transactions:

```text
  Page A (MMIO):  ... [first half of 32b instr at offset 0xFFE]
  Page B (MMIO):  [second half at offset 0x000] ...

  Transaction 1:  read Page A → returns 16-bit half (incomplete)
  Transaction 2:  read Page B → returns 16-bit half
  Assembly:       full 32-bit instruction = Cat(half_from_B, half_from_A)
```

The uncache FSM signals "incomplete" on the first response. The IFU saves the first 16 bits,
issues a second fetch for the next page, and assembles the complete 32-bit instruction from the
two halves. Only then is the instruction injected into the instruction buffer.

This cross-page case is rare — it requires both an MMIO-mapped instruction region *and* a 32-bit
instruction at the exact page boundary — but it must be handled correctly, because failing to
assemble the instruction would cause an illegal-instruction exception on valid code.

### 8.8.5 Industry Comparison: Uncached Fetch Approaches

> **Industry Comparison**
>
> - **ARM Cortex-A series**: Uses a similar approach — non-cacheable fetches bypass the I-cache
>   and are serialized. The ARM architecture defines memory types (Device, Normal Non-cacheable)
>   that control this behavior.
>
> - **Intel x86 cores**: The distinction is less visible because x86 memory types (UC, WC, WT, WB)
>   are managed through MTRRs and PAT entries. Uncacheable instruction fetches are effectively
>   serialized by the frontend, though the details are implementation-specific.
>
> - **BOOM (Berkeley Out-of-Order Machine)**: Routes non-cacheable fetches through a separate
>   "fetch buffer bypass" path. Like Kunminghu, BOOM serializes MMIO fetches to preserve ordering.
>
> The pattern is universal: all high-performance designs isolate uncacheable fetches into a slow,
> ordered side path.

> *Chapter 8a Section 8a.7 describes the RTL implementation of Kunminghu's `IfuUncacheUnit` FSM.*

---

## 8.9 Instruction Life Story: One Fetch Block's Journey

Let us follow a single fetch block — a 64-byte chunk of instructions — through the complete IFU
pipeline. We use a simplified IFU with 4 stages plus a write-back check stage.

**Setup:**
- Fetch block at PC = 0x8000_0100 contains 10 instructions (mix of 16-bit and 32-bit).
- The branch predictor says: "taken at instruction 8" (a JAL at byte offset 22).
- The IBuffer's write pointer is currently at bank 1.
- No half-instruction carry from the previous cycle.

| Cycle | Stage | What Happens |
| --- | --- | --- |
| T0 | **Request accept** | FTQ presents the fetch target (PC=0x8000_0100, taken at offset 22). IFU and ICache both signal ready. The request is captured. |
| T1 | **Boundary detect** | ICache delivers 64 bytes. Boundary detection scans from halfword 0 and finds instruction starts at halfwords {0, 1, 3, 4, 6, 7, 9, 10, 11, 13}. The prediction mask trims this to {0, 1, 3, 4, 6, 7, 9, 10, 11} (halfword 13 is past the taken branch). The last valid instruction is at halfword 11 — it is a 32-bit instruction that does not cross the block boundary. Half-instruction carry remains clear. |
| T2 | **Compact + align** | Compaction maps the 9 valid instructions into contiguous slots 0–8. Alignment rotates them by the IBuffer write pointer (bank 1), so instruction 0 goes to lane 1, instruction 1 to lane 2, etc. Pre-decode begins: each instruction is classified as branch/jump/non-CFI. |
| T3 | **Check + expand + enqueue** | Pre-decode results arrive. Instruction 8 (halfword 11, the predicted-taken position) is indeed a JAL — the prediction checker confirms the target matches PC + immediate. No fault detected. RVC instructions are expanded to 32-bit equivalents. All 9 instructions are enqueued into the IBuffer. |
| T4 | **Write-back check** | The checker's stage-2 output confirms no redirect is needed. The FTQ is notified that this fetch block completed successfully. The IFU is ready for the next request. |

**Total latency:** 4 cycles from request to IBuffer enqueue, plus 1 cycle for the write-back
confirmation. During cycles T1–T4, the IFU can accept the next fetch block at T1 (pipelined
operation), so steady-state throughput is one fetch block per cycle.

Now consider what happens if instruction 8 is actually a `c.addi` (not a branch). The checker
at T3 detects a NotCFI fault, masks out instruction 8 from the enqueue (stage-1 action), and
at T4 emits a redirect to the sequential PC past instruction 7. The FTQ rewinds, and the next
fetch restarts from the corrected address. The pipeline loses approximately 4 cycles — the IFU's
pipeline depth — instead of the 15–20 cycles it would take for the backend to discover the same
error.

---

## 8.10 Flush Priority: Managing Concurrent Corrections

### 8.10.1 The Multi-Source Redirect Problem

A pipelined IFU has multiple stages in flight simultaneously. At any moment, several sources can
independently declare the in-flight work stale:

- The **backend** discovers a branch misprediction or raises an exception (authoritative).
- The IFU's own **prediction checker** finds a structural fault (frontend-authoritative).
- The BPU's **slow predictor layer** overrides an earlier fast prediction (speculative correction).

These events can arrive in the same cycle. The IFU must decide: which correction wins, and how
much of the pipeline does it flush?

### 8.10.2 The Priority Hierarchy

The solution is a strict priority chain, with more authoritative sources overriding less
authoritative ones:

```text
  Priority 1 (highest):  Backend redirect
                          (branch misprediction, exception, memory ordering violation)
                          Flushes: ALL stages (s0 through s3 + write-back)

  Priority 2:            IFU prediction checker redirect
                          (pre-decode found structural BPU error)
                          Flushes: s0, s1, s2 (but NOT s3, which already enqueued)

  Priority 3:            Uncache/MMIO redirect
                          (MMIO fetch completed, redirect to next sequential PC)
                          Flushes: s0, s1, s2

  Priority 4 (lowest):   BPU slow-layer self-correction
                          (BPU's accurate stage disagrees with its fast stage)
                          Flushes: s0, s1 only (before ICache response arrives)
```

The key insight is that each source's **pipeline depth of effect** differs. A backend redirect
must kill everything — it represents ground truth from instruction execution. A BPU self-
correction, by contrast, only needs to kill the earliest stages, because the correction is itself
speculative and may be superseded by a later, more authoritative redirect.

### 8.10.3 Why Priority Matters for Correctness

Consider a race condition: in the same cycle, the IFU checker detects a NotCFI fault in the
write-back stage, while the backend detects a branch misprediction at a *different* instruction.
Both want to redirect the frontend to different targets. Without a priority scheme, the IFU could
redirect to the checker's target, then immediately be overridden by the backend — or worse, the
two redirects could interleave and leave the pipeline in an inconsistent state.

The strict priority ensures that the backend redirect always wins. The checker redirect is
silently suppressed because the backend's correction is more authoritative (it comes from actual
execution, not from pre-decode heuristics). This eliminates the race entirely.

### 8.10.4 Same-Entry Guard

One subtle corner case: the write-back stage and the current pipeline stage may be processing the
*same* FTQ entry. In this case, the write-back redirect should not flush the current stage,
because the current stage is already working on the corrected version of that entry. Implementations
handle this with a same-entry comparator that suppresses the flush when the FTQ indices match.

> *Chapter 8a Section 8a.5 describes the RTL flush signals and their exact pipeline-stage
> coverage in Kunminghu.*

---

## 8.11 Design Trade-Offs

### 8.11.1 Early IFU Checking vs. Backend-Only Checking

| Dimension | Early IFU Checking | Backend-Only Checking |
| --- | --- | --- |
| **Wrong-path residency** | Short (IFU pipeline depth, ~4 cycles) | Long (full pipeline depth, ~15–20 cycles) |
| **IFU complexity** | Higher (pre-decode + checker logic) | Lower (simple byte forwarding) |
| **Area** | More combinational logic in frontend | Less frontend area, but more wasted backend resources |
| **Energy** | Pre-decode costs energy per fetch block | Wrong-path instructions waste decode + issue energy |
| **Detectable faults** | Only structural faults (NotCFI, JAL target, etc.) | All faults including conditional direction |

Modern high-performance designs universally choose early checking because the energy and throughput
savings from avoiding wrong-path work far exceed the cost of the checker logic.

### 8.11.2 IFU-Side Compaction vs. Downstream Compaction

| Dimension | IFU compaction | Downstream (IBuffer/Decode) compaction |
| --- | --- | --- |
| **IFU complexity** | Wider muxes, prefix-sum logic | Minimal — forward sparse valid bits |
| **Downstream complexity** | Simple banked writes | Must compact before decode, adding latency |
| **Steady-state throughput** | High — IBuffer receives dense entries | Lower — gaps reduce effective write bandwidth |
| **Timing** | Compaction is on IFU critical path | Compaction timing pressure moves to decode |

The trade-off depends on where in the pipeline timing is tightest. If the IFU has slack (e.g., a
generous clock period or pipeline stages to spare), IFU-side compaction is preferred because it
maximizes downstream utilization.

### 8.11.3 Dedicated Uncache FSM vs. Unified Path

| Dimension | Dedicated FSM | Unified cache/uncache |
| --- | --- | --- |
| **Ordering correctness** | Explicit — FSM enforces commit-order | Must add ordering checks to cache pipeline |
| **Design clarity** | Clear separation of concerns | Fewer modules, but complex mode switching |
| **Area** | Extra FSM state and control logic | Shared datapath, less duplication |
| **Verification** | Easier to verify isolation properties | Harder to ensure no speculative MMIO leak |

The dedicated FSM approach is favored in practice because MMIO correctness is critical and
difficult to verify in a unified path.

---

## 8.12 IFU in the Broader Pipeline Context

### 8.12.1 What IFU Consumes

The IFU has two upstream producers:

- **FTQ** (Chapter 6): provides fetch targets — the starting PC, the predicted taken-branch
  offset, and the FTQ entry index for bookkeeping.
- **ICache** (Chapter 7): provides the raw instruction bytes, along with metadata such as
  physical addresses, exception flags, and memory-type attributes (cacheable vs. MMIO).

Both must be ready simultaneously for the IFU to accept a new fetch block. If either stalls, the
IFU stalls.

### 8.12.2 What IFU Produces

The IFU has one primary downstream consumer:

- **IBuffer** (Chapter 9): receives a vector of compacted, aligned, RVC-expanded instruction
  entries. Each entry carries its PC, its pre-decode classification, its validity flag, and
  exception metadata.

The IFU also produces a secondary output back to the FTQ:

- **Redirect** (on prediction fault): a correction signal that rewinds the FTQ pointers and
  restarts the fetch stream from a corrected address.

### 8.12.3 Stall Propagation

```text
  IBuffer full ──> IFU stalls ──> ICache stalls (backpressure) ──> FTQ stalls
                                                                       │
  FTQ empty ────────────────────────────────────> IFU starves           │
                                                                       v
  ICache miss ──────────────────> IFU waits ──> FTQ does not advance   BPU may
                                  for data                             continue
                                                                       predicting
                                                                       (runahead)
```

The IFU is the central bottleneck of the frontend: it is the only path from cached bytes to
decoded instructions. When the IFU stalls, both the cache and the FTQ are affected. When the IFU
starves (no requests from FTQ, or no data from ICache), the backend runs out of instructions and
stalls.

The one exception to this tight coupling is the FTQ's runahead capability (Chapter 6, Section
6.4): even when the IFU stalls on a cache miss, the BPU can continue predicting and filling the
FTQ, so that when the miss resolves, several fetch targets are already queued and ready.

---

## Key Takeaways

- The IFU bridges the gap between raw cache bytes and the structured instruction stream the
  backend needs. Without it, variable-length encoding, cross-block boundaries, and prediction
  errors would cripple decode.
- Boundary detection reconstructs instruction starts under mixed 16-bit/32-bit encoding.
  Speculative parallel evaluation breaks the serial carry chain to meet timing. Cross-block
  carry state handles the half-instruction edge case, including cross-page exceptions.
- Per-instruction PCs are reconstructed from shared high bits and narrow per-slot low bits,
  with a carry-detect mux — avoiding a full-width adder per instruction slot.
- Compaction and alignment pack sparse valid instructions into dense output lanes, maximizing
  downstream write bandwidth.
- Early prediction verification catches structural prediction faults (NotCFI, target mismatch)
  in the frontend, avoiding the full pipeline penalty of backend-only detection.
- Multiple redirect sources (backend, IFU checker, BPU self-correction) are resolved by a
  strict priority hierarchy that determines both which correction wins and how much of the
  pipeline is flushed.
- Uncached/MMIO instruction fetches are isolated into a serialized side path with explicit
  commit-ordering, including two-transaction assembly for cross-page MMIO instructions.

## Checkpoint Questions

1. **Basic**: Why can't the instruction cache deliver instructions directly to the decode stage?
   Name two problems that would arise.
2. **Basic**: What information does the IFU carry from one fetch cycle to the next to handle
   instructions that span fetch-block boundaries?
3. **Basic**: Why does the uncache path process only one instruction at a time?
4. **Intermediate**: Explain why the prediction checker is split into two stages rather than
   performing all its work in a single cycle.
5. **Intermediate**: If a fetch block contains all 16-bit (compressed) instructions and the
   predictor says "taken at the last halfword," how many valid instructions does the IFU extract?
   What is the compaction ratio (valid slots / total halfword slots)?
6. **Intermediate**: Why must the half-instruction carry state be cleared on a redirect?
7. **Intermediate**: Why does the flush priority hierarchy allow a BPU self-correction to flush
   only s0 and s1, but a backend redirect flushes all stages? What would go wrong if BPU
   self-corrections flushed all stages?
8. **Advanced**: The PC reconstruction optimization uses a cut point to split the address. If the
   cut point were set too low (e.g., bit 4), what would happen to the per-slot storage and the
   overflow frequency? If set too high (e.g., bit 20)?
9. **Advanced**: Consider a design where the IFU performs compaction but not alignment (the
   IBuffer handles alignment instead). What are the area and timing trade-offs? Under what
   workload conditions would this be preferable?
10. **Advanced**: The pathological case in Section 8.7.4 assumes systematic predictor aliasing.
    Propose a predictor-side mitigation that would reduce the frequency of NotCFI faults without
    increasing predictor table size.

## Further Reading

1. Reinman, G., Austin, T., and Calder, B. "A Scalable Front-End Architecture for Fast
   Instruction Delivery." ISCA 1999. *Introduced decoupled fetch architectures with
   prediction-driven instruction supply.*
2. Ramirez, A. et al., "Fetching instruction streams." MICRO 2002. *Analysis of fetch bandwidth
   and variable-length instruction challenges.*
3. RISC-V Unprivileged ISA Specification, Chapter 16 (Compressed Extension). *Defines the 16-bit
   instruction encoding that drives boundary detection complexity.*
4. Smith, J. E. and Sohi, G. S. "The Microarchitecture of Superscalar Processors." Proceedings of
   the IEEE, 1995. *Broader context for instruction supply in superscalar designs.*
5. Ishii, Y. et al., "Re-establishing fetch-directed instruction prefetching." ISPASS 2021.
   *Modern perspective on fetch-unit-driven prefetch, relevant to IFU-ICache interaction.*
