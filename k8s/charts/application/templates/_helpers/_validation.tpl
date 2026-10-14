{{/*
===============================================================================
VALIDATION — fail the render, never ship a silently-broken release.
===============================================================================
*/}}

{{/*
===============================================================================
VALIDATION — fail the render, never ship a silently-broken release.
===============================================================================
*/}}
{{- define "application.validateProbes" -}}
{{- $where := .where -}}
{{- range $n, $p := (.probes | default dict) -}}
  {{- if $p -}}
    {{- $handlers := list -}}
    {{- range $h := (list "httpGet" "exec" "tcpSocket" "grpc") -}}
      {{- if hasKey $p $h }}{{- $handlers = append $handlers $h -}}{{- end -}}
    {{- end -}}
    {{- if eq (len $handlers) 0 -}}
      {{- fail (printf "%s.%s is set but has no handler — add one of httpGet / exec / tcpSocket / grpc, or set it to null" $where $n) -}}
    {{- end -}}
    {{- if gt (len $handlers) 1 -}}
      {{- fail (printf "%s.%s declares %d handlers (%s) — a probe accepts exactly one" $where $n (len $handlers) (join ", " $handlers)) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end }}

{{- define "application.validate" -}}
{{- $v := .Values -}}

{{- if and $v.autoscaling.enabled $v.keda.enabled -}}
{{- fail "autoscaling.enabled and keda.enabled are mutually exclusive — KEDA manages its own HPA. Disable one." -}}
{{- end -}}

{{- if and $v.podDisruptionBudget.enabled $v.podDisruptionBudget.minAvailable $v.podDisruptionBudget.maxUnavailable -}}
{{- fail "podDisruptionBudget: set either minAvailable OR maxUnavailable, not both — the API server rejects a PDB with both." -}}
{{- end -}}

{{- if not (has $v.workload.kind (list "Deployment" "StatefulSet" "DaemonSet")) -}}
{{- fail (printf "workload.kind must be one of Deployment|StatefulSet|DaemonSet, got %q" $v.workload.kind) -}}
{{- end -}}

{{- if and (eq $v.workload.kind "DaemonSet") (or $v.autoscaling.enabled $v.keda.enabled) -}}
{{- fail "a DaemonSet cannot be autoscaled — disable autoscaling.enabled / keda.enabled" -}}
{{- end -}}

{{/* A probe must carry EXACTLY ONE handler. Zero handlers and two handlers are
     both accepted by Helm and rejected by the API server at apply time. */}}
{{- include "application.validateProbes" (dict "probes" $v.probes "where" "probes") -}}
{{- range $w := $v.workers -}}
  {{- if $w.enabled -}}
  {{- include "application.validateProbes" (dict "probes" ($w.probes | default dict) "where" (printf "workers[%s].probes" $w.name)) -}}
  {{- end -}}
{{- end -}}
{{- range $j := $v.cronjobs -}}
  {{- if $j.enabled -}}
  {{- include "application.validateProbes" (dict "probes" ($j.probes | default dict) "where" (printf "cronjobs[%s].probes" $j.name)) -}}
  {{- end -}}
{{- end -}}

{{- if and $v.serviceMonitor.enabled (not $v.service.enabled) -}}
{{- fail "serviceMonitor.enabled requires service.enabled — a ServiceMonitor selects a Service." -}}
{{- end -}}

{{- if and $v.ingress.enabled $v.httpRoute.enabled -}}
{{- fail "ingress.enabled and httpRoute.enabled are both on — pick one north-south path (Ingress or Gateway API)." -}}
{{- end -}}

{{- if and $v.ingress.enabled (not $v.ingress.hosts) -}}
{{- fail "ingress.enabled requires ingress.hosts — an Ingress with no rules routes nothing." -}}
{{- end -}}

{{- if and $v.keda.enabled (not $v.keda.triggers) -}}
{{- fail "keda.enabled requires at least one entry in keda.triggers" -}}
{{- end -}}

{{/*
`workers` and `cronjobs` are LISTS, and each entry becomes its own object named
<fullname>-<entry name>. Two hazards follow, both silent without these guards:

  • duplicate `name` → two objects of the same kind with the same name. Helm
    renders both and the install fails ("resource already exists") or one worker
    is quietly lost.
  • names are truncated to fit the Kubernetes limit (63 for a worker Deployment,
    52 for a CronJob so the generated Job/Pod suffixes still fit). Two long names
    sharing a prefix collide AFTER truncation even though the values look
    distinct.
*/}}
{{- $fullname := include "application.fullname" . -}}

{{- $wSeen := dict -}}
{{- range $i, $w := $v.workers -}}
  {{- if $w.enabled -}}
    {{- if not $w.name -}}{{- fail (printf "workers[%d].name is required" $i) -}}{{- end -}}
    {{- if and $w.autoscaling $w.autoscaling.enabled $w.keda $w.keda.enabled -}}
    {{- fail (printf "workers[%s]: autoscaling and keda are mutually exclusive" $w.name) -}}
    {{- end -}}
    {{- $rendered := printf "%s-%s" $fullname $w.name | trunc 63 | trimSuffix "-" -}}
    {{- if hasKey $wSeen $rendered -}}
      {{- $prev := index $wSeen $rendered -}}
      {{- if eq $prev $w.name -}}
        {{- fail (printf "workers[] contains %q twice — worker names must be unique. A list entry does not merge with an earlier one of the same name; both would render the Deployment %q." $w.name $rendered) -}}
      {{- else -}}
        {{- fail (printf "workers[%s] and workers[%s] both truncate to the Deployment name %q (63-char limit) — shorten one of the worker names, or set a shorter fullnameOverride" $prev $w.name $rendered) -}}
      {{- end -}}
    {{- end -}}
    {{- $_ := set $wSeen $rendered $w.name -}}
  {{- end -}}
{{- end -}}

{{- $cSeen := dict -}}
{{- range $i, $c := $v.cronjobs -}}
  {{- if $c.enabled -}}
    {{- if not $c.name -}}{{- fail (printf "cronjobs[%d].name is required" $i) -}}{{- end -}}
    {{- if not $c.schedule -}}{{- fail (printf "cronjobs[%s].schedule is required" $c.name) -}}{{- end -}}
    {{- $rendered := printf "%s-%s" $fullname $c.name | trunc 52 | trimSuffix "-" -}}
    {{- if hasKey $cSeen $rendered -}}
      {{- $prev := index $cSeen $rendered -}}
      {{- if eq $prev $c.name -}}
        {{- fail (printf "cronjobs[] contains %q twice — cronjob names must be unique. To run the same command on two schedules, give each entry its own name." $c.name) -}}
      {{- else -}}
        {{- fail (printf "cronjobs[%s] and cronjobs[%s] both truncate to the CronJob name %q (52-char limit, so the generated Job and Pod names still fit) — shorten one of the cronjob names" $prev $c.name $rendered) -}}
      {{- end -}}
    {{- end -}}
    {{- $_ := set $cSeen $rendered $c.name -}}
  {{- end -}}
{{- end -}}
{{- end }}
