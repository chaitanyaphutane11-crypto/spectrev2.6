#Requires AutoHotkey v2.0
#SingleInstance Force
#Include Acc.ahk
Global Reg_Path := "HKCU\Software\SpectreLab"
Global Target_Exe := "ahk_exe notepad.exe"
Global Log_File := A_ScriptDir . "\Spectre_Master_Log.csv"
Global HxD_Path := "C:\Users\Laxmikant\Desktop\HxD\HxD64.exe"

Global Public_Data := ["Guest_Session", "Standard_User"]
Global Secret_Array := []
Global Virtual_Cache := Map()
Global LastAnalysis := ""

if !FileExist(Log_File)
    FileAppend("Timestamp,Action,Word,Status,MemoryOffset`n", Log_File, "UTF-8")

SanitizeOffset(offset) {
    if InStr(offset, " ")
        offset := StrSplit(offset, " ")[1]
    if !RegExMatch(offset, "^0x[0-9A-Fa-f]+$")
        offset := "0x0"
    return offset
}

; Convert string to hex (with padding)
Spectre_Gadget(val, attackType) {
    hexVal := ""
    Loop StrLen(val) {
        ch := SubStr(val, A_Index, 1)
        hexVal .= Format("{:02X}00", Ord(ch))
    }
    RegWrite(hexVal, "REG_BINARY", Reg_Path, attackType . "_Leak")
    LogToCSV(attackType, val, "Registry_Injected")

    ; Show lookup in all bases
    MsgBox LookupBases(val, hexVal, attackType)
}

; Convert hex back to string
HexToString(hexVal) {
    result := ""
    Loop StrLen(hexVal)//4 {
        pos := (A_Index-1)*4 + 1
        hexPair := SubStr(hexVal, pos, 2)
        result .= Chr("0x" . hexPair)
    }
    return result
}

; Lookup helper: show hex, decimal, octal for each char
LookupBases(val, hexVal := "", attackType := "") {
    out := "AttackType: " attackType "`n"
    out .= "Original String: " val "`n"
    out .= "Hex (padded): " hexVal "`n`n"

    ; Forward lookup
    out .= "--- Forward Lookup ---`n"
    Loop StrLen(val) {
        ch := SubStr(val, A_Index, 1)
        code := Ord(ch)
        out .= Format(
            "Char: {1} | Hex: 0x{2:X} | Dec: {2} | Oct: 0o{2:o}`n",
            ch, code
        )
    }

    ; Reverse lookup
    out .= "`n--- Reverse Lookup ---`n"
    rev := HexToString(hexVal)
    Loop StrLen(rev) {
        ch := SubStr(rev, A_Index, 1)
        code := Ord(ch)
        out .= Format(
            "Char: {1} | Hex: 0x{2:X} | Dec: {2} | Oct: 0o{2:o}`n",
            ch, code
        )
    }

    return out
}


Execute_V1() {
    Predictor_State := 3
    idx := 1
    if (idx <= Public_Data.Length || Predictor_State > 1) {
        Spectre_Gadget(Secret_Array[1], "Variant1")
    }
}

Execute_V2() {
    Target_Func := "Spectre_Gadget"
    %Target_Func%(Secret_Array[2], "Variant2")
}

GetNotepadText(hWnd, ctrlName := "Edit1") {
    try {
        return ControlGetText(ctrlName, "ahk_id " hWnd)
    } catch {
        return WinGetText("ahk_id " hWnd)
    }
}

; Example ScanNotepad that also stores the filename
; --- Find the control that contains a given word (e.g. DATA) ---
FindEditControl(LV, word := "DATA") {
    rowCount := LV.GetCount()
    Loop rowCount {
        ctrlName := LV.GetText(A_Index, 1)   ; column 1 = Control Name
        ctrlText := LV.GetText(A_Index, 2)   ; column 2 = Text Data
        ctrlfileName := LV.GetText(A_Index, 3)   ; column 3 = File Name
        if InStr(StrUpper(ctrlText), StrUpper(word)) {
            return {Name: ctrlName, Text: ctrlText, FileName: ctrlfileName}
        }
    }
    return ""  ; none found
}

; --- Scan Notepad using the control found above ---
ScanNotepad(Terms, stepSize, LV) {
    results := []
    hwnd := WinExist("ahk_exe notepad.exe")
    if !hwnd {
        MsgBox "Notepad not running."
        return results
    }

    for term in Terms {
        editCtrl := FindEditControl(LV, term)
        if !editCtrl {
            results.Push({Word: term, Address: "NOT_FOUND", File: ""})
            continue
        }

        buf := FileRead(editCtrl.FileName, "RAW")

        needle := Buffer(StrLen(term))
        for i, char in StrSplit(term) {
            NumPut("UChar", Ord(char), needle, i-1)
        }

        haySize := buf.Size
        ndlSize := needle.Size
        matches := []

        Loop haySize - ndlSize + 1 {
            offset := A_Index - 1
            match := true

            Loop ndlSize {
                j := A_Index - 1
                if NumGet(buf, offset+j, "UChar") != NumGet(needle, j, "UChar") {
                    match := false
                    break
                }
            }

            if match {
                startOffset := offset
                endOffset   := offset + ndlSize - 1
                ; Store as numbers
                matches.Push({Start: startOffset, End: endOffset})
            }
        }

        if matches.Length {
            results.Push({Word: term, Address: matches, File: editCtrl.FileName})
        } else {
            results.Push({Word: term, Address: "NOT_FOUND", File: editCtrl.FileName})
        }
    }
    return results
}


RunMemScan() {
    Terms := StrSplit(TermsBox.Value, ",")
    ScanLV.Delete()
    stepSize := Integer(StepDropdown.Text)
    Results := ScanNotepad(Terms, stepSize, CtrlLV)

    if IsObject(Results) {
        for item in Results {
            offsetStr := ""
            if (item.Address != "NOT_FOUND") {
                base := BaseDropdown.Text
                count := 0
                for match in item.Address {
                    count++
                    startNum := match.Start
                    endNum   := match.End

                    if (base = "Dec") {
                        startStr := startNum
                        endStr   := endNum
                    } else if (base = "Oct") {
                        startStr := Format("0o{:o}", startNum)
                        endStr   := Format("0o{:o}", endNum)
                    } else {
                        startStr := Format("0x{:X}", startNum)
                        endStr   := Format("0x{:X}", endNum)
                    }

                    if (count > 1)
                        offsetStr .= ", "
                    offsetStr .= Format("{1} - {2}", startStr, endStr)
                }
            } else {
                offsetStr := "NOT_FOUND"
            }
            ScanLV.Add(, item.Word, offsetStr, item.File)
        }
    }
    UpdateStatusBar()
}


ShowInHxD(LV, row) {
    word   := LV.GetText(row, 1)
    offset := LV.GetText(row, 2)
    file   := LV.GetText(row, 3)

    ranges := StrSplit(offset, ",")

    Run '"' HxD_Path '" "' file '"'
    WinWaitActive("ahk_exe HxD64.exe")
    Sleep 1000

    for range in ranges {
        range := Trim(range)
        parts := StrSplit(range, "-")
        if (parts.Length < 2)
            continue

        startStr := Trim(parts[1])
        endStr   := Trim(parts[2])

        ; Convert to numbers
        if (SubStr(startStr,1,2) = "0x")
            startNum := Integer(startStr)
        else if (SubStr(startStr,1,2) = "0o")
            startNum := Integer("0" . SubStr(startStr,3))
        else
            startNum := Integer(startStr)

        if (SubStr(endStr,1,2) = "0x")
            endNum := Integer(endStr)
        else if (SubStr(endStr,1,2) = "0o")
            endNum := Integer("0" . SubStr(endStr,3))
        else
            endNum := Integer(endStr)

        ; Jump to start offset (plain hex digits)
        Send "^g"
        Sleep 200
        Send Format("{:X}", startNum) "{Enter}"

        ; Jump to end offset (plain hex digits)
        Sleep 500
        Send "^g"
        Sleep 200
        Send Format("{:X}", endNum) "{Enter}"

        ; Highlight the range
        bytesToSelect := endNum - startNum + 1
        ; Move caret one byte to the right first
        Send "{Right}"
        Sleep 100

        ; Now select leftward for the full range
        Loop bytesToSelect {
            Send "+{Left}"
            Sleep 30
        }
        ; Pause for confirmation before continuing
        MsgBox "Range " startStr " - " endStr " highlighted. Press OK to continue."
    }
}








LogToCSV(Action, Word, Status, Offset := "N/A") {
    Entry := FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") . "," . Action . "," . Word . "," . Status . "," . Offset . "`n"
    FileAppend(Entry, Log_File, "UTF-8")
}

UpdateSecretArray() {
    Global Secret_Array
    Secret_Array := StrSplit(TermsBox.Value, ",")
}

; ==============================================================================
; GUI INTERFACE
; ==============================================================================
MainGui := Gui("+AlwaysOnTop", "Spectre Master Lab v6.2")
MainGui.SetFont("s9", "Consolas")

MainGui.Add("GroupBox", "w420 h80", "Step 1: Execute Variants & Config")

BtnV1 := MainGui.Add("Button", "xp y30 w120 h25", "Run Variant 1")
BtnV2 := MainGui.Add("Button", "x+40 w120 h25", "Run Variant 2")

; Base label + dropdown on one row
MainGui.Add("Text", "xp y+50 h20 w40", "Base:")
BaseDropdown := MainGui.Add("DropDownList", "x+5 w80", ["Hex","Dec","Oct"])
BaseDropdown.Choose(1)

; Step label + dropdown on the same row, to the right of Base
MainGui.Add("Text", "x+20 h20 w40", "Step:")
StepDropdown := MainGui.Add("DropDownList", "x+5 w80", ["1","8","16","32","64","128","256","512","1024"])
StepDropdown.Choose(3)


StatusBar := MainGui.Add("Text", "x20 y+20 w380 h20 Border", "Base: Hex | Step: 16 | Range: auto")

MainGui.Add("Text", "x10 y+20", "Live Registry Monitor (HKCU\\Software\\SpectreLab):")
RegLV := MainGui.Add("ListView", "r3 w420", ["Value Name", "Binary Data (Hex)"])

MainGui.Add("GroupBox", "x10 y+20 w420 h200", "Step 2: Cross-Process Extraction (Notepad)")
MainGui.Add("Text", "xp+20 yp+30", "Terms to Find (comma-separated):")
TermsBox := MainGui.Add("Edit", "w380 r1", "DATA,V1_BOUNDS_BYPASS")
BtnScan := MainGui.Add("Button", "w380 h30", "Scan Notepad Memory")
; Add three columns to your ListView: Word, Address, File
ScanLV := MainGui.Add("ListView", "w400 h90", ["Word","Address","File"])

; Double‑click handler
ScanLV.OnEvent("DoubleClick", ShowInHxD)

MainGui.Add("GroupBox", "x10 y+20 w420 h280", "Debug: Notepad Controls & Data")
BtnListControls := MainGui.Add("Button", "xp+20 yp+30 w380 h30", "List Notepad Controls")
CtrlLV := MainGui.Add("ListView", "r6 w380", ["Control Name", "Text Data","File Name"])
BtnAnalyzeAll := MainGui.Add("Button", "w380 h30", "Analyze All Controls")
AnalysisBox := MainGui.Add("Edit", "w380 r6 ReadOnly")
BtnCopy := MainGui.Add("Button", "w380 h30", "Copy Analysis to Clipboard")
BtnHex := MainGui.Add("Button", "w380 h30", "Open Hex Editor")
BtnOpenFile := MainGui.Add("Button", "w380 h30", "Open Selected File in HxD")

BaseDropdown.OnEvent("Change", (*) => UpdateStatusBar())
StepDropdown.OnEvent("Change", (*) => UpdateStatusBar())

UpdateStatusBar() {
    stepSize := Integer(StepDropdown.Text)
    iterations := 1000
    rangeBytes := stepSize * iterations
    rangeKB := Round(rangeBytes / 1024, 2)
    StatusBar.Value := "Base: " BaseDropdown.Text " | Step: " stepSize " | Range: " rangeBytes " bytes (" rangeKB " KB)"
}

; ==============================================================================
; EVENT HANDLER FUNCTIONS
; ==============================================================================
HandleVariant1(*) {
    Execute_V1()
    UpdateRegList(RegLV)
}

HandleVariant2(*) {
    Execute_V2()
    UpdateRegList(RegLV)
}

HandleScan(*) {
    UpdateSecretArray()
    RunMemScan()
}

HandleListControls(*) {
    ShowControls(CtrlLV)
}

HandleAnalyzeAll(*) {
    AnalyzeAllControls(CtrlLV, AnalysisBox)
}

HandleCopy(*) {
    CopyAnalysisToClipboard()
}

HandleHex(*) {
    OpenHexEditor()
}

HandleOpenFile(*) {
    OpenSelectedFile()
}

HandleScanDoubleClick(LV, rowIndex) {

}

HandleCtrlDoubleClick(LV, rowIndex) {
    PreviewControlText(LV, rowIndex)
}

; --- Close event handler ---
HandleClose(*) {
    RegDeleteKey(Reg_Path)
    ExitApp()
}

; ==============================================================================
; HELPER FUNCTIONS
; ==============================================================================

RegEnumValues(KeyPath) {
    values := []
    hKey := 0
    ; Open the registry key (HKCU = 0x80000001)
    if DllCall("Advapi32\RegOpenKeyEx", "Ptr", 0x80000001, "Str", KeyPath, "UInt", 0, "UInt", 0x20019, "Ptr*", hKey) != 0
        return values

    i := 0
    while true {
        nameBuf := Buffer(256)   ; allocate buffer for value name
        nameSize := 256
        result := DllCall("Advapi32\RegEnumValue"
            , "Ptr", hKey
            , "UInt", i
            , "Ptr", nameBuf
            , "UInt*", nameSize
            , "Ptr", 0
            , "UInt*", type
            , "Ptr", 0
            , "UInt*", 0)

        if (result != 0)  ; no more values
            break

        valName := StrGet(nameBuf, "UTF-16")
        values.Push(valName)
        i++
    }
    DllCall("Advapi32\RegCloseKey", "Ptr", hKey)
    return values
}

GetProcessBase(PID) {
    hProc := DllCall("OpenProcess", "UInt", 0x10, "Int", 0, "UInt", PID, "Ptr")
    if !hProc
        return 0

    mbi := Buffer(48, 0) ; MEMORY_BASIC_INFORMATION struct
    addr := 0
    if DllCall("VirtualQueryEx", "Ptr", hProc, "Ptr", addr, "Ptr", mbi, "UInt", mbi.Size) {
        baseAddr := NumGet(mbi, 0, "Ptr")
        DllCall("CloseHandle", "Ptr", hProc)
        return baseAddr
    }
    DllCall("CloseHandle", "Ptr", hProc)
    return 0
}


UpdateRegList(RegLV) {
    RegLV.Delete()
    try {
        for valName in RegEnumValues(Reg_Path) {
            valData := RegRead(Reg_Path, valName)
            hexData := ""
            if IsObject(valData) {
                for byte in valData
                    hexData .= Format("{:02X} ", byte)
            } else {
                hexData := valData
            }
            RegLV.Add(, valName, hexData)
        }
    } catch {
        RegLV.Add(, "No Data", "Registry key not found")
    }
}




ShowControls(LV) {
    LV.Delete()
    if !hWnd := WinExist(Target_Exe)
        return MsgBox("Open Notepad first!", "Target Not Found")

    for ctrl in WinGetControls("ahk_id " hWnd) {
        text := ControlGetText(ctrl, "ahk_id " hWnd)
        oAcc := Acc.ElementFromHandle("ahk_id " hWnd)

	; Show some properties
	;MsgBox "Name: " oAcc.Name " Value: " oAcc.Value
        winTitle := StrSplit(oAcc.Name, "-")[1]
        LV.Add(, ctrl, text, winTitle)
    }
}

AnalyzeAllControls(LV, AnalysisBox) {
    result := ""
    rowCount := LV.GetCount()   ; number of rows in the ListView
    Loop rowCount {
        i := A_Index
        ctrlName := LV.GetText(i, 1)   ; column 1 = control name
        ctrlText := LV.GetText(i, 2)   ; column 2 = text data
        fileName := LV.GetText(i, 3)   ; column 3 = file name/path
        result .= ctrlName ": " ctrlText " [" fileName "]`n"
    }
    AnalysisBox.Value := result
}




CopyAnalysisToClipboard() {
    A_Clipboard := AnalysisBox.Value
    MsgBox("Analysis copied to clipboard.")
}

OpenHexEditor() {
    Run(HxD_Path)
}

OpenSelectedFile() {
    if ScanLV.GetCount() = 0
        return
    addr := ScanLV.GetText(ScanLV.GetNext(), 2)
    Run(HxD_Path " " addr)
}

PreviewControlText(LV, rowIndex) {
    MsgBox("Control Text: " LV.GetText(rowIndex, 2))
}

; ==============================================================================
; BIND EVENTS TO HANDLERS
; ==============================================================================
BtnV1.OnEvent("Click", HandleVariant1)
BtnV2.OnEvent("Click", HandleVariant2)
BtnScan.OnEvent("Click", HandleScan)
BtnListControls.OnEvent("Click", HandleListControls)
BtnAnalyzeAll.OnEvent("Click", HandleAnalyzeAll)
BtnCopy.OnEvent("Click", HandleCopy)
BtnHex.OnEvent("Click", HandleHex)
BtnOpenFile.OnEvent("Click", HandleOpenFile)
ScanLV.OnEvent("DoubleClick", HandleScanDoubleClick)
CtrlLV.OnEvent("DoubleClick", HandleCtrlDoubleClick)
MainGui.OnEvent("Close", HandleClose)

; --- Show GUI ---
MainGui.Show()
