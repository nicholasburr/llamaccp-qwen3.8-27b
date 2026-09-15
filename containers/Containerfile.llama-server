# Global Arguments
ARG FEDORA_VERSION=44
ARG ROCM_VERSION=10.0.0
ARG REPO=https://github.com/ggml-org/llama.cpp.git
# Pinned to the llama.cpp git TAG inside the current image (see TAGS:
# v0.4.1 -> tag v0.4.1-rocm-10.0.0). `make build` always passes TAG
# explicitly; this default keeps manual `podman build` reproducible too.
# Bump via `make new-build TAG=<v-or-b-tag>`.
# TAG is a llama.cpp release tag (vX.Y.Z) or a nightly tag (bXXXXX); it is
# checked out after clone (all refs are fetched first, so a tag is always
# resolvable — unlike `clone -b <sha>`, which treats the ref as a branch).
ARG TAG=v0.4.1
# The GPU target is hardcoded to gfx1151 (AMD Strix Halo / Ryzen AI Max+ 395) —
# this repository builds ONLY for gfx1151, so it is not a build arg.
# AMD's ROCm pip-wheel index (PEP 503). ROCm is installed with pip instead of
# the repo.radeon.com RPMs — see https://rocm.docs.amd.com (Install > pip).
ARG ROCM_PIP_INDEX=https://stable.repo.amd.com/rocm/whl-next/

# --- BUILDER STAGE ---
FROM registry.fedoraproject.org/fedora:${FEDORA_VERSION} AS builder
ARG REPO
ARG TAG
ARG ROCM_VERSION
ARG ROCM_PIP_INDEX

# Build dependencies. NOTE: no ROCm RPMs anymore — the ROCm toolchain arrives
# as pip wheels (rocm-sdk-*) below. gcc/g++ compile the host C/C++ side; the
# wheel's clang/hipcc compiles the HIP side (same split as the old RPM build).
RUN dnf -y --nodocs --setopt=install_weak_deps=False \
    install \
    make gcc gcc-c++ cmake lld ninja-build libcurl-devel \
    git-core python3 python3-pip \
    && dnf clean all && rm -rf /var/cache/dnf/*

# Install ROCm ${ROCM_VERSION} with pip, per AMD's pip install instructions
# (https://rocm.docs.amd.com — "Install ROCm wheel packages"), which for
# Ryzen gfx1151 / Python 3.14 are:
#
#   python -m pip install --index-url https://stable.repo.amd.com/rocm/whl-next/ \
#       "rocm[libraries,device-gfx1151]==10.0.0"
#
# We add the `devel` extra on top of the docs' `libraries,device-<gfx>` set
# because llama.cpp is compiled from source here: devel carries the HIP
# compiler, CMake configs, headers and static libraries.
RUN python3 -m venv /opt/rocm-venv && \
    /opt/rocm-venv/bin/pip install --no-cache-dir \
        --index-url ${ROCM_PIP_INDEX} \
        "rocm[libraries,devel,device-gfx1151]==${ROCM_VERSION}"

# The wheels unpack a classic /opt/rocm-style tree under the venv
# (lib64 on Fedora):
#   site-packages/_rocm_sdk_devel      SDK root: bin/, include/, lib/, lib/llvm/, lib/cmake/
#   site-packages/_rocm_sdk_core       runtime libraries (HIP, HSA, comgr, SMI, ...)
#   site-packages/_rocm_sdk_libraries  rocBLAS/hipBLAS/... + <gfx> prebuilt kernels
# `rocm-sdk path --root` lazily expands the devel payload on first use and
# prints the SDK root; remember it in a file + a sourceable env file.
RUN /opt/rocm-venv/bin/rocm-sdk path --root > /opt/.rocm-dev-root && \
    DEV=$(cat /opt/.rocm-dev-root) && \
    printf '%s\n' \
        "export ROCM_DEV_ROOT=${DEV}" \
        "export PATH=${DEV}/bin:${DEV}/lib/llvm/bin:\$PATH" \
        "export HIP_PATH=${DEV}" \
        "export ROCM_PATH=${DEV}" \
        "export HIP_CLANG_PATH=${DEV}/lib/llvm/bin" \
        "export HIP_DEVICE_LIB_PATH=${DEV}/lib/llvm/amdgcn/bitcode" \
        > /opt/rocm-env.sh

WORKDIR /opt/llama.cpp
RUN git clone --recursive ${REPO} . && \
    git checkout --detach ${TAG} && \
    git clean -xdf && git submodule update --recursive

# Build llama.cpp against the pip-installed ROCm (same flags as the old
# RPM-based build, pointed at the wheel's SDK root).
#
# Options at the pinned release (v0.4.1):
#   - LLAMA_BUILD_SERVER=ON gates tools/server (+ cli + ui); llama-server,
#     llama and llama-bench all live in tools/, so LLAMA_BUILD_EXAMPLES=OFF.
#   - GGML_HIP_GRAPHS is ON by default; set explicitly (iGPU launch overhead).
#   - No build flag exists or is needed for MTP speculative decoding: the
#     model file ships the MTP head and it is enabled at runtime
#     (LLAMA_ARG_SPEC_TYPE=draft-mtp in podman-compose.yml).
RUN . /opt/rocm-env.sh && \
    cmake -S . -B build -G Ninja \
    -DCMAKE_HIP_ARCHITECTURES=gfx1151 \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_BUILD_TESTS=OFF \
    -DGGML_HIP=1 \
    -DGGML_HIP_GRAPHS=ON \
    -DHIP_PATH=${ROCM_DEV_ROOT} \
    -DHIP_PLATFORM=amd \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_SERVER=ON \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DROCM_PATH=${ROCM_DEV_ROOT} \
    && cmake --build build --config Release -- -j$(nproc) \
    && cmake --install build --config Release

# Consolidate a slim runtime ROCm tree into /opt/rocm-rt (the runtime stage
# copies it to /opt/rocm-${ROCM_VERSION}/):
#   - core runtime libs, minus the bundled LLVM toolchain and static libs
#     (not needed at runtime — saves most of the wheel's bulk)
#   - rocBLAS / hipBLAS / hipBLASLt + their gfx1151 prebuilt kernels
#   - amdgpu.ids (GPU identification; the old image took it from the libdrm RPM)
RUN <<EOF
set -e
DEV=$(cat /opt/.rocm-dev-root)
SITE=$(dirname "$DEV")
CORE=${SITE}/_rocm_sdk_core
LIBS=${SITE}/_rocm_sdk_libraries

mkdir -p /opt/rocm-rt/lib /opt/rocm-rt/share/libdrm
tar -C ${CORE}/lib --exclude=llvm --exclude='*.a' -cf - . | tar -C /opt/rocm-rt/lib -xf -
for p in librocblas libhipblas libhipblaslt librocsolver liborigami librocroller; do
    cp -aP ${LIBS}/lib/${p}.so* /opt/rocm-rt/lib/
done
# rocroller/origami (rocBLAS 10 backends) link against the SDK's bundled LLVM/Clang runtime
cp -aP ${CORE}/lib/llvm/lib/libLLVM.so.* /opt/rocm-rt/lib/
cp -aP ${CORE}/lib/llvm/lib/libclang-cpp.so.* /opt/rocm-rt/lib/
cp -aP ${LIBS}/lib/rocblas      /opt/rocm-rt/lib/
cp -aP ${LIBS}/lib/hipblaslt    /opt/rocm-rt/lib/
cp -a ${CORE}/lib/rocm_sysdeps/share/libdrm/amdgpu.ids /opt/rocm-rt/share/libdrm/
ldconfig
EOF
 
# --- RUNTIME STAGE ---
FROM registry.fedoraproject.org/fedora-minimal:${FEDORA_VERSION}
ARG ROCM_VERSION

# Install runtime dependencies (libdrm: pulled in by ROCm runtime libs; the
# old image got it indirectly from the builder's ROCm RPMs)
RUN microdnf -y install bash ca-certificates libstdc++ libgomp libdrm procps-ng curl && \
    microdnf clean all

# Copy artifacts
COPY --from=builder /opt/rocm-rt/ /opt/rocm-${ROCM_VERSION}/
# amdgpu.ids at the classic system path (fallback the HIP runtime searches)
COPY --from=builder /opt/rocm-rt/share/libdrm/amdgpu.ids /usr/share/libdrm/amdgpu.ids
# llama.cpp shared libraries (cmake --install stage dir)
COPY --from=builder /usr/local/lib64/ /usr/local/lib64/
COPY --from=builder /opt/llama.cpp/build/bin/llama /usr/local/bin/
COPY --from=builder /opt/llama.cpp/build/bin/llama-server /usr/local/bin/
COPY --from=builder /opt/llama.cpp/build/bin/llama-bench /usr/local/bin/

# Linker Configuration
RUN <<EOF
cat <<CONFIG > /etc/ld.so.conf.d/rocm.conf
/opt/rocm-${ROCM_VERSION}/lib
/usr/local/lib64
CONFIG
ldconfig
EOF

# Environment for Strix Halo (gfx1151)
ENV PATH="/usr/local/bin:/opt/rocm-${ROCM_VERSION}/bin:$PATH" \
    LD_LIBRARY_PATH="/opt/rocm-${ROCM_VERSION}/lib:$LD_LIBRARY_PATH" \
    HIP_VISIBLE_DEVICES=0

HEALTHCHECK CMD [ "curl", "-f", "http://localhost:8000/health" ]

ENTRYPOINT ["/usr/local/bin/llama-server"]
