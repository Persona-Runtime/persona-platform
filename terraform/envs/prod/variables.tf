variable "expected_account_id" {
  description = "Explicit target AWS account; authenticate outside Terraform (e.g. AWS_PROFILE)."
  type        = string
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
  description = "Seoul AZ with a g6.xlarge offering; offering does not guarantee capacity."
  type        = string
  validation {
    condition     = can(regex("^ap-northeast-2[a-z]$", var.availability_zone))
    error_message = "Select a Seoul availability zone after checking offerings."
  }
}

variable "vpc_cidr" {
  description = "Reviewed RFC1918 IPv4 /16, non-overlapping with home LAN, Pod, Service and other routes."
  type        = string
  validation {
    condition = can(cidrnetmask(var.vpc_cidr)) && can(regex("/16$", var.vpc_cidr)) && can(regex(
      "^(10\\.[0-9]+|172\\.(1[6-9]|2[0-9]|3[01])|192\\.168)\\.0\\.0/16$", var.vpc_cidr
    ))
    error_message = "Use a canonical RFC1918 /16 after checking route overlaps."
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
  description = "Manual acknowledgement of quota, AMI/AZ, routing, access and cost review; not an automatic quota check."
  type        = bool
  default     = false
}
