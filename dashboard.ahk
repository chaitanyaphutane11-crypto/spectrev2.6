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

; Now you can safely push values
Secret_Array.Push("DATA")
Secret_Array.Push("V1_BOUNDS_BYPASS")
if !FileExist(Log_File)
    FileAppend("Timestamp,Action,Word,Status,MemoryOffset`n", Log_File, "UTF-8")

SanitizeOffset(offset) {
    if InStr(offset, " ")
        offset := StrSplit(offset, " ")[1]
    if !RegExMatch(offset, "^0x[0-9A-Fa-f]+$")
        offset := "0x0"
    return offset
}

Spectre_Gadget(val, attackType) {
    hexVal := ""
    ; Convert each character to UTF-16LE hex (two bytes per char)
    Loop StrLen(val) {
        ch := SubStr(val, A_Index, 1)
        hexVal .= Format("{:02X}00", Ord(ch))
    }

    ; Write as REG_BINARY
    RegWrite(hexVal, "REG_BINARY", Reg_Path, attackType . "_Leak")

    ; Log the injection
    LogToCSV(attackType, val, "Registry_Injected")

    ; Show a MsgBox with the key name depending on variant
    if (attackType = "Variant1") {
        MsgBox "Spectre Variant 1 key injected:`n" Reg_Path "\" attackType "_Leak"
    } else if (attackType = "Variant2") {
        MsgBox "Spectre Variant 2 key injected:`n" Reg_Path "\" attackType "_Leak"
    } else {
        MsgBox "Spectre key injected:`n" Reg_Path "\" attackType "_Leak"
    }
}

Spectre_ReadBack(attackType) {
    try {
        ; Read the binary value from registry
        hexVal := RegRead(Reg_Path, attackType . "_Leak")

        ; Convert hex string back into characters
        result := ""
        ; Each character is stored as XX00 (UTF-16LE)
        ; So we take every 4 hex digits: e.g. "4100" -> "A"
        Loop StrLen(hexVal) ; step through hex string
        {
            if (Mod(A_Index, 4) = 1) {
                charHex := SubStr(hexVal, A_Index, 2)
                result .= Chr("0x" charHex)
            }
        }

        ; Show the decoded string
        MsgBox "Read back Spectre key for " attackType ":`n" result

        ; Log the read-back verification
        LogToCSV(attackType, result, "Registry_ReadBack")

        return result
    } catch {
        MsgBox "No registry value found for " attackType . "_Leak"
        return ""
    }
}


Execute_V1() {
    Predictor_State := 3
    idx := 1
    if (idx <= Public_Data.Length || Predictor_State > 1) {
        Spectre_Gadget(Secret_Array[1], "Variant1")
        Spectre_ReadBack("Variant1")
    }
}

Execute_V2() {
    Target_Func := "Spectre_Gadget"
    %Target_Func%(Secret_Array[2], "Variant2")
    Target_Func_ReadBack := "Spectre_ReadBack"
    %Target_Func_ReadBack%("Variant2")
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
; Helper: safely parse string into integer
ParseInteger(str) {
    ; If empty string, return 0 to avoid error
    if (str = "")
        return 0

    ; Handle hex with 0x prefix
    if (SubStr(str,1,2) = "0x") {
        return Integer(str) ; hex
    }
    ; Handle pure octal digits (0–7 only)
    else if RegExMatch(str, "^[0-7]+$") {
        value := 0
        for i, ch in StrSplit(str) {
            value := value * 8 + (Ord(ch) - 48)
        }
        return value
    }
    ; Otherwise decimal
    else {
        return Integer(str)
    }
}

ScanNotepad(Terms, stepSize, LV) {
    results := []
    hwnd := WinExist("ahk_exe notepad.exe")
    if !hwnd {
        MsgBox "Notepad not running."
        return results
    }
    count := 0
    for term in Terms {

    editCtrl := FindEditControl(LV, term)
    if !editCtrl {
        results.Push({Word: term, Address: "NOT_FOUND", File: ""})
        continue
    }

    ; Try UTF-8 first, fallback to UTF-16
    bufStr := FileRead(editCtrl.FileName, "UTF-8")
    if !InStr(bufStr, term, true)
        bufStr := FileRead(editCtrl.FileName, "UTF-16")

    matches := []
    pos := 1
    charSize := (InStr(bufStr, term, true) ? 1 : 2)
    count := 8 * count

    while (pos := InStr(bufStr, term, true, pos)) {

        startOffset := (pos - 1) * charSize - 2
        endOffset   := startOffset + (StrLen(term) * charSize)
        ;- 1
        startOffset -= count+count/2
        endOffset -= count+count/2
        matches.Push({Start: startOffset, End: endOffset})
        pos := pos + 1

    }
    count:= count+ 1
    ; Adjust the final match always
if (matches.Length > 0) {
    last := matches.Length
    matches[last].Start += 3 + charSize
    matches[last].End   += 3

    ; Force highlight to cover exactly the term length
    maxLen := StrLen(term) * charSize
    matches[last].Start := matches[last].End - maxLen + 1
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
            base := BaseDropdown.Text
            offsetStr := ""
            lengthStr := ""

            if (item.Address != "NOT_FOUND") {
                count := 0
                for match in item.Address {
                    count++
                    startNum := match.Start
                    endNum   := match.End
                    length   := endNum - startNum + 1
                    startNum += length
                    endNum += length
                    ; Format offsets for display only
                    if (base = "Dec") {
                        startStr := Format("{:d}", startNum)
                        endStr   := Format("{:d}", endNum)
                    } else if (base = "Oct") {
                        ; Correct octal formatting
                        startStr := Format("{:o}", startNum)
                        endStr   := Format("{:o}", endNum)
                    } else { ; Hex
                        startStr := Format("0x{:X}", startNum)
                        endStr   := Format("0x{:X}", endNum)
                    }

                    if (count > 1) {
                        offsetStr .= ", "
                        lengthStr .= ", "
                    }
                    offsetStr .= Format("{1}-{2}", startStr, endStr)
                    lengthStr := length " bytes"
                }
            } else {
                offsetStr := "NOT_FOUND"
                lengthStr := ""
            }

            ScanLV.Add(, item.Word, offsetStr, item.File, lengthStr)
        }
    }
    UpdateStatusBar()
}


ShowInHxD(LV, row) {
    word   := LV.GetText(row, 1)
    offset := LV.GetText(row, 2)
    file   := LV.GetText(row, 3)
    length := LV.GetText(row, 4)

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
        base     := BaseDropdown.Text

        startNum := ParseInteger(startStr)
        endNum   := ParseInteger(endStr)
        startNum -= ParseInteger(StrReplace(length, " bytes"))
        endNum -= ParseInteger(StrReplace(length, " bytes"))
        ; Jump to start offset
        Send "^g"
        Sleep 200
        if (base = "Dec") {
            Send Format("{:d}", startNum) "{Enter}"
        } else if (base = "Oct") {
            Send Format("{:o}", startNum) "{Enter}"
        } else {
            Send Format("{:X}", startNum) "{Enter}"
        }

        ; Jump to end offset
        Sleep 500
        Send "^g"
        Sleep 200
        if (base = "Dec") {
            Send Format("{:d}", endNum) "{Enter}"
        } else if (base = "Oct") {
            Send Format("{:o}", endNum) "{Enter}"
        } else {
            Send Format("{:X}", endNum) "{Enter}"
        }

        ; Highlight the range
        bytesToSelect := ParseInteger(StrReplace(length, " bytes"))
        Loop bytesToSelect {
            Send "+{Right}"
            Sleep 30
        }
        startNum += ParseInteger(StrReplace(length, " bytes"))
        endNum += ParseInteger(StrReplace(length, " bytes"))
        ; Confirmation
        MsgBox "Highlighted " word " at range:`n"
            . "Dec: " startNum " - " endNum "`n"
            . "Hex: 0x" Format("{:X}", startNum) " - 0x" Format("{:X}", endNum) "`n"
            . "Oct: " Format("{:08o}", startNum) " - " Format("{:08o}", endNum) "`n`n"
            . "Length: " bytesToSelect " bytes`n`n"
            . "Press OK to continue to next match."
    }
}


; Helper function for octal parsing
StrToInt(str, base := 10) {
    ; Convert string in given base to integer
    return DllCall("msvcrt\strtol", "str", str, "ptr", 0, "int", base, "int")
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
ScanLV := MainGui.Add("ListView", "w400 h90", ["Word","Address","File","Length"])

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