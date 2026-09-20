; Cadmium's Windows installer.
;
; Built with NSIS, which runs under Wine on the Linux machine that builds
; everything else -- see tools/package.sh and docs/RELEASE.md. Produces one
; .exe that installs, registers and uninstalls itself the way Windows expects:
; a Start Menu entry, a .cadmium file association, and a row in Settings ▸ Apps
; that actually removes what it put down.
;
;   makensis -DVERSION=2026.09.20 -DSRC=<staged folder> -DOUT=<setup.exe> cadmium.nsi

Unicode true
!include "MUI2.nsh"
!include "FileFunc.nsh"
!include "LogicLib.nsh"

!ifndef VERSION
  !define VERSION "0.0.0"
!endif
!ifndef SRC
  !error "SRC must point at the staged Windows build"
!endif
!ifndef OUT
  !define OUT "Cadmium-setup.exe"
!endif

!define APPNAME    "Cadmium"
!define PUBLISHER  "cfinite"
!define APPURL     "https://github.com/Kujyssisi/Cadmium"
!define REGUNINST  "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}"

Name          "${APPNAME} ${VERSION}"
OutFile       "${OUT}"
Caption       "${APPNAME} ${VERSION} Setup"
BrandingText  "${APPNAME} ${VERSION}"
; Per user by default: no administrator prompt, and a DAW has no business in
; Program Files unless somebody asks for it there.
InstallDir    "$LOCALAPPDATA\Programs\${APPNAME}"
InstallDirRegKey HKCU "Software\${APPNAME}" "InstallDir"
RequestExecutionLevel user
SetCompressor /SOLID lzma
; The soundfont alone is 142 MB, so the dictionary is worth the memory.
SetCompressorDictSize 64

VIProductVersion "1.0.0.0"
VIAddVersionKey "ProductName"     "${APPNAME}"
VIAddVersionKey "FileDescription" "${APPNAME} installer"
VIAddVersionKey "FileVersion"     "${VERSION}"
VIAddVersionKey "ProductVersion"  "${VERSION}"
VIAddVersionKey "CompanyName"     "${PUBLISHER}"
VIAddVersionKey "LegalCopyright"  "GPL-3.0-or-later"

!define MUI_ABORTWARNING
!define MUI_ICON   "${SRC}\packaging\cadmium.ico"
!define MUI_UNICON "${SRC}\packaging\cadmium.ico"
!define MUI_FINISHPAGE_RUN "$INSTDIR\Cadmium.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Start ${APPNAME}"

!insertmacro MUI_PAGE_LICENSE "${SRC}\LICENSE.txt"
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

; ---------------------------------------------------------------------------
Section "Cadmium" SecMain
  SectionIn RO
  SetOutPath "$INSTDIR"

  ; Everything from the staged folder, minus the installer's own scaffolding.
  File "${SRC}\Cadmium.exe"
  File "${SRC}\Cadmium.pck"
  File "${SRC}\libcadmium.windows.template_release.x86_64.dll"
  File "${SRC}\LICENSE.txt"
  File "${SRC}\COPYRIGHT.txt"
  File "${SRC}\THIRD-PARTY-NOTICES.md"
  File "${SRC}\THIRD-PARTY-GODOT.txt"
  File /nonfatal "${SRC}\README.txt"
  ; The soundfont and the FLARE banks are read from beside the executable, so
  ; they are part of the program rather than optional extras.
  SetOutPath "$INSTDIR\Content"
  File /r "${SRC}\Content\*.*"
  SetOutPath "$INSTDIR\Banks"
  File /r "${SRC}\Banks\*.*"
  SetOutPath "$INSTDIR"

  WriteRegStr HKCU "Software\${APPNAME}" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\${APPNAME}" "Version"    "${VERSION}"

  ; Settings ▸ Apps. Without these it is a folder somebody has to find and
  ; delete by hand, which is not an installed program.
  WriteRegStr   HKCU "${REGUNINST}" "DisplayName"     "${APPNAME}"
  WriteRegStr   HKCU "${REGUNINST}" "DisplayVersion"  "${VERSION}"
  WriteRegStr   HKCU "${REGUNINST}" "Publisher"       "${PUBLISHER}"
  WriteRegStr   HKCU "${REGUNINST}" "URLInfoAbout"    "${APPURL}"
  WriteRegStr   HKCU "${REGUNINST}" "DisplayIcon"     "$INSTDIR\Cadmium.exe"
  WriteRegStr   HKCU "${REGUNINST}" "InstallLocation" "$INSTDIR"
  WriteRegStr   HKCU "${REGUNINST}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr   HKCU "${REGUNINST}" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
  WriteRegDWORD HKCU "${REGUNINST}" "NoModify" 1
  WriteRegDWORD HKCU "${REGUNINST}" "NoRepair" 1
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD HKCU "${REGUNINST}" "EstimatedSize" "$0"

  ; Double-clicking a .cadmium opens it in Cadmium, with Cadmium's icon.
  WriteRegStr HKCU "Software\Classes\.cadmium" "" "Cadmium.Project"
  WriteRegStr HKCU "Software\Classes\Cadmium.Project" "" "Cadmium project"
  WriteRegStr HKCU "Software\Classes\Cadmium.Project\DefaultIcon" "" "$INSTDIR\Cadmium.exe,0"
  WriteRegStr HKCU "Software\Classes\Cadmium.Project\shell\open\command" "" '"$INSTDIR\Cadmium.exe" -- "%1"'
  WriteRegStr HKCU "Software\Classes\Applications\Cadmium.exe\shell\open\command" "" '"$INSTDIR\Cadmium.exe" -- "%1"'
  System::Call 'shell32::SHChangeNotify(i 0x08000000, i 0, i 0, i 0)'

  CreateDirectory "$SMPROGRAMS\${APPNAME}"
  CreateShortCut  "$SMPROGRAMS\${APPNAME}\${APPNAME}.lnk"   "$INSTDIR\Cadmium.exe"
  CreateShortCut  "$SMPROGRAMS\${APPNAME}\Uninstall ${APPNAME}.lnk" "$INSTDIR\Uninstall.exe"

  WriteUninstaller "$INSTDIR\Uninstall.exe"
SectionEnd

Section "Desktop shortcut" SecDesktop
  CreateShortCut "$DESKTOP\${APPNAME}.lnk" "$INSTDIR\Cadmium.exe"
SectionEnd

LangString DESC_SecMain    ${LANG_ENGLISH} "Cadmium, its audio engine, the General MIDI soundfont and the FLARE banks."
LangString DESC_SecDesktop ${LANG_ENGLISH} "A shortcut on the desktop as well as in the Start Menu."
!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
  !insertmacro MUI_DESCRIPTION_TEXT ${SecMain}    $(DESC_SecMain)
  !insertmacro MUI_DESCRIPTION_TEXT ${SecDesktop} $(DESC_SecDesktop)
!insertmacro MUI_FUNCTION_DESCRIPTION_END

; ---------------------------------------------------------------------------
Section "Uninstall"
  ; The program and the two content folders. Named rather than a blanket
  ; wipe of $INSTDIR: somebody who installed into a folder of their own
  ; should not lose whatever else is in it.
  Delete "$INSTDIR\Cadmium.exe"
  Delete "$INSTDIR\Cadmium.pck"
  Delete "$INSTDIR\libcadmium.windows.template_release.x86_64.dll"
  Delete "$INSTDIR\LICENSE.txt"
  Delete "$INSTDIR\COPYRIGHT.txt"
  Delete "$INSTDIR\THIRD-PARTY-NOTICES.md"
  Delete "$INSTDIR\THIRD-PARTY-GODOT.txt"
  Delete "$INSTDIR\README.txt"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir /r "$INSTDIR\Content"
  RMDir /r "$INSTDIR\Banks"
  ; Only if it is empty now, for the same reason.
  RMDir "$INSTDIR"

  Delete "$SMPROGRAMS\${APPNAME}\${APPNAME}.lnk"
  Delete "$SMPROGRAMS\${APPNAME}\Uninstall ${APPNAME}.lnk"
  RMDir  "$SMPROGRAMS\${APPNAME}"
  Delete "$DESKTOP\${APPNAME}.lnk"

  DeleteRegKey HKCU "${REGUNINST}"
  DeleteRegKey HKCU "Software\${APPNAME}"
  DeleteRegKey HKCU "Software\Classes\Cadmium.Project"
  DeleteRegKey HKCU "Software\Classes\Applications\Cadmium.exe"
  ; Only unhook the extension if it is still pointing at us.
  ReadRegStr $0 HKCU "Software\Classes\.cadmium" ""
  ${If} $0 == "Cadmium.Project"
    DeleteRegKey HKCU "Software\Classes\.cadmium"
  ${EndIf}
  System::Call 'shell32::SHChangeNotify(i 0x08000000, i 0, i 0, i 0)'

  ; Projects and settings are the user's, not the installer's, and stay put in
  ; %APPDATA%\Godot\app_userdata\Cadmium.
SectionEnd
