#!/usr/bin/env bash

# Source this file from the XiangShan repo root:
#   source ./setvars_osx.sh

_this_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export NOOP_HOME="${NOOP_HOME:-$_this_dir}"
export JAVA_HOME="/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home"

# Prefer native macOS espresso if it exists.
if [ -x /tmp/espresso-logic-macos/bin/espresso ]; then
  export PATH="/tmp/espresso-logic-macos/bin:$JAVA_HOME/bin:$PATH"
else
  export PATH="$JAVA_HOME/bin:$PATH"
fi

echo "NOOP_HOME=$NOOP_HOME"
echo "JAVA_HOME=$JAVA_HOME"
echo "espresso=$(command -v espresso || echo 'not found')"
java --version
