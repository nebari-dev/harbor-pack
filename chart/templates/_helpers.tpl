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
Secret holding the Harbor admin password, for the OIDC-setup Job to read.

The upstream chart writes the password into its core Secret
(<harbor-fullname>-core, key HARBOR_ADMIN_PASSWORD) - but ONLY while
harbor.existingSecretAdminPassword is unset. Once it is set (as stableSecrets'
optional admin-password provisioning requires) upstream omits the key entirely,
so defaulting to the core Secret would leave the Job in
CreateContainerConfigError. Follow harbor.existingSecretAdminPassword when it is
set; an explicit oidcSetup.adminPasswordSecret still wins over both.
*/}}
{{- define "harbor-pack.admin-secret-name" -}}
{{- $harborAdminSecret := dig "existingSecretAdminPassword" "" (.Values.harbor | default dict) -}}
{{- if .Values.oidcSetup.adminPasswordSecret }}
{{- .Values.oidcSetup.adminPasswordSecret }}
{{- else if $harborAdminSecret }}
{{- $harborAdminSecret }}
{{- else }}
{{- printf "%s-core" (include "harbor-pack.harbor-fullname" .) }}
{{- end }}
{{- end }}

{{/*
Key within the Secret above. Mirrors the name resolution: when the name comes
from harbor.existingSecretAdminPassword, the key must come from its companion
harbor.existingSecretAdminPasswordKey (upstream default HARBOR_ADMIN_PASSWORD).
*/}}
{{- define "harbor-pack.admin-secret-key" -}}
{{- $harborAdminSecret := dig "existingSecretAdminPassword" "" (.Values.harbor | default dict) -}}
{{- if .Values.oidcSetup.adminPasswordSecret }}
{{- .Values.oidcSetup.adminPasswordKey }}
{{- else if $harborAdminSecret }}
{{- dig "existingSecretAdminPasswordKey" "HARBOR_ADMIN_PASSWORD" (.Values.harbor | default dict) | default "HARBOR_ADMIN_PASSWORD" }}
{{- else }}
{{- .Values.oidcSetup.adminPasswordKey }}
{{- end }}
{{- end }}

{{/*
Render a values-supplied string as a single-quoted /bin/sh literal for the
bootstrap Job's script, so project/group/pattern values cannot be re-split or
expanded by the shell.

Two layers of escaping are needed because two things read the script:
  1. the kubelet expands $(VAR) references in a container's command BEFORE the
     container starts, so every "$" is doubled ("$$" is Kubernetes' escape for
     a literal "$"). Without this, a value like $(HARBOR_ADMIN_PASSWORD) would
     be substituted with the admin password - which the Job then logs - and an
     apostrophe in the substituted value would break the quoting. Doubling
     (rather than rejecting "$") keeps names like robot$scanner usable.
  2. /bin/sh: the value is single-quoted and any embedded ' is escaped.

Characters that would corrupt the hand-assembled JSON payloads (the job image
has no jq) or the YAML block scalar - quotes, backslashes and control
characters - are rejected at template time.
Usage: {{ include "harbor-pack.sh-literal" $value }}
*/}}
{{- define "harbor-pack.sh-literal" -}}
{{- $v := toString . -}}
{{- if or (contains "\"" $v) (contains "\\" $v) -}}
{{- fail (printf "bootstrap: value %q must not contain double quotes or backslashes" $v) -}}
{{- end -}}
{{- if regexMatch "[[:cntrl:]]" $v -}}
{{- fail (printf "bootstrap: value %q must not contain control characters (newline, tab, CR, ...)" $v) -}}
{{- end -}}
{{- printf "'%s'" (replace "$" "$$" (replace "'" "'\\''" $v)) -}}
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
{{/*
  Three of upstream's existing-Secret options let you rename the key they read
  inside the Secret. The provisioning Job writes the default names, so a renamed
  selector would point the pods at a key that is not there. Require the defaults.
*/}}
{{- $keySelectors := dict
      "core.existingXsrfSecretKey" (list (dig "core" "existingXsrfSecretKey" "" $h | toString) "CSRF_KEY")
      "jobservice.existingSecretKey" (list (dig "jobservice" "existingSecretKey" "" $h | toString) "JOBSERVICE_SECRET")
      "registry.existingSecretKey" (list (dig "registry" "existingSecretKey" "" $h | toString) "REGISTRY_HTTP_SECRET") -}}
{{- range $key, $pair := $keySelectors -}}
  {{- $got := index $pair 0 -}}
  {{- $want := index $pair 1 -}}
  {{- if ne $got $want -}}
    {{- $wrong = append $wrong (printf "  harbor.%s = %q (must be %q - the Secret is written with the default key names)" $key $got $want) -}}
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
