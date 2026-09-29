provider "aws" {
  region = var.region

  default_tags {
    tags = merge(
      {
        Project   = var.name
        ManagedBy = "terraform"
      },
      var.tags
    )
  }
}

# ---------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = var.name
  }
}

resource "aws_vpc_ipv4_cidr_block_association" "secondary" {
  for_each = toset(var.secondary_cidr_blocks)

  vpc_id     = aws_vpc.this.id
  cidr_block = each.value
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name}-igw"
  }
}

# ---------------------------------------------------------------------------
# Subnets — fully driven by var.subnets, no hardcoded names or CIDRs.
# depends_on the secondary CIDR associations so a subnet CIDR carved out of
# a secondary block doesn't fail with "InvalidSubnet.Range".
# ---------------------------------------------------------------------------
resource "aws_subnet" "this" {
  for_each = var.subnets

  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.value.az
  cidr_block               = each.value.cidr
  map_public_ip_on_launch = each.value.type == "public"

  tags = merge(
    { Name = each.value.name, Tier = each.value.type },
    each.value.tags
  )

  depends_on = [aws_vpc_ipv4_cidr_block_association.secondary]
}

# ---------------------------------------------------------------------------
# NAT: one EIP + NAT gateway per AZ that has at least one public subnet, or
# a single shared one if single_nat_gateway = true.
# ---------------------------------------------------------------------------
locals {
  public_azs = distinct([for s in values(var.subnets) : s.az if s.type == "public"])
  nat_azs    = var.enable_nat_gateway ? (var.single_nat_gateway ? slice(local.public_azs, 0, min(1, length(local.public_azs))) : local.public_azs) : []

  # First public subnet found in each AZ — used as the NAT gateway's home subnet.
  first_public_subnet_key_by_az = {
    for az in local.public_azs :
    az => [for k, s in var.subnets : k if s.type == "public" && s.az == az][0]
  }
}

resource "aws_eip" "nat" {
  for_each = toset(local.nat_azs)
  domain   = "vpc"

  tags = {
    Name = "${var.name}-nat-eip-${each.key}"
  }
}

resource "aws_nat_gateway" "this" {
  for_each = toset(local.nat_azs)

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.this[local.first_public_subnet_key_by_az[each.key]].id

  tags = {
    Name = "${var.name}-nat-${each.key}"
  }

  depends_on = [aws_internet_gateway.this]
}

# ---------------------------------------------------------------------------
# Route tables — one per entry in var.route_tables, not one per AZ. Public
# tables get a default route to the IGW. Private tables get a default route
# to a NAT gateway (chosen by the table's optional `az`, falling back to the
# single/first NAT gateway) plus any custom_routes toward the Transit Gateway.
# ---------------------------------------------------------------------------
locals {
  default_nat_gateway_id = length(aws_nat_gateway.this) > 0 ? values(aws_nat_gateway.this)[0].id : null
}

resource "aws_route_table" "this" {
  for_each = var.route_tables

  vpc_id = aws_vpc.this.id

  tags = {
    Name = each.value.name
  }
}

resource "aws_route" "public_default" {
  for_each = { for k, rt in var.route_tables : k => rt if rt.type == "public" }

  route_table_id         = aws_route_table.this[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id              = aws_internet_gateway.this.id
}

resource "aws_route" "private_default_nat" {
  for_each = var.enable_nat_gateway ? { for k, rt in var.route_tables : k => rt if rt.type == "private" } : {}

  route_table_id         = aws_route_table.this[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id          = each.value.az != null && contains(local.nat_azs, each.value.az) ? aws_nat_gateway.this[each.value.az].id : local.default_nat_gateway_id
}

resource "aws_route" "custom" {
  for_each = {
    for pair in flatten([
      for rt_key, rt in var.route_tables : [
        for idx, route in rt.custom_routes : {
          key         = "${rt_key}-${idx}"
          rt_key      = rt_key
          cidr        = route.cidr
          target_type = route.target_type
        }
      ]
    ]) : pair.key => pair
  }

  route_table_id         = aws_route_table.this[each.value.rt_key].id
  destination_cidr_block = each.value.cidr

  # Extend this ternary if you add more target_type values.
  transit_gateway_id = each.value.target_type == "tgw" ? var.transit_gateway_id : null

  lifecycle {
    precondition {
      condition     = each.value.target_type != "tgw" || var.transit_gateway_id != null
      error_message = "route_tables[\"${each.value.rt_key}\"] has a custom_routes entry with target_type \"tgw\" but var.transit_gateway_id is null."
    }
  }
}

resource "aws_route_table_association" "this" {
  for_each = var.subnets

  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.this[each.value.route_table].id
}

# ---------------------------------------------------------------------------
# VPC flow logs
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name              = "/vpc/${var.name}/flow-logs"
  retention_in_days = var.flow_log_retention_days
}

data "aws_iam_policy_document" "flow_logs_assume" {
  count = var.enable_flow_logs ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name               = "${var.name}-vpc-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume[0].json
}

data "aws_iam_policy_document" "flow_logs_permissions" {
  count = var.enable_flow_logs ? 1 : 0

  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.flow_logs[0].arn}:*"]
  }
}

resource "aws_iam_role_policy" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name   = "${var.name}-vpc-flow-logs"
  role   = aws_iam_role.flow_logs[0].id
  policy = data.aws_iam_policy_document.flow_logs_permissions[0].json
}

resource "aws_flow_log" "this" {
  count = var.enable_flow_logs ? 1 : 0

  vpc_id                   = aws_vpc.this.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination           = aws_cloudwatch_log_group.flow_logs[0].arn
  iam_role_arn             = aws_iam_role.flow_logs[0].arn
  max_aggregation_interval = 600

  tags = {
    Name = "${var.name}-flow-log"
  }
}
