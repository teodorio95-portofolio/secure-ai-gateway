{{- define "ai-gateway.labels" -}}
app.kubernetes.io/part-of: secure-ai-gateway
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{/*
DNS egress to kube-dns through Cilium's DNS proxy (L7 rule). The proxy is what
lets toFQDNs rules learn which IPs a name resolved to; it also means DNS is
allowed only here, never by a plain NetworkPolicy on the same pods.
*/}}
{{- define "ai-gateway.dnsEgress" -}}
- toEndpoints:
    - matchLabels:
        k8s:io.kubernetes.pod.namespace: kube-system
        k8s-app: kube-dns
  toPorts:
    - ports:
        - port: "53"
          protocol: ANY
      rules:
        dns:
          - matchPattern: "*"
{{- end -}}
