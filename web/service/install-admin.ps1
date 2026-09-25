# Registers the Mac ID admin dashboard (admin_web.py) to run at boot as SYSTEM, like the fulfilment
# service, and publishes it to the owner's tailnet with Tailscale Serve. Never exposed publicly:
# it binds to 127.0.0.1, and Serve only answers devices signed in to the owner's Tailscale.
$python = 'C:\Program Files\Python312\python.exe'
$action   = New-ScheduledTaskAction -Execute $python -Argument 'C:\MacIDService\admin\admin_web.py' -WorkingDirectory 'C:\MacIDService\admin'
$trigger  = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) `
              -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
              -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName 'MacID-Admin' -Action $action -Trigger $trigger `
  -Settings $settings -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName 'MacID-Admin'
Start-Sleep -Seconds 3
$t = Get-ScheduledTask -TaskName 'MacID-Admin'
"task state: $($t.State)   time limit: $($t.Settings.ExecutionTimeLimit)"
try { "local: " + (Invoke-WebRequest -UseBasicParsing -Headers @{Host='127.0.0.1:8788'} http://127.0.0.1:8788/).StatusCode } catch { "local answer: $($_.Exception.Response.StatusCode.value__) (403 without a Tailscale login is expected)" }
