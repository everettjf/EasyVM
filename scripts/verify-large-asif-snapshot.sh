#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"

swift test --package-path "$project_root" \
  --filter VMSnapshotManagerTests/testLargeSparseASIFSnapshotRestorePreservesLogicalCapacity

echo "Verified 64 GiB sparse ASIF snapshot, audit, restore, reopen, and logical-capacity preservation."
