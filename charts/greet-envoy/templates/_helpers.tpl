
{{- define "common.envoyconfigsha" -}}
{{ include (print $.Template.BasePath "/envoy-configmap.yaml") . | sha256sum }}
{{- end -}}
