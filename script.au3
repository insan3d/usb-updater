#include <GUIConstantsEx.au3>
#include <EditConstants.au3>
#include <WindowsConstants.au3>
#include <MsgBoxConstants.au3>

Opt("MustDeclareVars", 1)

Global Const $SETTLE_TIME_MS = 2500
Global Const $REG_SETTINGS = "HKCU\Software\insan3d\usb-updater"
Global Const $GENERIC_READ = 0x80000000
Global Const $GENERIC_WRITE = 0x40000000
Global Const $FILE_SHARE_READ = 0x00000001
Global Const $FILE_SHARE_WRITE = 0x00000002
Global Const $OPEN_EXISTING = 3
Global Const $FSCTL_LOCK_VOLUME = 0x00090018
Global Const $FSCTL_DISMOUNT_VOLUME = 0x00090020
Global Const $IOCTL_STORAGE_EJECT_MEDIA = 0x002D4808

Global $g_hGui, $g_hBtnSelectSource, $g_hLblSource, $g_hChkEnabled, $g_hLog
Global $g_bMonitoring = False, $g_bBatchPending = False
Global $g_hBatchTimer = 0, $g_sKnownDrives = "|", $g_sSource = ""
Global $g_hPollTimer = TimerInit(), $g_sLastObservedDrives = "|"
Global $g_sCopyError = ""
Global $g_sLastSourceFolder = RegRead($REG_SETTINGS, "LastSourceFolder")

If @error Or Not IsFolder($g_sLastSourceFolder) Then $g_sLastSourceFolder = @ScriptDir

$g_hGui = GUICreate("USB updater", 620, 390)
$g_hBtnSelectSource = GUICtrlCreateButton("Выбрать папку...", 10, 10, 140, 26)
$g_hLblSource = GUICtrlCreateLabel("Источник не выбран", 160, 15, 450, 20)
$g_hChkEnabled = GUICtrlCreateCheckbox("Включить отслеживание новых съёмных накопителей", 10, 45, 360, 22)
GUICtrlSetState($g_hChkEnabled, $GUI_DISABLE)
$g_hLog = GUICtrlCreateEdit("", 10, 78, 600, 302, BitOR($ES_MULTILINE, $WS_VSCROLL))
GUICtrlSetFont($g_hLog, 9, 400, 0, "Consolas")
GUICtrlSetBkColor($g_hLog, 0x000000)
GUICtrlSetColor($g_hLog, 0xFFFFFF)

GUIRegisterMsg($WM_DEVICECHANGE, "WM_DEVICECHANGE")
GUISetState(@SW_SHOW)

If IsFolder($g_sLastSourceFolder) Then
	$g_sSource = $g_sLastSourceFolder
	GUICtrlSetData($g_hLblSource, $g_sSource)
	GUICtrlSetState($g_hChkEnabled, $GUI_ENABLE)
	AddLog("Восстановлен источник: " & $g_sSource)
Else
	AddLog("Выберите папку с данными для копирования.")
EndIf

While 1
	Local $iMsg = GUIGetMsg()
	If $iMsg = $GUI_EVENT_CLOSE Then ExitLoop

	If $iMsg = $g_hBtnSelectSource Then
		SelectSourceFolder()
	EndIf

	If $iMsg = $g_hChkEnabled Then
		$g_bMonitoring = (BitAND(GUICtrlRead($g_hChkEnabled), $GUI_CHECKED) = $GUI_CHECKED)
		If $g_bMonitoring Then
			If Not IsSourceFolder() Then
				$g_bMonitoring = False
				GUICtrlSetState($g_hChkEnabled, $GUI_UNCHECKED)
				MsgBox($MB_ICONERROR, "Нет данных", "Сначала выберите существующую папку с данными.")
				AddLog("ОШИБКА: источник не выбран или недоступен")
			Else
				; Existing drives are not touched. Only drives connected after enabling are processed.
				$g_sKnownDrives = GetRemovableDrives()
				$g_sLastObservedDrives = $g_sKnownDrives
				$g_hPollTimer = TimerInit()
				GUICtrlSetState($g_hBtnSelectSource, $GUI_DISABLE)
				AddLog("Отслеживание включено. Подключите хаб с накопителями.")
			EndIf
		Else
			$g_bBatchPending = False
			GUICtrlSetState($g_hBtnSelectSource, $GUI_ENABLE)
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
	; Some USB storage devices report unusual drive types. Compare every ready drive
	; letter instead; the baseline ensures that only newly mounted volumes are processed.
	Local $sResult = "|"
	AddDriveTypeToList("ALL", $sResult)
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

Func SelectSourceFolder()
	Local $sSelected = FileSelectFolder("Выберите папку с данными для копирования", $g_sLastSourceFolder, 0, "", $g_hGui)
	If @error Or $sSelected = "" Then Return

	$g_sSource = $sSelected
	$g_sLastSourceFolder = $sSelected
	RegWrite($REG_SETTINGS, "LastSourceFolder", "REG_SZ", $g_sLastSourceFolder)
	GUICtrlSetData($g_hLblSource, $g_sSource)
	GUICtrlSetState($g_hChkEnabled, $GUI_ENABLE)
	AddLog("Выбран источник: " & $g_sSource)
EndFunc

Func IsSourceFolder()
	Return IsFolder($g_sSource)
EndFunc

Func IsFolder($sPath)
	Return $sPath <> "" And FileExists($sPath) And StringInStr(FileGetAttrib($sPath), "D") > 0
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
	; Standard volume-control sequence: flush -> lock -> dismount -> eject media.
	; Unlike mountvol /p it does not permanently take the volume offline.
	Local $sDevicePath = "\\.\" & StringLeft($sDrive, 2)
	Local $aOpen = DllCall("kernel32.dll", "handle", "CreateFileW", "wstr", $sDevicePath, "dword", BitOR($GENERIC_READ, $GENERIC_WRITE), "dword", BitOR($FILE_SHARE_READ, $FILE_SHARE_WRITE), "ptr", 0, "dword", $OPEN_EXISTING, "dword", 0, "ptr", 0)
	If @error Or $aOpen[0] = Ptr(-1) Then
		AddLog("ОШИБКА открытия тома " & $sDrive & " (код " & GetLastErrorCode() & ")")
		Return False
	EndIf

	Local $hVolume = $aOpen[0], $iError = 0
	Local $bSuccess = FlushVolumeBuffers($hVolume, $iError)
	If $bSuccess Then $bSuccess = SendVolumeControl($hVolume, $FSCTL_LOCK_VOLUME, $iError)
	If $bSuccess Then $bSuccess = SendVolumeControl($hVolume, $FSCTL_DISMOUNT_VOLUME, $iError)
	If $bSuccess Then $bSuccess = SendVolumeControl($hVolume, $IOCTL_STORAGE_EJECT_MEDIA, $iError)
	If Not $bSuccess Then
		DllCall("kernel32.dll", "bool", "CloseHandle", "handle", $hVolume)
		AddLog("ОШИБКА безопасного извлечения " & $sDrive & " (код " & $iError & ")")
		Return False
	EndIf
	DllCall("kernel32.dll", "bool", "CloseHandle", "handle", $hVolume)

	; The eject request is asynchronous. Wait briefly for the drive letter to disappear.
	Local $i
	For $i = 1 To 30
		Sleep(100)
		If DriveStatus($sDrive) <> "READY" Then
			AddLog("Безопасно извлечён " & $sDrive)
			Return True
		EndIf
	Next

	AddLog("Носитель всё ещё используется: " & $sDrive)
	Return False
EndFunc

Func FlushVolumeBuffers($hVolume, ByRef $iError)
	Local $aCall = DllCall("kernel32.dll", "bool", "FlushFileBuffers", "handle", $hVolume)
	If Not @error And $aCall[0] Then Return True
	$iError = GetLastErrorCode()
	Return False
EndFunc

Func SendVolumeControl($hVolume, $iControlCode, ByRef $iError)
	Local $aCall = DllCall("kernel32.dll", "bool", "DeviceIoControl", "handle", $hVolume, "dword", $iControlCode, "ptr", 0, "dword", 0, "ptr", 0, "dword", 0, "dword*", 0, "ptr", 0)
	If Not @error And $aCall[0] Then Return True
	$iError = GetLastErrorCode()
	Return False
EndFunc

Func GetLastErrorCode()
	Local $aCall = DllCall("kernel32.dll", "dword", "GetLastError")
	If @error Then Return -1
	Return $aCall[0]
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
