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
Registry host recorded in the robot Secrets: the host[:port] part of
harbor.externalURL, with the scheme and any path stripped, so a consumer can
build a docker-style auth entry without a second lookup.

Falls back to the in-cluster Harbor front Service when harbor.externalURL is
unset - usable only from inside the cluster and only over plain HTTP, so the
robots Job prints a warning in that case. The fallback is fully qualified
(<service>.<namespace>.svc:<port>) because a consumer reading the Secret may
well run in a different namespace, where the bare Service name would not
resolve - or worse, would resolve to something else.
*/}}
{{- define "harbor-pack.registry-host" -}}
{{- $ext := .Values.harbor.externalURL | default "" -}}
{{- if $ext -}}
{{- $hostPath := regexReplaceAll "^[A-Za-z][A-Za-z0-9+.-]*://" $ext "" -}}
{{- (splitList "/" $hostPath) | first -}}
{{- else -}}
{{- printf "%s.%s.svc:%s" (include "harbor-pack.harbor-service-name" .) .Release.Namespace (include "harbor-pack.harbor-service-port" .) -}}
{{- end -}}
{{- end }}

{{/*
Secret created by the nebari-operator holding the provisioned OIDC client
credentials: <nebariapp-fullname>-oidc-client (keys client-id, client-secret,
issuer-url).
*/}}
{{- define "harbor-pack.oidc-secret-name" -}}
{{- printf "%s-oidc-client" (include "harbor-pack.fullname" .) }}
{{- end }}
