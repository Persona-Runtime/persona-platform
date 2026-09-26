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
