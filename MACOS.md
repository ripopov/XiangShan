# XiangShan on macOS (Apple Silicon): deps for `make verilog`

This guide lists the dependencies you need on Apple Silicon macOS so `make verilog` works.

## 1) Required dependencies

Install these first:

1. Xcode Command Line Tools (provides `git`, `make`, compiler toolchain).
2. Homebrew.
3. JDK 11.
4. Mill `0.12.15` (must match `.mill-version` in this repo).
5. GNU `time` (`gtime`) (required because BSD `time` on macOS does not support `-avp`).

## 2) Install commands

```bash
# Xcode CLI tools
xcode-select --install

# Homebrew (if not installed)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Core packages
brew install openjdk@11 gnu-time curl

# Configure Java 11 for shells and tools
echo 'export PATH="/opt/homebrew/opt/openjdk@11/bin:$PATH"' >> ~/.zshrc
echo 'export JAVA_HOME="$(/usr/libexec/java_home -v 11)"' >> ~/.zshrc

# Install mill 0.12.15 to ~/.local/bin
mkdir -p ~/.local/bin
curl -L https://repo1.maven.org/maven2/com/lihaoyi/mill-dist/0.12.15/mill-dist-0.12.15-mill.sh \
  -o ~/.local/bin/mill
chmod +x ~/.local/bin/mill
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc

```

Reload shell config:

```bash
source ~/.zshrc
```

## 3) Initialize repo and generate Verilog

From the XiangShan repo root:

```bash
make init
make verilog CONFIG=TLConfig
```

Generated RTL will be under `build/rtl/` (for example `build/rtl/XSTop.sv`).

## 4) Quick checks

```bash
java --version          # should show JDK 11
mill -i --version       # should show 0.12.15
gtime -avp true         # should work
```

## Notes

- `make verilog` does not require Verilator.
- First run downloads Scala/Chisel/firtool dependencies from the network, so internet access is required.
- If your machine has less memory, lower JVM heap, e.g.:
  - `make verilog JVM_XMX=16G`

## Troubleshooting

- Error: `Unsupported class file major version 69`
  - Cause: `mill` is running on Java 25 (class major 69), which is too new for this toolchain.
  - Fix (one-shot for current shell):
    - `export JAVA_HOME=/opt/homebrew/opt/openjdk@11/libexec/openjdk.jdk/Contents/Home`
    - `export PATH="$JAVA_HOME/bin:$PATH"`
    - `java --version`
    - `make verilog CONFIG=TLConfig`
