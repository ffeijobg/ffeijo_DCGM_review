variable "cluster_name" {
  default = "gfn-prod"
}

locals {
  kind_config_path = "${path.module}/kind-config.yaml"
}