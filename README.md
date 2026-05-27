# openshift-rpi4-kernel-build

🌐 **Language / 言語**: **English** | [日本語](README.ja.md)

A demo project that cross-compiles a Linux kernel for the Raspberry Pi 4 inside a container running on OpenShift.  
Build artifacts and `ccache` are persisted in PVCs so they can be reused across rebuilds.

---

## Table of Contents

1. [What this demo does](#1-what-this-demo-does)
2. [End-to-end flow](#2-end-to-end-flow)
3. [Prerequisites (host requirements)](#3-prerequisites-host-requirements)
4. [Step 1: Install OpenShift Local](#step-1-install-openshift-local)
5. [Step 2: Start the cluster](#step-2-start-the-cluster)
6. [Step 3: Log in and create a project](#step-3-log-in-and-create-a-project)
7. [Step 4: Build the build-container image](#step-4-build-the-build-container-image)
8. [Step 5: Create the PVCs](#step-5-create-the-pvcs)
9. [Step 6: Run the kernel-build Job](#step-6-run-the-kernel-build-job)
10. [Step 7: Retrieve the artifacts](#step-7-retrieve-the-artifacts)
11. [Rebuilding](#rebuilding)
12. [Customization (mainline kernel, etc.)](#customization-mainline-kernel-etc)
13. [Cleanup](#cleanup)
14. [Troubleshooting](#troubleshooting)
15. [Project layout](#project-layout)

---

## 1. What this demo does

- Builds a Linux kernel for the Raspberry Pi 4 (BCM2711 / arm64) on **OpenShift Local** (a single-node OpenShift cluster running on your laptop).
- The whole build runs inside a container, so the host OS stays clean.
- Artifacts (`Image`, `*.dtb`, modules) and `ccache` are persisted on PVCs, so subsequent builds are dramatically faster.

### Why build on OpenShift?

- **Reproducibility**: the same container image yields the same result for everyone.
- **Resource control**: the Job declares explicit CPU/memory requests and limits.
- **Persistence**: PVCs keep the cache and artifacts alive even after Pods go away.
- **Great for learning OpenShift**: even without a web app, you exercise Jobs, PVCs, the internal image registry, and Security Context Constraints.

---

## 2. End-to-end flow

```
[Host PC]                              [OpenShift Local cluster]
   │
   │ 1) crc start
   │ 2) podman build the image
   │ 3) podman push → internal registry ─►  image-registry (built-in)
   │ 4) oc apply -f manifests/   ────────►  Namespace / PVC / Job
   │                                          │
   │                                          ▼
   │                                      ┌────────────┐
   │ 5) oc logs -f job/... to follow      │ Build Pod  │
   │                                      │  ├ git clone│
   │                                      │  ├ make     │
   │                                      │  └ install  │
   │                                      └─────┬──────┘
   │                                            │
   │ 6) oc cp to pull artifacts ◄───────────────┘ out-pvc / ccache-pvc
```

### How long will this take?

Rough wall-clock estimates on the recommended host spec (8 cores / 24 GiB):

| Phase | First run | Subsequent runs |
|-------|-----------|-----------------|
| Install `crc` + `crc setup` (Step 1) | 5–10 min | — (one-time) |
| `crc start` (Step 2) | 10–20 min | 3–5 min |
| `podman build` the build image (Step 4-1) | 5–10 min | <1 min (cached layers) |
| `podman push` (Step 4-2) | 1–3 min | <1 min |
| Create namespace + PVCs (Steps 3 / 5) | <1 min | — |
| Kernel build Job (Step 6) | **30–60 min** | **5–15 min** (ccache warm) |
| Copy artifacts (Step 7) | 1–2 min | 1–2 min |
| **Total** | **~60–90 min** | **~15–25 min** |

---

## 3. Prerequisites (host requirements)

To run OpenShift Local comfortably you need a host PC with at least these resources:

| Item | Minimum | Recommended (for this demo) |
|------|---------|-----------------------------|
| CPU | 4 cores | **8+ cores** |
| Memory | 9 GiB | **24+ GiB** |
| Free disk space | 35 GB | **80+ GB** |
| OS | RHEL / Fedora / Ubuntu / macOS / Windows | Fedora or RHEL recommended |

> ⚠️ The Job manifest requests `cpu=4, memory=8Gi` and limits at `cpu=8, memory=20Gi` by default. If OpenShift Local has fewer resources allocated, the Pod will sit in `Pending` forever. Adjust with `crc config set` (shown below).

Tools you will need (installation covered in Step 1):

- `crc` (OpenShift Local)
- `oc` (OpenShift CLI; bundled with `crc`)
- `podman` (for building and pushing the image)
- `git`

---

## Step 1: Install OpenShift Local

### 1-1. Sign up and download

1. Go to [Red Hat Hybrid Cloud Console — OpenShift Local](https://console.redhat.com/openshift/create/local) and log in with your Red Hat account (free to create).
2. From that page, download two things:
   - **The OpenShift Local installer / tarball** for your OS
   - **Your pull secret** (`pull-secret.txt`) — needed when starting the cluster

### 1-2. Install `crc` (Linux example)

```bash
# Extract the tarball and put crc on your PATH
tar -xf crc-linux-amd64.tar.xz
sudo install -m 0755 crc-linux-*-amd64/crc /usr/local/bin/crc
crc version
```

> On macOS / Windows, run the downloaded pkg / msi installer.

### 1-3. Set up the host

`crc setup` configures host prerequisites (KVM, libvirt, networking, etc.) automatically.

```bash
crc setup
```

---

## Step 2: Start the cluster

### 2-1. Bump resource allocation (required for this demo)

The defaults are not enough for a kernel build. **Set this before starting:**

```bash
crc config set cpus 8
crc config set memory 24576       # 24 GiB
crc config set disk-size 80
```

Verify with `crc config view`.

### 2-2. Start the cluster

On first start you will be prompted for the pull secret path you downloaded in Step 1-1.

```bash
crc start --pull-secret-file ~/Downloads/pull-secret.txt
```

Startup takes 10–20 minutes. Once it finishes, you will see the `kubeadmin` and `developer` passwords plus the console URL. **Copy that output — you will need it next.**

### 2-3. Make `oc` available in your shell

`oc` ships with `crc`. Put it on your PATH:

```bash
eval $(crc oc-env)
oc version
```

> To make it permanent, add `eval $(crc oc-env)` to your `~/.bashrc`.

---

## Step 3: Log in and create a project

### 3-1. Log in as `kubeadmin`

Use the URL and password printed by `crc start`.

```bash
oc login -u kubeadmin https://api.crc.testing:6443
# To re-display the credentials later: crc console --credentials
```

### 3-2. Clone this project

```bash
git clone https://github.com/<your-org>/openshift-rpi4-kernel-build.git
cd openshift-rpi4-kernel-build
```

### 3-3. Create the dedicated namespace

```bash
oc apply -f manifests/namespace.yaml
oc project pi4-kernel-build
```

---

## Step 4: Build the build-container image

OpenShift Local ships with a built-in **internal image registry** at `default-route-openshift-image-registry.apps-crc.testing`. We push there so the Job can pull from it.

### 4-1. Build the image targeted at the internal registry

```bash
podman build \
  -f container/Containerfile \
  -t default-route-openshift-image-registry.apps-crc.testing/pi4-kernel-build/openshift-rpi4-kernel-build:latest \
  .
```

What's inside `container/Containerfile`:

- Base: `fedora:41`
- aarch64 cross toolchain (`gcc-aarch64-linux-gnu`, etc.)
- Kernel build deps (`bison`, `flex`, `bc`, `openssl-devel`, `elfutils-libelf-devel`, …)
- `ccache` enabled
- Non-root friendly (compatible with OpenShift's random UID policy)

### 4-2. Log in to the registry and push

```bash
podman login -u kubeadmin -p "$(oc whoami -t)" \
  default-route-openshift-image-registry.apps-crc.testing

podman push \
  default-route-openshift-image-registry.apps-crc.testing/pi4-kernel-build/openshift-rpi4-kernel-build:latest
```

> 💡 If you hit self-signed-cert warnings, either pass `--tls-verify=false` or trust the CRC CA.

After a successful push, the image is reachable from inside the cluster as `image-registry.openshift-image-registry.svc:5000/pi4-kernel-build/openshift-rpi4-kernel-build:latest` — which is exactly what the Job manifest references.

---

## Step 5: Create the PVCs

Create the volumes that hold artifacts and the ccache:

```bash
oc apply -f manifests/pvc-ccache.yaml   # 20Gi
oc apply -f manifests/pvc-out.yaml      # 30Gi
```

Verify:

```bash
oc get pvc -n pi4-kernel-build
# NAME         STATUS   VOLUME ...   CAPACITY
# ccache-pvc   Bound    ...          20Gi
# out-pvc      Bound    ...          30Gi
```

---

## Step 6: Run the kernel-build Job

### 6-1. Submit the Job

```bash
oc apply -f manifests/job-build.yaml
```

Key environment variables used by `manifests/job-build.yaml`:

| Variable | Default | Purpose |
|----------|---------|---------|
| `KERNEL_REPO` | `https://github.com/raspberrypi/linux.git` | Where to fetch sources from |
| `KERNEL_REF` | `rpi-6.6.y` | Branch / tag |
| `DEFCONFIG` | `bcm2711_defconfig` | Pi 4 defconfig |
| `JOBS` | `2` | `make -j` parallelism |

### 6-2. Follow progress

```bash
# Wait for the Pod to come up
oc get pods -n pi4-kernel-build -w

# Tail the build log
oc logs -f job/rpi4-kernel-build -n pi4-kernel-build
```

You should see something like:

```
==> Fetch kernel source
==> Configure (bcm2711_defconfig)
==> Build (Image/modules/dtbs)
   ...
==> Install modules into OUT_DIR/mods
==> Build summary
   -rw-r--r-- ... arch/arm64/boot/Image
==> ccache stats
DONE
```

> ⏱ A cold first build takes roughly 30–60 minutes depending on allocated CPU. Subsequent builds are much faster thanks to `ccache`.

### 6-3. Confirm completion

```bash
oc get job -n pi4-kernel-build rpi4-kernel-build
# COMPLETIONS   DURATION   AGE
# 1/1           45m        50m
```

---

## Step 7: Retrieve the artifacts

Artifacts live on `out-pvc` at `/work/out`. The easiest path is to copy them while the Job Pod is still around.

### Option A: Copy straight from the Job Pod

```bash
POD="$(oc get pods -n pi4-kernel-build -l job-name=rpi4-kernel-build \
       -o jsonpath='{.items[0].metadata.name}')"

oc cp -n pi4-kernel-build "$POD":/work/out ./out
```

### Option B: Mount `out-pvc` in a helper Pod

Use this if the Job Pod is already gone, or you want to grab artifacts later.

```bash
oc run -n pi4-kernel-build out-reader \
  --image=registry.access.redhat.com/ubi9/ubi \
  --restart=Never --command -- sleep 3600

oc patch -n pi4-kernel-build pod/out-reader -p '{
  "spec":{
    "volumes":[{"name":"out","persistentVolumeClaim":{"claimName":"out-pvc"}}],
    "containers":[{
      "name":"out-reader",
      "image":"registry.access.redhat.com/ubi9/ubi",
      "command":["sleep","3600"],
      "volumeMounts":[{"name":"out","mountPath":"/work/out"}]
    }]
  }
}'

oc cp -n pi4-kernel-build out-reader:/work/out ./out
oc delete pod -n pi4-kernel-build out-reader
```

### What you get

- `out/arch/arm64/boot/Image` — the kernel itself
- `out/arch/arm64/boot/dts/broadcom/bcm2711-rpi-4-*.dtb` — device trees
- `out/mods/lib/modules/<ver>/` — kernel modules

Drop these onto the boot / root partitions of your SD card and you can boot the kernel on a real Raspberry Pi 4.

---

## Rebuilding

Kubernetes `Job` specs are immutable, so to rebuild you **delete and re-create**. `ccache-pvc` is preserved, so subsequent runs are much faster.

```bash
oc delete job rpi4-kernel-build -n pi4-kernel-build
oc apply -f manifests/job-build.yaml
```

---

## Customization (mainline kernel, etc.)

Edit the `env:` block in `manifests/job-build.yaml` to build a different kernel.

Example: build mainline (`torvalds/linux`) at tag `v6.10`:

```yaml
- name: KERNEL_REPO
  value: https://github.com/torvalds/linux.git
- name: KERNEL_REF
  value: v6.10
- name: DEFCONFIG
  value: defconfig          # generic arm64 defconfig
```

To increase parallelism (if you have CPU headroom):

```yaml
- name: JOBS
  value: "8"
```

Bump `resources.limits` to match.

---

## Cleanup

When the demo is over, remove the resources and stop the cluster:

```bash
# Delete the whole namespace (Job + PVCs in one shot)
oc delete namespace pi4-kernel-build

# Stop the cluster
crc stop

# Or wipe it completely
crc delete
```

---

## Troubleshooting

### Pod stuck in `Pending`

- Run `oc describe pod -n pi4-kernel-build <pod-name>` and check for `Insufficient cpu` / `Insufficient memory`.
- Increase allocation with `crc config set cpus 8` / `crc config set memory 24576`, then `crc stop && crc start`.

### `ImagePullBackOff`

- Make sure the Step 4 push actually succeeded: `oc get is -n pi4-kernel-build`.
- Confirm the internal registry URL (`image-registry.openshift-image-registry.svc:5000/...`) in the manifest matches what you pushed.

### `podman push` returns 401 / 403

- Re-run `podman login` (`oc whoami -t` tokens have a limited lifetime).
- Confirm you are still logged in as `kubeadmin`: `oc whoami` should return `kubeadmin`.

### Build is OOM-killed

- Lower `JOBS` (e.g. `"2"` → `"1"`).
- Raise `resources.limits.memory` (and the cluster allocation to match).

### Capture logs for later

```bash
oc logs -n pi4-kernel-build job/rpi4-kernel-build > build.log
```

---

## Project layout

```
.
├── container/
│   └── Containerfile         # Build-image definition (Fedora + cross toolchain)
├── manifests/
│   ├── namespace.yaml        # pi4-kernel-build namespace
│   ├── pvc-ccache.yaml       # ccache PVC (20Gi)
│   ├── pvc-out.yaml          # artifacts PVC (30Gi)
│   └── job-build.yaml        # the build Job
├── scripts/
│   └── build.sh              # actual build script that runs inside the container
├── README.md                 # this file (English)
└── README.ja.md              # Japanese version
```

### Security context

To run cleanly under OpenShift's restricted SCC, the Job uses:

- `runAsNonRoot: true`
- `allowPrivilegeEscalation: false`
- `capabilities.drop: ["ALL"]`
- `seccompProfile: RuntimeDefault`

---

## License

MIT. See `LICENSE`.
