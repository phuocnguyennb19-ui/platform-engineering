{{/*
===============================================================================
IMAGE REFERENCE — registry/repository/tag/digest resolution.
No `latest` fallback: an unresolvable reference fails the render.
===============================================================================
*/}}

{{/*
===============================================================================
IMAGE

Resolution order: digest wins over tag; tag falls back to Chart.AppVersion.
There is NO `latest` fallback — an unresolvable reference fails the render
rather than silently shipping a floating tag (kyverno disallow-latest-tag).

Usage: {{ include "application.image" (dict "root" $ "image" $someImageMap) }}
       {{ include "application.image" $ }}   ← main application image
===============================================================================
*/}}
{{- define "application.image" -}}
{{- $root := . -}}
{{- $img := dict -}}
{{- if and (kindIs "map" .) (hasKey . "root") -}}
  {{- $root = .root -}}
  {{- $img = .image | default dict -}}
{{- else -}}
  {{- $img = $root.Values.image -}}
{{- end -}}
{{- $base := $root.Values.image -}}
{{- $registry := $img.registry | default $root.Values.global.imageRegistry | default "" -}}
{{- $repository := $img.repository | default $base.repository -}}
{{- $digest := $img.digest | default "" -}}
{{- $tag := $img.tag | default $base.tag | default $root.Chart.AppVersion -}}
{{- if not $repository -}}
  {{- fail "image.repository is required" -}}
{{- end -}}
{{- if and (not $digest) (not $tag) -}}
  {{- fail (printf "image tag/digest could not be resolved for %q — set image.tag or image.digest (a `latest` fallback is deliberately not provided)" $repository) -}}
{{- end -}}
{{- if eq (toString $tag) "latest" -}}
  {{- fail "image.tag `latest` is not allowed — pin an immutable tag or digest" -}}
{{- end -}}
{{- if $registry -}}
  {{- $registry = printf "%s/" (trimSuffix "/" $registry) -}}
{{- end -}}
{{- if $digest -}}
  {{- printf "%s%s@%s" $registry $repository $digest -}}
{{- else -}}
  {{- printf "%s%s:%s" $registry $repository (toString $tag) -}}
{{- end -}}
{{- end }}
