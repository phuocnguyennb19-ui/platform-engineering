{{/*
===============================================================================
SHARED POD SPEC

One implementation of the pod spec, used by every workload the chart produces:
Deployment / StatefulSet / DaemonSet / worker Deployments / CronJob job
templates. A knob added here is available to all of them at once — that is what
keeps "declare a value and it maps through" true instead of aspirational.

Usage:
  {{- include "application.podSpec" (dict
        "root" $
        "c" $c                  ← effective config from application.componentConfig
        "component" "app"       ← app | worker | cronjob
        "name" "consumer"       ← main container name
        "httpPort" true         ← expose the service port as a container port named `http`
        "proxy" true            ← app workload only: add the nginx sidecar when proxy.enabled
     ) | nindent 6 }}
===============================================================================
*/}}
{{- define "application.podSpec" -}}
{{- $root := .root -}}
{{- $c := .c -}}
{{- $component := .component -}}
{{- $name := .name -}}
{{- $httpPort := .httpPort | default false -}}
{{- $proxy := and (.proxy | default false) ($root.Values.proxy).enabled -}}
{{- with $c.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
serviceAccountName: {{ include "application.serviceAccountName" $root }}
automountServiceAccountToken: {{ $c.automountServiceAccountToken | default false }}
{{- if $c.restartPolicy }}
restartPolicy: {{ $c.restartPolicy }}
{{- end }}
{{- if not (eq $component "cronjob") }}
terminationGracePeriodSeconds: {{ $c.terminationGracePeriodSeconds | default 30 }}
{{- end }}
{{- with $c.priorityClassName }}
priorityClassName: {{ . }}
{{- end }}
{{- with $c.runtimeClassName }}
runtimeClassName: {{ . }}
{{- end }}
{{- with $c.schedulerName }}
schedulerName: {{ . }}
{{- end }}
{{- if $c.hostNetwork }}
hostNetwork: true
{{- end }}
{{- if $c.hostPID }}
hostPID: true
{{- end }}
{{- if $c.hostIPC }}
hostIPC: true
{{- end }}
{{- if $c.shareProcessNamespace }}
shareProcessNamespace: true
{{- end }}
{{- with $c.hostAliases }}
hostAliases:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $c.dnsPolicy }}
dnsPolicy: {{ . }}
{{- end }}
{{- with $c.dnsConfig }}
dnsConfig:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- $podSec := include "application.podSecurityContext" (dict "root" $root "c" $c) | trim }}
{{- if $podSec }}
securityContext:
  {{- $podSec | nindent 2 }}
{{- end }}

{{- /* ── initContainers ─────────────────────────────────────────────────── */}}
{{- if $c.initContainers }}
initContainers:
  {{- range $c.initContainers }}
  - name: {{ .name }}
    image: {{ include "application.image" (dict "root" $root "image" (.image | default dict)) }}
    imagePullPolicy: {{ (.image).pullPolicy | default $root.Values.image.pullPolicy | default "IfNotPresent" }}
    {{- with .command }}
    command:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- with .args }}
    args:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- if .restartPolicy }}
    restartPolicy: {{ .restartPolicy }}   {{- /* `Always` = native sidecar (k8s >= 1.29) */}}
    {{- end }}
    {{- $initSec := include "application.containerSecurityContext" (dict "root" $root "c" (dict "securityContext" (mergeOverwrite (deepCopy ($c.securityContext | default dict)) (deepCopy (.securityContext | default dict))))) | trim }}
    {{- if $initSec }}
    securityContext:
      {{- $initSec | nindent 6 }}
    {{- end }}
    {{- $initEnv := include "application.env" (dict "root" $root "c" .) | trim }}
    {{- if $initEnv }}
    env:
      {{- $initEnv | nindent 6 }}
    {{- end }}
    {{- $initEnvFrom := include "application.envFrom" (dict "root" $root "c" .) | trim }}
    {{- if $initEnvFrom }}
    envFrom:
      {{- $initEnvFrom | nindent 6 }}
    {{- end }}
    {{- with (.resources | default $c.resources) }}
    resources:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- with (concat ($c.extraVolumeMounts | default list) (.extraVolumeMounts | default list)) }}
    volumeMounts:
      {{- toYaml . | nindent 6 }}
    {{- end }}
  {{- end }}
{{- end }}

{{- /* ── containers ─────────────────────────────────────────────────────── */}}
containers:
  - name: {{ $name }}
    image: {{ include "application.image" (dict "root" $root "image" ($c.image | default dict)) }}
    imagePullPolicy: {{ ($c.image).pullPolicy | default "IfNotPresent" }}
    {{- with $c.command }}
    command:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- with $c.args }}
    args:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- $ctrSec := include "application.containerSecurityContext" (dict "root" $root "c" $c) | trim }}
    {{- if $ctrSec }}
    securityContext:
      {{- $ctrSec | nindent 6 }}
    {{- end }}
    {{- $ports := list }}
    {{- if $proxy }}
      {{- /* `http` belongs to the nginx sidecar; the app keeps its port as `app`. */}}
      {{- $ports = append $ports (dict "name" "app" "containerPort" (int $root.Values.proxy.upstreamPort) "protocol" "TCP") }}
    {{- else if $httpPort }}
      {{- $ports = append $ports (dict "name" "http" "containerPort" (int ($root.Values.service.targetPort | default $root.Values.service.port)) "protocol" "TCP") }}
    {{- end }}
    {{- range ($c.extraPorts | default list) }}
      {{- $ports = append $ports . }}
    {{- end }}
    {{- with $ports }}
    ports:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- with ($c.probes).startup }}
    startupProbe:
      {{- if $proxy }}
      {{- include "application.proxy.appProbe" . | nindent 6 }}
      {{- else }}
      {{- toYaml . | nindent 6 }}
      {{- end }}
    {{- end }}
    {{- with ($c.probes).liveness }}
    livenessProbe:
      {{- if $proxy }}
      {{- include "application.proxy.appProbe" . | nindent 6 }}
      {{- else }}
      {{- toYaml . | nindent 6 }}
      {{- end }}
    {{- end }}
    {{- with ($c.probes).readiness }}
    readinessProbe:
      {{- if $proxy }}
      {{- include "application.proxy.appProbe" . | nindent 6 }}
      {{- else }}
      {{- toYaml . | nindent 6 }}
      {{- end }}
    {{- end }}
    {{- $env := include "application.env" (dict "root" $root "c" $c) | trim }}
    {{- if $env }}
    env:
      {{- $env | nindent 6 }}
    {{- end }}
    {{- $envFrom := include "application.envFrom" (dict "root" $root "c" $c) | trim }}
    {{- if $envFrom }}
    envFrom:
      {{- $envFrom | nindent 6 }}
    {{- end }}
    {{- with $c.resources }}
    resources:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- $lifecycle := $c.lifecycle }}
    {{- if $proxy }}
      {{- $lifecycle = include "application.proxy.appLifecycle" (dict "root" $root "lifecycle" $c.lifecycle) | fromYaml }}
    {{- end }}
    {{- with $lifecycle }}
    lifecycle:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- with $c.extraVolumeMounts }}
    volumeMounts:
      {{- toYaml . | nindent 6 }}
    {{- end }}
  {{- if $proxy }}
  {{- include "application.proxy.container" (dict "root" $root "c" $c) | nindent 2 }}
  {{- end }}

  {{- /* Sidecars — inherit the shared env; their own `env` map wins. */}}
  {{- range $c.extraContainers }}
  - name: {{ .name }}
    {{- with omit . "name" "env" "envRaw" "extraEnvFrom" "inheritEnv" }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
    {{- if ne .inheritEnv false }}
    {{- $xEnv := include "application.env" (dict "root" $root "c" .) | trim }}
    {{- if $xEnv }}
    env:
      {{- $xEnv | nindent 6 }}
    {{- end }}
    {{- $xEnvFrom := include "application.envFrom" (dict "root" $root "c" .) | trim }}
    {{- if $xEnvFrom }}
    envFrom:
      {{- $xEnvFrom | nindent 6 }}
    {{- end }}
    {{- end }}
  {{- end }}

{{- $volumes := $c.extraVolumes }}
{{- if $proxy }}
  {{- $volumes = concat ($c.extraVolumes | default list) (include "application.proxy.volumes" $root | fromYamlArray) }}
{{- end }}
{{- with $volumes }}
volumes:
  {{- toYaml . | nindent 2 }}
{{- end }}

{{- /* ── scheduling ─────────────────────────────────────────────────────── */}}
{{- with $c.topologySpreadConstraints }}
topologySpreadConstraints:
  {{- range . }}
  - maxSkew: {{ .maxSkew | default 1 }}
    topologyKey: {{ .topologyKey | quote }}
    whenUnsatisfiable: {{ .whenUnsatisfiable | default "ScheduleAnyway" }}
    {{- with .minDomains }}
    minDomains: {{ . }}
    {{- end }}
    {{- with .nodeAffinityPolicy }}
    nodeAffinityPolicy: {{ . }}
    {{- end }}
    {{- with .nodeTaintsPolicy }}
    nodeTaintsPolicy: {{ . }}
    {{- end }}
    {{- with .matchLabelKeys }}
    matchLabelKeys:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    labelSelector:
      {{- if .labelSelector }}
      {{- toYaml .labelSelector | nindent 6 }}
      {{- else }}
      matchLabels:
        {{- include "application.componentSelectorLabels" (dict "root" $root "component" $component "name" (ternary $name "" (ne $component "app"))) | nindent 8 }}
      {{- end }}
  {{- end }}
{{- end }}
{{- with $c.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $c.affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $c.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/*
===============================================================================
SHARED POD TEMPLATE METADATA (annotations + labels)
===============================================================================
*/}}
{{- define "application.podTemplateMetadata" -}}
{{- $root := .root -}}
{{- $c := .c -}}
{{- $component := .component -}}
{{- $name := .name | default "" -}}
{{- $ann := include "application.checksumAnnotations" $root | trim -}}
{{- if and (eq $component "app") ($root.Values.proxy).enabled -}}
  {{- $ann = printf "%s\n%s" $ann (include "application.proxy.checksum" $root) | trim -}}
{{- end -}}
{{- $extraAnn := $c.podAnnotations | default dict -}}
{{- if or $ann $extraAnn }}
annotations:
  {{- if $ann }}
  {{- $ann | nindent 2 }}
  {{- end }}
  {{- with $extraAnn }}
  {{- toYaml . | nindent 2 }}
  {{- end }}
{{- end }}
labels:
  {{- include "application.componentSelectorLabels" (dict "root" $root "component" $component "name" $name) | nindent 2 }}
  {{- with $root.Values.commonLabels }}
  {{- toYaml . | nindent 2 }}
  {{- end }}
  {{- with $c.podLabels }}
  {{- toYaml . | nindent 2 }}
  {{- end }}
{{- end }}
