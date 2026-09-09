output "instance_id" {
  value = aws_instance.gpu.id
}

output "public_ip" {
  description = "Bootstrap address only; may change after stop/start. Not a vLLM endpoint."
  value       = aws_instance.gpu.public_ip
}

output "vpc_id" {
  value = aws_vpc.lab.id
}

output "security_group_id" {
  value = aws_security_group.gpu.id
}
