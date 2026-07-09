#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SatelliteSimJulia 论文知识库维护 Agent 入口。"""

from __future__ import annotations

import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]
PACKAGE_ROOT = PROJECT_ROOT / "tools" / "paper_agent"
if str(PACKAGE_ROOT) not in sys.path:
    sys.path.insert(0, str(PACKAGE_ROOT))

from paper_agent.cli import main


if __name__ == "__main__":
    raise SystemExit(main())
