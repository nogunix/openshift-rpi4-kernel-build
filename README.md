# openshift-rpi4-kernel-build

Build a Raspberry Pi 4 kernel on OpenShift using a reproducible, containerized cross-compilation environment.  
Artifacts and ccache are persisted in PVCs for reuse across runs.

## Overview
- Provides a Fedora-based build container and OpenShift Job manifests.
- `scripts/build.sh` fetches sources, builds the kernel, and installs modules.
- Outputs go to the `out` PVC and cache to the `ccache` PVC.

## Target Architecture
- arm64 (AArch64)
- Raspberry Pi 4 / BCM2711
- Default defconfig: `bcm2711_defconfig`

## Why OpenShift
- Reproducible build environment with pinned dependencies.
- Explicit resource requests/limits for predictable execution.
- Persistent volumes for artifacts and cache.

## Design
- `container/Containerfile` installs the cross toolchain and build deps.
- OpenShift-friendly non-root execution (random UID compatible).
- Uses `/work/src`, `/work/out`, `/work/ccache` inside the container.

## Build Flow
1. Fetch kernel sources (`KERNEL_REPO` and `KERNEL_REF`).
2. Generate config with `make <DEFCONFIG>`.
3. Build `Image`, `modules`, and `dtbs`.
4. Install modules into `OUT_DIR/mods`.

## Security Considerations
- `seccompProfile: RuntimeDefault`
- `runAsNonRoot: true`
- `allowPrivilegeEscalation: false`
- `capabilities: drop ["ALL"]`

## Performance / Cache
- `ccache` is persisted via PVC to speed up rebuilds.
- Tune parallelism with `JOBS`.

## How to Run
Example workflow. Adjust names and registry as needed.

1) Build and push the image
```bash
podman build -f container/Containerfile -t openshift-rpi4-kernel-build:latest .
# Push to your registry or the OpenShift internal registry
```

2) Create namespace and PVCs
```bash
oc apply -f manifests/namespace.yaml
oc apply -f manifests/pvc-ccache.yaml
oc apply -f manifests/pvc-out.yaml
```

3) Run the Job
```bash
oc apply -f manifests/job-build.yaml
```

4) Retrieve artifacts
- The output directory is mounted at `/work/out`.
- Mount the `out` PVC in another Pod or use `oc cp`.
