# Test root: holds no infrastructure. Every run block names the module it exercises,
# so all tests and their fixtures live here instead of beside each module.
terraform {
  required_version = ">= 1.10.0"
}
