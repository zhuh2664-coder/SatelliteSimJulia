# SatelliteSimJulia Xiaohei Illustration Shot List

> Purpose: a fine-grained candidate pool for a 100+ image Ian-style Xiaohei illustration set.
>
> Status: planning list. Generate in small batches, QA every image, and reject or regenerate weak images.

## Visual Contract

- 16:9 horizontal Chinese article illustration.
- Pure white background, black hand-drawn line art, lots of whitespace.
- Sparse red/orange/blue handwritten Chinese labels, at most 5-8 labels per image.
- Xiaohei must do the core conceptual action, not stand in the corner.
- One image explains one cognitive anchor.
- Avoid PPT diagrams, course slides, dense architecture charts, cute mascots, UI screenshots, and tech-poster styling.

## Status Legend

- `accepted`: already generated and QA-passed.
- `planned`: ready for prompt writing and generation.
- `draft`: generated but not accepted.
- `regenerate`: concept useful, current image not good enough.
- `defer`: keep as backup if the set needs more depth.

## A. Overview And Mental Model

| ID | Proposed File | Placement | Core Idea | Xiaohei Action And Metaphor | Labels | QA / Avoid |
|---|---|---|---|---|---|---|
| A-001 | `001-overview-time-slicer.png` | Project overview opening | Time decoupling turns constellation motion into one shared `N x T x 3` contract. | Xiaohei cranks a strange time-slicer machine; constellation input becomes an array tray consumed by Link/Net/Lab/Opt. | `星座输入`, `N x T x 3`, `各吃各的`, `别反向依赖` | `accepted`; preserve `02-time-slicer-clean.png` as source. |
| A-002 | `002-overview-dispatch-workbench.png` | Multiple dispatch principle | Same public verb, different propagator or evaluator types. | Xiaohei swaps odd tool heads on one low-tech workbench instead of rebuilding the bench. | `同一入口`, `不同类型`, `多重分派`, `少改旧代码` | Avoid formal class hierarchy. |
| A-003 | `003-overview-one-way-valve.png` | Dependency discipline | Dependencies flow one way; lower layers do not know higher layers. | Xiaohei holds a one-way valve in a crooked pipe while reverse water is blocked in red. | `单向依赖`, `下层稳定`, `不回流`, `Core 谨慎` | Avoid full package dependency graph. |
| A-004 | `004-overview-tools-and-bento.png` | Tool layer overview | Atomic tools remain available; precomposed tools are convenience packaging. | Xiaohei packs tiny bare tools into one bento box while leaving originals on the table. | `原子工具`, `预编排`, `可拆开`, `也可整套` | Do not imply precomposed tools add new physics. |
| A-005 | `005-overview-core-customs-window.png` | Core aggregation explanation | Core reexports Foundation/Orbit/Link/Metrics without becoming a physics layer. | Xiaohei sits at a customs window stamping symbols through one pass-through slot. | `Core`, `reexport`, `透传`, `不加新物理` | Avoid making Core a god object. |
| A-006 | `006-overview-lab-test-kitchen.png` | Lab layer explanation | Lab combines tools into experiments without forcing one route. | Xiaohei in a small test kitchen chooses either loose ingredients or a prepared meal. | `实验编排`, `自由组合`, `run_experiment`, `不是唯一入口` | Avoid big workflow chart. |
| A-007 | `007-overview-array-contract-ruler.png` | Data contract explanation | Bare arrays make modules composable and testable. | Xiaohei uses a weird folding ruler to measure drawers labeled `N`, `T`, `3`. | `裸数组`, `N x T x 3`, `标准盘`, `少嵌套` | Avoid matrix lecture slide. |
| A-008 | `008-overview-frame-laundry-line.png` | Streaming and visualization bridge | Simulation frames are slices of time hung one by one for clients. | Xiaohei clips frame cards to a laundry line; each card contains flattened positions. | `frame`, `positions`, `一帧一片`, `推流` | Avoid WebSocket protocol table. |
| A-009 | `009-overview-two-input-gates.png` | Orbit interface split | Design-time constellation inputs and real TLE/ephemeris inputs enter through separate gates. | Xiaohei guards two small gates, one marked Walker design, one marked real data ticket. | `设计入口`, `真实数据`, `Walker`, `TLE` | Avoid implying the two paths share identical validation. |
| A-010 | `010-overview-module-relay.png` | Recovery workflow | Stabilize modules in dependency order before running broad regressions. | Xiaohei passes a small torch along Foundation -> Orbit -> Link -> Core -> Net -> Lab stepping stones. | `先底层`, `再聚合`, `逐层跑通`, `小步验证` | Avoid all-repo CI poster. |

## B. Foundation / Orbit / Link / Metrics

| ID | Proposed File | Placement | Core Idea | Xiaohei Action And Metaphor | Labels | QA / Avoid |
|---|---|---|---|---|---|---|
| B-FDN-01 | `011-foundation-lowest-stone.png` | Foundation module page | Foundation is the low, boring, load-bearing layer. | Xiaohei crawls under a table to wedge a tiny stone under everything else. | `Foundation`, `常量`, `时间`, `坐标`, `契约` | Avoid dramatic skyscraper architecture. |
| B-FDN-02 | `012-foundation-coordinate-doors.png` | Coordinate system explanation | Coordinate conversions are controlled doors, not loose conventions. | Xiaohei rotates three small doors labeled ECI/ECEF/LLA to choose the right exit. | `ECI`, `ECEF`, `LLA`, `转换门` | Avoid globe classroom diagram. |
| B-FDN-03 | `013-foundation-time-clothesline.png` | Time representation | Simulation time is a shared axis all modules can hang samples on. | Xiaohei pins time tags on a taut clothesline while satellites hang below. | `tspan`, `采样`, `统一时间`, `秒` | Avoid calendar UI. |
| B-FDN-04 | `014-foundation-entity-locker.png` | Entity contracts | IDs and entity structs are lockers, not nested simulation objects. | Xiaohei sorts satellite and ground-station cards into simple metal lockers. | `SatelliteId`, `GroundStation`, `轻量实体`, `别塞行为` | Avoid object-oriented class diagram. |
| B-FDN-05 | `015-foundation-unit-scale.png` | Units and constants | Units/constants must be measured once near the root. | Xiaohei balances km, seconds, and radians on a tiny scale before stamping them. | `km`, `s`, `rad`, `常量`, `别混单位` | Avoid physics textbook illustration. |
| B-ORB-01 | `016-orbit-ephemeris-noodle.png` | Ephemeris contract | Propagation produces a position noodle other modules can consume. | Xiaohei feeds orbital elements into a noodle machine that outputs `N x T x 3` strips. | `ephemeris`, `位置序列`, `N x T x 3`, `可消费` | Avoid copying A-001 exactly. |
| B-ORB-02 | `017-orbit-propagator-scale.png` | Propagator choice | Two-body/J2/J4/SGP4 trade speed and fidelity. | Xiaohei weighs four propagator stones on a crooked scale. | `two_body`, `J2`, `J4`, `SGP4`, `精度/成本` | Avoid benchmark bar chart. |
| B-ORB-03 | `018-orbit-walker-seed-tray.png` | Walker constellation generation | Walker inputs are seed trays that grow a patterned constellation. | Xiaohei plants plane/phasing seeds into a tray; small orbit sprouts appear. | `planes`, `sats`, `phasing`, `Walker` | Avoid standard orbital plane diagram. |
| B-ORB-04 | `019-orbit-tle-ticket-gate.png` | Real TLE entry | TLE is a real-data ticket into propagation, not a design-time recipe. | Xiaohei scans a two-line ticket at a narrow gate before entering the propagator room. | `TLE`, `真实星座`, `一次性验票`, `SGP4` | Avoid implying TLE is edited like Walker config. |
| B-ORB-05 | `020-orbit-sgp4-library-lens.png` | SGP4 implementation boundary | SGP4 behavior should be exposed through project interfaces even if sourced from mature code. | Xiaohei mounts a borrowed lens into a local telescope frame. | `成熟实现`, `本地接口`, `统一输出`, `可替换` | Avoid vendoring/copy-paste endorsement. |
| B-LNK-01 | `021-link-five-laser-gates.png` | Link constraints overview | ISL availability is a sequence of physical gates. | Xiaohei pushes a laser thread through five tiny gates: range, LOS, elevation, azimuth, duration. | `距离`, `LOS`, `仰角`, `方位`, `持续` | Avoid dense constraint equations. |
| B-LNK-02 | `022-link-glass-earth-ruler.png` | Link geometry | Link distance/visibility are geometry checks around Earth obstruction. | Xiaohei measures a laser inside a glass Earth marble with a bent ruler. | `几何`, `地球遮挡`, `距离`, `可见` | Avoid realistic 3D globe. |
| B-LNK-03 | `023-link-ground-cups.png` | GSL evaluation | Ground stations catch satellite signal rain only above valid geometry. | Xiaohei moves tiny cups under falling blue signal drops. | `GSL`, `地面站`, `仰角`, `可接收` | Avoid weather/rain visual overload. |
| B-LNK-04 | `024-link-telescope-lenses.png` | Link model extensibility | Different link models are lenses on the same evaluator telescope. | Xiaohei swaps simple lenses while looking at the same satellite pair. | `同一 evaluator`, `不同模型`, `分派`, `不改入口` | Avoid API reference sheet. |
| B-LNK-05 | `025-link-handover-lantern.png` | Mobility and handover readiness | Visibility windows move; link choice must be temporal. | Xiaohei carries a lantern between moving ground cups as windows open and close. | `窗口`, `切换`, `可用期`, `时间相关` | Avoid routing-level path decisions. |
| B-MET-01 | `026-metrics-tailor-ruler.png` | Metrics purity | Metrics measure outputs without mutating the simulation. | Xiaohei as a deadpan tailor measures an array cloth without cutting it. | `纯函数`, `只测量`, `coverage`, `latency` | Avoid analytics dashboard. |
| B-MET-02 | `027-metrics-latency-bead-sieve.png` | Latency distribution | Latency samples should be sifted, not reduced too early. | Xiaohei shakes beads through a sieve labeled p50/p95/max. | `p50`, `p95`, `max`, `样本` | Avoid histogram chart. |
| B-MET-03 | `028-metrics-coverage-lightbox.png` | Coverage metric | Coverage is a lightbox of visible/not-visible tiles over time. | Xiaohei flips tiny blue/red bulbs on a ground grid. | `覆盖`, `可见`, `时间片`, `地面网格` | Avoid world map heatmap. |
| B-MET-04 | `029-metrics-topology-clinic.png` | Topology health metrics | Metrics can diagnose graph health after topology generation. | Xiaohei listens to a graph with a stethoscope and writes a small note. | `连通性`, `度数`, `瓶颈`, `健康检查` | Avoid medical cartoon over-cuteness. |
| B-MET-05 | `030-metrics-registry-stamp-shelf.png` | Metric registry | Registered metrics are named stamps on a shelf. | Xiaohei selects one stamp and presses it onto a result card. | `registry`, `metadata`, `命名指标`, `可复用` | Avoid plugin marketplace visual. |

## C. Net / Traffic / Distributed

| ID | Proposed File | Placement | Core Idea | Xiaohei Action And Metaphor | Labels | QA / Avoid |
|---|---|---|---|---|---|---|
| C-TOPO-01 | `031-topology-edge-punch.png` | Topology generation | Topology turns positions into candidate edge lists. | Xiaohei cranks an edge-list punch machine; satellite dots enter, edge cards exit. | `positions`, `edge list`, `拓扑`, `候选边` | Avoid graph theory chalkboard. |
| C-TOPO-02 | `032-topology-shoelace-cards.png` | Topology strategies | Strategy variants lace satellites differently. | Xiaohei threads seven shoelace cards through the same satellite buttons. | `策略`, `邻接`, `可替换`, `同一接口` | Avoid spiderweb network. |
| C-TOPO-03 | `033-topology-magnet-fishpond.png` | Static vs dynamic topology | Static edges are nailed; dynamic edges swim with time. | Xiaohei compares a nailed board with a magnet fish pond of moving edges. | `static`, `dynamic`, `随时间`, `快照` | Avoid two-column PPT layout. |
| C-TOPO-04 | `034-topology-edge-hop-scale.png` | Topology cost thinking | Edge count and hop count are different weights. | Xiaohei balances edge-count pebbles against hop-count beans. | `边数`, `跳数`, `成本`, `别混` | Avoid formal optimization chart. |
| C-ROUTE-01 | `035-routing-three-door-envelope.png` | End-to-end path | Ground-to-ground route passes GSL, ISL, GSL stages. | Xiaohei pushes an envelope through three tiny doors labeled uplink, space, downlink. | `GSL`, `ISL`, `GSL`, `路径` | Avoid full Internet diagram. |
| C-ROUTE-02 | `036-routing-stopwatch-weight.png` | Edge weights | Routing weights turn physical links into path costs. | Xiaohei hangs stopwatches on edges and lets the path sag toward cheaper links. | `weight`, `delay`, `距离`, `Dijkstra` | Avoid algorithm textbook diagram. |
| C-ROUTE-03 | `037-routing-ecmp-bridge.png` | Multipath and congestion | Equal-cost paths can split or bypass load. | Xiaohei opens two small bridges when one bridge gets crowded with beans. | `ECMP`, `拥塞`, `分流`, `绕行` | Avoid traffic-road realism. |
| C-ROUTE-04 | `038-routing-pinn-black-oven.png` | Learned routing surrogate | PINN routing is a black oven constrained by physics labels. | Xiaohei feeds route cards into an oven with physics salt sprinkled on top. | `PINN`, `约束`, `近似`, `路由` | Avoid magical AI sparkle. |
| C-ROUTE-05 | `039-routing-satellite-umbrella.png` | Handover choice | A moving user chooses the satellite umbrella that still covers them. | Xiaohei moves under one umbrella while others drift away. | `handover`, `覆盖`, `选择`, `移动性` | Avoid mobile-network vendor diagram. |
| C-ROUTE-06 | `040-routing-temporal-panels.png` | Temporal routing | Routes are panels over time, not one permanent path. | Xiaohei slides route panels on a clothesline and picks the current one. | `t0`, `t1`, `t2`, `时变路由` | Avoid duplicating A-008; focus path not frame. |
| C-TRAF-01 | `041-traffic-aon-bucket.png` | All-or-nothing assignment | AON pours all demand through one selected path. | Xiaohei tips a whole bucket of blue beads onto one bridge. | `AoN`, `全量`, `单一路径`, `需求` | Avoid implying load balancing. |
| C-TRAF-02 | `042-traffic-offered-carried-dropped.png` | Traffic accounting | Offered, carried, and dropped traffic must be separated. | Xiaohei weighs three bowls: offered, carried, dropped. | `offered`, `carried`, `dropped`, `容量` | Avoid stacked bar chart. |
| C-TRAF-03 | `043-traffic-link-load-drawer.png` | Link load artifact | Link loads are drawer contents per edge. | Xiaohei pulls a drawer full of beads from one edge cabinet. | `link_load`, `edge`, `容量`, `溢出` | Avoid database table screenshot. |
| C-TRAF-04 | `044-traffic-intent-postoffice.png` | Traffic demand model | Traffic intent cards become structured demand objects. | Xiaohei stamps origin/destination/time cards in a tiny post office. | `OD`, `需求`, `时间窗`, `intent` | Avoid enterprise BPM form. |
| C-TRAF-05 | `045-traffic-real-demand-seeds.png` | Real demand calibration | Real traffic data is seed material that must be cleaned before simulation. | Xiaohei washes muddy demand seeds before planting them into a demand tray. | `真实流量`, `清洗`, `校准`, `样本` | Avoid claiming real data is fully solved. |
| C-DIST-01 | `046-distributed-toolbox-suitcases.png` | Distributed execution idea | A monolith toolbox can split into per-satellite suitcases. | Xiaohei unpacks one giant toolbox into many tiny satellite suitcases. | `拆分`, `per-sat`, `状态`, `并行` | Avoid Kubernetes architecture. |
| C-DIST-02 | `047-distributed-event-loop-bench.png` | Per-satellite event loop | Each satellite can own a small event-loop workbench. | Many Xiaohei operators turn tiny wheels in separate benches. | `event loop`, `sat state`, `step`, `消息` | Avoid over-dense multi-agent diagram. |
| C-DIST-03 | `048-distributed-barrier-gate.png` | Coordination barrier | Distributed workers sync at controlled barriers. | Xiaohei closes a barrier gate until all satellite carts arrive. | `barrier`, `同步`, `step`, `一致` | Avoid deadlock horror poster. |
| C-DIST-04 | `049-distributed-length-json-hat.png` | Worker protocol | Messages need clear length and JSON framing. | Xiaohei puts a 4-byte length hat on a JSON paper roll. | `length`, `JSON`, `frame`, `协议` | Avoid mixing with MCP Content-Length. |
| C-DIST-05 | `050-distributed-statefulset-honeycomb.png` | Stateful deployment | Stateful workers need stable cells, not anonymous blobs. | Xiaohei labels honeycomb cells with stable satellite names. | `StatefulSet`, `稳定身份`, `worker`, `状态` | Avoid cloud-provider diagram. |
| C-DIST-06 | `051-distributed-six-core-oven.png` | Local parallel validation | Use available cores intentionally instead of single-core bottlenecks. | Xiaohei loads six small ovens with test trays while six remain idle for the user. | `6 cores`, `并行`, `留余量`, `验证` | Avoid promising infinite compute. |

## D. Opt / PINN / dSGP4

| ID | Proposed File | Placement | Core Idea | Xiaohei Action And Metaphor | Labels | QA / Avoid |
|---|---|---|---|---|---|---|
| D-OPT-01 | `052-opt-gradient-backflow.png` | Differentiable optimization intro | Gradients flow backward through simulation pipes. | Xiaohei pumps orange liquid backward through a glass pipe from metric to RAAN/MA knobs. | `梯度`, `loss`, `参数`, `回流` | Avoid neural-net stock art. |
| D-OPT-02 | `053-opt-array-drawer-cabinet.png` | Differentiable data contract | `Array{Float64,3}` remains the drawer cabinet shared by Opt. | Xiaohei pulls one differentiable drawer without changing the cabinet shape. | `N x T x 3`, `Dual`, `同一契约`, `可微` | Avoid repeating A-007 exactly. |
| D-OPT-03 | `054-opt-j2-potato-earth.png` | J2 intuition | Oblateness perturbs propagation. | Xiaohei tapes a flattened potato Earth under a satellite path. | `J2`, `扁地球`, `摄动`, `轨道漂移` | Avoid accurate geodesy diagram. |
| D-OPT-04 | `055-opt-dual-number-shadow.png` | ForwardDiff intuition | Dual numbers carry value and derivative shadows. | Xiaohei walks with a tiny shadow tag labeled derivative. | `value`, `derivative`, `Dual`, `ForwardDiff` | Avoid calculus lecture. |
| D-OPT-05 | `056-opt-soft-threshold-sandpaper.png` | Soft constraints | Hard thresholds need smoothing for gradients. | Xiaohei sands a sharp red threshold gate into a smooth ramp. | `hard`, `soft`, `可导`, `平滑` | Avoid implying physics constraints disappear. |
| D-OPT-06 | `057-opt-adam-mixer-console.png` | Gradient optimizer | Adam adjusts orbital parameters using feedback. | Xiaohei turns RAAN/MA knobs on a mixer while loss beads drop. | `Adam`, `RAAN`, `MA`, `loss` | Avoid optimizer comparison chart. |
| D-OPT-07 | `058-opt-soft-isl-rubber-ruler.png` | Soft ISL | Link constraints can become differentiable scores. | Xiaohei stretches a rubber ruler between satellites instead of snapping a hard ruler. | `soft ISL`, `score`, `距离`, `LOS` | Avoid replacing real evaluator. |
| D-OPT-08 | `059-opt-two-hop-water-trough.png` | Soft routing | Direct and two-hop routes can be relaxed as flowing weights. | Xiaohei adjusts two water trough gates and watches flow split. | `direct`, `two-hop`, `soft route`, `weight` | Avoid exact routing output claim. |
| D-OPT-09 | `060-opt-three-gradient-rulers.png` | Multi-objective gradients | Different metrics pull parameters in different directions. | Xiaohei holds three stretchy rulers tugging the same parameter peg. | `coverage`, `latency`, `capacity`, `tradeoff` | Avoid Pareto plot. |
| D-OPT-10 | `061-opt-discrete-f-gear.png` | Discrete parameter difficulty | Discrete phasing is a gear, not a smooth knob. | Xiaohei tries to turn a gear labeled F while smooth knobs sit nearby. | `F`, `离散`, `不可导`, `近似` | Avoid overpromising differentiability. |
| D-PINN-11 | `062-pinn-physics-salt-oven.png` | PINN training | Data and physics residual are ingredients. | Xiaohei pours data flour and physics salt into a small oven. | `data`, `physics`, `residual`, `PINN` | Avoid magical black box. |
| D-PINN-12 | `063-pinn-crack-rail-patch.png` | Residual PINN vs pure PINN | Residual learning patches known physics instead of replacing it. | Xiaohei patches a cracked rail next to a broken pure-PINN bridge. | `残差`, `基线物理`, `补偿`, `不替代` | Avoid insulting all neural methods. |
| D-NN-13 | `064-nn-hpop-truth-well.png` | High-fidelity truth data | HPOP or truth data is a well, expensive but grounding. | Xiaohei lowers a bucket into a deep labeled truth well. | `truth`, `HPOP`, `样本`, `昂贵` | Avoid claiming available data if not present. |
| D-NN-14 | `065-nn-j2-residual-stitch.png` | J2 + NN residual | Neural residual stitches onto analytic propagation. | Xiaohei sews a small blue patch onto an orange J2 orbit ribbon. | `J2`, `NN residual`, `缝补`, `误差` | Avoid replacing J2 core. |
| D-NN-15 | `066-nn-neural-slingshot.png` | Neural propagator constraint | Neural speedups still need physics weights. | Xiaohei pulls a neural slingshot while a physics weight keeps it grounded. | `神经传播`, `速度`, `物理约束`, `别飞走` | Avoid superhero AI style. |
| D-DSGP4-16 | `067-dsgp4-correction-tunnel.png` | dSGP4 interface | Differentiable SGP4 can include input/output correction mirrors. | Xiaohei walks through a tunnel with two correction mirrors around SGP4. | `dSGP4`, `输入修正`, `输出修正`, `可微` | Avoid pretending final API is already stable. |

## E. Lab / Experiment / AI Orchestration

| ID | Proposed File | Placement | Core Idea | Xiaohei Action And Metaphor | Labels | QA / Avoid |
|---|---|---|---|---|---|---|
| E-LAB-01 | `068-lab-three-layer-airlock.png` | Lab architecture | Tools, experiment orchestration, and AI interaction are separate airlocks. | Xiaohei passes a result capsule through three narrow airlock doors. | `工具层`, `实验层`, `AI层`, `不混层` | Avoid full architecture poster. |
| E-LAB-02 | `069-lab-universal-socket.png` | Experiment interface | Experiment configs plug into a shared socket. | Xiaohei inserts odd experiment cartridges into one universal socket. | `ExperimentConfig`, `Result`, `socket`, `可替换` | Avoid class diagram. |
| E-LAB-03 | `070-lab-implementation-customs.png` | Implementation nouns | Concrete experiment names should pass customs before becoming public concepts. | Xiaohei checks noun passports at a tiny customs booth. | `命名`, `边界`, `公共接口`, `别乱暴露` | Avoid bureaucracy joke overpowering meaning. |
| E-LAB-04 | `071-lab-precomposed-kitchen.png` | Precomposed tools | Common combinations are prepared kitchen stations. | Xiaohei plates `propagate`, `coverage`, and `routing` dishes from atomic ingredients. | `precomposed`, `原子工具`, `省事`, `不加物理` | Avoid food scene too detailed. |
| E-LAB-05 | `072-lab-run-experiment-egg.png` | `run_experiment` role | `run_experiment` is a thin shell convenience, not the whole Lab. | Xiaohei cracks a thin egg shell to reveal ordinary tool calls inside. | `便利入口`, `薄壳`, `不是唯一`, `组合` | Avoid implying deprecation. |
| E-LAB-06 | `073-lab-standard-plate.png` | Lab data contract | Lab passes standard plates between tools. | Xiaohei carries a plate labeled `N x T x 3` from Orbit to Link/Net. | `标准盘`, `裸数组`, `可拼接`, `少胶水` | Avoid duplicating A-001 exactly. |
| E-LAB-07 | `074-lab-experiment-cartridge.png` | Custom experiment dispatch | Experiments are cartridges with known inputs/outputs. | Xiaohei loads an experiment cartridge into an arcade machine. | `AbstractExperiment`, `dispatch`, `inputs`, `outputs` | Avoid game UI screenshot. |
| E-LAB-08 | `075-lab-sweep-abacus.png` | Parameter sweep | Sweeps are abacus beads, not hand-run copies. | Xiaohei slides RAAN/inclination/time beads on a long abacus. | `sweep`, `参数`, `批量`, `结果表` | Avoid huge matrix table. |
| E-LAB-09 | `076-lab-react-echo-well.png` | ReAct loop | Agent planning should hear tool feedback before next step. | Xiaohei drops a question stone into a well and listens to structured echo. | `thought`, `tool`, `observation`, `下一步` | Avoid chatbot bubbles. |
| E-LAB-10 | `077-lab-sentence-postoffice.png` | Natural language to tools | User sentence becomes a structured tool call. | Xiaohei stamps a sentence envelope into a JSON parcel. | `自然语言`, `工具调用`, `schema`, `结果` | Avoid magic wand. |
| E-LAB-11 | `078-lab-cache-fridge.png` | Experiment cache | Reused artifacts can live in a labeled fridge. | Xiaohei puts generated positions into a tiny fridge for later metrics. | `cache`, `positions`, `复用`, `省时间` | Avoid overpromising persistent cache if not implemented. |
| E-LAB-12 | `079-lab-comparison-scale.png` | Result comparison | Experiments become comparable result cards. | Xiaohei weighs two result cards on a scale. | `baseline`, `variant`, `metrics`, `比较` | Avoid scientific plot poster. |
| E-LAB-13 | `080-lab-multi-agent-site.png` | Multi-agent development | Different agents can build separate modules if contracts are clear. | Several Xiaohei workers carry labeled bricks to separate scaffolds. | `多智能体`, `边界`, `并行`, `汇总` | Avoid uncontrolled swarm. |
| E-LAB-14 | `081-lab-teamgraph-theater.png` | TeamGraph | Agent handoffs should move artifacts, not vague chat. | Xiaohei puppeteers pass an artifact box across a small theater stage. | `Planner`, `Runner`, `Reviewer`, `Artifact` | Avoid org chart. |
| E-LAB-15 | `082-lab-tool-gate.png` | Tool guard | Tool calls must pass schema and budget guards. | Xiaohei pushes a tool cart through a narrow measuring gate. | `schema`, `budget`, `guard`, `执行` | Avoid enterprise approval flow. |
| E-LAB-16 | `083-lab-audit-footprints.png` | Audit trail | Runs leave footprints for debugging and replay. | Xiaohei walks across wet ink; each footprint becomes a log card. | `trace`, `ledger`, `replay`, `可审计` | Avoid security compliance poster. |
| E-LAB-17 | `084-lab-checkpoint-sleeping-bag.png` | Checkpoints | Long runs can sleep and resume. | Xiaohei curls in a checkpoint sleeping bag beside a half-finished run. | `checkpoint`, `resume`, `long run`, `不中断` | Avoid implying all state is recoverable now. |
| E-LAB-18 | `085-lab-factory-narrow-door.png` | Experiment factory discipline | Experiments should enter through a narrow contract door. | Xiaohei trims a too-wide experiment crate until it fits the door. | `契约`, `最小输入`, `清晰输出`, `可测` | Avoid making architecture too punitive. |

## F. Server / WebSocket / MCP / Godot / Viz

| ID | Proposed File | Placement | Core Idea | Xiaohei Action And Metaphor | Labels | QA / Avoid |
|---|---|---|---|---|---|---|
| F-SRV-01 | `086-server-physical-projector.png` | Server README architecture | Server projects core simulation frames; it does not rewrite physics. | Xiaohei cranks an old projector; orbit film becomes client view. | `物理服务`, `复用核心`, `不重写`, `8080` | Avoid server rack. |
| F-SRV-02 | `087-server-five-drawers.png` | WebSocket endpoints | Five request types are fixed drawers. | Xiaohei inserts `start` JSON card into the correct drawer. | `列星座`, `看参数`, `开仿真`, `推帧`, `停止` | Avoid API reference table. |
| F-SRV-03 | `088-server-menu-handwritten-order.png` | Catalog vs custom Walker | Catalog uses menu items; custom Walker is a temporary order. | Xiaohei clips a handwritten Walker order beside a constellation menu. | `目录星座`, `临时 Walker`, `session`, `默认值` | Do not imply custom writes catalog. |
| F-SRV-04 | `089-server-digital-noodle-frame.png` | Frame positions | Per-frame positions are flattened into a client-friendly number strip. | Xiaohei turns a digital noodle machine producing `[x,y,z,...]`. | `一帧`, `ECEF km`, `展平数组`, `frame_index` | Avoid matrix lecture. |
| F-SRV-05 | `090-server-isl-laundry-lights.png` | `isl_pairs` / `isl_avail` | Candidate edges and availability booleans align one-to-one. | Xiaohei clips satellite pairs on a line and paints tiny on/off bulbs. | `候选边`, `可用`, `不可用`, `1-based` | Avoid full constellation light show. |
| F-SRV-06 | `091-server-one-way-tunnel-ticket.png` | Single connection behavior | One WebSocket connection carries one simulation stream. | Xiaohei checks a one-way ticket, then closes the tunnel after `stream_end`. | `单连接`, `单仿真`, `推完关闭`, `stream_end` | Avoid error-poster tone. |
| F-MCP-07 | `092-mcp-six-tool-drawers.png` | MCP tools overview | MCP exposes a small bounded tool surface. | Xiaohei measures each tool drawer with calipers. | `六个工具`, `JSON`, `有界`, `结构化` | Avoid universal toolbox. |
| F-MCP-08 | `093-mcp-content-length-postbox.png` | stdio framing | JSON-RPC calls are length-stamped envelopes. | Xiaohei weighs a JSON envelope and posts it through a stdio mailbox. | `stdio`, `Content-Length`, `tools/list`, `tools/call` | Do not mix with WebSocket frame stream. |
| F-MCP-09 | `094-mcp-sandbox-fence.png` | MCP safety | Tools run inside a small bounded sandbox. | Xiaohei pushes a red hammer outside a low fence. | `无发布`, `不破坏`, `有界`, `白名单` | Avoid padlock-heavy security poster. |
| F-MCP-10 | `095-mcp-whitelist-mask.png` | Tests and token audits | Tests use package whitelist; token audit shows summaries only. | Xiaohei scans a package at a gate while masking a ledger's text. | `包白名单`, `测试摘要`, `不吐正文`, `只看统计` | Avoid drawing chat contents. |
| F-AI-11 | `096-ai-study-origami.png` | AI roadmap | Natural language becomes inspectable Study DSL. | Xiaohei folds a wrinkled sentence into a structured experiment box. | `用户意图`, `Study DSL`, `可审查`, `结构化` | Avoid chatbot magic. |
| F-AI-12 | `097-ai-missing-fields-drawers.png` | Questionnaire | Missing inputs should become questions, not guesses. | Xiaohei opens empty drawers with question marks and holds missing screws. | `缺字段`, `先提问`, `不猜测`, `再规划` | Avoid customer-service form. |
| F-AI-13 | `098-ai-four-narrow-gates.png` | Tool-call guardrail | Tool calls pass registry, schema, budget, HITL/audit gates. | Xiaohei pushes a tool cart through four narrow gates. | `注册`, `Schema`, `预算`, `人工批准`, `审计` | Avoid corporate approval workflow. |
| F-AI-14 | `099-ai-teamgraph-spiral-stair.png` | Multi-agent handoff | Planner/runner/reviewer pass structured artifacts. | Three Xiaohei operators pass a box around a spiral stair. | `Planner`, `Runner`, `Reviewer`, `ARTIFACT` | Avoid node-link diagram. |
| F-LONG-15 | `100-longtask-footprint-wax.png` | Durable execution | Long tasks leave replayable traces and checkpoints. | Xiaohei steps through a wax-paper footprint machine with a checkpoint pack. | `Ledger`, `Trace`, `Checkpoint`, `Replay` | Avoid cloud backup visual. |
| F-LONG-16 | `101-longtask-pressure-vessel.png` | AIRun product gap | AIRun holds state/results/artifacts while future worker pipes attach later. | Xiaohei tightens a transparent pressure vessel with empty future pipe sockets. | `AIRun`, `状态`, `Artifacts`, `Worker`, `RBAC`, `UI` | Avoid Kubernetes chart. |

## G. Testing / Validation / Recovery

| ID | Proposed File | Placement | Core Idea | Xiaohei Action And Metaphor | Labels | QA / Avoid |
|---|---|---|---|---|---|---|
| G-TEST-01 | `102-test-nine-railings.png` | AGENTS discipline | The nine work rules are railings that keep changes surgical. | Xiaohei walks a narrow bridge with nine small railings. | `先想`, `简洁`, `外科`, `验证`, `边界` | Avoid scolding poster. |
| G-TEST-02 | `103-test-milestone-lamps.png` | Milestone docs | Milestones are lamps turned on one at a time. | Xiaohei lights M0-M10 lamps down a long hallway. | `M0`, `M1`, `M2`, `验收`, `状态` | Avoid timeline gantt chart. |
| G-TEST-03 | `104-test-validation-ladder.png` | Layer validation | L0-L6 validation should climb from root to higher layers. | Xiaohei climbs a ladder with package test buckets. | `L0`, `L1`, `L2`, `逐层`, `回归` | Avoid all-tests-at-once diagram. |
| G-TEST-04 | `105-test-parallel-stethoscopes.png` | Parallel probes | Multiple probes can diagnose independent modules. | Many stethoscopes listen to different package drawers at once. | `并行探针`, `包加载`, `失败归因`, `6 cores` | Avoid implying no resource limit. |
| G-TEST-05 | `106-test-package-drawers.png` | Package tests | Package test targets are drawers opened independently. | Xiaohei opens nine package drawers and marks pass/fail tags. | `Pkg.test`, `Foundation`, `Orbit`, `Link`, `Net` | Avoid package manager screenshot. |
| G-TEST-06 | `107-test-failure-medical-chart.png` | Failure attribution | Real failures need attribution, not panic. | Xiaohei pins a meteor-shaped failure to a medical chart. | `第一失败`, `根因`, `pre-existing`, `最小修复` | Avoid dramatic explosion. |
| G-TEST-07 | `108-test-old-runtests-scroll.png` | Legacy tests | Old giant runtests file is a scroll to mine carefully. | Xiaohei unrolls a long scroll and cuts out mature assertions. | `旧测试`, `可迁移`, `不要全搬`, `小步` | Avoid mocking old code. |
| G-TEST-08 | `109-test-assertion-transplant.png` | Assertion migration | Mature assertions can be transplanted into focused `@testset`s. | Xiaohei grafts assertion leaves onto a new test plant. | `@testset`, `断言`, `移植`, `聚焦` | Avoid garden too cute. |
| G-TEST-09 | `110-test-mvp-gate.png` | MVP regression gate | A small green gate beats a giant flaky suite. | Xiaohei fits a tiny core regression cart through a narrow MVP gate. | `MVP`, `核心回归`, `可重复`, `先绿` | Avoid lowering quality signal. |
| G-TEST-10 | `111-test-real-tle-flattening.png` | Real TLE validation | TLE entry must flatten into the same data contract. | Xiaohei feeds TLE ticker tape through a flattening press. | `TLE`, `SGP4`, `N x T x 3`, `真实入口` | Avoid duplicating B-ORB-04. |
| G-TEST-11 | `112-test-minload-waterpipes.png` | MinLoad semantics | MinLoad routes flow through pipes with limited capacity. | Xiaohei adjusts valves as blue water backs up in overloaded pipes. | `MinLoad`, `容量`, `溢出`, `选择` | Avoid exact hydrodynamic simulation. |
| G-TEST-12 | `113-test-temporal-routing-panels.png` | Temporal route validation | Time-varying route artifacts need frame-by-frame checks. | Xiaohei hangs route panels and stamps mismatched ones red. | `时变`, `frame`, `route`, `校验` | Avoid repeating C-ROUTE-06 too closely. |
| G-TEST-13 | `114-test-ai-evidence-receipts.png` | AI tool evidence | AI runs need evidence receipts, not vibes. | Xiaohei staples tool-call receipts to an audit board. | `证据`, `tool call`, `result`, `可复查` | Avoid chatbot screenshot. |
| G-TEST-14 | `115-test-viz-artifact-drying-line.png` | Viz artifact QA | Generated visual artifacts should be hung and inspected. | Xiaohei hangs PNG/SVG cards on a drying line with check marks. | `artifact`, `PNG`, `SVG`, `人工看图` | Avoid art-gallery scene. |
| G-TEST-15 | `116-test-night-ovens.png` | Unattended validation | Long validation can run as night ovens with status cards. | Xiaohei sets timers on several small ovens before sleeping. | `overnight`, `batch`, `logs`, `早上看` | Avoid promising unattended success. |
| G-TEST-16 | `117-test-sgp4-aon-pipe-repair.png` | Regression repair story | SGP4-to-AON failures are broken pipes repaired module by module. | Xiaohei patches a pipe labeled SGP4 -> topology -> AON. | `SGP4`, `topology`, `AoN`, `逐段修` | Avoid huge end-to-end monster. |

## H. Literature / Roadmap / Paper Story

| ID | Proposed File | Placement | Core Idea | Xiaohei Action And Metaphor | Labels | QA / Avoid |
|---|---|---|---|---|---|---|
| H-LIT-01 | `118-literature-ten-layer-library.png` | Literature overview index | Literature is organized into 10 technical layers. | Xiaohei shelves paper books into ten uneven cubbies matching project modules. | `10层`, `2640篇`, `模块对应`, `文献库` | Avoid bibliometric dashboard. |
| H-LIT-02 | `119-literature-orbit-stack.png` | Orbit literature page | Orbit propagation research is the first technical shelf. | Xiaohei weighs TLE/SGP4/J2 papers on a small orbit shelf. | `轨道传播`, `SGP4`, `J2/J4`, `真实数据` | Avoid academic citation collage. |
| H-LIT-03 | `120-literature-link-prism.png` | Link literature page | Link papers split into geometry, RF, visibility, and handover concerns. | Xiaohei shines a laser through a paper prism that splits into four beams. | `ISL/GSL`, `LOS`, `仰角`, `切换` | Avoid colorful rainbow background. |
| H-LIT-04 | `121-literature-routing-maze.png` | Routing literature page | Routing literature is huge and must be turned into implementation hooks. | Xiaohei cuts a small practical tunnel through a giant paper maze. | `路由`, `695篇`, `可实现`, `接口` | Avoid maze too visually dense. |
| H-LIT-05 | `122-literature-traffic-hourglass.png` | Traffic/capacity page | Traffic papers feed capacity and latency evaluation. | Xiaohei pours demand sand through a capacity hourglass into metric bowls. | `流量`, `容量`, `时延`, `需求` | Avoid standard network-traffic chart. |
| H-LIT-06 | `123-literature-differentiable-bridge.png` | Opt/PINN papers | Differentiable optimization and PINN literature bridge simulation and learning. | Xiaohei nails a wobbly bridge between physics books and neural books. | `可微`, `PINN`, `残差`, `优化` | Avoid AI hype visual. |
| H-LIT-07 | `124-literature-ai-orchestration-switchboard.png` | AI orchestration literature | Agent literature becomes guarded tool orchestration. | Xiaohei plugs paper cords into a small switchboard labeled tools. | `LLM Agent`, `工具`, `guard`, `审计` | Avoid generic chatbot icon. |
| H-LIT-08 | `125-literature-benchmark-matrix-quilt.png` | Benchmark matrix | Benchmarking is a quilt of comparable capability squares. | Xiaohei stitches simulator names and feature squares into a sparse quilt. | `benchmark`, `对比`, `能力矩阵`, `差距` | Avoid spreadsheet screenshot. |
| H-LIT-09 | `126-literature-roadmap-four-sprints.png` | Roadmap doc | The roadmap is four small sprints, not one heroic leap. | Xiaohei pushes four little carts over four short ramps. | `Sprint 1`, `Sprint 2`, `Sprint 3`, `Sprint 4` | Avoid corporate roadmap slide. |
| H-LIT-10 | `127-literature-paper-story-funnel.png` | Paper narrative | The paper story filters a large literature pile into one thesis: time decoupling + dispatch. | Xiaohei funnels many papers into two clean cards labeled time and dispatch. | `时间解耦`, `多重分派`, `论文主线`, `取舍` | Avoid making literature look solved. |

## I. 2026-07 Project Update Supplements

| ID | Proposed File | Placement | Core Idea | Xiaohei Action And Metaphor | Labels | QA / Avoid |
|---|---|---|---|---|---|---|
| I-UPD-01 | `128-agentos-safe-surface-airlock.png` | README / MCP safety boundary | AgentOS/MCP default surface is a narrow read-only airlock. | Xiaohei guards a loopback kiosk and lets only two catalog cards pass while heavier tools stay outside the fence. | `只读默认`, `2 个 safe tools`, `127.0.0.1`, `仿真不进`, `写文件不进` | `accepted`; do not imply privileged tools are enabled by default. |
| I-UPD-02 | `129-real-data-supply-line.png` | `docs/REAL_DATA_SOURCES.md` | Real data must be cleaned, indexed, and recorded before entering experiments. | Xiaohei runs source scraps through a washing/stamping machine into orbit, ground, and traffic trays. | `真实源`, `清洗索引`, `manifest`, `轨道`, `地面站`, `流量 proxy` | `accepted`; keep the proxy limitation visible. |
| I-UPD-03 | `130-real-traffic-calibration-balance.png` | traffic calibration section | Real traffic demand rates are calibrated from proxy demand plus reliability, distance, and measurement factors. | Xiaohei pours traffic beads onto a calibration balance with factor weights and bounded output cards. | `OD proxy`, `可靠性`, `距离因子`, `RIPE RTT`, `rate_mbps`, `上下限` | `accepted`; avoid concrete rate numbers in the image. |
| I-UPD-04 | `131-ns3-stk-neutral-export-crates.png` | `docs/SatelliteSimJulia_NS3_STK_EXPORTERS.md` | ns-3/STK integration is a neutral handoff bundle, not direct coupling. | Xiaohei ties two plain export crates and cuts a tangled direct-coupling cable. | `中立导出`, `CSV JSON`, `TLE facilities`, `不直接运行`, `别耦合`, `下游消费` | `accepted`; do not suggest this runs ns-3 or STK locally. |
| I-UPD-05 | `132-security-red-blue-arena.png` | `src/security` module notes | Security scenarios reuse Net/Link/Traffic/Metrics in a measurable red/blue sandbox. | Xiaohei referees a tiny satellite-network board with red attack tokens, blue defense shields, and risk meters. | `红队注入`, `蓝队防护`, `复用底层`, `指标观察`, `risk score`, `不重写物理` | `accepted`; avoid war-poster aesthetics. |
| I-UPD-06 | `133-paper-agent-night-library.png` | `docs/literature/15_自动论文知识库.md` | The paper agent maintains the literature library while leaving confirmed actions separated. | Xiaohei stamps arXiv slips through a relevance sieve into notes, SQLite, and weekly report containers. | `每日发现`, `相关性筛`, `摘要笔记`, `SQLite`, `周报`, `待确认不越权` | `accepted`; do not imply autonomous PRs/actions happen without confirmation. |

## First Production Batch

Recommended first batch after the accepted overview:

1. `A-002` - multiple dispatch workbench.
2. `A-003` - one-way dependency valve.
3. `A-009` - design-time vs real-data input gates.
4. `B-ORB-02` - propagator fidelity/cost scale.
5. `B-LNK-01` - five laser gates for link constraints.
6. `C-TOPO-01` - edge-list punch machine.
7. `C-ROUTE-01` - GSL/ISL/GSL envelope path.
8. `D-OPT-01` - gradient backflow pipe.

## Notes For Generation

- Preserve generated originals; copy accepted versions into this directory.
- Do not overwrite existing PNGs without explicit approval.
- Prefer 6-8 images per batch.
- Update `manifest.json` or this file after every accepted/rejected generation.
