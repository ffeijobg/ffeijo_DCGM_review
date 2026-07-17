# GPU Kubernetes Training — basement-nas Build Log

Status: Phases 1–6 of [`nvidia_gpu_k8s_training_plan.md`](nvidia_gpu_k8s_training_plan.md) verified working
on real hardware. Phase 7 (inference pods) not yet started.

**Target host:** `basement-nas` — Debian 12, single NVIDIA RTX A400 (4GB VRAM, no ECC, no NVLink, no MIG),
driver 580.126.18, CUDA 13.0. Homelab box, also runs other non-GPU Docker workloads — not a dedicated,
isolated GPU node.

---

## What's working

- **Phase 1 (Ansible host prep)** — driver check, Docker + NVIDIA Container Toolkit install, `kind`/`kubectl`/`helm`
  install. Runs locally via `ansible_connection=local` (`ansible/inventory.ini`).
- **Phase 2 (Terraform + kind)** — cluster provisions cleanly, including a post-create step that fixes a
  library-discovery gap kind doesn't handle on its own (see below).
- **Phase 3 (verify cluster)** — `docker exec gfn-prod-worker nvidia-smi` succeeds.
- **Phase 4 (RuntimeClass)** — applied as-is from the plan, no issues.
- **Phase 5 (taints/labels)** — applied as-is from the plan, no issues.
- **Phase 6 (device plugin)** — `nvidia-device-plugin` DaemonSet runs and the node reports
  `nvidia.com/gpu: 1` Allocatable.

## What's fixed and why (in the order we hit them)

1. **`ansible/inventory.ini`** — was pointed at a remote SSH host (`10.0.10.11`/`ubuntu`) that doesn't exist.
   Changed to `ansible_connection=local` so the playbook runs directly on `basement-nas`.

2. **`ansible/host-prep.yml`** — the driver-check task used a nonexistent module parameter
   (`failing_on_missing`), which would abort the play with a generic "unsupported parameters" error
   before the intended "no driver, fail with a clear message" task ever ran. Fixed to `failed_when: false`.
   Also made the `nvidia-ctk runtime configure` task idempotent (checks `/etc/docker/daemon.json` first) so
   re-running the playbook after the kind cluster exists doesn't unconditionally restart Docker and take
   the cluster down with it.

3. **`terraform/kind-confg.yaml` → `terraform/kind-config.yaml`** — filename typo; `variables.tf` referenced
   the correctly-spelled name, so `terraform apply` would have failed to find the file.

4. **`k8s/pod-inference-legacy.yaml`** — existed but was empty. Populated to match the plan's described
   legacy pattern (privileged + manual hostPath device/lib mounts, no RuntimeClass, no
   `resources.limits.nvidia.com/gpu`), so Phase 7's legacy-vs-modern diff actually has two pods to compare.

5. **`terraform/variables.tf`** — `kind_config_path`'s default used `${path.module}`, which Terraform
   doesn't allow inside a `variable` block's `default` (must be a literal). Moved it to a `locals` block;
   `main.tf` now references `local.kind_config_path`.

6. **The `docker exec <node> nvidia-smi` saga** — this took several wrong turns before landing on the real
   fix, worth recording in full:
   - Original symptom: `NVIDIA-SMI couldn't find libnvidia-ml.so`. I incorrectly diagnosed this as the
     manual `extraMounts` pattern being inherently wrong, and replaced it with "make nvidia Docker's
     default runtime" — this was a bad call for two reasons: (a) it doesn't work for kind specifically,
     since `kind create cluster` has no way to set `NVIDIA_VISIBLE_DEVICES` on the node containers it
     creates, so nothing actually got injected (regression: `nvidia-smi` binary itself went missing); and
     (b) it would have made `nvidia` the default runtime for *every* container on this host, not just kind
     nodes — a real risk on a shared homelab box. Reverted.
   - The user pointed at `ffeijo_reusable_templates-/intial1.txt`, a config proven to work on this same
     host for a prior cluster, using the same `extraMounts` pattern our original `kind-config.yaml` had.
     Restored it.
   - Root cause of the *original* error: bind-mounting `/opt/nvidia-libs` into the node makes the files
     visible, but doesn't register that directory with the node's dynamic linker — `ldconfig` was never run
     inside the node. Fixed permanently in `terraform/main.tf` via a `null_resource.refresh_gpu_node_ldcache`
     that runs `docker exec <node> ldconfig /opt/nvidia-libs` right after cluster creation.
   - Confirmed: `docker exec gfn-prod-worker nvidia-smi` now works without needing `LD_LIBRARY_PATH` set
     manually.

7. **The device-plugin NVML saga** — also took more than one pass:
   - Symptom: `nvidia-device-plugin` pod `CrashLoopBackOff`, logs show
     `Failed to initialize NVML: Unknown Error`.
   - First fix attempt: added `NVIDIA_VISIBLE_DEVICES=all` / `NVIDIA_DRIVER_CAPABILITIES=all` env vars to
     `device-plugin-ds.yaml` (it was the one manifest in the repo missing them, unlike both inference pods).
     Necessary but **not sufficient** — identical error persisted after this change.
   - Diagnosed with `docker exec <node> nvidia-container-cli -d /dev/stderr info`, which succeeded cleanly
     (driver version, CUDA version, and the A400 all correctly enumerated) — this ruled out "the injection
     tool can't find the driver" and pointed at something specific to how containerd invokes it for pods.
   - `docker exec <node> cat /etc/nvidia-container-runtime/config.toml` revealed a heavily hand-tuned config
     **that predates this repo** — `no-cgroups = true`, `library-search-dirs = ["/opt/nvidia-libs"]`,
     `mode = "legacy"`, with comments referencing a prior debugging session on this host. This file isn't
     managed by anything in `ansible/` or `terraform/` — it was edited directly on the host at some point
     before this work started.
   - Built a throwaway debug pod (`sleep infinity`, same `runtimeClassName`/env as the device plugin) to
     inspect the pod's filesystem directly after injection: devices *were* present in `/dev`, libraries
     *were* correctly injected into `/usr/lib/x86_64-linux-gnu/` and registered in `ldconfig` — yet
     `nvidia-smi` inside that pod still failed identically.
   - Root cause: `no-cgroups = true` (needed because `nvidia-container-cli` can't modify cgroups from
     inside a nested kind node) disables NVIDIA's own cgroup device-access grant. Normally that grant comes
     from Kubernetes' device-plugin resource-allocation flow instead — but the device plugin (and dcgm-exporter,
     which also doesn't request `nvidia.com/gpu`) can't go through that flow, since it's what *provides*
     that resource. Nothing was granting cgroup device access at all: files visible, kernel still denying
     `open()` on them.
   - Confirmed by adding `securityContext: privileged: true` to the debug pod — `nvidia-smi` immediately
     worked.
   - Applied permanently to `k8s/device-plugin-ds.yaml` (replacing the previous
     `allowPrivilegeEscalation: false` / `capabilities: drop: ["ALL"]`) and `k8s/dcgm-exporter-ds.yaml`
     (which already had `privileged: true` for an unrelated reason — DCGM diagnostics needing elevated
     capabilities — and turns out to need it for this reason too).

## Known gap — not yet resolved

**`k8s/pod-inference-modern.yaml` and `k8s/pod-inference-legacy.yaml` are not confirmed against the
`no-cgroups=true` / cgroup-device-access issue above.** Unlike the device plugin, the modern pod *does*
request `resources.limits.nvidia.com/gpu: 1`, which routes through kubelet's normal device-plugin
`Allocate()` call — that path may grant cgroup device access on its own and sidestep the whole problem, or
it may not, since `no-cgroups=true` is a node-wide `nvidia-container-cli` setting, not something scoped to
"only bootstrap pods." This hasn't been tested yet.

**Before starting Phase 7:** deploy `pod-inference-modern.yaml` as-is first. If it schedules but the Triton
container fails the same way (NVML error, or `nvidia-smi` inside the pod not finding the GPU), the fix is
the same one applied to the device plugin and dcgm-exporter — add `securityContext: privileged: true`. Don't
add it preemptively; there's a real chance the resource-request path works differently and it may not be
needed. `pod-inference-legacy.yaml` already runs `privileged: true` by design (that's the point of the
legacy pattern), so it isn't at risk here either way.
