#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Build curated paper-title shortlists for SatelliteSimJulia literature layers.

This script reads docs/literature/_data.json and _bibliography.bib, then writes
one high-confidence Markdown/CSV shortlist for each non-orbit layer. The orbit
layer already has a hand-audited list and is referenced from the generated index.
"""

from __future__ import annotations

import csv
import html
import json
import re
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import date
from pathlib import Path
from typing import Iterable


ROOT = Path(__file__).resolve().parents[1]
LIT_DIR = ROOT / "docs" / "literature"
DATA_PATH = LIT_DIR / "_data.json"
BIB_PATH = LIT_DIR / "_bibliography.bib"


@dataclass(frozen=True)
class LayerConfig:
    section_id: str
    name: str
    module: str
    slug: str
    arxiv_query_id: str
    focus: str
    subcategories: tuple[tuple[str, str], ...]
    exclude_patterns: tuple[str, ...]
    arxiv_keywords: str
    related_work_advice: str
    gate_patterns: tuple[str, ...] = ()
    demote_patterns: tuple[str, ...] = ()


GLOBAL_EXCLUDE_PATTERNS = (
    r"urban heat island",
    r"land surface temperature",
    r"satellite imagery",
    r"remote sensing",
    r"coral reef",
    r"pipe MIG welding",
    r"orbital angular momentum",
    r"atomic orbital",
    r"molecular orbital",
    r"orbital-free",
    r"settlement",
    r"landslide",
    r"object detector",
    r"image interpretation",
    r"semantic communication",
    r"AirComp",
    r"^(?!.*\bTCP\b.*\bsatellite\b)(?!.*\bsatellite\b.*\bTCP\b).*AWGN",
    r"HQAM",
    r"SIMO Systems",
    r"multicarrier optical wireless",
    r"^(?!.*\b(satellite|inter[- ]satellite|intersatellite|ISL)\b).*visible light communication",
    r"high-altitude platform",
)


LAYER_CONFIGS = [
    LayerConfig(
        section_id="02",
        name="ISL/GSL 链路评估层",
        module="src/link",
        slug="链路评估层",
        arxiv_query_id="02_link",
        focus="ISL/GSL 可见性、星间/星地物理链路、链路预算、光/RF 链路质量、测量验证和动态接触窗口。",
        subcategories=(
            ("ISL 几何/物理可用性", r"(?:\b(inter[- ]satellite links?|inter satellite links?|intersatellite links?|ISLs?|OISL|LISL|inter[- ]plane|inter[- ]satellite ranging|link availability|link duration|link performance|link evaluation|contact window|satellite link simulation)\b|\binter[- ]satellite\b.*\blink\b)"),
            ("光/激光 ISL 与 PAT", r"(?:\b(optical|laser|FSO|free[- ]space optical)\b.*\b(link|communication|communications|terminal|PAT|acquisition|pointing|tracking|beam|feeder|inter[- ]satellite|satellite[- ]ground)\b|\b(OISL|LISL|PAT|beam wander|beam steering|setup delay)\b)"),
            ("GSL/馈电/地面站", r"\b(GSL|ground station|gateway|feeder link|satellite[- ]ground|ground[- ]satellite|earth[- ]to[- ]satellite|elevation angle|visibility window)\b"),
            ("链路预算/信道/容量", r"\b(link budget|channel model|channel modeling|path loss|FSPL|SNR|SINR|received power|outage|capacity|rate analysis|attenuation|LOS/NLOS|line[- ]of[- ]sight|non[- ]line[- ]of[- ]sight)\b"),
            ("RF/mmWave/THz 链路", r"\b(RF|Ka[- ]band|Ku[- ]band|V[- ]band|THz|terahertz|mmWave|millimeter[- ]wave).*\b(link|satellite|channel|communication|capacity|rate)\b"),
            ("链路测量/验证基准", r"(?:\b(flight data|in[- ]orbit performance|CubeSat|measuring|measurements?|propagation measurements?|link measurements?|performance analysis|error performance measurements?|satellite link availability)\b.*\b(links?|satellite|ISL|GSL|channel)\b|\b(links?|satellite|ISL|GSL|channel)\b.*\b(measuring|measurements?|availability|simulation package|performance analysis)\b)"),
        ),
        exclude_patterns=(
            r"urban heat island",
            r"satellite remote sensing",
            r"GNSS NLOS.*urban",
            r"tsunami",
            r"pathogenicity island",
            r"microgrid.*islands",
            r"satellite imagery",
        ),
        arxiv_keywords="inter-satellite link / ISL / OISL / ground station / FSO / satellite-ground / link budget / path loss / propagation measurement",
        related_work_advice="建议从 ISL 几何、光/PAT、GSL/地面站、链路预算/信道、链路测量/验证五类各选 3-5 篇；优先保留能直接校验距离、LOS、仰角、FSPL、接收功率、SNR、容量、outage、setup delay 或实测 link availability 的论文。",
        gate_patterns=(
            r"\b(satellite|LEO|constellation|spacecraft|ground station|gateway|feeder|inter[- ]satellite|intersatellite|ISLs?|OISL|LISL)\b",
            r"\b(inter[- ]satellite links?|intersatellite links?|satellite links?|ISLs?|OISL|LISL|GSL|satellite[- ]ground|ground[- ]satellite|earth[- ]to[- ]satellite|feeder link|optical|laser|FSO|visibility|line[- ]of[- ]sight|elevation|link budget|link performance|link availability|link evaluation|satellite link simulation|path loss|SNR|SINR|outage|capacity|channel model|measuring|propagation measurements?|error performance|Ka[- ]band|Ku[- ]band|THz|mmWave|RF|attenuation|rate analysis)\b",
        ),
        demote_patterns=(
            r"\b(routing|route|path search|shortest path|snapshot routing|topology|SDN|TCP|QUIC|transport|PEP|SCPS|CFDP)\b",
            r"\b(edge computing|offloading|federated learning|authentication|zero trust|fingerprinting|spoof detection|attack|eavesdropping)\b",
            r"\b(orbit determination|orbital transfer|trajectory|rendezvous|cislunar dynamics|navigation constellation|PNT architecture)\b",
            r"\b(GNSS|GPS|BeiDou|BDS).*\b(urban|localization|positioning|NLOS correction)\b",
            r"\b(NDN|forwarding plane|handover|handovers|urban air mobility|quantum key distribution|privacy amplification|consensus|gravitational wave|interferometer|attitude[- ]formation tracking|LOS/NLOS classifier)\b",
            r"\b(antenna|front[- ]end|MMIC|amplifier|circuit|component)\b(?!.*\b(link|capacity|channel|outage|rate)\b)",
        ),
    ),
    LayerConfig(
        section_id="03",
        name="拓扑策略层",
        module="src/net",
        slug="拓扑策略层",
        arxiv_query_id="03_topology",
        focus="LEO/卫星网络 who-connects-to-whom 拓扑生成、链路分配、动态图快照、连通性和鲁棒性。",
        subcategories=(
            ("ISL 拓扑模式", r"\b(3[- ]ISL|grid|mesh|ring|honeycomb|non[- ]grid[- ]mesh|inter[- ]plane|intra[- ]plane|link assignment|link planning|link reassignment)\b"),
            ("需求/容量/故障感知拓扑", r"\b(demand[- ]aware|traffic[- ]driven|capacity[- ]maximiz|failure[- ]aware|fault[- ]tolerant|resilien|robustness|node failure|link failure)\b"),
            ("图指标/连通性分析", r"\b(connectivity|diameter|degree distribution|spanning tree|graph metric|connected)\b"),
            ("星地/多层拓扑", r"\b(satellite[- ]ground|satellite[- ]terrestrial|multi[- ]layer|VLEO[- ]LEO|NTN|space[- ]air[- ]ground)\b.*\b(topology|interconnection|connectivity)\b"),
            ("动态/快照/虚拟拓扑", r"\b(snapshot|dynamic topology|time[- ]varying topology|topology[- ]varying|topology switching|topology virtualization|virtual topology|logical topology|topology[- ]based|topology churn|topology dynamic)\b"),
            ("拓扑设计/控制/优化", r"\b(topology design|topological design|topology control|topology optimization|topology management|topology reconfiguration|topology modeling|topology dynamics?|topology[- ]driven|interconnection design)\b"),
        ),
        exclude_patterns=(
            r"semantic communication",
            r"constellation diagram",
            r"spacecraft topology optimization",
            r"actuator",
            r"additive manufactur",
            r"satellite structure",
            r"supporting structure",
            r"switching topology.*(attitude|stabili[sz]ation|controller|formation control|flocking)",
            r"satellite imagery",
            r"road topology",
            r"neural network topology",
            r"Poincare Map Topology",
            r"E[- ]Plane Resonators",
        ),
        arxiv_keywords="satellite topology / topology design / dynamic topology / temporal graph / logical topology / link assignment / LEO constellation connectivity",
        related_work_advice="建议从早期 logical/virtual topology、snapshot/reassignment、3-ISL/non-grid topology、demand-aware topology、failure-aware topology 五类各选 4-6 篇；路由/资源分配论文只作为邻接动机。",
        gate_patterns=(
            r"\b(LEO|VLEO|NGSO|MegaLEO|mega[- ]?constellations?|low[- ]earth orbit|satellite topology|satellite networks?|satellite constellation|constellation network|optical satellite networks?|inter[- ]satellite|intersatellite|ISL|satellite[- ]ground|satellite[- ]terrestrial|GNSS|NTN)\b",
            r"\b(topology design|topological design|topology control|topology optimization|topology modeling|topology dynamics?|topology[- ]driven|topology[- ]based|dynamic topology|time[- ]varying topology|topology[- ]varying|topology switching|topology virtualization|logical topology|virtual topology|satellite[- ]ground topology|snapshot|link assignment|link planning|link reassignment|interconnection design|3[- ]ISL|non[- ]grid[- ]mesh|spanning tree|connectivity|robustness|resilien|capacity|node failure|link failure)\b",
        ),
        demote_patterns=(
            r"\b(resource allocation|beam[- ]hopping|beam management|traffic(?: data)? estimation|federated learning|telemetry|offloading|Dijkstra|route reconstruction|snapshot routing)\b",
        ),
    ),
    LayerConfig(
        section_id="04",
        name="路由算法层",
        module="src/net",
        slug="路由算法层",
        arxiv_query_id="04_routing",
        focus="LEO/卫星网络路由、路径选择、负载均衡、SDN/NFV、多路径和抗毁路由。",
        subcategories=(
            ("Baseline SPF / 图搜索", r"\b(Dijkstra|Floyd|shortest path|SPF|k[- ]shortest|min[- ]hop|path search|path computation|graph search|GPS[- ]Free Geometric Routing)\b"),
            ("通用/分布式路由算法", r"\b(routing algorithm|routing protocol|routing scheme|routing strategy|routing method|packet routing|distributed routing|semi[- ]distributed routing|end[- ]to[- ]end routing|inter[- ]satellite link routing)\b"),
            ("时变/快照/预测路由", r"\b(temporal graph|topology[- ]varying|snapshot routing|contact graph routing|CGR|DTN|predictive routing|stable routing|dynamic routing)\b"),
            ("流量工程/负载均衡", r"\b(traffic engineering|load[- ]aware|load[- ]balanc\w*|min[- ]load|backpressure|congestion[- ]aware|multi[- ]commodity flow|MLU)\b"),
            ("多路径/ECMP/路径多样性", r"\b(ECMP|multipath routing|multi[- ]path routing|path diversity|network coding|MPTCP|QUIC)\b"),
            ("SDN/Segment/Source Routing", r"\b(SDN routing|software[- ]defined.*routing|segment routing|source routing|service function|SFC|NFV|controller|control[- ]domain)\b"),
            ("ML/RL/GNN 路由", r"(?:\b(DRL|MARL|Q[- ]learning|reinforcement learning|GNN|GraphSAGE|graph neural network|transformer)\b.*\b(routing|route|path|forwarding)\b|\b(routing|route|path|forwarding)\b.*\b(DRL|MARL|Q[- ]learning|reinforcement learning|GNN|GraphSAGE|graph neural network|transformer)\b)"),
            ("分层/地理/可扩展路由", r"(?:\b(hierarchical|geographic|geometric|angular|domain partition|inter[- ]shell|inter[- ]domain|scalable routing|mega[- ]constellation)\b.*\b(routing|route|path)\b|\b(routing|route|path)\b.*\b(hierarchical|geographic|geometric|angular|inter[- ]shell|inter[- ]domain|scalable)\b)"),
            ("QoS/鲁棒/安全/能量感知路由", r"\b(QoS routing|reliable routing|low[- ]latency routing|fault[- ]tolerant|secure routing|anonymous path|anti[- ]?jamming|resilien\w*|queue[- ]aware|energy[- ]aware|weather[- ]aware|eclipse|sun[- ]outage)\b"),
            ("组播/任播/服务/内容感知路由", r"\b(multicast|anycast|ICN|NDN|content[- ]aware|semantic routing|service routing)\b"),
        ),
        exclude_patterns=(
            r"author=.*",
            r"RETRACTED ARTICLE|retracted",
            r"satellite image",
            r"satellite images",
            r"cloud and shadow",
            r"GNSS.*multipath",
            r"GPS.*multipath",
            r"Galileo",
            r"BeiDou.*multipath",
            r"BDS.*multipath",
            r"pseudorange",
            r"carrier phase",
            r"software[- ]defined radio",
            r"software[- ]defined receiver",
            r"\bSDR\b",
            r"vehicle routing",
            r"satellite customers",
            r"satellite stations",
            r"stockyard",
            r"reclaimer",
            r"AGV",
            r"time windows",
            r"datacenter|data center|DCN|flowlet",
            r"orbital angular momentum",
            r"Rayleigh fading",
            r"multipath fading",
            r"QAM|TOA-DOA|crosstalk",
            r"power line inspection",
        ),
        arxiv_keywords="satellite routing / LEO routing / shortest path / SDN / ECMP / multipath / resilient routing",
        related_work_advice="建议选 20-30 篇，不是 695 篇全引；其中经典 LEO routing baseline 3-5 篇，时变/快照/最短路 5-8 篇，流量工程/负载均衡/多路径 4-6 篇，SDN/SR 4-6 篇，ML/RL/GNN 4-6 篇。",
        gate_patterns=(
            r"\b(satellite|satellites|LEO|VLEO|MEO|NGSO|NGEO|constellation|mega[- ]constellation|inter[- ]satellite|intersatellite|ISL|OISL|LISL|space network|CubeSat|nanosatellite|satellite[- ]terrestrial|NTN|SAGIN|space[- ]air[- ]ground|Internet of Satellites|Starlink|OneWeb|Iridium)\b",
            r"\b(routing|route|rerouting|path|path computation|forwarding|traffic engineering|source routing|segment routing|Dijkstra|shortest path|SPF|Floyd|ECMP|multipath routing|multi[- ]path routing|load[- ]balanced routing|backpressure routing|CGR|DTN|QoS routing)\b",
        ),
        demote_patterns=(
            r"\b(controller placement|gateway placement|resource allocation|beam hopping|handover|offloading|task allocation|spectrum allocation)\b(?!.*\b(routing|route|path)\b)",
            r"\b(multipath mitigation|multipath detection|multipath estimation|receiver|antenna|reflectometry)\b",
            r"\b(LTE|5G NR|OFDMA|CDMA|WCDMA|NOMA|VLC|base station)\b(?!.*\b(satellite routing|LEO routing)\b)",
            r"\b(SpaceWire|OBC|quantum satellite|entanglement routing)\b",
            r"\b(forwarding plane|handover|handovers)\b(?!.*\b(routing|route|path)\b)",
        ),
    ),
    LayerConfig(
        section_id="05",
        name="流量/容量/时延层",
        module="src/metrics + src/traffic",
        slug="流量容量时延层",
        arxiv_query_id="05_traffic",
        focus="业务流量、容量/吞吐、时延/排队、QoS/QoE 与性能评估指标。",
        subcategories=(
            ("流量工程/需求到路径", r"\b(traffic engineering|traffic scheduling|traffic prediction|traffic modeling|traffic[- ]aware|demand[- ]aware|load[- ]balanc\w*|load balance|flow[- ]level|demand[- ]to[- ]path|bandwidth prediction|bandwidth allocation|QoS|Quality of Service|QoE)\b"),
            ("网络容量/吞吐/瓶颈", r"\b(network capacity|throughput analysis|throughput optimization|throughput maximization|high[- ]throughput|transmission capacity|capacity analysis|capacity scheduling|max[- ]flow|maximum flow|link utilization|bottleneck|traffic intensity|rate control)\b"),
            ("时延/RTT/Delay 指标", r"\b(E2E latency|end[- ]to[- ]end latency|low[- ]latency|latency prediction|latency measurement|latency measurements|RTT|round trip time|delay analysis|delay constraints|queuing delay|queueing delay)\b"),
            ("队列/拥塞/缓冲模型", r"\b(queue[- ]aware|queues?|queueing|queuing|time[- ]sensitive networking|buffer sizing|bufferbloat|congestion control|ECN|loss differentiation|queue stability)\b"),
            ("LEO Internet 实测/Benchmark", r"\b(Starlink|SaTE|LeoCC|Hypatia|measurement|benchmark|characteri[sz]ing).*\b(latency|RTT|throughput|queu|bottleneck|performance)\b"),
        ),
        exclude_patterns=(
            r"land mobile satellite channel",
            r"high speed train satellite channel",
            r"RTT.*localization",
            r"localization.*RTT",
            r"Doppler Measurements.*Localization",
            r"IoRT Localization",
            r"GNSS",
            r"pose estimation",
            r"landmark localization",
            r"precoding",
            r"beamforming",
            r"LDPC",
            r"NOMA|RSMA",
            r"phase noise",
            r"antenna",
            r"RF front[- ]end",
            r"frequency plan",
            r"beam power",
            r"attenuation",
            r"beam pointing",
            r"physical layer",
            r"cell[- ]free massive MIMO",
            r"elliptic curve",
            r"authentication",
            r"solar energy",
            r"spacecraft performance",
            r"CubeSat resource utilization",
            r"information bottleneck",
        ),
        arxiv_keywords="satellite traffic / LEO capacity / throughput / latency / delay / QoS / demand",
        related_work_advice="建议每个子类选 2-4 篇，优先保留能复现实验输出的论文：RTT CDF、p95/p99 latency、link utilization、MLU、max-flow/network capacity、bottleneck links、demand-to-path assignment、queue/buffer behavior；Benchmark 若偏少，应从 04/09/10 层补查 Starlink、measurement、TCP/QUIC、low-latency、QoS 标题。",
        gate_patterns=(
            r"\b(LEO|satellite|satellites|satellite network|satellite constellation|constellation|NGSO|Starlink|satcom|all[- ]optical satellite network|mega[- ]?constellation|low[- ]earth orbit)\b",
            r"\b(traffic engineering|traffic scheduling|traffic prediction|traffic modeling|traffic[- ]aware|demand[- ]aware|load[- ]balanc\w*|load balance|flow[- ]level|bandwidth prediction|bandwidth allocation|network capacity|capacity analysis|capacity scheduling|throughput analysis|throughput optimization|throughput maximization|high[- ]throughput|transmission capacity|link utilization|bottleneck|max[- ]flow|maximum flow|traffic intensity|QoS|Quality of Service|QoE|rate control|data transport|E2E latency|end[- ]to[- ]end latency|low[- ]latency|latency prediction|latency measurement|RTT|round trip time|delay analysis|delay constraints|queuing delay|queueing delay|queue[- ]aware|queues?|queueing|queuing|time[- ]sensitive networking|buffer sizing|bufferbloat|congestion control|ECN|loss differentiation)\b",
        ),
        demote_patterns=(
            r"\b(High Throughput Satellite|Very High[- ]Throughput Satellite|HTS)\b(?!.*\b(traffic|load|path|latency|delay|throughput analysis|network capacity)\b)",
            r"\b(edge computing|task offloading|MEC|collaborative offloading|satellite computing)\b(?!.*\b(traffic|load|latency|throughput|capacity)\b)",
            r"\b(TCP|QUIC|BBR|PEP)\b(?!.*\b(metric|benchmark|latency|queue|throughput|performance)\b)",
            r"\b(power allocation|resource allocation|spectrum sensing)\b(?!.*\b(traffic|capacity|latency|throughput|load)\b)",
            r"\b(High[- ]Throughput Satellite|Very High[- ]Throughput Satellite|HTS|Q[- ]band|Ka/Q|MIMO|physical layer|beam pointing|attenuation)\b(?!.*\b(traffic|load|latency|queue|path|bottleneck|throughput analysis|network capacity|capacity analysis)\b)",
        ),
    ),
    LayerConfig(
        section_id="06",
        name="可微优化层",
        module="src/opt",
        slug="可微优化层",
        arxiv_query_id="06_differentiable",
        focus="可微仿真、自动微分、梯度优化、代理模型和面向卫星/轨道/网络的优化方法。",
        subcategories=(
            ("AD/可微轨道传播", r"(?:\b(differentiable|automatic differenti|autodiff|auto[- ]differenti|JAX|dSGP4|adjoint|reverse[- ]mode).*\b(SGP4|J2|orbit propagation|orbital|orbit prediction|spacecraft|propagator)\b|\b(orbital|orbit prediction|propagator|perturbation).*\b(differentiable|automatic differenti|autodiff|JAX|dSGP4|adjoint)\b)"),
            ("端到端可微卫星仿真", r"\b(end[- ]to[- ]end differentiable|differentiable).*\b(satellite simulation|satellite networking|satellite network|soft coverage|soft topology|soft routing|inter[- ]satellite|coverage|ISL|cross[- ]orbit)\b"),
            ("梯度轨道/星座优化", r"(?:\b(gradient[- ]based|gradient descent|trajectory optimization|orbit design|constellation optimization|coverage optimization|Walker)\b.*\b(satellite|spacecraft|orbit|LEO|constellation|coverage)\b|\b(satellite|spacecraft|orbit|LEO|constellation|coverage|trajectory)\b.*\b(gradient[- ]based|gradient descent|trajectory optimization|orbit design|constellation optimization|coverage optimization)\b)"),
            ("航天代理模型/PINN 桥接", r"(?:\b(surrogate model|physics[- ]informed|neural ODE|neural operator|PINN|reduced[- ]order|emulator)\b.*\b(spacecraft|orbit|orbital|trajectory|thermal)\b|\b(spacecraft|orbit|orbital|trajectory|thermal)\b.*\b(surrogate model|physics[- ]informed|neural ODE|neural operator|PINN|reduced[- ]order|emulator)\b)"),
            ("ML/RL 卫星优化基线", r"\b(reinforcement learning|deep reinforcement learning|DRL|graph neural network|GNN|deep learning).*\b(LEO satellite|satellite network|routing|handover|resource allocation|coverage|offloading)\b"),
        ),
        exclude_patterns=(
            r"constellation matrix",
            r"chip electromagnetic leakage",
            r"southern hemisphere constellations",
            r"orbital angular momentum",
            r"\bOAM\b",
            r"constellation shaping",
            r"constellation diagram",
            r"signal constellation",
            r"\b(MIMO|MU-MIMO|RIS|NOMA|RSMA)\b",
            r"fluid antenna",
            r"fiber",
            r"optical coherent",
            r"modulation classification",
            r"remote sensing|SAR|satellite imagery",
            r"urban heat island",
            r"molecular orbital|atomic orbital|orbital-free",
            r"exoplanet|stellar",
            r"robot teleoperation",
            r"biological gradient",
            r"thermal design",
        ),
        arxiv_keywords="differentiable satellite / autodiff orbit / gradient optimization / surrogate model / PINN / adjoint / dSGP4 / JAX",
        related_work_advice="建议按三桶写作：核心可微证据、桥接代理/PINN/轨迹优化、非可微 RL/GNN baseline；本层高置信 core 可能很少，应从邻接候选和 01/07 层补足，但 gap 要写清楚：可微 J2/SGP4 + soft coverage/ISL + Adam 端到端优化几乎为空。",
        gate_patterns=(
            r"\b(satellite|LEO|low earth orbit|NGSO|mega[- ]constellation|spacecraft|cislunar|inter[- ]satellite|Walker|SGP4|J2|orbit|orbital|coverage|ISL)\b",
            r"\b(differentiable|autodiff|automatic differenti|automatic differentiation|gradient[- ]based|gradient descent|adjoint|reverse[- ]mode|JAX|dSGP4|surrogate model|physics[- ]informed|neural ODE|neural operator|PINN|end[- ]to[- ]end differentiable|soft coverage|soft topology|soft routing|reinforcement learning|DRL|graph neural network|GNN)\b",
        ),
        demote_patterns=(
            r"\b(reinforcement learning|DRL|graph neural network|GNN|deep learning)\b(?!.*\b(differentiable|gradient|surrogate|physics[- ]informed|neural ODE|neural operator|PINN)\b)",
            r"\b(joint optimization|resource allocation|power allocation|offloading|routing|handover)\b(?!.*\b(differentiable|gradient|surrogate|orbit|coverage|Walker|ISL|LEO network metrics)\b)",
            r"^(?=.*\b(thermal|attitude planning|attitude control)\b)(?!.*\b(differentiable|gradient|surrogate|physics[- ]informed|neural ODE|neural operator|PINN)\b)",
            r"\bservice[- ]differentiable\b",
        ),
    ),
    LayerConfig(
        section_id="07",
        name="PINN / 神经传播层",
        module="src/opt (NN layers)",
        slug="PINN神经传播层",
        arxiv_query_id="07_pinn",
        focus="PINN、神经算子、神经 ODE、动力学识别和轨道/航天神经传播器。",
        subcategories=(
            ("PINN/物理信息轨道传播", r"\b(PINN|physics[- ]informed|physics informed|PIML|physics[- ]guided|scientific machine learning).*\b(orbit prediction|orbital prediction|orbital anomaly|satellite state estimation|trajectory prediction|orbit determination|orbital dynamics|spacecraft dynamics|propagator|propagation|ephemeris|TLE|SGP4|J2|cislunar|orbital transfer|orbital maneuver|satellite maneuver|spacecraft pursuit|trajectory planning)\b"),
            ("轨道神经算子/DeepONet", r"\b(neural operator|DeepONet|Fourier neural operator|FNO|operator learning).*\b(orbit|orbital|trajectory|spacecraft|dynamics|cislunar)\b"),
            ("神经ODE/可微残差传播器", r"\b(neural ODE|dynamics identification|Koopman|latent dynamics|differentiable simulation|residual propagator|normalizing flow).*\b(orbit|orbital|trajectory|spacecraft|propagator|J2|SGP4|TLE)\b"),
            ("ML 轨道预测/定轨基线", r"(?:\b(machine learning|deep learning|neural network|LSTM|Transformer|patch[- ]transformer|FDLSTM|Koopman|surrogate).*\b(satellite orbit prediction|LEO satellite orbit|space object orbital prediction|orbit correction|precise orbit determination|orbital maneuver|trajectory planning|clock bias prediction)\b|\b(orbit prediction|satellite orbit prediction|LEO satellite orbit|orbital prediction|orbit correction|precise orbit determination|clock bias prediction).*\b(LSTM|Transformer|patch[- ]transformer|FDLSTM|neural network|machine learning|deep learning|Koopman|surrogate)\b)"),
        ),
        exclude_patterns=(
            r"coral reef",
            r"ocean wave",
            r"welding",
            r"atomic feature",
            r"neural operator decomposition",
            r"electrospinning|spinning|de[- ]spinning|SpiNNaker|SpInN|pinned",
            r"orbital angular momentum",
            r"atomic orbital|molecular orbital|orbital-free",
            r"satellite image|satellite imagery|remote sensing|Sentinel|soil moisture|solar radiation|cloud optical depth|ocean|tropical cyclone",
            r"channel estimation|pilot selection|MIMO|OTFS|NOMA|mmWave|terahertz|laser communication|wavefront",
            r"battery|Li[- ]ion|thermal|power system|fault detection|pose estimation",
        ),
        arxiv_keywords="PINN orbit / physics-informed spacecraft / neural operator dynamics / DeepONet trajectory / neural ODE satellite",
        related_work_advice="建议选 20-30 篇：PINN/SciML 基础 3-5 篇，核心轨道 PINN/神经算子 5-8 篇，ML 轨道预测/定轨基线 6-10 篇，航天动力学/控制邻接 2-4 篇；不要把遥感、通信信道、热/电源健康论文当传播器核心。",
        gate_patterns=(
            r"\b(PINN|physics[- ]informed|physics informed|PIML|physics[- ]guided|scientific machine learning|neural operator|DeepONet|Fourier neural operator|FNO|neural ODE|neural surrogate|Koopman|Pontryagin Neural Networks|normalizing flow|machine learning|deep learning|neural network|LSTM|Transformer|patch[- ]transformer|FDLSTM|surrogate)\b",
            r"\b(orbit prediction|orbital prediction|orbital anomaly|satellite state estimation|trajectory prediction|orbit determination|orbit correction|orbital dynamics|spacecraft dynamics|propagator|propagation|ephemeris|TLE|SGP4|J2|perturbation|cislunar|space object orbital prediction|orbital transfer|orbital maneuver|satellite maneuver|spacecraft pursuit|satellite orbit prediction|LEO satellite orbit|precise orbit determination|trajectory planning)\b",
        ),
        demote_patterns=(
            r"\b(attitude control|attitude dynamics|rendezvous|formation|pursuit|evasion|thermal|battery|power|health)\b",
        ),
    ),
    LayerConfig(
        section_id="08",
        name="AI 编排 / LLM Agent 层",
        module="src/lab",
        slug="AI编排LLM层",
        arxiv_query_id="08_llm",
        focus="LLM/Agent 自然语言到工具调用、仿真/实验编排、卫星网络控制平面、空间任务/运维助手。",
        subcategories=(
            ("航天/卫星运维 Agent", r"\b(spacecraft operator|satellite operator|operations agent|autonomous spacecraft|mission assistant|scheduling assistant|behavior reasoning|spacecraft control)\b"),
            ("LLM 辅助卫星网络管理", r"\b(LLMs?|large language models?|language models?|GPT|RAG)\b.*\b(network slicing|task offloading|resource allocation|scheduling|security|routing|satellite network|LEO|NTN)\b"),
            ("服务编排/控制平面", r"(?:\b(orchestration|orchestrator|orchestrating|orchestration methods|control plane|Kubernetes|container|NFV|VNF|SFC|service function chain|emulation platforms?|space cloud|orbital edge|network slicing)\b.*\b(satellite|LEO|NTN|space cloud|orbital edge)\b|\b(satellite|LEO|NTN|space cloud|orbital edge|satellite network)\b.*\b(orchestration|orchestrating|orchestration methods|control plane|Kubernetes|container|NFV|VNF|SFC|service function chain|emulation platforms?)\b)"),
            ("LLM-to-tool/仿真编排", r"(?:\b(LLMs?|large language models?|GPT|RAG|language models?|VLM|LLM[- ]assisted|LLM[- ]guided|tool use|function calling|planner|workflow|code generation|spaceborne equipment code generation|simulation agent|experiment agent)\b.*\b(satellite|LEO|spacecraft|spaceborne|satellite network|NTN|simulation|simulator|digital twin|range scheduling)\b|\b(satellite|LEO|spacecraft|spaceborne|satellite network|NTN|simulation|simulator|digital twin|range scheduling|spacecraft control|autonomous spacecraft)\b.*\b(LLMs?|large language models?|GPT|RAG|language models?|VLM|LLM[- ]assisted|LLM[- ]guided|tool use|function calling|planner|workflow|code generation)\b)"),
            ("Agentic simulation/多智能体系统", r"\b(agent|multi[- ]agent|autonomous agent|copilot|planner|tool use|function calling)\b.*\b(simulation|simulator|digital twin|platform|benchmark|orchestration|spacecraft|satellite network)\b"),
        ),
        exclude_patterns=(
            r"geospatial foundation model",
            r"Earth observation",
            r"satellite imagery|remote sensing|SAR|poverty mapping|urban planning|road assessment",
            r"pile foundation|floating pile|foundation model.*soil|Vlasov",
            r"nucleotide|viral genomics|human genes|single[- ]nucleotide|DNA language model",
            r"term[- ]similarity|SimpleOCR|activation monitors|Chameleon",
            r"PhilEO|SeeFar|DiffusionSat|SATIN|OReole|WV-Net|solar irradiance|GNSS-FM",
            r"channel prediction|beamforming|semantic communication|HAP downlink|massive MIMO",
            r"captioning|labeling",
        ),
        arxiv_keywords="LLM satellite / RAG / tool use / function calling / agent simulation / digital twin / network orchestration / autonomous spacecraft",
        related_work_advice="建议手工补 5-7 篇通用 LLM agent/tool-use/RAG 基础；本地库中选 space LLM/operator 5-8 篇、LLM-assisted satellite-network management 6-10 篇、satellite orchestration/control-plane 8-12 篇；纯 MARL 路由/切换/卸载只作为邻接证据。",
        gate_patterns=(
            r"\b(LLMs?|large language models?|GPT|RAG|language models?|VLM|LLM[- ]assisted|LLM[- ]guided|agent|multi[- ]agent|autonomous agent|autonomous spacecraft|tool use|function calling|planner|orchestration|orchestrator|control plane|workflow|Kubernetes|container|NFV|VNF|SFC|service function chain|digital twin|simulation|simulator|spacecraft operator|satellite operator|spacecraft control|behavior reasoning|spaceborne equipment code generation)\b",
            r"\b(satellite|LEO|spacecraft|spaceborne|satellite network|NTN|space cloud|orbital edge|simulation|simulator|digital twin|network slicing|task offloading|resource allocation|scheduling|routing|management|operations|spacecraft control|autonomous spacecraft)\b",
        ),
        demote_patterns=(
            r"^(?=.*\b(multi[- ]agent reinforcement learning|MARL|reinforcement learning|DRL)\b)(?!.*\b(LLMs?|large language model|language model|tool|simulator|digital twin|orchestration|control plane|spacecraft control)\b)",
            r"\bfoundation model\b(?!.*\b(LLM|language model|agent|operations|tool|simulation|orchestration)\b)",
        ),
    ),
    LayerConfig(
        section_id="09",
        name="切换 / 移动性层",
        module="src/link + src/net",
        slug="切换移动性层",
        arxiv_query_id="09_handover",
        focus="LEO 卫星切换、移动性管理、波束跳变/波束调度、用户关联和切换优化。",
        subcategories=(
            ("测量/Benchmark/Survey", r"\b(Starlink|measurement|benchmark|survey|session duration|handover analysis|mobility analysis)\b.*\b(handovers?|handoffs?|mobility|session|Starlink)\b"),
            ("传统资源预留/排队切换", r"\b(call dropping|handover queue|handover queuing|channel allocation|admission control|resource reservation)\b.*\b(satellite|LEO|MSS|handovers?|handoffs?)\b"),
            ("路由/拓扑耦合切换", r"\b(handover[- ]aware routing|routing[- ]cost.*handover|ISL.*group handover|group handover|link duration|dynamic optical satellite connectivity)\b"),
            ("卫星/波束/用户关联", r"(?:\b(satellite selection|user association|access selection|space[- ]ground association|cell selection)\b.*\b(visibility|link duration|handover frequency|service continuity|mobility|handovers?|reducing handover)\b|\b(visibility|link duration|handover frequency|service continuity|mobility)\b.*\b(satellite selection|user association|access selection|space[- ]ground association|cell selection)\b)"),
            ("波束切换/Beam Handover", r"\b(beam handover|inter[- ]beam handover|spotbeam handover|beam switching|beam management|satellite switching)\b"),
            ("移动性管理/会话连续", r"\b(mobility management|IP mobility|node mobility|consumer mobility|location/identity separation|last[- ]hop ambiguity|feeder link switch|session continuity|service continuity)\b"),
            ("核心 Handover 算法", r"\b(handovers?|handoffs?|hand[- ]off|conditional handover|seamless handover|soft handover|hard handover|group handover|handover management|handover optimization|handover prediction|predictive handover|proactive handover)\b"),
        ),
        exclude_patterns=(
            r"mobile edge computing(?!.*satellite)",
            r"micromobility",
            r"Advanced Air Mobility",
            r"GPS spoofing",
            r"FANET",
            r"\b(LTE|WCDMA|UMTS|CDMA|HetNet|small[- ]cell|cell[- ]free)\b(?!.*\b(satellite|LEO|NTN)\b)",
            r"^(?!.*\b(satellite|LEO|NTN)\b.*\b(handovers?|handoffs?|hand[- ]off)\b).*(channel estimation|channel prediction|AFDM|OTFS|OFDM|OFDMA|MIMO|equalization|waveform)",
            r"base station association",
            r"piezoelectric.*handover mechanism",
            r"gravitational wave detection",
            r"Instant Positioning",
            r"Delay-Doppler",
        ),
        arxiv_keywords="LEO handover / satellite mobility / beam hopping / user association / satellite selection / service continuity",
        related_work_advice="建议选 30-45 篇：handover 算法 8-10，mobility/session continuity 5-7，beam handover/switching 4-6，routing/topology-coupled 4-6，measurement/survey/classic 4-6，legacy queue/channel reservation 2-4；优先对应 handover frequency、interruption duration、link duration、ping-pong、SPF recomputation。",
        gate_patterns=(
            r"\b(satellite|LEO|low earth orbit|NTN|non[- ]terrestrial|NGSO|Starlink|constellation|space[- ]ground|ground[- ]satellite|MSS|GEO|MEO)\b",
            r"\b(handovers?|handoffs?|hand[- ]off|conditional handover|seamless handover|soft handover|group handover|handover management|mobility management|IP mobility|node mobility|location/identity separation|consumer mobility|feeder link switch|last[- ]hop ambiguity|satellite selection|user association|access selection|space[- ]ground association|beam switching|beam handover|inter[- ]beam handover|spotbeam handover|beam management|handover frequency|service continuity|session continuity|link duration)\b",
        ),
        demote_patterns=(
            r"^(?=.*\b(beam hopping|beam scheduling|resource allocation|power allocation)\b)(?!.*\b(handovers?|handoffs?|switching|mobility|service continuity|session continuity)\b)",
            r"\b(authentication|security|attack|intrusion)\b(?!.*\b(handover|mobility management)\b)",
        ),
    ),
    LayerConfig(
        section_id="10",
        name="TCP / 传输层",
        module="外接 (ns-3/解析模型)",
        slug="TCP传输层",
        arxiv_query_id="10_tcp",
        focus="LEO/卫星网络 TCP、QUIC、MPTCP、拥塞控制、PEP 和传输层性能。",
        subcategories=(
            ("QUIC/HTTP3 over satellite", r"\b(QUIC|HTTP/3|MM[- ]QUIC|QPEP)\b"),
            ("MPTCP/多路径传输", r"\b(MPTCP|multipath transport|multipath scheduler|multi[- ]path transport)\b"),
            ("相邻空间传输协议", r"\b(SCPS[- ]TP|XTP|LEOTP|network[- ]coded transport|transport[- ]layer coding|ARQ)\b"),
            ("PEP/代理/分裂传输", r"\b(QPEP|P[- ]XCP|PETRA|PEP|performance enhancing proxy|performance enhancing transport architecture|split[- ]TCP|split TCP|TCP gateway|onboard proxy|secure PEP|SatPipe)\b"),
            ("传输测量/建模/仿真", r"\b(testbed|emulation|simulation|ns[- ]3|measurement|modeling|throughput|goodput|RTT|loss model|transport performance|transport layer mechanisms)\b"),
            ("拥塞控制/丢包/超时行为", r"\b(congestion control|slow start|retransmission timeout|RTO|SACK|ACK|ECN|goodput|congestion window|bufferbloat|BDP|loss differentiation)\b"),
            ("TCP 变体/自适应", r"\b(SaTCP|StarTCP|LeoCC|TCP[- ]Peach|TCP[- ]Cherry|TCP[- ]Hybla|TCP[- ]Reno|TCP[- ]Vegas|CUBIC|BBR|TCP)\b"),
        ),
        exclude_patterns=(
            r"wireless uplinks(?!.*satellite)",
            r"Hamming Window",
            r"Short[- ]Window Gamma",
            r"Low[- ]Cubic Metric",
            r"\bquick\b",
            r"electron transport layer",
            r"\buBBR\b",
            r"NeQuick",
            r"RTT.*Localization",
            r"Localization.*RTT",
            r"Truck.*Time Windows",
            r"Data Centers",
            r"TCP[- ]Incast",
        ),
        arxiv_keywords="satellite TCP / LEO congestion control / QUIC satellite / MPTCP satellite / PEP / QPEP / SCPS-TP / Starlink TCP",
        related_work_advice="建议选 15-20 篇：SaTCP/StarTCP/LeoCC/SatPipe/SEARCH/TCP-over-Starlink、QUIC-over-GEO/QPEP/MM-QUIC、MPTCP-over-LEO、split-TCP/PEP classics，以及 1-2 篇解析 TCP satellite model；普通无线/数据中心 TCP 只作背景。",
        gate_patterns=(
            r"\b(TCP|MPTCP|QUIC|HTTP/3|PEP|QPEP|P[- ]XCP|PETRA|performance enhancing proxy|performance enhancing transport architecture|split[- ]TCP|split TCP|SCPS[- ]TP|XTP|LEOTP|SatPipe|SaTCP|StarTCP|LeoCC|congestion control|slow start|retransmission timeout|RTO|SACK|ACK|ECN|goodput|transport layer|transport protocol|transport layer mechanisms|bufferbloat)\b",
            r"\b(satellite|LEO|GEO|geostationary|Starlink|SATCOM|DVB[- ]RCS|DVB[- ]S2|deep space|space links|space communications|satellite[- ]terrestrial|constellation)\b",
        ),
        demote_patterns=(
            r"^(?=.*\b(window|timeout|transport|congestion)\b)(?!.*\b(TCP|MPTCP|QUIC|HTTP/3|PEP|QPEP|P[- ]XCP|PETRA|SCPS|LEOTP|congestion control|transport layer|transport protocol|satellite|LEO|GEO|Starlink)\b)",
            r"\b(GNSS|GPS|localization|Doppler)\b(?!.*\b(transport|TCP|QUIC|congestion)\b)",
        ),
    ),
]


def clean_title(value: str) -> str:
    value = html.unescape(value or "")
    value = re.sub(r"<[^>]+>", "", value)
    value = re.sub(r"^\s*\d+\.\s*", "", value)
    value = re.sub(r"\s+", " ", value)
    return value.strip()


def norm_title(value: str) -> str:
    value = clean_title(value)
    value = (
        value.replace("–", "-")
        .replace("—", "-")
        .replace("‐", "-")
        .replace("‑", "-")
        .replace("−", "-")
    )
    return re.sub(r"\s+", " ", value).strip().lower()


def compile_any(patterns: Iterable[str]) -> re.Pattern[str] | None:
    patterns = tuple(patterns)
    if not patterns:
        return None
    return re.compile("|".join(f"(?:{p})" for p in patterns), re.IGNORECASE)


def parse_bibtex_keys() -> dict[str, list[str]]:
    text = BIB_PATH.read_text(encoding="utf-8")
    by_title: dict[str, list[str]] = defaultdict(list)
    for match in re.finditer(r"@\w+\{([^,]+),\s*(.*?)(?=\n@\w+\{|\Z)", text, re.S):
        key = match.group(1).strip()
        body = match.group(2)
        title_match = re.search(r"\btitle\s*=\s*\{(.*?)\}", body, re.S)
        if not title_match:
            continue
        by_title[norm_title(title_match.group(1))].append(key)
    return by_title


def flatten_source(data: dict) -> dict[str, list[dict]]:
    by_title: dict[str, list[dict]] = defaultdict(list)
    for section_id, items in data["sections"].items():
        for item in items:
            title = clean_title(item.get("title", ""))
            if not title:
                continue
            row = dict(item)
            row["title"] = title
            row["section"] = section_id
            by_title[norm_title(title)].append(row)
    return by_title


def source_sections(entries: list[dict]) -> str:
    sections = {str(entry.get("section", "")) for entry in entries if entry.get("section")}
    return ";".join(sorted(sections, key=lambda x: int(x) if x.isdigit() else 99))


def md_cell(value: object) -> str:
    return str(value or "").replace("\n", " ").replace("|", "\\|")


def source_ref(row: dict) -> str:
    source = row.get("source", "")
    ref = row.get("ref", "")
    if source and ref:
        return f"{source} / {ref}"
    return source or ref


def rank_row(row: dict) -> tuple[int, str]:
    try:
        year_rank = -int(row.get("year", "") or 0)
    except ValueError:
        year_rank = 0
    return year_rank, norm_title(row.get("title", ""))


def classify_layer(config: LayerConfig, data: dict, source_by_title: dict[str, list[dict]], bib_by_title: dict[str, list[str]]) -> tuple[list[dict], list[dict], list[dict]]:
    global_exclude = compile_any(GLOBAL_EXCLUDE_PATTERNS)
    layer_exclude = compile_any(config.exclude_patterns)
    demote = compile_any(config.demote_patterns)
    gates = [re.compile(pattern, re.IGNORECASE) for pattern in config.gate_patterns]
    subcategory_regex = [(name, re.compile(pattern, re.IGNORECASE)) for name, pattern in config.subcategories]

    core: list[dict] = []
    adjacent: list[dict] = []
    excluded: list[dict] = []
    seen: set[str] = set()

    for item in data["sections"][config.section_id]:
        title = clean_title(item.get("title", ""))
        key = norm_title(title)
        if not title or key in seen:
            continue
        seen.add(key)

        row = dict(item)
        row["title"] = title
        row["source_sections"] = source_sections(source_by_title.get(key, []))
        row["bibtex_keys"] = ";".join(dict.fromkeys(bib_by_title.get(key, [])))

        if (global_exclude and global_exclude.search(title)) or (layer_exclude and layer_exclude.search(title)):
            row["category"] = "排除"
            excluded.append(row)
            continue

        if any(not gate.search(title) for gate in gates):
            row["category"] = "邻接但非核心"
            adjacent.append(row)
            continue

        if demote and demote.search(title):
            row["category"] = "邻接但非核心"
            adjacent.append(row)
            continue

        category = None
        for name, pattern in subcategory_regex:
            if pattern.search(title):
                category = name
                break

        if category:
            row["category"] = category
            core.append(row)
        else:
            row["category"] = "邻接但非核心"
            adjacent.append(row)

    core.sort(key=rank_row)
    adjacent.sort(key=rank_row)
    excluded.sort(key=rank_row)
    for idx, row in enumerate(core, 1):
        row["index"] = str(idx)
    return core, adjacent, excluded


def write_csv(config: LayerConfig, rows: list[dict]) -> Path:
    path = LIT_DIR / f"{config.section_id}_{config.slug}相关论文标题清单.csv"
    fieldnames = ["index", "category", "tier", "year", "title", "source", "ref", "bibtex_keys", "source_sections"]
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow({field: row.get(field, "") for field in fieldnames})
    return path


def write_all_csv(config: LayerConfig, core: list[dict], adjacent: list[dict], excluded: list[dict]) -> Path:
    path = LIT_DIR / f"{config.section_id}_{config.slug}相关论文标题清单_all.csv"
    fieldnames = ["index", "status", "category", "tier", "year", "title", "source", "ref", "bibtex_keys", "source_sections"]
    rows: list[tuple[str, dict]] = (
        [("core", row) for row in core]
        + [("adjacent", row) for row in adjacent]
        + [("excluded", row) for row in excluded]
    )
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for idx, (status, row) in enumerate(rows, 1):
            output = {field: row.get(field, "") for field in fieldnames}
            output["index"] = str(idx)
            output["status"] = status
            writer.writerow(output)
    return path


def write_markdown(config: LayerConfig, core: list[dict], adjacent: list[dict], excluded: list[dict], raw_count: int) -> Path:
    path = LIT_DIR / f"{config.section_id}_{config.slug}相关论文标题清单.md"
    category_counts = Counter(row["category"] for row in core)
    year_counts = Counter(row.get("year", "") for row in core)
    tier_counts = Counter(row.get("tier", "") for row in core)

    lines: list[str] = []
    lines.append(f"# {config.name}相关论文标题清单")
    lines.append("")
    lines.append(f"> 生成日期: {date.today().isoformat()}")
    lines.append("> 数据来源: `docs/literature/_data.json` + `docs/literature/_bibliography.bib`")
    lines.append(f"> 原始范围: 第 {config.section_id} 层 `{config.name}` 原始 {raw_count} 条。")
    lines.append(f"> 本清单: 高置信去重标题 {len(core)} 条；邻接但非核心 {len(adjacent)} 条；明显误伤 {len(excluded)} 条。")
    lines.append("")
    lines.append("## 筛选原则")
    lines.append("")
    lines.append(f"- 本层关注: {config.focus}")
    lines.append("- 保留标题直接命中本层物理、算法、系统或指标对象的论文；剔除只因 satellite/LEO/constellation 等宽泛词误入的论文。")
    lines.append("- 对跨层论文按标题主要贡献归类；例如链路论文中的纯轨道确定、拓扑论文中的纯路由、AI 层中的纯地理基础模型会降为邻接或排除。")
    lines.append("- `BibTeX key` 来自 `_bibliography.bib`，同名标题可能有多个 key，说明它曾被多个板块引用。")
    lines.append("")
    lines.append("## 数量概览")
    lines.append("")
    lines.append("| 类别 | 篇数 |")
    lines.append("|---|---:|")
    for category, _ in config.subcategories:
        lines.append(f"| {category} | {category_counts[category]} |")
    lines.append(f"| **合计** | **{len(core)}** |")
    lines.append("")
    lines.append("## Tier 分布")
    lines.append("")
    lines.append("| Tier | 篇数 |")
    lines.append("|---|---:|")
    for tier, count in sorted(tier_counts.items()):
        lines.append(f"| {tier or '未标注'} | {count} |")
    lines.append("")
    lines.append("## 年份分布")
    lines.append("")
    lines.append("| 年份 | 篇数 |")
    lines.append("|---|---:|")
    for year, count in sorted(year_counts.items(), key=lambda kv: -int(kv[0]) if str(kv[0]).isdigit() else 0):
        lines.append(f"| {year} | {count} |")
    lines.append("")
    lines.append("## 全量标题清单")
    lines.append("")
    for category, _ in config.subcategories:
        category_rows = [row for row in core if row["category"] == category]
        lines.append(f"### {category} ({len(category_rows)} 篇)")
        lines.append("")
        lines.append("| # | 年份 | Tier | 标题 | 来源/Ref | BibTeX key |")
        lines.append("|---:|---:|---|---|---|---|")
        for local_idx, row in enumerate(category_rows, 1):
            keys = ", ".join(key for key in row.get("bibtex_keys", "").split(";") if key)
            key_cell = f"`{md_cell(keys)}`" if keys else ""
            lines.append(
                f"| {local_idx} | {md_cell(row.get('year'))} | {md_cell(row.get('tier'))} | "
                f"{md_cell(row.get('title'))} | {md_cell(source_ref(row))} | {key_cell} |"
            )
        lines.append("")

    lines.append("## 邻接但非核心标题")
    lines.append("")
    lines.append("这些标题与本层相邻，但主要贡献偏其他层或应用场景。为保持清单准确性，不计入核心清单；完整原始记录仍保留在本层原始文档和 `_data.json` 中。")
    lines.append("")
    lines.append("| # | 年份 | 标题 | 来源/Ref |")
    lines.append("|---:|---:|---|---|")
    for idx, row in enumerate(adjacent[:40], 1):
        lines.append(f"| {idx} | {md_cell(row.get('year'))} | {md_cell(row.get('title'))} | {md_cell(source_ref(row))} |")
    if len(adjacent) > 40:
        lines.append(f"| ... | ... | 另有 {len(adjacent) - 40} 条邻接标题，详见原始层文档。 | ... |")
    lines.append("")
    lines.append("## 已剔除的典型误伤")
    lines.append("")
    if excluded:
        lines.append("| # | 年份 | 标题 | 来源/Ref |")
        lines.append("|---:|---:|---|---|")
        for idx, row in enumerate(excluded[:25], 1):
            lines.append(f"| {idx} | {md_cell(row.get('year'))} | {md_cell(row.get('title'))} | {md_cell(source_ref(row))} |")
        if len(excluded) > 25:
            lines.append(f"| ... | ... | 另有 {len(excluded) - 25} 条明显误伤。 | ... |")
    else:
        lines.append("- 本轮未发现明确需要单独列出的标题级误伤。")
    lines.append("")
    lines.append("## 后续扩展建议")
    lines.append("")
    lines.append("- 若要继续补全外部最新论文，可运行:")
    lines.append("")
    lines.append("```bash")
    lines.append(f"python3 scripts/arxiv_collector.py --query-id {config.arxiv_query_id} --days 30 --max 100 --no-save")
    lines.append("```")
    lines.append("")
    lines.append(f"- 建议外部检索关键词: {config.arxiv_keywords}。")
    lines.append(f"- 若要写本层 Related Work，{config.related_work_advice}")

    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path


def write_index(records: list[dict]) -> Path:
    path = LIT_DIR / "分层相关论文标题清单索引.md"
    orbit_csv = LIT_DIR / "轨道层相关论文标题清单.csv"
    orbit_count = 0
    if orbit_csv.exists():
        with orbit_csv.open(encoding="utf-8") as handle:
            orbit_count = max(sum(1 for _ in handle) - 1, 0)

    lines = [
        "# 分层相关论文标题清单索引",
        "",
        f"> 生成日期: {date.today().isoformat()}",
        "> 目标: 除轨道层外，为每个 SatelliteSimJulia 技术分层生成高置信论文标题清单，并给出外部补全命令与 Related Work 选文建议。",
        "",
        "## 总览",
        "",
        "| 层级 | 分层 | 模块 | 原始条数 | 高置信核心 | 邻接非核心 | 明显误伤 | Markdown | 核心 CSV | 全量状态 CSV | arXiv query |",
        "|---|---|---|---:|---:|---:|---:|---|---|---|---|",
        f"| 01 | 轨道传播层 | `src/orbit` | 207 | {orbit_count} | - | - | [轨道层相关论文标题清单.md](轨道层相关论文标题清单.md) | [轨道层相关论文标题清单.csv](轨道层相关论文标题清单.csv) | - | `01_orbit` |",
    ]
    for record in records:
        lines.append(
            f"| {record['section_id']} | {record['name']} | `{record['module']}` | {record['raw_count']} | "
            f"{record['core_count']} | {record['adjacent_count']} | {record['excluded_count']} | "
            f"[{record['md_name']}]({record['md_name']}) | [{record['csv_name']}]({record['csv_name']}) | "
            f"[{record['all_csv_name']}]({record['all_csv_name']}) | `{record['arxiv_query_id']}` |"
        )
    unique_core_titles = set()
    if orbit_csv.exists():
        with orbit_csv.open(encoding="utf-8") as handle:
            for row in csv.DictReader(handle):
                unique_core_titles.add(norm_title(row.get("title", "")))
    for record in records:
        with (LIT_DIR / record["csv_name"]).open(encoding="utf-8") as handle:
            for row in csv.DictReader(handle):
                unique_core_titles.add(norm_title(row.get("title", "")))
    total_core = orbit_count + sum(record["core_count"] for record in records)
    lines += [
        "",
        f"全分层高置信标题按层累计: **{total_core}** 条。",
        f"跨层去重后的高置信标题: **{len(unique_core_titles)}** 条。",
        "",
        "## 使用方式",
        "",
        "- 想看某一层的论文，直接打开对应 Markdown；想做程序化筛选，用核心 CSV。",
        "- 想全量审阅候选池，用对应 `_all.csv`，其中 `status=core|adjacent|excluded`。",
        "- 想补最新 arXiv，使用各层文档中的 `scripts/arxiv_collector.py --query-id ... --no-save` 命令先试跑，再人工合并。",
        "- 想写 Related Work，先从每层高置信清单中选 30-50 篇，再按该层子类各挑代表作。",
        "",
        "## 生成命令",
        "",
        "```bash",
        "python3 scripts/build_layer_literature_shortlists.py",
        "```",
    ]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path


def main() -> int:
    data = json.loads(DATA_PATH.read_text(encoding="utf-8"))
    bib_by_title = parse_bibtex_keys()
    source_by_title = flatten_source(data)
    records: list[dict] = []

    for config in LAYER_CONFIGS:
        raw_count = len(data["sections"][config.section_id])
        core, adjacent, excluded = classify_layer(config, data, source_by_title, bib_by_title)
        csv_path = write_csv(config, core)
        all_csv_path = write_all_csv(config, core, adjacent, excluded)
        md_path = write_markdown(config, core, adjacent, excluded, raw_count)
        records.append(
            {
                "section_id": config.section_id,
                "name": config.name,
                "module": config.module,
                "raw_count": raw_count,
                "core_count": len(core),
                "adjacent_count": len(adjacent),
                "excluded_count": len(excluded),
                "md_name": md_path.name,
                "csv_name": csv_path.name,
                "all_csv_name": all_csv_path.name,
                "arxiv_query_id": config.arxiv_query_id,
            }
        )
        print(
            f"{config.section_id} {config.name}: raw={raw_count} "
            f"core={len(core)} adjacent={len(adjacent)} excluded={len(excluded)}"
        )

    index_path = write_index(records)
    print(f"index={index_path.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
