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

Global Const $WINDOW_WIDTH = 760
Global Const $WINDOW_HEIGHT = 560
Global Const $SLOT_COUNT = 8
Global Const $SLOT_WIDTH = 86
Global Const $SLOT_GAP = 7
Global Const $SLOT_LEFT = 10
Global Const $SLOT_TOP = 50
Global Const $POLL_INTERVAL_MS = 300
Global Const $REG_SETTINGS = "HKCU\Software\insan3d\usb-updater"

Global Const $SLOT_EMPTY = "EMPTY"
Global Const $SLOT_WORKING = "WORKING"
Global Const $SLOT_EJECTING = "EJECTING"
Global Const $SLOT_WAIT_EJECT = "WAIT_EJECT"
Global Const $SLOT_ERROR = "ERROR"

Global $g_hGui, $g_hBtnSource, $g_hLblSource, $g_hBtnMonitoring
Global $g_hStatusBar, $g_hLog, $g_sSource = "", $g_bMonitoring = False
Global $g_hPollTimer = TimerInit()
Global $g_aSlotDrive[$SLOT_COUNT], $g_aSlotState[$SLOT_COUNT], $g_aSlotIndicator[$SLOT_COUNT]
Global $g_aSlotStatus[$SLOT_COUNT], $g_aSlotPid[$SLOT_COUNT], $g_aSlotBuffer[$SLOT_COUNT], $g_aSlotResult[$SLOT_COUNT]

CreateGui()

While True
	Local $iMsg = GUIGetMsg()
	If $iMsg = $GUI_EVENT_CLOSE Then
		If CanCloseApplication() Then ExitLoop
	EndIf
	HandleGuiEvent($iMsg)

	If TimerDiff($g_hPollTimer) >= $POLL_INTERVAL_MS Then
		$g_hPollTimer = TimerInit()
		PollSlots()
	EndIf
WEnd

GUIDelete($g_hGui)

Func CreateGui()
	Local $sLastSource = RegRead($REG_SETTINGS, "LastSourceFolder")
	If Not @error And IsFolder($sLastSource) Then $g_sSource = $sLastSource

	$g_hGui = GUICreate("USB updater", $WINDOW_WIDTH, $WINDOW_HEIGHT)
	$g_hBtnSource = GUICtrlCreateButton("Выбрать папку...", 10, 10, 145, 28)
	$g_hLblSource = GUICtrlCreateLabel("", 165, 15, 390, 20)
	GUICtrlSetColor($g_hLblSource, 0x555555)
	$g_hBtnMonitoring = GUICtrlCreateCheckbox("Мониторинг", 595, 10, 150, 28, BitOR($BS_AUTOCHECKBOX, $BS_PUSHLIKE))

	CreateSlots()
	GUICtrlCreateLabel("Журнал", 10, 140, 100, 20)
	$g_hLog = GUICtrlCreateEdit("", 10, 162, 735, 359, BitOR($ES_MULTILINE, $ES_READONLY, $WS_VSCROLL))
	GUICtrlSetFont($g_hLog, 9, 400, 0, "Consolas")
	GUICtrlSetBkColor($g_hLog, 0x151515)
	GUICtrlSetColor($g_hLog, 0xE0E0E0)

	$g_hStatusBar = _GUICtrlStatusBar_Create($g_hGui)
	UpdateSourceLabel()
	UpdateStatusBar()
	GUISetState(@SW_SHOW, $g_hGui)
	If $g_sSource <> "" Then AddLog("Выбран источник: " & $g_sSource)
EndFunc

Func CreateSlots()
	Local $i, $iX, $sDefaultDrive, $sSavedDrive
	For $i = 0 To $SLOT_COUNT - 1
		$iX = $SLOT_LEFT + $i * ($SLOT_WIDTH + $SLOT_GAP)
		$sDefaultDrive = Chr(Asc("E") + $i) & ":"
		$sSavedDrive = RegRead($REG_SETTINGS, "Slot" & ($i + 1) & "Drive")
		If @error Or Not IsConfiguredDrive($sSavedDrive) Then $sSavedDrive = $sDefaultDrive
		$g_aSlotDrive[$i] = GUICtrlCreateCombo("", $iX, $SLOT_TOP, $SLOT_WIDTH, 24)
		GUICtrlSetData($g_aSlotDrive[$i], "--|D:|E:|F:|G:|H:|I:|J:|K:|L:|M:|N:|O:|P:|Q:|R:|S:|T:|U:|V:|W:|X:|Y:|Z:", $sSavedDrive)
		$g_aSlotState[$i] = GUICtrlCreateLabel("", $iX, $SLOT_TOP + 39, $SLOT_WIDTH, 18, $SS_CENTER)
		$g_aSlotIndicator[$i] = GUICtrlCreateLabel("", $iX, $SLOT_TOP + 68, $SLOT_WIDTH, 9)
		$g_aSlotPid[$i] = 0
		$g_aSlotBuffer[$i] = ""
		$g_aSlotResult[$i] = ""
		SetSlotStatus($i, $SLOT_EMPTY)
	Next
EndFunc

Func HandleGuiEvent($iMsg)
	If $iMsg = $g_hBtnSource Then
		SelectSourceFolder()
		Return
	EndIf
	If $iMsg = $g_hBtnMonitoring Then
		SetMonitoring(BitAND(GUICtrlRead($g_hBtnMonitoring), $GUI_CHECKED) = $GUI_CHECKED)
		Return
	EndIf
	SaveSlotLetter($iMsg)
EndFunc

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
	For $i = 0 To $SLOT_COUNT - 1
		$sDrive = GetSlotDrive($i)
		If $sDrive = "--" Then ContinueLoop
		If $sDrive = $sSourceDrive Then
			MsgBox($MB_ICONERROR, "Источник выбран как цель", "Папка источника находится на " & $sSourceDrive & ", а эта буква выбрана для слота. Выберите другой источник или уберите букву из слотов.")
			Return False
		EndIf
		For $j = $i + 1 To $SLOT_COUNT - 1
			If $sDrive = GetSlotDrive($j) Then
				MsgBox($MB_ICONERROR, "Повтор буквы", "Одна и та же буква выбрана более чем для одного слота: " & $sDrive)
				Return False
			EndIf
		Next
	Next
	Return True
EndFunc

Func PollSlots()
	Local $i, $sDrive, $bReady
	For $i = 0 To $SLOT_COUNT - 1
		$sDrive = GetSlotDrive($i)
		If $sDrive = "--" Then ContinueLoop
		$bReady = DriveStatus($sDrive) = "READY"

		If $g_aSlotStatus[$i] = $SLOT_EMPTY And $g_bMonitoring And $bReady Then StartWorker($i)
		If ($g_aSlotStatus[$i] = $SLOT_WAIT_EJECT Or $g_aSlotStatus[$i] = $SLOT_ERROR) And Not $bReady Then
			SetSlotStatus($i, $SLOT_EMPTY)
			AddLog($sDrive & " носитель отключён, слот свободен")
		EndIf
	Next
	ReadWorkerOutputs()
	UpdateConfigurationControls()
	UpdateStatusBar()
EndFunc

Func StartWorker($iSlot)
	Local $sWorker = @ScriptDir & "\updater_worker.exe"
	Local $sDrive = GetSlotDrive($iSlot)
	If Not FileExists($sWorker) Then
		SetSlotStatus($iSlot, $SLOT_ERROR)
		AddLog($sDrive & " не найден updater_worker.exe")
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
	For $i = 0 To $SLOT_COUNT - 1
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
EndFunc

Func SaveSlotLetter($iControl)
	Local $i
	For $i = 0 To $SLOT_COUNT - 1
		If $iControl = $g_aSlotDrive[$i] Then
			RegWrite($REG_SETTINGS, "Slot" & ($i + 1) & "Drive", "REG_SZ", GetSlotDrive($i))
			Return
		EndIf
	Next
EndFunc

Func UpdateConfigurationControls()
	Local $i, $iState = $GUI_ENABLE
	If $g_bMonitoring Or HasActiveWorker() Then $iState = $GUI_DISABLE
	GUICtrlSetState($g_hBtnSource, $iState)
	For $i = 0 To $SLOT_COUNT - 1
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
	For $i = 0 To $SLOT_COUNT - 1
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
	For $i = 0 To $SLOT_COUNT - 1
		If $g_aSlotPid[$i] <> 0 Then Return True
	Next
	Return False
EndFunc

Func CanCloseApplication()
	If Not HasActiveWorker() Then Return True
	Return MsgBox(BitOR($MB_ICONWARNING, $MB_YESNO), "Обработка продолжается", "Воркер(ы) продолжат работу без окна. Закрыть программу?") = $IDYES
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
