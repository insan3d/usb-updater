Func ShowSettingsDialog()
	If $g_bMonitoring Or HasActiveWorker() Then Return

	Local $hDialog = GUICreate("Настройки", 430, 355, -1, -1, -1, -1, $g_hGui)
	GUICtrlCreateLabel("Количество слотов:", 15, 18, 105, 20)

	Local $hSlotCount = GUICtrlCreateCombo("", 125, 14, 55, 24)
	GUICtrlSetData($hSlotCount, "1|2|3|4|5|6|7|8|9|10|11|12|13|14|15|16", $g_iSlotCount)
	Local $aDriveControls[$MAX_SLOT_COUNT], $i

	For $i = 0 To $MAX_SLOT_COUNT - 1
		Local $iX = 15 + Int($i / 8) * 200, $iY = 77 + Mod($i, 8) * 25
		GUICtrlCreateLabel("Слот " & ($i + 1) & ":", $iX, $iY + 3, 48, 18)
		$aDriveControls[$i] = GUICtrlCreateCombo("", $iX + 52, $iY, 72, 22)

		If $i < UBound($g_aSlotDrive) Then
			GUICtrlSetData($aDriveControls[$i], $DRIVE_OPTIONS, GetSlotDrive($i))
		Else
			GUICtrlSetData($aDriveControls[$i], $DRIVE_OPTIONS, GetSavedSlotDrive($i))
		EndIf

		If $i >= $g_iSlotCount Then GUICtrlSetState($aDriveControls[$i], $GUI_DISABLE)
	Next

	Local $hSave = GUICtrlCreateButton("Сохранить", 260, 316, 75, 26), $hCancel = GUICtrlCreateButton("Отмена", 340, 316, 75, 26)
	GUISetState(@SW_SHOW, $hDialog)

	While True
		Local $aMsg = GUIGetMsg(1)
		If $aMsg[0] = 0 Or $aMsg[1] <> $hDialog Then ContinueLoop
		If $aMsg[0] = $GUI_EVENT_CLOSE Or $aMsg[0] = $hCancel Then ExitLoop
		If $aMsg[0] = $hSlotCount Then SettingsSetEnabled($aDriveControls, Number(GUICtrlRead($hSlotCount)))
		If $aMsg[0] = $hSave And SettingsSave($hSlotCount, $aDriveControls) Then ExitLoop
	WEnd

	GUIDelete($hDialog)
EndFunc

Func SettingsSetEnabled(ByRef $aControls, $iCount)
	Local $i
	For $i = 0 To $MAX_SLOT_COUNT - 1
		If $i < $iCount Then
			GUICtrlSetState($aControls[$i], $GUI_ENABLE)
		Else
			GUICtrlSetState($aControls[$i], $GUI_DISABLE)
		EndIf
	Next
EndFunc

Func SettingsSave($hSlotCount, ByRef $aControls)
	Local $iCount = Number(GUICtrlRead($hSlotCount)), $i, $j, $sDrive

	For $i = 0 To $iCount - 1
		$sDrive = GUICtrlRead($aControls[$i])
		If $sDrive = "--" Then Return False
		For $j = $i + 1 To $iCount - 1
			If $sDrive = GUICtrlRead($aControls[$j]) Then Return False
		Next
		RegWrite($REG_SETTINGS, "Slot" & ($i + 1) & "Drive", "REG_SZ", $sDrive)
	Next

	ApplySlotCount($iCount)

	For $i = 0 To $g_iSlotCount - 1
		GUICtrlSetData($g_aSlotDrive[$i], GetSavedSlotDrive($i))
	Next

	AddLog("Настройки сохранены")
	Return True
EndFunc

#include "app_state.au3"
