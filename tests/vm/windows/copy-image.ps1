# Puts a small red image on the clipboard, like a screenshot tool would.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$bitmap = New-Object Drawing.Bitmap 300, 200
$graphics = [Drawing.Graphics]::FromImage($bitmap)
$graphics.Clear([Drawing.Color]::Red)
$graphics.Dispose()
[Windows.Forms.Clipboard]::SetDataObject($bitmap, $true, 10, 100)
