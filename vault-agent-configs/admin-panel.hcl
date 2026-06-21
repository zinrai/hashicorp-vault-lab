pid_file = "/tmp/pidfile"

vault {
  address         = "https://vault:8200"
  ca_cert         = "/vault-tls/vault-ca.pem"
  tls_server_name = "localhost"
}

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
{{ with secret "database/creds/main-readonly" -}}
{ "username": {{ .Data.username | toJSON }}, "password": {{ .Data.password | toJSON }}, "lease_id": "{{ .LeaseID }}", "lease_duration": {{ .LeaseDuration }} }
{{- end }}
EOT
  destination = "/vault/file/db-main.json"
  perms       = "0400"
}

template {
  contents    = <<EOT
{{ with secret "pki_int/issue/admin-panel" "common_name=admin.lab.example.local" "ttl=1h" -}}
{ "certificate": {{ .Data.certificate | toJSON }}, "private_key": {{ .Data.private_key | toJSON }}, "issuing_ca": {{ .Data.issuing_ca | toJSON }} }
{{- end }}
EOT
  destination = "/vault/file/pki.json"
  perms       = "0400"
}
