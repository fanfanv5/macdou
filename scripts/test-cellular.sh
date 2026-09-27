#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p .build/checks/cellular
LIBUSB_PREFIX="${LIBUSB_PREFIX:-/opt/homebrew/opt/libusb}"
clang -std=c11 -O2 -Wall -Wextra -Wno-unused-parameter \
  -I "$LIBUSB_PREFIX/include/libusb-1.0" Tests/Cellular/ModemFeatureTests.c \
  -L "$LIBUSB_PREFIX/lib" -lusb-1.0 -o .build/checks/cellular/modem-tests
.build/checks/cellular/modem-tests
swiftc Sources/MacDou/Cellular/SMSDecoder.swift Tests/Cellular/SMSDecoderTests.swift \
  -o .build/checks/cellular/sms-tests
.build/checks/cellular/sms-tests Tests/Cellular/sms-fixtures.json
swiftc Sources/MacDou/Cellular/ModemClient.swift Tests/Cellular/CommandRunnerTests.swift \
  -o .build/checks/cellular/command-tests
.build/checks/cellular/command-tests
swiftc Sources/MacDou/Cellular/NetworkSampler.swift Tests/Cellular/NetworkSamplerTests.swift \
  -framework SystemConfiguration -o .build/checks/cellular/network-tests
.build/checks/cellular/network-tests
swiftc -parse-as-library -swift-version 5 \
  Sources/MacDou/Cellular/AppBranding.swift Sources/MacDou/Cellular/GuardModel.swift \
  Sources/MacDou/Cellular/ModemClient.swift Sources/MacDou/Cellular/NetworkSampler.swift \
  Sources/MacDou/Cellular/SMSDecoder.swift Sources/MacDou/Cellular/ModuleFeaturesWindow.swift \
  Tests/Cellular/ModuleFeaturesTests.swift -o .build/checks/cellular/features-tests \
  -framework AppKit -framework Combine -framework SystemConfiguration -framework ServiceManagement
.build/checks/cellular/features-tests .build/checks/cellular
printf 'All offline cellular checks passed.\n'
