# Infrastructure for the Yandex Managed Service for OpenSearch, Managed Service for YDB, and Data Transfer
#
# RU: https://yandex.cloud/ru/docs/data-transfer/tutorials/opensearch-to-ydb
# EN: https://yandex.cloud/en/docs/data-transfer/tutorials/opensearch-to-ydb
#
# Configure the parameters of the source and target clusters and transfer:

locals {
  mos_version  = "" # Desired version of the Opensearch. For available versions, see the documentation main page: https://yandex.cloud/en/docs/managed-opensearch/.
  mos_password = "" # OpenSearch admin's password

  # Specify these settings ONLY AFTER the cluster is created. Then run the "terraform apply" command again.
  # You should set up the source endpoint using the GUI to obtain its ID
  source_endpoint_id = "" # Set the source endpoint ID
  transfer_enabled   = 0  # Set to 1 to enable creation of target endpoint and transfer

  # Setting for the YC CLI that allows running CLI command to activate cluster
  profile_name = "" # Name of the YC CLI profile

  # The following settings are predefined. Change them only if necessary.
  network_name          = "mos-network"             # Name of the network
  subnet_name           = "mos-subnet-a"            # Name of the subnet
  zone_a_v4_cidr_blocks = "10.1.0.0/16"             # CIDR block for the subnet in the ru-central1-a availability zone
  security_group_name   = "mos-security-group"      # Name of the security group
  sa_name               = "ydb-account"             # Name of the service account
  ydb_name              = "ydb1"                    # Name of the YDB
  mos_cluster_name      = "opensearch-cluster"      # Name of the OpenSearch cluster
  target_endpoint_name  = "ydb-target"              # Name of the target endpoint for the Managed Service for YDB
  transfer_name         = "opensearch-ydb-transfer" # Name of the transfer between the Managed Service for OpenSearch cluster and Managed Service for YDB
}

# Network infrastructure for the Managed Service for OpenSearch cluster

resource "yandex_vpc_network" "mos-network" {
  description = "Network for the Managed Service for OpenSearch cluster"
  name        = local.network_name
}

resource "yandex_vpc_subnet" "mos-subnet-a" {
  description    = "Subnet in the ru-central1-a availability zone"
  name           = local.subnet_name
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.mos-network.id
  v4_cidr_blocks = [local.zone_a_v4_cidr_blocks]
}

resource "yandex_vpc_security_group" "mos-security-group" {
  description = "Security group for the Managed Service for OpenSearch cluster"
  name        = local.security_group_name
  network_id  = yandex_vpc_network.mos-network.id

  ingress {
    description    = "The rule allows connections to the Managed Service for OpenSearch cluster from the Internet"
    protocol       = "TCP"
    port           = 443
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description    = "The rule allows connections to the Managed Service for OpenSearch cluster from the Internet with Dashboards"
    protocol       = "TCP"
    port           = 9200
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description    = "The rule allows all outgoing traffic"
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
    from_port      = 0
    to_port        = 65535
  }
}

# Infrastructure for the Managed Service for YDB

# Create the Yandex Managed Service for YDB
resource "yandex_ydb_database_serverless" "ydb" {
  name        = local.ydb_name
  location_id = "ru-central1"
}

# Create a service account
resource "yandex_iam_service_account" "ydb-account" {
  name = local.sa_name
}

# Grant a role to the service account. The role allows to perform any operations with database.
resource "yandex_ydb_database_iam_binding" "ydb-editor" {
  database_id = yandex_ydb_database_serverless.ydb.id
  role        = "ydb.editor"
  members = [
    "serviceAccount:${yandex_iam_service_account.ydb-account.id}",
  ]
}

# Infrastructure for the Managed Service for OpenSearch cluster

resource "yandex_mdb_opensearch_cluster" "opensearch-cluster" {
  description        = "Managed Service for OpenSearch cluster"
  name               = local.mos_cluster_name
  environment        = "PRODUCTION"
  network_id         = yandex_vpc_network.mos-network.id
  security_group_ids = [yandex_vpc_security_group.mos-security-group.id]

  config {

    version        = local.mos_version
    admin_password = local.mos_password

    opensearch {
      node_groups {
        name             = "opensearch-group"
        assign_public_ip = true
        hosts_count      = 1
        zone_ids         = ["ru-central1-a"]
        subnet_ids       = [yandex_vpc_subnet.mos-subnet-a.id]
        roles            = ["DATA", "MANAGER"]
        resources {
          resource_preset_id = "s2.micro"  # 2 vCPU, 8 GB RAM
          disk_size          = 10737418240 # Bytes
          disk_type_id       = "network-ssd"
        }
      }
    }

    dashboards {
      node_groups {
        name             = "dashboards-group"
        assign_public_ip = true
        hosts_count      = 1
        zone_ids         = ["ru-central1-a"]
        subnet_ids       = [yandex_vpc_subnet.mos-subnet-a.id]
        resources {
          resource_preset_id = "s2.micro"  # 2 vCPU, 8 GB RAM
          disk_size          = 10737418240 # Bytes
          disk_type_id       = "network-ssd"
        }
      }
    }
  }

  maintenance_window {
    type = "ANYTIME"
  }
}

# Data Transfer infrastructure

resource "yandex_datatransfer_endpoint" "ydb-target" {
  description = "Target endpoint for the Managed Service for YDB"
  count       = local.transfer_enabled
  name        = local.target_endpoint_name
  settings {
    ydb_target {
      database           = yandex_ydb_database_serverless.ydb.database_path
      service_account_id = yandex_iam_service_account.ydb-account.id
      cleanup_policy     = "YDB_CLEANUP_POLICY_DROP"
    }
  }
}

resource "yandex_datatransfer_transfer" "opensearch-ydb-transfer" {
  description = "Transfer from the Managed Service for YDB to the Managed Service for OpenSearch cluster"
  count       = local.transfer_enabled
  name        = local.transfer_name
  source_id   = local.source_endpoint_id
  target_id   = yandex_datatransfer_endpoint.ydb-target[count.index].id
  type        = "SNAPSHOT_ONLY" # Copy all data from the source
  provisioner "local-exec" {
    command = "yc --profile ${local.profile_name} datatransfer transfer activate ${yandex_datatransfer_transfer.opensearch-ydb-transfer[count.index].id}"
  }
}