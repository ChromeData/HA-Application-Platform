# ---------------------------------------------------------------------------
# The compute tier: load balancer, autoscaling group, and the security groups
# that tie them together.
#
# The shape of availability here is: the load balancer spans both AZs and only
# sends traffic to instances that pass a health check, and the autoscaling
# group replaces anything that fails. Neither alone is enough. A load balancer
# without autoscaling routes around a dead instance and then runs at reduced
# capacity forever. Autoscaling without health checks replaces instances that
# were fine and leaves the broken ones serving traffic.
#
# COST, and this is where the lab stops being free:
#   Application load balancer   ~$0.023/hr  plus a tiny per-request charge
#   EC2 t3.micro x2             free tier eligible, otherwise ~$0.0104/hr each
# Roughly 5 to 10 cents an hour. Destroy when done.
# ---------------------------------------------------------------------------

# Amazon Linux 2023, looked up rather than hardcoded. An AMI id is regional and
# they get replaced constantly, so a pinned id is broken in another region and
# stale within weeks.
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

# --- security groups ---------------------------------------------------------
#
# Three tiers, each only reachable from the one in front of it. The rules
# reference security groups rather than CIDR ranges, so access follows identity
# instead of whatever address happens to be in a range later.

resource "aws_security_group" "alb" {
  name        = "lab13-alb"
  description = "Load balancer. The only thing the internet can reach."
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "lab13-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  description       = "public http, this is the front door and it is meant to be open"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
  description                  = "forward to the app tier only"
}

resource "aws_security_group" "app" {
  name        = "lab13-app"
  description = "Application tier. Reachable only from the load balancer."
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "lab13-app" }
}

# Source is the ALB security group. Not the VPC CIDR, not the public subnets.
# If someone later puts an unrelated host in those subnets, it still cannot
# reach the app tier, because it is not in the load balancer's group.
resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
  description                  = "http from the load balancer only"
}

resource "aws_vpc_security_group_egress_rule" "app_to_db" {
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.db.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "postgres to the data tier, and nothing else"
}

resource "aws_security_group" "db" {
  name        = "lab13-db"
  description = "Data tier. Reachable only from the app tier, on one port."
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "lab13-db" }
}

resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "postgres from the app tier only"
}

# No egress rule on the database at all. AWS's default allows all outbound,
# which means a compromised database can reach the internet. Declaring the
# group with no egress rule removes that.

# --- load balancer -----------------------------------------------------------

resource "aws_lb" "main" {
  name               = "lab13-alb"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]

  # Both public subnets. An ALB can only route to targets in AZs where it has a
  # subnet, so giving it one AZ silently halves the design.
  subnets = aws_subnet.public[*].id

  tags = { Name = "lab13-alb" }
}

resource "aws_lb_target_group" "app" {
  name     = "lab13-app-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path     = "/"
    matcher  = "200"
    interval = 15

    # Two consecutive successes to come back, three failures to go out.
    # Asymmetric on purpose: slow to trust, quick to evict. A host that is
    # flapping should stay out until it is genuinely stable.
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
  }

  # Give a terminating instance time to finish in-flight requests instead of
  # cutting them off. The AWS default is 300 seconds, which makes every apply
  # crawl for no benefit at this size.
  deregistration_delay = 30

  tags = { Name = "lab13-app-tg" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# --- launch template and autoscaling -----------------------------------------

resource "aws_launch_template" "app" {
  name_prefix   = "lab13-app-"
  image_id      = data.aws_ami.al2023.id
  instance_type = "t3.micro"

  vpc_security_group_ids = [aws_security_group.app.id]

  # Metadata service v2 required. IMDSv1 is the mechanism behind a well known
  # class of credential theft: a server side request forgery bug in the app
  # reaches the metadata endpoint and walks away with the instance role. v2
  # needs a PUT to get a token first, which a blind SSRF cannot do.
  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  # Serves a page using ONLY what ships on the AMI. No package install.
  #
  # The first version ran `dnf install -y nginx` and every instance failed its
  # health check forever. The private subnets have no route off the network, by
  # design, so the package repos are unreachable and the install hangs. I had
  # built the network for isolation and then written a deploy that assumes
  # internet access, which is the exact conflict that shows up in real
  # environments.
  #
  # There were two ways out. A NAT gateway costs about $32 a month and puts an
  # outbound path back into a tier that is supposed to have none. Or stop
  # needing the internet: Amazon Linux 2023 ships Python, so it can serve the
  # page with nothing downloaded.
  #
  # The second is both cheaper and a better security posture, which is usually
  # how it goes when the first instinct is to punch a hole.
  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -x
    TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
      -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
    IID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
      http://169.254.169.254/latest/meta-data/instance-id)
    AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
      http://169.254.169.254/latest/meta-data/placement/availability-zone)

    mkdir -p /var/www
    echo "lab13 ok | instance $IID | az $AZ" > /var/www/index.html

    cat > /etc/systemd/system/lab13web.service <<'UNIT'
    [Unit]
    Description=lab13 minimal web server
    After=network.target

    [Service]
    WorkingDirectory=/var/www
    ExecStart=/usr/bin/python3 -m http.server 80
    Restart=always

    [Install]
    WantedBy=multi-user.target
    UNIT

    systemctl daemon-reload
    systemctl enable --now lab13web
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "lab13-app" }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "app" {
  name                = "lab13-asg"
  vpc_zone_identifier = aws_subnet.private[*].id

  min_size         = 2
  max_size         = 4
  desired_capacity = 2

  target_group_arns = [aws_lb_target_group.app.arn]

  # ELB, not EC2. The default EC2 check only asks whether the instance is
  # running, so a host whose web server has died stays in service forever. ELB
  # health means the autoscaling group replaces anything the load balancer will
  # not send traffic to, which is the behaviour people assume they already have.
  health_check_type         = "ELB"
  health_check_grace_period = 180

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "lab13-app"
    propagate_at_launch = true
  }
}

# --- closing the failover gap, issue #1 --------------------------------------
#
# The chaos test measured 11 requests served and 1 dropped. The cause is
# ordering: the instance dies, and the load balancer finds out afterwards via
# health checks. Interval 15s times unhealthy_threshold 3 is up to 45 seconds
# of traffic sent somewhere already gone, and no combination of those two
# settings removes it.
#
# The fix has to invert the order, so the instance leaves the pool BEFORE it
# stops serving.
#
# A terminate lifecycle hook does that. The instance moves to Terminating:Wait
# instead of dying, which triggers deregistration from the target group. The
# deregistration_delay on the target group then drains in-flight requests.
# Only after that does the instance actually terminate.
#
# heartbeat_timeout is 120s against a 30s deregistration delay, so there is
# room for draining to finish. CONTINUE on timeout means a hook that fails for
# any reason still lets the instance terminate rather than wedging the
# autoscaling group, which is the failure mode people hit with hooks.
#
# What this does NOT fix: sudden failure. A kernel panic or dead hardware gives
# no notice, nothing gets to run, and those requests still drop. Covering that
# needs retries in the client, which is not infrastructure's job.
resource "aws_autoscaling_lifecycle_hook" "drain_before_terminate" {
  name                   = "lab13-drain-before-terminate"
  autoscaling_group_name = aws_autoscaling_group.app.name
  lifecycle_transition   = "autoscaling:EC2_INSTANCE_TERMINATING"

  heartbeat_timeout = 120
  default_result    = "CONTINUE"
}

# Scale on CPU. Out at 70 percent, and AWS handles scaling back in on the same
# target, which avoids the classic mistake of setting the scale-in threshold so
# close to scale-out that the group oscillates.
resource "aws_autoscaling_policy" "cpu" {
  name                   = "lab13-cpu-target"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 70
  }
}

output "alb_dns" {
  value       = aws_lb.main.dns_name
  description = "curl this to hit the platform"
}
