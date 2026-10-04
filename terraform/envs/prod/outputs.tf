output "instance_id" {
  value = aws_instance.gpu.id
}

output "node_name" {
  description = "Stable Kubernetes node name planned for kubeadm join; not an AWS hostname."
  value       = local.gpu_node_name
}

output "availability_zone" {
  description = "Placement recorded with each GPU experiment."
  value       = aws_instance.gpu.availability_zone
}

output "private_ip" {
  description = "AWS VPC address for diagnosis only; the Kubernetes InternalIP will use the reviewed Tailscale address."
  value       = aws_instance.gpu.private_ip
}

output "public_ip" {
  description = "고정 관리 주소(EIP). vLLM endpoint가 아니며 SSH는 명시한 관리자 /32만 허용한다."
  value       = aws_eip.gpu.public_ip
}

output "vpc_id" {
  value = aws_vpc.lab.id
}

output "security_group_id" {
  value = aws_security_group.gpu.id
}

output "router_instance_id" {
  description = "Null until the separate AWS router is enabled and created."
  value       = one(aws_instance.router[*].id)
}

output "router_subnet_id" {
  description = "Separate router subnet; null while router_enabled is false."
  value       = one(aws_subnet.router[*].id)
}

output "router_private_ip" {
  description = "VPC address for the router; not a Kubernetes Node InternalIP."
  value       = one(aws_instance.router[*].private_ip)
}

output "router_public_ip" {
  description = "Temporary public IPv4 for bootstrap; not an application endpoint."
  value       = one(aws_instance.router[*].public_ip)
}

output "site_probe_private_ip" {
  description = "시험 EC2의 VPC 사설 주소. site_probe_enabled가 false이면 null이다."
  value       = one(aws_instance.site_probe[*].private_ip)
}
