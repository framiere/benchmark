provider "aws" {
  region  = var.region
  version = "3.50"
  profile = "conduktor-dev"
}

provider "random" {
  version = "3.1"
}

locals {
  tags = {
    "conduktor.io/team"       = "gateway"
    "conduktor.io/app-name"   = "openmessaging"
    "conduktor.io/managed-by" = "framiere"
  }
}

variable "public_key_path" {
  description = <<DESCRIPTION
Path to the SSH public key to be used for authentication.
Ensure this keypair is added to your local SSH agent so provisioners can
connect.

Example: ~/.ssh/kafka_aws.pub
DESCRIPTION
}

resource "random_id" "hash" {
  byte_length = 8
}

variable "key_name" {
  default     = "kafka-benchmark-key"
  description = "Desired name prefix for the AWS key pair"
}

variable "region" {}

variable "ami" {}

variable "az" {}

variable "instance_types" {
  type = map(string)
}

variable "num_instances" {
  type = map(string)
}

# NOTE: WE DO NOT NEED TO CREATE A VPC, WE CAN USE THE DEFAULT ONE
# Create a VPC to launch our instances into
# resource "aws_vpc" "benchmark_vpc" {
#   cidr_block = "10.0.0.0/16"

#   tags = {
#     Name = "Kafka_Benchmark_VPC_${random_id.hash.hex}"
#   }
# }
data "aws_vpc" "default" {
  default = true
}

# NOTE: Use the default internet gateway
data "aws_internet_gateway" "default" {
  filter {
    name   = "attachment.vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Grant the VPC internet access on its main route table
resource "aws_route" "internet_access" {
  route_table_id         = data.aws_vpc.default.main_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = data.aws_internet_gateway.default.id
}

# Create a subnet to launch our instances into
resource "aws_subnet" "benchmark_subnet" {
  vpc_id                  = data.aws_vpc.default.id
  cidr_block              = "172.31.48.0/28"
  map_public_ip_on_launch = true
  availability_zone       = var.az

  tags = merge(
    { Name = "benchmark-snet-01" },
    local.tags
  )
}

resource "aws_security_group" "benchmark_security_group" {
  name   = "terraform-kafka-${random_id.hash.hex}"
  vpc_id = data.aws_vpc.default.id

  # SSH access from anywhere
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # All ports open within the VPC
  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  # outbound internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    { Name = "Benchmark-Security-Group-${random_id.hash.hex}" },
    local.tags
  )
}

resource "aws_key_pair" "auth" {
  key_name   = "${var.key_name}-${random_id.hash.hex}"
  public_key = file(var.public_key_path)

  tags = merge(
    { Name = "benchmark-key" },
    local.tags
  )
}

resource "aws_instance" "zookeeper" {
  ami                    = var.ami
  instance_type          = var.instance_types["zookeeper"]
  key_name               = aws_key_pair.auth.id
  subnet_id              = aws_subnet.benchmark_subnet.id
  vpc_security_group_ids = ["${aws_security_group.benchmark_security_group.id}"]
  count                  = var.num_instances["zookeeper"]

  tags = merge({
    Name      = "zk_${count.index}"
    Benchmark = "Kafka"
    },
    local.tags
  )
}

resource "aws_instance" "kafka" {
  ami                    = var.ami
  instance_type          = var.instance_types["kafka"]
  key_name               = aws_key_pair.auth.id
  subnet_id              = aws_subnet.benchmark_subnet.id
  vpc_security_group_ids = ["${aws_security_group.benchmark_security_group.id}"]
  count                  = var.num_instances["kafka"]

  tags = merge({
    Name      = "kafka_${count.index}"
    Benchmark = "Kafka"
    },
    local.tags
  )
}

resource "aws_instance" "client" {
  ami                    = var.ami
  instance_type          = var.instance_types["client"]
  key_name               = aws_key_pair.auth.id
  subnet_id              = aws_subnet.benchmark_subnet.id
  vpc_security_group_ids = ["${aws_security_group.benchmark_security_group.id}"]
  count                  = var.num_instances["client"]

  tags = merge({
    Name      = "kafka_client_${count.index}"
    Benchmark = "Kafka"
    },
    local.tags
  )
}

output "kafka_ssh_host" {
  value = aws_instance.kafka.0.public_ip
}

output "client_ssh_host" {
  value = aws_instance.client.0.public_ip
}
