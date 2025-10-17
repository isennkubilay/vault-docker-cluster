storage "raft" {
  path    = "/vault/data"
  node_id = "vault-1"
}

listener "tcp" {
  address       = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_disable   = true
}

api_addr     = "http://vault-1:8200"
cluster_addr = "http://vault-1:8201"

ui = true
disable_mlock = true