output "AZURE_COSMOS_CONNECTION_STRING_KEY" {
  value = local.cosmos_connection_string_key
}

output "AZURE_COSMOS_DATABASE_NAME" {
  value = keys(module.cosmos.mongo_databases)[0]
}

output "AZURE_KEY_VAULT_ENDPOINT" {
  value     = module.keyvault.uri
  sensitive = true
}

output "REACT_APP_WEB_BASE_URL" {
  value = "https://${module.web.resource_uri}"
}

output "API_BASE_URL" {
  value =  "https://${module.api.resource_uri}"
}

output "AZURE_LOCATION" {
  value = var.location
}

output "APPLICATIONINSIGHTS_CONNECTION_STRING" {
  value     = module.applicationinsights.connection_string
  sensitive = true
}

output "SERVICE_API_ENDPOINTS" {
  value =  module.api.resource_uri 
}
