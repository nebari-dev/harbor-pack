{{/*
Expand the name of the chart.
*/}}
{{- define "harbor-pack.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "harbor-pack.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "harbor-pack.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "harbor-pack.labels" -}}
helm.sh/chart: {{ include "harbor-pack.chart" . }}
{{ include "harbor-pack.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "harbor-pack.selectorLabels" -}}
app.kubernetes.io/name: {{ include "harbor-pack.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Harbor front service name.
The upstream chart names the nginx ClusterIP service literally after
expose.clusterIP.name (NOT release-prefixed). This is the service the
NebariApp routes to and that the OIDC config Job talks to (it proxies
/api/v2.0/* to core on port 80).
*/}}
{{- define "harbor-pack.harbor-service-name" -}}
{{- .Values.harbor.expose.clusterIP.name | default "harbor" }}
{{- end }}

{{/*
Harbor front service HTTP port.
*/}}
{{- define "harbor-pack.harbor-service-port" -}}
{{- .Values.harbor.expose.clusterIP.ports.httpPort | default 80 }}
{{- end }}

{{/*
Replicate the upstream Harbor fullname logic so we can address its generated
resources (e.g. the core Secret) from the parent chart. The subchart's chart
name is fixed as "harbor".
*/}}
{{- define "harbor-pack.harbor-fullname" -}}
{{- if .Values.harbor.fullnameOverride }}
{{- .Values.harbor.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default "harbor" .Values.harbor.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Secret holding the Harbor admin password. The upstream chart writes it to the
core Secret (<harbor-fullname>-core) under key HARBOR_ADMIN_PASSWORD.
*/}}
{{- define "harbor-pack.admin-secret-name" -}}
{{- if .Values.oidcSetup.adminPasswordSecret }}
{{- .Values.oidcSetup.adminPasswordSecret }}
{{- else }}
{{- printf "%s-core" (include "harbor-pack.harbor-fullname" .) }}
{{- end }}
{{- end }}

{{/*
Secret created by the nebari-operator holding the provisioned OIDC client
credentials: <nebariapp-fullname>-oidc-client (keys client-id, client-secret,
issuer-url).
*/}}
{{- define "harbor-pack.oidc-secret-name" -}}
{{- printf "%s-oidc-client" (include "harbor-pack.fullname" .) }}
{{- end }}

{{/*
Name shared by the stable-secrets provisioning hook's ServiceAccount, Role,
RoleBinding and Job.
*/}}
{{- define "harbor-pack.stable-secrets.name" -}}
{{- printf "%s-stable-secrets" (include "harbor-pack.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
The registry credential username upstream authenticates with. It is NOT stored
in the Secret (only the password and the htpasswd line are), so the provisioning
Job must hash exactly the name the deployments will send.
*/}}
{{- define "harbor-pack.stable-secrets.registry-username" -}}
{{- dig "registry" "credentials" "username" "" (.Values.harbor | default dict) | default "harbor_registry_user" }}
{{- end }}

{{/*
Fan-out map: the seven upstream Harbor values keys that must point at the two
stable Secrets, keyed by dotted path under `harbor:` with the expected value.
Used by both the validation below and the docs/error message so they cannot
drift apart.
*/}}
{{- define "harbor-pack.stable-secrets.expected" -}}
{{- $s := .Values.stableSecrets -}}
{{- $internal := $s.internalSecret | default "" -}}
{{- $tokenSigning := $s.tokenSigningSecret | default "" -}}
{{- dict
      "existingSecretSecretKey" $internal
      "core.existingSecret" $internal
      "core.existingXsrfSecret" $internal
      "core.secretName" $tokenSigning
      "jobservice.existingSecret" $internal
      "registry.existingSecret" $internal
      "registry.credentials.existingSecret" $internal
    | toJson -}}
{{- end }}

{{/*
Validate the stableSecrets fan-out.

Helm cannot set a subchart's values from a parent template - `.Values.harbor` is
handed to the upstream chart as data, and templates cannot mutate it. So the
fan-out cannot be applied automatically; instead this fails the render with the
exact block to paste when `stableSecrets.enabled` is true but the upstream keys
do not point at the two Secret names. Renders nothing on success.
*/}}
{{- define "harbor-pack.stable-secrets.validate" -}}
{{- $s := .Values.stableSecrets -}}
{{- $h := .Values.harbor | default dict -}}
{{- $internal := $s.internalSecret | default "" -}}
{{- $tokenSigning := $s.tokenSigningSecret | default "" -}}
{{- if or (eq $internal "") (eq $tokenSigning "") -}}
{{- fail "stableSecrets.enabled is true but stableSecrets.internalSecret and/or stableSecrets.tokenSigningSecret is empty. Both Secret names are required; see examples/gitops-values.yaml." -}}
{{- end -}}
{{- $expected := include "harbor-pack.stable-secrets.expected" . | fromJson -}}
{{- $actual := dict
      "existingSecretSecretKey" (dig "existingSecretSecretKey" "" $h)
      "core.existingSecret" (dig "core" "existingSecret" "" $h)
      "core.existingXsrfSecret" (dig "core" "existingXsrfSecret" "" $h)
      "core.secretName" (dig "core" "secretName" "" $h)
      "jobservice.existingSecret" (dig "jobservice" "existingSecret" "" $h)
      "registry.existingSecret" (dig "registry" "existingSecret" "" $h)
      "registry.credentials.existingSecret" (dig "registry" "credentials" "existingSecret" "" $h) -}}
{{- $wrong := list -}}
{{- range $key, $want := $expected -}}
  {{- $got := index $actual $key | toString -}}
  {{- if ne $got $want -}}
    {{- $wrong = append $wrong (printf "  harbor.%s = %q (expected %q)" $key $got $want) -}}
  {{- end -}}
{{- end -}}
{{- $block := printf "harbor:\n  existingSecretSecretKey: %s\n  core:\n    existingSecret: %s\n    existingXsrfSecret: %s\n    secretName: %s\n  jobservice:\n    existingSecret: %s\n  registry:\n    existingSecret: %s\n    credentials:\n      existingSecret: %s" $internal $internal $internal $tokenSigning $internal $internal $internal -}}
{{- if dig "adminPassword" "enabled" false $s -}}
  {{- $adminSecret := dig "adminPassword" "secretName" "" $s -}}
  {{- $adminKey := dig "adminPassword" "key" "" $s -}}
  {{- if or (eq $adminSecret "") (eq $adminKey "") -}}
    {{- fail "stableSecrets.adminPassword.enabled is true but stableSecrets.adminPassword.secretName and/or .key is empty." -}}
  {{- end -}}
  {{- $gotName := dig "existingSecretAdminPassword" "" $h | toString -}}
  {{- $gotKey := dig "existingSecretAdminPasswordKey" "" $h | toString -}}
  {{- if ne $gotName $adminSecret -}}
    {{- $wrong = append $wrong (printf "  harbor.existingSecretAdminPassword = %q (expected %q)" $gotName $adminSecret) -}}
  {{- end -}}
  {{- if ne $gotKey $adminKey -}}
    {{- $wrong = append $wrong (printf "  harbor.existingSecretAdminPasswordKey = %q (expected %q)" $gotKey $adminKey) -}}
  {{- end -}}
  {{- $block = printf "%s\n  existingSecretAdminPassword: %s\n  existingSecretAdminPasswordKey: %s" $block $adminSecret $adminKey -}}
{{- end -}}
{{- if $wrong -}}
{{- fail (printf "stableSecrets.enabled is true, but the upstream Harbor values that select the pre-created Secrets are not set (or do not match). Helm cannot set subchart values from a parent template, so these must be supplied alongside stableSecrets.\n\nMismatched:\n%s\n\nAdd to your values:\n\n%s\n\nA ready-made file is committed at examples/gitops-values.yaml.\n" (join "\n" $wrong) $block) -}}
{{- end -}}
{{- end }}
