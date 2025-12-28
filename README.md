# openshift-rpi4-kernel-build

Build a Raspberry Pi 4 kernel on OpenShift using a reproducible, containerized cross-compilation environment.  
Artifacts and ccache are persisted in PVCs for reuse across runs.

## Overview
- Provides a Fedora-based build container and OpenShift Job manifests.
- `scripts/build.sh` fetches sources, builds the kernel, and installs modules (default: Linus mainline).
- Outputs go to the `out` PVC and cache to the `ccache` PVC.

## Target Architecture
- arm64 (AArch64)
- Raspberry Pi 4 / BCM2711
- Default defconfig: `defconfig` (mainline)
- Default kernel: Linus mainline (`KERNEL_REPO` + `KERNEL_REF=master`)

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
2. Generate config with `make <DEFCONFIG>`. For mainline, use `defconfig`.
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

## Rebuild / Rerun the Job
The Job spec is immutable, so delete and recreate it when you want a rebuild.
The `ccache` PVC is preserved to speed up rebuilds.

```bash
oc delete job rpi4-kernel-build -n pi4-kernel-build
oc apply -f manifests/job-build.yaml
```

4) Retrieve artifacts
- The output directory is mounted at `/work/out`.
- Mount the `out` PVC in another Pod or use `oc cp`.

Example (copy from the Job pod, if it still exists):
```bash
POD="$(oc get pods -n pi4-kernel-build -l job-name=rpi4-kernel-build -o jsonpath='{.items[0].metadata.name}')"
oc cp -n pi4-kernel-build "$POD":/work/out ./out
```

Example (mount the `out` PVC in a helper pod):
```bash
oc run -n pi4-kernel-build out-reader --image=registry.access.redhat.com/ubi9/ubi --restart=Never --command -- sleep 3600
oc patch -n pi4-kernel-build pod/out-reader -p '{"spec":{"volumes":[{"name":"out","persistentVolumeClaim":{"claimName":"out-pvc"}}],"containers":[{"name":"out-reader","image":"registry.access.redhat.com/ubi9/ubi","command":["sleep","3600"],"volumeMounts":[{"name":"out","mountPath":"/work/out"}]}]}}'
oc cp -n pi4-kernel-build out-reader:/work/out ./out
oc delete pod -n pi4-kernel-build out-reader
```

## License
MIT. See `LICENSE`.
