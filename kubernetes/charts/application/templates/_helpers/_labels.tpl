{{/*
===============================================================================
LABELS & ANNOTATIONS — including the component-scoped selectors
that keep worker/cronjob pods out of the app Service and PDB.
===============================================================================
*/}}

{{/*
===============================================================================
LABELS

`selectorLabels` is the IMMUTABLE identity of a workload. Every workload the
chart creates (app / worker / cronjob) carries a DISTINCT
`app.kubernetes.io/component`, so a Service, PDB or NetworkPolicy that targets
the app can never accidentally capture worker or cronjob pods.

  application.selectorLabels   → name + instance          (shared identity)
  application.componentLabels  → the above + component[+ worker/cronjob name]
===============================================================================
*/}}

{{- define "application.selectorLabels" -}}
app.kubernetes.io/name: {{ include "application.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Selector labels for one component.
Usage: {{ include "application.componentSelectorLabels" (dict "root" $ "component" "worker" "name" "consumer") }}
*/}}
{{- define "application.componentSelectorLabels" -}}
{{ include "application.selectorLabels" .root }}
app.kubernetes.io/component: {{ .component }}
{{- if .name }}
app.kubernetes.io/part-of: {{ include "application.name" .root }}
{{- end }}
{{- if and .name (eq .component "worker") }}
app.kubernetes.io/worker: {{ .name }}
{{- end }}
{{- if and .name (eq .component "cronjob") }}
app.kubernetes.io/cronjob: {{ .name }}
{{- end }}
{{- end }}

{{/*
Full metadata labels (recommended set + chart + commonLabels).
Usage: {{ include "application.labels" (dict "root" $ "component" "app" "name" "") }}
       {{ include "application.labels" $ }}   ← legacy form, component defaults to "app"
*/}}
{{- define "application.labels" -}}
{{- $root := . -}}
{{- $component := "app" -}}
{{- $name := "" -}}
{{- if kindIs "map" . -}}
  {{- if hasKey . "root" -}}
    {{- $root = .root -}}
    {{- $component = .component | default "app" -}}
    {{- $name = .name | default "" -}}
  {{- end -}}
{{- end -}}
helm.sh/chart: {{ include "application.chart" $root }}
{{ include "application.componentSelectorLabels" (dict "root" $root "component" $component "name" $name) }}
{{- if $root.Chart.AppVersion }}
app.kubernetes.io/version: {{ $root.Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ $root.Release.Service }}
{{- with $root.Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Annotations applied to every object: commonAnnotations (+ optional Reloader).
*/}}
{{- define "application.annotations" -}}
{{- $ann := deepCopy (.Values.commonAnnotations | default dict) -}}
{{- if .Values.reloader.enabled -}}
  {{- if eq .Values.reloader.mode "auto" -}}
    {{- $_ := set $ann "reloader.stakater.com/auto" "true" -}}
  {{- else -}}
    {{- with .Values.reloader.configmaps }}{{- $_ := set $ann "configmap.reloader.stakater.com/reload" (join "," .) -}}{{- end -}}
    {{- with .Values.reloader.secrets }}{{- $_ := set $ann "secret.reloader.stakater.com/reload" (join "," .) -}}{{- end -}}
  {{- end -}}
{{- end -}}
{{- with $ann }}
{{- toYaml . }}
{{- end }}
{{- end }}

{{/*
Rollout is triggered only by config this chart OWNS. Secrets pulled in through
`extraEnvFrom` are owned elsewhere (ESO / SealedSecrets) — use `reloader` for
those, a checksum here could not see their content.
*/}}
{{- define "application.checksumAnnotations" -}}
{{- if and .Values.configmap.enabled .Values.configmap.data }}
checksum/configmap: {{ toYaml .Values.configmap.data | sha256sum }}
{{- end }}
{{- if and .Values.secret.enabled (or .Values.secret.data .Values.secret.stringData) }}
checksum/secret: {{ printf "%s%s" (toYaml (.Values.secret.data | default dict)) (toYaml (.Values.secret.stringData | default dict)) | sha256sum }}
{{- end }}
{{- if .Values.secretEnv }}
checksum/secret-env: {{ toYaml .Values.secretEnv | sha256sum }}
{{- end }}
{{- end }}
