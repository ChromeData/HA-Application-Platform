#!/usr/bin/env python3
"""Break the platform on purpose and measure what the users would have seen.

An architecture diagram with two availability zones is a claim. This is the
measurement. Terminate a live instance, poll the load balancer every ten
seconds, and report how many requests actually survived.

    python scripts/chaos.py --alb <dns-name> --asg lab13-asg

Why the target selection is its own tested function: the first run of this test
picked Instances[0] from the autoscaling group, terminated it, and reported a
clean pass. That instance was already terminated, a stale entry from an earlier
replacement, so the test killed something dead while producing exactly the
output a successful test produces. See tests/test_chaos_helpers.py.
"""

import argparse
import sys
import time
import urllib.error
import urllib.request

try:
    import boto3
except ImportError:
    boto3 = None


# States where the instance is genuinely carrying traffic. Anything else is
# either not there yet or already leaving, and killing it proves nothing.
LIVE = "InService"


def pick_victim(instances, az=None):
    """Choose an instance that is genuinely serving.

    Returns None rather than falling back to "the first one", because a chaos
    test with no valid target should abort loudly, not run against a corpse.
    """
    live = [
        i for i in instances
        if i.get("LifecycleState") == LIVE and i.get("HealthStatus") == "Healthy"
    ]
    if not live:
        return None

    if az:
        in_az = [i for i in live if i.get("AvailabilityZone") == az]
        if in_az:
            return in_az[0]["InstanceId"]

    return live[0]["InstanceId"]


def verdict(served, failed):
    """A dropped request or two is expected. Never recovering is not.

    The health check runs every 15 seconds and needs 3 consecutive failures
    before the load balancer stops routing to a dead target, so up to 45
    seconds of traffic can still be sent to something that is gone. That window
    is arithmetic, not a bug. What would be a real failure is the platform
    never coming back at all.
    """
    total = served + failed
    if total == 0:
        return {"pass": False, "detail": "no requests were made"}

    if failed == 0:
        return {"pass": True, "detail": f"all {served} requests served, no visible impact"}

    if served > failed:
        return {
            "pass": True,
            "detail": (
                f"{served} served, {failed} dropped during the failover window. "
                f"Expected: health check interval times the unhealthy threshold "
                f"is up to 45 seconds of routing to a dead target."
            ),
        }

    return {
        "pass": False,
        "detail": f"only {served} of {total} served. The platform did not recover.",
    }


def poll(url, rounds, gap):
    served = failed = 0
    seen = []
    for i in range(1, rounds + 1):
        try:
            with urllib.request.urlopen(url, timeout=8) as r:
                body = r.read().decode(errors="replace").strip()
            served += 1
            seen.append(body)
            print(f"  t+{i * gap:03d}s  {body}")
        except (urllib.error.URLError, OSError, TimeoutError):
            failed += 1
            print(f"  t+{i * gap:03d}s  DOWN")
        time.sleep(gap)
    return served, failed, seen


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--alb", required=True, help="load balancer DNS name")
    ap.add_argument("--asg", default="lab13-asg")
    ap.add_argument("--az", default=None, help="prefer killing in this AZ")
    ap.add_argument("--rounds", type=int, default=12)
    ap.add_argument("--gap", type=int, default=10)
    args = ap.parse_args()

    if boto3 is None:
        sys.exit("needs boto3: pip install boto3")

    asg = boto3.client("autoscaling")
    ec2 = boto3.client("ec2")

    groups = asg.describe_auto_scaling_groups(AutoScalingGroupNames=[args.asg])
    instances = groups["AutoScalingGroups"][0]["Instances"]

    victim = pick_victim(instances, args.az)
    if not victim:
        sys.exit(
            "no instance is InService and Healthy right now. Aborting rather than "
            "killing something already dead, which is how this test passed falsely "
            "the first time."
        )

    print(f"Terminating {victim}, then polling http://{args.alb}/ every {args.gap}s\n")
    ec2.terminate_instances(InstanceIds=[victim])

    served, failed, _ = poll(f"http://{args.alb}/", args.rounds, args.gap)

    v = verdict(served, failed)
    print()
    print(v["detail"])
    print("PASS" if v["pass"] else "FAIL")
    return 0 if v["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
