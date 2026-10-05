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
{{ with secret "secret/data/notification/sendgrid" -}}
{{ .Data.data | toJSON }}
{{- end }}
EOT
  destination = "/vault/file/kv-sendgrid.json"
  perms       = "0400"
}

template {
  contents    = <<EOT
{{ with secret "secret/data/notification/webhook" -}}
{{ .Data.data | toJSON }}
{{- end }}
EOT
  destination = "/vault/file/kv-webhook.json"
  perms       = "0400"
}
