variable "name" {
  description = "The name of the DR S3 bucket to be created."
  type        = string
}
variable "context" {
  description = "Context object for tagging (project, environment, owner)."
  type        = any
}
variable "mirrored_acl" {
  description = "The ACL setting mirrored from the primary bucket."
  type        = string
}
variable "mirrored_versioning_status" {
  description = "The Versioning status mirrored from the primary bucket (e.g., 'Enabled')."
  type        = string
}
variable "mirrored_pab_config" {
  description = "Public Access Block configuration mirrored from the primary bucket."
  type        = any
}
variable "website_configuration" {
  description = "Website configuration data (index/error document), if present on the primary."
  type        = any
  default     = null
}
variable "replication_configuration" {
  description = "The CRR configuration for failback (DR to Primary)."
  type = object({
    rules = list(object({
      id                             = string
      status                         = string
      priority                       = number
      delete_marker_replication_status = string
      destinations = list(object({
        bucket_arn    = string
        storage_class = string
      }))
      filter = object({ prefix = string })
    }))
  })
}
variable "replication_iam" {
  description = "IAM role and policy naming details for replication."
  type        = any
}
variable "mrap_name" {
  description = "The desired name for the Multi-Region Access Point."
  type        = string
}
variable "mrap_regions" {
  description = "List of bucket ARNs/details to include in the MRAP."
  type        = list(any)
}

variable "primary_versioning_id" {
  description = "The ID of the versioning resource for the primary bucket, used for explicit dependency to resolve eventual consistency for CRR."
  type        = string
}