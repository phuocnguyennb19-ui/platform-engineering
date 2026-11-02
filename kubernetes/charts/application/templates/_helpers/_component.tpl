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
{{/*
`initContainers` is NOT inherited either: an app's migration initContainer would
otherwise run again in every worker and cronjob pod.

`image` is inherited whole only while the component keeps the app's repository.
A component that names another repository keeps registry and pullPolicy, never
tag or digest: a deep-merged app digest wins over the component's own tag and
would point `busybox@sha256:<app digest>`. A component that keeps the repository
but sets its own tag (no digest) drops the app digest, which would win over that tag.
*/}}
{{- $inherited := list
      "image" "imagePullSecrets" "command" "args" "extraPorts" "resources"
      "lifecycle" "podSecurityContext" "securityContext" "extraVolumes" "extraVolumeMounts"
      "nodeSelector" "tolerations" "affinity" "topologySpreadConstraints"
      "priorityClassName" "runtimeClassName" "schedulerName" "hostAliases"
      "dnsPolicy" "dnsConfig" "terminationGracePeriodSeconds"
      "hostNetwork" "hostPID" "hostIPC" "shareProcessNamespace"
      "podAnnotations" "podLabels" "extraContainers"
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
{{- $overrides := .overrides | default dict -}}
{{- $ownImage := $overrides.image | default dict -}}
{{- $ownRepo := $ownImage.repository | default "" -}}
{{- if and $ownRepo (ne $ownRepo ($root.Values.image.repository | default "")) -}}
  {{- $_ := set $base "image" (pick ($base.image | default dict) "registry" "pullPolicy") -}}
{{- else if and $ownImage.tag (not $ownImage.digest) -}}
  {{- $_ := set $base "image" (omit ($base.image | default dict) "digest") -}}
{{- end -}}
{{- $merged := mergeOverwrite $base (deepCopy $overrides) -}}
{{- toYaml $merged -}}
{{- end }}
