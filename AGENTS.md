# XiangShan Textbook Agent Guide

This repository is used to write a textbook on XiangShan (香山) Kunminghu (昆明湖) RISC-V CPU microarchitecture.

## 1) Mission, Audience, and Method

### Mission
Produce a coherent, technically accurate textbook that explains XiangShan from system view
down to module-level microarchitecture, using RTL as ground truth.

### Audience
- Primary reader: senior undergraduate / graduate students.
- Assumed background: RISC-V ISA knowledge.
- Not assumed: prior CPU microarchitecture expertise.

### Method: Literate Programming (LP) in this repo
Follow a literate-programming style inspired by Donald Knuth (1984): explain the design in
natural language first, then anchor claims in implementation.

For this project, LP means:
- The book is prose-first.
- Do **not** paste large code excerpts into chapters.
- Instead, cite exact source locations with clickable links into this codebase.

## 2) Source Priority and Truth Model

When sources disagree, resolve in this order:
1. RTL/Chisel implementation in this repository and submodules (final ground truth)
2. `XiangShan-Design-Doc/` design docs (prefer Chinese text if EN/CN differ)
3. External papers/blogs/slides used only for context and comparison

## 3) Repository Map

Main implementation directories:
- `src/main/scala/xiangshan/`: core pipeline and microarchitecture
- `src/main/scala/system/`: SoC wrappers
- `src/main/scala/device/`: simulation/peripheral devices
- `src/main/scala/top/`: top-level generators
- `src/main/scala/utils/`: shared utilities/transforms

Tests and generated outputs:
- `src/test/scala/`: Scala/Chisel tests
- `build/rtl`, `build/emu`: generated RTL and emulator artifacts

Key submodules:
- `difftest/`, `huancun/`, `coupledL2/`, `openLLC/`, `rocket-chip/`, `ready-to-run/`

## 4) Build, Validation, and Dev Commands

Environment and setup:
- `make init` or `make init-force`

Build and simulation:
- `make verilog CONFIG=TLConfig`
- `make sim-verilog CONFIG=TLConfig`
- `make emu -j16 CONFIG=TLConfig`

Tests and formatting:
- `make test`
- `make test-DecodeUnit`
- `make check-format`
- `make reformat`
- `make clean`

Wave dump flow (emu):
- Build with trace:
  - `make emu CONFIG=TLConfig EMU_TRACE=1` (VCD)
  - `make emu -j16 CONFIG=TLConfig EMU_TRACE=fst` (FST)
- Run with dump:
  - `./build/emu -i ./ready-to-run/coremark-2-iteration.bin --dump-wave`
  - Optional: `--dump-wave-full`
  - Optional: `--wave-path ./build/xs.vcd`
- Note: if built without `EMU_TRACE`, runtime dump flags do not work.
- Note: `--enable-fork` disables waveform dumping.

macOS reminder:
- `source ./setvars_osx.sh`
- `mill clean xiangshan.forkEnv` after env/PATH changes
- Then run `make verilog` or `make -B verilog`

### macOS + zsh shell safety (important for agents)

This repo is commonly operated from **macOS + `zsh`**. Agent-run shell snippets must avoid `zsh`
pitfalls that can silently break command lookup.

- Prefer `zsh`-safe variable names in scripts. Do **not** use `path` as a temporary variable name.
  In `zsh`, `path` is tied to `PATH`; assigning to it can remove command search paths and cause
  false "`command not found`" errors.
- Use names like `file_path`, `target_path`, `src_path`, `dst_path` instead of `path`.
- If command resolution looks suspicious, verify with:
  - `echo $SHELL`
  - `echo $PATH`
  - `command -v python3`
  - `command -v realpath`
- When needed in automation, prefer explicit binaries (for example `/bin/realpath`) to reduce
  shell-env ambiguity.
- If a script depends on `bash` behavior, run it explicitly with `bash -lc '...'` rather than
  assuming `zsh` semantics.

## 5) Writing Contract (Must Follow)

### Core writing rules
- Teach from problem -> mechanism -> trade-off -> evidence.
- Define terms at first use.
- Build from simple mental model to full design.
- Keep narrative continuity across chapters.
- Keep prose professional and clear by default; avoid repeated audience callouts such as "for students",
  "for beginners", or similar framing.

### Code citation rules
- Use clickable links with line anchors; no large pasted code.
- Standard path format:
  - `[Module.scala:123](src/main/scala/.../Module.scala#L123)`
- Submodule format:
  - `[Directory.scala:88](coupledL2/src/main/scala/.../Directory.scala#L88)`
- Do not paste more than 5 lines of code inline.

### Diagram rules
Each chapter must include:
- subsystem block diagram
- step-by-step data-flow diagram
- pipeline/timing diagram (cycle behavior)
- FSM/state diagram for any control machine

Diagrams should be described clearly enough to render in Mermaid/TikZ/draw.io.

### Table rules
Use tables for:
- parameters
- I/O interfaces
- CSR maps
- queue/stage breakdowns

Parameter table requirement:
- parameter names must be clickable links to definitions
- if multiple parameters appear in one row, each name is linked inline
- no separate trailing reference list for those rows

### Pedagogical elements
Each chapter should include:
- at least one **Worked Example**
- at least one **Design Trade-off** sidebar
- chapter-end **Key Takeaways** (3-5 bullets)
- chapter-end **Checkpoint Questions** (5-8, Basic/Intermediate/Advanced)

## 6) Chapter Template (Default)

1. Motivation and design challenge
2. Subsystem context in full-chip view
3. Module boundary and external interfaces
4. Internal pipeline/data-path walkthrough
5. Control/state-machine behavior
6. Parameterization and configuration knobs
7. Worked example(s)
8. Design trade-off discussion
9. Key takeaways
10. Checkpoint questions
11. Further reading (3-5 references)

## 7) Educational Principles

1. Motivate before explaining mechanisms.
2. Build complexity incrementally.
3. Ground abstraction with concrete traces.
4. Explain why this design was chosen over alternatives.
5. Define terminology precisely at first use.
6. End chapters with review and exercises.
7. Use layered diagrams: overview then zoom-in.
8. Connect to literature and industry designs.
9. Provide intuition first, then formal detail.
10. Preserve narrative continuity across the whole book.

## 8) Book Outline

### Part I - Overview and Fundamentals
1. Introduction
2. Architecture at a Glance
3. SoC Integration

### Part II - Frontend (Instruction Supply)
4. Frontend Overview
5. Branch Prediction Unit (uBTB, TAGE, SC, ITTAGE, RAS, FTB, history)
6. Fetch Target Queue
7. Instruction Cache
8. Instruction Fetch Unit
9. Instruction Buffer

### Part III - Backend (Execution Engine)
10. Backend Overview
11. Decode Stage
12. Rename Stage
13. Dispatch
14. Issue Queues and Scheduling
15. Physical Register File
16. Functional Units (ALU/BRU/MulDiv/BKU/FP/Vector/CSR)
17. Reorder Buffer
18. Data Path and Writeback

### Part IV - Memory Subsystem
19. Memory Subsystem Overview
20. Load Pipeline
21. Store Pipeline
22. Load Queue and Store Queue
23. L1 Data Cache
24. Hardware Prefetching
25. MMU

### Part V - Cache Hierarchy and Interconnect
26. L2 Cache (CoupledL2)
27. L3 Cache / LLC (HuanCun / OpenLLC)
28. Coherence Protocol (TileLink + CHI)

### Part VI - Privileged Architecture and Debug
29. Privilege Modes and Trap Handling
30. Performance Counters and Events
31. Debug and Trace

### Part VII - Physical Design Considerations
32. Clock, Reset, and Power Management
33. Design for Testability

### Appendices
A. Full `XSCoreParameters` table
B. Bundle/signal glossary
C. `FuConfig` reference table
D. CSR map (`NewCSR/`)
E. Build and simulation guide
F. Glossary of terms and acronyms

## 9) Style and Contribution Hygiene

- Scala/Chisel formatting follows `scalafmt` and `scalastyle`.
- Max line length: 120, no tabs, newline at EOF.
- Naming: `UpperCamelCase` (types), `lowerCamelCase` (fields/args), lowercase packages.
- Prefer explicit imports.

Commit/PR style:
- Commit format: `type(scope): imperative summary` (e.g., `fix(MDP): ...`).
- Keep functional changes, refactors, and formatting in separate commits when practical.
- PRs should state: problem, solution, impacted configs/modules, validation commands/results, linked issue.
