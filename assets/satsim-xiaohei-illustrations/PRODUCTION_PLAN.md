# SatelliteSimJulia Xiaohei Illustration Production Plan

> Goal: build a complete, fine-grained 100+ image illustration set for the project using the `ian-xiaohei-illustrations` skill.

## Quality Gate

Every accepted image must pass:

- Xiaohei is doing the core action, not decorating the corner.
- White background, hand-drawn black line art, lots of whitespace.
- No formal dependency graph, no PPT architecture diagram, no course slide.
- 5-8 short labels at most.
- One image, one cognitive anchor.
- Red is warning/result only; orange is flow/path only; blue is secondary system note only.
- The metaphor is specific to SatelliteSimJulia and does not reuse the previous example compositions.

## Coverage Map

Planned target: 120 shots, with room to reject/regenerate weak images.

| Block | Target Count | Scope |
|---|---:|---|
| A. Overview and mental model | 10 | time decoupling, dispatch, array contract, module boundary |
| B. Foundation / Orbit / Link / Metrics | 20 | constants, time, coordinates, Walker, SGP4/J2/J4, ISL/GSL, coverage |
| C. Net / Traffic / Distributed | 20 | topology, routing, load, latency, queues, distributed execution |
| D. Opt / PINN / dSGP4 | 16 | differentiable propagation, gradients, neural residuals, training data |
| E. Lab / Experiment / AI orchestration | 18 | experiment factory, precomposed tools, planner, study DSL, agent flow |
| F. Server / MCP / Godot / Viz | 16 | websocket frames, MCP tools, client rendering, sandbox controls |
| G. Testing / validation / recovery | 14 | regression ladder, module recovery, dirty worktree isolation, CI gates |
| H. Literature / roadmap / paper story | 10 | related work layers, benchmark matrix, paper narrative, roadmap |

## Batch Strategy

1. Build and review a 100+ shot list before generating the full set.
2. Generate images in batches of 6-10 to keep QA sharp.
3. Prefer regenerating weak images over accepting coarse diagrams.
4. Keep rejected or draft versions only if useful for comparison.
5. Update this plan after each batch with accepted image paths.

## Accepted Images

| ID | File | Status | Use |
|---|---|---|---|
| A-001 | `001-overview-time-slicer.png` | accepted | Project overview: time decoupling and `N×T×3` contract |
| A-002 | `002-overview-dispatch-workbench.png` | accepted | Multiple dispatch as one workbench with swappable tool heads |
| A-003 | `003-overview-one-way-valve.png` | accepted | One-way dependency discipline across the module chain |
| A-004 | `004-overview-tools-and-bento.png` | accepted | Atomic tools and precomposed convenience tools as a bento box |
| A-005 | `005-overview-core-customs-window.png` | accepted | Core as a reexport pass-through customs window |
| A-009 | `009-overview-two-input-gates.png` | accepted | Separate Orbit entry points for design-time Walker and real TLE/SGP4 data |
| B-FDN-01 | `011-foundation-lowest-stone.png` | accepted | Foundation as the low load-bearing stone |
| B-FDN-02 | `012-foundation-coordinate-doors.png` | accepted | Coordinate conversion as controlled rotating doors |
| B-FDN-03 | `013-foundation-time-clothesline.png` | accepted | Shared simulation time as a clothesline for module samples |
| B-FDN-04 | `014-foundation-entity-locker.png` | accepted | Lightweight entity contracts as ID/config cards in lockers |
| B-ORB-01 | `016-orbit-ephemeris-noodle.png` | accepted | Orbit ephemeris as consumable position sequence |
| B-ORB-02 | `017-orbit-propagator-scale.png` | accepted | Propagator fidelity/cost tradeoff for `two_body`, `J2`, `J4`, and `SGP4` |
| B-ORB-03 | `018-orbit-walker-seed-tray.png` | accepted | Walker-Delta generation as satellite seeds in plane grooves |
| B-ORB-04 | `019-orbit-tle-ticket-gate.png` | accepted | TLE as a real-data ticket scanned through SGP4 |
| B-LNK-01 | `021-link-five-laser-gates.png` | accepted | ISL/GSL physical constraints as five laser gates |
| B-LNK-02 | `022-link-glass-earth-ruler.png` | accepted | Link geometry around Earth obstruction |
| B-LNK-03 | `023-link-ground-cups.png` | accepted | GSL evaluation as ground cups catching valid signal drops |
| B-MET-01 | `026-metrics-tailor-ruler.png` | accepted | Metrics as pure measurement without mutation |
| B-MET-02 | `027-metrics-latency-bead-sieve.png` | accepted | Latency distribution as a bead sieve that preserves tail latency |
| C-TOPO-01 | `031-topology-edge-punch.png` | accepted | Topology generation as positions-to-edge-list punch machine |
| C-TOPO-02 | `032-topology-shoelace-cards.png` | accepted | Topology strategies as shoelace patterns on satellite buttons |
| C-ROUTE-01 | `035-routing-three-door-envelope.png` | accepted | End-to-end route as `GSL + ISL + GSL` packet movement |
| C-ROUTE-02 | `036-routing-stopwatch-weight.png` | accepted | Routing edge weights as stopwatch weights clipped to strings |
| C-TRAF-02 | `042-traffic-offered-carried-dropped.png` | accepted | Traffic accounting as offered/carried/dropped bowls |
| C-TRAF-04 | `044-traffic-intent-postoffice.png` | accepted | Traffic intent stamped into structured demand cards |
| C-DIST-01 | `046-distributed-toolbox-suitcases.png` | accepted | Monolithic toolbox split into per-satellite suitcases |
| C-DIST-04 | `049-distributed-length-json-hat.png` | accepted | JSON worker messages with length hats |
| D-OPT-01 | `052-opt-gradient-backflow.png` | accepted | Differentiable simulation as gradient backflow from loss to orbital parameters |
| D-OPT-04 | `055-opt-dual-number-shadow.png` | accepted | Dual numbers as a value curve carrying a derivative shadow |
| D-OPT-05 | `056-opt-soft-threshold-sandpaper.png` | accepted | Hard thresholds sanded into differentiable ramps |
| D-OPT-10 | `061-opt-discrete-f-gear.png` | accepted | Discrete Walker phase `F` as a clicky gear |
| D-PINN-12 | `063-pinn-crack-rail-patch.png` | accepted | Residual PINN as a patch on a J2 baseline rail |
| D-DSGP4-16 | `067-dsgp4-correction-tunnel.png` | accepted | dSGP4 as a correction-mirror tunnel |
| E-LAB-01 | `068-lab-three-layer-airlock.png` | accepted | Lab boundary as pressure jars connected by a translation valve |
| E-LAB-02 | `069-lab-universal-socket.png` | accepted | ExperimentConfig as a universal socket |
| E-LAB-07 | `074-lab-experiment-cartridge.png` | accepted | Custom experiment dispatch as a cartridge |
| E-LAB-08 | `075-lab-sweep-abacus.png` | accepted | Parameter sweep as abacus beads with failure isolation |
| E-LAB-11 | `078-lab-cache-fridge.png` | accepted | Experiment cache as a hash-keyed fridge |
| E-LAB-14 | `081-lab-teamgraph-theater.png` | accepted | TeamGraph handoff as a puppet theater |
| F-AI-11 | `096-ai-study-origami.png` | accepted | User intent folded into Study DSL |
| F-AI-12 | `097-ai-missing-fields-drawers.png` | accepted | Missing fields as drawers that trigger questions |
| F-SRV-01 | `086-server-physical-projector.png` | accepted | Julia server projects core simulation frames without rewriting physics |
| F-SRV-03 | `088-server-menu-handwritten-order.png` | accepted | Catalog constellations and custom Walker requests as menu plus handwritten order |
| F-MCP-09 | `094-mcp-sandbox-fence.png` | accepted | MCP safety as a bounded sandbox fence |
| F-MCP-10 | `095-mcp-whitelist-mask.png` | accepted | Package whitelist and token audit as gate plus masked ledger |
| F-LONG-16 | `101-longtask-pressure-vessel.png` | accepted | AIRun state/results/artifacts as a pressure vessel |
| G-TEST-02 | `103-test-milestone-lamps.png` | accepted | Milestones as lamps lit only after validation |
| G-TEST-03 | `104-test-validation-ladder.png` | accepted | Layer validation as a regression ladder |
| G-TEST-06 | `107-test-failure-medical-chart.png` | accepted | Failure attribution as calm diagnosis |
| H-LIT-01 | `118-literature-ten-layer-library.png` | accepted | Literature corpus organized into module-aligned technical shelves |
| H-LIT-03 | `120-literature-link-prism.png` | accepted | Link literature split into practical concern beams |
| H-LIT-04 | `121-literature-routing-maze.png` | accepted | Routing literature cut into implementation hooks |
| H-LIT-05 | `122-literature-traffic-hourglass.png` | accepted | Traffic demand filtered through capacity into metric bowls |
| H-LIT-07 | `124-literature-ai-orchestration-switchboard.png` | accepted | Agent literature converted into guarded tool orchestration |
| H-LIT-08 | `125-literature-benchmark-matrix-quilt.png` | accepted | Benchmark matrix as a stitched capability quilt |
| H-LIT-09 | `126-literature-roadmap-four-sprints.png` | accepted | Roadmap as four validated sprint carts |
| H-LIT-10 | `127-literature-paper-story-funnel.png` | accepted | Paper story filters literature into time decoupling and dispatch |
| F-AI-13 | `098-ai-four-narrow-gates.png` | accepted | Tool calls pass narrow registry/schema/budget/audit gates |
| F-AI-14 | `099-ai-teamgraph-spiral-stair.png` | accepted | Multi-agent handoff as artifact passing on a spiral stair |
| F-LONG-15 | `100-longtask-footprint-wax.png` | accepted | Durable execution leaves replayable wax-paper footprints |
| G-TEST-01 | `102-test-nine-railings.png` | accepted | Work discipline as bridge railings for surgical changes |
| G-TEST-04 | `105-test-parallel-stethoscopes.png` | accepted | Parallel package probes with a six-core listening box |
| G-TEST-05 | `106-test-package-drawers.png` | accepted | Package tests as independent pass/fail drawers |
| G-TEST-07 | `108-test-old-runtests-scroll.png` | accepted | Legacy runtests mined carefully for reusable assertions |
| G-TEST-08 | `109-test-assertion-transplant.png` | accepted | Mature assertions transplanted into focused testsets |
| G-TEST-09 | `110-test-mvp-gate.png` | accepted | Focused MVP regression as a repeatable core gate |
| G-TEST-10 | `111-test-real-tle-flattening.png` | accepted | Real TLE/SGP4 input flattened into the same array contract |
| G-TEST-11 | `112-test-minload-waterpipes.png` | accepted | MinLoad route choice as capacity-limited water pipes |
| G-TEST-12 | `113-test-temporal-routing-panels.png` | accepted | Time-varying route artifacts checked frame by frame |
| G-TEST-13 | `114-test-ai-evidence-receipts.png` | accepted | AI tool runs leave evidence receipts |
| G-TEST-14 | `115-test-viz-artifact-drying-line.png` | accepted | Viz artifacts are hung and inspected |
| G-TEST-15 | `116-test-night-ovens.png` | accepted | Overnight validation as batch ovens with status cards |
| G-TEST-16 | `117-test-sgp4-aon-pipe-repair.png` | accepted | SGP4-to-AON failures repaired segment by segment |
| B-FDN-05 | `015-foundation-unit-scale.png` | accepted | Foundation units and constants calibrated once at the root |
| B-ORB-05 | `020-orbit-sgp4-library-lens.png` | accepted | SGP4 library behavior exposed through Orbit API |
| B-LNK-04 | `024-link-telescope-lenses.png` | accepted | Different link models as swappable evaluator lenses |
| B-LNK-05 | `025-link-handover-lantern.png` | accepted | Temporal handover as a moving visibility lantern |
| B-MET-03 | `028-metrics-coverage-lightbox.png` | accepted | Coverage as visible/not-visible time tiles |
| C-TOPO-03 | `033-topology-magnet-fishpond.png` | accepted | Dynamic topology edges as swimming edge-fish |
| C-ROUTE-03 | `037-routing-ecmp-bridge.png` | accepted | Equal-cost paths as packet bridges around load |
| C-TRAF-03 | `043-traffic-link-load-drawer.png` | accepted | Link load as per-edge drawer contents |
| A-006 | `006-overview-lab-test-kitchen.png` | accepted | Lab combines tools into experiments without forcing one route |
| A-007 | `007-overview-array-contract-ruler.png` | accepted | Bare array contract measured across modules |
| A-008 | `008-overview-frame-laundry-line.png` | accepted | Simulation frames as ordered client slices |
| A-010 | `010-overview-module-relay.png` | accepted | Module recovery as dependency-order relay |
| F-SRV-02 | `087-server-five-drawers.png` | accepted | Fixed server request types as five drawers |
| F-SRV-04 | `089-server-digital-noodle-frame.png` | accepted | Per-frame positions flattened into numeric noodle strip |
| F-SRV-05 | `090-server-isl-laundry-lights.png` | accepted | ISL pairs and availability booleans align one-to-one |
| F-SRV-06 | `091-server-one-way-tunnel-ticket.png` | accepted | One WebSocket connection carries one simulation stream |
| E-LAB-03 | `070-lab-implementation-customs.png` | accepted | Concrete experiment names inspected before becoming public concepts |
| E-LAB-04 | `071-lab-precomposed-kitchen.png` | accepted | Precomposed helpers as prepared kitchen stations |
| E-LAB-05 | `072-lab-run-experiment-egg.png` | accepted | `run_experiment` as a thin-shell convenience wrapper |
| E-LAB-06 | `073-lab-standard-plate.png` | accepted | Lab data handoff as a standard plate |
| E-LAB-12 | `079-lab-comparison-scale.png` | accepted | Experiment results as comparable run cards |
| E-LAB-18 | `085-lab-factory-narrow-door.png` | accepted | Experiment factory entry as a narrow contract door |
| F-MCP-07 | `092-mcp-six-tool-drawers.png` | accepted | MCP tool surface as six bounded drawers |
| F-MCP-08 | `093-mcp-content-length-postbox.png` | accepted | JSON-RPC calls as Content-Length-stamped envelopes |
| C-DIST-02 | `047-distributed-event-loop-bench.png` | accepted | Each satellite owns a local event-loop workbench |
| C-DIST-03 | `048-distributed-barrier-gate.png` | accepted | Distributed workers sync at controlled barriers |
| C-DIST-05 | `050-distributed-statefulset-honeycomb.png` | accepted | Stateful workers return to stable cells |
| C-DIST-06 | `051-distributed-six-core-oven.png` | accepted | Available cores used intentionally as bounded oven slots |
| D-OPT-02 | `053-opt-array-drawer-cabinet.png` | accepted | Opt consumes the same `N x T x 3` drawer cabinet |
| D-OPT-03 | `054-opt-j2-potato-earth.png` | accepted | J2 perturbation as a flattened potato Earth |
| D-OPT-06 | `057-opt-adam-mixer-console.png` | accepted | Adam optimizer as feedback mixer console |
| D-OPT-07 | `058-opt-soft-isl-rubber-ruler.png` | accepted | Hard ISL threshold softened into a differentiable rubber ruler |
| draft-001 | `01-time-slicer.png` | optional | More detailed first draft |

## Batch 001

Contact sheet: `batch-001-contact-sheet.png`

Batch 001 covered the project overview plus first cross-layer anchors:

1. `001-overview-time-slicer` - already accepted as `02-time-slicer-clean.png`.
2. `002-overview-dispatch-workbench` - multiple dispatch as tool heads on one odd workbench.
3. `003-overview-no-reverse-dependency` - Xiaohei holding a one-way valve in a dependency pipe.
4. `009-overview-two-input-gates` - design-time Walker vs real TLE/SGP4 entry.
5. `017-orbit-propagator-scale` - two_body/J2/J4/SGP4 tradeoff.
6. `021-link-five-laser-gates` - Link physical constraints.
7. `031-topology-edge-punch` - positions to edge list.
8. `035-routing-three-door-envelope` - GSL/ISL/GSL route structure.
9. `052-opt-gradient-backflow` - loss-to-parameter gradient flow.

## Batch 002

Contact sheet: `batch-002-contact-sheet.png`

Batch 002 deepened the lower modules before jumping to Lab/AI:

1. `004-overview-tools-and-bento` - atomic tools vs precomposed convenience.
2. `005-overview-core-customs-window` - Core reexport pass-through.
3. `011-foundation-lowest-stone` - Foundation as the lowest load-bearing stone.
4. `013-foundation-time-clothesline` - shared time axis.
5. `016-orbit-ephemeris-noodle` - ephemeris as consumable position sequence.
6. `019-orbit-tle-ticket-gate` - real TLE entry.
7. `022-link-glass-earth-ruler` - geometry around Earth obstruction.
8. `026-metrics-tailor-ruler` - metrics as pure measurement.

Notes:

- `019-orbit-tle-ticket-gate` was regenerated once because the first version had a cute face and overly specific TLE text.
- `022-link-glass-earth-ruler` was regenerated once to reduce Xiaohei's smile/cute expression.
- `013-foundation-time-clothesline` is accepted, but future batches should stay stricter about sample-card text density.

## Batch 003

Contact sheet: `batch-003-contact-sheet.png`

Batch 003 diversified the low-level metaphors and started deeper Net/Opt coverage:

1. `012-foundation-coordinate-doors` - coordinate conversion as rotating doors.
2. `014-foundation-entity-locker` - simple entities as lockers.
3. `018-orbit-walker-seed-tray` - Walker constellation generation.
4. `023-link-ground-cups` - GSL ground station signal cups.
5. `027-metrics-latency-bead-sieve` - latency distribution samples.
6. `032-topology-shoelace-cards` - topology strategy variants.
7. `036-routing-stopwatch-weight` - routing weights as delay stopwatches.
8. `055-opt-dual-number-shadow` - ForwardDiff dual value and derivative shadow.

Notes:

- `012-foundation-coordinate-doors` needed multiple generations to reduce Xiaohei's face marks.
- `032-topology-shoelace-cards` was regenerated once to reduce title-like labels and diagram feel.
- `055-opt-dual-number-shadow` was accepted after a small black patch on the project copy removed a generated smile line; the original remains preserved.

## Batch 004

Contact sheet: `batch-004-contact-sheet.png`

Batch 004 broadened from core modules into Traffic / Distributed / Opt / PINN / dSGP4:

1. `042-traffic-offered-carried-dropped` - traffic accounting with three bowls.
2. `044-traffic-intent-postoffice` - demand modeling through stamped OD/time cards.
3. `046-distributed-toolbox-suitcases` - monolith split into per-satellite suitcases.
4. `049-distributed-length-json-hat` - worker protocol framing with a length hat.
5. `056-opt-soft-threshold-sandpaper` - smoothing hard constraints for gradients.
6. `061-opt-discrete-f-gear` - discrete phasing as a gear, not a smooth knob.
7. `063-pinn-crack-rail-patch` - residual PINN patches known physics.
8. `067-dsgp4-correction-tunnel` - dSGP4 correction mirrors around a differentiable core.

Notes:

- `044-traffic-intent-postoffice` was regenerated once to remove a title-like post-office sign.
- `049-distributed-length-json-hat` was regenerated once with side-facing Xiaohei to avoid a cute/smiling face.
- Batch 004 is one of the strongest batches so far: it uses bowls, suitcases, hats, sandpaper, gear, rail patch, and mirror tunnel rather than overused formal diagrams.

## Batch 005

Contact sheet: `batch-005-contact-sheet.png`

Batch 005 moved into Lab / Experiment / AI orchestration:

1. `068-lab-three-layer-airlock` - tools, experiment orchestration, and AI interaction as separated airlocks.
2. `069-lab-universal-socket` - experiment configs plugged into one socket.
3. `074-lab-experiment-cartridge` - custom experiment dispatch as arcade cartridges.
4. `075-lab-sweep-abacus` - parameter sweeps as abacus beads.
5. `078-lab-cache-fridge` - reusable experiment artifacts as a labeled fridge.
6. `081-lab-teamgraph-theater` - structured artifact handoff as a puppet theater.
7. `096-ai-study-origami` - user intent folded into Study DSL.
8. `097-ai-missing-fields-drawers` - missing fields as drawers that trigger questions instead of guesses.

Notes:

- `068-lab-three-layer-airlock` was regenerated because the first version looked too much like a stacked architecture diagram; the draft is preserved as `draft-068-lab-three-layer-airlock-v1.png`.
- `074-lab-experiment-cartridge` was regenerated once to reduce title-like labels.
- `075-lab-sweep-abacus` was regenerated once to remove a large sweep title sign.
- `096-ai-study-origami` was accepted after a small black patch removed a mouth-like arm line inside Xiaohei's body.
- `097-ai-missing-fields-drawers` was regenerated once with side-facing Xiaohei to avoid a smiling face.

## Batch 006

Contact sheet: `batch-006-contact-sheet.png`

Batch 006 covered Server / MCP / long-task execution / validation:

1. `086-server-physical-projector` - Julia server projects core simulation frames without rewriting physics.
2. `088-server-menu-handwritten-order` - catalog vs custom Walker as menu and handwritten order.
3. `094-mcp-sandbox-fence` - MCP safety as a bounded fence.
4. `095-mcp-whitelist-mask` - package whitelist and token audit as a masked ledger.
5. `101-longtask-pressure-vessel` - AIRun state/results/artifacts as a pressure vessel.
6. `103-test-milestone-lamps` - milestone completion as lamps lit one by one.
7. `104-test-validation-ladder` - layer-by-layer regression as a validation ladder.
8. `107-test-failure-medical-chart` - failure attribution as a calm medical chart.

Notes:

- `094-mcp-sandbox-fence` was accepted after contact-sheet review confirmed the red marks read as out-of-bounds actions, not rejected project goals.
- `101-longtask-pressure-vessel` stays metaphorical enough despite the system sockets; it does not drift into a Kubernetes or architecture chart.
- `107-test-failure-medical-chart` was regenerated once because the first stethoscope version created a mouth-like white curve on Xiaohei.

## Batch 007

Contact sheet: `batch-007-contact-sheet.png`

Batch 007 covered literature / paper story / roadmap:

1. `118-literature-ten-layer-library` - literature map as a layered library shelf.
2. `120-literature-link-prism` - link-model papers split through a prism.
3. `121-literature-routing-maze` - routing literature as a practical maze cut.
4. `122-literature-traffic-hourglass` - traffic models as demand passing through a capacity hourglass.
5. `124-literature-ai-orchestration-switchboard` - AI orchestration work as a guarded switchboard.
6. `125-literature-benchmark-matrix-quilt` - benchmark matrix as a stitched quilt.
7. `126-literature-roadmap-four-sprints` - roadmap as four small sprint carts.
8. `127-literature-paper-story-funnel` - paper narrative as a funnel from literature to two contribution cards.

Notes:

- `125-literature-benchmark-matrix-quilt` was regenerated because the first version had a mouth-like white line on Xiaohei; the accepted version keeps the matrix as an irregular cloth object.
- `127-literature-paper-story-funnel` was regenerated for the same Xiaohei mouth-line issue and to avoid a too-clean marketing funnel.
- `124-literature-ai-orchestration-switchboard` has an object label on the switchboard, but it was accepted because it functions as a physical prop rather than a slide title.

## Batch 008

Contact sheet: `batch-008-contact-sheet.png`

Batch 008 covered AI guardrails / durable execution / focused test recovery:

1. `098-ai-four-narrow-gates` - tool calls pass registry, schema, budget, HITL, and audit gates.
2. `099-ai-teamgraph-spiral-stair` - multi-agent handoff as structured artifact passing.
3. `100-longtask-footprint-wax` - durable execution leaves replayable traces and checkpoints.
4. `102-test-nine-railings` - the nine work rules as railings for surgical changes.
5. `105-test-parallel-stethoscopes` - independent package probes with explicit resource limits.
6. `106-test-package-drawers` - package tests as drawers opened independently.
7. `108-test-old-runtests-scroll` - old giant runtests file mined carefully.
8. `109-test-assertion-transplant` - mature assertions transplanted into focused `@testset`s.

Notes:

- `105-test-parallel-stethoscopes` avoids implying unlimited compute by making `6 cores` the physical listening box.
- `109-test-assertion-transplant` was regenerated because the first version had a mouth-like white body line on Xiaohei.
- Batch 008 is intentionally more process-heavy, so future batches should return to concrete simulation artifacts to keep the set visually varied.

## Batch 009

Contact sheet: `batch-009-contact-sheet.png`

Batch 009 covered remaining focused testing / real-entry validation / evidence artifacts:

1. `110-test-mvp-gate` - a small green gate beats a giant flaky suite.
2. `111-test-real-tle-flattening` - TLE entry flattens into the same data contract.
3. `112-test-minload-waterpipes` - MinLoad routes flow through capacity-limited pipes.
4. `113-test-temporal-routing-panels` - frame-by-frame checks for time-varying routes.
5. `114-test-ai-evidence-receipts` - AI runs need evidence receipts, not vibes.
6. `115-test-viz-artifact-drying-line` - generated visual artifacts are hung and inspected.
7. `116-test-night-ovens` - overnight validation as batch ovens with status cards.
8. `117-test-sgp4-aon-pipe-repair` - SGP4-to-AON failures repaired pipe segment by segment.

Notes:

- `113-test-temporal-routing-panels` was regenerated because the first version had a standalone title-like label.
- `112-test-minload-waterpipes` and `117-test-sgp4-aon-pipe-repair` are strong examples of validation concepts expressed as local physical mechanisms rather than diagrams.
- After Batch 009, the test/recovery coverage is broad enough; the next batch should return to simulation mechanics to keep the set balanced.

## Batch 010

Contact sheet: `batch-010-contact-sheet.png`

Batch 010 returned to simulation-mechanics details:

1. `015-foundation-unit-scale` - units and constants calibrated near the root.
2. `020-orbit-sgp4-library-lens` - SGP4 behavior exposed through a stable Orbit API lens.
3. `024-link-telescope-lenses` - different link models as swappable evaluator lenses.
4. `025-link-handover-lantern` - temporal handover as a moving visibility lantern.
5. `028-metrics-coverage-lightbox` - coverage as visible/not-visible tiles over time.
6. `033-topology-magnet-fishpond` - static versus dynamic edges as nailed cards and edge-fish.
7. `037-routing-ecmp-bridge` - equal-cost paths as two bridges splitting packet beads.
8. `043-traffic-link-load-drawer` - per-edge traffic load as inspectable drawer contents.

Notes:

- `033-topology-magnet-fishpond` has a visible time note, but it functions as a local annotation rather than a slide title.
- `020-orbit-sgp4-library-lens` is useful for explaining why library-backed SGP4 still belongs behind the project interface.
- Batch 010 adds strong concrete mechanics after several validation-heavy batches.

## Batch 011

Contact sheet: `batch-011-contact-sheet.png`

Batch 011 covered overview / server protocol / client frame flow:

1. `006-overview-lab-test-kitchen` - Lab combines tools into experiments without forcing one route.
2. `007-overview-array-contract-ruler` - bare arrays make modules composable and testable.
3. `008-overview-frame-laundry-line` - simulation frames are slices of time for clients.
4. `010-overview-module-relay` - stabilize modules in dependency order before broad regressions.
5. `087-server-five-drawers` - fixed request types as five drawers.
6. `089-server-digital-noodle-frame` - per-frame positions flattened into a client-friendly number strip.
7. `090-server-isl-laundry-lights` - candidate edges and availability booleans align one-to-one.
8. `091-server-one-way-tunnel-ticket` - one WebSocket connection carries one simulation stream.

Notes:

- `089-server-digital-noodle-frame` and `091-server-one-way-tunnel-ticket` are strong protocol metaphors without becoming protocol diagrams.
- `006-overview-lab-test-kitchen` is a bit label-heavy but remains a physical kitchen scene and captures the “not only run_experiment” point.
- `007-overview-array-contract-ruler` is intentionally more literal because the array contract is central to the project.

## Batch 012

Contact sheet: `batch-012-contact-sheet.png`

Batch 012 covered Lab convenience / MCP protocol boundaries:

1. `070-lab-implementation-customs` - concrete experiment names pass customs before becoming public concepts.
2. `071-lab-precomposed-kitchen` - common tool combinations are prepared kitchen stations.
3. `072-lab-run-experiment-egg` - `run_experiment` is a thin shell convenience, not the whole Lab.
4. `073-lab-standard-plate` - Lab passes standard data plates between tools.
5. `079-lab-comparison-scale` - experiments become comparable result cards.
6. `085-lab-factory-narrow-door` - experiments enter through a narrow contract door.
7. `092-mcp-six-tool-drawers` - MCP exposes a small bounded tool surface.
8. `093-mcp-content-length-postbox` - JSON-RPC calls are length-stamped envelopes.

Notes:

- `072-lab-run-experiment-egg`, `085-lab-factory-narrow-door`, and `093-mcp-content-length-postbox` are the strongest metaphors in this batch.
- `070-lab-implementation-customs` and `071-lab-precomposed-kitchen` are text-heavier but still physical, non-PPT scenes.
- Batch 012 brings the accepted set to the edge of the 100+ target; Batch 013 should push it over the line.

## Batch 013

Contact sheet: `batch-013-contact-sheet.png`

Batch 013 covered Distributed / Opt mechanism details and pushed the accepted set past 100:

1. `047-distributed-event-loop-bench` - each satellite owns a small event-loop workbench.
2. `048-distributed-barrier-gate` - distributed workers sync at controlled barriers.
3. `050-distributed-statefulset-honeycomb` - stateful workers need stable cells.
4. `051-distributed-six-core-oven` - use available cores intentionally instead of single-core bottlenecks.
5. `053-opt-array-drawer-cabinet` - `Array{Float64,3}` remains the drawer cabinet shared by Opt.
6. `054-opt-j2-potato-earth` - oblateness perturbs propagation.
7. `057-opt-adam-mixer-console` - Adam adjusts orbital parameters using feedback.
8. `058-opt-soft-isl-rubber-ruler` - link constraints can become differentiable scores.

Notes:

- `051-distributed-six-core-oven`, `054-opt-j2-potato-earth`, `057-opt-adam-mixer-console`, and `058-opt-soft-isl-rubber-ruler` are the strongest final-batch images.
- `047-distributed-event-loop-bench` is denser than ideal but remains a physical workbench scene rather than an architecture graph.
- The production target of 100+ accepted illustrations is satisfied by this batch.

## Remaining Backlog

The accepted set is complete for the 100+ target. Remaining shot-list ideas can be generated later if a specific document needs them:

1. Lower-priority Metrics and Routing variants.
2. Additional Distributed worker internals.
3. Extra Lab/AI interaction refinements.
4. Literature pages not yet illustrated, such as Orbit stack and differentiable bridge.
