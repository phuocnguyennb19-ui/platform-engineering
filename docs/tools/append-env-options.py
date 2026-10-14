#!/usr/bin/env python3
"""Append the options people usually change per environment, commented out, to an
applications/<app>/k8s/<env>/values.yaml — skipping any top-level key the file already sets.
usage: append-env-options.py <file>...   (idempotent: a file that has the block is left alone)"""
import re, sys

MARK = "# ── Tuỳ chọn ──"
OPTIONS = {
    "image": ["# image:",
              "#   tag: \"1.2.3\""],
    "replicaCount": ["# replicaCount: 2"],
    "autoscaling": ["# autoscaling:",
                    "#   enabled: true",
                    "#   minReplicas: 2",
                    "#   maxReplicas: 5",
                    "#   targetCPUUtilizationPercentage: 75"],
    "resources": ["# resources:",
                  "#   requests: { cpu: 100m, memory: 128Mi }",
                  "#   limits:   { memory: 256Mi }"],
    "podDisruptionBudget": ["# podDisruptionBudget:",
                            "#   enabled: true",
                            "#   maxUnavailable: 1"],
    "env": ["# env:",
            "#   LOG_LEVEL: info"],
    "ingress": ["# ingress:",
                "#   enabled: true",
                "#   annotations:",
                "#     cert-manager.io/cluster-issuer: letsencrypt-staging",
                "#   hosts:",
                "#     - host: <app>.dev.example.com",
                "#       paths: [ { path: /, pathType: Prefix } ]",
                "#   tls:",
                "#     - { secretName: <app>-tls, hosts: [ <app>.dev.example.com ] }"],
    "nodeSelector": ["# nodeSelector: {}"],
}
for p in sys.argv[1:]:
    s = open(p, encoding="utf-8").read()
    if MARK in s:
        continue
    keys = set(re.findall(r"(?m)^([A-Za-z_][\w-]*):", s))
    block = [l for k, ls in OPTIONS.items() if k not in keys for l in ls]
    if not block:
        continue
    s = s.rstrip("\n") + "\n\n" + MARK + "\n" + "\n".join(block) + "\n"
    open(p, "w", encoding="utf-8").write(s)
    print("updated", p)
