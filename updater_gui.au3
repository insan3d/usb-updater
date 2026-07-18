#pragma compile(CompanyName, "insan3d")
#pragma compile(ProductName, "USB updater")
#pragma compile(ProductVersion, "1.1.0.0")
#pragma compile(FileVersion, "1.1.0.0")
#pragma compile(FileDescription, "USB updater")
#pragma compile(InternalName, "usb-updater")
#pragma compile(OriginalFilename, "usb-updater.exe")
#pragma compile(ExecutionLevel, "asInvoker")
#pragma compile(Icon, "icon.ico")

#include <AutoItConstants.au3>
#include <ButtonConstants.au3>
#include <GUIConstantsEx.au3>
#include <EditConstants.au3>
#include <GuiStatusBar.au3>
#include <MsgBoxConstants.au3>
#include <StaticConstants.au3>
#include <WindowsConstants.au3>

Opt("MustDeclareVars", 1)

; Layout and timing.
Global Const $WINDOW_WIDTH = 760
Global Const $WINDOW_HEIGHT = 560
Global Const $DEFAULT_SLOT_COUNT = 8
Global Const $MAX_SLOT_COUNT = 16
Global Const $SLOTS_PER_ROW = 8
Global Const $SLOT_WIDTH = 86
Global Const $SLOT_GAP = 7
Global Const $SLOT_LEFT = 10
Global Const $SLOT_TOP = 50
Global Const $SLOT_ROW_HEIGHT = 95
Global Const $FALLBACK_SCAN_INTERVAL_MS = 1500
Global Const $WORKER_OUTPUT_INTERVAL_MS = 100
Global Const $DEVICE_SETTLE_MS = 600
Global Const $REG_SETTINGS = "HKCU\Software\insan3d\usb-updater"
Global Const $DRIVE_OPTIONS = "--|D:|E:|F:|G:|H:|I:|J:|K:|L:|M:|N:|O:|P:|Q:|R:|S:|T:|U:|V:|W:|X:|Y:|Z:"

; Slot lifecycle.
Global Const $SLOT_EMPTY = "EMPTY"
Global Const $SLOT_WORKING = "WORKING"
Global Const $SLOT_EJECTING = "EJECTING"
Global Const $SLOT_WAIT_EJECT = "WAIT_EJECT"
Global Const $SLOT_ERROR = "ERROR"

; GUI controls and application state.
Global $g_hGui, $g_hBtnSource, $g_hLblSource, $g_hCmbSlotCount, $g_hBtnMonitoring
Global $g_hStatusBar, $g_hLog, $g_sSource = "", $g_bMonitoring = False, $g_iSlotCount = $DEFAULT_SLOT_COUNT
Global $g_hPollTimer = TimerInit(), $g_hWorkerTimer = TimerInit(), $g_hDeviceTimer = TimerInit()
Global $g_bScanRequested = True, $g_bDeviceChangePending = False, $g_bUiDirty = False
Global $g_aSlotDrive[1], $g_aSlotState[1], $g_aSlotIndicator[1]
Global $g_aSlotStatus[1], $g_aSlotPid[1], $g_aSlotBuffer[1], $g_aSlotResult[1]

; Initialise the window and process GUI, device and worker events.
CreateGui()
GUIRegisterMsg($WM_DEVICECHANGE, "WM_DEVICECHANGE")

While True
	Local $iMsg = GUIGetMsg()
	If $iMsg = $GUI_EVENT_CLOSE Then
		If CanCloseApplication() Then ExitLoop
	EndIf

	HandleGuiEvent($iMsg)

	If $g_bScanRequested Or ($g_bDeviceChangePending And TimerDiff($g_hDeviceTimer) >= $DEVICE_SETTLE_MS) Or TimerDiff($g_hPollTimer) >= $FALLBACK_SCAN_INTERVAL_MS Then
		$g_hPollTimer = TimerInit()
		$g_bScanRequested = False
		$g_bDeviceChangePending = False
		PollSlots()
	EndIf

	If TimerDiff($g_hWorkerTimer) >= $WORKER_OUTPUT_INTERVAL_MS Then
		$g_hWorkerTimer = TimerInit()
		ReadWorkerOutputs()
	EndIf

	If $g_bUiDirty Then
		UpdateConfigurationControls()
		UpdateStatusBar()
		$g_bUiDirty = False
	EndIf
WEnd

GUIDelete($g_hGui)

; Build the static controls, then create the configurable slots and log.
Func CreateGui()
	Local $sLastSource = RegRead($REG_SETTINGS, "LastSourceFolder")
	If Not @error And IsFolder($sLastSource) Then $g_sSource = $sLastSource

	Local $iSavedSlotCount = RegRead($REG_SETTINGS, "SlotCount")
	If Not @error And $iSavedSlotCount >= 1 And $iSavedSlotCount <= $MAX_SLOT_COUNT Then $g_iSlotCount = Number($iSavedSlotCount)

	$g_hGui = GUICreate("USB updater", $WINDOW_WIDTH, $WINDOW_HEIGHT)
	$g_hBtnSource = GUICtrlCreateButton("Выбрать папку...", 10, 10, 145, 28)
	$g_hLblSource = GUICtrlCreateLabel("", 165, 15, 330, 20)

	GUICtrlSetColor($g_hLblSource, 0x555555)
	GUICtrlCreateLabel("Порты:", 500, 15, 42, 20)

	$g_hCmbSlotCount = GUICtrlCreateCombo("", 542, 11, 48, 24)
	GUICtrlSetData($g_hCmbSlotCount, "1|2|3|4|5|6|7|8|9|10|11|12|13|14|15|16", $g_iSlotCount)

	$g_hBtnMonitoring = GUICtrlCreateCheckbox("Мониторинг", 595, 10, 150, 28, BitOR($BS_AUTOCHECKBOX, $BS_PUSHLIKE))

	CreateSlots()
	CreateLogControls("")

	$g_hStatusBar = _GUICtrlStatusBar_Create($g_hGui)
	UpdateSourceLabel()
	UpdateStatusBar()

	GUISetState(@SW_SHOW, $g_hGui)
	If $g_sSource <> "" Then AddLog("Выбран источник: " & $g_sSource)
EndFunc

; Create one set of controls per configured target drive.
Func CreateSlots()
	Local $i
	ReDim $g_aSlotDrive[$g_iSlotCount]
	ReDim $g_aSlotState[$g_iSlotCount]
	ReDim $g_aSlotIndicator[$g_iSlotCount]
	ReDim $g_aSlotStatus[$g_iSlotCount]
	ReDim $g_aSlotPid[$g_iSlotCount]
	ReDim $g_aSlotBuffer[$g_iSlotCount]
	ReDim $g_aSlotResult[$g_iSlotCount]

	For $i = 0 To $g_iSlotCount - 1
		CreateSlotControls($i, GetSavedSlotDrive($i))
		ResetSlotRuntimeState($i)
	Next
EndFunc

; Read a valid saved letter or use the sequential default for a new slot.
Func GetSavedSlotDrive($iSlot)
	Local $sSavedDrive = RegRead($REG_SETTINGS, "Slot" & ($iSlot + 1) & "Drive")
	If Not @error And IsConfiguredDrive($sSavedDrive) Then Return $sSavedDrive

	Return Chr(Asc("E") + $iSlot) & ":"
EndFunc

; Create the three visible controls belonging to one slot.
Func CreateSlotControls($iSlot, $sDrive)
	Local $iX = $SLOT_LEFT + Mod($iSlot, $SLOTS_PER_ROW) * ($SLOT_WIDTH + $SLOT_GAP)
	Local $iTop = GetSlotTop($iSlot)

	$g_aSlotDrive[$iSlot] = GUICtrlCreateCombo("", $iX, $iTop, $SLOT_WIDTH, 24)
	GUICtrlSetData($g_aSlotDrive[$iSlot], $DRIVE_OPTIONS, $sDrive)

	$g_aSlotState[$iSlot] = GUICtrlCreateLabel("", $iX, $iTop + 39, $SLOT_WIDTH, 18, $SS_CENTER)
	$g_aSlotIndicator[$iSlot] = GUICtrlCreateLabel("", $iX, $iTop + 68, $SLOT_WIDTH, 9)
EndFunc

; Initialise state that exists only for the current GUI session.
Func ResetSlotRuntimeState($iSlot)
	$g_aSlotPid[$iSlot] = 0
	$g_aSlotBuffer[$iSlot] = ""
	$g_aSlotResult[$iSlot] = ""
	SetSlotStatus($iSlot, $SLOT_EMPTY)
EndFunc

; The log moves down when a second row of slots is shown.
Func CreateLogControls($sText)
	Local $iTop = GetLogTop()
	$g_hLog = GUICtrlCreateEdit($sText, 10, $iTop, 735, 521 - $iTop, BitOR($ES_MULTILINE, $ES_READONLY, $WS_VSCROLL))

	GUICtrlSetFont($g_hLog, 9, 400, 0, "Consolas")
	GUICtrlSetBkColor($g_hLog, 0x151515)
	GUICtrlSetColor($g_hLog, 0xE0E0E0)
EndFunc

Func GetSlotTop($iSlot)
	Return $SLOT_TOP + Int($iSlot / $SLOTS_PER_ROW) * $SLOT_ROW_HEIGHT
EndFunc

Func GetLogTop()
	Return $SLOT_TOP + (Int(($g_iSlotCount - 1) / $SLOTS_PER_ROW) + 1) * $SLOT_ROW_HEIGHT - 5
EndFunc

; Route GUI control events to their handlers.
Func HandleGuiEvent($iMsg)
	If $iMsg = $g_hBtnSource Then
		SelectSourceFolder()
		Return
	EndIf

	If $iMsg = $g_hBtnMonitoring Then
		SetMonitoring(BitAND(GUICtrlRead($g_hBtnMonitoring), $GUI_CHECKED) = $GUI_CHECKED)
		Return
	EndIf

	If $iMsg = $g_hCmbSlotCount Then
		ChangeSlotCount()
		Return
	EndIf

	SaveSlotLetter($iMsg)
EndFunc

; Recreate slot controls only while monitoring is off and no worker is active.
Func ChangeSlotCount()
	Local $iNewCount = Number(GUICtrlRead($g_hCmbSlotCount))
	If $iNewCount < 1 Or $iNewCount > $MAX_SLOT_COUNT Or $iNewCount = $g_iSlotCount Then Return

	Local $sLog = GUICtrlRead($g_hLog)
	GUISetState(@SW_LOCK, $g_hGui)
	DeleteSlotControls()
	GUICtrlDelete($g_hLog)

	$g_iSlotCount = $iNewCount
	RegWrite($REG_SETTINGS, "SlotCount", "REG_DWORD", $g_iSlotCount)

	CreateSlots()
	CreateLogControls($sLog)
	AddLog("Количество слотов: " & $g_iSlotCount)
	GUISetState(@SW_UNLOCK)
EndFunc

; Remove the current slot controls before changing their count.
Func DeleteSlotControls()
	Local $i
	For $i = 0 To UBound($g_aSlotDrive) - 1
		GUICtrlDelete($g_aSlotDrive[$i])
		GUICtrlDelete($g_aSlotState[$i])
		GUICtrlDelete($g_aSlotIndicator[$i])
	Next
EndFunc

; Source folder selection and persistence.
Func SelectSourceFolder()
	Local $sInitial = $g_sSource
	If Not IsFolder($sInitial) Then $sInitial = @ScriptDir

	Local $sSelected = FileSelectFolder("Выберите папку с данными для копирования", $sInitial, 0, "", $g_hGui)
	If @error Or $sSelected = "" Then Return

	$g_sSource = $sSelected
	RegWrite($REG_SETTINGS, "LastSourceFolder", "REG_SZ", $g_sSource)
	UpdateSourceLabel()
	AddLog("Выбран источник: " & $g_sSource)
EndFunc

; Monitoring configuration and validation.
Func SetMonitoring($bEnabled)
	If $bEnabled Then
		If Not IsFolder($g_sSource) Then
			MsgBox($MB_ICONERROR, "Нет данных", "Сначала выберите существующую папку с данными.")
			GUICtrlSetState($g_hBtnMonitoring, $GUI_UNCHECKED)
			Return
		EndIf

		If Not ValidateSlotConfiguration() Then
			GUICtrlSetState($g_hBtnMonitoring, $GUI_UNCHECKED)
			Return
		EndIf

		$g_bMonitoring = True
		$g_bScanRequested = True
		AddLog("Мониторинг включён")
	Else
		$g_bMonitoring = False
		AddLog("Мониторинг выключен: новые накопители не запускаются")
	EndIf

	UpdateConfigurationControls()
	UpdateStatusBar()
EndFunc

Func ValidateSlotConfiguration()
	Local $i, $j, $sDrive, $sSourceDrive = StringUpper(StringLeft($g_sSource, 2))
	For $i = 0 To $g_iSlotCount - 1
		$sDrive = GetSlotDrive($i)
		If $sDrive = "--" Then ContinueLoop
		If $sDrive = $sSourceDrive Then
			MsgBox($MB_ICONERROR, "Источник выбран как цель", "Папка источника находится на " & $sSourceDrive & ", а эта буква выбрана для слота. Выберите другой источник или уберите букву из слотов.")
			Return False
		EndIf

		For $j = $i + 1 To $g_iSlotCount - 1
			If $sDrive = GetSlotDrive($j) Then
				MsgBox($MB_ICONERROR, "Повтор буквы", "Одна и та же буква выбрана более чем для одного слота: " & $sDrive)
				Return False
			EndIf
		Next
	Next

	Return True
EndFunc

; Scan configured letters and launch workers for newly ready targets.
Func PollSlots()
	Local $i, $sDrive, $bReady
	For $i = 0 To $g_iSlotCount - 1
		$sDrive = GetSlotDrive($i)
		If $sDrive = "--" Then ContinueLoop
		$bReady = DriveStatus($sDrive) = "READY"

		If $g_aSlotStatus[$i] = $SLOT_EMPTY And $g_bMonitoring And $bReady Then StartWorker($i)

		If ($g_aSlotStatus[$i] = $SLOT_WAIT_EJECT Or $g_aSlotStatus[$i] = $SLOT_ERROR) And Not $bReady Then
			SetSlotStatus($i, $SLOT_EMPTY)
			AddLog($sDrive & " носитель отключён, слот свободен")
		EndIf
	Next
EndFunc

; Debounce device-change bursts before the next scan.
Func WM_DEVICECHANGE($hWnd, $iMsg, $wParam, $lParam)
	$g_bDeviceChangePending = True
	$g_hDeviceTimer = TimerInit()
	Return 0
EndFunc

; Worker process lifecycle and stdout protocol.
Func StartWorker($iSlot)
	Local $sWorker = @ScriptDir & "\usb-updater-worker.exe"
	Local $sDrive = GetSlotDrive($iSlot)

	If Not FileExists($sWorker) Then
		SetSlotStatus($iSlot, $SLOT_ERROR)
		AddLog($sDrive & " не найден usb-updater-worker.exe")
		Return
	EndIf

	Local $sCommand = '"' & $sWorker & '" /worker /drive ' & $sDrive & ' /source "' & $g_sSource & '"'
	Local $iPid = Run($sCommand, @ScriptDir, @SW_HIDE, $STDOUT_CHILD)

	If $iPid = 0 Then
		SetSlotStatus($iSlot, $SLOT_ERROR)
		AddLog($sDrive & " не удалось запустить обработку")
		Return
	EndIf

	$g_aSlotPid[$iSlot] = $iPid
	$g_aSlotBuffer[$iSlot] = ""
	$g_aSlotResult[$iSlot] = ""

	SetSlotStatus($iSlot, $SLOT_WORKING)
	AddLog($sDrive & " накопитель обнаружен, начата обработка")
EndFunc

Func ReadWorkerOutputs()
	Local $i, $sRead
	For $i = 0 To $g_iSlotCount - 1
		If $g_aSlotPid[$i] = 0 Then ContinueLoop

		$sRead = StdoutRead($g_aSlotPid[$i])
		If Not @error And $sRead <> "" Then
			$g_aSlotBuffer[$i] &= $sRead
			ProcessWorkerLines($i)
		EndIf

		If Not ProcessExists($g_aSlotPid[$i]) Then FinishWorker($i)
	Next
EndFunc

Func ProcessWorkerLines($iSlot)
	Local $iNewline, $sLine
	While True
		$iNewline = StringInStr($g_aSlotBuffer[$iSlot], @LF)
		If $iNewline = 0 Then ExitLoop

		$sLine = StringLeft($g_aSlotBuffer[$iSlot], $iNewline - 1)
		$g_aSlotBuffer[$iSlot] = StringMid($g_aSlotBuffer[$iSlot], $iNewline + 1)
		$sLine = StringStripWS(StringReplace($sLine, @CR, ""), 3)

		If $sLine <> "" Then ProcessWorkerLine($iSlot, $sLine)
	WEnd
EndFunc

Func ProcessWorkerLine($iSlot, $sLine)
	Local $iSeparator = StringInStr($sLine, "|")

	If $iSeparator = 0 Then Return
	Local $sType = StringLeft($sLine, $iSeparator - 1)
	Local $sValue = StringMid($sLine, $iSeparator + 1)
	Local $sDrive = GetSlotDrive($iSlot)

	Switch $sType
		Case "STATE"
			If $sValue = "COPYING" Then SetSlotStatus($iSlot, $SLOT_WORKING)
			If $sValue = "EJECTING" Then SetSlotStatus($iSlot, $SLOT_EJECTING)

		Case "LOG"
			AddLog($sDrive & " " & $sValue)

		Case "RESULT"
			$g_aSlotResult[$iSlot] = $sValue
	EndSwitch
EndFunc

Func FinishWorker($iSlot)
	Local $sRead = StdoutRead($g_aSlotPid[$iSlot])
	If Not @error And $sRead <> "" Then
		$g_aSlotBuffer[$iSlot] &= $sRead
		ProcessWorkerLines($iSlot)
	EndIf

	Local $sDrive = GetSlotDrive($iSlot)
	$g_aSlotPid[$iSlot] = 0

	If $g_aSlotResult[$iSlot] = "OK" Then
		SetSlotStatus($iSlot, $SLOT_WAIT_EJECT)
		AddLog($sDrive & " готово, носитель можно заменить")
	Else
		SetSlotStatus($iSlot, $SLOT_ERROR)
		If $g_aSlotResult[$iSlot] = "" Then AddLog($sDrive & " обработчик завершился без результата")
	EndIf
EndFunc

; Slot display and persisted configuration.
Func SetSlotStatus($iSlot, $sStatus)
	$g_aSlotStatus[$iSlot] = $sStatus

	Switch $sStatus
		Case $SLOT_EMPTY
			GUICtrlSetData($g_aSlotState[$iSlot], "ПУСТО")
			GUICtrlSetColor($g_aSlotState[$iSlot], 0x555555)
			GUICtrlSetBkColor($g_aSlotIndicator[$iSlot], 0xB8B8B8)

		Case $SLOT_WORKING
			GUICtrlSetData($g_aSlotState[$iSlot], "ЗАПИСЬ")
			GUICtrlSetColor($g_aSlotState[$iSlot], 0x1E5B9B)
			GUICtrlSetBkColor($g_aSlotIndicator[$iSlot], 0x3B82C4)

		Case $SLOT_EJECTING
			GUICtrlSetData($g_aSlotState[$iSlot], "ИЗВЛЕЧЕНИЕ")
			GUICtrlSetColor($g_aSlotState[$iSlot], 0x946200)
			GUICtrlSetBkColor($g_aSlotIndicator[$iSlot], 0xF2B134)

		Case $SLOT_WAIT_EJECT
			GUICtrlSetData($g_aSlotState[$iSlot], "ГОТОВО")
			GUICtrlSetColor($g_aSlotState[$iSlot], 0x287A35)
			GUICtrlSetBkColor($g_aSlotIndicator[$iSlot], 0x4CAF50)

		Case $SLOT_ERROR
			GUICtrlSetData($g_aSlotState[$iSlot], "ОШИБКА")
			GUICtrlSetColor($g_aSlotState[$iSlot], 0xB11B1B)
			GUICtrlSetBkColor($g_aSlotIndicator[$iSlot], 0xD32F2F)
	EndSwitch

	$g_bUiDirty = True
EndFunc

Func SaveSlotLetter($iControl)
	Local $i
	For $i = 0 To $g_iSlotCount - 1
		If $iControl = $g_aSlotDrive[$i] Then
			RegWrite($REG_SETTINGS, "Slot" & ($i + 1) & "Drive", "REG_SZ", GetSlotDrive($i))
			Return
		EndIf
	Next
EndFunc

; UI state and utility helpers.
Func UpdateConfigurationControls()
	Local $i, $iState = $GUI_ENABLE
	If $g_bMonitoring Or HasActiveWorker() Then $iState = $GUI_DISABLE

	GUICtrlSetState($g_hBtnSource, $iState)
	GUICtrlSetState($g_hCmbSlotCount, $iState)

	For $i = 0 To $g_iSlotCount - 1
		GUICtrlSetState($g_aSlotDrive[$i], $iState)
	Next
EndFunc

Func UpdateSourceLabel()
	If $g_sSource = "" Then
		GUICtrlSetData($g_hLblSource, "Источник не выбран")
	Else
		GUICtrlSetData($g_hLblSource, $g_sSource)
	EndIf
EndFunc

Func UpdateStatusBar()
	Local $iWorking = 0, $iErrors = 0, $i, $sText
	For $i = 0 To $g_iSlotCount - 1
		If $g_aSlotStatus[$i] = $SLOT_WORKING Or $g_aSlotStatus[$i] = $SLOT_EJECTING Then $iWorking += 1
		If $g_aSlotStatus[$i] = $SLOT_ERROR Then $iErrors += 1
	Next

	If $iWorking > 0 Then
		$sText = "В работе: " & $iWorking & ". Можно подключать следующие накопители."
	ElseIf $g_bMonitoring Then
		$sText = "Мониторинг включён. Ожидание накопителей."
	Else
		$sText = "Мониторинг выключен"
	EndIf

	If $iErrors > 0 Then $sText &= " Ошибок: " & $iErrors
	_GUICtrlStatusBar_SetText($g_hStatusBar, $sText)
EndFunc

Func HasActiveWorker()
	Local $i
	For $i = 0 To $g_iSlotCount - 1
		If $g_aSlotPid[$i] <> 0 Then Return True
	Next

	Return False
EndFunc

Func CanCloseApplication()
	If Not HasActiveWorker() Then
		Return True
	EndIf

	Local $iResult = MsgBox(BitOR($MB_ICONWARNING, $MB_YESNO), "Обработка продолжается", "Воркер(ы) продолжат работу без окна. Закрыть программу?")
	Return $iResult = $IDYES
EndFunc

Func GetSlotDrive($iSlot)
	Return GUICtrlRead($g_aSlotDrive[$iSlot])
EndFunc

Func IsConfiguredDrive($sDrive)
	Return $sDrive = "--" Or StringRegExp($sDrive, "^[A-Z]:$")
EndFunc

Func IsFolder($sPath)
	Return $sPath <> "" And FileExists($sPath) And StringInStr(FileGetAttrib($sPath), "D") > 0
EndFunc

Func AddLog($sText)
	Local $sCurrent = GUICtrlRead($g_hLog)
	Local $sLine = StringFormat("%02d:%02d:%02d  %s", @HOUR, @MIN, @SEC, $sText)

	If $sCurrent <> "" Then $sCurrent &= @CRLF

	GUICtrlSetData($g_hLog, $sCurrent & $sLine)
	GUICtrlSendMsg($g_hLog, $EM_SETSEL, -1, -1)
	GUICtrlSendMsg($g_hLog, $EM_SCROLLCARET, 0, 0)
EndFunc
