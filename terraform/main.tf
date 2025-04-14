provider "aws" {
  region = "us-east-1"
}

resource "aws_vpc" "sp_vpc" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_subnet" "sp_public_subnet" {
  vpc_id     = aws_vpc.sp_vpc.id
  cidr_block = "10.0.1.0/24"
  availability_zone = "us-east-1a"
}

resource "aws_subnet" "sp_private_subnet" {
  vpc_id     = aws_vpc.sp_vpc.id
  cidr_block = "10.0.2.0/24"
  availability_zone = "us-east-1a"
}

resource "aws_internet_gateway" "sp_internet_gateway" {
  vpc_id = aws_vpc.sp_vpc.id
}

resource "aws_route_table" "sp_route_table" {
  vpc_id = aws_vpc.sp_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.sp_internet_gateway.id
  }
}

resource "aws_route_table_association" "sp_route_table_association" {
  subnet_id      = aws_subnet.sp_public_subnet.id
  route_table_id = aws_route_table.sp_route_table.id
}

resource "aws_security_group" "sp_security_group" {
  vpc_id = aws_vpc.sp_vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "sp_ec2_role" {
  name = "sp_ec2_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Effect    = "Allow"
        Sid       = ""
      },
    ]
  })
}

resource "aws_iam_role_policy" "sp_ec2_policy" {
  name = "sp_ec2_policy"
  role = aws_iam_role.sp_ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = [
          "s3:ListBucket",
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = [
          aws_s3_bucket.sp_s3_bucket.arn,
          "${aws_s3_bucket.sp_s3_bucket.arn}/*"
        ]
        Effect   = "Allow"
      },
    ]
  })
}

resource "aws_instance" "sp_ec2_instance" {
  ami           = "ami-0c55b159cbfafe1f0" # Replace with a valid AMI ID
  instance_type = "t2.micro"
  key_name      = var.key_pair_name  

  subnet_id              = aws_subnet.sp_public_subnet.id
  vpc_security_group_ids = [aws_security_group.sp_security_group.id]
  
  iam_instance_profile = aws_iam_instance_profile.sp_ec2_instance_profile.id

  user_data = <<-EOF
              #!/bin/bash
              # Your user data script here
              EOF
}

resource "aws_iam_instance_profile" "sp_ec2_instance_profile" {
  name = "sp_ec2_instance_profile"
  role = aws_iam_role.sp_ec2_role.name
}

resource "aws_s3_bucket" "sp_s3_bucket" {
  bucket = "sp-s3-bucket-${var.bucket_suffix}" # Ensure uniqueness
  acl    = "private"
}

resource "aws_s3_bucket_policy" "sp_bucket_policy" {
  bucket = aws_s3_bucket.sp_s3_bucket.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${aws_iam_role.sp_ec2_role.name}"
        }
        Action   = "s3:*"
        Resource = [
          aws_s3_bucket.sp_s3_bucket.arn,
          "${aws_s3_bucket.sp_s3_bucket.arn}/*"
        ]
      },
    ]
  })
}

resource "aws_s3_bucket_versioning" "sp_bucket_versioning" {
  bucket = aws_s3_bucket.sp_s3_bucket.id
  
  versioning_configuration {
    enabled = true
  }
}

resource "aws_s3_bucket_logging" "sp_bucket_logging" {
  bucket        = aws_s3_bucket.sp_s3_bucket.id
  target_bucket = aws_s3_bucket.sp_logging_bucket.id # Create this bucket or replace with an existing one
  target_prefix = "log/"
}

resource "aws_s3_bucket_encryption" "sp_bucket_encryption" {
  bucket = aws_s3_bucket.sp_s3_bucket.id

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm = "AES256"
      }
    }
  }
}

resource "aws_s3_bucket_public_access_block" "sp_bucket_public_access" {
  bucket = aws_s3_bucket.sp_s3_bucket.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_security_group_rule" "allow_ec2_to_s3" {
  type              = "ingress"
  from_port        = 0
  to_port          = 0
  protocol         = "-1"
  security_group_id = aws_security_group.sp_security_group.id
  cidr_blocks       = [aws_s3_bucket.sp_s3_bucket.id]
}

data "aws_caller_identity" "current" {}