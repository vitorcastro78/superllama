' Silent launcher for Inference Monitor (Edge/Chrome --app). No cmd blink.
Option Explicit
Dim sh, fso, here, pyw, app, edge, chrome, url, rc
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

here = fso.GetParentFolderName(WScript.ScriptFullName)
app = here & "\gpu-monitor.py"
url = "http://127.0.0.1:11436/"
edge = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
chrome = "C:\Program Files\Google\Chrome\Application\chrome.exe"

pyw = FindPythonW()
If pyw = "" Then
  MsgBox "Python 3 (pythonw.exe) nao encontrado." & vbCrLf & _
         "Instala Python 3.10+ e marca 'Add python.exe to PATH'." & vbCrLf & _
         "Monitor: " & url, vbExclamation, "Inference Monitor"
  WScript.Quit 1
End If

rc = sh.Run("powershell -NoProfile -WindowStyle Hidden -Command ""try { Get-NetTCPConnection -LocalPort 11436 -State Listen -EA Stop | Out-Null; exit 0 } catch { exit 1 }""", 0, True)
If rc <> 0 Then
  sh.Run """" & pyw & """ """ & app & """ --no-browser --host 0.0.0.0 --port 11436", 0, False
  WScript.Sleep 2000
End If

If fso.FileExists(edge) Then
  sh.Run """" & edge & """ --app=" & url & " --window-size=1100,820 --disable-features=TranslateUI", 1, False
ElseIf fso.FileExists(chrome) Then
  sh.Run """" & chrome & """ --app=" & url & " --window-size=1100,820", 1, False
Else
  sh.Run url, 1, False
End If

Function FindPythonW()
  Dim candidates, i, cmd, outFile, ts, line
  candidates = Array( _
    sh.ExpandEnvironmentStrings("%LOCALAPPDATA%\Programs\Python\Python312\pythonw.exe"), _
    sh.ExpandEnvironmentStrings("%LOCALAPPDATA%\Programs\Python\Python311\pythonw.exe"), _
    sh.ExpandEnvironmentStrings("%LOCALAPPDATA%\Programs\Python\Python310\pythonw.exe"), _
    "C:\Python312\pythonw.exe", _
    "C:\Python311\pythonw.exe" _
  )
  For i = 0 To UBound(candidates)
    If fso.FileExists(candidates(i)) Then
      FindPythonW = candidates(i)
      Exit Function
    End If
  Next
  ' where.exe pythonw
  outFile = sh.ExpandEnvironmentStrings("%TEMP%\infmon-pyw.txt")
  sh.Run "cmd /c where pythonw > """ & outFile & """ 2>nul", 0, True
  If fso.FileExists(outFile) Then
    Set ts = fso.OpenTextFile(outFile, 1)
    If Not ts.AtEndOfStream Then
      line = Trim(ts.ReadLine)
      If fso.FileExists(line) Then FindPythonW = line
    End If
    ts.Close
    On Error Resume Next
    fso.DeleteFile outFile, True
    On Error GoTo 0
  End If
End Function
