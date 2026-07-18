#pragma compile(CompanyName, "insan3d")
#pragma compile(ProductName, "USB updater")
#pragma compile(ProductVersion, "1.2.0.0")
#pragma compile(FileVersion, "1.2.0.0")
#pragma compile(FileDescription, "USB updater worker")
#pragma compile(InternalName, "updater-worker")
#pragma compile(OriginalFilename, "usb-updater-worker.exe")
#pragma compile(ExecutionLevel, "asInvoker")
#pragma compile(Icon, "icon.ico")

#include <Crypt.au3>

Opt("MustDeclareVars", 1)

; Windows volume-control constants and retry policy.
Global Const $FSCTL_LOCK_VOLUME = 0x00090018
Global Const $FSCTL_DISMOUNT_VOLUME = 0x00090020
Global Const $IOCTL_STORAGE_EJECT_MEDIA = 0x002D4808
Global Const $LOCK_RETRY_COUNT = 6
Global Const $LOCK_RETRY_DELAY_MS = 500
Global Const $ERROR_ALREADY_EXISTS = 183

; Per-process state.
Global $g_sCopyError = ""
Global $g_hDriveMutex = 0
Global $g_iFilesCopied = 0

Main()

Func OnManifestFileHashed($iFileCount)
	Emit("VERIFY_PROGRESS|" & $iFileCount)
EndFunc

#include "manifest.au3"

; Validate input, prevent concurrent processing of one drive, copy and eject.
Func Main()
	Local $sDrive = GetArgument("/drive")
	Local $sSource = GetArgument("/source")

	If Not IsFolder($sSource) Then FailAndExit("Не найдена папка источника", 10)
	If Not IsDriveLetter($sDrive) Or DriveStatus($sDrive) <> "READY" Then FailAndExit("Накопитель недоступен", 11)
	If Not AcquireDriveMutex($sDrive) Then FailAndExit("Этот накопитель уже обрабатывается другим окном программы", 15)

	Emit("STATE|COPYING")
	Emit("LOG|начата запись на " & $sDrive)

	If Not _Crypt_Startup() Then FailAndExit("Не удалось запустить проверку SHA-256", 12)

	If Not CopyFolderContents($sSource, DriveRoot($sDrive), "") Then
		_Crypt_Shutdown()
		FailAndExit($g_sCopyError, 13)
	EndIf

	Emit("STATE|VERIFYING")
	Emit("LOG|проверка записанных файлов")

	Local $bHashSuccess = True
	Local $sManifestFailure = "", $iManifestFiles = 0
	Local $sManifest = BuildManifest($sSource, DriveRoot($sDrive), "", $bHashSuccess, $sManifestFailure, $iManifestFiles)
	Local $bContentHash = 0

	If $bHashSuccess Then $bContentHash = _Crypt_HashData($sManifest, $CALG_SHA_256)
	Local $bHashFailed = @error Or Not IsBinary($bContentHash) Or BinaryLen($bContentHash) = 0
	_Crypt_Shutdown()

	If Not $bHashSuccess Or $bHashFailed Then FailAndExit("Не удалось вычислить контрольную сумму устройства", 13)
	Local $sContentHash = StringLower(Hex($bContentHash))

	Emit("STATE|EJECTING")
	Emit("LOG|запись и проверка завершены")
	Local $sEjectFailure = ""
	If Not SafelyDismount($sDrive, $sEjectFailure) Then FailAndExit($sEjectFailure, 14)

	Emit("RESULT|HASH:" & $sContentHash)
	ReleaseDriveMutex()
	Exit 0
EndFunc

; One worker per target letter, including workers from another GUI instance.
Func AcquireDriveMutex($sDrive)
	Local $sName = "Local\insan3d.usb-updater.drive-" & StringLeft($sDrive, 1)
	Local $aCall = DllCall("kernel32.dll", "handle", "CreateMutexW", "ptr", 0, "bool", True, "wstr", $sName)
	If @error Or $aCall[0] = 0 Then Return False

	$g_hDriveMutex = $aCall[0]
	If GetLastErrorCode() = $ERROR_ALREADY_EXISTS Then
		DllCall("kernel32.dll", "bool", "CloseHandle", "handle", $g_hDriveMutex)
		$g_hDriveMutex = 0
		Return False
	EndIf

	Return True
EndFunc

; Release the mutex on every normal or handled error path.
Func ReleaseDriveMutex()
	If $g_hDriveMutex = 0 Then Return
	DllCall("kernel32.dll", "bool", "ReleaseMutex", "handle", $g_hDriveMutex)
	DllCall("kernel32.dll", "bool", "CloseHandle", "handle", $g_hDriveMutex)
	$g_hDriveMutex = 0
EndFunc

; Command-line parsing.
Func GetArgument($sName)
	Local $i
	For $i = 1 To $CmdLine[0] - 1
		If StringLower($CmdLine[$i]) = StringLower($sName) Then Return $CmdLine[$i + 1]
	Next

	Return ""
EndFunc

; Recursive copy. Verification runs once over the completed target tree.
Func CopyFolderContents($sSource, $sDestination, $sRelative)
	If Not FileExists($sDestination) And Not DirCreate($sDestination) Then
		$g_sCopyError = "Не удалось создать папку назначения"
		Return False
	EndIf

	Local $hSearch = FileFindFirstFile($sSource & "\*")
	If $hSearch = -1 Then Return True

	Local $sEntry, $sSourcePath, $sDestinationPath, $sChildRelative
	While True
		$sEntry = FileFindNextFile($hSearch)
		If @error Then ExitLoop
		If $sEntry = "." Or $sEntry = ".." Then ContinueLoop

		$sSourcePath = $sSource & "\" & $sEntry
		$sDestinationPath = $sDestination & "\" & $sEntry
		$sChildRelative = $sEntry
		If $sRelative <> "" Then $sChildRelative = $sRelative & "\" & $sEntry

		If StringInStr(FileGetAttrib($sSourcePath), "D") Then
			If Not CopyFolderContents($sSourcePath, $sDestinationPath, $sChildRelative) Then
				FileClose($hSearch)
				Return False
			EndIf
		Else
			If FileCopy($sSourcePath, $sDestinationPath, 1) = 0 Then
				$g_sCopyError = "Ошибка записи: " & SafeEventText($sChildRelative)
				FileClose($hSearch)
				Return False
			EndIf

			$g_iFilesCopied += 1
			Emit("PROGRESS|" & $g_iFilesCopied)

		EndIf
	WEnd

	FileClose($hSearch)
	Return True
EndFunc

; Flush, lock, dismount and eject the completed target volume.
Func SafelyDismount($sDrive, ByRef $sFailure)
	Local $sDevicePath = "\\.\" & StringLeft($sDrive, 2), $aOpen, $iDllError
	Local $hVolume, $iError = 0, $iAttempt, $sStage = ""

	For $iAttempt = 1 To $LOCK_RETRY_COUNT
		$aOpen = DllCall("kernel32.dll", "handle", "CreateFileW", "wstr", $sDevicePath, "dword", BitOR($GENERIC_READ, $GENERIC_WRITE), "dword", BitOR($FILE_SHARE_READ, $FILE_SHARE_WRITE), "ptr", 0, "dword", $OPEN_EXISTING, "dword", 0, "ptr", 0)
		$iDllError = @error

		If $iDllError Then
			$sFailure = "CreateFileW для " & $sDrive & ": ошибка DllCall " & $iDllError & " после " & $iAttempt & " попыток"
			If $iAttempt = $LOCK_RETRY_COUNT Then Return False
			Sleep($LOCK_RETRY_DELAY_MS)
			ContinueLoop
		EndIf

		If $aOpen[0] = Ptr(-1) Then
			$iError = GetLastErrorCode()
			$sStage = "CreateFileW"
		Else
			$hVolume = $aOpen[0]
			If Not FlushVolumeBuffers($hVolume, $iError) Then
				$sStage = "FlushFileBuffers"
			ElseIf Not SendVolumeControl($hVolume, $FSCTL_LOCK_VOLUME, $iError) Then
				$sStage = "FSCTL_LOCK_VOLUME"
			ElseIf Not SendVolumeControl($hVolume, $FSCTL_DISMOUNT_VOLUME, $iError) Then
				$sStage = "FSCTL_DISMOUNT_VOLUME"
			ElseIf Not SendVolumeControl($hVolume, $IOCTL_STORAGE_EJECT_MEDIA, $iError) Then
				$sStage = "IOCTL_STORAGE_EJECT_MEDIA"
			Else
				DllCall("kernel32.dll", "bool", "CloseHandle", "handle", $hVolume)
				ExitLoop
			EndIf

			DllCall("kernel32.dll", "bool", "CloseHandle", "handle", $hVolume)
		EndIf

		$sFailure = $sStage & " " & $sDrive & ": Win32 " & $iError & " после " & $iAttempt & " попыток"
		If $iAttempt = $LOCK_RETRY_COUNT Then Return False
		Sleep($LOCK_RETRY_DELAY_MS)
	Next

	Local $i
	For $i = 1 To 30
		Sleep(100)
		If DriveStatus($sDrive) <> "READY" Then
			Emit("LOG|накопитель безопасно извлечён")
			Return True
		EndIf
	Next

	$sFailure = "IOCTL_STORAGE_EJECT_MEDIA выполнен, но " & $sDrive & " остаётся " & DriveStatus($sDrive) & " спустя 3 секунды"
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

; Windows and path helpers.
Func GetLastErrorCode()
	Local $aCall = DllCall("kernel32.dll", "dword", "GetLastError")
	If @error Then Return -1
	Return $aCall[0]
EndFunc

Func IsFolder($sPath)
	Return $sPath <> "" And FileExists($sPath) And StringInStr(FileGetAttrib($sPath), "D") > 0
EndFunc

Func IsDriveLetter($sDrive)
	Return StringRegExp($sDrive, "^[A-Z]:$")
EndFunc

Func DriveRoot($sDrive)
	Return StringLeft($sDrive, 2) & "\"
EndFunc

Func SafeEventText($sText)
	$sText = StringReplace($sText, "|", "/")
	$sText = StringReplace($sText, @CR, " ")
	Return StringReplace($sText, @LF, " ")
EndFunc

; Line-based protocol consumed by the GUI.
Func Emit($sLine)
	ConsoleWrite($sLine & @LF)
EndFunc

Func FailAndExit($sMessage, $iCode)
	Emit("LOG|ОШИБКА: " & SafeEventText($sMessage))
	Emit("RESULT|ERROR")
	ReleaseDriveMutex()
	Exit $iCode
EndFunc
