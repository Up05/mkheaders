package main

import "core:fmt"
import "core:strings"
import "core:os"
import "core:unicode/utf8"

between_any :: proc(a: rune, b: ..rune) -> bool {
    assert(len(b) % 2 == 0)
    for i := 0; i < len(b); i += 2 {
        if a >= b[i] && a <= b[i + 1] do return true
    }
    return false
}

any_of :: proc(a: string, ss: ..string) -> bool {
    for b in ss { if a == b do return true }
    return false
}

first_rune :: proc(s: string) -> rune {
    for r in s do return r
    return 0
}

index_unescaped :: proc(str: string, substr: string) -> int {
    escaped: bool
    for r, i in str {
        if escaped do escaped = false
        else if r == '\\' do escaped = true
        else if strings.starts_with(str[i:], substr) do return i
    }
    return -1
}

index_unescaped_any :: proc(str: string, substrs: ..string) -> int {
    min: int = len(str) + 1
    for substr in substrs {
        idx := index_unescaped(str, substr)
        if idx == -1 do continue
        if idx < min do min = idx
    }
    return min if min != len(str) + 1 else -1
}

rip_apart :: proc(str: string) -> [] string {//{{{
    using strings
    str := str

    skip_whitespace :: proc(s: string) -> string {
        for r, i in s do if !is_space(r) do return s[i:]
        return s
    }

    // I think you can infact '\\n' in comments in C, but whatever
    skip_comment :: proc(s: string) -> (string, bool) {
        if starts_with(s, "//") {
            i := index_unescaped_any(s, "\r", "\n")
            if i == -1 do return s, false
            return s[i+1:], true
        }
        if starts_with(s, "/*") {
            i := index(s, "*/")
            if i == -1 do return s, false
            return s[i+2:], true
        }
        return s, false
    }

    skip_preproc :: proc(s: string) -> (string, bool) {
        if starts_with(s, "#") {
            i := index_unescaped_any(s, "\r", "\n")
            if i == -1 do return s, false
            return s[i+1:], true
        }
        return s, false
    }

    skip_string :: proc(s: string) -> (string, bool) {
        if len(s) == 0 do return "", false
        if s[0] != '"' && s[0] != '\'' do return s, false
        q := s[0]
        escaped := false
        for r, i in s[1:] {
            if escaped do escaped = false
            else if r == '\\' do escaped = true
            else if u8(r) == q do return s[i+2:], true // because s[1:] at start of for loop! 
        }
        fmt.println("[mkheaders warning] mismatched quotes found!")
        return s, false
    }

    grab_token :: proc(s: string) -> (token: string, leftover: string) {
        for r, i in s do if !( between_any(r, 'A', 'Z', 'a', 'z', '0', '9') || r == '_' || r == '$' ) do return s[:i], s[i:]
        return "", s
    }

    tokens: [dynamic] string
    
    for i in 0..<10000 {
        if len(str) < 2 do break

        repeat: bool
        str = skip_whitespace(str)
        str, repeat = skip_comment(str) ; if repeat do continue
        str, repeat = skip_preproc(str) ; if repeat do continue
        str, repeat = skip_string(str)  ; if repeat do continue

        token: string
        token, str = grab_token(str)
        if token != "" do append(&tokens, token)
        else {
            token = utf8.runes_to_string({first_rune(str)}) 
            str = str[utf8.rune_size(first_rune(str)):]
            append(&tokens, token)
        }
    }

    return tokens[:]
}//}}}

dissolve_bodies :: proc(raw_tokens: [] string) -> [] string {
    tokens: [dynamic] string

    curly_level: int
    for token in raw_tokens {
             if token == "{" do curly_level += 1
        else if token == "}"  { curly_level -= 1; append(&tokens, "__ROLLED_BODY__") }
        else if curly_level == 0 do append(&tokens, token)
    }
    
    return tokens[:]
}

function :: proc(tokens: [] string) -> bool {
    is_ident :: proc(s: string) -> bool {
        for r in s {   
            if !( between_any(r, 'A', 'Z', 'a', 'z', '0', '9') || r == '_' || r == '$' ) do return false
        } 
        return true
    }

    for token, i in tokens {
        if i == len(tokens) - 1 do return false
        if is_ident(token) && tokens[i + 1] == "(" do return true
    }
    return false
}

segregate :: proc(raw_tokens: [] string) -> [] string {
    raw_tokens := raw_tokens
    tokens: [dynamic] string
    
    last: int
    for token, i in raw_tokens {
        if i != len(raw_tokens) - 1 {
            if token != ";" && token !=  "__ROLLED_BODY__" do continue
        }

        if function(raw_tokens[last:i]) {
            for tj in raw_tokens[last:i + int(i == len(raw_tokens) - 1)] {
                if tj == "__ROLLED_BODY__" do continue
                append(&tokens, tj)
            }
            append(&tokens, ";\n")
        } 
        last = i + 1
    }

    return tokens[:]
}

inflate :: proc(tokens: [] string) -> [] string {
    tokens := tokens
        
    for &token, i in tokens {
        next := tokens[i + 1] if i < len(tokens) - 1 else ""
        if any_of(next,  "(", ")", ",", "*", ";\n") do continue    // STOPS ADDING SPACE BEFORE THESE
        if any_of(token, "(", ";\n") do continue                   // STOPS ADDING SPACE AFTER  THESE
        
        token = strings.concatenate({ token, " " })
    }
    
    return tokens
}

main :: proc() {

    path := os.args[1] if len(os.args) > 1 else "."
    name := os.args[2] if len(os.args) > 2 else "__function_index.h"
    
    handle, err_open := os.open(path);
    files,  err_list := os.read_dir(handle, 0); 
    
    output : strings.Builder
    strings.write_string(&output, "#ifndef FUNCTION_INDEX_H\n#define FUNCTION_INDEX_H\n")
    strings.write_string(&output, "// This file has been automatically generated by Up05/mkheader\n")

    for file in files {
        if file.is_dir || !strings.has_suffix(file.name, ".c") do continue
        bytes, err_read := os.read_entire_file(file.fullpath)
        text := string(bytes)

        tokens : [] string
        tokens = rip_apart(text)
        tokens = dissolve_bodies(tokens)
        tokens = segregate(tokens)
        tokens = inflate(tokens)

        strings.write_string(&output, "\n// file: ")
        strings.write_string(&output, file.name)
        strings.write_string(&output, "\n\n")
        for token in tokens do strings.write_string(&output, token)
    }
    strings.write_string(&output, "\n#endif\n")
    
    // fmt.println(strings.to_string(output))
    ok := os.write_entire_file(name, output.buf[:])
    if !ok do fmt.printf("mkheader failed to write to file: '%s'\n", name)
}
