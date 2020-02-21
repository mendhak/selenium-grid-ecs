# Set up providers and variables. 

provider "aws" {
  region  = "eu-west-1"
}

variable "vpc_id" {
  type        = string
  description = "The id of a VPC in your AWS account"
  default = "vpc-11111111"
}

variable subnet_public_ids {
  type    = list(string)  
  description = "The ids of the public subnet, for the load balancer"
  default = ["subnet-11111111","subnet-2222222"]
}

variable subnet_private_ids {
  type    = list(string)  
  description = "The ids of the private subnet, for the containers"
  default = ["subnet-3333333333"]
}


data "aws_vpc" "your_vpc" {
  id = var.vpc_id
}

## Create a security group to limit ingress

resource "aws_security_group" "sg_selenium_grid" {
  name        = "selenium_Grid"
  description = "Allow Selenium Grid ports within the VPC, and browsing from the outside"
  vpc_id      = var.vpc_id

   ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    # You should restrict this to your own IP
    # If creating internally, restrict it to your own range
    cidr_blocks = ["0.0.0.0/0"]
    description = "Change this to your own IP"
  }

  ingress {
    from_port   = 4444
    to_port     = 4444
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.your_vpc.cidr_block]
    description = "Selenium Hub port"
  }

  ingress {
    from_port   = 5555
    to_port     = 5555
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.your_vpc.cidr_block]
    description = "Selenium Node port"
  }

   egress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    cidr_blocks     = ["0.0.0.0/0"]
  }

}


## Create a role which allows ECS containers to perform actions such as write logs, call KMS

data "aws_iam_policy_document" "assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "ecs_execution_policy" {
  name        = "ecsTaskExecutionPolicy"
  path        = "/"
  description = "Allows ECS containers to execute commands on our behalf"

  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ecr:GetAuthorizationToken",
                "ecr:BatchCheckLayerAvailability",
                "ecr:GetDownloadUrlForLayer",
                "ecr:BatchGetImage",
                "logs:CreateLogStream",
                "logs:PutLogEvents",
                "logs:CreateLogGroup"
            ],
            "Resource": "*"
        }
    ]
}
EOF
}


resource "aws_iam_role" "ecsTaskExecutionRole" {
  name               = "ecsTaskExecutionRole"
  assume_role_policy = data.aws_iam_policy_document.assume_role_policy.json
}


resource "aws_iam_role_policy_attachment" "ecsTaskExecutionRole_policy" {
  role       = aws_iam_role.ecsTaskExecutionRole.name
  # policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
  policy_arn = aws_iam_policy.ecs_execution_policy.arn
}

## Service Discovery (AWS Cloud Map) for a private DNS, so containers can find each other

resource "aws_service_discovery_private_dns_namespace" "selenium" {
  name        = "selenium"
  description = "private DNS for selenium"
  vpc         = var.vpc_id
}

resource "aws_service_discovery_service" "hub" {
  name = "hub"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.selenium.id

    dns_records {
      ttl  = 60
      type = "A"
    }
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}


## ECS cluster, with default fargate spot containers

resource "aws_ecs_cluster" "selenium_grid" {
  name = "selenium-grid"
  capacity_providers = ["FARGATE_SPOT"]
  default_capacity_provider_strategy {
      capacity_provider = "FARGATE_SPOT"
      weight = 1
  }

}

## The definition for Selenium hub container

resource "aws_ecs_task_definition" "seleniumhub" {
  family                = "seleniumhub"
  network_mode = "awsvpc"
  container_definitions = <<DEFINITION
[
   {
        "name": "hub", 
        "image": "selenium/hub:3.141.59", 
        "portMappings": [
            {
            "hostPort": 4444,
            "protocol": "tcp",
            "containerPort": 4444
            }
        ], 
        "essential": true, 
        "entryPoint": [], 
        "command": []
        
    }
]
DEFINITION

requires_compatibilities = ["FARGATE"]
cpu = 1024
memory = 2048

}

## Service for selenium hub container

resource "aws_ecs_service" "seleniumhub" {
  name          = "seleniumhub"
  cluster       = aws_ecs_cluster.selenium_grid.id
  desired_count = 1

  network_configuration {
      subnets = var.subnet_private_ids
      security_groups = [aws_security_group.sg_selenium_grid.id]
      assign_public_ip = false
  }

  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight = 1
  }

  platform_version = "LATEST"
  scheduling_strategy = "REPLICA"
  service_registries {
      registry_arn = aws_service_discovery_service.hub.arn
      container_name = "hub"
  }

  task_definition = aws_ecs_task_definition.seleniumhub.arn

  load_balancer {
    target_group_arn =   aws_lb_target_group.selenium-hub.arn
    container_name   = "hub"
    container_port   = 4444
  }

  depends_on = [aws_lb_target_group.selenium-hub, aws_lb.selenium-hub]


}

resource "aws_lb_target_group" "selenium-hub" {
  name        = "selenium-hub-tg"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id
}

resource "aws_lb" "selenium-hub" {
  name               = "selenium-hub-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.sg_selenium_grid.id]
  subnets            = var.subnet_public_ids

  enable_deletion_protection = false
}

resource "aws_lb_listener" "selenium-hub" {
  load_balancer_arn = aws_lb.selenium-hub.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.selenium-hub.arn
  }
}



## Definition for Firefox container

resource "aws_ecs_task_definition" "firefox" {
  family                = "seleniumfirefox"
  network_mode = "awsvpc"
  container_definitions = <<DEFINITION
[
   {
            "name": "hub", 
            "image": "selenium/node-firefox:latest", 
            "portMappings": [
                {
                    "hostPort": 5555,
                    "protocol": "tcp",
                    "containerPort": 5555
                }
            ],
            "essential": true, 
            "entryPoint": [], 
            "command": [ "/bin/bash", "-c", "PRIVATE=$(curl -s http://169.254.170.2/v2/metadata | jq -r '.Containers[1].Networks[0].IPv4Addresses[0]') ; export REMOTE_HOST=\"http://$PRIVATE:5555\" ; /opt/bin/entry_point.sh" ],
            "environment": [
                {
                  "name": "HUB_HOST",
                  "value": "hub.selenium"
                },
                {
                  "name": "HUB_PORT",
                  "value": "4444"
                },
                {
                    "name":"NODE_MAX_SESSION",
                    "value":"3"
                },
                {
                    "name":"NODE_MAX_INSTANCES",
                    "value":"3"
                }
            ],
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-create-group":"true",
                    "awslogs-group": "awslogs-selenium",
                    "awslogs-region": "eu-west-1",
                    "awslogs-stream-prefix": "firefox"
                }
            }
        }
]
DEFINITION

  requires_compatibilities = ["FARGATE"]
  cpu = 2048
  memory = 4096
  execution_role_arn = aws_iam_role.ecsTaskExecutionRole.arn

}



## Service for firefox  container

resource "aws_ecs_service" "firefox" {
  name          = "seleniumfirefox"
  cluster       = aws_ecs_cluster.selenium_grid.id
  desired_count = 3
  
  network_configuration {
      subnets = var.subnet_private_ids
      security_groups = [aws_security_group.sg_selenium_grid.id]
      assign_public_ip = false

  }

  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight = 1
  }

  platform_version = "LATEST"
  scheduling_strategy = "REPLICA"
  

  task_definition = aws_ecs_task_definition.firefox.arn

}



## Definition for Chrome container

resource "aws_ecs_task_definition" "chrome" {
  family                = "seleniumchrome"
  network_mode = "awsvpc"
  container_definitions = <<DEFINITION
[
   {
            "name": "hub", 
            "image": "selenium/node-chrome:latest", 
            "portMappings": [
                {
                    "hostPort": 5555,
                    "protocol": "tcp",
                    "containerPort": 5555
                }
            ],
            "essential": true, 
            "entryPoint": [], 
            "command": [ "/bin/bash", "-c", "PRIVATE=$(curl -s http://169.254.170.2/v2/metadata | jq -r '.Containers[1].Networks[0].IPv4Addresses[0]') ; export REMOTE_HOST=\"http://$PRIVATE:5555\" ; /opt/bin/entry_point.sh" ],
            "environment": [
                {
                  "name": "HUB_HOST",
                  "value": "hub.selenium"
                },
                {
                  "name": "HUB_PORT",
                  "value": "4444"
                },
                {
                    "name":"NODE_MAX_SESSION",
                    "value":"3"
                },
                {
                    "name":"NODE_MAX_INSTANCES",
                    "value":"3"
                }
            ],
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-create-group":"true",
                    "awslogs-group": "awslogs-selenium",
                    "awslogs-region": "eu-west-1",
                    "awslogs-stream-prefix": "chrome"
                }
            }
        }
]
DEFINITION

  requires_compatibilities = ["FARGATE"]
  cpu = 2048
  memory = 4096
  execution_role_arn = aws_iam_role.ecsTaskExecutionRole.arn

}



## Service for firefox  container

resource "aws_ecs_service" "chrome" {
  name          = "seleniumchrome"
  cluster       = aws_ecs_cluster.selenium_grid.id
  desired_count = 3

  network_configuration {
      subnets = var.subnet_private_ids
      security_groups = [aws_security_group.sg_selenium_grid.id]
      assign_public_ip = false

  }

  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight = 1
  }

  platform_version = "LATEST"
  scheduling_strategy = "REPLICA"
  

  task_definition = aws_ecs_task_definition.chrome.arn

}


output "hub_address" {

  value = aws_lb.selenium-hub.dns_name

}
