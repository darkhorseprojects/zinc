std = "lua54"
max_line_length = 120
ignore = { "212/self" }

files["../../tests/**/*.lua"] = {
    globals = { "after_each", "before_each", "describe", "it" },
    ignore = { "143" },
    max_line_length = false,
}

files["../../tools/*.lua"] = {
    ignore = { "512" },
    max_line_length = false,
}
