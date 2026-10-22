; Based on Tauri CLI 2.11.1, commit e5ae5b93cdd310045191cc0526f253140ad64b87.
; Modified for winsmux: generation-owned includes and unique plugin namespace.
; Original license terms are preserved in LICENSE_APACHE-2.0 and LICENSE_MIT.
Unicode true
ManifestDPIAware true
; Add in `dpiAwareness` `PerMonitorV2` to manifest for Windows 10 1607+ (note this should not affect lower versions since they should be able to ignore this and pick up `dpiAware` `true` set by `ManifestDPIAware true`)
; Currently undocumented on NSIS's website but is in the Docs folder of source tree, see
; https://github.com/kichik/nsis/blob/5fc0b87b819a9eec006df4967d08e522ddd651c9/Docs/src/attributes.but#L286-L300
; https://github.com/tauri-apps/tauri/pull/10106
ManifestDPIAwareness PerMonitorV2

!if "{{compression}}" == "none"
  SetCompress off
!else
  ; Set the compression algorithm. We default to LZMA.
  SetCompressor /SOLID "{{compression}}"
!endif

!include MUI2.nsh
!include FileFunc.nsh
!include x64.nsh
!include WordFunc.nsh
!include TextFunc.nsh

!macro WINSMUX_OPTION_FLAG OPTION FLAG
  ${GetOptions} $CMDLINE "${OPTION}" ${FLAG}
  ${If} ${Errors}
    StrCpy ${FLAG} 0
  ${Else}
    StrCpy ${FLAG} 1
  ${EndIf}
  ClearErrors
!macroend

; Every helper output line and the root it judged go to the details view, and the abort text names
; what the helper's classification, its last line, means for the user. The text is printed to the
; details view before the abort because the status line truncates it and /P and /S runs do not show
; it at all. A "winsmux installer: restore_incomplete <refusal> <domain> <path>" line whose domain is
; desktop or start_menu means a rollback left that shortcut parked, so the abort text also says that
; the next run puts it back. Any other restore_incomplete line adds nothing to the abort text.
; UN is "" or "un."; PREFIX is "" or "UN_" and selects the install or uninstall strings.
; $0/$1 stay the plugin return/output. $3 ends as the last non-empty line, $5 as the restore flag.
!macro WINSMUX_REPORT_HELPER_FAILURE UN PREFIX
  DetailPrint "winsmux installer root: $INSTDIR"
  DetailPrint "winsmux installer helper exit: $0"
  StrCpy $3 ""
  StrCpy $5 0
  StrCpy $6 ""
  StrCpy $7 0
  ${Do}
    StrCpy $8 $1 1 $7
    ${If} $8 == "$\n"
    ${OrIf} $8 == ""
      ${${UN}TrimNewLines} $6 $6
      ${If} $6 != ""
        DetailPrint "winsmux installer helper: $6"
        StrCpy $3 $6
        StrCpy $6 $6 37
        ${If} $6 == "winsmux installer: restore_incomplete"
          ${${UN}WordFind} $3 " " "+5" $6
          ${If} $6 S== "desktop"
          ${OrIf} $6 S== "start_menu"
            StrCpy $5 1
          ${EndIf}
        ${EndIf}
      ${EndIf}
      StrCpy $6 ""
    ${Else}
      StrCpy $6 "$6$8"
    ${EndIf}
    IntOp $7 $7 + 1
  ${LoopUntil} $8 == ""
  StrCpy $4 "$(WINSMUX_${PREFIX}TRANSACTION_FAILED)"
  ${If} $3 S== "winsmux installer: member_unconfirmed"
    StrCpy $4 "$(WINSMUX_${PREFIX}FAILED_MEMBER)"
  ${ElseIf} $3 S== "winsmux installer: destination_occupied"
    StrCpy $4 "$(WINSMUX_${PREFIX}FAILED_OCCUPIED)"
  ${ElseIf} $3 S== "winsmux installer: shortcut_folder_moved"
    StrCpy $4 "$(WINSMUX_${PREFIX}FAILED_FOLDER_MOVED)"
  ${ElseIf} $3 S== "winsmux installer: legacy_inventory_incomplete"
  ${OrIf} $3 S== "winsmux installer: legacy_receipt_missing"
  ${OrIf} $3 S== "winsmux installer: legacy_profile_incomplete"
    StrCpy $4 "$(WINSMUX_${PREFIX}FAILED_LEGACY_CAPTURE)"
  ${ElseIf} $3 S== "winsmux installer: registration_conflict"
    StrCpy $4 "$(WINSMUX_${PREFIX}FAILED_REGISTRATION)"
  ${ElseIf} $3 S== "winsmux installer: work_running_or_locked"
    StrCpy $4 "$(WINSMUX_${PREFIX}FAILED_RUNNING)"
  ${ElseIf} $3 S== "winsmux installer: pending_unconfirmed"
    StrCpy $4 "$(WINSMUX_${PREFIX}FAILED_PENDING)"
  ${EndIf}
  ${If} $5 = 1
    StrCpy $4 "$4 $(WINSMUX_${PREFIX}RESTORE_INCOMPLETE)"
  ${EndIf}
  DetailPrint $4
  Abort $4
!macroend

; Diagnostic-only finite observation. Remove with the exact four-file overlay.
; $0/$1 remain the existing plugin return/combined output; only $2 is diagnostic.
!macro WINSMUX_OBSERVE_FAILURE STAGE
  StrCpy $2 59
  !if "${STAGE}" == "context-write"
    StrCpy $2 52
  !else if "${STAGE}" == "helper"
    ${If} $0 S== "error"
      StrCpy $2 50
    ${ElseIf} $0 S== "timeout"
      StrCpy $2 51
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: usage$\n"
      StrCpy $2 60
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: usage$\r$\n"
      StrCpy $2 60
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: context_refused$\n"
      StrCpy $2 61
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: context_refused$\r$\n"
      StrCpy $2 61
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: plan_refused$\n"
      StrCpy $2 62
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: plan_refused$\r$\n"
      StrCpy $2 62
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: actor_refused$\n"
      StrCpy $2 63
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: actor_refused$\r$\n"
      StrCpy $2 63
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: path_refused$\n"
      StrCpy $2 64
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: path_refused$\r$\n"
      StrCpy $2 64
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: member_unconfirmed$\n"
      StrCpy $2 65
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: member_unconfirmed$\r$\n"
      StrCpy $2 65
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: registration_conflict$\n"
      StrCpy $2 66
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: registration_conflict$\r$\n"
      StrCpy $2 66
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: legacy_inventory_incomplete$\n"
      StrCpy $2 67
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: legacy_inventory_incomplete$\r$\n"
      StrCpy $2 67
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: legacy_receipt_missing$\n"
      StrCpy $2 72
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: legacy_receipt_missing$\r$\n"
      StrCpy $2 72
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: legacy_profile_incomplete$\n"
      StrCpy $2 73
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: legacy_profile_incomplete$\r$\n"
      StrCpy $2 73
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: destination_occupied$\n"
      StrCpy $2 75
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: destination_occupied$\r$\n"
      StrCpy $2 75
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: shortcut_folder_moved$\n"
      StrCpy $2 76
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: shortcut_folder_moved$\r$\n"
      StrCpy $2 76
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: work_running_or_locked$\n"
      StrCpy $2 68
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: work_running_or_locked$\r$\n"
      StrCpy $2 68
    ${ElseIf} $0 S== "3"
    ${AndIf} $1 S== "winsmux installer: pending_unconfirmed$\n"
      StrCpy $2 69
    ${ElseIf} $0 S== "3"
    ${AndIf} $1 S== "winsmux installer: pending_unconfirmed$\r$\n"
      StrCpy $2 69
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: io_unconfirmed$\n"
      StrCpy $2 70
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: io_unconfirmed$\r$\n"
      StrCpy $2 70
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_unconfirmed$\n"
      StrCpy $2 71
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_unconfirmed$\r$\n"
      StrCpy $2 71
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: nsis_startup_usage$\n"
      StrCpy $2 380
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: nsis_startup_usage$\r$\n"
      StrCpy $2 380
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: nsis_startup_plan$\n"
      StrCpy $2 381
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: nsis_startup_plan$\r$\n"
      StrCpy $2 381
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: nsis_startup_path$\n"
      StrCpy $2 382
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: nsis_startup_path$\r$\n"
      StrCpy $2 382
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: nsis_startup_member$\n"
      StrCpy $2 383
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: nsis_startup_member$\r$\n"
      StrCpy $2 383
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: nsis_startup_actor$\n"
      StrCpy $2 384
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: nsis_startup_actor$\r$\n"
      StrCpy $2 384
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: nsis_startup_isolation$\n"
      StrCpy $2 385
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: nsis_startup_isolation$\r$\n"
      StrCpy $2 385
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: nsis_startup_launch$\n"
      StrCpy $2 386
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: nsis_startup_launch$\r$\n"
      StrCpy $2 386
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: nsis_startup_receipt$\n"
      StrCpy $2 387
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: nsis_startup_receipt$\r$\n"
      StrCpy $2 387
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: nsis_startup_timeout$\n"
      StrCpy $2 388
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: nsis_startup_timeout$\r$\n"
      StrCpy $2 388
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: nsis_startup_cleanup$\n"
      StrCpy $2 389
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: nsis_startup_cleanup$\r$\n"
      StrCpy $2 389
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=timeout phase=awaiting_pipe_listening$\nwinsmux installer: nsis_startup_timeout$\n"
      StrCpy $2 390
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=timeout phase=awaiting_pipe_listening$\nwinsmux installer: nsis_startup_timeout$\r$\n"
      StrCpy $2 390
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=timeout phase=awaiting_pipe_listening$\r$\nwinsmux installer: nsis_startup_timeout$\n"
      StrCpy $2 390
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=timeout phase=awaiting_pipe_listening$\r$\nwinsmux installer: nsis_startup_timeout$\r$\n"
      StrCpy $2 390
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=timeout phase=awaiting_pipe_no_data$\nwinsmux installer: nsis_startup_timeout$\n"
      StrCpy $2 391
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=timeout phase=awaiting_pipe_no_data$\nwinsmux installer: nsis_startup_timeout$\r$\n"
      StrCpy $2 391
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=timeout phase=awaiting_pipe_no_data$\r$\nwinsmux installer: nsis_startup_timeout$\n"
      StrCpy $2 391
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=timeout phase=awaiting_pipe_no_data$\r$\nwinsmux installer: nsis_startup_timeout$\r$\n"
      StrCpy $2 391
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=timeout phase=verified_peer_read_zero$\nwinsmux installer: nsis_startup_timeout$\n"
      StrCpy $2 392
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=timeout phase=verified_peer_read_zero$\nwinsmux installer: nsis_startup_timeout$\r$\n"
      StrCpy $2 392
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=timeout phase=verified_peer_read_zero$\r$\nwinsmux installer: nsis_startup_timeout$\n"
      StrCpy $2 392
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=timeout phase=verified_peer_read_zero$\r$\nwinsmux installer: nsis_startup_timeout$\r$\n"
      StrCpy $2 392
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=timeout phase=verified_peer_read_no_data$\nwinsmux installer: nsis_startup_timeout$\n"
      StrCpy $2 393
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=timeout phase=verified_peer_read_no_data$\nwinsmux installer: nsis_startup_timeout$\r$\n"
      StrCpy $2 393
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=timeout phase=verified_peer_read_no_data$\r$\nwinsmux installer: nsis_startup_timeout$\n"
      StrCpy $2 393
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=timeout phase=verified_peer_read_no_data$\r$\nwinsmux installer: nsis_startup_timeout$\r$\n"
      StrCpy $2 393
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=failed phase=awaiting_pipe_listening$\nwinsmux installer: nsis_startup_timeout$\n"
      StrCpy $2 394
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=failed phase=awaiting_pipe_listening$\nwinsmux installer: nsis_startup_timeout$\r$\n"
      StrCpy $2 394
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=failed phase=awaiting_pipe_listening$\r$\nwinsmux installer: nsis_startup_timeout$\n"
      StrCpy $2 394
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=failed phase=awaiting_pipe_listening$\r$\nwinsmux installer: nsis_startup_timeout$\r$\n"
      StrCpy $2 394
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=failed phase=awaiting_pipe_no_data$\nwinsmux installer: nsis_startup_timeout$\n"
      StrCpy $2 395
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=failed phase=awaiting_pipe_no_data$\nwinsmux installer: nsis_startup_timeout$\r$\n"
      StrCpy $2 395
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=failed phase=awaiting_pipe_no_data$\r$\nwinsmux installer: nsis_startup_timeout$\n"
      StrCpy $2 395
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=failed phase=awaiting_pipe_no_data$\r$\nwinsmux installer: nsis_startup_timeout$\r$\n"
      StrCpy $2 395
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=failed phase=verified_peer_read_zero$\nwinsmux installer: nsis_startup_timeout$\n"
      StrCpy $2 396
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=failed phase=verified_peer_read_zero$\nwinsmux installer: nsis_startup_timeout$\r$\n"
      StrCpy $2 396
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=failed phase=verified_peer_read_zero$\r$\nwinsmux installer: nsis_startup_timeout$\n"
      StrCpy $2 396
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=failed phase=verified_peer_read_zero$\r$\nwinsmux installer: nsis_startup_timeout$\r$\n"
      StrCpy $2 396
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=failed phase=verified_peer_read_no_data$\nwinsmux installer: nsis_startup_timeout$\n"
      StrCpy $2 397
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=failed phase=verified_peer_read_no_data$\nwinsmux installer: nsis_startup_timeout$\r$\n"
      StrCpy $2 397
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=failed phase=verified_peer_read_no_data$\r$\nwinsmux installer: nsis_startup_timeout$\n"
      StrCpy $2 397
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=failed phase=verified_peer_read_no_data$\r$\nwinsmux installer: nsis_startup_timeout$\r$\n"
      StrCpy $2 397
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=other phase=awaiting_pipe_listening$\nwinsmux installer: nsis_startup_timeout$\n"
      StrCpy $2 398
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=other phase=awaiting_pipe_listening$\nwinsmux installer: nsis_startup_timeout$\r$\n"
      StrCpy $2 398
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=other phase=awaiting_pipe_listening$\r$\nwinsmux installer: nsis_startup_timeout$\n"
      StrCpy $2 398
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=other phase=awaiting_pipe_listening$\r$\nwinsmux installer: nsis_startup_timeout$\r$\n"
      StrCpy $2 398
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=other phase=awaiting_pipe_no_data$\nwinsmux installer: nsis_startup_timeout$\n"
      StrCpy $2 399
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=other phase=awaiting_pipe_no_data$\nwinsmux installer: nsis_startup_timeout$\r$\n"
      StrCpy $2 399
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=other phase=awaiting_pipe_no_data$\r$\nwinsmux installer: nsis_startup_timeout$\n"
      StrCpy $2 399
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=other phase=awaiting_pipe_no_data$\r$\nwinsmux installer: nsis_startup_timeout$\r$\n"
      StrCpy $2 399
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=other phase=verified_peer_read_zero$\nwinsmux installer: nsis_startup_timeout$\n"
      StrCpy $2 400
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=other phase=verified_peer_read_zero$\nwinsmux installer: nsis_startup_timeout$\r$\n"
      StrCpy $2 400
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=other phase=verified_peer_read_zero$\r$\nwinsmux installer: nsis_startup_timeout$\n"
      StrCpy $2 400
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=other phase=verified_peer_read_zero$\r$\nwinsmux installer: nsis_startup_timeout$\r$\n"
      StrCpy $2 400
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=other phase=verified_peer_read_no_data$\nwinsmux installer: nsis_startup_timeout$\n"
      StrCpy $2 401
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=other phase=verified_peer_read_no_data$\nwinsmux installer: nsis_startup_timeout$\r$\n"
      StrCpy $2 401
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=other phase=verified_peer_read_no_data$\r$\nwinsmux installer: nsis_startup_timeout$\n"
      StrCpy $2 401
    ${ElseIf} $0 S== "2"
    ${AndIf} $1 S== "winsmux installer: startup_timeout_phase root_wait=other phase=verified_peer_read_no_data$\r$\nwinsmux installer: nsis_startup_timeout$\r$\n"
      StrCpy $2 401
    ${EndIf}
    ${If} $2 == 59
      ${If} $1 S== "winsmux installer: path_refused$\n"
      ${OrIf} $1 S== "winsmux installer: path_refused$\r$\n"
        ${If} $0 S== "100"
        ${OrIf} $0 S== "101"
        ${OrIf} $0 S== "102"
        ${OrIf} $0 S== "103"
        ${OrIf} $0 S== "104"
        ${OrIf} $0 S== "105"
        ${OrIf} $0 S== "106"
        ${OrIf} $0 S== "107"
        ${OrIf} $0 S== "108"
        ${OrIf} $0 S== "109"
        ${OrIf} $0 S== "110"
        ${OrIf} $0 S== "111"
        ${OrIf} $0 S== "112"
        ${OrIf} $0 S== "113"
        ${OrIf} $0 S== "114"
        ${OrIf} $0 S== "115"
        ${OrIf} $0 S== "116"
        ${OrIf} $0 S== "117"
        ${OrIf} $0 S== "118"
        ${OrIf} $0 S== "119"
        ${OrIf} $0 S== "120"
        ${OrIf} $0 S== "121"
        ${OrIf} $0 S== "122"
        ${OrIf} $0 S== "123"
        ${OrIf} $0 S== "124"
        ${OrIf} $0 S== "125"
        ${OrIf} $0 S== "126"
        ${OrIf} $0 S== "127"
        ${OrIf} $0 S== "128"
        ${OrIf} $0 S== "129"
        ${OrIf} $0 S== "130"
        ${OrIf} $0 S== "131"
        ${OrIf} $0 S== "132"
        ${OrIf} $0 S== "133"
        ${OrIf} $0 S== "134"
        ${OrIf} $0 S== "135"
        ${OrIf} $0 S== "136"
        ${OrIf} $0 S== "137"
        ${OrIf} $0 S== "138"
        ${OrIf} $0 S== "139"
        ${OrIf} $0 S== "140"
        ${OrIf} $0 S== "141"
        ${OrIf} $0 S== "142"
        ${OrIf} $0 S== "143"
        ${OrIf} $0 S== "144"
        ${OrIf} $0 S== "145"
        ${OrIf} $0 S== "146"
        ${OrIf} $0 S== "147"
        ${OrIf} $0 S== "148"
        ${OrIf} $0 S== "149"
        ${OrIf} $0 S== "150"
        ${OrIf} $0 S== "151"
        ${OrIf} $0 S== "152"
        ${OrIf} $0 S== "153"
        ${OrIf} $0 S== "154"
        ${OrIf} $0 S== "155"
        ${OrIf} $0 S== "156"
        ${OrIf} $0 S== "157"
        ${OrIf} $0 S== "158"
        ${OrIf} $0 S== "159"
        ${OrIf} $0 S== "160"
        ${OrIf} $0 S== "161"
        ${OrIf} $0 S== "162"
        ${OrIf} $0 S== "163"
        ${OrIf} $0 S== "164"
        ${OrIf} $0 S== "165"
        ${OrIf} $0 S== "166"
        ${OrIf} $0 S== "167"
        ${OrIf} $0 S== "168"
        ${OrIf} $0 S== "169"
        ${OrIf} $0 S== "170"
        ${OrIf} $0 S== "171"
        ${OrIf} $0 S== "172"
        ${OrIf} $0 S== "200"
        ${OrIf} $0 S== "201"
        ${OrIf} $0 S== "202"
        ${OrIf} $0 S== "203"
        ${OrIf} $0 S== "204"
        ${OrIf} $0 S== "205"
        ${OrIf} $0 S== "206"
        ${OrIf} $0 S== "207"
        ${OrIf} $0 S== "208"
        ${OrIf} $0 S== "209"
        ${OrIf} $0 S== "210"
        ${OrIf} $0 S== "211"
        ${OrIf} $0 S== "212"
        ${OrIf} $0 S== "213"
        ${OrIf} $0 S== "214"
        ${OrIf} $0 S== "215"
        ${OrIf} $0 S== "216"
        ${OrIf} $0 S== "217"
        ${OrIf} $0 S== "218"
        ${OrIf} $0 S== "219"
        ${OrIf} $0 S== "220"
        ${OrIf} $0 S== "221"
        ${OrIf} $0 S== "222"
        ${OrIf} $0 S== "223"
        ${OrIf} $0 S== "224"
        ${OrIf} $0 S== "225"
        ${OrIf} $0 S== "226"
        ${OrIf} $0 S== "227"
        ${OrIf} $0 S== "228"
        ${OrIf} $0 S== "229"
        ${OrIf} $0 S== "230"
        ${OrIf} $0 S== "231"
        ${OrIf} $0 S== "232"
        ${OrIf} $0 S== "233"
        ${OrIf} $0 S== "234"
        ${OrIf} $0 S== "235"
        ${OrIf} $0 S== "236"
        ${OrIf} $0 S== "237"
        ${OrIf} $0 S== "238"
        ${OrIf} $0 S== "239"
        ${OrIf} $0 S== "240"
        ${OrIf} $0 S== "241"
        ${OrIf} $0 S== "242"
        ${OrIf} $0 S== "243"
        ${OrIf} $0 S== "244"
        ${OrIf} $0 S== "245"
        ${OrIf} $0 S== "246"
        ${OrIf} $0 S== "247"
        ${OrIf} $0 S== "248"
        ${OrIf} $0 S== "249"
        ${OrIf} $0 S== "250"
        ${OrIf} $0 S== "251"
        ${OrIf} $0 S== "252"
        ${OrIf} $0 S== "253"
        ${OrIf} $0 S== "254"
        ${OrIf} $0 S== "255"
        ${OrIf} $0 S== "256"
        ${OrIf} $0 S== "257"
        ${OrIf} $0 S== "258"
        ${OrIf} $0 S== "259"
        ${OrIf} $0 S== "260"
        ${OrIf} $0 S== "261"
        ${OrIf} $0 S== "262"
        ${OrIf} $0 S== "263"
        ${OrIf} $0 S== "264"
        ${OrIf} $0 S== "265"
        ${OrIf} $0 S== "266"
        ${OrIf} $0 S== "267"
        ${OrIf} $0 S== "268"
        ${OrIf} $0 S== "269"
        ${OrIf} $0 S== "270"
        ${OrIf} $0 S== "271"
        ${OrIf} $0 S== "272"
        ${OrIf} $0 S== "273"
        ${OrIf} $0 S== "274"
        ${OrIf} $0 S== "275"
        ${OrIf} $0 S== "276"
        ${OrIf} $0 S== "277"
        ${OrIf} $0 S== "278"
        ${OrIf} $0 S== "279"
        ${OrIf} $0 S== "280"
        ${OrIf} $0 S== "281"
        ${OrIf} $0 S== "282"
        ${OrIf} $0 S== "283"
        ${OrIf} $0 S== "284"
        ${OrIf} $0 S== "285"
        ${OrIf} $0 S== "286"
        ${OrIf} $0 S== "287"
        ${OrIf} $0 S== "288"
        ${OrIf} $0 S== "289"
        ${OrIf} $0 S== "290"
        ${OrIf} $0 S== "291"
        ${OrIf} $0 S== "292"
        ${OrIf} $0 S== "293"
        ${OrIf} $0 S== "294"
        ${OrIf} $0 S== "295"
        ${OrIf} $0 S== "296"
        ${OrIf} $0 S== "297"
        ${OrIf} $0 S== "298"
        ${OrIf} $0 S== "299"
        ${OrIf} $0 S== "300"
        ${OrIf} $0 S== "301"
        ${OrIf} $0 S== "302"
        ${OrIf} $0 S== "303"
        ${OrIf} $0 S== "304"
        ${OrIf} $0 S== "305"
        ${OrIf} $0 S== "306"
        ${OrIf} $0 S== "307"
        ${OrIf} $0 S== "308"
        ${OrIf} $0 S== "309"
        ${OrIf} $0 S== "310"
        ${OrIf} $0 S== "311"
        ${OrIf} $0 S== "312"
        ${OrIf} $0 S== "313"
        ${OrIf} $0 S== "314"
        ${OrIf} $0 S== "315"
        ${OrIf} $0 S== "316"
        ${OrIf} $0 S== "317"
        ${OrIf} $0 S== "318"
        ${OrIf} $0 S== "319"
        ${OrIf} $0 S== "320"
        ${OrIf} $0 S== "321"
        ${OrIf} $0 S== "322"
        ${OrIf} $0 S== "323"
        ${OrIf} $0 S== "324"
        ${OrIf} $0 S== "325"
        ${OrIf} $0 S== "326"
        ${OrIf} $0 S== "327"
        ${OrIf} $0 S== "328"
        ${OrIf} $0 S== "329"
        ${OrIf} $0 S== "330"
        ${OrIf} $0 S== "331"
        ${OrIf} $0 S== "332"
        ${OrIf} $0 S== "333"
        ${OrIf} $0 S== "334"
        ${OrIf} $0 S== "335"
        ${OrIf} $0 S== "336"
        ${OrIf} $0 S== "337"
        ${OrIf} $0 S== "338"
        ${OrIf} $0 S== "339"
        ${OrIf} $0 S== "340"
        ${OrIf} $0 S== "341"
        ${OrIf} $0 S== "342"
        ${OrIf} $0 S== "343"
        ${OrIf} $0 S== "344"
        ${OrIf} $0 S== "345"
        ${OrIf} $0 S== "346"
        ${OrIf} $0 S== "347"
        ${OrIf} $0 S== "348"
        ${OrIf} $0 S== "349"
        ${OrIf} $0 S== "350"
        ${OrIf} $0 S== "351"
        ${OrIf} $0 S== "352"
        ${OrIf} $0 S== "353"
        ${OrIf} $0 S== "354"
        ${OrIf} $0 S== "355"
        ${OrIf} $0 S== "356"
        ${OrIf} $0 S== "357"
        ${OrIf} $0 S== "358"
        ${OrIf} $0 S== "359"
        ${OrIf} $0 S== "360"
        ${OrIf} $0 S== "361"
        ${OrIf} $0 S== "362"
        ${OrIf} $0 S== "363"
        ${OrIf} $0 S== "364"
        ${OrIf} $0 S== "365"
        ${OrIf} $0 S== "366"
        ${OrIf} $0 S== "367"
        ${OrIf} $0 S== "368"
          StrCpy $2 $0
        ${EndIf}
      ${EndIf}
    ${EndIf}
  !else
    !error "Unsupported diagnostic observation stage."
  !endif
!macroend

{{#if installer_hooks}}
!include "{{installer_hooks}}"
{{/if}}
!ifndef WINSMUX_NSIS_INPUTS
!error "Verified winsmux NSIS generation is required."
!endif
!include "${WINSMUX_NSIS_INPUTS}\winsmux-utils.nsh"
!include "Win\COM.nsh"
!include "Win\Propkey.nsh"
!include "StrFunc.nsh"
${StrCase}
${StrLoc}


!define WEBVIEW2APPGUID "{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"

!define MANUFACTURER "{{manufacturer}}"
!define PRODUCTNAME "{{product_name}}"
!define VERSION "{{version}}"
!define VERSIONWITHBUILD "{{version_with_build}}"
!define HOMEPAGE "{{homepage}}"
!define INSTALLMODE "{{install_mode}}"
!define LICENSE "{{license}}"
!define INSTALLERICON "{{installer_icon}}"
!define SIDEBARIMAGE "{{sidebar_image}}"
!define HEADERIMAGE "{{header_image}}"
!define UNINSTALLERICON "{{uninstaller_icon}}"
!define UNINSTALLERHEADERIMAGE "{{uninstaller_header_image}}"
!define MAINBINARYNAME "{{main_binary_name}}"
!define MAINBINARYSRCPATH "{{main_binary_path}}"
!include "{{main_binary_path}}.winsmux-nsis-plan.nsh"
!define BUNDLEID "{{bundle_id}}"
!define COPYRIGHT "{{copyright}}"
!define OUTFILE "{{out_file}}"
!define ARCH "{{arch}}"
!define ADDITIONALPLUGINSPATH "{{additional_plugins_path}}"
!define ALLOWDOWNGRADES "{{allow_downgrades}}"
!define DISPLAYLANGUAGESELECTOR "{{display_language_selector}}"
!define INSTALLWEBVIEW2MODE "{{install_webview2_mode}}"
!define WEBVIEW2INSTALLERARGS "{{webview2_installer_args}}"
!define WEBVIEW2BOOTSTRAPPERPATH "{{webview2_bootstrapper_path}}"
!define WEBVIEW2INSTALLERPATH "{{webview2_installer_path}}"
!define MINIMUMWEBVIEW2VERSION "{{minimum_webview2_version}}"
!define UNINSTKEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCTNAME}"
!define MANUKEY "Software\${MANUFACTURER}"
!define MANUPRODUCTKEY "${MANUKEY}\${PRODUCTNAME}"
!define UNINSTALLERSIGNCOMMAND "{{uninstaller_sign_cmd}}"
!define ESTIMATEDSIZE "{{estimated_size}}"
!define STARTMENUFOLDER "{{start_menu_folder}}"

Var PassiveMode
Var UpdateMode
Var NoShortcutMode
Var WinsmuxWorkspace
Var WinsmuxCommand
Var WinsmuxSource
Var WinsmuxContext
Var WinsmuxHelper
Var WinsmuxDesktop
Var WinsmuxStartMenu
Var WinsmuxDesktopCheckbox
Var WinsmuxCommitted

Name "${PRODUCTNAME}"
BrandingText "${COPYRIGHT}"
OutFile "${OUTFILE}"

; We don't actually use this value as default install path,
; it's just for nsis to append the product name folder in the directory selector
; https://nsis.sourceforge.io/Reference/InstallDir
!define PLACEHOLDER_INSTALL_DIR "placeholder\${PRODUCTNAME}"
InstallDir "${PLACEHOLDER_INSTALL_DIR}"

VIProductVersion "${VERSIONWITHBUILD}"
VIAddVersionKey "ProductName" "${PRODUCTNAME}"
VIAddVersionKey "FileDescription" "${PRODUCTNAME}"
VIAddVersionKey "LegalCopyright" "${COPYRIGHT}"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "ProductVersion" "${VERSION}"

# additional plugins
!addplugindir "${ADDITIONALPLUGINSPATH}"
!addplugindir "${WINSMUX_NSIS_INPUTS}\plugins"

; Uninstaller signing command
!if "${UNINSTALLERSIGNCOMMAND}" != ""
  !uninstfinalize '${UNINSTALLERSIGNCOMMAND}'
!endif

; Fixed current-user x64 transaction profile.
!if "${INSTALLMODE}" != "currentUser"
!error "winsmux transactional NSIS supports currentUser only."
!endif
!if "${ARCH}" != "x64"
!error "winsmux transactional NSIS supports x64 only."
!endif
!if "${STARTMENUFOLDER}" != ""
!error "Custom Start Menu folders are unsupported."
!endif
!if "${HOMEPAGE}" != ""
!error "Homepage registration is unsupported."
!endif
{{#each file_associations}}
!error "File associations are unsupported by the fixed transaction profile."
{{/each}}
{{#each deep_link_protocols}}
!error "Deep-link registration is unsupported by the fixed transaction profile."
{{/each}}
RequestExecutionLevel user

; Installer icon
!if "${INSTALLERICON}" != ""
  !define MUI_ICON "${INSTALLERICON}"
!endif

; Installer sidebar image
!if "${SIDEBARIMAGE}" != ""
  !define MUI_WELCOMEFINISHPAGE_BITMAP "${SIDEBARIMAGE}"
!endif

; Enable header images for installer and uninstaller pages when either image is configured.
!if "${HEADERIMAGE}" != ""
  !define MUI_HEADERIMAGE
!else if "${UNINSTALLERHEADERIMAGE}" != ""
  !define MUI_HEADERIMAGE
!endif

; Installer header image
!if "${HEADERIMAGE}" != ""
  !define MUI_HEADERIMAGE_BITMAP "${HEADERIMAGE}"
!endif

; Uninstaller header image
!if "${UNINSTALLERHEADERIMAGE}" != ""
  !define MUI_HEADERIMAGE_UNBITMAP "${UNINSTALLERHEADERIMAGE}"
!endif

; Uninstaller icon
!if "${UNINSTALLERICON}" != ""
  !define MUI_UNICON "${UNINSTALLERICON}"
!endif

; Native transaction owns the language registration.

; Installer pages, must be ordered as they appear
; 1. Welcome Page
!define MUI_PAGE_CUSTOMFUNCTION_PRE SkipIfPassive
!insertmacro MUI_PAGE_WELCOME

; 2. License Page (if defined)
!if "${LICENSE}" != ""
  !define MUI_PAGE_CUSTOMFUNCTION_PRE SkipIfPassive
  !insertmacro MUI_PAGE_LICENSE "$(WINSMUX_LICENSE)"
!endif

; Choose install directory and shortcut intent before publication.

!define MUI_PAGE_CUSTOMFUNCTION_PRE SkipIfPassive
!define MUI_PAGE_CUSTOMFUNCTION_SHOW WinsmuxDesktopChoiceShow
!define MUI_PAGE_CUSTOMFUNCTION_LEAVE WinsmuxDesktopChoiceLeave
!insertmacro MUI_PAGE_DIRECTORY

; Installation page

!insertmacro MUI_PAGE_INSTFILES

; 8. Finish page
;
; Don't auto jump to finish page after installation page,
; because the installation page has useful info that can be used debug any issues with the installer.
!define MUI_FINISHPAGE_NOAUTOCLOSE
; Show run app after installation.
!define MUI_FINISHPAGE_RUN
!define MUI_FINISHPAGE_RUN_FUNCTION RunMainBinary
!define MUI_PAGE_CUSTOMFUNCTION_PRE SkipIfPassive
!insertmacro MUI_PAGE_FINISH

Function RunMainBinary
  ${If} $WinsmuxCommitted != 1
    Return
  ${EndIf}
  winsmux_nsis_utils::RunAsUser "$INSTDIR\${MAINBINARYNAME}.exe" ""
FunctionEnd

; Uninstaller Pages
; 1. Confirm uninstall page
!define MUI_PAGE_CUSTOMFUNCTION_PRE un.SkipIfPassive
!insertmacro MUI_UNPAGE_CONFIRM

; 2. Uninstalling Page
!insertmacro MUI_UNPAGE_INSTFILES

;Languages
{{#each languages}}
!insertmacro MUI_LANGUAGE "{{this}}"
{{/each}}
!insertmacro MUI_RESERVEFILE_LANGDLL
!if "${LICENSE}" != ""
  LicenseLangString WINSMUX_LICENSE ${LANG_ENGLISH} "${LICENSE}"
  LicenseLangString WINSMUX_LICENSE ${LANG_JAPANESE} "${WINSMUX_LICENSE_JAPANESE}"
!endif
{{#each language_files}}
  !include "{{this}}"
{{/each}}

Function .onInit
  StrCpy $PassiveMode 0
  StrCpy $NoShortcutMode 0
  StrCpy $UpdateMode 0
  StrCpy $WinsmuxCommitted 0
  StrCpy $WinsmuxDesktop 1
  StrCpy $WinsmuxStartMenu 1
  !insertmacro WINSMUX_OPTION_FLAG "/P" $PassiveMode

  !insertmacro WINSMUX_OPTION_FLAG "/NS" $NoShortcutMode

  !insertmacro WINSMUX_OPTION_FLAG "/UPDATE" $UpdateMode

  ${If} $NoShortcutMode = 1
  ${OrIf} $UpdateMode = 1
    StrCpy $WinsmuxDesktop 0
    StrCpy $WinsmuxStartMenu 0
  ${EndIf}

  !if "${DISPLAYLANGUAGESELECTOR}" == "true"
    !insertmacro MUI_LANGDLL_DISPLAY
  !endif

  !insertmacro SetContext

  ${If} $INSTDIR == "${PLACEHOLDER_INSTALL_DIR}"
    ; Set default install location
    !if "${INSTALLMODE}" == "perMachine"
      ${If} ${RunningX64}
        !if "${ARCH}" == "x64"
          StrCpy $INSTDIR "$PROGRAMFILES64\${PRODUCTNAME}"
        !else if "${ARCH}" == "arm64"
          StrCpy $INSTDIR "$PROGRAMFILES64\${PRODUCTNAME}"
        !else
          StrCpy $INSTDIR "$PROGRAMFILES\${PRODUCTNAME}"
        !endif
      ${Else}
        StrCpy $INSTDIR "$PROGRAMFILES\${PRODUCTNAME}"
      ${EndIf}
    !else if "${INSTALLMODE}" == "currentUser"
      StrCpy $INSTDIR "$LOCALAPPDATA\${PRODUCTNAME}"
    !endif

    Call RestorePreviousInstallLocation
  ${EndIf}


  !if "${INSTALLMODE}" == "both"
    !insertmacro MULTIUSER_INIT
  !endif
FunctionEnd


Section WebView2
  InitPluginsDir
  ; Check if Webview2 is already installed and skip this section
  ${If} ${RunningX64}
    ReadRegStr $4 HKLM "SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\${WEBVIEW2APPGUID}" "pv"
  ${Else}
    ReadRegStr $4 HKLM "SOFTWARE\Microsoft\EdgeUpdate\Clients\${WEBVIEW2APPGUID}" "pv"
  ${EndIf}
  ${If} $4 == ""
    ReadRegStr $4 HKCU "SOFTWARE\Microsoft\EdgeUpdate\Clients\${WEBVIEW2APPGUID}" "pv"
  ${EndIf}

  ${If} $4 == ""
    ; Webview2 installation
    ;
    ; Skip if updating
    ${If} $UpdateMode <> 1
      !if "${INSTALLWEBVIEW2MODE}" == "downloadBootstrapper"
        Delete "$PLUGINSDIR\MicrosoftEdgeWebview2Setup.exe"
        DetailPrint "$(webview2Downloading)"
        NSISdl::download "https://go.microsoft.com/fwlink/p/?LinkId=2124703" "$PLUGINSDIR\MicrosoftEdgeWebview2Setup.exe"
        Pop $0
        ${If} $0 == "success"
          DetailPrint "$(webview2DownloadSuccess)"
        ${Else}
          DetailPrint "$(webview2DownloadError)"
          Abort "$(webview2AbortError)"
        ${EndIf}
        StrCpy $6 "$PLUGINSDIR\MicrosoftEdgeWebview2Setup.exe"
        Goto install_webview2
      !endif

      !if "${INSTALLWEBVIEW2MODE}" == "embedBootstrapper"
        Delete "$PLUGINSDIR\MicrosoftEdgeWebview2Setup.exe"
        File "/oname=$PLUGINSDIR\MicrosoftEdgeWebview2Setup.exe" "${WEBVIEW2BOOTSTRAPPERPATH}"
        DetailPrint "$(installingWebview2)"
        StrCpy $6 "$PLUGINSDIR\MicrosoftEdgeWebview2Setup.exe"
        Goto install_webview2
      !endif

      !if "${INSTALLWEBVIEW2MODE}" == "offlineInstaller"
        Delete "$TEMP\MicrosoftEdgeWebView2RuntimeInstaller.exe"
        File "/oname=$TEMP\MicrosoftEdgeWebView2RuntimeInstaller.exe" "${WEBVIEW2INSTALLERPATH}"
        DetailPrint "$(installingWebview2)"
        StrCpy $6 "$TEMP\MicrosoftEdgeWebView2RuntimeInstaller.exe"
        Goto install_webview2
      !endif

      Goto webview2_done

      install_webview2:
        DetailPrint "$(installingWebview2)"
        ; $6 holds the path to the webview2 installer
        ExecWait "$6 ${WEBVIEW2INSTALLERARGS} /install" $1
        ${If} $1 = 0
          DetailPrint "$(webview2InstallSuccess)"
        ${Else}
          DetailPrint "$(webview2InstallError)"
          Abort "$(webview2AbortError)"
        ${EndIf}
      webview2_done:
    ${EndIf}
  ${Else}
    !if "${MINIMUMWEBVIEW2VERSION}" != ""
      ${VersionCompare} "${MINIMUMWEBVIEW2VERSION}" "$4" $R0
      ${If} $R0 = 1
        update_webview:
          DetailPrint "$(installingWebview2)"
          ${If} ${RunningX64}
            ReadRegStr $R1 HKLM "SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate" "path"
          ${Else}
            ReadRegStr $R1 HKLM "SOFTWARE\Microsoft\EdgeUpdate" "path"
          ${EndIf}
          ${If} $R1 == ""
            ReadRegStr $R1 HKCU "SOFTWARE\Microsoft\EdgeUpdate" "path"
          ${EndIf}
          ${If} $R1 != ""
            ; Chromium updater docs: https://source.chromium.org/chromium/chromium/src/+/main:docs/updater/user_manual.md
            ; Modified from "HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft EdgeWebView\ModifyPath"
            ExecWait `"$R1" /install appguid=${WEBVIEW2APPGUID}&needsadmin=true` $1
            ${If} $1 = 0
              DetailPrint "$(webview2InstallSuccess)"
            ${Else}
              MessageBox MB_ICONEXCLAMATION|MB_ABORTRETRYIGNORE "$(webview2InstallError)" IDIGNORE ignore IDRETRY update_webview
              Quit
              ignore:
            ${EndIf}
          ${EndIf}
      ${EndIf}
    !endif
  ${EndIf}
SectionEnd

Section Install
  Call WinsmuxInitWorkspace
  SetOutPath "$WinsmuxWorkspace\winsmux-bootstrap"
  File /oname=winsmux.exe "${WINSMUX_NSIS_HELPER_PATH}"
  SetOutPath $WinsmuxSource
  File "${MAINBINARYSRCPATH}"
  File /oname=winsmux.install-plan.json "${WINSMUX_NSIS_PLAN_PATH}"
  {{#each resources_dirs}}
    CreateDirectory "$WinsmuxSource\\{{this}}"
  {{/each}}
  {{#each resources}}
    File /a "/oname={{this.[1]}}" "{{no-escape @key}}"
  {{/each}}
  {{#each binaries}}
    File /a "/oname={{this}}" "{{no-escape @key}}"
  {{/each}}
  WriteUninstaller "$WinsmuxSource\uninstall.exe"
  ${If} $WinsmuxStartMenu = 1
    CreateDirectory "$WinsmuxSource\shortcuts"
    CreateShortcut "$WinsmuxSource\shortcuts\start_menu.lnk" "$INSTDIR\${MAINBINARYNAME}.exe" "" "$INSTDIR\${MAINBINARYNAME}.exe" 0
    !insertmacro SetLnkAppUserModelId "$WinsmuxSource\shortcuts\start_menu.lnk"
  ${EndIf}
  ${If} $WinsmuxDesktop = 1
    CreateDirectory "$WinsmuxSource\shortcuts"
    CreateShortcut "$WinsmuxSource\shortcuts\desktop.lnk" "$INSTDIR\${MAINBINARYNAME}.exe" "" "$INSTDIR\${MAINBINARYNAME}.exe" 0
    !insertmacro SetLnkAppUserModelId "$WinsmuxSource\shortcuts\desktop.lnk"
  ${EndIf}
  Call WinsmuxWriteInstallContext
  nsExec::ExecToStack $WinsmuxCommand
  Pop $0
  Pop $1
  ${If} $0 != 0
    !insertmacro WINSMUX_OBSERVE_FAILURE helper
    SetErrorLevel $2
    !insertmacro WINSMUX_REPORT_HELPER_FAILURE "" ""
  ${EndIf}
  StrCpy $WinsmuxCommitted 1
  ${If} $PassiveMode = 1
    SetAutoClose true
  ${EndIf}
SectionEnd

Function .onInstSuccess
  ${If} $WinsmuxCommitted != 1
    Return
  ${EndIf}
  ; Check for `/R` flag only in silent and passive installers because
  ; GUI installer has a toggle for the user to (re)start the app
  ${If} $PassiveMode = 1
  ${OrIf} ${Silent}
    ${GetOptions} $CMDLINE "/R" $R0
    ${IfNot} ${Errors}
      ${GetOptions} $CMDLINE "/ARGS" $R0
      winsmux_nsis_utils::RunAsUser "$INSTDIR\${MAINBINARYNAME}.exe" "$R0"
    ${EndIf}
  ${EndIf}
FunctionEnd

Function un.onInit
  !insertmacro SetContext

  !if "${INSTALLMODE}" == "both"
    !insertmacro MULTIUSER_UNINIT
  !endif

  ReadRegStr $LANGUAGE HKCU "${MANUPRODUCTKEY}" "Installer Language"
  ${If} $LANGUAGE != 1041
    StrCpy $LANGUAGE 1033
  ${EndIf}
  StrCpy $UpdateMode 0
  StrCpy $PassiveMode 0
  StrCpy $WinsmuxDesktop 0
  StrCpy $WinsmuxStartMenu 0

  !insertmacro WINSMUX_OPTION_FLAG "/P" $PassiveMode

  !insertmacro WINSMUX_OPTION_FLAG "/UPDATE" $UpdateMode
FunctionEnd

Section Uninstall
  Call un.WinsmuxInitWorkspace
  SetOutPath "$WinsmuxWorkspace\winsmux-bootstrap"
  File /oname=winsmux.exe "${WINSMUX_NSIS_HELPER_PATH}"
  SetOutPath $WinsmuxSource
  File /oname=winsmux.install-plan.json "${WINSMUX_NSIS_PLAN_PATH}"
  Call un.WinsmuxWriteUninstallContext
  nsExec::ExecToStack $WinsmuxCommand
  Pop $0
  Pop $1
  ${If} $0 != 0
    !insertmacro WINSMUX_OBSERVE_FAILURE helper
    SetErrorLevel $2
    !insertmacro WINSMUX_REPORT_HELPER_FAILURE "un." "UN_"
  ${EndIf}
  ${If} $PassiveMode = 1
    SetAutoClose true
  ${EndIf}
SectionEnd

Function RestorePreviousInstallLocation
  ReadRegStr $4 SHCTX "${MANUPRODUCTKEY}" ""
  StrCmp $4 "" +2 0
    StrCpy $INSTDIR $4
FunctionEnd

Function Skip
  Abort
FunctionEnd

Function SkipIfPassive
  ${IfThen} $PassiveMode = 1  ${|} Abort ${|}
FunctionEnd
Function un.SkipIfPassive
  ${IfThen} $PassiveMode = 1  ${|} Abort ${|}
FunctionEnd

Function WinsmuxDesktopChoiceShow
  ${If} $UpdateMode = 1
  ${OrIf} $NoShortcutMode = 1
    Return
  ${EndIf}
  FindWindow $1 "#32770" "" $HWNDPARENT
  System::Call 'user32::CreateWindowEx(i 0, w "Button", w "$(createDesktop)", i 0x50010003, i 0, i 180, i 400, i 25, p r1, i 0, i 0, i 0) p .r0'
  StrCpy $WinsmuxDesktopCheckbox $0
  SendMessage $HWNDPARENT ${WM_GETFONT} 0 0 $1
  SendMessage $WinsmuxDesktopCheckbox ${WM_SETFONT} $1 1
  SendMessage $WinsmuxDesktopCheckbox ${BM_SETCHECK} $WinsmuxDesktop 0
FunctionEnd
Function WinsmuxDesktopChoiceLeave
  ${If} $UpdateMode = 1
  ${OrIf} $NoShortcutMode = 1
    Return
  ${EndIf}
  SendMessage $WinsmuxDesktopCheckbox ${BM_GETCHECK} 0 0 $WinsmuxDesktop
FunctionEnd

!macro WINSMUX_WORKSPACE_FUNCTION NAME ACTION COMMAND_OVERHEAD
Function ${NAME}
  Push $0
  Push $1
  Push $2
  Push $3
  StrCpy $WinsmuxWorkspace ""
  StrCpy $WinsmuxCommand ""
  StrCpy $WinsmuxSource ""
  StrCpy $WinsmuxHelper ""
  StrCpy $WinsmuxContext ""
  InitPluginsDir
  StrCpy $0 $PLUGINSDIR
  StrCpy $1 ""
  StrCpy $2 0
  ${If} $0 == ""
    Goto winsmux_workspace_refused
  ${EndIf}
  System::Call 'kernel32::GetLongPathNameW(w r0, w .r1, i ${NSIS_MAX_STRLEN}) i.r2'
  StrCmp $2 "error" winsmux_workspace_refused
  ${If} $2 <= 0
  ${OrIf} $2 >= ${NSIS_MAX_STRLEN}
    Goto winsmux_workspace_refused
  ${EndIf}
  StrLen $3 $1
  ${If} $3 != $2
    Goto winsmux_workspace_refused
  ${EndIf}
  ; L is the returned UTF-16 length. Before expansion, bound both commands:
  ; install = 2L+115; uninstall = 2L+117; source/member <= L+95.
  IntOp $3 $2 * 2
  IntOp $3 $3 + 117
  ${If} $3 >= ${NSIS_MAX_STRLEN}
    Goto winsmux_workspace_refused
  ${EndIf}
  StrCpy $WinsmuxWorkspace $1
  StrCpy $WinsmuxSource "$WinsmuxWorkspace\winsmux-source"
  StrCpy $WinsmuxHelper "$WinsmuxWorkspace\winsmux-bootstrap\winsmux.exe"
  StrCpy $WinsmuxContext "$WinsmuxWorkspace\winsmux-context.txt"
  StrCpy $WinsmuxCommand '$\"$WinsmuxHelper$\" --winsmux-internal-desktop-installer nsis-${ACTION} --context $\"$WinsmuxContext$\"'
  IntOp $3 $2 * 2
  IntOp $3 $3 + ${COMMAND_OVERHEAD}
  StrLen $0 $WinsmuxCommand
  ${If} $0 != $3
    Goto winsmux_workspace_refused
  ${EndIf}
  Goto winsmux_workspace_finish
winsmux_workspace_refused:
  StrCpy $WinsmuxWorkspace ""
  StrCpy $WinsmuxCommand ""
  StrCpy $WinsmuxSource ""
  StrCpy $WinsmuxHelper ""
  StrCpy $WinsmuxContext ""
winsmux_workspace_finish:
  Pop $3
  Pop $2
  Pop $1
  Pop $0
  ${If} $WinsmuxWorkspace == ""
    SetErrorLevel 2
    Abort "$(WINSMUX_TRANSACTION_FAILED)"
  ${EndIf}
FunctionEnd
!macroend
!insertmacro WINSMUX_WORKSPACE_FUNCTION WinsmuxInitWorkspace install 115
!insertmacro WINSMUX_WORKSPACE_FUNCTION un.WinsmuxInitWorkspace uninstall 117

!macro WINSMUX_CONTEXT_FUNCTION NAME ACTION
Function ${NAME}
  ClearErrors
  FileOpen $0 $WinsmuxContext w
  FileWriteUTF16LE $0 "schema=winsmux-nsis-context/v1$\r$\n"
  FileWriteUTF16LE $0 "command=${ACTION}$\r$\n"
  FileWriteUTF16LE $0 "root=$INSTDIR$\r$\n"
  FileWriteUTF16LE $0 "source=$WinsmuxSource$\r$\n"
  FileWriteUTF16LE $0 "plan_sha256=${WINSMUX_NSIS_PLAN_SHA256}$\r$\n"
  FileWriteUTF16LE $0 "version=${WINSMUX_NSIS_VERSION}$\r$\n"
  FileWriteUTF16LE $0 "language=$LANGUAGE$\r$\n"
  FileWriteUTF16LE $0 "start_menu=$WinsmuxStartMenu$\r$\n"
  FileWriteUTF16LE $0 "desktop=$WinsmuxDesktop$\r$\n"
  FileWriteUTF16LE $0 "update=$UpdateMode$\r$\n"
  FileClose $0
  ${If} ${Errors}
    !insertmacro WINSMUX_OBSERVE_FAILURE context-write
    SetErrorLevel $2
    Abort "$(WINSMUX_TRANSACTION_FAILED)"
  ${EndIf}
FunctionEnd
!macroend
!insertmacro WINSMUX_CONTEXT_FUNCTION WinsmuxWriteInstallContext install
!insertmacro WINSMUX_CONTEXT_FUNCTION un.WinsmuxWriteUninstallContext uninstall
