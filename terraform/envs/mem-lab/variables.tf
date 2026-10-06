variable "expected_account_id" {
  description = "Explicit target AWS account; authenticate outside Terraform (e.g. AWS_PROFILE)."
  type        = string
  # Not a credential, but keeping the account number out of CLI output, plan diffs and CI
  # logs costs nothing.
  sensitive = true
  validation {
    condition     = can(regex("^[0-9]{12}$", var.expected_account_id))
    error_message = "Provide the verified 12-digit target account ID."
  }
}

variable "ami_id" {
  description = "Pinned Canonical Ubuntu 24.04 amd64 server AMI in Seoul. No latest lookup."
  type        = string
  validation {
    condition     = can(regex("^ami-[0-9a-f]{17}$", var.ami_id))
    error_message = "Provide a reviewed AMI ID."
  }
}

variable "availability_zone" {
  description = "Seoul AZ offering t3a.medium; an offering does not guarantee capacity."
  type        = string
  validation {
    condition     = can(regex("^ap-northeast-2[a-z]$", var.availability_zone))
    error_message = "Select a Seoul availability zone after checking offerings."
  }
}

variable "vpc_cidr" {
  description = "Reviewed RFC1918 IPv4 /16 for this lab VPC. Overlap is checked against reserved_cidrs, not assumed."
  type        = string
  # This checks the SHAPE only. Whether the block actually collides with the home LAN, the
  # Pod/Service CIDRs or the GPU VPC candidate is decided by the reserved_cidrs gate in
  # main.tf, because a regex cannot compare ranges.
  validation {
    condition = can(cidrnetmask(var.vpc_cidr)) && can(regex("/16$", var.vpc_cidr)) && can(regex(
      "^(10\\.[0-9]+|172\\.(1[6-9]|2[0-9]|3[01])|192\\.168)\\.0\\.0/16$", var.vpc_cidr
    ))
    error_message = "Use a canonical RFC1918 /16 before the overlap gate can evaluate it."
  }
}

variable "reserved_cidrs" {
  description = "Every IPv4 range this lab VPC must not overlap: home LAN, Pod CIDR, Service CIDR, GPU VPC candidate. Read each from the live cluster; there is no default."
  type        = list(string)
  # Deliberately required, with no default.
  #
  # The home LAN (192.168.50.0/24) and the Pod CIDR (10.244.0.0/16) are recorded in this
  # repository, but the Service CIDR is not -- only the kube-dns address 10.96.0.10, from which
  # the prefix length cannot be derived. Guessing /12 or /16 there would hard-code an
  # unverified range into the safety gate and make it look stronger than it is. So the operator
  # supplies all four, read from the control plane at the time of planning.
  validation {
    condition     = length(var.reserved_cidrs) > 0
    error_message = "List the ranges to protect; an empty list would make the overlap gate vacuous."
  }
  # `cidrnetmask` is the complete IPv4 gate here, and the overlap arithmetic in main.tf needs
  # exactly that: it splits on "." and expects four octets. Verified in `terraform console` that
  # it returns an error -- so `can(...)` is false -- for an IPv6 prefix, a missing prefix length
  # and a prefix above /32.
  #
  # Do not add a second check that calls cidrhost() on these values. cidrhost() raises a hard
  # "Error in function call" on a malformed entry instead of failing this validation, so the
  # operator sees an opaque function error rather than the message below. The test run
  # `malformed_reserved_cidr_rejected` covers this.
  validation {
    condition     = alltrue([for cidr in var.reserved_cidrs : can(cidrnetmask(cidr))])
    error_message = "Each reserved entry must be a valid IPv4 CIDR block; IPv6 ranges are not supported by the overlap gate."
  }
}

variable "ssh_public_key" {
  description = "Dedicated OpenSSH public key only. Never provide a private key."
  type        = string
  validation {
    condition     = can(regex("^(ssh-ed25519|ssh-rsa) [A-Za-z0-9+/]+={0,3}( .*)?$", trimspace(var.ssh_public_key)))
    error_message = "Supply a single-line OpenSSH public key (ed25519 or RSA)."
  }
}

variable "bootstrap_ssh_cidr" {
  description = "Optional administrator public IPv4 /32 for initial SSH. Null closes public SSH."
  type        = string
  default     = null
  nullable    = true
  validation {
    condition     = var.bootstrap_ssh_cidr == null ? true : can(cidrnetmask(var.bootstrap_ssh_cidr)) && can(regex("/32$", var.bootstrap_ssh_cidr))
    error_message = "Public SSH may allow only one IPv4 /32, or null."
  }
}

variable "tailscale_peer_cidrs" {
  description = "Optional peer public IPv4 /32 addresses allowed to UDP 41641. Not tailnet 100.x addresses."
  type        = set(string)
  default     = []
  validation {
    condition     = alltrue([for cidr in var.tailscale_peer_cidrs : can(cidrnetmask(cidr)) && can(regex("/32$", cidr))])
    error_message = "Each Tailscale peer source must be an IPv4 /32; broad public ingress is not allowed."
  }
}

variable "launch_review_confirmed" {
  description = "Manual acknowledgement of cost, AZ offering, CIDR review and teardown plan; not an automatic check."
  type        = bool
  default     = false
}
