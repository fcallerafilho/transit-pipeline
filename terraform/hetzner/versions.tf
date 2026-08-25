# Layer A — machine provisioning (DESIGN §6).
# Cloud-specific and deliberately thin. Everything that RUNS on the machine is
# Layer B (bootstrap/ + k8s/) and is byte-identical across hosts.
terraform {
  required_version = ">= 1.8"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.48"
    }
  }
}

# Token comes from the HCLOUD_TOKEN environment variable, never from a .tfvars
# file — DESIGN §12: no secrets in the repo, ever.
provider "hcloud" {}
