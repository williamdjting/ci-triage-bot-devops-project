# ---------------------------------------------------------------------------
# Layer 1: the cluster itself.
#
# This mirrors kind/cluster.yaml in HCL. Terraform is now the source of truth;
# kind/cluster.yaml is kept only as the manual escape hatch documented in
# k8s/README.md. If you change one, change the other.
# ---------------------------------------------------------------------------

resource "kind_cluster" "this" {
  name           = var.cluster_name
  node_image     = var.node_image
  wait_for_ready = true

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    node {
      role = "control-plane"

      # ingress-nginx (layer 2) has a nodeSelector on this label, so the
      # controller lands on the one node with the host port mappings below.
      kubeadm_config_patches = [
        <<-PATCH
          kind: InitConfiguration
          nodeRegistration:
            kubeletExtraArgs:
              node-labels: "ingress-ready=true"
        PATCH
      ]

      # Without these, the kind node is a Docker container whose ports are
      # unreachable from macOS. This is what makes localhost:8080 work.
      extra_port_mappings {
        container_port = 80
        host_port      = var.http_host_port
        protocol       = "TCP"
      }

      extra_port_mappings {
        container_port = 443
        host_port      = var.https_host_port
        protocol       = "TCP"
      }
    }

    # dynamic: worker_count is a variable, so the node blocks are generated
    # rather than copy-pasted.
    dynamic "node" {
      for_each = range(var.worker_count)
      content {
        role = "worker"
      }
    }
  }
}
