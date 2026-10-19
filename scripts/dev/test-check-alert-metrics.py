#!/usr/bin/env python3
"""check-alert-metrics.py does not call a healthy-when-empty metric blind (infra #357); a really missing one still is.
Offline: imports the script and feeds classify() the list a cluster query would produce.   Usage: python3 -I scripts/dev/test-check-alert-metrics.py"""
import importlib.util
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location("cam", Path(__file__).resolve().parents[1] / "ops/check-alert-metrics.py")
cam = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cam)
fails = 0


def check(cond, msg):
    global fails
    print(("ok   " if cond else "FAIL ") + msg)
    fails += not cond


blind, expected = cam.classify([("kube_job_failed", ["OpenBaoBootstrapJobFailed"]), ("node_foo_total", ["NodeFoo"]),
                                ("kubelet_volume_stats_capacity_bytes", ["PersistentVolumeFillingUp"])])
check([m[0] for m in blind] == ["node_foo_total"], f"a metric nobody produces stays blind ({[m[0] for m in blind]})")
check(sorted(m[0] for m in expected) == ["kube_job_failed", "kubelet_volume_stats_capacity_bytes"], "kube_job_failed and the volume stats are expected-empty")
check(all(cam.HEALTHY_WHEN_EMPTY[k] for k in cam.HEALTHY_WHEN_EMPTY), "every allow-listed name carries its reason")
check(cam.metric_names('kube_job_failed{condition="true"} > 0') == {"kube_job_failed"}, "metric_names still reads the rule expression")
sys.exit(1 if fails else 0)
