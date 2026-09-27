#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p .build/checks
swiftc -swift-version 5 -parse-as-library -module-name MacDouChecks \
    Sources/MacDou/StatusModels.swift \
    Sources/MacDou/Preferences.swift \
    Sources/MacDou/RingRenderer.swift \
    Tests/MacDouTests/StatusTests.swift \
    scripts/RegressionRunner.swift \
    -o .build/checks/MacDouChecks
.build/checks/MacDouChecks
