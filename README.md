# NVIDIA GPU Kubernetes Training — Ansible + Terraform + kind

A hands-on curriculum for taking a bare-metal GPU host to `nvidia-smi`/DCGM fluency on Kubernetes,
using `kind` so every trainee gets an identical, throwaway cluster on a single GPU box — no cloud GPU
quota required. The full curriculum lives in
[`nvidia_gpu_k8s_training_plan.md`](nvidia_gpu_k8s_training_plan.md); this file covers what running it
against real hardware actually surfaced, and the environment-specific fixes now baked into the repo as
a result.

**Verified against:** Debian 12, single NVIDIA RTX A400 (4GB VRAM, no ECC, no NVLink, no MIG), driver
580.126.18, CUDA 13.0, on a homelab box that also runs other non-GPU Docker workloads — not a
dedicated, isolated GPU node. That last detail matters: several of the fixes below exist specifically
*because* this is a shared box and a nested-container (`kind`) setup, not a clean single-purpose GPU
server. On a real multi-node GPU cluster, some of these wouldn't apply at all — the plan calls this out
inline wherever it's relevant.

---

## Status

Phases 1–12 of the training plan have been run end-to-end against real hardware, including every fix
described below. Phases 13 (capstone) and 14 (cleanup) are written but have not yet been executed as
part of this verification pass — treat them as designed-but-untested.

One remaining open item: `dcgmi diag` (Phase 11) cannot run from inside any `dcgm-exporter` container —
by design, not by bug — and needs a full `datacenter-gpu-manager` install directly on the host. That
install has not been attempted or verified yet; Phase 11 documents the gap and what package to look for.

---

## Repository layout

```
.
├── ansible/
│   ├── inventory.ini
│   └── host-prep.yml
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   └── kind-config.yaml
├── k8s/
│   ├── runtimeclass.yaml
│   ├── device-plugin-ds.yaml
│   ├── dcgm-exporter-ds.yaml
│   ├── pod-inference-legacy.yaml
│   ├── pod-inference-modern.yaml
│   └── model-cache-statefulset.yaml
└── nvidia_gpu_k8s_training_plan.md   ← the actual curriculum, start here
```

Every manifest here is kept in sync with what the training plan documents inline — if you're diffing
the plan's embedded YAML against what's in `k8s/`/`terraform/`, they should match. If they don't,
that's a bug; the plan is meant to be copy-pasteable, not aspirational.

---

## The central finding: `no-cgroups=true` and why almost everything here runs `privileged: true`

This is the single most important thing to understand before running this on your own hardware, and
it's specific to running GPU workloads in `kind` (nested containers), not a general Kubernetes GPU
fact.

`nvidia-container-cli` cannot manage cgroups from *inside* a nested `kind` node — a workload pod's
cgroup is a child of the `kind` node container's own cgroup, one layer removed from the host, and the
tool isn't built to reach through that. The practical consequence, on a node where
`/etc/nvidia-container-runtime/config.toml` sets `no-cgroups = true` (required for exactly this reason),
is that the automatic cgroup device-access grant never happens for *any* pod going through the `nvidia`
RuntimeClass. Device files and driver libraries still get bind-mounted into the container correctly —
they're visible, they look right — but the kernel still denies `open()` on them, producing a generic
`Failed to initialize NVML: Unknown Error` with no other clue as to why.

Kubernetes' normal fix for exactly this class of problem is the device-plugin `Allocate()` flow, which
grants cgroup access as part of scheduling a pod that requests `resources.limits.nvidia.com/gpu`. That
doesn't help here for two separate reasons:

- The device plugin and `dcgm-exporter` themselves can't go through that flow — they're what *provides*
  the `nvidia.com/gpu` resource in the first place, so there's nothing to request it from yet.
- Confirmed directly by testing: even the inference pods, which *do* request
  `resources.limits.nvidia.com/gpu: 1` and go through the normal Allocate() path, hit the identical
  error. `no-cgroups=true` is a node-wide `nvidia-container-cli` setting with no carve-out for the
  resource-request path.

The only fix that works is `securityContext.privileged: true`, applied to every pod that touches
`/dev/nvidia*` on this node: `device-plugin-ds.yaml`, `dcgm-exporter-ds.yaml`, and
`pod-inference-modern.yaml` (`pod-inference-legacy.yaml` already ran privileged by design, being the
manual/legacy GPU-access pattern). On a normal, non-nested cluster, none of this would be necessary —
the modern pattern's whole security pitch is *not* needing `privileged: true`, and that's still true
there. It just isn't true on `kind`.

---

## Other fixes and findings, by category

### Getting the repo to actually run

- **`ansible/inventory.ini`** pointed at a remote SSH host that doesn't exist. Set to
  `ansible_connection=local` so the playbook runs directly on the target box.
- **`ansible/host-prep.yml`**'s driver-check task used a nonexistent module parameter
  (`failing_on_missing`), which aborted the play with a generic "unsupported parameters" error before
  the intended "no driver, fail clearly" logic ever ran. Corrected to `failed_when: false`. The
  `nvidia-ctk runtime configure` task was also made idempotent (checks `/etc/docker/daemon.json` first),
  so re-running the playbook after the cluster already exists doesn't unconditionally restart Docker
  and take the cluster down with it.
- **`terraform/kind-confg.yaml` → `terraform/kind-config.yaml`** — filename typo; `variables.tf`
  referenced the correct spelling, so `terraform apply` couldn't find the file at all.
- **`terraform/variables.tf`** used `${path.module}` as a `variable` block's `default`, which Terraform
  rejects (must be a literal) — only surfaces as an error the first time you actually `terraform apply`.
  Moved to a `locals` block instead.
- **`k8s/pod-inference-legacy.yaml`** existed but was empty. Populated to match the plan's legacy
  pattern (privileged + manual `hostPath` device/lib mounts, no RuntimeClass, no
  `resources.limits.nvidia.com/gpu`) so Phase 7's legacy-vs-modern comparison has two real pods to diff.

### GPU library discoverability

Bind-mounting `/opt/nvidia-libs` into the `kind` node (via `extraMounts`) makes the driver library files
visible, but doesn't register that directory with the node's dynamic linker — `ldconfig` never runs
automatically. Without it, neither `nvidia-smi` nor `nvidia-container-cli` can find `libnvidia-ml.so`.
Fixed permanently via a `null_resource.refresh_gpu_node_ldcache` in `terraform/main.tf` that runs
`docker exec <node> ldconfig /opt/nvidia-libs` right after cluster creation — no manual step required.

### GPU Operator vs. `kind`'s shared host topology

Installing the NVIDIA GPU Operator (Phase 9) surfaced a second, unrelated class of problem: every
`kind` node is a container on the *same physical host*, and PCI device enumeration (`/sys/bus/pci`) is
visible host-wide, not scoped per node the way `/dev/nvidia*` is. Node Feature Discovery — and,
confirmed directly, something in the Operator's own controller independent of NFD — labels *every*
node `nvidia.com/gpu.present=true`, including the control-plane and the two nodes deliberately built
without any GPU tooling. Neither disabling NFD (`--set nfd.enabled=false`) nor manually stripping the
label held; both were reasserted.

The `ClusterPolicy` CRD in the pinned chart version (`v26.3.3`) has no field to override per-component
node placement (`kubectl explain clusterpolicy.spec --recursive` turns up exactly one `nodeSelector`,
unrelated to DaemonSet scheduling), so the label can't be fought at that layer either. The fix that
actually holds: taint the two non-GPU workers with a key the Operator's DaemonSets don't tolerate
(`no-gpu-runtime=true:NoSchedule` — deliberately not `nvidia.com/gpu`, which the Operator tolerates
unconditionally). Automated in `terraform/main.tf` via `null_resource.taint_non_gpu_workers`, and
confirmed live: after the fix, all four nodes still show the mislabel, but every Operator pod lands
only on the correct node regardless.

One accepted side effect of that fix: `gpu-operator-node-feature-discovery-gc`, a generic utility
Deployment with no special tolerations, can become permanently unschedulable once both the GPU node's
own taint (from Phase 5) and the two new worker taints exist — there's no untainted node left for it.
It isn't required for any GPU functionality; `helm install --wait` will hang waiting on it regardless,
and that's safe to interrupt once the release has otherwise deployed.

### Tooling gotchas worth knowing about generically

- **`kubectl taint` has no `--overwrite` flag** (that's `kubectl label`). Passing it fails immediately
  with `unknown flag: --overwrite`, even against a taint that doesn't exist yet. The idempotent pattern
  used throughout this repo is remove-then-add: `kubectl taint ... key:effect- || true` followed by the
  real `kubectl taint ... key=value:effect`.
- **CRLF line endings silently corrupt embedded shell scripts.** This repo was edited from a Windows
  checkout at points during development; Terraform heredocs and Ansible `shell: |` blocks are
  particularly vulnerable — a stray `\r` before a line-continuation `\` breaks the continuation
  entirely, and a stray `\r` on an argument (e.g. a taint effect) gets rejected as an invalid value with
  a confusing error. If you're editing on Windows, verify line endings (`file <path>` should say
  "with CRLF line terminators" or not) before assuming a script bug.
- **Backgrounding a process inside `kubectl exec` doesn't survive the exec session ending**, unless
  it's explicitly detached. A plain `nv-hostengine &` inside an interactive `kubectl exec -it` shell
  dies the moment that shell exits; a separate, later `kubectl exec` finds nothing listening. Use
  `setsid <cmd> > /tmp/log 2>&1 < /dev/null &` in a single, non-interactive `kubectl exec` instead.

### `dcgm-exporter` and `dcgmi` — three separate limitations, not one bug

- `dcgm-exporter` runs DCGM in *embedded* mode for its own metrics scraping — there's no
  `nv-hostengine` daemon listening for external clients. `dcgmi` commands fail with
  `unable to establish a connection to the specified host: localhost` until you start one manually
  (detached, per the `setsid` note above).
- The GPU Operator's own `dcgm-exporter` image tag is `distroless` — no shell, no `dcgmi` binary, no way
  to run this walkthrough from it at all. The hand-rolled `k8s/dcgm-exporter-ds.yaml` (Ubuntu-based)
  is what Phase 11 actually depends on, and is deliberately **not** deleted when retiring the rest of
  the hand-rolled manifests in Phase 9 — unlike the device plugin, running two `dcgm-exporter`s side by
  side is harmless (two independent metrics targets, no shared registration to conflict over).
- Even with `nv-hostengine` running, `dcgmi diag` fails separately — `The NVVS binary was not found...
  please install it to /usr/share/nvidia-validation-suite/`. NVVS (NVIDIA Validation Suite) is what
  `diag` shells out to for health checks and stress tests, and it isn't bundled in either
  `dcgm-exporter` image. No container-side fix exists; it needs a full `datacenter-gpu-manager` install
  on the host itself. This is the one open item noted in Status above.

---

## Full troubleshooting reference

Phase 12 of the training plan is a symptom → cause table covering every failure mode above in more
detail, plus several narrower ones (typo'd `extraMounts` paths, missing `RuntimeClass`, unapplied
taints). If something in this repo breaks for you, check there first.
