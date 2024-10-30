variable "name" {
  type = string
}

variable "dns_name" {
  type = string
}

variable "ami" {
  type = string
}

variable "subnet" {
  description = "us-east-1c"
  type        = string
  default     = "subnet-08bcb7e889b485874"
}
