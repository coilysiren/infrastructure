variable "name" {
  type = string
}

variable "dns_name" {
  type = string
}

variable "instance_type" {
  description = "https://aws.amazon.com/ec2/instance-types/"
  type        = string
  default     = "t3.medium"
}

variable "ami" {
  type = string
}

variable "subnet" {
  description = "us-east-1c"
  type        = string
  default     = "subnet-08bcb7e889b485874"
}

variable "security_groups" {
  type = string
}

variable "name" {
  description = "name of the server"
  type        = string
}

variable "service" {
  description = "systemd service name"
  type        = string
}

variable "key_name" {
  description = "https://console.aws.amazon.com/ec2/v2/home?region=us-east-1#KeyPairs"
  type        = string
  default     = "ssh"
}

variable "env" {
  description = "environment"
  type        = string
}

variable "instance_type" {
  description = "https://aws.amazon.com/ec2/instance-types/"
  type        = string
  default     = "t3.medium"
}

variable "ami" {
  type = string
}

variable "subnet" {
  description = "us-east-1c"
  type        = string
  default     = "subnet-08bcb7e889b485874"
}

variable "security_groups" {
  type = string
}

variable "eip_allocation_id" {
  type = string
}

variable "volume" {
  type = string
}
