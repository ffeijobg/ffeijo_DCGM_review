# NVIDIA GPU Kubernetes Training Plan
### Terraform + Ansible + kind, from bare metal to `nvidia-smi`/DCGM fluency

**Audience:** engineers new to Kubernetes infrastructure work, comfortable with Linux and basic containers.
**Format:** every step after cluster bring-up is done with `kubectl`/`helm`/CLI tools — no dashboards.
**Origin:** this plan grew out of reconciling two draft `kind` cluster configs that disagreed with each other on how to label the GPU worker node, plus a pod manifest with a truncated hostPath and two incompatible GPU-access patterns mixed together. The relevant "before" excerpts are shown inline in Phase 2 and Phase 7, where they're actually fixed — spotting that kind of drift is exactly what a principal engineer does before anything ships.

---

## 0. Learning Outcomes

By the end, a trainee can:

1. Explain why GPU access in a `kind` cluster is a *two-layer* problem (Docker host → containerd inside the kind node) and configure both layers.
2. Use Ansible for host configuration and Terraform for cluster lifecycle, and articulate why those responsibilities are split rather than merged.
3. Reconcile a kind cluster config against the Kubernetes objects it depends on (RuntimeClass, taints, labels) that `kind` itself does *not* create for you.
4. Contrast the **legacy/manual** GPU-exposure pattern (privileged pod + hostPath device mounts) against the **modern** pattern (device plugin + `resources.limits`), and know why you never mix them in production.
5. Deploy and read output from `nvidia-smi` and DCGM (`dcgmi`, `dcgm-exporter`) for both ad-hoc diagnostics and continuous monitoring.
6. Explain what the NVIDIA GPU Operator automates, and when to use it instead of hand-rolled manifests.
7. Diagnose a "device files visible but access denied" GPU failure by distinguishing file-level injection from cgroup-level permission grants, and recognize when an environment-specific limitation (like `kind`'s nested-container `no-cgroups` requirement, covered in depth in Section 2 and Phase 12) quietly breaks an assumption a pattern's whole security story depends on.

---

## 1. Prerequisites

| Tool | Why | Version note |
|---|---|---|
| Docker Engine | runs the kind "node" containers | must have NVIDIA Container Toolkit registered as a runtime |
| NVIDIA driver (host) | kind nodes share the host kernel/driver — there is no in-container driver | `nvidia-smi` must work on the **host** before you touch Kubernetes |
| `kind` | disposable multi-node clusters using containers as nodes | v0.23+ |
| `kubectl` | cluster-side CLI, used for everything post-provisioning | matched to cluster's k8s minor version |
| `helm` | used once, for the GPU Operator | v3.x |
| Terraform | cluster lifecycle | v1.7+ |
| Ansible | host configuration | core 2.16+ |

A real, working GPU on the host is required — `kind` does not virtualize or emulate one.

---

## 2. Architecture Decisions (read before writing any code)

**Why `kind` at all for GPU training?** It gives every trainee an identical, throwaway cluster on a single GPU box without needing cloud GPU quota. The tradeoff you must teach explicitly: kind nodes are Docker containers, so GPU access has to be threaded through *two* container boundaries — Docker's runtime for the node container, and containerd's runtime *inside* that node container for workload pods. This is why the config has both a Docker-level toolkit install (Ansible, Phase 1) and a `containerdConfigPatches` block (kind config, Phase 2).

**Why Ansible for hosts and Terraform for the cluster, instead of one tool doing both?** Ansible is idempotent configuration management against a long-lived machine (the GPU host) — driver checks, package installs, daemon config. Terraform models a resource's lifecycle (create/read/update/destroy) — the cluster itself. Using Terraform to push files onto a host, or Ansible to manage cluster create/destroy state, works but fights each tool's design and gets fragile as the team grows. Keep the boundary: **Ansible = host is correctly configured. Terraform = cluster exists or doesn't.**

**Why does Terraform shell out to `kind` instead of using a provider?** There is no official HashiCorp/kind API-driven provider — `kind` itself has no daemon or REST API, only a CLI that wraps Docker. Community Terraform providers for kind exist but wrap the same CLI underneath, so this plan uses an explicit `null_resource` + `local-exec`/`local-exec` destroy-time provisioner. It's more verbose, but a trainee can `docker ps` and `kind get clusters` and see exactly what Terraform did — no hidden abstraction.

**The pattern mismatch you must call out (this is the core lesson from the original inference pod manifest, shown in full in Phase 7):**

- **Legacy/manual pattern:** `securityContext.privileged: true` + explicit `hostPath` mounts of `/dev/nvidia0`, driver libraries, and toolkit binaries. The pod does the work itself. Insecure (privileged means the container can do almost anything on the host) and brittle (paths are hardcoded, no scheduling awareness of GPU count).
- **Modern pattern:** a `RuntimeClass` + device plugin DaemonSet advertise `nvidia.com/gpu` as a schedulable resource; a pod just requests `resources.limits: {nvidia.com/gpu: 1}` and the runtime injects the right devices automatically. On a normal cluster this needs no `privileged` flag at all — the device plugin's Allocate() call grants the container's cgroup direct access to just the GPU devices it was scheduled. The scheduler also enforces GPU accounting either way, which the legacy pattern never gets.

**Caveat specific to this `kind` cluster:** because `nvidia-container-cli` cannot manage cgroups from *inside* a nested kind node (the workload pod's cgroup is a child of the kind node container's own cgroup, two layers removed from the host), this cluster's `/etc/nvidia-container-runtime/config.toml` is set to `no-cgroups = true`. That disables the automatic cgroup device grant for *every* pod going through the `nvidia` RuntimeClass — including the device plugin itself and the modern-pattern inference pod — so on this specific cluster both patterns end up needing `securityContext.privileged: true`, just for different reasons: legacy needs it by design (it wires up the GPU itself), modern needs it as a workaround for a nested-containerization limitation that a normal (non-`kind`) cluster wouldn't have. See Phase 12 for the full symptom (`Failed to initialize NVML: Unknown Error` despite devices/libraries visibly present in the container) and the `no-cgroups` comment repeated in `device-plugin-ds.yaml`, `dcgm-exporter-ds.yaml`, and `pod-inference-modern.yaml`.

The original inference pod manifest (Phase 7) does **both at once** — it requests `nvidia.com/gpu: 1` in `resources` *and* manually hostPath-mounts the devices *and* runs privileged. That's redundant and confusing: if the device plugin is doing its job, the manual mounts and privileged flag are unnecessary; if you don't trust the device plugin, the resource request does nothing useful. Part of this curriculum (Phase 7) is stripping the pod down to one pattern deliberately, having trainees experience both, and explaining why real deployments pick the modern one.

---

## 3. Working Directory Layout

```
gpu-training/
├── ansible/
│   ├── inventory.ini
│   └── host-prep.yml
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   └── kind-config.yaml
└── k8s/
    ├── runtimeclass.yaml
    ├── device-plugin-ds.yaml
    ├── pod-inference-legacy.yaml
    ├── pod-inference-modern.yaml
    ├── dcgm-exporter-ds.yaml
    └── model-cache-statefulset.yaml
```

---

## Phase 1 — Host Preparation (Ansible)

**Goal:** every GPU host has the NVIDIA driver verified, Docker configured with the NVIDIA Container Toolkit, and the CLI tools (`kind`, `kubectl`, `helm`) present — *before* Terraform ever runs.

`ansible/inventory.ini`:
```ini
[gpu_hosts]
gpu-node-1 ansible_host=10.0.10.11 ansible_user=ubuntu
```

`ansible/host-prep.yml`:
```yaml
---
- name: Prepare GPU host for kind + Kubernetes GPU workloads
  hosts: gpu_hosts
  become: true
  vars:
    kind_version: "v0.23.0"
    kubectl_version: "v1.30.0"

  tasks:
    - name: Confirm NVIDIA driver is present on the host
      command: nvidia-smi -L
      register: driver_check
      changed_when: false
      failed_when: false

    - name: Fail fast with a clear message if no driver
      fail:
        msg: >
          nvidia-smi did not return a GPU. Install the host driver first —
          this playbook does not install kernel drivers, only container tooling.
      when: driver_check.rc != 0

    - name: Install Docker Engine
      apt:
        name: docker.io
        state: present
        update_cache: true

    - name: Add NVIDIA Container Toolkit apt repo
      shell: |
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
          | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit.gpg
        curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
          | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit.gpg] https://#g' \
          | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
      args:
        creates: /etc/apt/sources.list.d/nvidia-container-toolkit.list

    - name: Install nvidia-container-toolkit
      apt:
        name: nvidia-container-toolkit
        state: present
        update_cache: true

    - name: Check whether docker daemon.json already has the nvidia runtime
      command: grep -q '"nvidia"' /etc/docker/daemon.json
      register: nvidia_runtime_present
      changed_when: false
      failed_when: false

    # Deliberately NOT --set-as-default: this host runs other, non-GPU Docker
    # workloads, and setting nvidia as the system-wide default runtime would
    # affect all of them, not just kind's node containers. GPU access for the
    # kind node containers is provided via kind-config.yaml's extraMounts
    # instead (devices + driver libs + toolkit binaries bind-mounted directly).
    - name: Register nvidia runtime with Docker
      command: nvidia-ctk runtime configure --runtime=docker
      when: nvidia_runtime_present.rc != 0
      notify: restart docker

    - name: Ensure kind is installed
      get_url:
        url: "https://kind.sigs.k8s.io/dl/{{ kind_version }}/kind-linux-amd64"
        dest: /usr/local/bin/kind
        mode: "0755"

    - name: Ensure kubectl is installed
      get_url:
        url: "https://dl.k8s.io/release/{{ kubectl_version }}/bin/linux/amd64/kubectl"
        dest: /usr/local/bin/kubectl
        mode: "0755"

    - name: Ensure helm is installed
      shell: |
        curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
      args:
        creates: /usr/local/bin/helm

  handlers:
    - name: restart docker
      service:
        name: docker
        state: restarted
```

Run it:
```bash
ansible-playbook -i ansible/inventory.ini ansible/host-prep.yml
```

**Teaching point:** the `fail` task on a missing driver is deliberate — trainees should see a playbook refuse to proceed rather than silently building a cluster that can never see a GPU. This is where most real-world GPU cluster failures start.

---

## Phase 2 — Cluster Provisioning (Terraform + kind)

First, the corrected kind config. Two earlier drafts of this config disagreed with each other in two separate ways. Draft A labeled the GPU worker for human/scheduling use:

```yaml
  - role: worker
    labels: { node-pool: gpu-inference, tier: prod }
    extraMounts:
      # ...full device/library/toolkit-binary mounts, same shape as the corrected version below...
```

Draft B labeled it for workload selection instead — and, the real problem, duplicated the *entire* `extraMounts` block (all ~40 lines of device nodes, driver libs, and toolkit binaries) across multiple worker nodes, rather than confining it to the one node that actually has GPU access:

```yaml
  - role: worker
    labels: { nvidia.com/gpu.present: "true" }
    extraMounts:
      # ...full block...

  - role: worker
    labels: { nvidia.com/gpu.present: "true" }
    extraMounts:
      # ...identical block, duplicated again...
```

The corrected config below keeps **both** label sets — `nvidia.com/gpu.present` is the one workloads actually select on, and `node-pool`/`tier` are there for humans running `kubectl get nodes --show-labels` and for future scheduling flexibility (e.g. separating staging from prod) — but standardizes on Draft A's single-node-per-worker mount discipline: only the one node that genuinely has GPU access gets `extraMounts`, not every worker.

`terraform/kind-config.yaml`:
```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: gfn-prod

# Registers nvidia as an available runtime — does NOT set as default.
# System pods (device plugin's own controller aside, kube-proxy, etc.) stay on runc.
# Only pods/DaemonSets with runtimeClassName: nvidia use nvidia-container-runtime.
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia]
      runtime_type = "io.containerd.runc.v2"
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia.options]
      BinaryName = "/usr/bin/nvidia-container-runtime"

nodes:
  - role: control-plane

  - role: worker
    labels:
      node-pool: gpu-inference
      tier: prod
      nvidia.com/gpu.present: "true"
    extraMounts:
      # ── GPU character devices ──────────────────────────────────────────
      - hostPath: /dev/nvidia0
        containerPath: /dev/nvidia0
      - hostPath: /dev/nvidiactl
        containerPath: /dev/nvidiactl
      - hostPath: /dev/nvidia-uvm
        containerPath: /dev/nvidia-uvm
      - hostPath: /dev/nvidia-uvm-tools
        containerPath: /dev/nvidia-uvm-tools

      # ── NVIDIA userspace libs ───────────────────────────────────────────
      - hostPath: /opt/nvidia-libs
        containerPath: /opt/nvidia-libs
        readOnly: true

      # ── nvidia-container-runtime toolkit binaries ──────────────────────
      # runtime → OCI wrapper, called by containerd
      # hook    → prestart hook, called by runc
      # cli     → device injector, called by hook
      # ctk     → config helper, referenced in config
      - hostPath: /usr/bin/nvidia-container-runtime
        containerPath: /usr/bin/nvidia-container-runtime
        readOnly: true
      - hostPath: /usr/bin/nvidia-container-runtime-hook
        containerPath: /usr/bin/nvidia-container-runtime-hook
        readOnly: true
      - hostPath: /usr/bin/nvidia-container-cli
        containerPath: /usr/bin/nvidia-container-cli
        readOnly: true
      - hostPath: /usr/bin/nvidia-ctk
        containerPath: /usr/bin/nvidia-ctk
        readOnly: true
      - hostPath: /usr/bin/nvidia-smi
        containerPath: /usr/bin/nvidia-smi

      # ── nvidia-container-runtime config ─────────────────────────────────
      - hostPath: /etc/nvidia-container-runtime
        containerPath: /etc/nvidia-container-runtime
        readOnly: true

  # These two workers deliberately get none of the GPU worker's extraMounts —
  # no /dev/nvidia*, no toolkit binaries, no /opt/nvidia-libs. That's the
  # point: they represent ordinary CPU nodes in the pool.
  #
  # IMPORTANT — if you install the NVIDIA GPU Operator (Phase 9) against this
  # cluster, taint both of these nodes first (Phase 5: `no-gpu-runtime`).
  # Confirmed live: every kind node here is a container on the same physical
  # host, and PCI enumeration (/sys/bus/pci) is visible host-wide, so Node
  # Feature Discovery (and the Operator's own controller, independent of NFD)
  # labels ALL nodes nvidia.com/gpu.present=true — including these two and
  # the control-plane — not just gfn-prod-worker. Disabling NFD and manually
  # stripping the label does not reliably stop it from being reasserted, and
  # the ClusterPolicy CRD (chart v26.3.3) has no field to override per-
  # component node placement. Only a taint the Operator's DaemonSets don't
  # tolerate (i.e. not key nvidia.com/gpu) actually blocks scheduling here.
  - role: worker
    labels: { node-pool: cpu-general, tier: prod }

  - role: worker
    labels: { node-pool: cpu-general, tier: staging }
```

`terraform/variables.tf`:
```hcl
variable "cluster_name" {
  default = "gfn-prod"
}

locals {
  kind_config_path = "${path.module}/kind-config.yaml"
}
```

Note this is a `locals` block, not a `variable` — Terraform doesn't allow `${path.module}` as a `variable` block's `default` (must be a literal), only a runtime error you hit the first time you `terraform apply`. `main.tf` below references it as `local.kind_config_path`.

`terraform/main.tf`:
```hcl
terraform {
  required_version = ">= 1.7.0"
}

resource "null_resource" "kind_cluster" {
  triggers = {
    config_sha = filesha256(local.kind_config_path)
    name       = var.cluster_name
  }

  provisioner "local-exec" {
    command = "kind create cluster --name ${var.cluster_name} --config ${local.kind_config_path}"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "kind delete cluster --name ${self.triggers.name}"
  }
}

resource "null_resource" "refresh_gpu_node_ldcache" {
  depends_on = [null_resource.kind_cluster]

  triggers = {
    cluster_id = null_resource.kind_cluster.id
  }

  provisioner "local-exec" {
    # extraMounts bind-mounts driver libs into /opt/nvidia-libs on the GPU
    # worker, but a bind mount alone doesn't register that directory with the
    # node's dynamic linker. Without this, nvidia-smi can't find
    # libnvidia-ml.so, and neither can nvidia-container-cli, which resolves
    # driver libraries the same way when injecting them into pods that use
    # runtimeClassName: nvidia.
    command = "docker exec ${var.cluster_name}-worker ldconfig /opt/nvidia-libs"
  }
}

resource "null_resource" "export_kubeconfig" {
  depends_on = [null_resource.kind_cluster]

  provisioner "local-exec" {
    command = "kind export kubeconfig --name ${var.cluster_name}"
  }
}

resource "null_resource" "taint_non_gpu_workers" {
  depends_on = [null_resource.export_kubeconfig]

  triggers = {
    cluster_id = null_resource.kind_cluster.id
  }

  provisioner "local-exec" {
    # See Phase 5/Phase 9: every kind node here shares the host's PCI bus, so
    # NFD/the GPU Operator will label ALL nodes nvidia.com/gpu.present=true,
    # not just this one. That label can't be reliably fought (confirmed:
    # disabling NFD and stripping it by hand doesn't stick), so block
    # scheduling with a taint key the Operator's DaemonSets don't tolerate.
    # kubectl taint has no --overwrite flag (that's kubectl label).
    command = <<-EOT
      kubectl taint nodes ${var.cluster_name}-worker2 no-gpu-runtime:NoSchedule- || true
      kubectl taint nodes ${var.cluster_name}-worker2 no-gpu-runtime=true:NoSchedule
      kubectl taint nodes ${var.cluster_name}-worker3 no-gpu-runtime:NoSchedule- || true
      kubectl taint nodes ${var.cluster_name}-worker3 no-gpu-runtime=true:NoSchedule
    EOT
  }
}
```

**Why `filesha256` as a trigger?** So that editing `kind-config.yaml` and re-running `terraform apply` forces a recreate instead of Terraform assuming nothing changed (a `null_resource` has no real-world state to diff against — that's the tradeoff of the CLI-wrapping approach, and trainees should understand it explicitly rather than be surprised by it).

Run it:
```bash
cd terraform
terraform init
terraform plan
terraform apply
```

---

## Phase 3 — Verify the Cluster (CLI)

```bash
kubectl get nodes -o wide --show-labels
kubectl get nodes -l nvidia.com/gpu.present=true
```

Check the Docker-to-containerd handoff actually worked, from the host:
```bash
docker exec gfn-prod-worker nvidia-smi
```
If this fails, stop here — nothing above the Docker layer can work until this does. This isolates whether a problem is host/Docker-level (Phase 1) or Kubernetes-level (everything after).

---

## Phase 4 — The Missing Piece: `RuntimeClass` (Kubernetes object)

Neither of the two draft kind configs from Phase 2 created this, and it's the single most common gap in hand-written GPU cluster configs: registering a runtime with containerd (what the kind config patch did) is not the same as making it usable by name from a pod spec. You need a cluster-side `RuntimeClass` object whose `handler` matches the name from `containerdConfigPatches`.

`k8s/runtimeclass.yaml`:
```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: nvidia
handler: nvidia
```

```bash
kubectl apply -f k8s/runtimeclass.yaml
kubectl get runtimeclass
```

Only pods that set `spec.runtimeClassName: nvidia` will actually execute under the NVIDIA containerd runtime; everything else — including the original inference pod manifest as first written (Phase 7) — runs on plain `runc` regardless of what device mounts it has.

---

## Phase 5 — Taints and Labels (CLI)

Labels alone don't stop non-GPU pods from landing on the GPU node and wasting its capacity. The original inference pod manifest's toleration (`nvidia.com/gpu: Exists, NoSchedule`, shown in Phase 7) is meaningless unless a matching taint exists:

```bash
kubectl taint nodes gfn-prod-worker nvidia.com/gpu=present:NoSchedule
kubectl label nodes gfn-prod-worker nvidia.com/gpu.present=true --overwrite
kubectl describe node gfn-prod-worker | grep -A2 Taints
```

**Teaching point:** taint + toleration keeps *other* workloads off the GPU node; nodeSelector/label pulls the GPU workload *onto* it. You need both directions, and it's easy to configure only one and get confused about why scheduling doesn't behave as expected.

**Also taint the two non-GPU workers — required before Phase 9, not optional:** Node Feature Discovery (installed by the GPU Operator in Phase 9) and, we found by hand, the operator's own controller as well, will label `gfn-prod-worker2` and `gfn-prod-worker3` as `nvidia.com/gpu.present=true` too. This isn't a bug you can configure away — every `kind` worker is a container on the *same physical host*, and PCI device enumeration (`/sys/bus/pci`) is visible host-wide, not scoped per node container the way `/dev/nvidia*` is. NFD genuinely finds a real NVIDIA PCI device from every node and labels accordingly, and (confirmed live) even disabling NFD entirely and stripping the labels by hand doesn't make it stick — something in the operator stack keeps reasserting `nvidia.com/gpu.present=true` and the cascaded `nvidia.com/gpu.deploy.*` labels on all four nodes. Fighting that label is a losing battle. Taints aren't part of that label cascade, so they're the reliable lever:

```bash
kubectl taint nodes gfn-prod-worker2 no-gpu-runtime:NoSchedule- || true
kubectl taint nodes gfn-prod-worker2 no-gpu-runtime=true:NoSchedule
kubectl taint nodes gfn-prod-worker3 no-gpu-runtime:NoSchedule- || true
kubectl taint nodes gfn-prod-worker3 no-gpu-runtime=true:NoSchedule
kubectl describe node gfn-prod-worker2 | grep -A2 Taints
```

`kubectl taint` has no `--overwrite` flag — that's `kubectl label`; confirmed live, `kubectl taint ... --overwrite` fails immediately with `unknown flag: --overwrite` even on a taint that doesn't exist yet, since the flag itself is unrecognized. The `key:effect-` line removes any existing taint with that key/effect first (harmless no-op via `|| true` if none exists), then the next line adds it fresh — safe to run whether or not Terraform (Phase 2, `null_resource.taint_non_gpu_workers`) already applied it. That automation exists so the cluster is safe for Phase 9 even if someone jumps straight there; this manual run is for understanding what it actually did.

Use a taint key that is **not** `nvidia.com/gpu` — the GPU Operator's DaemonSets carry a blanket toleration for `key: nvidia.com/gpu, operator: Exists`, so reusing that key (even with a different value) would be tolerated and silently do nothing. `no-gpu-runtime` (or any other key nothing in the cluster tolerates) actually blocks scheduling regardless of what labels NFD or the operator assert.

---

## Phase 6 — NVIDIA Device Plugin (DaemonSet)

This is the "modern pattern" piece: it watches for GPUs and advertises `nvidia.com/gpu` as an allocatable resource so the scheduler can count it. On a normal cluster this component needs no privilege escalation — note that it carries `securityContext.privileged: true` below anyway. That's a `kind`-specific workaround, not a design choice; see the comment in the manifest and Phase 12 for why.

`k8s/device-plugin-ds.yaml`:
```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nvidia-device-plugin
  namespace: kube-system
spec:
  selector:
    matchLabels:
      name: nvidia-device-plugin
  template:
    metadata:
      labels:
        name: nvidia-device-plugin
    spec:
      runtimeClassName: nvidia
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      nodeSelector:
        nvidia.com/gpu.present: "true"
      containers:
        - name: nvidia-device-plugin-ctr
          image: nvcr.io/nvidia/k8s-device-plugin:v0.16.1
          # This node's /etc/nvidia-container-runtime/config.toml sets
          # no-cgroups = true (required because nvidia-container-cli can't
          # modify cgroups from inside a nested kind node). That disables
          # NVIDIA's own cgroup device grant, and this pod can't get one via
          # the normal resources.limits.nvidia.com/gpu route either — it's
          # what provides that resource in the first place. privileged: true
          # is the only way this container actually gets to open /dev/nvidia*
          # once no-cgroups is set; without it NVML fails with a generic
          # "Unknown Error" even though the device files are visible.
          securityContext:
            privileged: true
          env:
            - name: NVIDIA_VISIBLE_DEVICES
              value: "all"
            - name: NVIDIA_DRIVER_CAPABILITIES
              value: "all"
          volumeMounts:
            - name: device-plugin
              mountPath: /var/lib/kubelet/device-plugins
      volumes:
        - name: device-plugin
          hostPath:
            path: /var/lib/kubelet/device-plugins
```

```bash
kubectl apply -f k8s/device-plugin-ds.yaml
kubectl get pods -n kube-system -l name=nvidia-device-plugin
kubectl describe node gfn-prod-worker | grep -A8 "Allocatable:"
```

You should now see `nvidia.com/gpu: 1` under Allocatable — that's the scheduler's confirmation the whole chain (Docker toolkit → containerd runtime → RuntimeClass → device plugin) is wired correctly, and it's a much better verification checkpoint than "the pod happened to start."

---

## Phase 7 — Sample Workload: Fixing and Choosing a Pattern

Here's the original inference pod manifest this phase starts from, unmodified:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: gpu-inference-pod
  namespace: ai-workloads
  labels:
    app: inference
spec:
  tolerations:
    - key: "nvidia.com/gpu"
      operator: "Exists"
      effect: "NoSchedule"
  nodeSelector:
    nvidia.com/gpu.present: "true"
  initContainers:
    - name: model-loader
      image: busybox:1.36
      command: ["sh", "-c", "echo 'Load models here'; ls /models"]
      volumeMounts:
        - name: model-repository
          mountPath: /models
  containers:
    - name: inference
      image: nvcr.io/nvidia/tritonserver:24.01-py3
      command: ["tritonserver"]
      args:
        - "--model-repository=/models"
        - "--model-control-mode=poll"
        - "--repository-poll-secs=30"
        - "--http-port=8000"
        - "--grpc-port=8001"
        - "--metrics-port=8002"
        - "--log-verbose=1"
      ports:
        - containerPort: 8000
          name: http
        - containerPort: 8001
          name: grpc
        - containerPort: 8002
          name: metrics
      resources:
        limits:
          nvidia.com/gpu: 1
          memory: "4Gi"
        requests:
          nvidia.com/gpu: 1
          memory: "2Gi"
      env:
        - name: NVIDIA_VISIBLE_DEVICES
          value: "all"
        - name: NVIDIA_DRIVER_CAPABILITIES
          value: "compute,utility"
        - name: LD_LIBRARY_PATH
          value: "/opt/nvidia-libs:/usr/local/cuda/lib64:/usr/local/cuda/extras/CUPTI/lib64"
      securityContext:
        privileged: true
      readinessProbe:
        httpGet:
          path: /v2/health/ready
          port: 8000
        initialDelaySeconds: 15
        periodSeconds: 10
        failureThreshold: 6
      livenessProbe:
        httpGet:
          path: /v2/health/live
          port: 8000
        initialDelaySeconds: 30
        periodSeconds: 15
      volumeMounts:
        - name: model-repository
          mountPath: /models
        - name: nvidia-libs
          mountPath: /opt/nvidia-libs
          readOnly: true
        - name: dev-nvidia0
          mountPath: /dev/nvidia0
        - name: dev-nvidiactl
          mountPath: /dev/nvidiactl
        - name: dev-nvidia-uvm
          mountPath: /dev/nvidia-uvm
        - name: dev-nvidia-uvm-tools
          mountPath: /dev/nvidia-uvm-tools
        - name: dev-nvidia-smi-tools
          mountPath: /usr/bin/nvidia-smi
  volumes:
    - name: model-repository
      emptyDir: {}
    - name: nvidia-libs
      hostPath:
        path: /opt/nvidia-libs
        type: Directory
    - name: dev-nvidia0
      hostPath:
        path: /dev/nvidia0
    - name: dev-nvidiactl
      hostPath:
        path: /dev/nvidiactl
    - name: dev-nvidia-uvm
      hostPath:
        path: /dev/nvidia-uvm
    - name: dev-nvidia-uvm-tools
      hostPath:
        path: /dev/nvidia-uvm-tools
    - name: dev-nvidia-smi-tools
      hostPath:
        path: /usr/bin/nvidia-s
```

Two problems, one obvious and one architectural. First, the bug: the last `hostPath` truncates at `path: /usr/bin/nvidia-s` — it's missing `mi`. That volume would fail to mount as written. Second, the design decision from Section 2: this manifest requests `nvidia.com/gpu: 1` through `resources` (the modern, device-plugin-mediated pattern) *and* separately hostPath-mounts every device/library/binary by hand *and* runs `privileged: true` (the legacy, manual pattern) — all at once, in the same pod. Pick one GPU-access pattern, don't run both.

**Modern pattern (recommended, what you deploy in this training):**

`k8s/pod-inference-modern.yaml`:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: gpu-inference-pod
  namespace: ai-workloads
  labels:
    app: inference
spec:
  runtimeClassName: nvidia
  tolerations:
    - key: "nvidia.com/gpu"
      operator: "Exists"
      effect: "NoSchedule"
  nodeSelector:
    nvidia.com/gpu.present: "true"
  initContainers:
    - name: model-loader
      image: busybox:1.36
      command: ["sh", "-c", "echo 'Load models here'; ls /models"]
      volumeMounts:
        - name: model-repository
          mountPath: /models
  containers:
    - name: inference
      image: nvcr.io/nvidia/tritonserver:24.01-py3
      command: ["tritonserver"]
      args:
        - "--model-repository=/models"
        - "--model-control-mode=poll"
        - "--repository-poll-secs=30"
        - "--http-port=8000"
        - "--grpc-port=8001"
        - "--metrics-port=8002"
        - "--log-verbose=1"
      ports:
        - containerPort: 8000
          name: http
        - containerPort: 8001
          name: grpc
        - containerPort: 8002
          name: metrics
      # Required for actual cgroup access to /dev/nvidia* given this node's
      # no-cgroups = true nvidia-container-runtime config — see the matching
      # comment in device-plugin-ds.yaml and dcgm-exporter-ds.yaml. Without
      # this, NVML fails to init ("Unknown Error") even though the device
      # files and driver libraries are visibly injected into the container.
      securityContext:
        privileged: true
      resources:
        limits:
          nvidia.com/gpu: 1
          memory: "4Gi"
        requests:
          nvidia.com/gpu: 1
          memory: "2Gi"
      env:
        - name: NVIDIA_VISIBLE_DEVICES
          value: "all"
        - name: NVIDIA_DRIVER_CAPABILITIES
          value: "all"
      readinessProbe:
        httpGet:
          path: /v2/health/ready
          port: 8000
        initialDelaySeconds: 15
        periodSeconds: 10
        failureThreshold: 6
      livenessProbe:
        httpGet:
          path: /v2/health/live
          port: 8000
        initialDelaySeconds: 30
        periodSeconds: 15
      volumeMounts:
        - name: model-repository
          mountPath: /models
  volumes:
    - name: model-repository
      emptyDir: {}
```

Note what's still gone versus the legacy pattern: no manual `/dev/nvidia*` hostPath mounts, no manual `LD_LIBRARY_PATH`, no hardcoded paths at all — the `nvidia` RuntimeClass + device plugin discover and inject the right devices/libraries transparently via the `resources.limits.nvidia.com/gpu: 1` request, and the scheduler tracks GPU accounting for this pod (the legacy pod gets none of that).

What's *not* gone on this particular cluster: `securityContext.privileged: true`. On a normal (non-`kind`) cluster the modern pattern needs no privilege escalation at all — that's normally its main security win over legacy. Here it's required only because of `kind`'s nested-container `no-cgroups` limitation described in Section 2 and Phase 12; it is not an inherent property of the modern pattern.

Have trainees also deploy the **legacy pattern** (the original manifest shown above, with the path fixed and the two patterns *not* combined — strip the `resources.nvidia.com/gpu` request from it) so they can `diff` the two and see the actual security/complexity cost of the manual approach side by side.

```bash
kubectl create namespace ai-workloads
kubectl apply -f k8s/pod-inference-modern.yaml
kubectl get pods -n ai-workloads -w
kubectl logs -n ai-workloads gpu-inference-pod -c model-loader
kubectl exec -n ai-workloads gpu-inference-pod -- nvidia-smi
```

**Now deploy and test the legacy pattern alongside it** (`pod-inference-legacy.yaml` — fixed truncated path, `resources.nvidia.com/gpu` request stripped so it doesn't combine both patterns):

```bash
kubectl apply -f k8s/pod-inference-legacy.yaml
kubectl get pods -n ai-workloads -w
kubectl logs -n ai-workloads gpu-inference-pod-legacy -c model-loader
kubectl exec -n ai-workloads gpu-inference-pod-legacy -- nvidia-smi
```

Have trainees confirm it three ways. Note: `privileged: true` is present on **both** pods on this cluster (see the Section 2 caveat and Phase 12) so it is *not* a usable diff point here — the real structural differences are RuntimeClass usage, scheduler accounting, and hardcoded-vs-dynamic device wiring:

```bash
# 1. It runs on plain runc, not the nvidia RuntimeClass — no runtimeClassName is set in the manifest
kubectl get pod -n ai-workloads gpu-inference-pod-legacy -o jsonpath='{.spec.runtimeClassName}{"\n"}'
kubectl get pod -n ai-workloads gpu-inference-pod -o jsonpath='{.spec.runtimeClassName}{"\n"}'

# 2. It never touched the scheduler's GPU accounting — no nvidia.com/gpu in its resources, so Allocated GPU count is unaffected by this pod
kubectl get pod -n ai-workloads gpu-inference-pod-legacy -o jsonpath='{.spec.containers[0].resources}{"\n"}'
kubectl describe node gfn-prod-worker | grep -A10 "Allocated resources:"

# 3. It hardcodes hostPath device/lib/binary volumes instead of letting the RuntimeClass discover and inject them
kubectl get pod -n ai-workloads gpu-inference-pod-legacy -o jsonpath='{.spec.volumes[*].name}{"\n"}'
kubectl get pod -n ai-workloads gpu-inference-pod -o jsonpath='{.spec.volumes[*].name}{"\n"}'
```

```bash
# NOTE: kubectl diff -f a -f b does NOT compare the two files to each other —
# each file is independently diffed against its own live object, so with both
# pods already applied and unchanged this silently prints nothing. Use a plain
# file diff to actually compare the two patterns side by side:
diff k8s/pod-inference-legacy.yaml k8s/pod-inference-modern.yaml || true
```

**Teaching point:** the legacy pod starts and serves inference successfully — that's the trap. Nothing about the Triton logs or `nvidia-smi` output inside it looks different from the modern pod's. On a normal cluster the sharpest observable difference would be `privileged: true` itself; on *this* `kind` cluster that signal is muddied by the `no-cgroups` workaround both patterns need, so the durable differences are structural instead: no `runtimeClassName`, no scheduler-tracked `nvidia.com/gpu` accounting, and a fixed list of hand-picked `hostPath` volumes instead of dynamic device-plugin injection. This is why code review, not runtime behavior, is what catches the legacy pattern in practice — and also why an environment-specific workaround (like `no-cgroups`) can quietly erase the exact signal you were relying on to teach a security lesson, which is itself worth calling out to trainees.

---

## Phase 8 — "Sets": DaemonSet and StatefulSet Patterns

**DaemonSet** — one-per-node monitoring agent (used for real in Phase 11 as `dcgm-exporter`, introduced conceptually here):
```bash
kubectl get daemonsets -A
```
Ask trainees: why is the device plugin from Phase 6 a DaemonSet and not a Deployment? (Answer: it must run exactly once per GPU node, tied to that node's local device files — a Deployment's replica count has no relationship to node topology.)

**StatefulSet** — for a model-cache tier needing stable identity and persistent storage across restarts:

`k8s/model-cache-statefulset.yaml`:
```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: model-cache
  namespace: ai-workloads
spec:
  serviceName: model-cache
  replicas: 2
  selector:
    matchLabels:
      app: model-cache
  template:
    metadata:
      labels:
        app: model-cache
    spec:
      nodeSelector:
        nvidia.com/gpu.present: "true"
      tolerations:
        - key: "nvidia.com/gpu"
          operator: "Exists"
          effect: "NoSchedule"
      containers:
        - name: cache
          image: busybox:1.36
          command: ["sh", "-c", "sleep infinity"]
          volumeMounts:
            - name: cache-data
              mountPath: /cache
  volumeClaimTemplates:
    - metadata:
        name: cache-data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 5Gi
```

Ask trainees why this needs stable network identity (`model-cache-0`, `model-cache-1`) and per-replica storage instead of a Deployment: cache contents are tied to a specific replica, and losing that mapping on a restart defeats the purpose of caching.

---

## Phase 9 — "Operators": NVIDIA GPU Operator

Everything from Phases 4–6 (RuntimeClass wiring, device plugin, and — coming up — DCGM) can instead be managed by a single Operator, via a CRD called `ClusterPolicy`. This is what most production clusters use instead of hand-assembling manifests.

**Do not skip Phase 5's `no-gpu-runtime` taint on `gfn-prod-worker2`/`gfn-prod-worker3` before running this phase.** On a real (non-`kind`) cluster the Operator's node-selection is trustworthy — it labels nodes based on genuinely-per-node PCI visibility. On this cluster it is not: confirmed live, the Operator (via Node Feature Discovery, and independently of it) labels *every* node `nvidia.com/gpu.present=true`, including `gfn-prod-control-plane`, because all `kind` nodes share the one physical host's PCI bus. Worse, the `ClusterPolicy` CRD in chart `v26.3.3` (pinned explicitly below — this finding was confirmed against that exact version and may not hold on a different one) has **no** field to override per-component node placement — `kubectl explain clusterpolicy.spec --recursive` turns up exactly one `nodeSelector`, under `spec.runtimeClasses[]`, which is unrelated to DaemonSet scheduling. Disabling NFD (`--set nfd.enabled=false`) and manually stripping the mislabeled nodes' labels does not reliably stick — something in the Operator stack reasserts them. The only lever that actually holds is the taint from Phase 5, because none of the Operator's DaemonSets tolerate it.

Confirm the taint is actually there before installing — this is the one precondition everything below depends on:

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
```

`gfn-prod-worker2`/`gfn-prod-worker3` must show `no-gpu-runtime=true:NoSchedule`. If not, re-run Phase 5's taint commands (or `terraform apply` to let `null_resource.taint_non_gpu_workers` catch it) before continuing.

```bash
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update

helm install --wait gpu-operator \
  -n gpu-operator --create-namespace \
  nvidia/gpu-operator \
  --version v26.3.3 \
  --set driver.enabled=false \
  --set toolkit.enabled=false
```

`driver.enabled=false` and `toolkit.enabled=false` matter here specifically because of the kind architecture from Section 2: the host already owns the driver and toolkit (Ansible, Phase 1), and kind nodes share the host kernel — letting the Operator try to install its own driver container would conflict with what's already there. `--version v26.3.3` is pinned deliberately: the "no configurable `nodeSelector`" finding above is specific to this chart version's `ClusterPolicy` schema, and an unpinned `helm install` would silently pull whatever's newest whenever this training is run.

```bash
kubectl get clusterpolicy -o yaml
kubectl get pods -n gpu-operator -o wide
kubectl get nodes --show-labels | grep -o 'nvidia.com/gpu.present=[a-z]*'
```

Have trainees actually look at that last command's output: all four nodes will show `nvidia.com/gpu.present=true`, including `gfn-prod-worker2`/`gfn-prod-worker3` and the control-plane, confirming the mislabeling happens every time — it isn't a one-off fluke from the first pass through this training. Despite that, `kubectl get pods -n gpu-operator -o wide` should show every pod on `gfn-prod-worker` only. That gap — wrong label, right placement — is the taint doing its job.

If any `gpu-operator` namespace pod shows a node other than `gfn-prod-worker`, or is stuck in `Init:0/1` / `ContainerCreating` with `fork/exec /usr/bin/nvidia-container-runtime: no such file or directory` in its events, the Phase 5 taint either wasn't applied or was applied after the Operator already scheduled pods on the wrong nodes — delete the stray pods and let the DaemonSet controller reschedule; it will now correctly refuse to place them on the tainted nodes regardless of what labels they carry.

**Retire the hand-rolled Phase 6 device plugin once the Operator is confirmed healthy** — running two device plugins is a real conflict, not just redundant: both try to register `nvidia.com/gpu` with kubelet on the same node.

```bash
kubectl delete -f k8s/device-plugin-ds.yaml
```

**Do not delete `k8s/dcgm-exporter-ds.yaml`.** Unlike the device plugin, two `dcgm-exporter`s coexisting is harmless — just two independent Prometheus scrape targets, no shared registration to conflict over. More importantly, confirmed live in Phase 11: the Operator's own `dcgm-exporter` uses a `distroless` image with no shell and no `dcgmi` CLI at all, so it can't run the `dcgmi` walkthrough. The hand-rolled Ubuntu-based one is what Phase 11 actually depends on — keep it running.

**Teaching point:** compare `kubectl get pods -n gpu-operator` against what you built by hand in Phases 4–6 — the Operator is running a device plugin, a DCGM exporter, and node-feature-discovery pods for you. This is the point where trainees should understand *when* to reach for the Operator (production, ongoing fleet management) versus hand-written manifests (this training, understanding the mechanics, debugging when the Operator's abstraction breaks down) — and, from what this cluster just taught us, that the Operator's automation is only as trustworthy as the hardware-detection signal it's built on. `kind`'s shared-host-PCI-bus topology breaks that signal in a way a real multi-node cluster never would; a taint that doesn't depend on labels is what closes the gap.

---

## Phase 10 — `nvidia-smi` Mastery (CLI)

Run these both from the host and via `kubectl exec` into the inference pod, and compare:

```bash
nvidia-smi                                    # summary: driver/CUDA version, utilization, memory, processes
nvidia-smi -L                                 # list GPUs with UUIDs
nvidia-smi -q                                  # full query: clocks, ECC, power, PCIe
nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu --format=csv
nvidia-smi dmon                                # live rolling monitor (util%, mem%, temp, power)
nvidia-smi topo -m                             # GPU-to-GPU / GPU-to-NIC topology matrix
nvidia-smi -pm 1                               # persistence mode (needs privileged/host access)
```

```bash
kubectl exec -n ai-workloads gpu-inference-pod -- nvidia-smi
```

Have trainees run `nvidia-smi` inside the pod while Triton is loading a model, and again while idle, to connect the numbers to actual workload behavior.

---

## Phase 11 — DCGM Mastery (CLI)

If you deployed the GPU Operator in Phase 9, `dcgm-exporter` is already running. Otherwise, deploy it by hand:

`k8s/dcgm-exporter-ds.yaml`:
```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: dcgm-exporter
  namespace: kube-system
spec:
  selector:
    matchLabels:
      name: dcgm-exporter
  template:
    metadata:
      labels:
        name: dcgm-exporter
    spec:
      runtimeClassName: nvidia
      nodeSelector:
        nvidia.com/gpu.present: "true"
      tolerations:
        - key: "nvidia.com/gpu"
          operator: "Exists"
          effect: "NoSchedule"
      containers:
        - name: dcgm-exporter
          image: nvcr.io/nvidia/k8s/dcgm-exporter:3.3.5-3.4.1-ubuntu22.04
          # Required for DCGM diagnostics/profiling, and also the only way
          # this container gets actual cgroup access to /dev/nvidia* given
          # this node's no-cgroups = true nvidia-container-runtime config —
          # see the matching comment in device-plugin-ds.yaml.
          securityContext:
            privileged: true
          env:
            - name: NVIDIA_VISIBLE_DEVICES
              value: "all"
            - name: NVIDIA_DRIVER_CAPABILITIES
              value: "all"
          ports:
            - containerPort: 9400
              name: metrics
```

```bash
kubectl apply -f k8s/dcgm-exporter-ds.yaml
kubectl get pods -n kube-system -l name=dcgm-exporter
```

**`dcgmi` needs a running `nv-hostengine`, and `dcgm-exporter` doesn't start one for you.** This tripped us up live, worth understanding why: `dcgm-exporter` runs DCGM in *embedded* mode — an in-process instance purely for its own metrics scraping — not *standalone* mode, which is what exposes the socket an external `dcgmi` client connects to. The `dcgmi` binary being present in the container (it is, in the hand-rolled `dcgm-exporter-ds.yaml`'s Ubuntu-based image — confirmed **not** present at all in the GPU Operator's own `dcgm-exporter`, which uses a `distroless` image tag with no shell and no CLI tools beyond the exporter binary itself) doesn't mean there's anything for it to talk to.

**This is also why Phase 9 must not delete `k8s/dcgm-exporter-ds.yaml`, unlike `device-plugin-ds.yaml`.** The Operator's `dcgm-exporter` can't run this walkthrough at all (no `dcgmi`, no shell). Keep the hand-rolled one around specifically for Phase 11 — running two `dcgm-exporter`s side by side is harmless redundancy (two independent Prometheus scrape targets), not the real registration conflict two device plugins have.

Start `nv-hostengine` detached so it survives the `kubectl exec` session that launched it — a plain `kubectl exec -it ... -- nv-hostengine` followed by a second, separate `kubectl exec ... -- dcgmi ...` will fail, because closing the first exec session's channel kills everything spawned under it that wasn't explicitly detached:

```bash
kubectl exec dcgm-exporter-<pod-suffix> -n kube-system -- \
  sh -c "setsid /usr/bin/nv-hostengine > /tmp/nv-hostengine.log 2>&1 < /dev/null &"
sleep 2
kubectl exec dcgm-exporter-<pod-suffix> -n kube-system -- ps aux | grep nv-hostengine
```

Confirmed working once `nv-hostengine` is actually running:

```bash
dcgmi discovery -l              # list discovered GPUs and NVLinks
dcgmi group -c training-group   # create a GPU group for scoped monitoring
dcgmi health -g 0 --set a       # enable all health watches on group 0
dcgmi health -g 0 -c            # check health status of group 0
```

**`dcgmi dmon` needs an explicit target — it was never runnable bare.** Confirmed live: `dcgmi dmon` with no arguments fails with `Required argument missing: {field-group-id | field-id | list}`. It doesn't monitor a sensible default set on its own; you have to tell it what to watch via `-f <fieldGroupId>`, `-e <fieldId>`, or list what's available first:

```bash
dcgmi dmon -l   # list every valid field ID for this DCGM version — confirm before relying on the IDs below
```

Field IDs are version-specific in principle, but these were confirmed against this exact cluster's `dcgmi dmon -l` output and map onto exactly what the original "util, mem, temp, power, ECC errors" comment promised:

```bash
dcgmi dmon -e 203,204,150,155,252,300 -d 1000 -c 5
# 203 gpu_utilization, 204 mem_copy_utilization, 150 gpu_temp,
# 155 power_usage, 252 fb_used, 300 ecc — 1s delay, 5 samples
```

**`dcgmi diag` is a separate problem, not fixed by starting `nv-hostengine`.** `dcgm-exporter`'s image ships enough for metrics export, not the full diagnostic suite — `dcgmi diag -r 1` fails with `The NVVS binary was not found... please install it to /usr/share/nvidia-validation-suite/`. NVVS (NVIDIA Validation Suite) is what `diag` actually shells out to run health checks and stress tests, and it isn't bundled here. There's no container-side fix for this one; it needs the full `datacenter-gpu-manager` package installed directly on `basement-nas` (bare metal, not a container) — check package availability first (`apt-cache search datacenter-gpu-manager`) rather than assuming a specific repo/install command, since this hasn't been verified against this host yet:

```bash
dcgmi diag -r 1                 # quick health diagnostic — host-level DCGM install only
dcgmi diag -r 2                 # medium diagnostic (a few minutes)
dcgmi diag -r 3                 # long diagnostic (stress test, use sparingly)
```

**Teaching point:** `nvidia-smi` is point-in-time and human-facing; DCGM is built for continuous, scriptable, fleet-scale health monitoring — that's why `dcgm-exporter` exposes a `/metrics` endpoint on `:9400` for Prometheus rather than requiring someone to run a command by hand. Trainees should leave this phase able to explain when they'd reach for one tool versus the other.

---

## Phase 12 — Troubleshooting Playbook

| Symptom | Likely cause |
|---|---|
| `docker exec <node> nvidia-smi` fails | Docker-level toolkit not registered (Phase 1) — nothing above this layer will work |
| Pod stuck `Pending`, node shows no `nvidia.com/gpu` in Allocatable | Device plugin DaemonSet not running, or its `runtimeClassName` isn't set |
| `OCI runtime create failed ... nvidia-container-cli` | One of the four toolkit binaries (`runtime`, `hook`, `cli`, `ctk`) isn't mounted — check `extraMounts` |
| Pod ignores `runtimeClassName: nvidia` silently | No `RuntimeClass` object exists cluster-side (Phase 4) — containerd registration alone isn't enough |
| GPU node keeps getting non-GPU pods scheduled on it | Taint was never applied — a toleration alone doesn't attract or repel anything by itself |
| `hostPath` volume fails to mount | Typo'd path — this is literally the bug in the original inference pod manifest shown in Phase 7 (`/usr/bin/nvidia-s`) |
| `nvidia-smi` works on host but not in pod | Pod isn't using `runtimeClassName: nvidia` and has no manual device mounts — it's running on plain `runc` |
| `Failed to initialize NVML: Unknown Error` inside a `runtimeClassName: nvidia` pod, even though `/dev/nvidia*` and the driver `.so` files are visibly present and correctly injected | This node's `/etc/nvidia-container-runtime/config.toml` has `no-cgroups = true`, because `nvidia-container-cli` cannot manage cgroups from *inside* a nested `kind` node (the pod's cgroup is a child of the kind node container's own cgroup). File-level injection (bind-mounting devices/libraries) still works and looks correct, but the cgroup device *permission* grant never happens, so `open()` on the device nodes is denied even though the files themselves are world-readable. Fix: `securityContext.privileged: true` on the container — confirmed working, already applied in `device-plugin-ds.yaml`, `dcgm-exporter-ds.yaml`, and `pod-inference-modern.yaml`. This is specific to `kind`'s nested-container GPU passthrough; a normal cluster's device plugin would not need this. |
| GPU Operator (Phase 9) DaemonSet pods stuck `Init:0/1`/`ContainerCreating` on `gfn-prod-worker2`/`gfn-prod-worker3`, with `fork/exec /usr/bin/nvidia-container-runtime: no such file or directory` in events | Every `kind` node is a container on the *same physical host*, and PCI enumeration (`/sys/bus/pci`) is visible host-wide — so NFD (and the Operator's own controller, independent of NFD) labels *all* nodes `nvidia.com/gpu.present=true`, not just the one node with the toolkit binaries actually bind-mounted in (`extraMounts`, Phase 2). Confirmed live: `--set nfd.enabled=false` plus manually stripping the label does not reliably stop it from being reasserted. `ClusterPolicy` (chart `v26.3.3`) has no field to override per-component node placement (`kubectl explain clusterpolicy.spec --recursive` shows no usable `nodeSelector`). Fix: the `no-gpu-runtime` taint on the two non-GPU workers from Phase 5, applied *before* installing the Operator — taints aren't part of the label cascade the Operator controls, so they hold regardless. |
| `helm install --wait` for the GPU Operator hangs indefinitely | Confirmed live: `gpu-operator-node-feature-discovery-gc` (a generic, GPU-agnostic Deployment with no special tolerations) can become permanently unschedulable once both Phase 5 taints exist — `gfn-prod-worker` is tainted `nvidia.com/gpu=present`, `worker2`/`worker3` are tainted `no-gpu-runtime`, and control-plane carries the standard `node-role.kubernetes.io/control-plane` taint, leaving no untainted node for it to land on. This is a real, accepted side effect of the taint fix above, not a bug to chase further — the GC pod isn't required for any GPU functionality. Ctrl+C the hanging `helm install`; the release is already deployed regardless of what the CLI is still waiting on. |
| `dcgmi discovery -l` (or any `dcgmi` command) inside a `dcgm-exporter` pod says `unable to establish a connection to the specified host: localhost` | `dcgm-exporter` runs DCGM in *embedded* mode for its own metrics scraping, not *standalone* mode — no `nv-hostengine` is listening for external clients like `dcgmi` to connect to, even though the `dcgmi` binary itself may be present. Fix: start `nv-hostengine` detached with `setsid` (Phase 11) so it survives the `kubectl exec` session that launched it — a plain foreground start followed by a *second*, separate `kubectl exec` will fail, because closing the first exec session kills anything spawned under it that wasn't explicitly detached. |
| `dcgmi diag -r N` fails with `The NVVS binary was not found... please install it to /usr/share/nvidia-validation-suite/` | `dcgm-exporter`'s image (Operator's or hand-rolled) ships enough for metrics export, not the full diagnostic suite — NVVS, what `diag` actually shells out to, isn't bundled in either. No container-side fix; run `diag` from a full `datacenter-gpu-manager` install directly on `basement-nas` instead. |

---

## Phase 13 — Capstone Exercise

1. Add a second GPU worker node to the kind config, re-`terraform apply`, and confirm Terraform recreates the cluster (via the `filesha256` trigger).
2. Deploy a second replica of the modern-pattern inference pod and confirm the scheduler places one per GPU node (not both on the same one).
3. Run `dcgmi diag -r 3` against both nodes and produce a one-page health summary.
4. Deliberately break something (remove the `RuntimeClass`, or delete one toolkit binary mount) and have a partner trainee diagnose it using only the Phase 12 table and CLI output — no hints.

---

## Phase 14 — Cleanup

```bash
kubectl delete namespace ai-workloads
cd terraform
terraform destroy
```
(`terraform destroy` triggers the `local-exec` destroy provisioner, which runs `kind delete cluster`.)

---

## Suggested Schedule

| Day | Focus |
|---|---|
| 1 | Section 2 architecture discussion + Phase 1 (Ansible) + Phase 2–3 (Terraform, verify cluster) |
| 2 | Phase 4–6 (RuntimeClass, taints/labels, device plugin) — get to a real `nvidia.com/gpu` Allocatable |
| 3 | Phase 7 (fix and deploy the pod, legacy vs modern comparison) + Phase 8 (Sets) |
| 4 | Phase 9 (Operator) — budget the full day; the taint precondition, mislabeling verification, and hand-rolled-manifest retirement decisions each take real discussion time |
| 5 | Phase 10–11 (`nvidia-smi` / DCGM CLI drills, including the `nv-hostengine` and NVVS limitations) |
| 6 | Phase 12 troubleshooting drills + Phase 13 capstone + Phase 14 cleanup |

---

## Appendix: Corrected-File Summary

- **`kind-config.yaml`** — merged label strategy from both source files; single clean GPU worker block (Phase 2).
- **`runtimeclass.yaml`** — new; was missing entirely from both source configs (Phase 4).
- **`pod-inference-modern.yaml`** — fixed truncated hostPath, removed redundant manual-mount pattern in favor of `resources.limits.nvidia.com/gpu`, added `runtimeClassName: nvidia` (Phase 7). Still carries `securityContext.privileged: true` — not part of the legacy pattern it replaced, but required on this specific `kind` cluster due to the `no-cgroups` nested-container limitation (Phase 12).
- **`device-plugin-ds.yaml`**, **`dcgm-exporter-ds.yaml`** — both carry `securityContext.privileged: true` and `NVIDIA_DRIVER_CAPABILITIES: "all"` for the same `no-cgroups` reason as `pod-inference-modern.yaml` (Phase 12).
- **`main.tf`** — two `null_resource`s beyond basic cluster create/destroy: `refresh_gpu_node_ldcache` (registers `/opt/nvidia-libs` with the GPU worker's dynamic linker — a bind mount alone doesn't do this) and `taint_non_gpu_workers` (blocks the GPU Operator from scheduling onto `worker2`/`worker3` — see Phase 9/12) (Phase 2).
- Node taint command — new; the original toleration had nothing to match against (Phase 5). Extended to also taint `gfn-prod-worker2`/`gfn-prod-worker3` with `no-gpu-runtime`, required before Phase 9 (Phase 5, Phase 9).
