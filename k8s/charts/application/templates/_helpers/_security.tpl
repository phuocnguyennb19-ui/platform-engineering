{{/*
===============================================================================
SECURITY CONTEXT — three-level merge, wired into every workload.
===============================================================================
*/}}

{{/*
===============================================================================
SECURITY CONTEXT — three-level merge, actually wired into every workload.

  global.podSecurityContext          (platform-wide)
    → securityDefaults.podSecurityContext   (chart/base-values hardening)
      → podSecurityContext                  (per-service override)
        → <component>.podSecurityContext    (per-worker / per-cronjob override)

deepCopy is mandatory: mergeOverwrite mutates its first argument, and that
argument is a live reference into .Values — without it one component's override
would leak into every later render in the same release.
===============================================================================
*/}}

{{- define "application.podSecurityContext" -}}
{{- $root := .root -}}
{{- $c := .c | default dict -}}
{{- $merged := deepCopy ($root.Values.global.podSecurityContext | default dict) -}}
{{- $merged = mergeOverwrite $merged (deepCopy ($root.Values.securityDefaults.podSecurityContext | default dict)) -}}
{{- $merged = mergeOverwrite $merged (deepCopy ($root.Values.podSecurityContext | default dict)) -}}
{{- $merged = mergeOverwrite $merged (deepCopy ($c.podSecurityContext | default dict)) -}}
{{- with $merged }}
{{- toYaml . }}
{{- end }}
{{- end }}

{{- define "application.containerSecurityContext" -}}
{{- $root := .root -}}
{{- $c := .c | default dict -}}
{{- $merged := deepCopy ($root.Values.global.securityContext | default dict) -}}
{{- $merged = mergeOverwrite $merged (deepCopy ($root.Values.securityDefaults.containerSecurityContext | default dict)) -}}
{{- $merged = mergeOverwrite $merged (deepCopy ($root.Values.securityContext | default dict)) -}}
{{- $merged = mergeOverwrite $merged (deepCopy ($c.securityContext | default dict)) -}}
{{- with $merged }}
{{- toYaml . }}
{{- end }}
{{- end }}
