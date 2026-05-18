variable "admin_group_name" {
  description = "Name of the existing IAM group whose members get encrypt/decrypt on the admin key. Group membership is the only path; individual user ARNs are intentionally not supported."
  type        = string
  default     = "admins"
}
