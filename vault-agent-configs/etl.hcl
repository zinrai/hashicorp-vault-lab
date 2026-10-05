pid_file = "/tmp/pidfile"

auto_auth {
  method "approle" {
    config = {
      role_id_file_path                   = "/vault-creds/role-id"
      secret_id_file_path                 = "/vault-creds/secret-id"
      remove_secret_id_file_after_reading = false
    }
  }
  sink "file" {
    config = {
      path = "/tmp/token"
    }
  }
}

template {
  contents    = <<EOT
{{ with secret "database/creds/main-long" -}}
{ "username": {{ .Data.username | toJSON }}, "password": {{ .Data.password | toJSON }}, "lease_id": "{{ .LeaseID }}", "lease_duration": {{ .LeaseDuration }} }
{{- end }}
EOT
  destination = "/vault/file/db-main.json"
  perms       = "0400"
}

template {
  contents    = <<EOT
{{ with secret "database/creds/analytics-readwrite" -}}
{ "username": {{ .Data.username | toJSON }}, "password": {{ .Data.password | toJSON }}, "lease_id": "{{ .LeaseID }}", "lease_duration": {{ .LeaseDuration }} }
{{- end }}
EOT
  destination = "/vault/file/db-analytics.json"
  perms       = "0400"
}
