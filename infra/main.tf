locals {
  tags                         = { azd-env-name : var.environment_name }
  sha                          = base64encode(sha256("${var.environment_name}${var.location}${data.azurerm_client_config.current.subscription_id}"))
  resource_token               = substr(replace(lower(local.sha), "[^A-Za-z0-9_]", ""), 0, 13)
  api_command_line             = "gunicorn --workers 4 --threads 2 --timeout 60 --access-logfile \"-\" --error-logfile \"-\" --bind=0.0.0.0:8000 -k uvicorn.workers.UvicornWorker todo.app:app"
  cosmos_connection_string_key = "AZURE-COSMOS-CONNECTION-STRING"
  enable_telemetry             = true
}

resource "azurecaf_name" "rg_name" {
  name          = var.environment_name
  resource_type = "azurerm_resource_group"
  random_length = 0
  clean_input   = true
}

resource "azurerm_resource_group" "rg" {
  name     = azurecaf_name.rg_name.result
  location = var.location

  tags = local.tags
}

module "naming" {
  source  = "Azure/naming/azurerm"
  version = ">= 0.3.0"
}

module "applicationinsights" {
  source              = "Azure/avm-res-insights-component/azurerm"
  location            = var.location
  name                = "${module.naming.application_insights.name_unique}-${local.resource_token}"
  resource_group_name = azurerm_resource_group.rg.name
  workspace_id        = module.loganalytics.resource_id
  enable_telemetry    = local.enable_telemetry
}

module "loganalytics" {
  source                                    = "Azure/avm-res-operationalinsights-workspace/azurerm"
  enable_telemetry                          = local.enable_telemetry
  location                                  = var.location
  resource_group_name                       = azurerm_resource_group.rg.name
  name                                      = "${module.naming.analysis_services_server.name_unique}-${local.resource_token}"
  log_analytics_workspace_retention_in_days = 30
  log_analytics_workspace_sku               = "PerGB2018"
}

module "keyvault" {
  source                        = "Azure/avm-res-keyvault-vault/azurerm"
  version                       = "0.9.1"
  name                          = "${module.naming.key_vault.name_unique}-${local.resource_token}"
  location                      = var.location
  resource_group_name           = azurerm_resource_group.rg.name
  tags                          = azurerm_resource_group.rg.tags
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  public_network_access_enabled = true

  sku_name                 = "standard"
  purge_protection_enabled = false
  secrets = {
    cosmos_secret = {
      name = local.cosmos_connection_string_key
    }
  }
  secrets_value = {
    cosmos_secret = module.cosmos.cosmosdb_mongodb_connection_strings.primary_mongodb_connection_string
  }
  role_assignments = {
    user = {
      role_definition_id_or_name = "Key Vault Administrator"
      principal_id               = data.azurerm_client_config.current.object_id
    }
    api1 = {
      role_definition_id_or_name = "Key Vault Administrator"
      principal_id               = module.api.identity_principal_id
    }
  }
  wait_for_rbac_before_secret_operations = {
    create = "60s"
  }
  network_acls = null
}

module "cosmos" {
  source                     = "Azure/avm-res-documentdb-databaseaccount/azurerm"
  resource_group_name        = azurerm_resource_group.rg.name
  location                   = var.location
  name                       = "${module.naming.cosmosdb_account.name_unique}-${local.resource_token}"
  mongo_server_version       = "4.0"
  analytical_storage_enabled = true
  tags                       = azurerm_resource_group.rg.tags
  capabilities = [
    {
      name = "EnableServerless"
    }
  ]
  consistency_policy = {
    consistency_level = "Session"
  }
  geo_locations = [
    {
      location          = var.location
      failover_priority = 0
      zone_redundant    = false
    }
  ]
  mongo_databases = {
    database_collection = {
      name = "Todo"
      collections = {
        "collection_TodoList" = {
          name      = "TodoList"
          shard_key = "_id"
          index = {
            keys = ["_id"]
          }
        }
        "collection_TodoItem" = {
          name      = "TodoItem"
          shard_key = "_id"
          index = {
            keys = ["_id"]
          }
        }
      }
    }
  }
}

module "appserviceplan" {
  source                 = "Azure/avm-res-web-serverfarm/azurerm"
  enable_telemetry       = local.enable_telemetry
  name                   = "${module.naming.app_service_plan.name_unique}-${local.resource_token}"
  resource_group_name    = azurerm_resource_group.rg.name
  location               = var.location
  os_type                = "Linux"
  sku_name               = "B3"
  worker_count           = 1
  zone_balancing_enabled = false
}

module "web" {
  source                      = "Azure/avm-res-web-site/azurerm"
  enable_telemetry            = local.enable_telemetry
  name                        = "${module.naming.app_service.name_unique}-web${local.resource_token}"
  resource_group_name         = azurerm_resource_group.rg.name
  location                    = var.location
  tags                        = merge(local.tags, { azd-service-name : "web" })
  service_plan_resource_id    = module.appserviceplan.resource_id
  https_only                  = true
  kind                        = "webapp"
  os_type                     = "Linux"
  enable_application_insights = false
  site_config = {
    always_on         = true
    use_32_bit_worker = false
    ftps_state        = "FtpsOnly"
    app_command_line  = "pm2 serve /home/site/wwwroot --no-daemon --spa"
    application_stack = {
      node = {
        current_stack = "node"
        node_version  = "20-lts"
      }
    }
  }
  app_settings = {
    "SCM_DO_BUILD_DURING_DEPLOYMENT" = "false"
  }
  logs = {
    app_service_logs = {
      http_logs = {
        config1 = {
          file_system = {
            retention_in_days = 1
            retention_in_mb   = 35
          }
        }
      }
      application_logs = {
        config1 = {
          file_system_level = "Verbose"
        }
      }
      detailed_error_messages = true
      failed_request_tracing  = true
    }
  }
}

module "api" {
  source                      = "Azure/avm-res-web-site/azurerm"
  name                        = "${module.naming.app_service.name_unique}-api${local.resource_token}"
  resource_group_name         = azurerm_resource_group.rg.name
  location                    = var.location
  tags                        = merge(local.tags, { azd-service-name : "api" })
  service_plan_resource_id    = module.appserviceplan.resource_id
  https_only                  = true
  kind                        = "webapp"
  os_type                     = "Linux"
  enable_application_insights = false
  app_settings = {
    "AZURE_COSMOS_CONNECTION_STRING_KEY"    = local.cosmos_connection_string_key
    "AZURE_COSMOS_DATABASE_NAME"            = keys(module.cosmos.mongo_databases)[0]
    "SCM_DO_BUILD_DURING_DEPLOYMENT"        = "true"
    "AZURE_KEY_VAULT_ENDPOINT"              = module.keyvault.uri
    "APPLICATIONINSIGHTS_CONNECTION_STRING" = module.applicationinsights.connection_string
  }
  site_config = {
    always_on         = true
    use_32_bit_worker = false
    ftps_state        = "FtpsOnly"
    app_command_line  = local.api_command_line
    application_stack = {
      node = {
        current_stack  = "python"
        python_version = "3.10"
      }
    }
  }
  logs = {
    app_service_logs = {
      http_logs = {
        config1 = {
          file_system = {
            retention_in_days = 1
            retention_in_mb   = 35
          }
        }
      }
      application_logs = {
        config1 = {
          file_system_level = "Verbose"
        }
      }
      detailed_error_messages = true
      failed_request_tracing  = true
    }
  }
  managed_identities = {
    system_assigned = true
  }
}

# Workaround: set API_ALLOW_ORIGINS to the web app URI
resource "null_resource" "api_set_allow_origins" {
  triggers = {
    web_uri = module.web.resource_uri
  }

  provisioner "local-exec" {
    command = "az webapp config appsettings set --resource-group ${azurerm_resource_group.rg.name} --name ${module.api.name} --settings API_ALLOW_ORIGINS=https://${module.web.resource_uri}"
  }
}

resource "null_resource" "webapp_basic_auth_disable" {
  triggers = {
    account = module.web.name
  }

  provisioner "local-exec" {
    command = "az resource update --resource-group ${azurerm_resource_group.rg.name} --name ftp --namespace Microsoft.Web --resource-type basicPublishingCredentialsPolicies --parent sites/${module.web.name} --set properties.allow=false && az resource update --resource-group ${azurerm_resource_group.rg.name} --name scm --namespace Microsoft.Web --resource-type basicPublishingCredentialsPolicies --parent sites/${module.web.name} --set properties.allow=false"
  }
}

