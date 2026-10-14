{{/*
===============================================================================
API VERSION DISCOVERY — cluster capability probing.
===============================================================================
*/}}

{{/*
===============================================================================
API VERSION DISCOVERY
===============================================================================
*/}}

{{- define "application.hpa.apiVersion" -}}
{{- if .Capabilities.APIVersions.Has "autoscaling/v2" -}}
autoscaling/v2
{{- else -}}
autoscaling/v2beta2
{{- end -}}
{{- end }}

{{- define "application.pdb.apiVersion" -}}
{{- if .Capabilities.APIVersions.Has "policy/v1" -}}
policy/v1
{{- else -}}
policy/v1beta1
{{- end -}}
{{- end }}
