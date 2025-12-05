# ---------------------------------------------------
# Providers: Primary Region (us-east-1) and DR Region (us-east-2)
# ---------------------------------------------------

provider "aws" {
  alias = "primary"
  # This is your main region where existing buckets reside
  region = "us-east-1"
}

provider "aws" {
  alias = "dr"
  # This is your Disaster Recovery region where new buckets will be created
  region = "us-east-2" # <-- CHANGED TO US-EAST-2
}

# The Multi-Region Access Point (MRAP) resource is an account-level control resource.
# It MUST be configured using the provider in the US East (N. Virginia) region (us-east-1),
# as this is the S3 Control API control plane. We pass this alias into the module.
provider "aws" {
  alias  = "mrap_control"
  region = "us-east-1"
}