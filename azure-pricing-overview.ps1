# =================== Einstellungen ===================
$CurrencyCode    = 'EUR'   # Alternativ: 'USD','GBP',...
$PriceTypes      = @('Consumption')   # Nur PAYG
$ShareLink       = 'https://microsofteur-my.sharepoint.com/:f:/g/personal/miniehue_microsoft_com/EnE9eDtKzYJAs14iPMFQViUBwfYjFrk_i84aTIpb2uO70Q?e=tsS55P'
$OutFileName     = 'Azure-Retail-Prices-PAYG.xlsx'
$TempFile        = Join-Path $env:TEMP $OutFileName
$MaxRowsPerSheet = 900000
# =====================================================

Write-Host "==> Sammle PAYG-Preise (Quelle: prices.azure.com) und erstelle Excel..." -ForegroundColor Cyan

# --- Robust: REST GET mit Retry/Backoff ---
function Invoke-PricesApi {
  param([Parameter(Mandatory=$true)][string]$Uri)
  $tries=0;$max=8;$delay=1
  while ($true) {
    try { return Invoke-RestMethod -Uri $Uri -Method GET -TimeoutSec 120 }
    catch {
      if (++$tries -ge $max){ throw "API fehlgeschlagen nach $tries Versuchen: $Uri`n$($_.Exception.Message)" }
      Start-Sleep -Seconds $delay; $delay=[Math]::Min($delay*2,30)
    }
  }
}

function New-BaseUri { param([string]$Filter)
  $q=@(); if ($CurrencyCode){$q+="currencyCode=$CurrencyCode"}
  if ($Filter){$q+="`$filter=$([uri]::EscapeDataString($Filter))"}
  "https://prices.azure.com/api/retail/prices?"+($q -join '&')
}

# --- Daten sammeln (nur PAYG) ---
$dataAll = New-Object System.Collections.Generic.List[object]
foreach ($ptype in $PriceTypes) {
  $filter = "type eq '$ptype'"
  $uri = New-BaseUri -Filter $filter
  $page = 1
  while ($uri) {
    $resp = Invoke-PricesApi -Uri $uri
    foreach ($it in $resp.Items){
      $dataAll.Add([pscustomobject]@{
        currencyCode=$it.currencyCode; retailPrice=$it.retailPrice; unitPrice=$it.unitPrice
        unitOfMeasure=$it.unitOfMeasure; armRegionName=$it.armRegionName; location=$it.location
        effectiveStartDate=$it.effectiveStartDate; meterId=$it.meterId; meterName=$it.meterName
        productId=$it.productId; productName=$it.productName; skuId=$it.skuId; skuName=$it.skuName
        armSkuName=$it.armSkuName; serviceName=$it.serviceName; serviceId=$it.serviceId
        serviceFamily=($it.serviceFamily ?? 'Unspecified'); type=$it.type
        reservationTerm=$it.reservationTerm; isPrimaryMeterRegion=$it.isPrimaryMeterRegion
      })
    }
    Write-Host ("  [type={0}] Page {1}: {2} Items" -f $ptype, $page, ($resp.Items|Measure-Object).Count)
    $page++; $uri = $resp.NextPageLink
  }
}

# --- Excel erzeugen ---
if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
  try { Install-Module ImportExcel -Scope CurrentUser -Force -ErrorAction Stop | Out-Null } catch {}
}
if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
  $csv = [IO.Path]::ChangeExtension($TempFile, ".csv")
  $dataAll | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
  Write-Warning "Konnte 'ImportExcel' nicht laden – CSV-Fallback erzeugt: $csv"
  $TempFile = $csv
} else {
  Import-Module ImportExcel -ErrorAction Stop
  Remove-Item -LiteralPath $TempFile -ErrorAction SilentlyContinue

  $groups = $dataAll | Group-Object serviceFamily, type
  foreach ($g in $groups) {
    $family = if ($g.Group[0].serviceFamily) { $g.Group[0].serviceFamily } else { 'Unspecified' }
    $ptype  = $g.Group[0].type
    $sheet  = ($family + '_' + $ptype).Replace('/','-'); if ($sheet.Length -gt 31){$sheet=$sheet.Substring(0,31)}
    $rows   = $g.Group
    if ($rows.Count -le $MaxRowsPerSheet) {
      $rows | Export-Excel -Path $TempFile -WorksheetName $sheet -AutoSize -AutoFilter -FreezeTopRow -Append
    } else {
      $chunks=[math]::Ceiling($rows.Count/$MaxRowsPerSheet)
      for ($i=0; $i -lt $chunks; $i++){
        $part=$rows | Select-Object -Skip ($i*$MaxRowsPerSheet) -First $MaxRowsPerSheet
        $name=("{0}_{1}" -f $sheet, $i+1); if ($name.Length -gt 31){$name=$name.Substring(0,31)}
        $part | Export-Excel -Path $TempFile -WorksheetName $name -AutoSize -AutoFilter -FreezeTopRow -Append
      }
    }
  }

  # Overview + Notes
  $dataAll |
    Select serviceFamily,serviceName,productName,skuName,armSkuName,type,armRegionName,currencyCode,unitOfMeasure,unitPrice,retailPrice |
    Export-Excel -Path $TempFile -WorksheetName 'Overview' -AutoSize -AutoFilter -FreezeTopRow -Append

  [pscustomobject]@{
    GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ssZ')
    Source         = 'https://prices.azure.com/api/retail/prices'
    Currency       = $CurrencyCode
    PriceTypes     = ($PriceTypes -join ', ')
    Note1          = 'Nur PAYG (Consumption). Portalpreise können durch OS/Währung/Zeithorizont abweichen.'
  } | Export-Excel -Path $TempFile -WorksheetName 'Notes' -AutoSize -Append
}

Write-Host "==> Excel erzeugt: $TempFile" -ForegroundColor Green

# --- Upload nach OneDrive/SharePoint per Graph ---
Write-Host "==> Lade Datei in den angegebenen OneDrive-Ordner hoch..." -ForegroundColor Cyan

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph)) {
  try { Install-Module Microsoft.Graph -Scope CurrentUser -Force -ErrorAction Stop | Out-Null } catch {
    throw "Microsoft.Graph konnte nicht installiert werden: $($_.Exception.Message)"
  }
}
Import-Module Microsoft.Graph -ErrorAction Stop
Connect-MgGraph -Scopes "Files.ReadWrite.All" | Out-Null

$raw   = [System.Text.Encoding]::UTF8.GetBytes($ShareLink)
$base64= [Convert]::ToBase64String($raw).TrimEnd('=').Replace('+','-').Replace('/','_')
$shareId = "u!$base64"

$createBody = @{ item = @{ "@microsoft.graph.conflictBehavior" = "replace"; name = $OutFileName } } | ConvertTo-Json
$session = Invoke-MgGraphRequest -Method POST -Uri ("https://graph.microsoft.com/v1.0/shares/{0}/driveItem:/{1}:/createUploadSession" -f $shareId, $OutFileName) -Body $createBody -ContentType "application/json"
$uploadUrl = $session.uploadUrl

$chunkSize = 8MB
$fs = [System.IO.File]::OpenRead($TempFile)
try {
  $buffer = New-Object byte[] $chunkSize
  $offset = 0
  while (($read = $fs.Read($buffer,0,$buffer.Length)) -gt 0) {
    $start = $offset
    $end   = $offset + $read - 1
    $headers = @{ "Content-Length" = $read; "Content-Range" = "bytes $start-$end/$($fs.Length)" }
    Invoke-WebRequest -Uri $uploadUrl -Method PUT -Headers $headers -Body ($buffer[0..($read-1)]) | Out-Null
    $offset += $read
    Write-Host ("  Hochgeladen: {0:P1}" -f ($offset / $fs.Length))
  }
} finally { $fs.Dispose() }

Write-Host "==> Upload abgeschlossen. Datei liegt jetzt im OneDrive-Ordner: $OutFileName" -ForegroundColor Green
