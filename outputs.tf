output "vpc_id" {
  description = "ID of the created VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "Primary CIDR block of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "subnet_ids" {
  description = "Map of subnet key (as given in var.subnets) to subnet ID."
  value       = { for k, s in aws_subnet.this : k => s.id }
}

output "subnet_ids_by_type" {
  description = "Subnet IDs grouped by \"public\"/\"private\"."
  value = {
    for type in ["public", "private"] :
    type => [for k, s in var.subnets : aws_subnet.this[k].id if s.type == type]
  }
}

output "route_table_ids" {
  description = "Map of route table key (as given in var.route_tables) to route table ID."
  value       = { for k, rt in aws_route_table.this : k => rt.id }
}

output "nat_gateway_ids" {
  description = "Map of AZ to NAT gateway ID (empty if NAT is disabled)."
  value       = { for az, n in aws_nat_gateway.this : az => n.id }
}
