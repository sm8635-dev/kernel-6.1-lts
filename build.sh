#!/usr/bin/env bash
# shellcheck disable=SC2199
# shellcheck source=/dev/null
#
# Copyright (C) 2020-22 UtsavBalar1231 <utsavbalar1231@gmail.com>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Clean function
clean_build() {
    echo "Cleaning previous build..."
    make clean && rm -rf out/
    rm -f *.zip build.log
}

# Set base directory - where you want everything saved
BASE_DIR="$HOME/kernel-builds"
mkdir -p "$BASE_DIR"

# Download and setup WeebX Clang
setup_weebx_clang() {
    local weebx_url="https://github.com/XSans0/WeebX-Clang/releases/download/WeebX-Clang-19.1.5-release/WeebX-Clang-19.1.5.tar.gz"
    local weebx_tarball="WeebX-Clang-19.1.5.tar.gz"
    local weebx_extracted="WeebX-Clang-19.1.5"
    local weebx_path="./$weebx_extracted"
    
    # Check if already extracted in current directory
    if [ -d "$weebx_path" ]; then
        echo "WeebX Clang already exists at: $weebx_path"
        if [ -f "$weebx_path/bin/clang" ]; then
            echo "$weebx_path/bin/clang"
            return 0
        fi
    fi
    
    # Download if not exists
    if [ ! -f "$weebx_tarball" ]; then
        echo "Downloading WeebX Clang..."
        wget -q --show-progress -O "$weebx_tarball" "$weebx_url"
        if [ $? -ne 0 ]; then
            echo "Failed to download WeebX Clang!"
            return 1
        fi
    fi
    
    # Extract
    echo "Extracting WeebX Clang..."
    tar -xf "$weebx_tarball"
    if [ $? -ne 0 ]; then
        echo "Failed to extract WeebX Clang!"
        return 1
    fi
    
    # Verify extraction
    if [ -f "$weebx_path/bin/clang" ]; then
        echo "WeebX Clang setup completed successfully!"
        echo "$weebx_path/bin/clang"
        return 0
    else
        echo "WeebX Clang extraction failed - clang binary not found!"
        return 1
    fi
}

# Find LLD in WeebX Clang directory
find_lld() {
    local clang_path="$1"
    local clang_dir=$(dirname "$(dirname "$clang_path")")
    
    # Look for ld.lld in the same directory as clang
    local lld_path="$clang_dir/bin/ld.lld"
    if [ -f "$lld_path" ] && [ -x "$lld_path" ]; then
        echo "$lld_path"
        echo "Found LLD at: $lld_path"
        return 0
    else
        echo "Error: LLD not found in WeebX Clang directory!"
        return 1
    fi
}

# Setup WeebX Clang toolchain
echo "Setting up WeebX Clang toolchain..."
CLANG_PATH=$(setup_weebx_clang)
if [ $? -ne 0 ] || [ ! -f "$CLANG_PATH" ]; then
    echo "Error: Failed to setup WeebX Clang!"
    exit 1
fi

LLD_PATH=$(find_lld "$CLANG_PATH")
if [ $? -ne 0 ] || [ ! -f "$LLD_PATH" ]; then
    echo "Error: Failed to find LLD in WeebX Clang!"
    exit 1
fi

# Get compiler versions
echo "Getting compiler versions..."
KBUILD_COMPILER_STRING=$("$CLANG_PATH" --version | head -n 1 | perl -pe 's/\(http.*?\)//gs' | sed -e 's/  */ /g' -e 's/[[:space:]]*$//')
KBUILD_LINKER_STRING=$("$LLD_PATH" --version | head -n 1 | perl -pe 's/\(http.*?\)//gs' | sed -e 's/  */ /g' -e 's/[[:space:]]*$//' | sed 's/(compatible with [^)]*)//')
export KBUILD_COMPILER_STRING
export KBUILD_LINKER_STRING

# Bypass warnings treated as errors
export KCFLAGS="-Wno-error"
echo "Bypassing -Werror: Warnings will not stop the build."

#
# Environmental Variables
#

DATE=$(date '+%Y%m%d-%H%M')

# Set our directory
OUT_DIR=out/

VERSION="6.1-Lts-Peridot-${DATE}"

# How much kebabs we need? Kanged from @raphielscape :)
if [[ -z "${KEBABS}" ]]; then
    COUNT="$(grep -c '^processor' /proc/cpuinfo)"
    export KEBABS="$COUNT"
fi

echo "Jobs: ${KEBABS}"
echo "Using Clang: $CLANG_PATH"
echo "Using LLD: $LLD_PATH"
echo "Build files will be saved in: $BASE_DIR"

ARGS="ARCH=arm64 \
O=${OUT_DIR} \
CC=$CLANG_PATH \
LD=$LLD_PATH \
CLANG_TRIPLE=aarch64-linux-gnu- \
CROSS_COMPILE=aarch64-linux-gnu- \
CROSS_COMPILE_COMPAT=arm-linux-gnueabi- \
-j${KEBABS}"

dts_source=arch/arm64/boot/dts/vendor/qcom

START=$(date +"%s")

# Clean before building
clean_build

# Set compiler Path - use the directory containing the compilers
COMPILER_DIR=$(dirname "$CLANG_PATH")
export PATH="$COMPILER_DIR:$PATH"
export LD_LIBRARY_PATH=$(dirname "$COMPILER_DIR")/lib:$LD_LIBRARY_PATH

echo "------ Starting Compilation ------"

# Make defconfig
make -j${KEBABS} ${ARGS} peridot_defconfig

# Make olddefconfig
cd ${OUT_DIR}
make -j${KEBABS} ${ARGS} CC="ccache $CLANG_PATH" HOSTCC="ccache gcc" HOSTCXX="ccache g++" olddefconfig
cd ../

make -j${KEBABS} ${ARGS} CC="ccache $CLANG_PATH" HOSTCC="ccache gcc" HOSTCXX="ccache g++" 2>&1 | tee build.log

echo "------ Finishing Build ------"

END=$(date +"%s")
DIFF=$((END - START))
if [ -f "out/arch/arm64/boot/Image" ]; then
        echo "Cloning AnyKernel3..."
        git clone https://github.com/sm8635-dev/AnyKernel3.git -b master ak3

        echo "Copying kernel image..."
        cp out/arch/arm64/boot/Image.gz ak3/

        echo "Creating flashable ZIP..."
        cd ak3
        # Create ZIP with proper extension
        zip -r9 "../${VERSION}.zip" * -x '*.git*' README.md *placeholder >> /dev/null
        cd ..

        echo "Organizing build files..."
        # Move ZIP to organized location
        mv "${VERSION}.zip" "$BASE_DIR/"

        # Copy build log
        cp build.log "$BASE_DIR/build-${DATE}.log"

        # Keep ak3 directory but move it to organized location
        mv ak3 "$BASE_DIR/ak3-${DATE}"

        echo -e "\nCompleted in $((SECONDS / 60)) minute(s) and $((SECONDS % 60)) second(s) !"
        echo ""
        echo -e "=== BUILD FILES SAVED IN: $BASE_DIR ==="
        echo -e "Flashable ZIP: ${VERSION}.zip"
        echo -e "AK3 directory: ak3-${DATE}/"
        echo -e "Build log: build-${DATE}.log"
        echo ""

        # List the created files
        echo "Created files:"
        ls -la "$BASE_DIR/${VERSION}.zip"
        ls -la "$BASE_DIR/ak3-${DATE}/"
        ls -la "$BASE_DIR/build-${DATE}.log"
else
        echo -e "\n Compilation Failed!"
        # Save the failed build log anyway
        cp build.log "$BASE_DIR/build-FAILED-${DATE}.log"
        echo "Error log saved to: $BASE_DIR/build-FAILED-${DATE}.log"
fi
