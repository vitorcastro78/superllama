Rollback:
  1) Copy *.env, models-preset.ini back to C:\LlamaServer\config\
  2) Copy run-server.bat to C:\LlamaServer\scripts\
  3) nssm restart LlamaServer
  Or: powershell -File C:\LlamaServer\scripts\Rollback-PreMtp.ps1
