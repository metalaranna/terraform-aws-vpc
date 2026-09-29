variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Name prefix applied to VPC-level resources (the VPC itself, IGW, flow log group)."
  type        = string
  default     = "app"
}

variable "vpc_cidr" {
  description = "Primary CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "secondary_cidr_blocks" {
  description = "Optional additional CIDR blocks to associate with the VPC (useful for growing past the primary block, e.g. a second /22 for another environment)."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Subnets: fully parameterized, no hardcoded environment/service names.
# Each entry becomes one aws_subnet. `route_table` must match a key in
# var.route_tables.
# ---------------------------------------------------------------------------
variable "subnets" {
  description = "Map of subnets to create. Key is an arbitrary logical name; `name` is the resource Name tag."
  type = map(object({
    name         = string
    cidr         = string
    az           = string
    type         = string           # "public" or "private"
    route_table  = string           # key into var.route_tables
    tags         = optional(map(string), {})
  }))

  validation {
    condition     = alltrue([for s in values(var.subnets) : contains(["public", "private"], s.type)])
    error_message = "Each subnet's type must be \"public\" or \"private\"."
  }

  validation {
    condition     = alltrue([for s in values(var.subnets) : contains(keys(var.route_tables), s.route_table)])
    error_message = "Each subnet's route_table must match a key in var.route_tables."
  }
}

# ---------------------------------------------------------------------------
# Route tables: one per logical group (e.g. one per tier, per service, per
# environment) rather than one hardcoded public/private pair. Public tables
# route to the IGW; private tables route to NAT (if enabled) plus any
# custom_routes you list (e.g. toward a Transit Gateway).
# ---------------------------------------------------------------------------
variable "route_tables" {
  description = "Map of route tables to create. Key is referenced by var.subnets[*].route_table."
  type = map(object({
    name = string
    type = string # "public" or "private"
    az = optional(string) # For "private" tables: which AZ's NAT gateway to route the default 0.0.0.0/0 route through. Ignored if type = "public", or if enable_nat_gateway = false. If omitted, falls back to the single/first NAT gateway.
    custom_routes = optional(list(object({
      cidr        = string
      target_type = string # "tgw" (more target types can be added as needed)
    })), [])
  }))

  validation {
    condition     = alltrue([for rt in values(var.route_tables) : contains(["public", "private"], rt.type)])
    error_message = "Each route table's type must be \"public\" or \"private\"."
  }
}

variable "transit_gateway_id" {
  description = "Transit Gateway ID to attach and route toward, when any route_tables entry uses a custom_routes target_type of \"tgw\". Leave null if you don't use custom TGW routes."
  type        = string
  default     = null
}

variable "enable_nat_gateway" {
  description = "Create NAT gateway(s) so private subnets can reach the internet."
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "Use a single NAT gateway for all private subnets instead of one per AZ. Cheaper, less resilient."
  type        = bool
  default     = false
}

variable "enable_flow_logs" {
  description = "Send VPC flow logs to CloudWatch Logs."
  type        = bool
  default     = true
}

variable "flow_log_retention_days" {
  description = "Retention period, in days, for the VPC flow log group."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Additional tags applied to all resources."
  type        = map(string)
  default     = {}
}
