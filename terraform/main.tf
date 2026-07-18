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
    # node's dynamic linker. Without this, `nvidia-smi` can't find
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
    # Every kind node here is a container on the same physical host, so PCI
    # enumeration (/sys/bus/pci) is visible host-wide — Node Feature Discovery
    # (and the GPU Operator's own controller, Phase 9) labels ALL nodes
    # nvidia.com/gpu.present=true, not just the one with the toolkit
    # extraMounts, which schedules GPU-Operator DaemonSets onto workers that
    # can't actually run them. That label can't be reliably fought — disabling
    # NFD and manually stripping the label doesn't stick (confirmed live) —
    # so block scheduling with a taint key the Operator's DaemonSets don't
    # tolerate instead. Must not be `nvidia.com/gpu`: the Operator's
    # DaemonSets carry a blanket toleration for that key regardless of value.
    # kubectl taint has no --overwrite flag (that's kubectl label). A
    # multi-line heredoc here previously broke on this Windows-edited repo's
    # CRLF line endings — local-exec passed the embedded \r straight into the
    # shell command, so "|| true" became the unrecognized command "true\r"
    # and "NoSchedule" became the invalid effect "NoSchedule\r". A single-line
    # command has no embedded newline for a stray \r to hide in, and this
    # resource only ever runs once against a freshly created cluster (see
    # cluster_id trigger below) so there's never a pre-existing taint to
    # worry about overwriting.
    command = "kubectl taint nodes ${var.cluster_name}-worker2 no-gpu-runtime=true:NoSchedule && kubectl taint nodes ${var.cluster_name}-worker3 no-gpu-runtime=true:NoSchedule"
  }
}