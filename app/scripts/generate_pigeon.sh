#!/usr/bin/env bash
# LIFECYCLE: permanent
set -euo pipefail
cd "$(dirname "$0")/.."
flutter pub run pigeon --input lib/pigeon_interfaces.dart
# Pigeon's Kotlin emitter leaves spaces after handler braces.
python3 - <<'PYTHON'
from pathlib import Path
path = Path('android/app/src/main/kotlin/com/friend/ios/PigeonCommunicator.g.kt')
path.write_text('\n'.join(line.rstrip() for line in path.read_text().splitlines()) + '\n')
PYTHON
