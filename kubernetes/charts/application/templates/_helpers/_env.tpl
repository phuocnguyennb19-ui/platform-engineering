{{/*
===============================================================================
ENVIRONMENT — inherited env/envFrom with per-container override.
===============================================================================
*/}}

{{/*
===============================================================================
ENV — base inherited by EVERY container, overridden per container.

  .Values.env        (public, map)
  .Values.secretEnv  (map — rendered INLINE as `value:`; see SECURITY note)
  <container>.env    (map — wins)

Every value passes through `tpl` against the ROOT context, so Helm expressions
resolve at render time. `envRaw` is appended verbatim for the cases a map
cannot express (valueFrom: fieldRef / secretKeyRef / resourceFieldRef).

SECURITY: `env` / `secretEnv` values land in the pod spec in plain text and are
readable via `kubectl get <workload> -o yaml`, in etcd, and in the Helm release
secret. For real credentials use `extraEnvFrom` (secretRef) or `envRaw` with
`valueFrom.secretKeyRef` — never `secretEnv`.

Usage: {{- $e := include "application.env" (dict "root" $ "c" $c) | trim }}
===============================================================================
*/}}
{{- define "application.env" -}}
{{- $root := .root -}}
{{- $c := .c | default dict -}}
{{- $merged := dict -}}
{{- range $k, $v := ($root.Values.env | default dict) }}{{- $_ := set $merged $k $v -}}{{- end }}
{{- range $k, $v := ($root.Values.secretEnv | default dict) }}{{- $_ := set $merged $k $v -}}{{- end }}
{{- range $k, $v := ($c.env | default dict) }}{{- $_ := set $merged $k $v -}}{{- end }}
{{- range $k := (keys $merged | sortAlpha) }}
{{- $v := index $merged $k }}
- name: {{ $k }}
  value: {{ tpl (printf "%v" $v) $root | quote }}
{{- end }}
{{- with (concat ($root.Values.envRaw | default list) ($c.envRaw | default list)) }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
envFrom — chart-owned ConfigMap/Secret plus anything declared externally.
*/}}
{{- define "application.envFrom" -}}
{{- $root := .root -}}
{{- $c := .c | default dict -}}
{{- if $root.Values.configmap.enabled }}
- configMapRef:
    name: {{ include "application.configmapName" $root }}
{{- end }}
{{- if $root.Values.secret.enabled }}
- secretRef:
    name: {{ include "application.secretName" $root }}
{{- end }}
{{- if and $root.Values.externalSecret.enabled $root.Values.externalSecret.injectEnvFrom }}
- secretRef:
    name: {{ $root.Values.externalSecret.target.name | default (include "application.fullname" $root) }}
{{- end }}
{{- with (concat ($root.Values.extraEnvFrom | default list) ($c.extraEnvFrom | default list)) }}
{{ toYaml . }}
{{- end }}
{{- end }}
