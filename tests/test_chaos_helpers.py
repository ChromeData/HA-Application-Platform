"""Offline tests for the chaos test's target selection.

These exist because of a specific near miss. The first chaos run grabbed
Instances[0] from the autoscaling group and terminated it. Every request
succeeded afterwards and it looked like a clean pass.

That instance was already terminated, a stale entry left from an earlier
replacement. The test killed something dead and produced exactly the output a
successful test produces.

So the selection logic is its own function now, and it is tested, because a
chaos test that cannot fail is not a chaos test.
"""

import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("chaos", ROOT / "scripts" / "chaos.py")
chaos = importlib.util.module_from_spec(spec)
sys.modules["chaos"] = chaos
spec.loader.exec_module(chaos)


def inst(iid, lifecycle="InService", health="Healthy", az="us-east-1a"):
    return {
        "InstanceId": iid,
        "LifecycleState": lifecycle,
        "HealthStatus": health,
        "AvailabilityZone": az,
    }


class TestPickVictim:
    def test_picks_an_inservice_instance(self):
        group = [inst("i-good")]
        assert chaos.pick_victim(group) == "i-good"

    def test_skips_terminating_instances(self):
        # The exact bug. A stale Terminating entry sat at index 0 and got
        # chosen, so the test killed something already dead.
        group = [
            inst("i-stale", lifecycle="Terminating"),
            inst("i-live"),
        ]
        assert chaos.pick_victim(group) == "i-live"

    def test_skips_every_non_inservice_state(self):
        for state in ("Pending", "Terminating", "Terminated", "Detaching", "Standby"):
            group = [inst("i-bad", lifecycle=state), inst("i-live")]
            assert chaos.pick_victim(group) == "i-live", f"{state} must not be chosen"

    def test_skips_unhealthy_instances(self):
        # Killing something already failing proves nothing either. The point is
        # to remove capacity that was genuinely serving.
        group = [inst("i-sick", health="Unhealthy"), inst("i-live")]
        assert chaos.pick_victim(group) == "i-live"

    def test_returns_none_when_nothing_is_killable(self):
        # Must not fall back to "just pick the first one". Returning None makes
        # the caller abort instead of running a test that means nothing.
        group = [inst("i-stale", lifecycle="Terminating")]
        assert chaos.pick_victim(group) is None

    def test_returns_none_on_empty_group(self):
        assert chaos.pick_victim([]) is None

    def test_prefers_an_instance_in_the_named_az(self):
        group = [inst("i-a", az="us-east-1a"), inst("i-b", az="us-east-1b")]
        assert chaos.pick_victim(group, az="us-east-1b") == "i-b"

    def test_falls_back_when_the_named_az_has_nothing_live(self):
        group = [inst("i-a", az="us-east-1a")]
        assert chaos.pick_victim(group, az="us-east-1b") == "i-a"


class TestVerdict:
    """A single dropped request is expected. Total loss is not."""

    def test_all_served_is_a_pass(self):
        assert chaos.verdict(served=12, failed=0)["pass"] is True

    def test_one_drop_still_passes_but_is_reported(self):
        v = chaos.verdict(served=11, failed=1)
        assert v["pass"] is True
        assert "1" in v["detail"]

    def test_never_recovering_is_a_failure(self):
        # If nothing ever came back, the platform did not self heal and the
        # whole premise of the lab is wrong.
        assert chaos.verdict(served=0, failed=12)["pass"] is False

    def test_majority_failure_is_a_failure(self):
        assert chaos.verdict(served=3, failed=9)["pass"] is False
