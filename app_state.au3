#include-once

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
Global Const $SLOT_EMPTY = "EMPTY"
Global Const $SLOT_WORKING = "WORKING"
Global Const $SLOT_VERIFYING = "VERIFYING"
Global Const $SLOT_EJECTING = "EJECTING"
Global Const $SLOT_WAIT_EJECT = "WAIT_EJECT"
Global Const $SLOT_ERROR = "ERROR"

Global $g_hGui, $g_hBtnSource, $g_hLblSource, $g_hBtnSettings, $g_hBtnMonitoring
Global $g_hStatusBar, $g_hLog, $g_sSource = "", $g_bMonitoring = False, $g_iSlotCount = $DEFAULT_SLOT_COUNT
Global $g_sExpectedContentHash = "", $g_sHashError = "", $g_iSourceFileCount = 0
Global $g_hPollTimer = TimerInit(), $g_hWorkerTimer = TimerInit(), $g_hDeviceTimer = TimerInit()
Global $g_bScanRequested = True, $g_bDeviceChangePending = False, $g_bUiDirty = False
Global $g_aSlotDrive[1], $g_aSlotState[1], $g_aSlotIndicator[1]
Global $g_aSlotStatus[1], $g_aSlotPid[1], $g_aSlotBuffer[1], $g_aSlotResult[1], $g_aSlotProgress[1]
