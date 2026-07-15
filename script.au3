#include <GUIConstantsEx.au3>
#include <EditConstants.au3>
#include <WindowsConstants.au3>
#include <MsgBoxConstants.au3>

Opt("MustDeclareVars", 1)

; Copy the contents of .\data to every newly connected removable USB volume.
; Do not enable monitoring until the correct data is in the data folder.
Global Const $SETTLE_TIME_MS = 2500

Global $g_hGui, $g_hChkEnabled, $g_hLog
Global $g_bMonitoring = False, $g_bBatchPending = False
Global $g_hBatchTimer = 0, $g_sKnownDrives = "|", $g_sSource = @ScriptDir & "\data"
Global $g_hPollTimer = TimerInit(), $g_sLastObservedDrives = "|"
Global $g_sCopyError = ""

$g_hGui = GUICreate("USB updater", 620, 350)
$g_hChkEnabled = GUICtrlCreateCheckbox("Включить отслеживание новых съёмных накопителей", 10, 12, 360, 22)
$g_hLog = GUICtrlCreateEdit("", 10, 45, 600, 295, BitOR($ES_MULTILINE, $WS_VSCROLL))
GUICtrlSetFont($g_hLog, 9, 400, 0, "Consolas")
GUICtrlSetBkColor($g_hLog, 0x000000)
GUICtrlSetColor($g_hLog, 0xFFFFFF)

GUIRegisterMsg($WM_DEVICECHANGE, "WM_DEVICECHANGE")
GUISetState(@SW_SHOW)

If Not EnsureSourceFolder() Then
	MsgBox($MB_ICONERROR, "Ошибка", "Не удалось создать папку data:" & @CRLF & $g_sSource)
	Exit
EndIf
AddLog("Готово. Источник: " & $g_sSource)
AddLog("Включите отслеживание, затем подключите хаб с накопителями.")

While 1
	Local $iMsg = GUIGetMsg()
	If $iMsg = $GUI_EVENT_CLOSE Then ExitLoop

	If $iMsg = $g_hChkEnabled Then
		$g_bMonitoring = (BitAND(GUICtrlRead($g_hChkEnabled), $GUI_CHECKED) = $GUI_CHECKED)
		If $g_bMonitoring Then
			If Not EnsureSourceFolder() Then
				$g_bMonitoring = False
				GUICtrlSetState($g_hChkEnabled, $GUI_UNCHECKED)
				MsgBox($MB_ICONERROR, "Нет данных", "Не удалось создать папку data:" & @CRLF & $g_sSource)
				AddLog("ОШИБКА: папка data недоступна")
			Else
				; Existing drives are not touched. Only drives connected after enabling are processed.
				$g_sKnownDrives = GetRemovableDrives()
				$g_sLastObservedDrives = $g_sKnownDrives
				$g_hPollTimer = TimerInit()
				AddLog("Отслеживание включено. Подключите хаб с накопителями.")
			EndIf
		Else
			$g_bBatchPending = False
			AddLog("Отслеживание выключено.")
		EndIf
	EndIf

	; Some USB hubs do not relay WM_DEVICECHANGE to ordinary GUI windows.
	; Polling is a fallback, so newly attached removable volumes are still detected.
	If $g_bMonitoring And TimerDiff($g_hPollTimer) >= 500 Then
		$g_hPollTimer = TimerInit()
		CheckDrivesByPolling()
	EndIf

	If $g_bMonitoring And $g_bBatchPending And TimerDiff($g_hBatchTimer) >= $SETTLE_TIME_MS Then
		ProcessNewDrives()
	EndIf
WEnd

Func WM_DEVICECHANGE($hWnd, $iMsg, $wParam, $lParam)
	If Not $g_bMonitoring Then Return 0

	; Restart the delay on every device event: all drives on a hub become one batch.
	$g_bBatchPending = True
	$g_hBatchTimer = TimerInit()
	Return 0
EndFunc

Func CheckDrivesByPolling()
	Local $sCurrent = GetRemovableDrives()
	If $sCurrent = $g_sLastObservedDrives Then Return

	$g_sLastObservedDrives = $sCurrent
	If $sCurrent <> $g_sKnownDrives Then
		; A changed set restarts the hub-settling delay; an unchanged set does not.
		$g_bBatchPending = True
		$g_hBatchTimer = TimerInit()
		AddLog("Обнаружено изменение съёмных накопителей: " & $sCurrent)
	EndIf
EndFunc

Func ProcessNewDrives()
	$g_bBatchPending = False
	Local $sCurrent = GetRemovableDrives()
	Local $aCurrent = StringSplit(StringStripWS($sCurrent, 3), "|")
	Local $i, $sDrive, $iSuccess = 0, $iFailed = 0, $sResult = ""

	If $sCurrent = "|" Then
		$g_sKnownDrives = $sCurrent
		Return
	EndIf

	For $i = 1 To $aCurrent[0]
		$sDrive = $aCurrent[$i]
		If $sDrive <> "" And Not StringInStr($g_sKnownDrives, "|" & $sDrive & "|") Then
			AddLog("Обработка " & $sDrive)
			If CopyDataToDrive($sDrive) Then
				If SafelyDismount($sDrive) Then
					$iSuccess += 1
					$sResult &= $sDrive & " — готов" & @CRLF
				Else
					$iFailed += 1
					$sResult &= $sDrive & " — скопировано, но не извлечено" & @CRLF
				EndIf
			Else
				$iFailed += 1
				$sResult &= $sDrive & " — ошибка копирования" & @CRLF
			EndIf
		EndIf
	Next

	$g_sKnownDrives = GetRemovableDrives()
	$g_sLastObservedDrives = $g_sKnownDrives
	If $iSuccess + $iFailed > 0 Then
		AddLog("Партия завершена: успешно " & $iSuccess & ", ошибок " & $iFailed)
		If $iFailed = 0 Then
			MsgBox($MB_ICONINFORMATION, "Хаб можно менять", "Все накопители обработаны и безопасно отключены." & @CRLF & @CRLF & $sResult)
		Else
			MsgBox($MB_ICONWARNING, "Проверьте накопители", "Партия завершена, но есть проблемы:" & @CRLF & @CRLF & $sResult)
		EndIf
	EndIf
EndFunc

Func GetRemovableDrives()
	; Some USB sticks identify as FIXED. The baseline is captured on startup,
	; therefore only newly mounted local volumes are ever processed.
	Local $sResult = "|"
	AddDriveTypeToList("REMOVABLE", $sResult)
	AddDriveTypeToList("FIXED", $sResult)
	Return $sResult
EndFunc

Func AddDriveTypeToList($sType, ByRef $sList)
	Local $aDrives = DriveGetDrive($sType), $i, $sDrive
	If Not IsArray($aDrives) Then Return
	For $i = 1 To $aDrives[0]
		$sDrive = StringUpper($aDrives[$i])
		If DriveStatus($sDrive) = "READY" And Not StringInStr($sList, "|" & $sDrive & "|") Then $sList &= $sDrive & "|"
	Next
EndFunc

Func EnsureSourceFolder()
	If FileExists($g_sSource) Then Return StringInStr(FileGetAttrib($g_sSource), "D") > 0
	If DirCreate($g_sSource) Then
		AddLog("Создана папка data: " & $g_sSource)
		Return True
	EndIf
	Return False
EndFunc

Func CopyDataToDrive($sDrive)
	; FileCopy with a wildcard is unreliable for a source consisting only of folders.
	; Copy every entry explicitly, including empty directories.
	$g_sCopyError = ""
	If Not CopyFolderContents($g_sSource, DriveRoot($sDrive)) Then
		AddLog("ОШИБКА копирования в " & $sDrive & ": " & $g_sCopyError)
		Return False
	EndIf
	AddLog("Скопировано в " & $sDrive)
	Return True
EndFunc

Func CopyFolderContents($sSource, $sDestination)
	If Not FileExists($sDestination) And Not DirCreate($sDestination) Then
		$g_sCopyError = "не удалось создать " & $sDestination
		Return False
	EndIf

	Local $hSearch = FileFindFirstFile($sSource & "\*")
	If $hSearch = -1 Then Return True ; an empty source folder is valid

	Local $sEntry = "", $sSourcePath, $sDestinationPath, $iResult
	While 1
		$sEntry = FileFindNextFile($hSearch)
		If @error Then ExitLoop
		If $sEntry = "." Or $sEntry = ".." Then ContinueLoop

		$sSourcePath = $sSource & "\" & $sEntry
		$sDestinationPath = $sDestination & "\" & $sEntry
		If StringInStr(FileGetAttrib($sSourcePath), "D") Then
			If Not CopyFolderContents($sSourcePath, $sDestinationPath) Then
				FileClose($hSearch)
				Return False
			EndIf
		Else
			$iResult = FileCopy($sSourcePath, $sDestinationPath, 1) ; 1 = overwrite existing file
			If $iResult = 0 Then
				$g_sCopyError = $sSourcePath & " -> " & $sDestinationPath & " (" & _FileErrorText(@error) & ")"
				FileClose($hSearch)
				Return False
			EndIf
		EndIf
	WEnd
	FileClose($hSearch)
	Return True
EndFunc

Func DriveRoot($sDrive)
	; DriveGetDrive normally returns E:\, but keep one exact trailing backslash in all cases.
	Return StringLeft($sDrive, 2) & "\"
EndFunc

Func SafelyDismount($sDrive)
	Return DismountWithMountvol($sDrive)
EndFunc

Func DismountWithMountvol($sDrive)
	; mountvol /p is the native, reliable way to detach the mounted volume:
	; it flushes/dismounts the volume, removes its drive letter and prevents automount.
	Local $sMountPoint = DriveRoot($sDrive)
	Local $iExitCode = RunWait(@ComSpec & " /c mountvol " & $sMountPoint & " /p", "", @SW_HIDE)
	If $iExitCode = 0 Then
		AddLog("Том отключён через mountvol: " & $sDrive)
		Return True
	EndIf
	AddLog("ОШИБКА mountvol для " & $sDrive & " (код " & $iExitCode & ")")
	Return False
EndFunc

Func _FileErrorText($iError)
	Switch $iError
		Case 1
			Return "неверный исходный путь"
		Case 2
			Return "неверный путь назначения"
		Case 4
			Return "не удалось создать каталог назначения"
		Case 5
			Return "ошибка записи (проверьте место и защиту от записи)"
	EndSwitch
	Return "код " & $iError
EndFunc

Func AddLog($sText)
	Local $sCurrent = GUICtrlRead($g_hLog)
	Local $sLine = StringFormat("%02d:%02d:%02d  %s", @HOUR, @MIN, @SEC, $sText)
	If $sCurrent <> "" Then $sCurrent &= @CRLF
	$sCurrent &= $sLine
	GUICtrlSetData($g_hLog, $sCurrent)
	; Place the caret at the end and bring it into view.
	GUICtrlSendMsg($g_hLog, $EM_SETSEL, -1, -1)
	GUICtrlSendMsg($g_hLog, $EM_SCROLLCARET, 0, 0)
	ConsoleWrite($sLine & @CRLF)
EndFunc
