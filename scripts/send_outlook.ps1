param(
  [Parameter(Mandatory = $true)][string]$To,
  [Parameter(Mandatory = $true)][string]$Subject,
  [Parameter(Mandatory = $true)][string]$HtmlPath,
  [Parameter(Mandatory = $false)][string]$From = ""
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $HtmlPath)) {
  throw "HTML file not found: $HtmlPath"
}

$html = Get-Content -LiteralPath $HtmlPath -Raw -Encoding UTF8
$outlook = New-Object -ComObject Outlook.Application
$session = $outlook.Session
$mail = $outlook.CreateItem(0)

if ($From -ne "") {
  foreach ($account in $session.Accounts) {
    if ($account.SmtpAddress -and ($account.SmtpAddress.ToLowerInvariant() -eq $From.ToLowerInvariant())) {
      $mail.SendUsingAccount = $account
      break
    }
  }
}

$mail.To = $To
$mail.Subject = $Subject
$mail.HTMLBody = $html
$mail.Send()

Write-Output "sent"
