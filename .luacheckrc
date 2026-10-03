std = "lua54"
max_line_length = 160
ignore = { "212/self" }

files["tools/*.lua"] = {
    ignore = { "512" },
    max_line_length = false,
}
