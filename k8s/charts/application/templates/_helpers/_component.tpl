{{/*
===============================================================================
COMPONENT CONFIG — deep-merge of root defaults with per-component
overrides. This is what makes workers/cronjobs inherit everything.
===============================================================================
*/}}

{{/*
===============================================================================
COMPONENT CONFIG

Builds the EFFECTIVE pod-level configuration for a component by deep-merging
the root-level defaults with that component's own overrides. Maps merge,
lists are replaced wholesale (standard Helm semantics).

This is what makes the chart "declare a value and it maps through": a worker or
cronjob inherits every root knob and overrides only what it needs, without the
chart having to enumerate `coalesce` for each field.

Usage: {{- $c := include "application.componentConfig" (dict "root" $ "overrides" .) | fromYaml }}
===============================================================================
*/}}
{{- define "application.componentConfig" -}}
{{- $root := .root -}}
{{- $base := dict -}}
{{/*
`probes` is deliberately NOT inherited.

Two ways inheritance breaks a probe, both silent at render time:
  1. The app's probes target `port: http`. Workers and cronjobs have no `http`
     port, so the kubelet cannot resolve the name and the pod never goes Ready.
  2. mergeOverwrite is a DEEP merge, so a worker's `liveness.exec` merged over
     the app's `liveness.httpGet` yields a probe carrying BOTH handlers, which
     the API server rejects.
A component gets exactly the probes it declares, or none.
*/}}
{{- $inherited := list
      "image" "imagePullSecrets" "command" "args" "extraPorts" "resources"
      "lifecycle" "podSecurityContext" "securityContext" "extraVolumes" "extraVolumeMounts"
      "nodeSelector" "tolerations" "affinity" "topologySpreadConstraints"
      "priorityClassName" "runtimeClassName" "schedulerName" "hostAliases"
      "dnsPolicy" "dnsConfig" "terminationGracePeriodSeconds"
      "hostNetwork" "hostPID" "hostIPC" "shareProcessNamespace"
      "podAnnotations" "podLabels" "initContainers" "extraContainers"
      "extraEnvFrom" "envRaw" "automountServiceAccountToken" "restartPolicy"
-}}
{{- range $k := $inherited -}}
  {{- if hasKey $root.Values $k -}}
    {{- $val := index $root.Values $k -}}
    {{- if not (kindIs "invalid" $val) -}}
      {{- $_ := set $base $k (deepCopy $val) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- $merged := mergeOverwrite $base (deepCopy (.overrides | default dict)) -}}
{{- toYaml $merged -}}
{{- end }}
