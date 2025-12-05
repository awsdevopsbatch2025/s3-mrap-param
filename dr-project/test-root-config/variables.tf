variable "context" {
  description = "The context (e.g., tags, account info) to apply to resources."
  type = object({
    project     = string
    environment = string
    owner       = string
  })
  default = {
    project     = "dr-s3"
    environment = "dev"
    owner       = "terraform"
  }
}

variable "region_primary" {
  description = "The AWS region for the primary bucket (e.g., us-east-1)."
  type        = string
  # Added default value:
  default = "us-east-1"
}

variable "region_dr" {
  description = "The AWS region for the disaster recovery bucket (e.g., us-east-2)."
  type        = string
  # Added default value:
  default = "us-east-2"
}

variable "mrap_control_plane_region" {
  description = "The region where S3 Control Plane operations (like MRAP traffic dial) must be executed."
  type        = string
  # This must be one of the regions that supports S3 Control Plane, typically us-east-1 or us-west-2.
  default     = "us-east-1" 
}