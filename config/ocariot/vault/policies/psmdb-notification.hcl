path "secret/data/vault/ca" {
  capabilities = ["read"]
}

path "pki/issue/psmdb-notification" {
  capabilities = ["read","update"]
}

path "secret/data/psmdb-notification/*" {
  capabilities = ["create", "read"]
}
