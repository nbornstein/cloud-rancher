# Registers the SUSE AI Factory downstream cluster with this Rancher
# management cluster. Uses the generic/imported-cluster resource rather than
# rancher2_cluster_v2 (which drives node provisioning itself via
# node_command/custom clusters) - our boot scripts install and start RKE2
# independently, before Rancher ever hears about this cluster, so there is no
# node provisioning for Rancher to drive.
resource "rancher2_cluster" "ai_factory" {
  count    = var.install_ai_factory ? 1 : 0
  provider = rancher2.admin

  name        = "ai-factory"
  description = "GPU-enabled downstream cluster for SUSE AI Factory"

  labels = {
    "ai-factory" = "true"
  }

  depends_on = [rancher2_bootstrap.admin]
}
