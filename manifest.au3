#include <Crypt.au3>

; Build a canonical manifest from source-relative paths and target file hashes.
Func BuildManifest($sSource, $sTarget, $sRelative, ByRef $bSuccess, ByRef $sFailure, ByRef $iFileCount)
	Local $sManifest = ""
	Local $hSearch = FileFindFirstFile($sSource & "\*")
	If $hSearch = -1 Then Return $sManifest

	While True
		Local $sEntry = FileFindNextFile($hSearch)
		If @error Then ExitLoop
		If $sEntry = "." Or $sEntry = ".." Then ContinueLoop

		Local $sSourcePath = $sSource & "\" & $sEntry
		Local $sTargetPath = $sTarget & "\" & $sEntry
		Local $sChildRelative = $sEntry
		If $sRelative <> "" Then $sChildRelative = $sRelative & "\" & $sEntry

		If StringInStr(FileGetAttrib($sSourcePath), "D") Then
			$sManifest &= BuildManifest($sSourcePath, $sTargetPath, $sChildRelative, $bSuccess, $sFailure, $iFileCount)
			If Not $bSuccess Then ExitLoop
		Else
			If Not FileExists($sTargetPath) Then
				$bSuccess = False
				$sFailure = "Файл не найден: " & $sTargetPath
				ExitLoop
			EndIf

			Local $bFileHash = _Crypt_HashFile($sTargetPath, $CALG_SHA_256)
			If @error Or Not IsBinary($bFileHash) Or BinaryLen($bFileHash) = 0 Then
				$bSuccess = False
				$sFailure = "Не удалось посчитать хеш: " & $sTargetPath & " (код " & @error & ")"
				ExitLoop
			EndIf

			$sManifest &= $sChildRelative & "|" & StringLower(Hex($bFileHash)) & @LF
			$iFileCount += 1
			OnManifestFileHashed($iFileCount)
		EndIf
	WEnd

	FileClose($hSearch)
	Return $sManifest
EndFunc
