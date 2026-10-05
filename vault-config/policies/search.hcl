# main-readonly shared with web-frontend and admin-panel, not split: there
# is no case where stopping search should leave the other two running.
# Sharing a template is a decision, not an oversight. See docs/DECIDING.md 2.

path "database/creds/main-readonly" {
  capabilities = ["read"]
}
