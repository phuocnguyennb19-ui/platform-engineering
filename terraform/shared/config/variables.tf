variable "config_root" {
  description = "Directory holding <dir>/terraform/{environment,core,backend}.yaml per environment (environments/)."
  type        = string
}

variable "applications_root" {
  description = "Directory holding <app>/terraform/{app,<environment>}.yaml. Null means <config_root>/applications (test fixtures)."
  type        = string
  default     = null
}

variable "environment" {
  description = "Terraform environment name: the `environment:` field of environments/<dir>/terraform/environment.yaml (dev | staging | production)."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,31}$", var.environment))
    error_message = "environment must be a lowercase Terraform environment name (dev | staging | production)."
  }
}

variable "application" {
  description = "Application directory name under applications/. Null loads every application for the registry layer."
  type        = string
  default     = null

  validation {
    condition     = var.application == null || can(regex("^[a-z0-9][a-z0-9-]{0,62}$", var.application))
    error_message = "application must be a lowercase directory name under applications/."
  }
}

variable "image_tag" {
  description = "IMAGE_TAG from the pipeline. Empty means not passed."
  type        = string
  default     = ""
  nullable    = false
}
