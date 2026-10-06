# 출력에는 식별자와 주소만 둔다. tailnet auth key·kubeadm token·CA hash는 이 환경이 받지도
# 출력하지도 않는다 — output에 넣으면 state와 `terraform output` 기록에 남는다.

output "instance_id" {
  value = aws_instance.mem.id
}

output "node_name" {
  description = "Kubernetes node name planned for kubeadm join; not an AWS hostname."
  value       = local.mem_node_name
}

output "instance_type" {
  description = "Recorded with every MEM-01 run: allocatable memory follows from this."
  value       = aws_instance.mem.instance_type
}

output "availability_zone" {
  value = aws_instance.mem.availability_zone
}

output "private_ip" {
  description = "AWS VPC address for diagnosis only; the Kubernetes InternalIP will use the reviewed Tailscale address."
  value       = aws_instance.mem.private_ip
}

output "public_ip" {
  description = "Bootstrap SSH address only; may change after stop/start."
  value       = aws_instance.mem.public_ip
}

output "vpc_id" {
  value = aws_vpc.lab.id
}

output "security_group_id" {
  value = aws_security_group.mem.id
}

output "reserved_cidrs_checked" {
  description = "The ranges the overlap gate compared against. Recorded so a run can be audited later; an entry missing here was never checked."
  value       = var.reserved_cidrs
}
