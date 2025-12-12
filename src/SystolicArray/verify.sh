#!/bin/bash

# 1. Check if user provided at least 2 arguments
if [ -z "$1" ] || [ -z "$2" ]; then 
  echo "Usage: ./scripts/verify.sh <type> <testbench_file>"
  echo "Example: ./scripts/verify.sh sequential dot_product_tb.v"
  exit 1
fi

# 2. Define the specific implementation file
IMPL="src/dot_product_$1.v"
TB="src/$2"

# 3. Check if the implementation exists
if [ ! -f "$IMPL" ]; then 
  echo "Error: Could not find Implementation: $IMPL"
  exit 1
fi

# 4. Check if the testbench exists
if [ ! -f "$TB" ]; then 
  echo "Error: Could not find Testbench: $TB"
  exit 1
fi

# 5. Define output paths
BIN_DIR="outputs/bin"
WAVES_DIR="outputs/waves"

# Create directories if they don't exist
mkdir -p "$BIN_DIR"
mkdir -p "$WAVES_DIR"

# Construct dynamic output filename
TB_BASENAME=$(basename "$2" .v)
OUT_EXE="${BIN_DIR}/${1}_${TB_BASENAME}.out"

# 6. Compile ONLY the chosen implementation + SPECIFIC testbench
echo "----------------------------------------"
echo "Compiling: $1 implementation + $2"
echo "Output: $OUT_EXE"
echo "----------------------------------------"

iverilog -g2012 -o "$OUT_EXE" "$IMPL" "$TB"

# 7. Run the simulation if compilation succeeded
if [ $? -eq 0 ]; then
    echo "Running Simulation..."
    vvp "$OUT_EXE"
    
    # Move any generated VCD files to the waves folder
    if ls *.vcd 1> /dev/null 2>&1; then
        mv *.vcd "$WAVES_DIR/" 2>/dev/null
        echo "Waveforms moved to $WAVES_DIR/"
    else
        echo "Simulation ran, but no VCD file was found in root."
    fi
else
    echo "Compilation Failed!"
    exit 1
fi