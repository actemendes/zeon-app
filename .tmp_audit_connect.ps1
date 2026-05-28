$adb='C:\Users\ZEON\devtools\android-sdk\platform-tools\adb.exe'
& $adb shell monkey -p com.zeon.hiddify -c android.intent.category.LAUNCHER 1 | Out-Null
Start-Sleep -Seconds 2
for($i=0; $i -lt 20; $i++){
  & $adb shell uiautomator dump /sdcard/window.xml | Out-Null
  & $adb pull /sdcard/window.xml .tmp_window.xml | Out-Null
  $xml = Get-Content .tmp_window.xml -TotalCount 1
  if($xml -match '????????|????????????????'){ & $adb shell input tap 1212 642; Start-Sleep -Seconds 1 }
  if($xml -match 'permission_allow_button'){ & $adb shell input tap 1212 742; Start-Sleep -Seconds 1 }
  if($xml -match 'content-desc="OK"'){ & $adb shell input tap 1780 690; Start-Sleep -Seconds 1 }
  if($xml -match '??????? ??? ???????????|??????????????'){ & $adb shell input tap 1324 760; Start-Sleep -Seconds 2 }
  $tun = & $adb shell "ip addr show tun0 || ifconfig tun0"
  if(($tun | Out-String) -match 'tun0:'){
    Write-Output 'VPN_UP'
    $tun
    break
  }
  Start-Sleep -Milliseconds 800
}
Write-Output '===LAST_UI===';
Get-Content .tmp_window.xml -TotalCount 1
Write-Output '===RECENT_LOGS===';
& $adb logcat -d | rg -n "ConnectionFailure|failed to start|permission denied|VPN_CONNECTED|startService|requestVPNPermission" | Select-Object -Last 120
