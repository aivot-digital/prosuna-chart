{{- /*
Name and key of the Secret holding one of the chart's secrets, for a secretKeyRef:
Secrets.Refs.<key> if set, otherwise <key> in Secrets.ExistingSecret or the chart's Secret "prosuna".
Usage: include "prosuna.secretKeyRef" (dict "root" $ "key" "SmtpPassword")
*/}}
{{- define "prosuna.secretKeyRef" -}}
{{- $ref := get .root.Values.Secrets.Refs .key | default dict -}}
name: {{ $ref.Secret | default .root.Values.Secrets.ExistingSecret | default "prosuna" | quote }}
key: {{ $ref.Key | default .key | quote }}
{{- end }}

{{- /* Keys of the chart's secrets the deployed components read. */}}
{{- define "prosuna.secretKeys" -}}
{{- $keys := list "SecretsKey" "CaptchaKey" "SmtpPassword" "KeycloakBackendClientSecret" }}
{{- if not .Values.Keycloak.Url }}
{{- $keys = concat $keys (list "KeycloakBootstrapAdminPassword" "KeycloakAdminPassword" "KeycloakDeploymentClientSecret") }}
{{- end }}
{{- toJson $keys }}
{{- end }}
