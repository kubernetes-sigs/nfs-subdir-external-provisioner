
{{/* 
   Allow namespace to be overriden
*/}}
{{- define "common.name.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* vim: set filetype=mustache: */}}
{{/*
Expand the name of the chart.
*/}}
{{- define "nfs-subdir-external-provisioner.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "nfs-subdir-external-provisioner.fullname" -}}
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
{{- end -}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "nfs-subdir-external-provisioner.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "nfs-subdir-external-provisioner.provisionerName" -}}
{{- if .Values.storageClass.provisionerName -}}
{{- printf .Values.storageClass.provisionerName -}}
{{- else -}}
cluster.local/{{ template "nfs-subdir-external-provisioner.fullname" . -}}
{{- end -}}
{{- end -}}

{{/*
Create the name of the service account to use
*/}}
{{- define "nfs-subdir-external-provisioner.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
    {{ default (include "nfs-subdir-external-provisioner.fullname" .) .Values.serviceAccount.name }}
{{- else -}}
    {{ default "default" .Values.serviceAccount.name }}
{{- end -}}
{{- end -}}

{{/*
Return the appropriate apiVersion for podSecurityPolicy.
*/}}
{{- define "podSecurityPolicy.apiVersion" -}}
{{- if semverCompare ">=1.10-0" .Capabilities.KubeVersion.GitVersion -}}
{{- print "policy/v1beta1" -}}
{{- else -}}
{{- print "extensions/v1beta1" -}}
{{- end -}}
{{- end -}}

{{/*
Return the appropriate apiVersion for podDisruptionBudget.
*/}}
{{- define "podDisruptionBudget.apiVersion" -}}
{{- if semverCompare ">=1.21-0" .Capabilities.KubeVersion.GitVersion -}}
{{- print "policy/v1" -}}
{{- else -}}
{{- print "policy/v1beta1" -}}
{{- end -}}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "nfs-subdir-external-provisioner.labels" -}}
chart: {{ template "nfs-subdir-external-provisioner.chart" . }}
heritage: {{ .Release.Service }}
{{ include "nfs-subdir-external-provisioner.selectorLabels" . }}
{{- with .Values.labels }}
{{- toYaml . | nindent 0 }}
{{- end }}
{{- end }}

{{/*
Pod template labels
*/}}
{{- define "nfs-subdir-external-provisioner.podLabels" -}}
{{ include "nfs-subdir-external-provisioner.selectorLabels" . }}
{{- with .Values.labels }}
{{- toYaml . | nindent 0 }}
{{- end }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "nfs-subdir-external-provisioner.selectorLabels" -}}
app: {{ template "nfs-subdir-external-provisioner.name" . }}
release: {{ .Release.Name }}
{{- end }}

{{/*
Return true if an existing configmap name has been provided 
*/}}
{{- define "nfs.existing-configmap-provided" -}}
{{- if  .Values.nfs.existingConfigMap.name -}}
    {{- true -}}
{{- end -}}
{{- end -}}

{{/*
Return the existing NFS Configmap Name
*/}}
{{- define "nfs.existing-configmap" -}}
     {{- if .Values.nfs.existingConfigMap.name -}}
         {{- printf "%s" (tpl .Values.nfs.existingConfigMap.name $) -}}
     {{- else -}}
         {{- printf "\n%s CONFIGMAP ERROR: no existing configmap has been provided" }}
     {{- end -}}
{{- end }}


{{/*
Reuses the value from an existing configmap, otherwise sets its value to a default value.

Usage:
{{ include "common.configmap.lookup" (dict "secret" "configmap-name" "key" "keyName" "defaultValue" .Values.myValue "context" $) }}

Params:
  - configmapName - String - Required - Name of the 'Secret' resource where the password is stored.
  - key - String - Required - Name of the key in the secret.
  - defaultValue - String - Required - The path to the validating value in the values.yaml, e.g: "mysql.password". Will pick first parameter with a defined value.
  - context - Context - Required - Parent context.

*/}}
{{- define "common.configmap.lookup" -}}
{{- $value := "" -}}
{{- $configmapData := (lookup "v1" "ConfigMap" (include "common.names.namespace" .context) .configmapName).data -}}
{{- if and $configmapData (hasKey $configmapData .key) -}}
  {{- $value = index $configmapData .key -}}
{{- else if .defaultValue -}}
  {{- $value = .defaultValue | toString  -}}
{{- end -}}
{{- if $value -}}
{{- printf "%s" $value -}}
{{- end -}}
{{- end -}}
