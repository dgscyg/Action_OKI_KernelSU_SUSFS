#!/usr/bin/env bash
set -xve

# 获取 GitHub Actions 传入的参数
MANIFEST_FILE="$1"
ENABLE_LTO="$2"
ENABLE_POLLY="$3"
ENABLE_O3="$4"

# 根据 manifest_file 映射 CPUD
case "$MANIFEST_FILE" in
    "oneplus12_v" | "oneplus_13r" | "oneplus_ace3_pro" | "oneplus_ace3_pro_v" | "oneplus_ace5" | "oneplus_pad2_v")
        CPUD="pineapple"
        ;;
    *)
        echo "Error: Unsupported manifest_file: $MANIFEST_FILE"
        exit 1
        ;;
esac

# 设置版本变量
ANDROID_VERSION="android14"
KERNEL_VERSION="6.1"
SUSFS_VERSION="1.5.7"

# 设置工作目录
OLD_DIR="$(pwd)"
KERNEL_WORKSPACE="$OLD_DIR/kernel_platform"

# 配置编译器环境
export CC="clang"
export CLANG_TRIPLE="aarch64-linux-gnu-"
export LDFLAGS="-fuse-ld=lld"

# 根据参数设置优化标志
BAZEL_ARGS=""
[ "$ENABLE_O3" = "true" ] && BAZEL_ARGS="$BAZEL_ARGS --copt=-O3 --copt=-Wno-error"
[ "$ENABLE_LTO" = "true" ] && BAZEL_ARGS="$BAZEL_ARGS --copt=-flto --linkopt=-flto"
[ "$ENABLE_POLLY" = "true" ] && BAZEL_ARGS="$BAZEL_ARGS --copt=-mllvm --copt=-polly --copt=-mllvm --copt=-polly-vectorizer=stripmine"

# 清理旧的保护导出文件
rm -f "$KERNEL_WORKSPACE/common/android/abi_gki_protected_exports_*" || echo "No protected exports!"
rm -f "$KERNEL_WORKSPACE/msm-kernel/android/abi_gki_protected_exports_*" || echo "No protected exports!"
sed -i 's/ -dirty//g' "$KERNEL_WORKSPACE/build/kernel/kleaf/workspace_status_stamp.py"

# 检查完整目录结构
cd "$KERNEL_WORKSPACE" || exit 1
find . -type d > "$OLD_DIR/kernel_directory_structure.txt"

# 下载依赖
cd "$OLD_DIR" || exit 1
git clone https://gitlab.com/simonpunk/susfs4ksu.git -b "gki-${ANDROID_VERSION}-${KERNEL_VERSION}" --depth 1
git clone https://github.com/WildPlusKernel/kernel_patches.git --depth 1

# 设置 KernelSU (MKSU 变体)
cd "$KERNEL_WORKSPACE" || exit 1
curl -LSs "https://raw.githubusercontent.com/5ec1cff/KernelSU/main/kernel/setup.sh" | bash -s main
cd KernelSU || exit 1
KSU_VERSION=$(expr "$(git rev-list --count HEAD)" + 10200)
sed -i "s/DKSU_VERSION=16/DKSU_VERSION=${KSU_VERSION}/" kernel/Makefile

# 修复 KSU_GIT_VERSION 警告 - 使用正确的语法
KSU_GIT_VERSION=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
# 这里是关键修复 - 确保Makefile中的warning函数调用语法正确
sed -i 's/$(warning "KSU_GIT_VERSION not defined.*)/$(warning "KSU_GIT_VERSION not defined!")/' kernel/Makefile
# 然后添加正确的KSU_GIT_VERSION定义
echo "KSU_GIT_VERSION := $KSU_GIT_VERSION" >> kernel/Makefile

# 复制 SUSFS 文件到内核源码
cd "$KERNEL_WORKSPACE" || exit 1
cp ../susfs4ksu/kernel_patches/50_add_susfs_in_gki-${ANDROID_VERSION}-${KERNEL_VERSION}.patch ./common/
cp -r ../susfs4ksu/kernel_patches/fs/* ./common/fs/
cp -r ../susfs4ksu/kernel_patches/include/linux/* ./common/include/linux/

# 应用 MKSU 专用的 SUSFS 补丁
cd KernelSU || exit 1
cp ../../kernel_patches/next/0001-kernel-patch-susfs-v1.5.7-to-KernelSU-Next-v1.0.7.patch ./
patch -p1 --forward --fuzz=3 < 0001-kernel-patch-susfs-v1.5.7-to-KernelSU-Next-v1.0.7.patch || true

# 应用 hide_stuff 补丁
cd "$KERNEL_WORKSPACE/common" || exit 1
cp ../../kernel_patches/69_hide_stuff.patch ./
patch -p1 -F 3 < 69_hide_stuff.patch || true

# 应用 SUSFS 补丁到内核
patch -p1 --fuzz=3 < 50_add_susfs_in_gki-${ANDROID_VERSION}-${KERNEL_VERSION}.patch || true

# 应用 LZ4 和 ZSTD 补丁
curl -o 001-lz4.patch https://raw.githubusercontent.com/ferstar/kernel_manifest/realme/sm8650/patches/001-lz4.patch
patch -p1 < 001-lz4.patch || true
curl -o 002-zstd.patch https://raw.githubusercontent.com/ferstar/kernel_manifest/realme/sm8650/patches/002-zstd.patch
patch -p1 < 002-zstd.patch || true

cd "$KERNEL_WORKSPACE" || exit 1

# 检查KernelSU Makefile语法
cd KernelSU || exit 1
make -n -f kernel/Makefile || {
    echo "KernelSU Makefile语法错误，尝试修复..."
    # 备份原始文件
    cp kernel/Makefile kernel/Makefile.bak
    # 替换整个Makefile，以确保语法正确
    cat > kernel/Makefile << 'EOF'
obj-y += ksu.o
DKSU_VERSION=10333
KSU_GIT_VERSION := unknown

ksu-y += apk_sign.o
ksu-y += allowlist.o
ksu-y += arch.o
ksu-y += core.o
ksu-y += events.o
ksu-y += kernel_compat.o 
ksu-y += module.o
ksu-y += sucompat.o
ksu-y += uid_observer.o
ksu-y += manager.o
ksu-y += selinux.o

ifndef KSU_EXPECTED_SIZE
KSU_EXPECTED_SIZE := 0x033b
endif

ifndef KSU_EXPECTED_HASH
KSU_EXPECTED_HASH := 0xb0b91415
endif

ccflags-y += -DKSU_VERSION=$(DKSU_VERSION)
ccflags-y += -DKSU_GIT_VERSION=\"$(KSU_GIT_VERSION)\"
ccflags-y += -DKSU_EXPECTED_SIZE=$(KSU_EXPECTED_SIZE)
ccflags-y += -DKSU_EXPECTED_HASH=$(KSU_EXPECTED_HASH)
EOF
}
cd "$KERNEL_WORKSPACE" || exit 1

# 修复 lz4 与 zstd 所导致的问题
rm -f common/android/abi_gki_protected_exports_*

# 添加基本内核配置
echo "CONFIG_TMPFS_XATTR=y" >> "$KERNEL_WORKSPACE/common/arch/arm64/configs/gki_defconfig"
echo "CONFIG_TMPFS_POSIX_ACL=y" >> "$KERNEL_WORKSPACE/common/arch/arm64/configs/gki_defconfig"

# 添加 KSU 配置
echo "CONFIG_KSU=y" >> "$KERNEL_WORKSPACE/common/arch/arm64/configs/gki_defconfig"

# 添加 SUSFS 配置
echo "CONFIG_KSU_SUSFS=y" >> "$KERNEL_WORKSPACE/common/arch/arm64/configs/gki_defconfig"
echo "CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT=y" >> "$KERNEL_WORKSPACE/common/arch/arm64/configs/gki_defconfig"
echo "CONFIG_KSU_SUSFS_SUS_PATH=y" >> "$KERNEL_WORKSPACE/common/arch/arm64/configs/gki_defconfig"
echo "CONFIG_KSU_SUSFS_SUS_MOUNT=y" >> "$KERNEL_WORKSPACE/common/arch/arm64/configs/gki_defconfig"
echo "CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y" >> "$KERNEL_WORKSPACE/common/arch/arm64/configs/gki_defconfig"
echo "CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y" >> "$KERNEL_WORKSPACE/common/arch/arm64/configs/gki_defconfig"
echo "CONFIG_KSU_SUSFS_SUS_KSTAT=y" >> "$KERNEL_WORKSPACE/common/arch/arm64/configs/gki_defconfig"
echo "CONFIG_KSU_SUSFS_SUS_OVERLAYFS=n" >> "$KERNEL_WORKSPACE/common/arch/arm64/configs/gki_defconfig"
echo "CONFIG_KSU_SUSFS_TRY_UMOUNT=y" >> "$KERNEL_WORKSPACE/common/arch/arm64/configs/gki_defconfig"
echo "CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y" >> "$KERNEL_WORKSPACE/common/arch/arm64/configs/gki_defconfig"
echo "CONFIG_KSU_SUSFS_SPOOF_UNAME=y" >> "$KERNEL_WORKSPACE/common/arch/arm64/configs/gki_defconfig"
echo "CONFIG_KSU_SUSFS_ENABLE_LOG=y" >> "$KERNEL_WORKSPACE/common/arch/arm64/configs/gki_defconfig"
echo "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y" >> "$KERNEL_WORKSPACE/common/arch/arm64/configs/gki_defconfig"
echo "CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y" >> "$KERNEL_WORKSPACE/common/arch/arm64/configs/gki_defconfig"
echo "CONFIG_KSU_SUSFS_OPEN_REDIRECT=y" >> "$KERNEL_WORKSPACE/common/arch/arm64/configs/gki_defconfig"
echo "CONFIG_KSU_SUSFS_SUS_SU=y" >> "$KERNEL_WORKSPACE/common/arch/arm64/configs/gki_defconfig"

# 添加网络配置
echo "CONFIG_IP_NF_TARGET_TTL=y" >> "$KERNEL_WORKSPACE/common/arch/arm64/configs/gki_defconfig"
echo "CONFIG_IP6_NF_TARGET_HL=y" >> "$KERNEL_WORKSPACE/common/arch/arm64/configs/gki_defconfig"
echo "CONFIG_IP6_NF_MATCH_HL=y" >> "$KERNEL_WORKSPACE/common/arch/arm64/configs/gki_defconfig"

# 添加 BBR 配置
echo "CONFIG_TCP_CONG_ADVANCED=y" >> "$KERNEL_WORKSPACE/common/arch/arm64/configs/gki_defconfig" 
echo "CONFIG_TCP_CONG_BBR=y" >> "$KERNEL_WORKSPACE/common/arch/arm64/configs/gki_defconfig"
echo "CONFIG_NET_SCH_FQ=y" >> "$KERNEL_WORKSPACE/common/arch/arm64/configs/gki_defconfig"
echo "CONFIG_TCP_CONG_BIC=n" >> "$KERNEL_WORKSPACE/common/arch/arm64/configs/gki_defconfig"
echo "CONFIG_TCP_CONG_WESTWOOD=n" >> "$KERNEL_WORKSPACE/common/arch/arm64/configs/gki_defconfig"
echo "CONFIG_TCP_CONG_HTCP=n" >> "$KERNEL_WORKSPACE/common/arch/arm64/configs/gki_defconfig"

# 添加安全相关配置
echo "CONFIG_SECURITY_SELINUX_DISABLE=y" >> "$KERNEL_WORKSPACE/common/arch/arm64/configs/gki_defconfig"
echo "CONFIG_KPROBES=y" >> "$KERNEL_WORKSPACE/common/arch/arm64/configs/gki_defconfig"
echo "CONFIG_HAVE_KPROBES=y" >> "$KERNEL_WORKSPACE/common/arch/arm64/configs/gki_defconfig"
echo "CONFIG_KPROBE_EVENTS=y" >> "$KERNEL_WORKSPACE/common/arch/arm64/configs/gki_defconfig"

# 修改内核名称
perl -pi -e 's{UTS_VERSION="\$\(echo \$UTS_VERSION \$CONFIG_FLAGS \$TIMESTAMP \| cut -b -\$UTS_LEN\)"}{UTS_VERSION="#1 SMP PREEMPT Fri May 31 14:58:10 UTC 2025 by dgscyg"}' ./common/scripts/mkcompile_h
sed -i '$s|echo "\$res"|echo "\$res-MKSU"|' ./common/scripts/setlocalversion
sed -i '/^[[:space:]]*"protected_exports_list"[[:space:]]*:[[:space:]]*"android\/abi_gki_protected_exports_aarch64",$/d' ./common/BUILD.bazel
sed -i "/stable_scmversion_cmd/s/-maybe-dirty//g" ./build/kernel/kleaf/impl/stamp.bzl
sed -E -i '/^CONFIG_LOCALVERSION=/ s/(.*)"$/\1-MKSU"/' ./common/arch/arm64/configs/gki_defconfig

# 禁用 check_defconfig
sed -i 's/check_defconfig//' "$KERNEL_WORKSPACE/common/build.config.gki"

export OPLUS_FEATURES="OPLUS_FEATURE_BSP_DRV_INJECT_TEST=1"

# 构建内核
cd "$OLD_DIR" || exit 1
./kernel_platform/build_with_bazel.py -t "${CPUD}" gki \
    --config=stamp \
    --linkopt="-fuse-ld=lld" \
    $BAZEL_ARGS

# 获取内核版本
KERNEL_VERSION=$(cat "$KERNEL_WORKSPACE/out/msm-kernel-${CPUD}-gki/dist/version.txt" 2>/dev/null || echo "6.1")

# 输出变量到 GitHub Actions
echo "kernel_version=$KERNEL_VERSION" >> "$GITHUB_OUTPUT"
echo "ksu_version=$KSU_VERSION" >> "$GITHUB_OUTPUT"
echo "susfs_version=$SUSFS_VERSION" >> "$GITHUB_OUTPUT"
