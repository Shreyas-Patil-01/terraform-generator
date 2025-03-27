output "instance_id" {
  value       = aws_instance.app_instance.id
  description = "ID of the EC2 instance"
}

output "instance_public_ip" {
  value       = aws_eip.app_eip.public_ip
  description = "Public IP address of the EC2 instance"
}

output "application_url" {
  value       = "http://\${aws_eip.app_eip.public_ip}"
  description = "URL to access the Terraform Generator application"
}