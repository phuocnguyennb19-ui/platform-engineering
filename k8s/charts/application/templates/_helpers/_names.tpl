{{/*
===============================================================================
NAMING — chart/release names and the derived object names.
===============================================================================
*/}}

{{/*
===============================================================================
NAMING
===============================================================================
*/}}

{{- define "application.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{- define "application.namespace" -}}
{{- .Values.namespaceOverride | default .Release.Namespace | default "default" -}}
{{- end }}

{{- define "application.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "application.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{- define "application.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "application.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end }}

{{/*
===============================================================================
CONFIGMAP / SECRET NAMES + CHECKSUMS
===============================================================================
*/}}

{{- define "application.configmapName" -}}
{{- .Values.configmap.nameOverride | default (printf "%s-config" (include "application.fullname" .)) | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{- define "application.secretName" -}}
{{- .Values.secret.nameOverride | default (printf "%s-secret" (include "application.fullname" .)) | trunc 63 | trimSuffix "-" -}}
{{- end }}
