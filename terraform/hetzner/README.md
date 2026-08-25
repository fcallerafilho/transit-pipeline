# Layer A — Hetzner

Provisions the single VM that Layer B runs on. Roughly forty lines, cloud-specific,
and disposable: swapping to another provider means rewriting this directory and
nothing else (DESIGN §6).

**The host was chosen at DESIGN §9.4 step 6.** Oracle Cloud A1 Always Free was the
first choice and had no capacity for the required shape — the exact risk §8 flags.
Hetzner was the documented fallback and took minutes.

## The server already exists

It was created by hand in the Hetzner console before this module was written, so
the module is reconciled to reality by import rather than by `apply`. That is the
intended path — recreating a box that is already accruing runtime would reset the
clock DESIGN §9.3 depends on.

```sh
export HCLOUD_TOKEN=...            # read/write, project-scoped. Never in a file.
terraform init

# Find the existing IDs:
curl -sH "Authorization: Bearer $HCLOUD_TOKEN" https://api.hetzner.cloud/v1/servers  | python -m json.tool
curl -sH "Authorization: Bearer $HCLOUD_TOKEN" https://api.hetzner.cloud/v1/ssh_keys | python -m json.tool

terraform import hcloud_server.transit  <server-id>
terraform import hcloud_ssh_key.operator <ssh-key-id>
```

Then **converge to an empty plan**:

```sh
terraform plan
```

Adjust `terraform.tfvars` until the plan reports no changes. The firewall does not
exist yet, so the first real `apply` creates it and attaches it to the server —
that is the one intended change.

> **Read the plan before applying.** `image` and `location` are replacement-forcing
> attributes: if they do not match the live server, Terraform will propose
> destroying and recreating it. `prevent_destroy = true` on the server is there to
> turn that mistake into an error instead of an outage, but it is a backstop, not
> a substitute for reading the diff.

## What this module deliberately does not do

No k3s, no Docker, no application config, no `user_data` bootstrap. All of that is
Layer B (`bootstrap/` and `k8s/`) and must stay identical across hosts — DESIGN §12.
