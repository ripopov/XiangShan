# Chapter 26. Directory-Based Coherence and Networks-on-Chip

<!-- Status: Detailed plan — content to be written -->

---

## Purpose

This chapter is the conceptual foundation for Part V. It teaches directory-based
cache coherence and network-on-chip interconnects as general mechanisms, independent
of any specific protocol. A reader who finishes this chapter should be able to
explain *why* a multi-core chip needs a coherence directory, *how* snooping scales
(and where it breaks), and *what* a network-on-chip does for cache traffic — all
before encountering a single line of AMBA CHI or XiangShan RTL.

The chapter follows the Conceptual Introduction Guideline: problem first, naive
attempt, incremental refinement, worked examples, trade-offs.

---

## Table of Contents

### 1. The Coherence Problem at Scale

1.1. Why Caches Create Correctness Problems in Multi-Core
   - The stale-data scenario: two cores, one shared variable, two L1 copies
   - Write propagation and write serialization as the two invariants
   - Quantitative pain: IPC collapse without coherence (motivating numbers)

1.2. Snooping: The First Solution and Its Limits
   - Bus-based snooping: broadcast every miss to all caches
   - Why it works at 2-4 cores: shared bus serializes all requests
   - Why it breaks at 8+ cores: bus bandwidth wall, snoop storm energy cost
   - ASCII diagram: "Bus snoop at 4 cores vs. 16 cores" showing bandwidth collapse

1.3. The Directory Idea: Track Who Has What
   - Central ledger that records which caches hold each line and in what state
   - Directed messages instead of broadcasts: only notify caches that care
   - Bandwidth scales O(1) per miss instead of O(N)

### 2. Directory-Based Coherence Mechanisms

2.1. Directory Organization
   - Full bit-vector directory: one bit per cache per line (precise, expensive)
   - Coarse bit-vector: group caches, trade precision for area
   - Limited pointer directory: track K sharers, fall back to broadcast
   - Snoop filter: inverse directory that tracks only cached lines

2.2. Directory State Machine
   - States per line: Invalid, Shared (clean copies), Exclusive/Modified (single owner)
   - Mapping to MOESI: which states the directory tracks vs. which the caches track
   - State transition diagram (Mermaid FSM)

2.3. Point-of-Coherence and Point-of-Serialization
   - PoC: the location where all observers agree on the latest value
   - PoS: the location where all requests to the same address are ordered
   - Why these concepts matter for correctness and for understanding CHI (Chapter 27)

2.4. Inclusion Policies
   - Inclusive directory: LLC always has a copy — simplifies snoop filtering
   - Exclusive directory: data lives in exactly one level — maximizes effective capacity
   - Non-inclusive (NINE): directory tracks presence but LLC may or may not hold data
   - Trade-offs table: hit rate vs. back-invalidation traffic vs. directory size

### 3. Coherence Transactions Step by Step

3.1. Read Miss to Shared Line (Simple Case)
   - Requester → Directory → Data response (no snoop needed)
   - Cycle-by-cycle trace with 4-entry toy directory

3.2. Read Miss to Exclusively-Owned Line (Snoop Required)
   - Requester → Directory → Snoop owner → Data transfer → Directory update
   - Three-party handshake: request, snoop, completion

3.3. Write Miss: Upgrade from Shared to Modified
   - Invalidation of all sharers before granting write permission
   - Why this is the expensive case: fan-out scales with sharer count

3.4. Eviction and Write-Back
   - Owner writes back dirty data → Directory transitions to Invalid
   - Silent eviction of clean lines: directory must still be notified

### 4. Networks-on-Chip: Moving Coherence Traffic

4.1. Why a Bus Is Not Enough
   - Bandwidth and wire-length limits of shared buses
   - The network-on-chip as a packet-switched fabric for cache messages

4.2. Topology Vocabulary
   - Crossbar: full connectivity, O(N^2) area, lowest latency
   - Ring: O(N) area, bounded latency, used in Intel Sandy Bridge through Skylake
   - 2D Mesh: O(N) area, scalable to many-core, used in ARM CMN and Intel server parts
   - Hierarchical: clusters with local crossbar, global ring/mesh
   - Comparison table: area, latency, bisection bandwidth

4.3. Router Microarchitecture (Conceptual)
   - Input buffers, crossbar switch, output ports
   - Virtual channels: preventing deadlock by separating traffic classes
   - Credit-based flow control: sender tracks receiver buffer space

4.4. Routing
   - Deterministic (XY routing): simple, deadlock-free, no adaptivity
   - Adaptive routing: better load balance, harder to verify
   - Source routing vs. table-based routing

4.5. Mapping Coherence to NoC Channels
   - Request, response, snoop, data as logical channels
   - Why separate physical channels prevent protocol deadlock
   - Message classes and virtual networks

### 5. Worked Example: 4-Core Directory Coherence on a Ring

5.1. Setup
   - 4 cores on a bidirectional ring, one home node with directory
   - Cache line X starts in Invalid everywhere

5.2. Trace: Core 0 Reads X, Then Core 2 Writes X
   - Step-by-step message flow with ring hop counts
   - Directory state after each transaction
   - Total latency in hops and cycles

5.3. Trace: Core 1 Reads X (Now Modified in Core 2)
   - Snoop, intervention, data forwarding
   - Comparison: what would snooping broadcast cost?

### 6. Design Trade-Offs

6.1. Snooping vs. Directory
   - Spectrum: pure broadcast ↔ pure directory ↔ hybrid
   - Snoop filter as practical middle ground

6.2. Crossbar vs. Ring vs. Mesh
   - Performance: latency sensitivity vs. bandwidth per mm^2
   - Area: quadratic vs. linear scaling
   - Design effort: verification complexity grows with topology

6.3. Directory Precision vs. Area
   - Full bit-vector is precise but O(N) bits per line
   - Limited-pointer schemes save area, add broadcast fallback
   - Snoop filter tracks only cached lines: area proportional to cache, not memory

6.4. Inclusive vs. Non-Inclusive LLC
   - Effective capacity vs. coherence traffic vs. directory complexity
   - How the inclusion policy constrains eviction and back-invalidation

### 7. Common Misconceptions

- **"Snooping is obsolete."** Snooping is still used inside clusters (e.g., ARM DSU).
  The key insight is that snooping and directories coexist at different hierarchy levels.

- **"A directory eliminates all broadcasts."** Limited-pointer overflow and snoop filter
  evictions can trigger broadcast fallbacks. No practical directory is fully precise at
  reasonable area cost.

- **"More cache levels always help."** An additional level adds latency on every miss
  that passes through it. The benefit depends on working-set size distribution — the
  wrong sizing can make things worse.

### 8. Key Takeaways

1. Directory-based coherence replaces broadcast snooping with targeted messages,
   enabling O(1)-per-miss bandwidth scaling in multi-core systems.
2. The directory tracks per-line state and sharer identity; its organization
   (bit-vector, pointer, snoop filter) trades area for precision.
3. Point-of-Coherence and Point-of-Serialization are the anchoring concepts for
   understanding where correctness is enforced in the hierarchy.
4. Networks-on-chip provide the physical fabric for coherence traffic; topology
   choice (crossbar, ring, mesh) is a three-way trade-off of area, latency, and
   bandwidth.
5. Separate message channels (request, response, snoop, data) on the NoC prevent
   protocol-level deadlocks.

### 9. Checkpoint Questions

**Basic:**
1. Why does bus-based snooping fail to scale beyond ~8 cores?
2. What two invariants must a cache coherence protocol enforce?
3. What is the role of a snoop filter, and how does it differ from a full directory?

**Intermediate:**
4. In a non-inclusive LLC, what happens when the LLC must evict a line that is
   still cached in L2? Compare with an inclusive design.
5. Why do coherence protocols need separate NoC virtual channels for requests
   and responses? What deadlock scenario arises without them?

**Advanced:**
6. A 16-core chip uses a full bit-vector directory. Each directory entry needs
   one presence bit per core plus state bits. Calculate the directory storage
   overhead as a percentage of L3 capacity for 64B lines, 16MB L3, assuming
   3 state bits per entry.
7. Compare ring and mesh topologies for a 16-core design in terms of worst-case
   hop count, bisection bandwidth, and router count. Under what workload
   characteristics does mesh become clearly superior?
8. Design a hybrid coherence scheme where a 4-core cluster uses snooping internally
   and directory-based coherence across clusters. What are the boundary conditions
   for coherence correctness at the cluster interface?

### 10. Further Reading

1. Sorin, Hill, and Wood, *A Primer on Memory Consistency and Cache Coherence*
   (2nd ed., 2020) — the definitive graduate reference on coherence.
2. Dally and Towles, *Principles and Practices of Interconnection Networks*
   (2004) — topology, routing, and flow control fundamentals.
3. ARM CoreLink CMN-700 Technical Reference Manual — industry mesh interconnect
   for CHI-based systems.
4. Martin, Hill, and Sorin, "Why On-Chip Cache Coherence Is Here to Stay"
   (CACM 2012) — debunks the myth that coherence is too expensive.
5. Chapter 27 of this book — applies these concepts to the AMBA CHI protocol
   specifically.
