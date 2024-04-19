ARG DRIVER_TOOLKIT_IMAGE=''

FROM ${DRIVER_TOOLKIT_IMAGE} as builder

ARG BASE_URL='https://us.download.nvidia.com/tesla'

ARG CENTOS_VERSION=''
ARG CENTOS_VERSION_MAJOR=''
ARG KERNEL_VERSION=''

ARG BUILD_ARCH=''
ARG TARGET_ARCH=''

ARG DRIVER_VERSION=''

ARG BUILDER_USER=''
ARG BUILDER_EMAIL=''

USER builder

WORKDIR /home/builder
COPY --chown=1001:0 x509-configuration.ini x509-configuration.ini

RUN export KVER=$(echo ${KERNEL_VERSION} | cut -d '-' -f 1) \
        KREL=$(echo ${KERNEL_VERSION} | cut -d '-' -f 2 | sed 's/\.el._*.*\..\+$//') \
        KDIST=$(echo ${KERNEL_VERSION} | cut -d '-' -f 2 | sed 's/^.*\(\.el._*.*\)\..\+$/\1/') \
        DRIVER_STREAM=$(echo ${DRIVER_VERSION} | cut -d '.' -f 1) \
    && git clone --depth 1 --single-branch -b rhel${CENTOS_VERSION_MAJOR} https://github.com/NVIDIA/yum-packaging-precompiled-kmod \
    && cd yum-packaging-precompiled-kmod \
    && mkdir BUILD BUILDROOT RPMS SRPMS SOURCES SPECS \
    && mkdir nvidia-kmod-${DRIVER_VERSION}-${BUILD_ARCH} \
    && curl -sLOf ${BASE_URL}/${DRIVER_VERSION}/NVIDIA-Linux-${TARGET_ARCH}-${DRIVER_VERSION}.run \
    && sh ./NVIDIA-Linux-${TARGET_ARCH}-${DRIVER_VERSION}.run --extract-only --target tmp \
    && mv tmp/kernel-open nvidia-kmod-${DRIVER_VERSION}-${BUILD_ARCH}/kernel \
    && tar -cJf SOURCES/nvidia-kmod-${DRIVER_VERSION}-${BUILD_ARCH}.tar.xz nvidia-kmod-${DRIVER_VERSION}-${BUILD_ARCH} \
    && mv kmod-nvidia.spec SPECS/ \
    && sed -i -e "s/\$USER/${BUILDER_USER}/" -e "s/\$EMAIL/${BUILDER_EMAIL}/" ${HOME}/x509-configuration.ini \
    && openssl req -x509 -new -nodes -utf8 -sha256 -days 36500 -batch \
      -config ${HOME}/x509-configuration.ini \
      -outform DER -out SOURCES/public_key.der \
      -keyout SOURCES/private_key.priv \
    && rpmbuild \
        --define "% _arch ${BUILD_ARCH}" \
        --define "%_topdir $(pwd)" \
        --define "debug_package %{nil}" \
        --define "kernel ${KVER}" \
        --define "kernel_release ${KREL}" \
        --define "kernel_dist ${KDIST}" \
        --define "driver ${DRIVER_VERSION}" \
        --define "driver_branch ${DRIVER_STREAM}" \
        -v -bb SPECS/kmod-nvidia.spec

FROM quay.io/centos-bootc/centos-bootc:stream9

ARG BUILD_DATE=''
ARG BASE_IMAGE_DIGEST=''

ARG BASE_URL='https://us.download.nvidia.com/tesla'

ARG CENTOS_VERSION=''
ARG CENTOS_VERSION_MAJOR=''
ARG KERNEL_VERSION=''

ARG DRIVER_VERSION=''
ENV DRIVER_VERSION=${DRIVER_VERSION}

ARG DRIVER_TYPE=passthrough
ENV DRIVER_TYPE=${DRIVER_TYPE}

ARG CUDA_VERSION=''

ARG BUILD_ARCH=''
ARG TARGET_ARCH=''
ENV TARGETARCH=${TARGET_ARCH}

# Disable vGPU version compability check by default
ARG DISABLE_VGPU_VERSION_CHECK=true
ENV DISABLE_VGPU_VERSION_CHECK=$DISABLE_VGPU_VERSION_CHECK

USER root

COPY --from=builder /home/builder/yum-packaging-precompiled-kmod/RPMS/${TARGET_ARCH}/*.rpm /rpms/
COPY --from=builder --chmod=444 /home/builder/yum-packaging-precompiled-kmod/tmp/firmware/*.bin /lib/firmware/nvidia/${DRIVER_VERSION}/

RUN dnf install -y /rpms/kmod-nvidia-*.rpm

COPY usr/lib/systemd/system/nvidia-toolkit-firstboot.service /usr/lib/systemd/system/nvidia-toolkit-firstboot.service

RUN export DRIVER_STREAM=$(echo ${DRIVER_VERSION} | cut -d '.' -f 1) \
        CUDA_VERSION_ARRAY=(${CUDA_VERSION//./ }) \
        CUDA_DASHED_VERSION=${CUDA_VERSION_ARRAY[0]}-${CUDA_VERSION_ARRAY[1]} \
        CUDA_REPO_ARCH=${TARGET_ARCH} \
    && if [ "${TARGET_ARCH}" == "aarch64" ]; then CUDA_REPO_ARCH="sbsa"; fi \
    && dnf config-manager --best --nodocs --setopt=install_weak_deps=False --save \
    && dnf config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/rhel${CENTOS_VERSION_MAJOR}/${CUDA_REPO_ARCH}/cuda-rhel${CENTOS_VERSION_MAJOR}.repo \
    && dnf -y module enable nvidia-driver:${DRIVER_STREAM}/default \
    && dnf install -y \
        nvidia-driver-cuda-${DRIVER_VERSION} \
        nvidia-driver-libs-${DRIVER_VERSION} \
        nvidia-driver-NVML-${DRIVER_VERSION} \
        cuda-compat-${CUDA_DASHED_VERSION} \
        cuda-cudart-${CUDA_DASHED_VERSION} \
        nvidia-persistenced-${DRIVER_VERSION} \
        nvidia-container-toolkit \
    && if [ "$DRIVER_TYPE" != "vgpu" ] && [ "$TARGETARCH" != "arm64" ]; then \
        versionArray=(${DRIVER_VERSION//./ }); \
        DRIVER_BRANCH=${versionArray[0]}; \
        dnf module enable -y nvidia-driver:${DRIVER_BRANCH} && \
        dnf install -y nvidia-fabric-manager-${DRIVER_VERSION} libnvidia-nscq-${DRIVER_BRANCH}-${DRIVER_VERSION} ; \
    fi \
    && dnf clean all \
    && ln -s /usr/lib/systemd/system/nvidia-toolkit-firstboot.service /usr/lib/systemd/system/basic.target.wants/nvidia-toolkit-firstboot.service \
    && echo "blacklist nouveau" > /etc/modprobe.d/blacklist_nouveau.conf

LABEL org.opencontainers.image.base.digest="${BASE_IMAGE_DIGEST}"
LABEL org.opencontainers.image.base.name="quay.io/centos-bootc/centos-bootc:${CENTOS_VERSION}"
LABEL org.opencontainers.image.created="${BUILD_DATE}"
LABEL org.opencontainers.image.description="Image-based CentOS Stream ${CENTOS_VERSION_MAJOR} with NVIDIA drivers"
LABEL org.opencontainers.image.source="https://gitlab.cee.redhat.com/magma/rhel-bootc-nvidia.git"
LABEL org.opencontainers.image.title="Image-based CentOS Stream ${CENTOS_VERSION_MAJOR} with NVIDIA drivers"
LABEL org.opencontainers.image.version="${CENTOS_VERSION}-${DRIVER_VERSION}-${BUILD_DATE}"
LABEL name="Image-based CentOS Stream ${CENTOS_VERSION_MAJOR} with NVIDIA drivers"
LABEL vendor="Red Hat - Magma Project"
LABEL version="${CENTOS_VERSION}-${DRIVER_VERSION}-${BUILD_DATE}"
LABEL description="Provision image-based CentOS Stream ${CENTOS_VERSION_MAJOR} with NVIDIA drivers"

CMD ["/usr/bin/bash"]
