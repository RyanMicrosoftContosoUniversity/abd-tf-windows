$resp = Invoke-RestMethod -Uri 'https://registry.terraform.io/v1/providers/databricks/databricks/versions'
$latest = $resp.versions | Sort-Object -Property version -Descending | Select-Object -First 1
$latest | ConvertTo-Json -Depth 5