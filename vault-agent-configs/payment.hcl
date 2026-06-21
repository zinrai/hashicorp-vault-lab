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
{{ with secret "secret/data/payment/stripe" -}}
{{ .Data.data | toJSON }}
{{- end }}
EOT
  destination = "/vault/file/kv-stripe.json"
  perms       = "0400"
}

template {
  contents    = <<EOT
{{ with secret "database/creds/payment-short" -}}
{ "username": {{ .Data.username | toJSON }}, "password": {{ .Data.password | toJSON }}, "lease_id": "{{ .LeaseID }}", "lease_duration": {{ .LeaseDuration }} }
{{- end }}
EOT
  destination = "/vault/file/db-payment.json"
  perms       = "0400"
}
