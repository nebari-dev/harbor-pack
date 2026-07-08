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
