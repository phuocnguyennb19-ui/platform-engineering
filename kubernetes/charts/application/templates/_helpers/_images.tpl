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

The main image (`.Values.image`) is inherited only by a map that names no other
repository: an empty map (an initContainer without `image`) is the application
image — registry, digest and all. A map with its own tag and no digest drops the
application digest, which would otherwise win over that tag. A map with a
different repository inherits nothing but global.imageRegistry, and must carry
its own tag or digest.

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
{{- $global := $root.Values.global.imageRegistry | default "" -}}
{{- $sameRepo := or (not $img.repository) (eq $img.repository $base.repository) -}}
{{- $repository := $img.repository | default $base.repository -}}
{{- $registry := "" -}}
{{- $digest := "" -}}
{{- $tag := "" -}}
{{- if $sameRepo -}}
  {{- $registry = $img.registry | default $base.registry | default $global -}}
  {{- if $img.digest -}}
    {{- $digest = $img.digest -}}
    {{- $tag = $img.tag | default $base.tag -}}
  {{- else if $img.tag -}}
    {{- $tag = $img.tag -}}
  {{- else -}}
    {{- $digest = $base.digest | default "" -}}
    {{- $tag = $base.tag | default $root.Chart.AppVersion -}}
  {{- end -}}
{{- else -}}
  {{- $registry = $img.registry | default $global -}}
  {{- $digest = $img.digest | default "" -}}
  {{- $tag = $img.tag | default "" -}}
{{- end -}}
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
