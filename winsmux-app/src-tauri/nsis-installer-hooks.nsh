LangString WINSMUX_OPEN_WITH_LABEL 1033 "Open with winsmux"
LangString WINSMUX_OPEN_WITH_LABEL 1041 "winsmuxで開く"

!macro WINSMUX_WRITE_EXPLORER_CONTEXT_MENU ENTRY_KEY TARGET_ARG
  WriteRegStr SHCTX "Software\Classes\${ENTRY_KEY}" "" "$(WINSMUX_OPEN_WITH_LABEL)"
  WriteRegStr SHCTX "Software\Classes\${ENTRY_KEY}" "MUIVerb" "$(WINSMUX_OPEN_WITH_LABEL)"
  WriteRegStr SHCTX "Software\Classes\${ENTRY_KEY}" "Icon" "$\"$INSTDIR\${MAINBINARYNAME}.exe$\",0"
  WriteRegStr SHCTX "Software\Classes\${ENTRY_KEY}" "Position" "Top"
  WriteRegStr SHCTX "Software\Classes\${ENTRY_KEY}\command" "" "$\"$INSTDIR\${MAINBINARYNAME}.exe$\" $\"${TARGET_ARG}$\""
!macroend

!macro WINSMUX_DELETE_EXPLORER_CONTEXT_MENU ENTRY_KEY
  DeleteRegKey SHCTX "Software\Classes\${ENTRY_KEY}"
!macroend

!macro WINSMUX_REFRESH_SHORTCUT_ICON SHORTCUT_PATH
  ${If} ${FileExists} "${SHORTCUT_PATH}"
    CreateShortcut "${SHORTCUT_PATH}" "$INSTDIR\${MAINBINARYNAME}.exe" "" "$INSTDIR\${MAINBINARYNAME}.exe" 0
    !insertmacro SetLnkAppUserModelId "${SHORTCUT_PATH}"
  ${EndIf}
!macroend

!macro NSIS_HOOK_POSTINSTALL
  !insertmacro WINSMUX_WRITE_EXPLORER_CONTEXT_MENU "Directory\shell\winsmux" "%1"
  !insertmacro WINSMUX_WRITE_EXPLORER_CONTEXT_MENU "Directory\Background\shell\winsmux" "%V"
  !insertmacro WINSMUX_REFRESH_SHORTCUT_ICON "$DESKTOP\${PRODUCTNAME}.lnk"
  !if "${STARTMENUFOLDER}" != ""
    !insertmacro WINSMUX_REFRESH_SHORTCUT_ICON "$SMPROGRAMS\$AppStartMenuFolder\${PRODUCTNAME}.lnk"
  !else
    !insertmacro WINSMUX_REFRESH_SHORTCUT_ICON "$SMPROGRAMS\${PRODUCTNAME}.lnk"
  !endif
!macroend

!macro NSIS_HOOK_POSTUNINSTALL
  !insertmacro WINSMUX_DELETE_EXPLORER_CONTEXT_MENU "Directory\shell\winsmux"
  !insertmacro WINSMUX_DELETE_EXPLORER_CONTEXT_MENU "Directory\Background\shell\winsmux"
!macroend
