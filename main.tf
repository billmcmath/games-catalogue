provider "aws" {
  region = "eu-west-1"
}

terraform {
  required_version = "~> 1.11.4"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.10.0"
    }
  }
  backend "s3" {
    bucket = "terraform-state-billmcmath-co-uk"
    key    = "game-catalogue/terraform.tfstate"
    region = "eu-west-1"

    encrypt      = true
    use_lockfile = true
  }
}

data "terraform_remote_state" "lambda_bucket" {
  backend = "s3"

  config = {
    bucket = "terraform-state-billmcmath-co-uk"
    key    = "state_bucket/terraform.tfstate"
    region = "eu-west-1"

    # Optional: If your state bucket has encryption
    encrypt = true
  }
}

variable "python_version" {
  type        = string
  default     = "python3.13"
  description = "The version of Python to use for the Lambda"
}

resource "aws_dynamodb_table" "games_catalogue" {
  name         = "games-catalogue"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "platform"
  range_key    = "game_id"

  attribute {
    name = "platform"
    type = "S"
  }

  attribute {
    name = "game_id"
    type = "S"
  }

  tags = {
    Name = "games-catalogue"
  }
}

data "aws_iam_policy_document" "lambda_assume_policy" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_role" {
  name               = "games-catalogue-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_policy.json
}

resource "aws_iam_role_policy" "lambda_policy" {
  name   = "games-catalogue-lambda-policy"
  role   = aws_iam_role.lambda_role.id
  policy = data.aws_iam_policy_document.lambda_policy.json
}

data "aws_iam_policy_document" "lambda_policy" {
  statement {
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
      "dynamodb:Query",
      "dynamodb:Scan"
    ]
    effect    = "Allow"
    resources = [aws_dynamodb_table.games_catalogue.arn]
  }

  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    effect    = "Allow"
    resources = ["${aws_cloudwatch_log_group.games_catalogue_logs.arn}:*"]
  }
}

data "archive_file" "lambda_dependencies" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_layer"
  output_path = "${path.module}/lambda_layer.zip"

  excludes = ["*.pyc", "__pycache__"]
}

resource "aws_lambda_layer_version" "dependencies" {
  layer_name          = "games-catalogue-dependencies"
  filename            = data.archive_file.lambda_dependencies.output_path
  source_code_hash    = data.archive_file.lambda_dependencies.output_base64sha256
  compatible_runtimes = [var.python_version]
}

data "archive_file" "lambda_code" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/lambda_function.zip"

  excludes = ["*.pyc", "__pycache__"]
}

resource "aws_lambda_function" "games_catalogue" {
  filename         = data.archive_file.lambda_code.output_path
  function_name    = "games-catalogue"
  description      = "http://ec2-subnet-router/gc"
  role             = aws_iam_role.lambda_role.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = var.python_version
  source_code_hash = data.archive_file.lambda_code.output_base64sha256
  layers           = [aws_lambda_layer_version.dependencies.arn]

  architectures = ["arm64"]

  tags = {
    Name    = "games-catalogue"
    invoker = "tailscale"
  }
}

resource "aws_cloudwatch_log_group" "games_catalogue_logs" {
  name              = "/aws/lambda/${aws_lambda_function.games_catalogue.function_name}"
  retention_in_days = 30

  depends_on = [aws_lambda_function.games_catalogue]

  tags = {
    Name = "games-catalogue-logs"
  }
}


locals {
  nginx_conf = <<-EOF
location /gc {
    proxy_pass http://127.0.0.1:5000;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_connect_timeout 5s;
    proxy_read_timeout 300s;
}
EOF

  proxy_config = jsonencode({
    "function_name" : "games-catalogue",
    "name" : "gc",
    "region" : "eu-west-1",
    "routes" : [
      { "methods" : ["GET"], "path" : "/gc" },
      { "methods" : ["GET"], "path" : "/gc/<platform>" },
      { "methods" : ["POST"], "path" : "/gc/add" },
      { "methods" : ["POST"], "path" : "/gc/wishlist/add" },
      { "methods" : ["POST"], "path" : "/gc/wishlist/purchased" },
      { "methods" : ["DELETE"], "path" : "/gc/delete" },
      { "methods" : ["DELETE"], "path" : "/gc/wishlist/delete" },
      { "methods" : ["GET"], "path" : "/gc/wishlist" }
    ]
    }
  )
}

resource "aws_s3_object" "nginx_conf" {
  bucket                 = data.terraform_remote_state.lambda_bucket.outputs.lambda_description_bucket
  key                    = "nginx/gamescatalogue.conf"
  content                = local.nginx_conf
  content_type           = "text/nginx"
  acl                    = "private"
  server_side_encryption = "AES256"
}

resource "aws_s3_object" "proxy_config" {
  bucket                 = data.terraform_remote_state.lambda_bucket.outputs.lambda_description_bucket
  key                    = "configs/gamescatalogue.json"
  content                = local.proxy_config
  content_type           = "application/json"
  acl                    = "private"
  server_side_encryption = "AES256"
}