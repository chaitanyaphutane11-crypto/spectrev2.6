#Requires AutoHotkey v2.0
SetWorkingDir A_ScriptDir

global useMarkers := true
global sourceLines := []
global showFullAST := false   ; false = single line AST, true = full program AST

; ===== Helper =====
StrRepeat(str, count) {
    result := ""
    Loop count
        result .= str
    return result
}

StrJoin(sep, arr) {
    out := ""
    for i, v in arr {
        if (i > 1)
            out .= sep
        out .= v
    }
    return out
}

; ===== Lexer =====
Lexer_New(source) {
    return {source: source, pos: 1}
}

Lexer_NextToken(lexer) {
    while (lexer.pos <= StrLen(lexer.source) && RegExMatch(SubStr(lexer.source, lexer.pos, 1), "\s"))
        lexer.pos++

    if (lexer.pos > StrLen(lexer.source))
        return {type: "EOF", value: ""}

    ch := SubStr(lexer.source, lexer.pos, 1)

    if (ch = '"') {
        lexer.pos++
        start := lexer.pos
        while (lexer.pos <= StrLen(lexer.source) && SubStr(lexer.source, lexer.pos, 1) != '"')
            lexer.pos++
        value := SubStr(lexer.source, start, lexer.pos - start)
        lexer.pos++
        return {type: "STRING", value: value}
    }

    if RegExMatch(ch, "[A-Za-z_]") {
        start := lexer.pos
        while (lexer.pos <= StrLen(lexer.source) && RegExMatch(SubStr(lexer.source, lexer.pos, 1), "[A-Za-z0-9_]"))
            lexer.pos++
        value := SubStr(lexer.source, start, lexer.pos - start)
        return {type: "IDENT", value: value}
    }

    if RegExMatch(ch, "[0-9]") {
        start := lexer.pos
        while (lexer.pos <= StrLen(lexer.source) && RegExMatch(SubStr(lexer.source, lexer.pos, 1), "[0-9]"))
            lexer.pos++
        value := SubStr(lexer.source, start, lexer.pos - start)
        return {type: "NUMBER", value: value}
    }

    lexer.pos++
    return {type: "SYMBOL", value: ch}
}

; ===== Parser =====
Parser_New(lexer) {
    return {lexer: lexer, current: Lexer_NextToken(lexer)}
}

Parser_Eat(parser, type) {
    if (parser.current.type = type)
        parser.current := Lexer_NextToken(parser.lexer)
    else
        throw Error("Unexpected token: " . parser.current.type)
}

Parser_Factor(parser) {
    if (parser.current.type = "NUMBER") {
        node := {type: "NumberLiteral", value: parser.current.value}
        Parser_Eat(parser, "NUMBER")
        return node
    } else if (parser.current.type = "STRING") {
        node := {type: "StringLiteral", value: parser.current.value}
        Parser_Eat(parser, "STRING")
        return node
    } else if (parser.current.type = "IDENT") {
        name := parser.current.value
        Parser_Eat(parser, "IDENT")
        if (parser.current.type = "SYMBOL" && parser.current.value = "(") {
            Parser_Eat(parser, "SYMBOL")
            args := []
            while !(parser.current.type = "SYMBOL" && parser.current.value = ")") {
                args.Push(Parser_Expr(parser))
                if (parser.current.type = "SYMBOL" && parser.current.value = ",")
                    Parser_Eat(parser, "SYMBOL")
                else
                    break
            }
            Parser_Eat(parser, "SYMBOL")
            return {type: "CallExpr", callee: name, arguments: args}
        }
        return {type: "Identifier", name: name}
    }
}

Parser_Expr(parser) {
    node := Parser_Factor(parser)
    while (parser.current.type = "SYMBOL" && (parser.current.value = "+" || parser.current.value = "-" || parser.current.value = "=")) {
        op := parser.current.value
        Parser_Eat(parser, "SYMBOL")
        right := Parser_Factor(parser)
        node := {type: "BinaryExpr", operator: op, left: node, right: right}
    }
    return node
}

Parser_Block(parser) {
    body := []
    while (parser.current.type != "EOF" && !(parser.current.type = "IDENT" && (parser.current.value = "EndIf" || parser.current.value = "EndWhile"))) {
        body.Push(Parser_Statement(parser))
    }
    return body
}

Parser_Statement(parser) {
    global showFullAST

    if (parser.current.type = "IDENT" && parser.current.value = "if") {
        Parser_Eat(parser, "IDENT")
        cond := Parser_Expr(parser)
        ; choose block vs single line based on showFullAST
        body := showFullAST ? Parser_Block(parser) : [Parser_Statement(parser)]
        return {type: "IfStatement", condition: cond, body: body}

    } else if (parser.current.type = "IDENT" && parser.current.value = "while") {
        Parser_Eat(parser, "IDENT")
        cond := Parser_Expr(parser)
        body := showFullAST ? Parser_Block(parser) : [Parser_Statement(parser)]
        return {type: "WhileStatement", condition: cond, body: body}

    } else {
        expr := Parser_Expr(parser)
        return {type: "Statement", expr: expr}
    }
}


Parser_Parse(parser) {
    stmts := []
    while (parser.current.type != "EOF") {
        stmts.Push(Parser_Statement(parser))
    }
    return {type: "Program", body: stmts}
}

; ===== Code Generator =====
CodeGen(node, indent := 0) {
    global useMarkers
    space := StrRepeat(" ", indent*2)

    if !IsObject(node)
        return node

    switch node.type {
        case "NumberLiteral":
            return node.value
        case "StringLiteral":
            return '"' . node.value . '"'
        case "Identifier":
            return node.name
        case "BinaryExpr":
            return CodeGen(node.left) . " " . node.operator . " " . CodeGen(node.right)
        case "CallExpr":
            args := []
            for arg in node.arguments
                args.Push(CodeGen(arg))
            return node.callee . "(" . StrJoin(",", args) . ")"
        case "Statement":
            return CodeGen(node.expr)
        case "IfStatement":
            if (useMarkers) {
                code := "if " . CodeGen(node.condition) . "`n"
                for stmt in node.body
                    code .= space . CodeGen(stmt, indent+1) . "`n"
                code .= "EndIf"
                return code
            } else {
                code := "if " . CodeGen(node.condition) . " {" . "`n"
                for stmt in node.body
                    code .= space . CodeGen(stmt, indent+1) . "`n"
                code .= space . "}"
                return code
            }
        case "WhileStatement":
            if (useMarkers) {
                code := "while " . CodeGen(node.condition) . "`n"
                for stmt in node.body
                    code .= space . CodeGen(stmt, indent+1) . "`n"
                code .= "EndWhile"
                return code
            } else {
                code := "while " . CodeGen(node.condition) . " {" . "`n"
                for stmt in node.body
                    code .= space . CodeGen(stmt, indent+1) . "`n"
                code .= space . "}"
                return code
            }
        default:
            return "; Unknown node"
    }
}



; ===== PrettyPrint AST =====
PrettyPrint(node, indent := 0) {
    global useMarkers
    space := StrRepeat(" ", indent*2)
    out := ""

    if !IsObject(node)
        return space . node . "`n"

    switch node.type {
        case "Program":
            out .= "Program`n"
            for stmt in node.body
                out .= PrettyPrint(stmt, indent+1)

        case "Statement":
            out .= space . "Statement`n"
            out .= PrettyPrint(node.expr, indent+1)

        case "BinaryExpr":
            out .= space . "BinaryExpr (" . node.operator . ")`n"
            out .= PrettyPrint(node.left, indent+1)
            out .= PrettyPrint(node.right, indent+1)

        case "NumberLiteral":
            out .= space . "NumberLiteral: " . node.value . "`n"

        case "StringLiteral":
            out .= space . "StringLiteral: " . node.value . "`n"

        case "Identifier":
            out .= space . "Identifier: " . node.name . "`n"

        case "CallExpr":
            out .= space . "CallExpr: " . node.callee . "`n"
            for arg in node.arguments
                out .= PrettyPrint(arg, indent+1)

        case "IfStatement":
            out .= space . "IfStatement`n"
            out .= PrettyPrint(node.condition, indent+1)
            for stmt in node.body
                out .= PrettyPrint(stmt, indent+2)
            if (useMarkers)
                out .= space . "EndIf`n"
            else
                out .= space . "}`n"   ; show closing brace

        case "WhileStatement":
            out .= space . "WhileStatement`n"
            out .= PrettyPrint(node.condition, indent+1)
            for stmt in node.body
                out .= PrettyPrint(stmt, indent+2)
            if (useMarkers)
                out .= space . "EndWhile`n"
            else
                out .= space . "}`n"   ; show closing brace

        default:
            out .= space . "Unknown node: " . node.type . "`n"
    }
    return out
}



; ===== Load Source =====
if !FileExist("test.ahk") {
    MsgBox("File test.ahk not found in script directory.")
    ExitApp
}
source := FileRead("test.ahk", "UTF-8")
sourceLines := StrSplit(source, "`n")

; ===== GUI =====
myGui := Gui()
myGui.OnEvent("Close", (*) => ExitApp())

myGui.Add("Text",, "Enter line numbers (comma separated):")
lineInput := myGui.Add("Edit", "w200 vLineNums")

btnDecode := myGui.Add("Button",, "Decode")
btnDecode.OnEvent("Click", DecodeLines)

btnAST := myGui.Add("Button",, "Show AST")
btnAST.OnEvent("Click", ShowAST)

btnBoth := myGui.Add("Button",, "Show Both")
btnBoth.OnEvent("Click", ShowBoth)

btnToggleAST := myGui.Add("Button",, "Toggle AST Mode")
btnToggleAST.OnEvent("Click", ToggleASTMode)

btnToggleMode := myGui.Add("Button",, "Toggle Brackets/Markers")
btnToggleMode.OnEvent("Click", ToggleMode)

myGui.Add("Text",, "Decoded Code:")
outputCode := myGui.Add("Edit", "w300 h300 vOutputCode ReadOnly")
myGui.Add("Text",, "AST Tree:")
outputAST := myGui.Add("Edit", "w300 h300 vOutputAST ReadOnly x+10")

myGui.Show()

; ===== Handlers =====
DecodeLines(*) {
    global sourceLines, myGui
    lineNums := myGui["LineNums"].Value
    decoded := ""
    for num in StrSplit(lineNums, ",") {
        num := Trim(num)
        if (num != "" && num >= 1 && num <= sourceLines.Length) {
            if (Trim(sourceLines[num]) = "") {
                decoded .= "Line " . num . ": (empty line)`n"
                continue
            }
            try {
                lexer := Lexer_New(sourceLines[num])
                parser := Parser_New(lexer)
                stmt := Parser_Statement(parser)
                decoded .= "Line " . num . ": " . CodeGen(stmt) . "`n"
            } catch as err {
                decoded .= "Line " . num . ": Parse error - " . err.Message . "`n"
            }
        } else {
            decoded .= "Line " . num . ": Invalid line number.`n"
        }
    }
    myGui["OutputCode"].Value := decoded
    myGui["OutputAST"].Value := ""
}

ShowAST(*) {
    global sourceLines, myGui, showFullAST
    lineNums := myGui["LineNums"].Value
    astOutput := ""
    for num in StrSplit(lineNums, ",") {
        num := Trim(num)
        if (num != "" && num >= 1 && num <= sourceLines.Length) {
            if (Trim(sourceLines[num]) = "") {
                astOutput .= "Line " . num . ": (empty line)`n"
                continue
            }
            try {
                lexer := Lexer_New(sourceLines[num])
                parser := Parser_New(lexer)
                ast := showFullAST ? Parser_Parse(parser) : Parser_Statement(parser)
                astOutput .= "Line " . num . " AST:`n" . PrettyPrint(ast) . "`n"
            } catch as err {
                astOutput .= "Line " . num . ": Parse error - " . err.Message . "`n"
            }
        } else {
            astOutput .= "Line " . num . ": Invalid line number.`n"
        }
    }
    myGui["OutputAST"].Value := astOutput
    myGui["OutputCode"].Value := ""
}

ShowBoth(*) {
    global sourceLines, myGui, showFullAST
    lineNums := myGui["LineNums"].Value
    decoded := ""
    astOutput := ""
    for num in StrSplit(lineNums, ",") {
        num := Trim(num)
        if (num != "" && num >= 1 && num <= sourceLines.Length) {
            if (Trim(sourceLines[num]) = "") {
                decoded .= "Line " . num . ": (empty line)`n"
                astOutput .= "Line " . num . ": (empty line)`n"
                continue
            }
            try {
                lexer := Lexer_New(sourceLines[num])
                parser := Parser_New(lexer)
                ast := showFullAST ? Parser_Parse(parser) : Parser_Statement(parser)
                decoded .= "Line " . num . ": " . CodeGen(ast) . "`n"
                astOutput .= "Line " . num . " AST:`n" . PrettyPrint(ast) . "`n"
            } catch as err {
                decoded .= "Line " . num . ": Parse error - " . err.Message . "`n"
                astOutput .= "Line " . num . ": Parse error - " . err.Message . "`n"
            }
        } else {
            decoded .= "Line " . num . ": Invalid line number.`n"
            astOutput .= "Line " . num . ": Invalid line number.`n"
        }
    }
    myGui["OutputCode"].Value := decoded
    myGui["OutputAST"].Value := astOutput
}

ToggleMode(*) {
    global useMarkers, myGui
    useMarkers := !useMarkers
    myGui["OutputCode"].Value := "Mode toggled. Now using " . (useMarkers ? "markers" : "braces")
    myGui["OutputAST"].Value := ""
}

ToggleASTMode(*) {
    global showFullAST, myGui
    showFullAST := !showFullAST
    myGui["OutputAST"].Value := "AST mode toggled. Now showing "
        . (showFullAST ? "entire program AST" : "single line AST")
}
myGui.Show()
