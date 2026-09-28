output "vpc_id" {
  description = "ID of the created VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Map of AZ to public subnet ID."
  value       = { for az, s in aws_subnet.public : az => s.id }
}

output "private_subnet_ids" {
  description = "Map of AZ to private subnet ID."
  value       = { for az, s in aws_subnet.private : az => s.id }
}

output "nat_gateway_ids" {
  description = "Map of AZ to NAT gateway ID (empty if NAT is disabled)."
  value       = { for az, n in aws_nat_gateway.this : az => n.id }
}

output "public_route_table_id" {
  description = "ID of the public route table."
  value       = aws_route_table.public.id
}

output "private_route_table_ids" {
  description = "Map of AZ to private route table ID."
  value       = { for az, rt in aws_route_table.private : az => rt.id }
}
