# Chapter 10. Backend Overview

The previous Part covered the frontend: a branch predictor that anticipates control flow, an instruction cache that supplies raw bytes, an IFU that aligns and pre-decodes them, and an instruction buffer that smooths the bursty supply into a steady 8-wide stream. At the end of Chapter 9, we left instructions sitting at the output of the IBuffer, ready to cross into the backend. This chapter maps the territory they are about to enter.

The **backend execution engine** is the heart of XiangShan's Kunminghu core. It receives a stream of decoded RISC-V instructions and transforms them into completed, committed results — resolving data dependencies through register renaming, executing instructions out of program order on parallel functional units, and retiring them in order through a reorder buffer. The backend must sustain high throughput (up to 8 instructions decoded, renamed, and dispatched per cycle) while recovering quickly from mispredictions and exceptions.

This chapter provides the architectural roadmap: a full block diagram of the backend, the major pipeline stages and their roles, the key data structures that track in-flight instructions, and the control flow that ties everything together. Chapters 11–18 then examine each subsystem in detail.

---

## 10.1 The Problem: From Instructions to Results

A simple processor fetches, decodes, and executes one instruction at a time, in strict program order. This design is easy to reason about, but it leaves performance on the table. When one instruction depends on the result of a previous long-latency operation — a multiply, a cache-missing load — the entire pipeline stalls, and every functional unit sits idle. Real programs, however, contain abundant **instruction-level parallelism (ILP)**: independent instructions that *could* execute simultaneously if the hardware could find and exploit them.

The backend's purpose is exactly this. It takes the stream of decoded instructions delivered by the frontend and orchestrates their execution on parallel functional units, overlapping independent work to keep as many units busy as possible. The fundamental tension is between *performance* and *correctness*: the hardware reorders instructions internally to maximize throughput, yet the programmer must see the effect of strict sequential execution. XiangShan resolves this tension through three cooperating mechanisms:

1. **Register renaming** eliminates false dependencies (WAR and WAW hazards) by mapping architectural registers to a larger pool of physical registers, so that only true data dependencies (RAW hazards) constrain execution order.

2. **Dynamic scheduling** through issue queues allows instructions to fire as soon as their operands become available, regardless of program order. Wake-up signals propagate readiness, and select logic picks the next instructions to issue each cycle.

3. **In-order commit** through a Reorder Buffer (ROB) ensures that architectural state — visible registers, memory, and exceptions — updates in strict program order, enabling precise exceptions and correct recovery from speculation.

Together, these mechanisms form a **superscalar, out-of-order execution** engine: superscalar because multiple instructions proceed through each pipeline stage per cycle, and out-of-order because execution is governed by data readiness rather than program sequence.

> **Design Trade-off: Reservation Stations vs. Unified Physical Register File**
>
> Two classical approaches exist for out-of-order execution. In a *reservation station* (RS) design (as in Intel's P6 family), operand values are copied into the RS entries when they become available; execution reads data directly from the RS. In a *physical register file* (PRF) design (as in MIPS R10000 and Alpha 21264), operand *tags* are stored in issue queue entries, and the actual data lives in a centralized register file read at issue time.
>
> XiangShan uses the **PRF approach**. This avoids duplicating data across many RS entries — critical when supporting 128-bit vector registers — and simplifies the bypass network. The trade-off is that the register file must have enough read ports to serve all issuing instructions simultaneously, which XiangShan addresses through banking and a register cache.

---

## 10.2 Backend Block Diagram

The following diagram shows the major modules inside the backend and their interconnections. The backend is implemented in [Backend.scala:178](src/main/scala/xiangshan/backend/Backend.scala#L178) (`BackendInlinedImp`), which instantiates four major subsystems:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                               BACKEND                                       │
│                                                                             │
│  ┌───────────────────────────────────────────────────────┐                  │
│  │                      CtrlBlock                        │                  │
│  │  ┌────────┐  ┌────────┐  ┌──────────┐  ┌──────────┐   │                  │
│  │  │ Decode │→ │ Rename │→ │ Dispatch │→ │   ROB    │   │                  │
│  │  │(8-wide)│  │(8-wide)│  │ (8-wide) │  │(352 ent) │   │                  │
│  │  └────────┘  └────────┘  └──────────┘  └──────────┘   │                  │
│  │       ↑          ↑           │              ↑   │     │                  │
│  │   fusionDec   RAT+FreeList   │         writeback│     │                  │
│  │                              │              │   flush │                  │
│  │                    ┌─────────┴──────────┐   │   │     │                  │
│  │                    │    RedirectGen     │←──┘   │     │                  │
│  │                    └────────────────────┘       │     │                  │
│  └────────────────────────┬────────────────────────┴─────┘                  │
│          dispatch uops    │           ↑ writeback / flush                   │
│     ┌─────────────────────┬┴──────────┴───────────────┐                     │
│     ↓                     ↓                           ↓                     │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐                   │
│  │  intRegion   │  │  fpRegion    │  │   vecRegion      │                   │
│  │              │  │              │  │                  │                   │
│  │ ┌──────────┐ │  │ ┌──────────┐ │  │ ┌──────────┐     │                   │
│  │ │Issue Ques│ │  │ │Issue Ques│ │  │ │Issue Ques│     │                   │
│  │ │(4 ALU/BJ)│ │  │ │(3 FP)    │ │  │ │(2 VALU)  │     │                   │
│  │ │(3 LDU)   │ │  │ └────┬─────┘ │  │ │(2 VLSU)  │     │                   │
│  │ │(2 STA)   │ │  │      ↓       │  │ └────┬─────┘     │                   │
│  │ │(2 STD)   │ │  │ ┌──────────┐ │  │      ↓           │                   │
│  │ └────┬─────┘ │  │ │ DataPath │ │  │ ┌──────────┐     │                   │
│  │      ↓       │  │ │(RF read) │ │  │ │ DataPath │     │                   │
│  │ ┌──────────┐ │  │ └────┬─────┘ │  │ │(RF read) │     │                   │
│  │ │ DataPath │ │  │      ↓       │  │ └────┬─────┘     │                   │
│  │ │(RF read) │ │  │ ┌──────────┐ │  │      ↓           │                   │
│  │ └────┬─────┘ │  │ │ Bypass   │ │  │ ┌──────────┐     │                   │
│  │      ↓       │  │ │ Network  │ │  │ │ Bypass   │     │                   │
│  │ ┌──────────┐ │  │ └────┬─────┘ │  │ │ Network  │     │                   │
│  │ │ Bypass   │ │  │      ↓       │  │ └────┬─────┘     │                   │
│  │ │ Network  │ │  │ ┌──────────┐ │  │      ↓           │                   │
│  │ └────┬─────┘ │  │ │ ExuBlock │ │  │ ┌──────────┐     │                   │
│  │      ↓       │  │ │(FP exec) │ │  │ │ ExuBlock │     │                   │
│  │ ┌──────────┐ │  │ └────┬─────┘ │  │ │(Vec exec)│     │                   │
│  │ │ ExuBlock │ │  │      ↓       │  │ └────┬─────┘     │                   │
│  │ │(ALU,BJ)  │ │  │ ┌──────────┐ │  │      ↓           │                   │
│  │ └────┬─────┘ │  │ │WbDataPath│ │  │ ┌──────────┐     │                   │
│  │      ↓       │  │ └──────────┘ │  │ │WbDataPath│     │                   │
│  │ ┌──────────┐ │  └──────────────┘  │ └──────────┘     │                   │
│  │ │WbDataPath│ │         ↑↓              ↑↓            │                   │
│  │ └──────────┘ │    cross-domain    cross-domain       │                   │
│  └──────────────┘      wakeup          wakeup           │                   │
│         ↑↓                                              │                   │
│    ┌────────────┐                                       │                   │
│    │  MemBlock  │ ←── issue/writeback ──→               │                   │
│    │ (external) │                                       │                   │
│    └────────────┘                                       │                   │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Figure 10.1: Backend top-level block diagram.** The backend contains a CtrlBlock (in-order control pipeline) and three execution Regions (integer, floating-point, vector). Each Region contains its own issue queues, data path, bypass network, execution units, and writeback path. The MemBlock is external to the backend but tightly coupled via issue and writeback interfaces.

The backend instantiation in `BackendInlinedImp` ([Backend.scala:186–191](src/main/scala/xiangshan/backend/Backend.scala#L186)) creates:

```
ctrlBlock    — CtrlBlock (decode, rename, dispatch, ROB, redirect generation)
intRegion    — Region(IntScheduler) for integer/branch/memory address
fpRegion     — Region(FpScheduler) for floating-point
vecRegion    — Region(VecScheduler) for vector
```

---

## 10.3 Pipeline Stages at a Glance

An instruction's journey through the backend can be divided into seven logical stages. The table below summarizes each stage, its width, and the module responsible.

| Stage | Width | Module | Key Action |
|-------|-------|--------|------------|
| **Decode** | 8-wide | `DecodeStage` in CtrlBlock | Translate instruction bits into micro-ops; detect fusion opportunities |
| **Rename** | 8-wide | `Rename` in CtrlBlock | Allocate physical registers; eliminate false dependencies |
| **Dispatch** | 8-wide | `NewDispatch` in CtrlBlock | Route micro-ops to issue queues; check structural hazards |
| **Issue (OG0)** | per-IQ | `IssueQueue` in Region | Hold entries until operands ready; select oldest ready entry |
| **Read & Steer (OG1)** | per-IQ | `DataPath` in Region | Read physical register file; apply bypass forwarding |
| **Execute** | per-FU | `ExuBlock` in Region | Compute results (1–N cycles depending on FU) |
| **Writeback** | per-RF | `WbDataPath` in Region | Arbitrate write ports; update register files and ROB |
| **Commit** | 8-wide | `Rob` in CtrlBlock | Retire instructions in order; free old physical registers |

> **Terminology note.** XiangShan's codebase uses the naming convention **OG0** (operand-generation stage 0) for the issue stage, **OG1** for the register-read/bypass stage, and optionally **OG2** for an additional pipeline stage used by certain vector operations. These correspond to the "issue", "read", and "execute" stages in textbook terminology.

**Worked Example: Life of an ADD Instruction**

Consider the instruction `add x3, x1, x2` entering the backend:

1. **Decode** (cycle 0): The 32-bit encoding `0x002081b3` is recognized as an R-type ADD. The decoder produces a micro-op with `fuType = ALU`, `fuOpType = ADD`, `lsrc[0] = 1`, `lsrc[1] = 2`, `ldest = 3`.

2. **Rename** (cycle 1): The rename table maps logical `x1 → p47`, `x2 → p12`. A new physical register `p88` is allocated from the free list for the destination `x3`. The old mapping of `x3` (say `p31`) is recorded so it can be freed at commit. The micro-op now carries `psrc[0] = p47`, `psrc[1] = p12`, `pdest = p88`.

3. **Dispatch** (cycle 2): The dispatcher examines `fuType = ALU` and routes the micro-op to one of the four integer ALU issue queues (say IQ0). It also checks that the ROB has a free slot and enqueues the instruction into the ROB.

4. **Issue / OG0** (cycle 3+): The issue queue entry monitors wake-up signals. When both `p47` and `p12` have been written back (or are being forwarded), the entry becomes ready. The select logic picks it as the oldest ready entry and dequeues it.

5. **Read & Bypass / OG1** (cycle N): The DataPath reads `p47` and `p12` from the integer register file (or receives them via bypass from a just-completing instruction). The BypassNetwork selects the freshest available source for each operand.

6. **Execute** (cycle N+1): The ALU computes `p47 + p12` in a single cycle and produces the result.

7. **Writeback** (cycle N+2): The WbDataPath writes the result to physical register `p88` and signals the ROB that this instruction has completed. The result is also broadcast as a wake-up to any younger instructions waiting on `p88`.

8. **Commit** (cycle M): When the ADD reaches the head of the ROB with all older instructions already committed, the ROB retires it. The old physical register `p31` (which previously held `x3`) is returned to the free list.

---

## 10.4 The Two Planes: Control and Data

A key architectural insight in XiangShan's backend is the clean separation between the **control plane** and the **data plane**.

### 10.4.1 Control Plane: CtrlBlock

The **CtrlBlock** ([CtrlBlock.scala:56](src/main/scala/xiangshan/backend/CtrlBlock.scala#L56)) manages instruction flow and speculative state. It contains:

- **DecodeStage** — Converts raw instruction bits into micro-ops ([CtrlBlock.scala:99](src/main/scala/xiangshan/backend/CtrlBlock.scala#L99))
- **FusionDecoder** — Detects pairs of instructions that can be fused into a single micro-op ([CtrlBlock.scala:100](src/main/scala/xiangshan/backend/CtrlBlock.scala#L100))
- **RenameTableWrapper (RAT)** — Maintains speculative and architectural register mappings ([CtrlBlock.scala:101](src/main/scala/xiangshan/backend/CtrlBlock.scala#L101))
- **Rename** — Performs register renaming with free list allocation ([CtrlBlock.scala:102](src/main/scala/xiangshan/backend/CtrlBlock.scala#L102))
- **NewDispatch** — Routes instructions to issue queues and performs structural hazard checks ([CtrlBlock.scala:97](src/main/scala/xiangshan/backend/CtrlBlock.scala#L97))
- **Rob** — Reorder buffer for in-order commit and exception handling ([CtrlBlock.scala:106](src/main/scala/xiangshan/backend/CtrlBlock.scala#L106))
- **RedirectGenerator** — Arbitrates among multiple redirect sources (branch misprediction, load replay, ROB flush) ([CtrlBlock.scala:103](src/main/scala/xiangshan/backend/CtrlBlock.scala#L103))
- **MemCtrl** — Coordinates load/store queue allocation and memory dependency prediction ([CtrlBlock.scala:107](src/main/scala/xiangshan/backend/CtrlBlock.scala#L107))
- **pcMem** — Synchronous memory storing PCs indexed by FTQ pointer, used for redirect target computation ([CtrlBlock.scala:105](src/main/scala/xiangshan/backend/CtrlBlock.scala#L105))

The CtrlBlock processes instructions *in order* through the decode → rename → dispatch pipeline. It receives writeback status from all execution units and manages the ROB commit logic. When a misprediction or exception is detected, the CtrlBlock generates a redirect that flushes speculative state throughout the backend and frontend.

### 10.4.2 Data Plane: Regions

The **data plane** is organized as three independent **Regions**, each implemented by the `Region` module ([Region.scala:37](src/main/scala/xiangshan/backend/Region.scala#L37)). A Region encapsulates everything needed to hold, read, execute, and write back instructions for one domain of execution:

| Region | Scheduler Type | Functional Units | Register File |
|--------|---------------|------------------|---------------|
| **intRegion** | IntScheduler | 4 ALU, 3 BJU, 3 LDU, 2 STA, 2 STD | 224 × 64-bit integer |
| **fpRegion** | FpScheduler | 3 FP execution units (FMAC, FCVT, FDIV, etc.) | 256 × 64-bit floating-point |
| **vecRegion** | VecScheduler | 2 VALU, 2 VLSU | 128 × 128-bit vector |

Each Region contains five internal submodules:

1. **Issue Queues** (`IssueQueue`) — Hold dispatched micro-ops until their operands are ready; perform wake-up and select.
2. **DataPath** — Reads operands from the physical register file and manages the OG0 → OG1 → OG2 pipeline stages.
3. **BypassNetwork** — Forwards results from completing instructions to dependent consumers, avoiding register file read latency.
4. **ExuBlock** — Contains the actual functional unit implementations (ALU, FPU, vector ALU, etc.).
5. **WbDataPath** — Arbitrates write-port access when multiple execution units complete in the same cycle.

> **Analogy.** Think of the CtrlBlock as an air traffic controller and the three Regions as separate runways. The controller sequences aircraft (instructions) and assigns them to runways (Regions) based on their type. Once on a runway, each aircraft proceeds through its own taxi-execute-park sequence independently. The controller monitors all runways and can halt traffic (flush) if something goes wrong.

---

## 10.5 Instruction Flow: Decode to Commit

This section traces the complete path of instructions through the backend, identifying the key data structures and handshake signals at each boundary.

### 10.5.1 Frontend → Decode

The IBuffer delivers up to 8 instructions per cycle to the backend via the `FrontendToCtrlIO` interface ([Backend.scala:711](src/main/scala/xiangshan/backend/Backend.scala#L711)). Each instruction arrives as a `CtrlFlow` bundle carrying the 32-bit instruction encoding, virtual PC, FTQ pointer, and any frontend-detected exceptions (e.g., instruction page fault, access fault).

The CtrlBlock connects this interface directly: `ctrlBlock.io.frontend <> io.frontend` ([Backend.scala:202](src/main/scala/xiangshan/backend/Backend.scala#L202)).

### 10.5.2 Decode → Rename

The **DecodeStage** translates each instruction encoding into a micro-op. For most RISC-V instructions this is a one-to-one mapping, but complex vector instructions may expand into multiple micro-ops via the complex decoder. The **FusionDecoder** runs in parallel, identifying instruction pairs (e.g., `LUI` + `ADDI`) that can be collapsed into a single micro-op.

The decode output is a vector of `DecodeOutUop` bundles, which flow into the **Rename** stage. Decode also initiates register alias table (RAT) lookups so that physical register mappings are available by the time renaming begins.

### 10.5.3 Rename → Dispatch

The **Rename** module performs register renaming for five register types: integer, floating-point, vector, v0 (mask), and vl (vector length). For each instruction, it:

- Reads the source physical register mappings from the RAT
- Allocates a fresh physical register from the appropriate free list for the destination
- Records the old-to-new mapping for rollback on misprediction
- Detects **move elimination** opportunities (integer `MV` instructions that simply copy the source-to-destination mapping without consuming a register file write)

The renamed micro-ops (carrying physical register tags instead of logical register names) flow into **Dispatch**.

### 10.5.4 Dispatch → Issue Queues

The **NewDispatch** module performs two critical functions:

1. **Routing**: Each micro-op is directed to the appropriate issue queue based on its functional unit type (`fuType`). When a functional unit type is present in multiple issue queues (e.g., ALU appears in all four integer IQ blocks), the dispatcher selects the least-full queue for load balancing.

2. **Hazard checking**: Dispatch stalls if any structural resource is unavailable — the target issue queue is full, the ROB is full, or the load/store queue cannot accept the instruction.

Dispatch also consults the **busy tables** to annotate each micro-op with which source operands are already ready, giving the issue queue a head start on scheduling.

The three dispatch outputs connect to the three Regions:

```
ctrlBlock.io.toIssueBlock → intRegion / fpRegion / vecRegion (dispatch uops)
```

### 10.5.5 Issue → Execute → Writeback (Inside a Region)

Within each Region, the instruction passes through a pipeline of internal stages:

**OG0 (Issue):** The issue queue selects the oldest entry whose operands are all ready (or will be ready via bypass). The selected entry is dequeued into the DataPath.

**OG1 (Read & Steer):** The DataPath reads the physical register file using the source physical register indices. The BypassNetwork checks whether any of the needed operands are being produced by a currently-completing instruction and forwards them, avoiding a stale register file read. The operand data is steered to the correct execution unit input.

**Execute:** The ExuBlock performs the computation. Latency varies: ALU operations complete in 1 cycle, multiplications take 3 cycles, FP divide may take 10+ cycles. Pipelined units can accept a new operation every cycle; non-pipelined units (divider, CSR) may block their issue port.

**Writeback:** The WbDataPath arbitrates when multiple execution units complete in the same cycle and compete for the same register file write port. Certain-latency units (ALU, multiplier) are guaranteed a write port and never stall; uncertain-latency units (divider) receive backpressure if their port is occupied.

### 10.5.6 Writeback → ROB Commit

Writeback results flow from all three Regions back to the CtrlBlock. The aggregation happens in `BackendInlinedImp` ([Backend.scala:207–215](src/main/scala/xiangshan/backend/Backend.scala#L207)):

```
wbDataPathToCtrlBlock = intRegion.writeback ++ fpRegion.writeback ++ vecRegion.writeback
ctrlBlock.io.fromWB.wbData ← wbDataPathToCtrlBlock
```

Each writeback carries the ROB index, physical destination, result data, and optional exception/redirect information. The ROB marks the corresponding entry as *completed*. When the oldest un-committed instruction (the ROB head) has completed without exception, it is retired: its architectural effects become permanent, and its old physical register is freed.

---

## 10.6 Cross-Region Communication

Although the three Regions are largely independent, they must communicate in two scenarios:

### 10.6.1 Cross-Domain Wake-up

When a load instruction completes in the integer Region and its result will be consumed by a floating-point operation (e.g., `FLW` loads data used by `FADD`), the FP Region's issue queues need a wake-up signal. XiangShan implements this through dedicated cross-region wake-up paths ([Backend.scala:306–312](src/main/scala/xiangshan/backend/Backend.scala#L306)):

- `intRegion → fpRegion`: Integer-to-FP wake-up (load results used by FP ops)
- `fpRegion → intRegion`: FP-to-integer wake-up (FP conversion results used by integer ops)
- `intRegion → vecRegion` and `fpRegion → vecRegion`: For vector operations consuming scalar operands

### 10.6.2 Cross-Domain Register File Access

Some operations require reading a register in one domain and writing in another. For example, an `FMV.X.W` instruction reads the FP register file and writes the integer register file. XiangShan handles this through cross-region register file read/write ports:

```
fpRegion.io.fromIntIQ  ←  intRegion.io.intIQOut     (int-issued ops needing FP RF read)
intRegion.io.fpRfRdata ←  fpRegion.io.fpRfRdataOut  (FP data returned to int region)
```

These ports are configured in [Backend.scala:385–393](src/main/scala/xiangshan/backend/Backend.scala#L385).

---

## 10.7 Redirect and Recovery

Mispredicted branches, memory ordering violations, and exceptions all require the backend to flush speculative state and redirect execution. XiangShan's redirect mechanism operates through a multi-stage pipeline to meet timing constraints.

### 10.7.1 Redirect Sources

Three sources can generate a redirect, listed in priority order:

| Redirect Source | Generated By | Example |
|----------------|-------------|---------|
| **ROB flush** | ROB exception/trap detection | Illegal instruction, page fault, interrupt |
| **Execution redirect** | Branch/jump unit misprediction | BEQ predicted taken but resolved not-taken |
| **Load replay** | Memory ordering violation | Load observed stale data due to store-to-load ordering |

The **RedirectGenerator** ([CtrlBlock.scala:103](src/main/scala/xiangshan/backend/CtrlBlock.scala#L103)) arbitrates among these sources, always selecting the redirect from the *oldest* instruction (earliest in program order) to ensure correct recovery.

### 10.7.2 Redirect Pipeline

The redirect propagates through a multi-stage pipeline for timing closure ([CtrlBlock.scala:111–134](src/main/scala/xiangshan/backend/CtrlBlock.scala#L111)):

```
Cycle S0: ROB detects flush condition (s0_robFlushRedirect)
Cycle S1: ROB flush registered; merged with EXU redirect → s1_s3_redirect
Cycle S2: s2_s4_redirect = RegNext(s1_s3_redirect)  — sent to Regions
Cycle S3: s3_s5_redirect = RegNext(s2_s4_redirect)  — sent to FTQ/frontend
```

The key mux at cycle S1 ([CtrlBlock.scala:124](src/main/scala/xiangshan/backend/CtrlBlock.scala#L124)):
```
s1_s3_redirect = Mux(s1_robFlushRedirect.valid, s1_robFlushRedirect, s3_redirectGen)
```

This ensures that ROB flushes (highest priority) override execution unit redirects.

### 10.7.3 Recovery Actions

When a redirect fires, the following recovery actions occur:

1. **Frontend**: The FTQ receives a redirect pointer, causing the BPU and IFU to restart fetching from the correct target.
2. **Decode/Rename**: All instructions younger than the redirect point are squashed. The rename table can either walk back entry-by-entry or restore from a **snapshot** (XiangShan maintains up to 4 rename snapshots for fast branch recovery, configurable via `RenameSnapshotNum`).
3. **Issue Queues**: All entries with a ROB index younger than the redirect point are invalidated.
4. **ROB**: Enters the **walk state** (`s_walk`), scanning from the redirect point to the tail, invalidating mis-speculated entries and returning their physical registers to the free lists. When a snapshot is available, the walk can begin from the snapshot rather than the ROB head, significantly reducing recovery latency.
5. **Load/Store Queues**: Entries younger than the redirect point are invalidated in the MemBlock.

---

## 10.8 Memory Subsystem Interface

The backend communicates with the memory subsystem (MemBlock, covered in Part IV) through the `BackendMemIO` interface ([Backend.scala:616](src/main/scala/xiangshan/backend/Backend.scala#L616)). This interface is extensive because load/store instructions are *issued* from the integer Region's issue queues but *executed* in the MemBlock.

### 10.8.1 Issue Path (Backend → MemBlock)

- `intIssue`: Load and store-address micro-ops issued from the integer scheduler to load/store pipelines
- `vecIssue`: Vector load/store micro-ops from the vector scheduler
- `storePcRead` / `hyuPcRead`: PC values for store instructions (needed for exception reporting)

### 10.8.2 Writeback Path (MemBlock → Backend)

- `intWriteback`: Completed load results written back into the integer Region
- `vecWriteback`: Completed vector memory results written back into the vector Region
- `wakeup`: Early wake-up signals from load units — broadcast one cycle before data is available so that dependent instructions can begin issuing

### 10.8.3 Feedback Path (MemBlock → Backend)

- `ldaIqFeedback` / `staIqFeedback` / `hyuIqFeedback`: Feedback from memory pipelines to issue queues indicating whether an issued operation succeeded or needs replay (e.g., TLB miss, cache miss requiring MSHR allocation)
- `ldCancel`: Load cancellation signals that kill speculatively woken-up instructions in the issue queues
- `memoryViolation`: Load-store ordering violations detected by the memory subsystem
- `mdpTrain`: Memory dependency prediction training data

### 10.8.4 ROB ↔ LSQ Coordination

- `robLsqIO`: Commit and exception information between ROB and load/store queues
- `lsqEnqIO`: Flow control for load/store queue allocation at dispatch time
- `lqCanAccept` / `sqCanAccept`: Backpressure signals indicating whether the queues have space

---

## 10.9 Backend I/O Interface Table

The following table lists the major I/O ports of the `BackendIO` bundle ([Backend.scala:703–733](src/main/scala/xiangshan/backend/Backend.scala#L703)), which defines the backend's boundary with the rest of the SoC:

| Port Name | Direction | Width / Type | Description |
|-----------|-----------|-------------|-------------|
| `fromTop.hartId` | Input | `UInt(hartIdLen.W)` | Hardware thread identifier |
| `fromTop.externalInterrupt` | Input | `ExternalInterruptIO` | External interrupt signals (MEIP, SEIP, etc.) |
| `fromTop.msiInfo` | Input | `ValidIO(UInt)` | MSI interrupt information from IMSIC |
| `fromTop.clintTime` | Input | `ValidIO(UInt(64.W))` | CLINT timer value |
| `fromTop.l2FlushDone` | Input | `Bool` | L2 cache flush completion |
| `toTop.cpuHalted` | Output | `Bool` | CPU halted (WFI or power-down) |
| `toTop.cpuCriticalError` | Output | `Bool` | Critical error detected |
| `toTop.msiAck` | Output | `Bool` | MSI interrupt acknowledged |
| `frontend` | Input (Flipped) | `FrontendToCtrlIO` | Decoded instructions from IBuffer; FTQ pointers |
| `frontendSfence` | Output | `SfenceBundle` | SFENCE signals to frontend TLB |
| `frontendCsrCtrl` | Output | `CustomCSRCtrlIO` | CSR control to frontend |
| `frontendTlbCsr` | Output | `TlbCsrBundle` | TLB configuration (SATP, etc.) to frontend |
| `mem` | Bidirectional | `BackendMemIO` | Complete memory subsystem interface (see Section 10.8) |
| `fenceio` | Bidirectional | `FenceIO` | Fence instruction coordination (SFENCE, FENCE.I, SBuffer flush) |
| `perf` | Input | `PerfCounterIO` | Performance counter events from frontend and memory |
| `tlb` | Output | `TlbCsrBundle` | TLB CSR values to MemBlock |
| `csrCustomCtrl` | Output | `CustomCSRCtrlIO` | Custom CSR controls to MemBlock |
| `traceCoreInterface` | Output | `TraceCoreInterface` | Instruction trace output for debug |
| `debugTopDown` | Bidirectional | Bundle | Top-down performance analysis (ROB commit info, cache miss signals) |

---

## 10.10 Key Backend Parameters

The backend is highly parameterized through `XSCoreParameters` ([Parameters.scala:48](src/main/scala/xiangshan/Parameters.scala#L48)) and `BackendParams` ([BackendParams.scala:36](src/main/scala/xiangshan/backend/BackendParams.scala#L36)). The following table lists the most important parameters with their default values in the Kunminghu configuration:

| Parameter | Default | Description |
|-----------|---------|-------------|
| [`DecodeWidth`](src/main/scala/xiangshan/Parameters.scala#L80) | 8 | Instructions decoded per cycle |
| [`RenameWidth`](src/main/scala/xiangshan/Parameters.scala#L81) | 8 | Instructions renamed per cycle |
| [`CommitWidth`](src/main/scala/xiangshan/Parameters.scala#L82) | 8 | Instructions committed per cycle |
| [`RobSize`](src/main/scala/xiangshan/Parameters.scala#L110) | 352 | Reorder buffer entries |
| [`RabSize`](src/main/scala/xiangshan/Parameters.scala#L111) | 352 | Register alias buffer entries |
| [`RenameSnapshotNum`](src/main/scala/xiangshan/Parameters.scala#L87) | 4 | Rename state snapshots for fast recovery |
| [`IssueQueueSize`](src/main/scala/xiangshan/Parameters.scala#L113) | 20 | Default issue queue depth |
| [`IssueQueueCompEntrySize`](src/main/scala/xiangshan/Parameters.scala#L114) | 12 | Compressed (simple) entries in each IQ |
| [`intPreg.numEntries`](src/main/scala/xiangshan/Parameters.scala#L117) | 224 | Physical integer registers |
| [`fpPreg.numEntries`](src/main/scala/xiangshan/Parameters.scala#L123) | 256 | Physical FP registers |
| [`vfPreg.numEntries`](src/main/scala/xiangshan/Parameters.scala#L129) | 128 | Physical vector registers (128-bit) |
| [`v0Preg.numEntries`](src/main/scala/xiangshan/Parameters.scala#L135) | 22 | Physical mask (v0) registers |
| [`vlPreg.numEntries`](src/main/scala/xiangshan/Parameters.scala#L141) | 32 | Physical vector-length registers |
| [`IntRegCacheSize`](src/main/scala/xiangshan/Parameters.scala#L146) | 16 | Integer register cache entries |
| [`MemRegCacheSize`](src/main/scala/xiangshan/Parameters.scala#L147) | 12 | Memory register cache entries |
| [`VirtualLoadQueueSize`](src/main/scala/xiangshan/Parameters.scala#L99) | 72 | Load queue capacity |
| [`StoreQueueSize`](src/main/scala/xiangshan/Parameters.scala#L106) | 56 | Store queue capacity |
| [`LoadPipelineWidth`](src/main/scala/xiangshan/Parameters.scala#L152) | 3 | Parallel load pipelines |
| [`StorePipelineWidth`](src/main/scala/xiangshan/Parameters.scala#L153) | 2 | Parallel store pipelines |
| [`VLEN`](src/main/scala/xiangshan/Parameters.scala#L53) | 128 | Vector register width (bits) |

---

## 10.11 Execution Unit Organization

The default Kunminghu backend configuration ([BackendParams.scala:534–693](src/main/scala/xiangshan/backend/BackendParams.scala#L534)) organizes execution units into three scheduler domains. Each scheduler domain maps to one Region.

### 10.11.1 Integer Scheduler

The integer scheduler has 11 issue queue blocks:

| IQ Block | Units | Entries | Enq Ports | Writeback Ports |
|----------|-------|---------|-----------|----------------|
| IQ0 | ALU0 + BJU0 | 20 | 2 | IntWB(0), IntWB(4) |
| IQ1 | ALU1 + BJU1 | 20 | 2 | IntWB(1), IntWB(5) |
| IQ2 | ALU2 + BJU2 | 20 | 2 | IntWB(2), IntWB(6) |
| IQ3 | ALU3 | 20 | 2 | IntWB(3) |
| IQ4 | LDU0 | 16 | 2 | IntWB(4), FpWB(3) |
| IQ5 | LDU1 | 16 | 2 | IntWB(5), FpWB(4) |
| IQ6 | LDU2 | 16 | 2 | IntWB(6), FpWB(5) |
| IQ7 | STA0 | 16 | 2 | — (address only) |
| IQ8 | STA1 | 16 | 2 | — (address only) |
| IQ9 | STD0 | 16 | 2 | — (data only) |
| IQ10 | STD1 | 16 | 2 | — (data only) |

Note that load and store units are issued from the *integer* scheduler because their address computations use integer registers. The actual execution happens in the MemBlock, not in the integer ExuBlock.

### 10.11.2 Floating-Point Scheduler

| IQ Block | Units | Entries | Writeback Ports |
|----------|-------|---------|----------------|
| FEX0 | FMAC, FCVT, F2I, F2V | 18 | FpWB(0), IntWB(3), VfWB(5), V0WB(3) |
| FEX1 | FMAC, FCVT | 18 | FpWB(1), VfWB(6) |
| FEX2 | FMAC, FCVT, FDIV | 18 | FpWB(2), VfWB(7) |

FP units share issue queue blocks because many FP operations use the same register read ports. The F2I (FP-to-integer) conversion unit in FEX0 can write back to the integer register file, illustrating cross-domain writeback.

### 10.11.3 Vector Scheduler

| IQ Block | Units | Entries | Writeback Ports |
|----------|-------|---------|----------------|
| VFEX0 | VALU, VMAC, VecDIV, VPPU, VIMAC | 16 | VfWB(0), V0WB(0), VlWB(0) |
| VFEX1 | VALU, VMAC, VPPU, VIMAC | 16 | VfWB(1), V0WB(1), VlWB(1) |
| VLSU0 | VLD, VST (segmented) | 16 | VfWB(2), V0WB(2) |
| VLSU1 | VLD, VST (segmented) | 16 | VfWB(3) |

Vector execution units operate on 128-bit datapaths (VLEN=128). For operations with LMUL > 1, a single vector instruction is decomposed into multiple micro-ops at decode time.

---

## 10.12 Wake-up and Bypass Architecture

Efficient wake-up and bypass are essential for sustaining high IPC. Without forwarding, every instruction would need to wait for its producer to write the register file before it could read its operands — adding at least one cycle of latency to every dependent instruction chain.

### 10.12.1 Wake-up Mechanism

When an execution unit produces a result, it broadcasts a **wake-up signal** containing the destination physical register index. Issue queues compare this against their entries' source tags. A match marks that source as *ready*; when all sources of an entry are ready, it becomes eligible for selection.

XiangShan supports two types of wake-up:

1. **Speculative (IQ-to-IQ) wake-up**: Broadcast at issue time for known-latency units (e.g., ALU has 1-cycle latency, so the wake-up fires when the instruction issues, one cycle before the result is available). This allows back-to-back dependent instructions to execute without a bubble.

2. **Non-speculative (WB) wake-up**: Broadcast when the result actually writes back to the register file. Required for uncertain-latency units (e.g., divider, cache-missing loads).

> **Caution — speculative wake-up and load cancellation.** Load instructions are speculatively assumed to hit the L1 cache. If the load actually misses, all instructions that were speculatively woken up by that load must be **cancelled** and replayed. The `ldCancel` signal from the MemBlock triggers this cancellation in the issue queues.

### 10.12.2 Bypass Network

The **BypassNetwork** ([BypassNetwork.scala:20](src/main/scala/xiangshan/backend/datapath/BypassNetwork.scala#L20)) provides three levels of data forwarding within each Region:

| Bypass Level | Timing | Data Source | Use Case |
|-------------|--------|------------|----------|
| **Forward** | Same cycle (combinational) | Execution unit output | Back-to-back ALU → ALU |
| **Bypass** | Next cycle (registered) | Registered execution result | 2-cycle producer → consumer |
| **Bypass2** | Two cycles (vector-specific) | Registered vector result | Vector pipeline forwarding |

For each operand, the DataPath selects the freshest available source in priority order: forward > bypass > register cache > register file > immediate > zero.

### 10.12.3 Register Cache

The **Register Cache** is a small, high-speed structure (16 integer + 12 memory entries) that stores recently-produced results for zero-latency access. It acts as a write-through cache in front of the physical register file, reducing read port contention on the banked register file. The register cache is particularly valuable for tight loops where the same registers are repeatedly read and written.

---

## 10.13 Comparison with Other Out-of-Order Designs

To place XiangShan's backend in context, the following table compares its key parameters with well-known commercial processors:

| Feature | XiangShan Kunminghu | ARM Cortex-A77 | Intel Golden Cove | AMD Zen 4 |
|---------|---------------------|----------------|-------------------|-----------|
| Decode width | 8 | 4 | 6 | 4 |
| Rename width | 8 | 4 | 6 | 4 |
| ROB size | 352 | 160 | 512 | 320 |
| Int phys regs | 224 | ~160 | ~280 | ~224 |
| FP phys regs | 256 | ~128 | ~332 | ~192 |
| Issue queues | 11 int + 3 FP + 4 vec | Distributed | Unified | Distributed |
| Load pipelines | 3 | 2 | 3 | 3 |
| Store pipelines | 2 | 1 | 2 | 2 |
| ISA | RV64GCBHV | ARMv8.2-A | x86-64 | x86-64 |

> **Design Trade-off: Wide Decode vs. Deep Buffers**
>
> XiangShan's 8-wide decode pipeline is wider than most commercial designs (typically 4–6 wide). A wider pipeline can sustain higher throughput on code with abundant ILP, but requires proportionally more rename/dispatch bandwidth, more issue queue entries to hold in-flight instructions, and wider commit logic. XiangShan compensates with its large 352-entry ROB and generous physical register files. The trade-off is increased area and power for the in-order frontend pipeline stages, which must scale with width even if the out-of-order window only uses a fraction of the bandwidth on average.

---

## 10.14 Pipeline Timing Diagram

The following diagram shows the cycle-by-cycle flow of instructions through the backend under ideal conditions (no stalls, no mispredictions):

```
Cycle:        0     1     2     3     4     5     6     7     8
            ┌─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┐
Instr i     │ Dec │ Ren │ Dsp │ OG0 │ OG1 │ Exe │ WB  │ Cmt │     │
            └─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┘
            ┌─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┐
Instr i+1   │     │ Dec │ Ren │ Dsp │ OG0 │ OG1 │ Exe │ WB  │ Cmt │
            └─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┘
            ┌─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┐
Instr i+2   │     │     │ Dec │ Ren │ Dsp │ ... │     │     │     │
            └─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┘

Dec = Decode, Ren = Rename, Dsp = Dispatch, OG0 = Issue/Select,
OG1 = RegFile Read + Bypass, Exe = Execute, WB = Writeback, Cmt = Commit
```

**Figure 10.2: Ideal pipeline timing.** Each instruction spends one cycle in each in-order stage (Decode, Rename, Dispatch). The out-of-order stages (OG0–WB) may vary: OG0 may take multiple cycles if operands are not ready, and execution latency depends on the functional unit. Commit happens when the instruction reaches the ROB head.

In the presence of a **data dependency**, the OG0 stage stretches:

```
Cycle:        0     1     2     3     4     5     6     7     8     9
            ┌─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┐
ADD x3,x1,x2│ Dec │ Ren │ Dsp │ OG0 │ OG1 │ Exe │ WB  │     │ Cmt │     │
            └─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┘
                                       ↓ wake-up of x3
            ┌─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┐
SUB x4,x3,x5│     │ Dec │ Ren │ Dsp │wait │ OG0 │ OG1 │ Exe │ WB  │     │
            └─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┘
                                  ↑ waits for x3 (p88)
```

With speculative wake-up and bypass, the SUB can issue one cycle after the ADD issues (because the ALU has 1-cycle latency and the bypass network forwards the result):

```
Cycle:        0     1     2     3     4     5     6     7     8     9
            ┌─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┐
ADD x3,x1,x2│ Dec │ Ren │ Dsp │ OG0 │ OG1 │ Exe │ WB  │     │ Cmt │     │
            └─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┘
                               spec wakeup↓  forward↓
            ┌─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┐
SUB x4,x3,x5│     │ Dec │ Ren │ Dsp │     │ OG0 │ OG1 │ Exe │ WB  │     │
            └─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┘
```

**Figure 10.3: Back-to-back execution with speculative wake-up and bypass.** The ADD issues at cycle 3 and produces its result at cycle 5. The speculative wake-up fires at cycle 3 (issue time), allowing the dependent SUB to issue at cycle 5. The bypass network forwards the ADD's result directly to the SUB's OG1 stage, achieving zero-bubble dependent execution.

---

## 10.15 Branch Misprediction Recovery Timing

When a branch misprediction is detected, the redirect pipeline takes several cycles to propagate:

```
Cycle:         0          1          2          3          4          5
             ┌──────────┬──────────┬──────────┬──────────┬──────────┬──────────┐
Redirect     │ EXU      │ Redir    │ Flush    │ Flush    │ FTQ      │ New      │
Pipeline     │ detect   │ Gen      │ IQ+      │ propagate│ →front   │ fetch    │
             │          │ select   │ DataPath │          │          │ begins   │
             └──────────┴──────────┴──────────┴──────────┴──────────┴──────────┘
                        s1_s3      s2_s4      s3_s5
```

**Figure 10.4: Misprediction recovery timeline.** The branch unit detects the misprediction at execution time. The RedirectGenerator selects the oldest misprediction (s1/s3). The flush propagates through Regions (s2/s4) and to the frontend FTQ (s3/s5). New instructions begin arriving from the correct path several cycles later. With rename snapshots, the rename table can be restored in 1 cycle rather than walking the ROB.

---

## 10.16 Source Code Map

The following table maps the major concepts discussed in this chapter to their primary source files:

| Concept | Primary File | Key Class |
|---------|-------------|-----------|
| Backend top-level | [Backend.scala](src/main/scala/xiangshan/backend/Backend.scala) | `BackendInlinedImp` |
| Backend parameters | [BackendParams.scala](src/main/scala/xiangshan/backend/BackendParams.scala) | `BackendParams` |
| Core parameters | [Parameters.scala](src/main/scala/xiangshan/Parameters.scala) | `XSCoreParameters` |
| Control block | [CtrlBlock.scala](src/main/scala/xiangshan/backend/CtrlBlock.scala) | `CtrlBlockImp` |
| Execution region | [Region.scala](src/main/scala/xiangshan/backend/Region.scala) | `Region` |
| Data path | [DataPath.scala](src/main/scala/xiangshan/backend/datapath/DataPath.scala) | `DataPath` |
| Bypass network | [BypassNetwork.scala](src/main/scala/xiangshan/backend/datapath/BypassNetwork.scala) | `BypassNetwork` |
| Execution units | [ExuBlock.scala](src/main/scala/xiangshan/backend/exu/ExuBlock.scala) | `ExuBlock` |
| Writeback arbitration | [WbArbiter.scala](src/main/scala/xiangshan/backend/datapath/WbArbiter.scala) | `WbDataPath` |
| Issue queue | [IssueQueue.scala](src/main/scala/xiangshan/backend/issue/IssueQueue.scala) | `IssueQueueImp` |
| FU configuration | [FuConfig.scala](src/main/scala/xiangshan/backend/fu/FuConfig.scala) | `FuConfig` |
| XSCore integration | [XSCore.scala](src/main/scala/xiangshan/XSCore.scala) | `XSCoreImp` |

---

## 10.17 Checkpoint Questions

**Basic:**

1. What are the three major mechanisms that enable out-of-order execution, and which backend module implements each one?

2. Name the three execution Regions in the backend. For each Region, give one example of a functional unit it contains and the type of register file it uses.

3. What is the purpose of the ROB, and why must it retire instructions in program order even though they execute out of order?

**Intermediate:**

4. Explain the difference between speculative (IQ-to-IQ) wake-up and non-speculative (WB) wake-up. Why is speculative wake-up used for ALU operations but not for cache-missing loads?

5. The redirect pipeline takes multiple cycles to propagate (s1_s3 → s2_s4 → s3_s5). Why is this pipelining necessary, and what is the cost in terms of misprediction penalty?

6. With a 352-entry ROB and 8-wide commit, what is the maximum number of cycles the ROB can buffer instructions before filling? Under what conditions would the ROB actually become the throughput bottleneck?

**Advanced:**

7. XiangShan's integer scheduler issues load and store *address* operations alongside ALU and branch operations, even though loads and stores execute in the MemBlock. What are the advantages and disadvantages of this design choice compared to having a dedicated memory scheduler?

8. The register cache holds 28 entries (16 integer + 12 memory). Design an experiment to measure the hit rate of the register cache under different workloads. What workload characteristics would lead to a low hit rate, and how would this affect overall IPC?

---

## 10.18 Further Reading

- R. M. Tomasulo. "An Efficient Algorithm for Exploiting Multiple Arithmetic Units." *IBM Journal of Research and Development*, 11(1):25–33, January 1967. (The foundational paper on register renaming and dynamic scheduling.)
- J. E. Smith and A. R. Pleszkun. "Implementing Precise Interrupts in Pipelined Processors." *IEEE Transactions on Computers*, 37(5):562–573, May 1988. (The case for in-order commit via reorder buffers.)
- M. Moudgill, K. Pingali, and S. Vassiliadis. "Register Renaming and Dynamic Speculation: an Alternative Approach." *MICRO-26*, 1993. (Compares reservation station vs. physical register file approaches.)
- S. McFarling. "Combining Branch Predictors." *DEC WRL Technical Note TN-36*, June 1993. (Context for understanding how frontend prediction quality affects backend utilization.)
- XiangShan Kunminghu Architecture Documentation: https://xiangshan-doc.readthedocs.io/

---

### Key Takeaways

- The XiangShan backend is a **superscalar, out-of-order execution engine** with an 8-wide in-order frontend pipeline (decode → rename → dispatch) feeding three independent execution Regions (integer, floating-point, vector) that execute instructions out of program order.

- The architecture cleanly separates a **control plane** (CtrlBlock: decode, rename, dispatch, ROB, redirect) from a **data plane** (three Regions, each containing issue queues, register file access, bypass network, execution units, and writeback arbitration).

- **Register renaming** maps 32 logical integer registers to 224 physical registers, eliminating false dependencies. Five separate register files serve integer, FP, vector, v0 (mask), and vl (vector length) operands.

- A **multi-level wake-up and bypass** system — speculative IQ-to-IQ wake-up, registered bypass, and a 28-entry register cache — minimizes the effective latency of dependent instruction chains.

- **Recovery from misprediction** uses a pipelined redirect mechanism with up to 4 rename snapshots for fast state restoration. The redirect pipeline spans 3–5 cycles from detection to new fetch, determining the effective branch misprediction penalty.
