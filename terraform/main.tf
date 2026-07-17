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