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

{{/*
The budget line of a PDB. "" (the default) or null means unset; 0 is a real value
(maxUnavailable: 0 blocks every voluntary eviction), so plain truthiness cannot be used.
  args: dict "pdb" <podDisruptionBudget dict> "what" <name for the error message>
*/}}
{{- define "application.pdb.budget" -}}
{{- $min := .pdb.minAvailable -}}
{{- $max := .pdb.maxUnavailable -}}
{{- $minSet := not (or (kindIs "invalid" $min) (eq (toString $min) "")) -}}
{{- $maxSet := not (or (kindIs "invalid" $max) (eq (toString $max) "")) -}}
{{- if and $minSet $maxSet -}}
{{- fail (printf "%s: set either minAvailable OR maxUnavailable, not both — the API server rejects a PDB with both." .what) -}}
{{- else if $minSet -}}
minAvailable: {{ $min }}
{{- else if $maxSet -}}
maxUnavailable: {{ $max }}
{{- else -}}
maxUnavailable: 1
{{- end -}}
{{- end }}
